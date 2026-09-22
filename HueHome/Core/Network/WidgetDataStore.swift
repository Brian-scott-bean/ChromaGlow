// WidgetDataStore.swift
// ChromaGlow — shared widget data layer
//
// Shared data layer between the main app and the widget/watch extensions.
// Uses App Group UserDefaults (group.com.huehome.pro) so the processes
// can read and write without XPC or file-coordination overhead.
//
// WRITE path: UnifiedOrchestrator.scheduleWidgetWrite() — debounced 500ms,
//   fired by room/zone rebuilds AND scene loads/mutations. Scenes are
//   preserved-until-first-load: the launch publish must not clobber the
//   stored snapshot with the not-yet-loaded empty array.
// READ path:  HueWidgetProvider (timeline), SceneAppEntity/HueGroupEntity
//   queries, Control Center controls, and the Siri intent layer.
//
// Also contains the lightweight WidgetAPIClient used by the widget
// to fetch a fresh grouped_light state in a single network call.

import Foundation
import WidgetKit

// MARK: - Shared Room Model

struct WidgetRoomSnapshot: Codable, Identifiable {
    let id:             String
    let name:           String
    let archetype:      String?
    var isOn:           Bool
    var brightness:     Double   // 1–100
    let lightCount:     Int
    let groupedLightId: String?  // enables fresh fetch without re-fetching rooms
    let bridgeID:       String?  // bridge routing key for multi-bridge intent writes
    let bridgeName:     String?  // display name for per-bridge sections (optional)
    /// "room" or "zone" — optional/defaulted so older snapshots (no key) decode as rooms.
    let kind:           String?

    /// Convenience: a zone snapshot (vs a room).
    var isZone: Bool { kind == "zone" }

    init(
        id: String,
        name: String,
        archetype: String?,
        isOn: Bool,
        brightness: Double,
        lightCount: Int,
        groupedLightId: String?,
        bridgeID: String? = nil,
        bridgeName: String? = nil,
        kind: String? = "room"
    ) {
        self.id = id
        self.name = name
        self.archetype = archetype
        self.isOn = isOn
        self.brightness = brightness
        self.lightCount = lightCount
        self.groupedLightId = groupedLightId
        self.bridgeID = bridgeID
        self.bridgeName = bridgeName
        self.kind = kind
    }
}

/// A recallable Hue scene, associated with the room/zone it belongs to.
/// Widgets/complications recall via `PUT /clip/v2/resource/scene/{id}`.
struct WidgetSceneSnapshot: Codable, Identifiable {
    let id:           String  // real Hue scene UUID (used for recall)
    let name:         String
    let ownerGroupID: String  // matches WidgetRoomSnapshot.id of the owning room/zone
    let bridgeID:     String  // routing key for the recall write
}

struct WidgetBridgeCredentials: Codable {
    let bridgeID: String
    let ip: String
    let token: String
}

/// Non-secret routing metadata kept in the App Group (M-02/D-018): everything
/// a widget/complication needs for display without touching the Keychain.
struct WidgetBridgeRouting: Codable {
    let bridgeID: String
    let ip: String
}

/// Family Sharing: what a guest grant allows on one bridge, published so the
/// out-of-app surfaces (widgets, Control Center, Siri, watch) honour the same
/// feature limits Dashboard/RoomDetail do. Only GRANTED bridges have an
/// entry; a missing entry (the owner's own bridge, or a snapshot written
/// before this existed) is unrestricted — the pre-existing behaviour.
struct WidgetGuestFeatures: Codable, Equatable, Sendable {
    let canPower: Bool
    let canAdjust: Bool
    let canRecallScenes: Bool

    static let unrestricted = WidgetGuestFeatures(canPower: true, canAdjust: true, canRecallScenes: true)

    /// A preset / level / colour write turns lights ON and sets their state.
    var canPowerAndAdjust: Bool { canPower && canAdjust }
}

// MARK: - WidgetDataStore

final class WidgetDataStore: @unchecked Sendable {
    static let shared = WidgetDataStore()
    private init() {}

