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

    /// Publish rooms, zones, and scenes together (one coherent snapshot).
    /// Rooms/zones are stored separately so the widget can group them; `groups`
    /// reads them back merged. Scenes are keyed to their owning room/zone id.
    func write(rooms: [WidgetRoomSnapshot], zones: [WidgetRoomSnapshot], scenes: [WidgetSceneSnapshot]) {
        let encoder = JSONEncoder()
        if let roomsData = try? encoder.encode(rooms) { ud?.set(roomsData, forKey: Key.rooms) }
        if let zonesData = try? encoder.encode(zones) { ud?.set(zonesData, forKey: Key.zones) }
        if let scenesData = try? encoder.encode(scenes) { ud?.set(scenesData, forKey: Key.scenes) }
        ud?.set(Date(), forKey: Key.updatedAt)
    }

    func write(bridges: [String: WidgetBridgeCredentials]) {
        // Secrets go to the shared Keychain only (M-02/D-018). The App Group
        // carries non-secret routing metadata for display.
        if bridges.isEmpty {
            SharedKeychainStore.delete(account: SharedKeychainStore.bridgeCredentialsAccount)
            ud?.removeObject(forKey: Key.routing)
            ud?.removeObject(forKey: Key.bridgeIP)
            WidgetCenter.shared.reloadAllTimelines()
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
    func markAllGroups(on isOn: Bool, brightness: Double? = nil) {
        func patched(_ list: [WidgetRoomSnapshot]) -> [WidgetRoomSnapshot] {
            list.map { g -> WidgetRoomSnapshot in
                var c = g
                c.isOn = isOn
                if let brightness { c.brightness = brightness }
                return c
            }
        }
        if let d = try? JSONEncoder().encode(patched(rooms)) { ud?.set(d, forKey: Key.rooms) }
        if let d = try? JSONEncoder().encode(patched(zones)) { ud?.set(d, forKey: Key.zones) }
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
        scrubLegacyPlaintextSecrets()
        SharedKeychainStore.delete(account: SharedKeychainStore.bridgeCredentialsAccount)
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