    private let group = "group.com.huehome.pro"
    /// One cached suite instance. This was a computed property constructing a NEW
    /// UserDefaults per access (~30 call sites in this file) — costly on fresh
    /// installs where cfprefsd detaches the not-yet-created group domain and every
    /// access becomes an uncached plist hit. UserDefaults is thread-safe.
    private let ud: UserDefaults? = UserDefaults(suiteName: "group.com.huehome.pro")

    private enum Key {
        static let rooms     = "hue_widget_rooms_v1"
        static let zones     = "hue_widget_zones_v1"
        static let scenes    = "hue_widget_scenes_v1"
        static let routing   = "hue_widget_routing_v1"
        static let bridgeIP  = "hue_widget_bridge_ip"
        static let updatedAt = "hue_widget_updated_at"
        static let largePage = "hue_widget_large_page"   // current page of the paginated Large widget
        static let structure = "hue_widget_structure_v1" // identity list of the last published snapshot
        static let guestFeatures = "hue_widget_guest_features_v1" // [bridgeID: WidgetGuestFeatures], granted bridges only
        // Legacy plaintext-secret keys (pre-D-018) — scrubbed, never written.
        static let legacyBridges = "hue_widget_bridges_v1"
        static let legacyToken   = "hue_widget_token"
    }

    // ──────────────────────────────────────────────
    // MARK: - Write (called from main app)
    // ──────────────────────────────────────────────

    func write(rooms: [WidgetRoomSnapshot]) {
        guard let data = try? JSONEncoder().encode(rooms) else { return }
        ud?.set(data, forKey: Key.rooms)
        ud?.set(Date(), forKey: Key.updatedAt)
    }

    /// What a snapshot publish actually changed — the caller gates the
    /// downstream fan-out (watch push, Siri re-donation) on it.
    struct SnapshotPublishOutcome {
        let contentChanged: Bool
    }

    /// Publish rooms, zones, and scenes together (one coherent snapshot).
    /// Rooms/zones are stored separately so the widget can group them; `groups`
    /// reads them back merged. Scenes are keyed to their owning room/zone id.
    ///
    /// Diff-gated: SSE-driven rebuilds schedule a publish every quiet gap for
    /// as long as a bridge-side dynamic scene runs — hours of byte-identical
    /// snapshots re-written, re-pushed to the watch, and re-donated to Siri.
    /// An unchanged snapshot now skips everything except the freshness stamp.
    /// A STRUCTURAL change (the room/zone/scene identity list — what the
    /// widget's timeline actually renders) additionally reloads timelines:
    /// nothing else did, so a revocation-pruned room list sat stale on the
    /// widget until WidgetKit's own budgeted refresh, potentially hours.
    /// State-only flips (isOn/brightness) deliberately do NOT reload — the
    /// timeline provider fetches live grouped-light state itself, and reload
    /// budget is precious.
    /// `reloadOnStructureChange` must be true ONLY from the main app — the
    /// widget extension also calls this to persist freshly fetched state,
    /// and a timeline reload issued from inside the widget process is a
    /// refresh-loop hazard. When false, the structure key is left alone so
    /// the main app's next publish still detects and reloads.
    @discardableResult
    func write(rooms: [WidgetRoomSnapshot], zones: [WidgetRoomSnapshot], scenes: [WidgetSceneSnapshot],
               reloadOnStructureChange: Bool = false) -> SnapshotPublishOutcome {
        let encoder = JSONEncoder()
        guard let roomsData = try? encoder.encode(rooms),
              let zonesData = try? encoder.encode(zones),
              let scenesData = try? encoder.encode(scenes) else {
            return SnapshotPublishOutcome(contentChanged: false)
        }
        // updatedAt always advances — it means "the app last confirmed this
        // snapshot", and any staleness affordance depends on that meaning.
        ud?.set(Date(), forKey: Key.updatedAt)

        let contentChanged = roomsData != ud?.data(forKey: Key.rooms)
            || zonesData != ud?.data(forKey: Key.zones)
            || scenesData != ud?.data(forKey: Key.scenes)
        guard contentChanged else {
            return SnapshotPublishOutcome(contentChanged: false)
        }

        let structure = ((rooms + zones).map { "\($0.id)|\($0.name)|\($0.kind ?? "room")" }
            + ["§"]
            + scenes.map { "\($0.id)|\($0.name)|\($0.ownerGroupID)" })
            .joined(separator: ",")

        ud?.set(roomsData, forKey: Key.rooms)
        ud?.set(zonesData, forKey: Key.zones)
        ud?.set(scenesData, forKey: Key.scenes)

        if reloadOnStructureChange, structure != (ud?.string(forKey: Key.structure) ?? "") {
            ud?.set(structure, forKey: Key.structure)
            WidgetCenter.shared.reloadAllTimelines()
        }
        // Controls DO show state (room toggles, the All Lights master
        // switch), and nothing else refreshes them: WidgetKit's timeline
        // reload doesn't reach Control Center. Main app only (same rule as
        // the timeline reload above).
        if reloadOnStructureChange { Self.reloadControls() }
        return SnapshotPublishOutcome(contentChanged: true)
    }

    func write(bridges: [String: WidgetBridgeCredentials]) {
        // Secrets go to the shared Keychain only (M-02/D-018). The App Group
        // carries non-secret routing metadata for display.
        if bridges.isEmpty {
            SharedKeychainStore.delete(account: SharedKeychainStore.bridgeCredentialsAccount)
            ud?.removeObject(forKey: Key.routing)
            ud?.removeObject(forKey: Key.bridgeIP)
            WidgetCenter.shared.reloadAllTimelines()
            Self.reloadControls()
        } else {
            // Deterministic encoding (sortedKeys) so an unchanged map skips
            // the Keychain delete/add cycle — publish runs on every loadAll
            // and the non-atomic upsert briefly exposes a no-credential
            // window to concurrently rendering widget timelines.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let blob = try? encoder.encode(bridges),
               SharedKeychainStore.load(account: SharedKeychainStore.bridgeCredentialsAccount) != blob {
                SharedKeychainStore.save(blob, account: SharedKeychainStore.bridgeCredentialsAccount)
                // Credential state changed (pair/re-pair): kick the widget out
                // of any frozen `.never`-policy unpaired timeline — nothing
                // else reloads it, so a widget that rendered while unpaired
                // stayed blank forever even after a successful re-pair.
                WidgetCenter.shared.reloadAllTimelines()
                Self.reloadControls()
            }
            let routing = bridges.mapValues { WidgetBridgeRouting(bridgeID: $0.bridgeID, ip: $0.ip) }
            if let data = try? encoder.encode(routing) {
                ud?.set(data, forKey: Key.routing)
            }
            if let first = bridges.values.first {
                ud?.set(first.ip, forKey: Key.bridgeIP)
            }
        }
        scrubLegacyPlaintextSecrets()
    }

    /// Optimistically patch one group's cached on/brightness and persist just the
    /// list (rooms or zones) that owns it, so the widget reflects a tap immediately.
    func applyOptimistic(groupID: String, isOn: Bool? = nil, brightness: Double? = nil) {
        func patched(_ list: [WidgetRoomSnapshot]) -> [WidgetRoomSnapshot]? {
            guard let idx = list.firstIndex(where: { $0.id == groupID }) else { return nil }
            var copy = list
            if let isOn { copy[idx].isOn = isOn }
            if let brightness { copy[idx].brightness = brightness }
            return copy
        }
        if let updated = patched(rooms), let data = try? JSONEncoder().encode(updated) {
            ud?.set(data, forKey: Key.rooms)
        } else if let updated = patched(zones), let data = try? JSONEncoder().encode(updated) {
            ud?.set(data, forKey: Key.zones)
        }
    }

    /// Optimistically mark every room and zone on or off (used by All-Off and the
    /// All-Lights control). `brightness` is applied only when non-nil.
    /// `onlyGroupIDs` limits the patch to the groups actually written (a
    /// guest grant can exclude some) — never paint a change that didn't happen.
    func markAllGroups(on isOn: Bool, brightness: Double? = nil, onlyGroupIDs: Set<String>? = nil) {
        func patched(_ list: [WidgetRoomSnapshot]) -> [WidgetRoomSnapshot] {
            list.map { g -> WidgetRoomSnapshot in
                if let onlyGroupIDs, !onlyGroupIDs.contains(g.id) { return g }
                var c = g
                c.isOn = isOn
                if let brightness { c.brightness = brightness }
                return c
            }
        }
        if let d = try? JSONEncoder().encode(patched(rooms)) { ud?.set(d, forKey: Key.rooms) }
        if let d = try? JSONEncoder().encode(patched(zones)) { ud?.set(d, forKey: Key.zones) }
    }

    /// Publish the per-bridge guest feature limits (granted bridges only).
    /// Returns true when the stored map changed — the caller re-pushes the
    /// watch on a feature-only change, which the room diff alone would miss.
    @discardableResult
    func write(guestFeatures: [String: WidgetGuestFeatures]) -> Bool {
        if guestFeatures.isEmpty {
            let hadAny = ud?.data(forKey: Key.guestFeatures) != nil
            ud?.removeObject(forKey: Key.guestFeatures)
            return hadAny
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(guestFeatures) else { return false }
        guard data != ud?.data(forKey: Key.guestFeatures) else { return false }
        ud?.set(data, forKey: Key.guestFeatures)
        return true
    }

    /// Remove the pre-D-018 plaintext token copies from the App Group.
    func scrubLegacyPlaintextSecrets() {
        ud?.removeObject(forKey: Key.legacyBridges)
        ud?.removeObject(forKey: Key.legacyToken)
    }

    /// Forget-all: wipe every shared artifact — snapshot, routing metadata,
    /// and the Keychain credential blob.
    func clearAll() {
        ud?.removeObject(forKey: Key.rooms)
        ud?.removeObject(forKey: Key.zones)
        ud?.removeObject(forKey: Key.scenes)
        ud?.removeObject(forKey: Key.routing)
        ud?.removeObject(forKey: Key.bridgeIP)
        ud?.removeObject(forKey: Key.updatedAt)
        ud?.removeObject(forKey: Key.largePage)
        ud?.removeObject(forKey: Key.guestFeatures)
        // The structure key too: left behind, a re-pair publishing the same
        // rooms matched the stale identity list and never reloaded timelines.
        ud?.removeObject(forKey: Key.structure)
        scrubLegacyPlaintextSecrets()
        SharedKeychainStore.delete(account: SharedKeychainStore.bridgeCredentialsAccount)
        Self.reloadControls()
    }

    /// Refresh Control Center / Lock Screen controls (iOS 18+). They read
    /// this store, but `reloadAllTimelines()` never reaches them — before
    /// this nothing in the app ever reloaded a control.
    static func reloadControls() {
        #if os(iOS)
        if #available(iOS 18.0, *) {
            ControlCenter.shared.reloadAllControls()
        }
        #endif
    }

    /// Timelines AND controls — what a widget/control intent calls after a write.
    static func reloadAllSurfaces() {
        WidgetCenter.shared.reloadAllTimelines()
        reloadControls()
    }

    // ──────────────────────────────────────────────
    // MARK: - Read (called from widget)
    // ──────────────────────────────────────────────

    var rooms: [WidgetRoomSnapshot] {
        guard let d = ud?.data(forKey: Key.rooms),
              let r = try? JSONDecoder().decode([WidgetRoomSnapshot].self, from: d)
        else { return [] }
        return r
    }

    var zones: [WidgetRoomSnapshot] {
        guard let d = ud?.data(forKey: Key.zones),
              let z = try? JSONDecoder().decode([WidgetRoomSnapshot].self, from: d)
        else { return [] }
        return z
    }

    /// Rooms followed by zones — the full set of controllable groups.
    var groups: [WidgetRoomSnapshot] { rooms + zones }

    var scenes: [WidgetSceneSnapshot] {
        guard let d = ud?.data(forKey: Key.scenes),
              let s = try? JSONDecoder().decode([WidgetSceneSnapshot].self, from: d)
        else { return [] }
        return s
    }

    /// Scenes belonging to a specific room/zone (matched by owner id + bridge).
    func scenes(forGroup groupID: String, bridgeID: String?) -> [WidgetSceneSnapshot] {
        scenes.filter { $0.ownerGroupID == groupID && (bridgeID == nil || $0.bridgeID == bridgeID) }
    }

    /// Credential map from the shared Keychain access group (D-018).
    var bridges: [String: WidgetBridgeCredentials] {
        guard let data = SharedKeychainStore.load(account: SharedKeychainStore.bridgeCredentialsAccount),
              let decoded = try? JSONDecoder().decode([String: WidgetBridgeCredentials].self, from: data)
        else { return [:] }
        return decoded
    }

    /// Per-bridge guest feature limits (granted bridges only).
    var guestFeatures: [String: WidgetGuestFeatures] {
        guard let data = ud?.data(forKey: Key.guestFeatures),
              let decoded = try? JSONDecoder().decode([String: WidgetGuestFeatures].self, from: data)
        else { return [:] }
        return decoded
    }

    /// What a surface may do to a group on `bridgeID`. Unrestricted for
    /// owned bridges and nil ids (legacy single-bridge snapshots).
    func features(for bridgeID: String?) -> WidgetGuestFeatures {
        Self.features(for: bridgeID, in: guestFeatures)
    }

    /// Pure lookup (tests + callers that already hold the map).
    static func features(for bridgeID: String?,
                         in map: [String: WidgetGuestFeatures]) -> WidgetGuestFeatures {
        guard let bridgeID, let features = map[bridgeID] else { return .unrestricted }
        return features
    }

    /// Non-secret routing metadata (display/pairing state — no Keychain hit).
    var routing: [String: WidgetBridgeRouting] {
        guard let data = ud?.data(forKey: Key.routing),
              let decoded = try? JSONDecoder().decode([String: WidgetBridgeRouting].self, from: data)
        else { return [:] }
        return decoded
    }

    var bridgeIP:    String? { ud?.string(forKey: Key.bridgeIP) }
    var lastUpdated: Date?   { ud?.object(forKey: Key.updatedAt) as? Date }
    var isPaired:    Bool    { !routing.isEmpty || !(bridgeIP?.isEmpty ?? true) }

    /// Current page of the paginated Large widget. Shared across every Large
    /// instance (widgets have no per-instance intent identity); a `WidgetPageIntent`
    /// writes it, the provider clamps it into range and the view slices by it.
    var largePage: Int {
        get { ud?.integer(forKey: Key.largePage) ?? 0 }
        set { ud?.set(newValue, forKey: Key.largePage) }
    }

    func credentials(for bridgeID: String?) -> WidgetBridgeCredentials? {
        let map = bridges
        if let bridgeID, let creds = map[bridgeID] { return creds }
        // Legacy single-bridge fallback: the migrated legacy Keychain slots
        // (the app's KeychainManager moved them into the shared group).
        if let ip = SharedKeychainStore.loadString(account: "hue_bridge_ip"),
           let token = SharedKeychainStore.loadString(account: "hue_api_token") {
            return WidgetBridgeCredentials(bridgeID: bridgeID ?? "legacy-default", ip: ip, token: token)
        }
        // Upgrade-window fallback (READ-ONLY): the app was updated but has not
        // launched yet, so the shared-Keychain blob does not exist while the
        // pre-D-018 plaintext copies are still in the App Group. Without this
        // the widget/Siri surfaces of a paired user go dead until the app is
        // opened. The app's first launch writes the blob and scrubs these
        // keys, after which this path is unreachable.
        if let data = ud?.data(forKey: Key.legacyBridges),
           let legacyMap = try? JSONDecoder().decode([String: WidgetBridgeCredentials].self, from: data) {
            if let bridgeID, let creds = legacyMap[bridgeID] { return creds }
            if bridgeID == nil, let firstKey = legacyMap.keys.sorted().first { return legacyMap[firstKey] }
        }
        if let ip = ud?.string(forKey: Key.bridgeIP),
           let token = ud?.string(forKey: Key.legacyToken) {
            return WidgetBridgeCredentials(bridgeID: bridgeID ?? "legacy-default", ip: ip, token: token)
        }
        return nil
    }

    /// First available credentials — deterministic (sorted by bridge id) so
    /// the widget's single-fetch refresh always targets the same bridge.
    func primaryCredentials() -> WidgetBridgeCredentials? {
        let map = bridges
        if let firstKey = map.keys.sorted().first, let creds = map[firstKey] { return creds }
        return credentials(for: nil)
    }

    // ──────────────────────────────────────────────
    // MARK: - TTL
    // ──────────────────────────────────────────────

    /// Seconds since the last successful write. `.infinity` if never written.
    var staleness: TimeInterval {
        guard let last = lastUpdated else { return .infinity }
        return Date().timeIntervalSince(last)
    }

    /// Returns true if the stored snapshot is older than `interval` seconds.
    /// The widget extension calls this to decide whether to show a "stale" badge.
    func isStale(olderThan interval: TimeInterval = 300) -> Bool {
        staleness > interval
    }
}

// MARK: - WidgetAPIClient

/// Lightweight, widget-only HTTP client.
/// Makes a single call to /grouped_light to refresh all room states.
/// Uses the shared pinned bridge trust delegate (M-01/D-016).
enum WidgetAPIClient {

    private static let session: URLSession = {
        URLSession(configuration: .default,
                   delegate: BridgePinnedTrustDelegate.shared,
                   delegateQueue: nil)
    }()

    /// Test seam: replaces the pinned session so unit tests can stub or hang
    /// the transport (URLProtocol stubs cannot present a pinned server trust).
    /// nonisolated(unsafe): test-only — set once before any fetch on the
    /// test's thread, always nil in production, never mutated concurrently.
    nonisolated(unsafe) static var sessionOverride: URLSession?

    // ──────────────────────────────────────────────
    // MARK: - Response Models
    // ──────────────────────────────────────────────

    struct V2Response<T: Decodable>: Decodable { let data: [T] }

    struct GLData: Decodable {
        let id:      String
        let on:      OnState
        let dimming: Dimming?
        struct OnState:  Decodable { let on: Bool }
        struct Dimming:  Decodable { let brightness: Double }
    }

    // ──────────────────────────────────────────────
    // MARK: - Fetch
    // ──────────────────────────────────────────────

    /// ONE call: fetch all grouped_light states.
    /// Widget merges this against cached WidgetRoomSnapshot array.
    static func fetchGroupedLights(ip: String, token: String) async throws -> [GLData] {
        guard let url = URL(string: "https://\(ip)/clip/v2/resource/grouped_light") else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue(token, forHTTPHeaderField: "hue-application-key")
        let (data, _) = try await (sessionOverride ?? session).data(for: req)
        return try JSONDecoder().decode(V2Response<GLData>.self, from: data).data
    }

    /// Round-2 Item 3: fetch with a HARD wall-clock budget. WidgetKit throttles
    /// (and eventually renders as the blurred placeholder) extensions whose
    /// timeline generation is repeatedly slow — an unreachable bridge must cost
    /// at most `budget` seconds, never the transport's full timeout. Returns
    /// nil on timeout or any transport error; callers fall back to the cache.
    static func fetchGroupedLightsBounded(
        ip: String, token: String, budget: TimeInterval
    ) async -> [GLData]? {
        let fetch = Task { try await fetchGroupedLights(ip: ip, token: token) }
        let reaper = Task {
            try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
            fetch.cancel()
        }
        defer { reaper.cancel() }
        return try? await fetch.value
    }

    // The former per-target trust-all TrustDelegate (audit M-01) was replaced
    // by the shared BridgePinnedTrustDelegate (D-016).
}
