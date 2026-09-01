// UnifiedOrchestrator.swift
// CastChroma — Stage 2A Multi-Bridge
//
// Aggregates N bridges into a single source of truth.
// Each registered, active bridge gets its own BridgeAPIClient.
// All rooms from all bridges are fetched in parallel and merged
// into a single sorted list for the Dashboard to consume.
//
// Architecture:
//   SwiftData BridgeRecord[] (persisted)
//     └─ UnifiedOrchestrator (in-memory, @Observable)
//          ├─ BridgeAPIClient per bridge
//          └─ allRooms: [RoomDisplayItem]  ← merged, sorted
//
// SSE: one connection per bridge, all events merged into allRooms.
// Cross-bridge "All Off": fires simultaneously on every active bridge.

import Foundation
import SwiftUI
import SwiftData
import OSLog
import CoreLocation

// MARK: - Bridge Connection Status

enum BridgeConnectionStatus {
    case connecting
    case connected
    case error(String)
    case disabled
}

// MARK: - ActiveEffectEntry

/// Represents one room that currently has a Hue effect applied.
/// Stored in UnifiedOrchestrator.activeEffectEntries so both
/// DashboardView (menu) reads this shared state (the old Effects surface's
/// writer was deleted in R4 — see DEVLOG for the follow-up).
/// Surfaced when a bulk write (All Off, automation preset/effect) could not
/// reach every room even after the gate's retry (M-08) — the UI shows it so
/// partial application is never silent.
struct BulkWriteFailure: Equatable {
    let operation: String
    let roomNames: [String]
    let at: Date
}

struct ActiveEffectEntry: Identifiable, Equatable {
    /// Presentation key. For a bridge-attributed live effect it is
    /// bridge-qualified (`liveID`), so two bridges running the same room id
    /// produce two rows instead of one silently overwriting the other in
    /// `addActiveEffect` — the same rule recovered rows (packet 8) already
    /// follow by keying off the MANIFEST id. An unattributed live row keeps
    /// the bare room id.
    let id: String
    /// The room this row is about. For a recovered row it is the manifest's
    /// room id, which may resolve to no room at all.
    let roomID: String
    /// The bridge whose look this live row asserts, when the publisher could
    /// say. nil = unattributed: exact removal retains such a row — never
    /// destroy what cannot be attributed.
    let bridgeID: String?
    let roomName: String
    let groupedLightID: String?   // needed to stop bridge-native effects
    let effectID: String          // HueEffect.id
    let effectName: String        // display name
    let effectIcon: String        // SF Symbol
    let isAppDriven: Bool         // true → engine loop must keep running
    /// Non-nil = a bridge-stored animation recovered at launch (packet 8).
    /// Carries the exact identity every stop path must use; the room id alone
    /// cannot say which bridge.
    let recovered: UnifiedOrchestrator.RecoveredBridgeAnimationKey?

    /// Live effect with exact bridge attribution (round 4c).
    init(liveBridgeID: String?, roomID: String, roomName: String,
         groupedLightID: String?, effectID: String,
         effectName: String, effectIcon: String, isAppDriven: Bool) {
        self.id = Self.liveID(bridgeID: liveBridgeID, roomID: roomID)
        self.roomID = roomID
        self.bridgeID = liveBridgeID
        self.roomName = roomName
        self.groupedLightID = groupedLightID
        self.effectID = effectID
        self.effectName = effectName
        self.effectIcon = effectIcon
        self.isAppDriven = isAppDriven
        self.recovered = nil
    }

    /// Unattributed live effect. Every pre-round-4c call site keeps compiling
    /// verbatim; the row keys by bare room id and exact removal retains it.
    init(id: String, roomName: String, groupedLightID: String?, effectID: String,
         effectName: String, effectIcon: String, isAppDriven: Bool) {
        self.id = id
        self.roomID = id
        self.bridgeID = nil
        self.roomName = roomName
        self.groupedLightID = groupedLightID
        self.effectID = effectID
        self.effectName = effectName
        self.effectIcon = effectIcon
        self.isAppDriven = isAppDriven
        self.recovered = nil
    }

    /// Recovered bridge-stored animation.
    init(recovered animation: UnifiedOrchestrator.RecoveredBridgeAnimation) {
        self.id = Self.recoveredID(manifestID: animation.manifest.id)
        self.roomID = animation.manifest.roomID
        self.bridgeID = animation.bridgeID
        self.roomName = animation.roomName
        self.groupedLightID = animation.room?.groupedLightID
        self.effectID = "comp_\(animation.manifest.presetID.uuidString)"
        self.effectName = animation.displayName
        self.effectIcon = "externaldrive.connected.to.line.below"
        // No app task exists behind this row, so it must never draw the
        // "keep app open" chrome that an app-driven effect does.
        self.isAppDriven = false
        self.recovered = animation.key
    }

    static func recoveredID(manifestID: UUID) -> String {
        "cg-recovered:\(manifestID.uuidString)"
    }

    /// Presentation key for a bridge-attributed live row. Falls back to the
    /// bare room id when the publisher cannot name a bridge, so unattributed
    /// rows keep their historical key.
    static func liveID(bridgeID: String?, roomID: String) -> String {
        guard let bridgeID else { return roomID }
        return "cg-live:\(bridgeID):\(roomID)"
    }
}

// MARK: - String + Hue UUID Detection

private extension String {
    /// Returns true if this string is formatted like a Hue API v2 UUID
    /// (8-4-4-4-12 hex, e.g. "004289e5-0e84-4a7a-b194-3c4ccf89e2a1").
    /// Third-party apps sometimes store the internal UUID as the scene name.
    var isHueUUID: Bool {
        let pattern = #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#
        return range(of: pattern, options: .regularExpression) != nil
    }
    /// Returns a friendly fallback if this string is a raw UUID, otherwise self.
    var sanitizedSceneName: String { isHueUUID ? "Untitled Scene" : self }
}

// MARK: - UnifiedOrchestrator

@Observable
@MainActor
final class UnifiedOrchestrator {

    // MARK: - Public State

    /// All rooms across every active bridge, sorted alphabetically.
    /// Reverse map: light UUID → room ID. Rebuilt on every loadAll().
    private var lightIDToRoomID: [String: String] = [:]

    /// Reverse map: light UUID → zone ID. Parallel to lightIDToRoomID.
    /// A light may appear in both maps (member of a room AND a zone).
    private var lightIDToZoneID: [String: String] = [:]

    var allRooms: [RoomDisplayItem] = []

    /// Per-bridge SSE connection status  (bridgeID → status)
    var connectionStatus: [String: BridgeConnectionStatus] = [:]

    /// Brief error message for the UI toast (auto-cleared after 3 s).
    /// Set on API failure; nil when no error is pending.
    var toastMessage: String? = nil

    /// True while an initial full-load is in flight for any bridge.
    var isLoading: Bool = false

    /// Non-nil during a full-load error (transient — cleared on next successful load).
    var errorMessage: String? = nil

    /// Timestamp of the last successful loadAll() completion.
    /// Read by DashboardView to decide whether a background refresh is needed.
    var lastLoadedAt: Date = .distantPast

    /// Whether to group rooms by bridge in the UI (user toggle).
    var groupByBridge: Bool = false

    /// Demo mode — true when exploring the app without a real Bridge.
    /// All state changes work locally; no network calls are made.
    var isDemoMode: Bool = false

    /// Family Sharing: guest-state summary for the UI shell (banner, tab
    /// gating). Recomputed whenever grants or clients change — views observe
    /// this instead of running their own @Query over GuestAccessGrant.
    private(set) var guestAccessInfo = GuestAccessInfo.none

    // ── All Day Scenes (Circadian / Solar) ────────────────────────────────────
    //
    // Goal: "All day" lighting without requiring continuous location access.
    // We store a one-time location anchor (lat/lon + timezone) and compute
    // sunrise/sunset locally. Updates are grouped_light-only and low cadence.
    private var allDayTask: Task<Void, Never>? = nil
    private var allDayGeneration: Int = 0

    /// All-Day keeps its OWN dedicated senders — deliberately not part of
    /// `restSendersByBridge`. Its cadence, ownership, and stop path are entirely
    /// separate from Composer/Studio playback: `stopStudioMode` clears every
    /// scope on every one of those senders, so sharing them would let a Studio
    /// stop-all drop an All-Day tick, and All-Day's 1.2 s grouped fades would
    /// interleave into Composer's FIFO order and delay composition frames.
    ///
    /// Packet 6: one sender PER BRIDGE, one scope PER ROOM inside it. Before
    /// packet 6 this was a single sender with a single sentinel scope, so every
    /// room in a tick overwrote the previous room's pending slot and in the
    /// general case only the last room survived.
    @ObservationIgnored
    private var allDayRestSendersByBridge: [String: RestSender] = [:]

    /// Bridges All-Day may not touch. Inserted SYNCHRONOUSLY by `removeBridge`
    /// before its first `await`, and deliberately NOT cleared when removal
    /// finishes: a tick captured before the removal can still hold that bridge's
    /// targets, and without a persistent tombstone it would recreate the sender
    /// long afterwards. Cleared only when the bridge is legitimately registered
    /// again — `configure(bridges:modelContext:)` and `addBridge(_:)`, BOTH of
    /// which assign into `clients`.
    @ObservationIgnored
    private var allDayBlockedBridgeKeys: Set<String> = []

    /// Set for the duration of `forgetAllBridges`. Detaching the senders up
    /// front is not sufficient on its own: forget-all suspends at its first
    /// `await`, and a `startAllDayScenes` arriving in that window would build a
    /// fresh task and fresh senders OUTSIDE the retired snapshot.
    @ObservationIgnored
    private var allDayTeardownInProgress = false

    /// The All-Day mailbox for a bridge, or nil when All-Day may not write to
    /// it. Optional on purpose: a lazily-creating non-optional accessor cannot
    /// express refusal, so every call site would have to remember to check the
    /// tombstone first — and one that forgot would recreate a sender for a
    /// bridge that is mid-removal. Refusal is structural here instead.
    private func allDayRestSender(for bridgeID: String?) -> RestSender? {
        guard isAllDayBridgeEligible(bridgeID) else { return nil }
        let key = bridgeID ?? "legacy"
        if let sender = allDayRestSendersByBridge[key] { return sender }
        let sender = RestSender()
        allDayRestSendersByBridge[key] = sender
        return sender
    }

    /// May All-Day touch this bridge at all? Deliberately SEPARATE from
    /// `isAllDayWriteAllowed`, which answers the different question of whether a
    /// ROOM is currently under playback. Folding the two together would let a
    /// later edit to the ownership rule silently reopen the recreation race.
    private func isAllDayBridgeEligible(_ bridgeID: String?) -> Bool {
        !allDayTeardownInProgress && !allDayBlockedBridgeKeys.contains(bridgeID ?? "legacy")
    }

    /// Lift the All-Day tombstone for a bridge that is legitimately registered
    /// again. One helper, called from BOTH paths that assign into `clients`
    /// (`configure(bridges:modelContext:)` and `addBridge(_:)`) — a third
    /// registration path that forgot to call it would silently disable All-Day
    /// for that bridge forever, which is why a source guard pins both callers.
    private func clearAllDayBridgeTombstone(_ bridgeID: String) {
        allDayBlockedBridgeKeys.remove(bridgeID)
    }

    // ── Bridge-native playback ownership (packet 6) ──────────────────────
    //
    // Studio's `.bridgeNative` cards (candle, fire, sparkle, prism, opal,
    // glisten) are LONG-RUNNING firmware effects, but they leave no
    // orchestrator state at all — the branch writes per-light effects and then
    // records only the view model's `runningEffects` row.
    //
    // `activeEffectEntries` cannot stand in for that: its `isAppDriven` flag
    // is false for BOTH firmware effects and one-shot `.bridgeOptimized`
    // presets, so it cannot tell persistent playback from a command that
    // already finished. This registry can, and it lives here rather than in
    // the view model so ownership survives StudioView being dismissed.

    /// Exact identity of one bridge-native owner. Never keyed by roomID alone —
    /// the same room id can exist on two bridges.
    struct BridgeNativeOwnershipKey: Hashable {
        let bridgeKey: String
        let roomID: String
    }

    /// A specific bridge-native START. The generation is what makes a stale stop
    /// harmless: an unregister only clears ownership it still holds.
    struct BridgeNativeOwnershipToken: Hashable, Sendable {
        let key: BridgeNativeOwnershipKey
        let generation: Int
    }

    /// Exact identity of one LIVE composition playback (round 4e). The runtime
    /// authority — generations, runtimes, scheduler order, transport claims —
    /// is keyed by this, never by roomID alone: the same room id can exist on
    /// two bridges, and a room-only key makes the second start overwrite the
    /// first's real runtime while both presentation rows survive.
    ///
    /// `bridgeKey` follows the REST/telemetry normalization (`bridgeID ??
    /// "legacy"`), the same convention as `BridgeNativeOwnershipKey` and
    /// `ComposerTelemetrySessionKey` — NOT the Entertainment maps' `?? ""`
    /// coercion, which stays confined to those bridge-keyed maps.
    ///
    /// **Why this key carries no resource kind.** `StudioSelectionKey` and
    /// `RolodexItemToken` distinguish `.room` from `.zone`; this key does not,
    /// and that asymmetry is deliberate. It rests on one invariant:
    ///
    /// > Within a single bridge, a room's id and a zone's id are never equal.
    ///
    /// `RoomDisplayItem.id` is the bridge's CLIP v2 resource `rid` — a UUID
    /// assigned per resource, with `groupedLightID` kept as a separate field on
    /// the same struct, so `id` is never the grouped-light id. Distinct v2
    /// resources receive distinct UUIDs regardless of type, so a room and a zone
    /// on one bridge cannot collide. `testRoomAndZoneIDsNeverCollideWithinABridge`
    /// proves it over the live room/zone dictionaries.
    ///
    /// The kind on the selection keys is therefore defense in depth for view
    /// identity and the legacy nil-bridge path — NOT a claim that this key is
    /// insufficient. If that test ever fails, adding `kind` here is its own
    /// reviewed change to round-4e ownership identity; it may not ride along
    /// with a UI packet.
    struct CompositionPlaybackKey: Hashable, Sendable {
        let bridgeKey: String
        let roomID: String

        init(bridgeKey: String, roomID: String) {
            self.bridgeKey = bridgeKey
            self.roomID = roomID
        }

        init(bridgeID: String?, roomID: String) {
            self.init(bridgeKey: bridgeID ?? "legacy", roomID: roomID)
        }
    }

    @ObservationIgnored
    private var bridgeNativeOwners: [BridgeNativeOwnershipKey: Int] = [:]
    @ObservationIgnored
    private var bridgeNativeOwnershipSequence: Int = 0

    /// Claim a room for a bridge-native effect. Called BEFORE the first mutating
    /// request, not when the effect is finally registered — the startup sequence
    /// turns the group on and writes per-light firmware effects well before it
    /// stores a `RunningEffect`, and All-Day must not dispatch into that window.
    @discardableResult
    func beginBridgeNativeOwnership(roomID: String, bridgeID: String?) -> BridgeNativeOwnershipToken {
        bridgeNativeOwnershipSequence &+= 1
        let key = BridgeNativeOwnershipKey(bridgeKey: bridgeID ?? "legacy", roomID: roomID)
        bridgeNativeOwners[key] = bridgeNativeOwnershipSequence
        noteRoomOwnershipChange(bridgeID: bridgeID, roomID: roomID)
        return BridgeNativeOwnershipToken(key: key, generation: bridgeNativeOwnershipSequence)
    }

    // ── Per-exact-bridge+room ownership generation (packet 8) ────────────
    //
    // A recovered stop suspends between "the bridge confirmed the resources are
    // gone" and "turn the room off". Something else can take that exact bridge
    // and room in the gap, and an off PUT landing then would darken a room that
    // is legitimately playing. The generation is captured when the stop begins
    // and re-checked immediately before the off, exactly as
    // `BridgeNativeOwnershipToken` guards its own release.

    @ObservationIgnored
    private var roomOwnershipGenerations: [BridgeNativeOwnershipKey: Int] = [:]
    @ObservationIgnored
    private var roomOwnershipSequence: Int = 0

    /// Called by EVERY owner takeover of an exact bridge + room.
    func noteRoomOwnershipChange(bridgeID: String?, roomID: String) {
        roomOwnershipSequence &+= 1
        roomOwnershipGenerations[
            BridgeNativeOwnershipKey(bridgeKey: bridgeID ?? "legacy", roomID: roomID)
        ] = roomOwnershipSequence
    }

    func roomOwnershipGeneration(bridgeID: String?, roomID: String) -> Int {
        roomOwnershipGenerations[
            BridgeNativeOwnershipKey(bridgeKey: bridgeID ?? "legacy", roomID: roomID)
        ] ?? 0
    }

    /// Release ownership — but only if this token still holds it. A stop that
    /// completes after its effect was already replaced must not clear the
    /// replacement's claim.
    func endBridgeNativeOwnership(_ token: BridgeNativeOwnershipToken) {
        guard bridgeNativeOwners[token.key] == token.generation else { return }
        bridgeNativeOwners.removeValue(forKey: token.key)
    }

    // ── The All-Day suppression predicate (packet 6) ─────────────────────

    /// May All-Day write to this exact bridge + room?
    ///
    /// Deliberately SEPARATE from `isAllDayBridgeEligible`, which answers the
    /// different question of whether the bridge may be touched at all. Every arm
    /// below is keyed or compared on BOTH bridge and room, and each is read with
    /// its own subsystem's bridgeless convention — `"legacy"` for the Composer
    /// session, Studio scope and this registry, `""` for the Entertainment maps.
    /// Unifying those two spellings is a wider migration than this packet.
    ///
    /// Display state is not consulted: `activeEffectEntries` and the view
    /// model's `runningEffects` are presentation mirrors, and they cannot
    /// distinguish a one-shot from a continuing owner.
    private func isAllDayWriteAllowed(bridgeID: String?, roomID: String) -> Bool {
        let legacyKey = bridgeID ?? "legacy"

        // 1. Composer, ALL THREE transports. The telemetry session is opened in
        //    `startCompositionMode` BEFORE the transport decision and removed by
        //    `stopCompositionMode`, so it is the only record that covers REST,
        //    Entertainment and bridge-stored under one exact key. Notably NOT
        //    `compositionTransportByRoom`, whose roomID-only key cannot tell
        //    identical room ids on different bridges apart.
        let composerKey = ComposerTelemetrySessionKey(
            bridgeKey: legacyKey,
            scope: RestScope(roomID: roomID, owner: .composer))
        if composerTelemetrySessions[composerKey] != nil { return false }

        // 2. Entertainment ownership, recorded per bridge as bridge -> room.
        if compositionEntRoomByBridge[bridgeID ?? ""] == roomID { return false }

        // 3. Studio's app-driven engine, recorded per bridge (round 4g). The
        //    key carries the bridge and the value carries the room, so the
        //    comparison still covers both halves of the identity.
        if studioRestScopesByBridge[legacyKey] == RestScope(roomID: roomID, owner: .studio) {
            return false
        }

        // 4. Bridge-stored manifests. These are persisted, so a look uploaded in
        //    a previous session is still genuinely running on the bridge.
        //    Manifests record the bridge by IP, so resolve this bridge's IP the
        //    same way `hueClient(for:)` does and match on both fields.
        //    Packet 8: the stable bridgeID is authoritative when the manifest
        //    carries one, because an IP is a route — a DHCP move would
        //    otherwise silently un-suppress a look that is still running, and
        //    All-Day would stomp it every tick. The IP arm remains for legacy
        //    manifests written before packet 8, so this is a strict superset of
        //    the previous behaviour.
        let ownershipIP = bridgeIPForAllDayOwnership(bridgeID)
        if bridgeAnimationStore.allManifests().contains(where: { manifest in
            guard manifest.roomID == roomID else { return false }
            if let recorded = manifest.bridgeID { return recorded == legacyKey }
            guard let ownershipIP else { return false }
            return manifest.bridgeIP == ownershipIP
        }) {
            return false
        }

        // 5. Long-running Studio firmware effects.
        if bridgeNativeOwners[
            BridgeNativeOwnershipKey(bridgeKey: legacyKey, roomID: roomID)] != nil {
            return false
        }

        return true
    }

    /// This bridge's LAN IP, for matching bridge-stored manifests. Mirrors
    /// `hueClient(for:)`'s nil rule: a bridgeless room can only exist in a
    /// single-bridge home, and guessing with several bridges would reintroduce
    /// the wrong-bridge class. Unresolvable means All-Day is not blocked here —
    /// a bridge with no client cannot be written to anyway.
    private func bridgeIPForAllDayOwnership(_ bridgeID: String?) -> String? {
        guard let client = hueClient(for: bridgeID) else { return nil }
        return (try? client.credentials())?.ip
    }

    private enum AllDayKeys {
        static let enabled = "allDayScenes.enabled"
        static let lat     = "allDayScenes.anchor.lat"
        static let lon     = "allDayScenes.anchor.lon"
        static let tz      = "allDayScenes.anchor.tz"
        static let updated = "allDayScenes.anchor.updatedAt"
    }

    struct AllDayAnchor: Equatable, Codable {
        let lat: Double
        let lon: Double
        let timeZoneID: String
        let updatedAt: Date
    }

    var allDayScenesEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: AllDayKeys.enabled) }
        set { UserDefaults.standard.set(newValue, forKey: AllDayKeys.enabled) }
    }

    func loadAllDayAnchor() -> AllDayAnchor? {
        let d = UserDefaults.standard
        guard d.object(forKey: AllDayKeys.lat) != nil,
              d.object(forKey: AllDayKeys.lon) != nil,
              let tz = d.string(forKey: AllDayKeys.tz)
        else { return nil }
        let lat = d.double(forKey: AllDayKeys.lat)
        let lon = d.double(forKey: AllDayKeys.lon)
        let updated = (d.object(forKey: AllDayKeys.updated) as? Date) ?? .distantPast
        return AllDayAnchor(lat: lat, lon: lon, timeZoneID: tz, updatedAt: updated)
    }

    func saveAllDayAnchor(lat: Double, lon: Double, timeZoneID: String) {
        let d = UserDefaults.standard
        d.set(lat, forKey: AllDayKeys.lat)
        d.set(lon, forKey: AllDayKeys.lon)
        d.set(timeZoneID, forKey: AllDayKeys.tz)
        d.set(Date(), forKey: AllDayKeys.updated)
    }

    func startAllDayScenesIfNeeded() {
        guard !allDayTeardownInProgress else { return }
        guard allDayScenesEnabled, let anchor = loadAllDayAnchor() else { return }
        startAllDayScenes(anchor: anchor)
    }

    func startAllDayScenes(anchor: AllDayAnchor) {
        // Refuse outright while forget-all is in flight. A start accepted here
        // would outlive the teardown with its own task and its own senders, both
        // outside the snapshot forget-all detached before it suspended.
        // Forget-all does NOT restart All-Day afterwards — the user re-enables
        // it, or the next launch's `startAllDayScenesIfNeeded` does.
        guard !allDayTeardownInProgress else { return }
        stopAllDayScenes()
        allDayScenesEnabled = true

        allDayGeneration &+= 1
        let gen = allDayGeneration

        // Low cadence: 5 minutes. (Scene changes are gradual; we avoid bridge spam.)
        let interval: TimeInterval = 5 * 60

        allDayTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if self.allDayGeneration != gen { return }
                await self.tickAllDayScenes(anchor: anchor, generation: gen)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stopAllDayScenes() {
        // Order is load-bearing, and every invalidating step is SYNCHRONOUS.
        //
        // This method cannot become async — it is called from a SwiftUI Toggle
        // setter (SettingsView) that cannot await — while `clearAll()` is async,
        // and `startAllDayScenes` calls us and then IMMEDIATELY starts the next
        // generation. So the sender map is detached (steps 4-5) BEFORE any
        // cleanup is spawned: a retired `clearAll()` landing on a sender the new
        // generation had reused would erase the new generation's pending work,
        // and no generation guard can catch that — `clearAll` bumps epochs on a
        // live sender regardless of which generation queued the closures.
        allDayScenesEnabled = false
        allDayGeneration &+= 1
        allDayTask?.cancel()
        allDayTask = nil
        let retiredSenders = Array(allDayRestSendersByBridge.values)
        allDayRestSendersByBridge.removeAll()
        // Hygiene only. The generation bump above is the correctness boundary;
        // a fresh start now builds new sender instances this cannot reach.
        Task { for sender in retiredSenders { await sender.clearAll() } }
    }

    private func tickAllDayScenes(anchor: AllDayAnchor, generation: Int) async {
        guard allDayGeneration == generation else { return }
        guard !isDemoMode else { return }

        let tz = TimeZone(identifier: anchor.timeZoneID) ?? .current
        let now = Date()
        let output = AllDayCurve.output(at: now, lat: anchor.lat, lon: anchor.lon, timeZone: tz)

        // Apply to every room grouped_light with a smooth transition.
        // M-18 class: route each PUT to the room's OWN bridge, not the first.
        // Packet 6 carries the ROOM ID through as well: it is the key every
        // ownership table uses, and it is what scopes this room's mailbox slot.
        let targets = allRooms.compactMap { room -> (roomID: String, glID: String, bridgeID: String?)? in
            guard let glID = room.groupedLightID else { return nil }
            guard isAllDayBridgeEligible(room.bridgeID) else { return nil }
            // Active playback wins. Skipping happens per exact bridge+room, so
            // one owned room never suppresses its neighbours.
            guard isAllDayWriteAllowed(bridgeID: room.bridgeID, roomID: room.id) else { return nil }
            return (room.id, glID, room.bridgeID)
        }

        for target in targets {
            // One scope PER ROOM, on that room's OWN bridge sender. Latest-wins
            // is per scope, so a later room can no longer erase an earlier one,
            // and `order` (FIFO across scopes) guarantees every one of them is
            // dispatched. Identical room IDs on two bridges land in two
            // different sender instances and never meet.
            //
            // A nil sender means the bridge is tombstoned or forget-all is in
            // flight — skip the room rather than resurrect its mailbox.
            guard let sender = allDayRestSender(for: target.bridgeID) else { continue }
            await sender.enqueue(
                scope: RestScope(roomID: target.roomID, owner: .allDay)
            ) { [weak self] stillCurrent in
                guard let self else { return }
                // All-Day used to discard this probe, so `clear`/`clearAll`
                // could not stop an executing closure. It consumes it now.
                guard await stillCurrent() else { return }
                guard self.allDayGeneration == generation else { return }
                // Re-check at DISPATCH, not only at enqueue: a bridge may have
                // been removed while this sat pending.
                guard self.isAllDayBridgeEligible(target.bridgeID) else { return }
                // Ownership is checked AGAIN, immediately before the write. The
                // enqueue-time check alone is not enough: playback can start
                // while this sits pending, and the whole point of the packet is
                // that All-Day must not overwrite a room someone just claimed.
                guard self.isAllDayWriteAllowed(
                    bridgeID: target.bridgeID, roomID: target.roomID) else { return }
                guard let api = self.hueClient(for: target.bridgeID) else { return }
                // grouped_light supports on/dimming/ct/color; we do CT + brightness here.
                try? await api.setGroupedLightEffect(
                    id: target.glID,
                    on: true,
                    brightness: output.brightnessPercent,
                    xy: nil,
                    mirek: output.mirek,
                    duration: 1200
                )
            }
        }
    }

    // ── Scenes (Stage 2B) ────────────────────────────────────

    /// All scenes across every active bridge, active-first then alphabetical.
    var globalScenes: [GlobalSceneItem] = []

    /// True while a scenes fetch is in flight.
    var isLoadingScenes: Bool = false

    /// True once a scenes fetch (real or demo) has populated `globalScenes`
    /// this session. Until then the widget/watch publisher preserves the
    /// previously stored snapshot: launch publishes fire from room/zone
    /// rebuilds BEFORE scenes have loaded, and an unconditional write would
    /// clobber the stored scenes with an empty array (the "scenes vanished
    /// from every widget" bug). No view reads this — infrastructure only.
    @ObservationIgnored private var hasLoadedScenesOnce = false

    // ── Zones (Stage 2B) ──────────────────────────────────────

    /// All zones across every active bridge, sorted alphabetically.
    /// Populated by loadAll(); updated via rebuildAllZones().
    var allZones: [RoomDisplayItem] = []

    // ── Active Effects (Now Playing) ─────────────────────────────────────────
    // Each room/zone can have an independently applied effect.
    // DashboardView reads this to build the Now Playing bar and per-room stop menu.
    // StudioViewModel is the writer (it mirrors runningEffects here); stops from
    // non-Studio surfaces route through requestNowPlayingStop so the owning
    // engine loop is torn down with the entry, never just the entry alone.

    /// All rooms that currently have an effect applied. Most recent last.
    var activeEffectEntries: [ActiveEffectEntry] = []

    // Convenience computed properties kept for backward compatibility.
    var activeEffectName:       String? { activeEffectEntries.last?.effectName }
    var activeEffectIcon:       String? { activeEffectEntries.last?.effectIcon }
    var activeEffectIsAppDriven: Bool   { activeEffectEntries.last?.isAppDriven ?? false }

    // ── Helpers ───────────────────────────────────────────────────────────────

    /// Records or updates a room's active effect.
    func addActiveEffect(_ entry: ActiveEffectEntry) {
        activeEffectEntries.removeAll { $0.id == entry.id }
        activeEffectEntries.append(entry)
    }

    /// Removes one room's live active-effect entry — the room-scoped
    /// compatibility path (round 4c).
    ///
    /// Live rows are bridge-qualified now, so a bare room id can be ambiguous:
    /// when exactly one live row matches the room it is removed; when several
    /// bridges' rows share the room id NONE is removed (fail closed — a caller
    /// that cannot say which bridge must not guess). Recovered bridge-stored
    /// rows key off their manifest and are structurally out of reach either
    /// way, because stopping a live effect in a room must not silently retire
    /// a different bridge's running animation that happens to share the room
    /// id.
    func removeActiveEffect(roomID: String, context: StopAuditContext = .unattributed) {
        let matches = activeEffectEntries.filter { $0.recovered == nil && $0.roomID == roomID }
        guard matches.count == 1, let only = matches.first else { return }
        activeEffectEntries.removeAll { $0.id == only.id }
        recordStopAudit(context, operation: .nowPlayingRemoved,
                        bridgeID: only.bridgeID, roomID: roomID,
                        cardOrEffectID: only.effectID, outcomeReason: "roomScoped")
    }

    /// Exact live-row removal — the destructive path (round 4c). Removes only
    /// live rows recording exactly this bridge + room; unattributed rows are
    /// retained (never destroy what cannot be attributed), and recovered rows
    /// key off their manifest, structurally out of reach.
    func removeActiveEffect(bridgeID: String, roomID: String,
                            context: StopAuditContext = .unattributed) {
        let beforeCount = activeEffectEntries.count
        activeEffectEntries.removeAll {
            $0.recovered == nil && $0.roomID == roomID && $0.bridgeID == bridgeID
        }
        if activeEffectEntries.count != beforeCount {
            recordStopAudit(context, operation: .nowPlayingRemoved,
                            bridgeID: bridgeID, roomID: roomID)
        }
    }

    /// Removes one entry by its exact presentation key. The only way to clear a
    /// recovered bridge-stored row.
    func removeActiveEffect(id: String, context: StopAuditContext = .unattributed) {
        let beforeCount = activeEffectEntries.count
        activeEffectEntries.removeAll { $0.id == id }
        if activeEffectEntries.count != beforeCount {
            recordStopAudit(context, operation: .nowPlayingRemoved,
                            bridgeID: nil, roomID: nil,
                            cardOrEffectID: id, outcomeReason: "presentationKey")
        }
    }

    /// Removes all active effect entries (Stop All).
    func removeAllActiveEffects(context: StopAuditContext = .unattributed) {
        let beforeCount = activeEffectEntries.count
        activeEffectEntries.removeAll()
        if beforeCount != 0 {
            recordStopAudit(context, operation: .nowPlayingRemoved,
                            bridgeID: nil, roomID: nil,
                            outcomeReason: "allRows count=\(beforeCount)")
        }
    }

    // ── Stop-audit diagnostics (PR #60 stop-isolation) ────────────────────
    //
    // Observational only. DEBUG builds append one event per destructive stop
    // operation so the exact teardown chain — route, identity, outcome — is
    // provable in tests and readable from the device console. Release builds
    // compile the recorder to a no-op; nothing here changes stop ordering,
    // guard outcomes, or return values.

    #if DEBUG
    /// Every recorded stop operation, in commit order. Test-readable.
    @ObservationIgnored private(set) var stopAuditEvents: [StopAuditEvent] = []
    @ObservationIgnored private var stopAuditSequence = 0

    /// Clear the ledger between a test's staging and its assertions.
    func testResetStopAudit() {
        stopAuditEvents.removeAll()
        stopAuditSequence = 0
    }
    #endif

    /// Stable DEBUG identity for audit correlation (runtime param boxes,
    /// Entertainment clients). Identity only — never dereferenced.
    static func stopAuditToken(_ object: AnyObject) -> String {
        String(UInt(bitPattern: ObjectIdentifier(object).hashValue), radix: 16)
    }

    /// Record one stop-audit event. DEBUG-only observation; no-op in Release.
    func recordStopAudit(_ context: StopAuditContext,
                         operation: StopAuditOperation,
                         bridgeID: String?,
                         roomID: String?,
                         cardOrEffectID: String? = nil,
                         runtimeToken: String? = nil,
                         clientID: String? = nil,
                         outcomeReason: String? = nil) {
        #if DEBUG
        stopAuditSequence += 1
        let event = StopAuditEvent(
            sequence: stopAuditSequence,
            timestamp: Date(),
            route: context.route,
            bridgeID: bridgeID,
            roomID: roomID,
            cardOrEffectID: cardOrEffectID ?? context.cardOrEffectID,
            runtimeToken: runtimeToken,
            clientID: clientID,
            operation: operation,
            outcomeReason: outcomeReason)
        stopAuditEvents.append(event)
        debugLog("[StopAudit] #\(event.sequence) \(event.route.rawValue).\(event.operation.rawValue) bridge=\(event.bridgeID ?? "nil") room=\(event.roomID ?? "nil") card=\(event.cardOrEffectID ?? "-") runtime=\(event.runtimeToken ?? "-") client=\(event.clientID ?? "-") reason=\(event.outcomeReason ?? "-")")
        #endif
    }

    /// Exact live-stop target handed to Studio (round 4d). Core-level so the
    /// handler can carry bridge identity without the orchestrator depending
    /// on the UI's row key. `bridgeID == nil` is the room-only compatibility
    /// request: Studio honours it only when exactly one bridge holds the
    /// room id, and fails closed on a collision.
    struct LiveEffectStopTarget: Equatable, Sendable {
        let bridgeID: String?
        let roomID: String
        let turnOffLights: Bool
    }

    /// Studio owns effect teardown (per-light no_effect cleanup, engine loops,
    /// mailbox clears, settle delays) — a bare grouped-light PUT from another
    /// surface would leave the loop running underneath. @ObservationIgnored:
    /// installed once from StudioViewModel.configure, never read by views.
    @ObservationIgnored var studioStopHandler: (@MainActor (LiveEffectStopTarget) async -> Void)?

    /// Studio mirrors the reconciled bridge-stored registry into
    /// `runningEffects` for rooms that resolve. Installed once from
    /// `StudioViewModel.configure` and called by `publishRecovered`.
    /// @ObservationIgnored: infrastructure, never read by views.
    @ObservationIgnored var studioRecoveredHydrationHandler: (@MainActor () -> Void)?

    /// Stop from a non-Studio surface, routing on the ENTRY rather than a bare
    /// room id.
    ///
    /// A recovered bridge-stored row carries an exact manifest identity and
    /// must not go through the roomID handler: a room id cannot say which
    /// bridge, and Studio has no engine to tear down for one of these. A
    /// bridge-attributed live row keeps its bridge identity all the way to
    /// Studio's exact key (round 4d) — with two live rows sharing one room
    /// id, a downgraded room-only request would fail closed and stop
    /// NEITHER. Only an unattributed row falls back to the room-only path.
    func requestNowPlayingStop(_ entry: ActiveEffectEntry, turnOffLights: Bool = true) async {
        if let key = entry.recovered {
            await stopRecoveredBridgeAnimation(key, turnOffLights: turnOffLights)
            return
        }
        if let bridgeID = entry.bridgeID {
            await requestNowPlayingStop(
                bridgeID: bridgeID, roomID: entry.roomID, turnOffLights: turnOffLights)
            return
        }
        await requestNowPlayingStop(roomID: entry.roomID, turnOffLights: turnOffLights)
    }

    /// Exact live stop — this bridge's look in this room, no other's (round
    /// 4d). `turnOffLights: true` is explicit-stop semantics — the room goes
    /// off, matching the Dashboard Stop button. `false` ends the effect but
    /// leaves lights at their current state (Siri's "stop the lights"
    /// promises exactly that).
    func requestNowPlayingStop(bridgeID: String, roomID: String, turnOffLights: Bool = true) async {
        if let studioStopHandler {
            await studioStopHandler(LiveEffectStopTarget(
                bridgeID: bridgeID, roomID: roomID, turnOffLights: turnOffLights))
        } else {
            // Defensive: the handler exists whenever Studio started anything.
            removeActiveEffect(bridgeID: bridgeID, roomID: roomID)
        }
    }

    /// Room-only COMPATIBILITY stop for callers that genuinely cannot name a
    /// bridge. Studio honours it only when exactly one bridge holds the room
    /// id and fails closed on a collision; still the ONLY sanctioned
    /// non-Studio stop path besides the exact overloads above.
    func requestNowPlayingStop(roomID: String, turnOffLights: Bool = true) async {
        if let studioStopHandler {
            await studioStopHandler(LiveEffectStopTarget(
                bridgeID: nil, roomID: roomID, turnOffLights: turnOffLights))
        } else {
            // Defensive: the handler exists whenever Studio started anything.
            removeActiveEffect(roomID: roomID)
        }
    }

    // MARK: - Internal

    /// Active bridge clients.  keyed by BridgeRecord.id
    /// @ObservationIgnored: views read allRooms, never clients directly.
    @ObservationIgnored
    private var clients: [String: BridgeAPIClient] = [:]

    /// Per-bridge pacing gates for bulk/effect writes (M-08/M-14/M-15).
    /// keyed by BridgeRecord.id ("legacy" for the single-bridge fallback).
    @ObservationIgnored
    private var commandGates: [String: BridgeCommandGate] = [:]

    /// Latest bulk-write failure — DashboardView surfaces it as a toast so a
    /// partially applied All Off/automation is never silent (M-08).
    private(set) var lastBulkFailure: BulkWriteFailure?

    /// The pacing gate for a bridge — one per bridge, created lazily.
    func commandGate(for bridgeID: String?) -> BridgeCommandGate {
        let key = bridgeID ?? "legacy"
        if let gate = commandGates[key] { return gate }
        let gate = BridgeCommandGate()
        commandGates[key] = gate
        return gate
    }

    /// Per-bridge REST mailboxes (Composer 2 packet 3), modelled on
    /// `commandGates` above and keyed identically ("legacy" for the
    /// single-bridge fallback).
    ///
    /// Before packet 3 ONE `RestSender` served every Composer room, every
    /// Studio engine loop, and every Studio live-param write across every
    /// bridge — so `clear()` on one room's stop discarded another bridge's
    /// queued frame. Bridge isolation now lives HERE, in the dictionary, and
    /// room/owner isolation lives in `RestScope`. `RestScope` deliberately
    /// carries no bridgeID: duplicating it would let the key and the value
    /// disagree, and a clear() aimed at the wrong sender silently does nothing.
    @ObservationIgnored
    private var restSendersByBridge: [String: RestSender] = [:]

    /// The REST mailbox for a bridge — one per bridge, created lazily.
    private func restSender(for bridgeID: String?) -> RestSender {
        let key = bridgeID ?? "legacy"
        if let sender = restSendersByBridge[key] { return sender }
        let sender = RestSender()
        restSendersByBridge[key] = sender
        return sender
    }

    /// Rooms per bridge — used for merge.  keyed by BridgeRecord.id
    private var roomsByBridge: [String: [RoomDisplayItem]] = [:]

    /// Zones per bridge — parallel to roomsByBridge.
    private var zonesByBridge: [String: [RoomDisplayItem]] = [:]

    /// Family Sharing: guest-access grants keyed by BridgeRecord.id — value
    /// snapshots loaded from SwiftData (never @Model objects). Applied by
    /// applyGuestAccessFilter() inside the rebuilds; UI shells read the
    /// derived guestAccessInfo instead.
    /// @ObservationIgnored: infrastructure, no view reads the dictionary.
    @ObservationIgnored
    private var guestGrantsByBridge: [String: GuestGrantSnapshot] = [:]

    /// Raw lights per bridge — cached from the same fetch `loadAll` already runs so
    /// RoomDetail can render instantly instead of blocking on a fresh `fetchLights()`.
    /// @ObservationIgnored: infrastructure, read one-shot by `cachedLightItems(for:)`.
    @ObservationIgnored
    private var lightsByBridge: [String: [HueLight]] = [:]

    /// SSE tasks per bridge — cancelled when bridge is removed.
    /// @ObservationIgnored: purely infrastructure, no UI reads this.
    @ObservationIgnored
    private var sseTasks: [String: Task<Void, Never>] = [:]

    /// Optimistic-action guard: keyed by grouped_light UUID, value is the deadline
    /// after which SSE may freely overwrite on/brightness for that resource.
    /// Set to now+1.5 s whenever setRoom or setBrightness fires; cleared on expiry.
    /// @ObservationIgnored: infrastructure, never read by views.
    @ObservationIgnored
    private var pendingActionDeadlines: [String: Date] = [:]

    /// Navigation transition guard.
    /// Set to true by signalNavigationStarted() when a NavigationLink push begins.
    /// rebuildAllRooms/Zones buffer their work while this is true and apply it
    /// after the animation window (450 ms) to prevent layout churn mid-transition.
    @ObservationIgnored
    private var isNavigating = false
    @ObservationIgnored
    private var navigationResetTask: Task<Void, Never>?
    @ObservationIgnored
    private var sseRebuildPendingRooms = false
    @ObservationIgnored
    private var sseRebuildPendingZones = false
    /// Trailing throttle for SSE-driven rebuilds: the first event schedules one
    /// rebuild ~150 ms out; events arriving inside that window just accumulate the
    /// dirty flags above, instead of each triggering a full flatMap+sort+reassign
    /// of `allRooms`. Composes with the `isNavigating` deferral (a rebuild that
    /// fires mid-navigation re-buffers via the flags and `navigationResetTask` drains it).
    @ObservationIgnored
    private var sseRebuildTask: Task<Void, Never>?

    /// Continuation for the orchestrator light-event bus.
    /// RoomDetailViewModel subscribes here instead of opening its own SSE connection.
    /// @ObservationIgnored: infrastructure — views never read this directly.
    @ObservationIgnored
    private var lightEventContinuation: AsyncStream<[SSEResourceUpdate]>.Continuation?

    /// Identity of the CURRENT light-event subscriber. A stale stream's
    /// deferred onTermination (room A popped, room B already subscribed) must
    /// not nil out the newer subscriber's continuation — it checks this token
    /// first. @ObservationIgnored: infrastructure.
    @ObservationIgnored
    private var lightEventSubscriberToken = UUID()

    /// Debounced task for widget + watch writes.
    /// Cancelled and re-scheduled on every rebuildAllRooms/Zones call so that
    /// rapid SSE events (e.g. a dimmer ramp) only trigger ONE write 500 ms after
    /// the last mutation instead of a write per event.
    @ObservationIgnored
    private var widgetWriteTask: Task<Void, Never>?

    /// Debounced post-action state refresh.
    /// Any successful state-change (toggle, brightness, scene) schedules a 1.5 s
    /// delayed loadAll() so colors and aggregate brightness always reflect the
    /// bridge's confirmed state — SSE is the primary path but this is a reliable net.
    @ObservationIgnored
    private var pendingStateRefreshTask: Task<Void, Never>?

    /// One shared URL session for all SSE streams.
    /// Created lazily so the cert delegate is retained for the orchestrator's lifetime.
    /// NOT recreated on reconnect — reusing a session avoids resource leaks.
    /// @ObservationIgnored: infrastructure state, not UI state.
    @ObservationIgnored
    private lazy var sseSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest  = .infinity   // required for indefinite SSE
        config.timeoutIntervalForResource = .infinity
        return URLSession(
            configuration: config,
            delegate: BridgePinnedTrustDelegate.shared,
            delegateQueue: nil
        )
    }()

    /// Whether the app-lifecycle observer has been set up (guard against double-register).
    @ObservationIgnored
    private var lifecycleObserverStarted = false

    private let keychain = KeychainManager.shared
    private let log = Logger(subsystem: "com.lightshade.app", category: "UnifiedOrchestrator")

    // MARK: - Init

    init() {}

    // ──────────────────────────────────────────────
    // MARK: - Test Injection (debug only)
    // ──────────────────────────────────────────────

    #if DEBUG
    /// Directly inject pre-built BridgeAPIClient instances — bypasses configure() and Keychain.
    /// Call this from unit tests to provide a TestableAPIClient without touching SwiftData.
    func injectForTesting(clients testClients: [String: BridgeAPIClient]) {
        clients = testClients
    }

    /// Point Entertainment ownership at an isolated store so a suite never
    /// reads or writes the real user's persisted records.
    func injectForTesting(ownership store: EntertainmentSessionOwnership) {
        entertainmentOwnership = store
    }

    func testResolveCompositionGamut(
        for room: RoomDisplayItem,
        api: HueAPIClient
    ) async -> HueColorUtils.Gamut {
        await resolveCompositionGamut(for: room, api: api)
    }

    func testResolveCompositionLightIDs(
        for room: RoomDisplayItem,
        api: HueAPIClient
    ) async -> [String] {
        await resolveCompositionLightIDs(for: room, api: api)
    }

    /// Mirrors decoded-event apply + conditional rebuild from `runSSE` (no line parsing or
    /// light yields). Rebuilds synchronously here — production coalesces via
    /// `scheduleSSERebuild` — so tests can assert `allRooms` immediately after applying.
    @discardableResult
    func testApplySSEEventsAndRebuild(
        _ events: [SSEEvent],
        bridgeID: String
    ) -> (rooms: Bool, zones: Bool) {
        var roomsMutated = false
        var zonesMutated = false

        for event in events {
            let result = applySSEEvent(event, bridgeID: bridgeID)
            if result.rooms { roomsMutated = true }
            if result.zones { zonesMutated = true }
        }

        if roomsMutated { rebuildAllRooms() }
        if zonesMutated { rebuildAllZones() }

        return (rooms: roomsMutated, zones: zonesMutated)
    }

    /// Awaits the deferred entertainment-cleanup task so tests can assert its GET
    /// deterministically (loadAll now schedules cleanup fire-and-forget).
    /// Await an in-flight uncommitted-candidate rollback, so a test can
    /// assert on ownership after it has actually completed.
    func testAwaitEntertainmentRollback() async {
        for task in entertainmentRollbackTasks.values { await task.value }
    }

    /// Is any prepared-but-uncommitted candidate outstanding right now?
    func testHasPendingEntertainmentCandidate() -> Bool {
        !outstandingEntertainmentCandidates.isEmpty
    }

    /// Exactly which candidates are still outstanding.
    func testOutstandingCandidateIDs() -> Set<UUID> {
        Set(outstandingEntertainmentCandidates.keys)
    }

    /// TEST SEAM: stage an outstanding candidate directly.
    ///
    /// A unit test cannot reach `.prepared` through `prepareEntertainment`,
    /// because every client key in this suite is non-hex so the DTLS open
    /// refuses before a socket exists. This stages the state that a real
    /// successful prepare produces, so the rollback contract itself is
    /// testable without a live handshake.
    @discardableResult
    func testStagePendingEntertainmentCandidate(
        client: HueEntertainmentClient,
        plan: EntertainmentTakeoverPlan,
        consent: EntertainmentConsent? = nil
    ) -> PreparedEntertainment {
        let candidate = PreparedEntertainment(client: client, plan: plan, consent: consent)
        outstandingEntertainmentCandidates[candidate.id] = candidate
        return candidate
    }

    /// TEST SEAM: configure each freshly built Entertainment client before
    /// its `startSession` — the hook the production-path takeover tests use
    /// to stub the DTLS transport and script a mid-window session death.
    func injectForTesting(
        entertainmentClientConfigurator: @escaping (HueEntertainmentClient) async -> Void
    ) {
        self.entertainmentClientConfigurator = entertainmentClientConfigurator
    }

    func testAwaitEntertainmentCleanup() async {
        await entertainmentCleanupTask?.value
    }

    /// Seeds the private per-bridge room/zone snapshots so bridge-removal
    /// tests can exercise removeBridge's exact-group teardown without a full
    /// loadAll (round 4d).
    func testSeedBridgeGroups(
        bridgeID: String,
        rooms: [RoomDisplayItem] = [],
        zones: [RoomDisplayItem] = []
    ) {
        roomsByBridge[bridgeID] = rooms
        zonesByBridge[bridgeID] = zones
    }

    /// Seeds the private light→room/zone reverse maps so SSE light-event tests
    /// can exercise applySSEEvent without running a full loadAll.
    func testSeedLightIndex(
        lightIDToRoomID roomMap: [String: String],
        lightIDToZoneID zoneMap: [String: String] = [:]
    ) {
        for (k, v) in roomMap { lightIDToRoomID[k] = v }
        for (k, v) in zoneMap { lightIDToZoneID[k] = v }
    }

    /// Seeds the private per-bridge raw-light cache so SSE cache-freshness
    /// tests can run without a full loadAll. Read back via `cachedRawLights`.
    func testSeedLightCache(bridgeID: String, lights: [HueLight]) {
        lightsByBridge[bridgeID] = lights
    }

    /// Yields updates on the light-event bus exactly as runSSE would, so
    /// subscriber-lifecycle tests run without a live SSE connection.
    func testYieldLightEvents(_ updates: [SSEResourceUpdate]) {
        lightEventContinuation?.yield(updates)
    }
    #endif

    // ──────────────────────────────────────────────
    // MARK: - Demo Mode
    // ──────────────────────────────────────────────

    /// Enter demo mode: loads mock data, marks as demo. No network access.
    func enterDemoMode() {
        isDemoMode = true
        loadDemoData()
        log.info("Demo mode activated")
    }

    /// Exit demo mode and reset all state.
    func exitDemoMode() {
        isDemoMode = false
        allRooms = []
        roomsByBridge = [:]
        connectionStatus = [:]
        clients = [:]
        sseTasks.values.forEach { $0.cancel() }
        sseTasks = [:]
        log.info("Demo mode deactivated")
    }

    private func loadDemoData() {
        allRooms = DemoDataProvider.rooms
        // Populate roomsByBridge for turnAllOff support in demo
        roomsByBridge[DemoDataProvider.bridgeMainID]  = allRooms.filter { $0.bridgeID == DemoDataProvider.bridgeMainID }
        roomsByBridge[DemoDataProvider.bridgeGuestID] = allRooms.filter { $0.bridgeID == DemoDataProvider.bridgeGuestID }
        connectionStatus = DemoDataProvider.connectionStatuses
    }

    // ──────────────────────────────────────────────
    // MARK: - Bridge Registry Management
    // ──────────────────────────────────────────────

    /// Call on app start with the full list from SwiftData.
    /// Handles first-launch legacy credential migration automatically.
    func configure(bridges: [BridgeRecord], modelContext: ModelContext) {
        // MARK: Legacy migration — one-time on first Stage 2A launch
        if bridges.isEmpty {
            let legacyID = UUID().uuidString
            if let (ip, _) = keychain.migrateLegacyCredentials(to: legacyID) {
                let record = BridgeRecord(id: legacyID, name: "My Bridge", host: ip, sortOrder: 0)
                modelContext.insert(record)
                try? modelContext.save()
                log.info("Legacy bridge migrated and saved as BridgeRecord \(legacyID)")
                configure(bridges: [record], modelContext: modelContext)
                return
            }
        }

        // Build/update clients for active bridges (deduplicated by host IP).
        // If the same physical bridge is registered under two BridgeRecord entries
        // (same IP, different UUIDs — common after debug re-pairing), only the first
        // matching record gets a client. This prevents dual SSE streams and duplicate
        // room fetches from the same bridge.
        var seenHostIPs = Set<String>()
        var widgetBridgeCreds: [String: WidgetBridgeCredentials] = [:]
        for bridge in bridges where bridge.isActive {
            guard let creds = try? keychain.loadCredentials(for: bridge.id) else {
                log.warning("No credentials for bridge \(bridge.id) — skipping")
                connectionStatus[bridge.id] = .error("No credentials found")
                continue
            }
            guard seenHostIPs.insert(creds.ip).inserted else {
                log.warning("Bridge \(bridge.id) (\(bridge.name)) skipped — duplicate IP \(creds.ip)")
                continue
            }
             let client = BridgeAPIClient(
                bridgeID:   bridge.id,
                bridgeName: bridge.name,
                ip:         creds.ip,
                token:      creds.token
            )
            wireAuthorizationSignal(client)
            clients[bridge.id] = client
            // This bridge is legitimately registered again — lift any All-Day
            // tombstone `removeBridge` left for it. BOTH registration paths must
            // do this: `configure` is the LAUNCH path (HueHomeApp calls it right
            // before `startAllDayScenesIfNeeded`), so clearing only in
            // `addBridge` would leave a re-paired bridge permanently blocked
            // from All-Day after the next relaunch.
            clearAllDayBridgeTombstone(bridge.id)
            connectionStatus[bridge.id] = .connecting
            widgetBridgeCreds[bridge.id] = WidgetBridgeCredentials(
                bridgeID: bridge.id,
                ip: creds.ip,
                token: creds.token
            )
        }
        // Publish only when the result is trustworthy: an empty map while
        // active bridges exist means every per-bridge Keychain read failed
        // transiently — writing it would wipe the widget/watch credential
        // surface for a paired user.
        let activeBridgeCount = bridges.filter(\.isActive).count
        if widgetBridgeCreds.isEmpty && activeBridgeCount > 0 {
            log.warning("No credentials resolved for \(activeBridgeCount) active bridge(s) — keeping the previous shared credential snapshot")
        } else {
            WidgetDataStore.shared.write(bridges: widgetBridgeCreds)
        }

        // Mark disabled bridges
        for bridge in bridges where !bridge.isActive {
            connectionStatus[bridge.id] = .disabled
        }

        // Drop state keyed by bridge ids that no longer exist (forgotten /
        // re-paired records) and refresh the merged views — rebuild prunes
        // roomsByBridge/zonesByBridge via pruneStaleBridgeSnapshots().
        let liveBridgeIDs = Set(clients.keys)
        for staleID in connectionStatus.keys
        where !liveBridgeIDs.contains(staleID) && !bridges.contains(where: { $0.id == staleID }) {
            connectionStatus.removeValue(forKey: staleID)
        }
        // Family Sharing: snapshot grants BEFORE the rebuilds below, so the
        // first rebuild of the session is already filtered — a guest device
        // must never flash forbidden rooms.
        loadGuestGrants(from: modelContext)
        rebuildAllRooms()
        rebuildAllZones()
    }

    /// Register a newly paired bridge without restarting everything.
    func addBridge(_ record: BridgeRecord) {
        guard let creds = try? keychain.loadCredentials(for: record.id) else { return }
        let client = BridgeAPIClient(
            bridgeID:   record.id,
            bridgeName: record.name,
            ip:         creds.ip,
            token:      creds.token
        )
        wireAuthorizationSignal(client)
        clients[record.id] = client
        // Legitimate re-registration lifts this bridge's All-Day tombstone —
        // see the matching clear in `configure(bridges:modelContext:)`.
        clearAllDayBridgeTombstone(record.id)
        connectionStatus[record.id] = .connecting
        publishWidgetBridgeCredentials()
        // A just-granted bridge coming online can flip the guest-only shell.
        recomputeGuestAccessInfo()
        log.info("Added bridge \(record.id) (\(record.name)) to orchestrator")
    }

    /// Remove a bridge — stops its running effects, cancels SSE, clears
    /// rooms AND zones, wipes credentials + TLS pin.
    func removeBridge(id: String) async {
        // ── All-Day, SYNCHRONOUSLY, before this function's first `await` ──
        //
        // Detaching alone is not enough. While we are suspended in
        // `stopEffectsForRemovedGroups` below, `clients[id]` and this bridge's
        // `allRooms` entries BOTH still exist (they are dropped further down),
        // so a concurrent All-Day tick resolving a sender would lazily create a
        // fresh one for the bridge we are removing — resurrecting exactly the
        // state we just detached. The tombstone makes that structurally
        // impossible, and it OUTLIVES this call: a tick captured before removal
        // can dispatch long afterwards.
        allDayBlockedBridgeKeys.insert(id)
        let retiredAllDaySender = allDayRestSendersByBridge.removeValue(forKey: id)
        // Only THIS bridge's bridge-native claims — another bridge's firmware
        // effect keeps running and keeps its room protected.
        for key in bridgeNativeOwners.keys where key.bridgeKey == id {
            bridgeNativeOwners.removeValue(forKey: key)
        }

        // Stop running effects on this bridge's groups BEFORE dropping the
        // client, so teardown/no_effect PUTs can still reach the bridge.
        // Previously these were orphaned: a dead Now-Playing entry pointed at
        // a removed bridge while its render loop kept erroring against it.
        // Exact identities (round 4d): only THIS bridge's rooms and zones —
        // another bridge's effect on the same room id keeps running.
        let doomedGroups = ((roomsByBridge[id] ?? []) + (zonesByBridge[id] ?? []))
            .map { RemovedGroupIdentity(bridgeID: id, roomID: $0.id) }
        await stopEffectsForRemovedGroups(doomedGroups)
        // Round 4g backstop: whatever the exact stops above could not
        // attribute — this bridge's app-driven engine loop, its live param
        // box, its DTLS session and its owner record — dies with the bridge.
        // Exact key only: another bridge's runtime, session, and owner must
        // survive its neighbour's removal untouched.
        if let runtime = studioEngineRuntimesByBridge.removeValue(forKey: id) {
            runtime.task.cancel()
        }
        if let entClient = studioEntClients.removeValue(forKey: id) {
            await entClient.stopSession()
        }
        studioEntOwnerByBridge.removeValue(forKey: id)
        await retiredAllDaySender?.clearAll()
        sseTasks[id]?.cancel()
        sseTasks.removeValue(forKey: id)
        // Packet 3: invalidate and drop ONLY this bridge's REST mailbox. Every
        // other bridge's queued work must survive — removing one bridge from
        // Bridge Manager may not stop a look running on another.
        //
        // DELIBERATE DIVERGENCE from the `commandGates` precedent above: that
        // dictionary is never cleaned here, so it leaks an idle gate per removed
        // bridge. Senders do not reproduce that — a leaked sender would also
        // hold live epochs for a bridge that no longer exists.
        if let sender = restSendersByBridge.removeValue(forKey: id) {
            let removedScopes = await sender.clearAll()
            // Packet 4: the sender's OWN report — the exact scopes whose
            // pending work was dropped — drives pending-cancellation evidence.
            // Executing-only scopes are invalidated but not returned; their
            // closures report at their probes and those reports die once the
            // session below is deactivated.
            for scope in removedScopes where scope.owner == .composer {
                deactivateComposerTelemetrySession(
                    sessionKey: ComposerTelemetrySessionKey(bridgeKey: id, scope: scope),
                    pendingRemovalReported: true)
            }
        }
        // Sessions with nothing pending at removal time (executing-only or
        // idle, incl. Entertainment compositions on this bridge) still belong
        // to it — deactivate the remainder by EXACT key, filtered on the
        // authoritative bridge identity, never on roomID.
        for sessionKey in Array(composerTelemetrySessions.keys)
        where sessionKey.bridgeKey == id {
            deactivateComposerTelemetrySession(
                sessionKey: sessionKey, pendingRemovalReported: false)
        }
        activeRESTCadenceByBridgeRoom.removeValue(forKey: id)
        // …and forget the Studio owner iff it lived on this bridge (round 4g:
        // the map key IS the bridge, so the removal is exact by construction).
        studioRestScopesByBridge.removeValue(forKey: id)
        clients.removeValue(forKey: id)
        roomsByBridge.removeValue(forKey: id)
        // Zones were never cleared here — and pruneStaleBridgeSnapshots bails
        // when the LAST bridge is removed, so its stale zones lingered forever.
        zonesByBridge.removeValue(forKey: id)
        connectionStatus.removeValue(forKey: id)
        // D-016: drop the TLS pin with the credentials (also unblocks a future
        // re-pair if the bridge's certificate legitimately changed).
        if let creds = try? keychain.loadCredentials(for: id) {
            BridgePinStore.shared.removePins(forHost: creds.ip)
        }
        keychain.deleteCredentials(for: id)
        publishWidgetBridgeCredentials()
        // The grant snapshot for this bridge is dropped here; its SwiftData
        // row is pruned on the next updateGuestGrants/configure pass.
        guestGrantsByBridge.removeValue(forKey: id)
        recomputeGuestAccessInfo()
        rebuildAllRooms()
        rebuildAllZones()
        log.info("Removed bridge \(id)")
    }

    /// The exact identity of a group that is about to disappear (round 4d).
    /// `bridgeID == nil` is a legacy caller that cannot name the bridge —
    /// matched on room id alone, as before the rekey.
    struct RemovedGroupIdentity: Hashable, Sendable {
        let bridgeID: String?
        let roomID: String
    }

    /// Stop any running effects on rooms/zones that are about to disappear
    /// (bridge removal, room/zone delete). Routes each doomed ENTRY through
    /// the sanctioned requestNowPlayingStop path — preserving its exact
    /// identity — so the owning engine loop, transport truth, and Studio's
    /// mirror tear down together. Matching is on the entry's recorded
    /// bridge + room, never on its presentation key: live rows are
    /// bridge-qualified ids now, and comparing bare group ids against them
    /// would match nothing while removing bridge A must also never stop
    /// bridge B's same-room-id look. Recovered bridge-stored rows are not
    /// matched (as before): the bridge's own chain and its manifest evidence
    /// answer to reconciliation, not to a group-list edit. turnOffLights:
    /// false — the group is going away; a goodbye off-PUT is pointless (and
    /// unreachable once a removed bridge's client is dropped).
    /// (Internal, not private, so tests can drive it directly.)
    func stopEffectsForRemovedGroups(_ doomed: [RemovedGroupIdentity]) async {
        func matches(_ entry: ActiveEffectEntry, _ identity: RemovedGroupIdentity) -> Bool {
            guard entry.recovered == nil, entry.roomID == identity.roomID else { return false }
            guard let doomedBridge = identity.bridgeID else { return true }   // legacy caller
            guard let entryBridge = entry.bridgeID else { return true }       // unattributed row
            return entryBridge == doomedBridge
        }
        for entry in activeEffectEntries
        where doomed.contains(where: { matches(entry, $0) }) {
            await requestNowPlayingStop(entry, turnOffLights: false)
        }
    }

    private func publishWidgetBridgeCredentials() {
        var map: [String: WidgetBridgeCredentials] = [:]
        for bridgeID in clients.keys {
            guard let creds = try? keychain.loadCredentials(for: bridgeID) else { continue }
            map[bridgeID] = WidgetBridgeCredentials(bridgeID: bridgeID, ip: creds.ip, token: creds.token)
        }
        // Same trust rule as setupClients: clients exist but zero credentials
        // resolved = transient Keychain failure, not an unpair — don't wipe.
        if map.isEmpty && !clients.isEmpty {
            log.warning("publishWidgetBridgeCredentials: transient empty result with \(self.clients.count) client(s) — keeping previous snapshot")
            return
        }
        WidgetDataStore.shared.write(bridges: map)
    }

    // ──────────────────────────────────────────────
    // MARK: - Instant Startup Cache (Stage 2A Perf)
    // ──────────────────────────────────────────────

    /// Synchronously populate allRooms from SwiftData cache.
    /// Call this BEFORE the first network fetch so the dashboard is
    /// populated immediately on launch — zero flicker, zero spinner.
    func preloadCached(from cachedRooms: [HueLocalRoom]) {
        guard allRooms.isEmpty, !cachedRooms.isEmpty else { return }
        let items = cachedRooms
            .filter { !$0.isHidden && $0.cachedName != nil }
            .sorted { ($0.cachedName ?? "") < ($1.cachedName ?? "") }
            .map { local -> RoomDisplayItem in
                RoomDisplayItem(
                    id:                local.roomID,
                    name:              local.nameOverride ?? local.cachedName ?? local.roomID,
                    archetype:         local.cachedArchetype,
                    isOn:              local.lastIsOn,
                    brightness:        max(1, local.lastBrightness),   // clamp cached 0 to 1
                    groupedLightID:    local.cachedGroupedLightID,
                    lightCount:        local.cachedLightCount,
                    bridgeID:          local.bridgeID,
                    childResourceRefs: []
                )
            }
        // Family Sharing: the cache may hold pre-grant rows (or rows written
        // before a newer, narrower invite was scanned) — filter before first
        // paint. configure() has already loaded the grants (AppRootView calls
        // configure → preloadCached in that order).
        let visible = items.filter {
            GuestAccessPolicy.allows(groupID: $0.id, bridgeID: $0.bridgeID,
                                     grants: guestGrantsByBridge)
        }
        guard !visible.isEmpty else { return }
        allRooms = visible
        // CRITICAL: also populate roomsByBridge so updateRoom() and applySSEEvent()
        // can find rooms during the startup window before loadAll() completes.
        // Without this, toggles and SSE events silently do nothing because both
        // functions iterate/lookup roomsByBridge which would otherwise be empty.
        var byBridge: [String: [RoomDisplayItem]] = [:]
        for item in visible {
            if let bid = item.bridgeID {
                byBridge[bid, default: []].append(item)
            }
        }
        roomsByBridge = byBridge
        log.info("Preloaded \(visible.count) rooms from SwiftData cache (\(byBridge.keys.count) bridge(s))")
    }

    func writeCache(to context: ModelContext) {
        do {
            // Fetch ALL cached rooms in ONE query — avoids the N+1 pattern of one
            // FetchDescriptor per room inside the loop (previously O(N) round-trips).
            let existing = try context.fetch(FetchDescriptor<HueLocalRoom>())
            var existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.roomID, $0) })
            let now = Date()

            for room in allRooms {
                let record = existingByID[room.id] ?? {
                    let r = HueLocalRoom(roomID: room.id, bridgeID: room.bridgeID)
                    context.insert(r)
                    existingByID[room.id] = r
                    return r
                }()
                record.cachedName          = room.name
                record.lastIsOn            = room.isOn
                record.lastBrightness      = room.brightness
                record.cachedLightCount    = room.lightCount
                record.cachedArchetype     = room.archetype
                record.cachedGroupedLightID = room.groupedLightID
                record.bridgeID            = room.bridgeID
                record.updatedAt           = now
            }
            try context.save()
        } catch {
            log.error("writeCache failed: \(error.localizedDescription)")
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Load All (Parallel)
    // ──────────────────────────────────────────────

    /// Fetch rooms from every active bridge concurrently; merge results.
    /// Pass `cacheContext` to auto-write cache on success (nil = skip cache write).
    func loadAll(cacheContext: ModelContext? = nil) async {
        // Demo mode: load mock data synchronously, never hit the network
        if isDemoMode {
            loadDemoData()
            return
        }
        guard !clients.isEmpty else {
            // No bridges configured yet — keep whatever rooms are already showing.
            // Do NOT clear allRooms: isLoading stays false so the dashboard would
            // instantly flip to "no rooms found" even though rooms are on screen.
            log.info("loadAll: no active bridge clients — skipping fetch, keeping cached state")
            return
        }
        // Guard against concurrent calls: two simultaneous loadAll() runs
        // (one from AppRootView, one from DashboardView) can race against an
        // in-flight optimistic toggle and overwrite it with stale bridge data.
        // NOTE: isLoading is ALWAYS set to true below so this guard reliably fires.
        guard !isLoading else {
            log.info("loadAll: concurrent call suppressed (fetch already in flight)")
            return
        }
        // Always set isLoading = true so the concurrent guard above works correctly.
        // Shimmer only shows when allRooms.isEmpty — existing rooms are shown while
        // refreshing in the background, giving immediate feedback without a jarring flash.
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        // D-016 pin acquisition is now per-host inside fetchAndMergeAllBridges so a
        // single offline unpinned bridge no longer stalls every bridge's first fetch
        // up to ~10s. Pinned hosts (the steady state) are a synchronous no-op there.

        // Fetch every bridge (per-bridge pin acquisition happens inside). Stuck
        // entertainment-session cleanup no longer shares this await — it is deferred
        // and throttled below so it never delays first paint or fires per toggle.
        await fetchAndMergeAllBridges()

        // Yield so any pending main-thread interactions (e.g. tab bar) run before
        // large @Observable room list updates from rebuildAllRooms/Zones.
        await Task.yield()

        rebuildAllRooms()
        rebuildAllZones()
        lastLoadedAt = Date()
        // Scenes load lazily (Scenes tab realize), but the widget/watch
        // publisher must not preserve a stale snapshot all session. Fetch
        // once per cold session — detached from this await so the cold-start
        // critical section and the prewarm gate are untouched.
        if !hasLoadedScenesOnce {
            Task { [weak self] in await self?.loadAllScenes() }
        }
        scheduleEntertainmentCleanup()
        refreshEntertainmentAvailability(reason: .periodic)
        // Packet 8: after `rebuildAllRooms()`, so a recovered animation can be
        // matched to the room it is actually running in. Throttled and
        // detached for the same reason the Entertainment cleanup is — this runs
        // on every load, and `scheduleStateRefresh` drives loads every ~1.5 s.
        scheduleBridgeAnimationReconciliation()
        if let ctx = cacheContext {
            let __cacheStart = Date()
            writeCache(to: ctx)
            StartupTimeline.mark("cache.write.done", "\(Int(Date().timeIntervalSince(__cacheStart) * 1000))ms")
        }
    }

    @ObservationIgnored private var entertainmentCleanupTask: Task<Void, Never>?
    @ObservationIgnored private var lastEntertainmentCleanupAt: Date = .distantPast

    /// Stuck entertainment-session cleanup used to run inside loadAll's await (an
    /// `entertainment_configuration` GET per bridge) on every launch/foreground AND
    /// ~1.5s after every toggle via `scheduleStateRefresh` → `loadAll`. Defer it off
    /// the fetch path at low priority and throttle to once per 60s: launch/foreground
    /// coverage is kept (stuck sessions throttle REST, so cleaning then matters), but
    /// the per-toggle GETs are gone.
    private func scheduleEntertainmentCleanup() {
        guard entertainmentCleanupTask == nil,
              Date().timeIntervalSince(lastEntertainmentCleanupAt) > 60 else { return }
        lastEntertainmentCleanupAt = Date()
        entertainmentCleanupTask = Task(priority: .utility) { [weak self] in
            await self?.deactivateStuckEntertainmentSessions()
            self?.entertainmentCleanupTask = nil
        }
    }

    /// Why an availability refresh was asked for (packet 7 follow-up).
    ///
    /// The distinction exists because a throttle that cannot tell the two apart
    /// is a throttle that silently eats the user's own pull-to-refresh: an
    /// automatic load seconds earlier would make the deliberate gesture a no-op,
    /// and the stale "Entertainment Area (Streaming)" verdict it was meant to
    /// clear would survive the gesture that exists to clear it.
    enum EntertainmentAvailabilityRefreshReason {
        case periodic
        case userInitiated
    }

    @ObservationIgnored private var entertainmentAvailabilityRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var lastEntertainmentAvailabilityRefreshAt: Date = .distantPast
    /// A manual refresh that arrived while an automatic pass was already in
    /// flight. Deferred, never dropped: the whole reason `.userInitiated`
    /// exists is that the user's own gesture must not be eaten by a load that
    /// happened to be running.
    @ObservationIgnored private var pendingUserInitiatedRefresh = false

    /// Re-ask every paired bridge what it can stream, so a cached verdict can
    /// go stale on its own instead of only when someone taps the row it
    /// disabled (packet 7 follow-up).
    ///
    /// The defect: `entertainmentAvailability` is cache-only, and nothing but
    /// an explicit Studio transport tap ever warmed those caches. Create an
    /// Entertainment Area in the Hue app while ChromaGlow is running and the
    /// stale "no area" answer stood until a force-quit.
    ///
    /// **GETs ONLY.** This runs unattended — on load, on foreground, on a pull
    /// — so it must never read foreign ownership, raise a prompt, stop a
    /// session, start playback, or move any registry entry. It warms caches and
    /// nothing else; every decision that could interrupt the user stays on the
    /// attended start path.
    func refreshEntertainmentAvailability(reason: EntertainmentAvailabilityRefreshReason) {
        if entertainmentAvailabilityRefreshTask != nil {
            // A pass is already running. An automatic one simply steps aside;
            // a deliberate gesture is REMEMBERED instead, and re-run by the
            // running pass's tail. Returning here would make pull-to-refresh
            // and Studio re-entry silent no-ops for the length of whatever
            // `loadAll` happened to schedule.
            if reason == .userInitiated { pendingUserInitiatedRefresh = true }
            return
        }
        if reason == .periodic,
           Date().timeIntervalSince(lastEntertainmentAvailabilityRefreshAt) <= 60 { return }

        // Snapshot on the main actor: the detached pass must not read
        // `allRooms` while a rebuild is mutating it.
        let rooms = allRooms
        var seenBridges: Set<String> = []
        let targets = rooms.filter { room in
            guard let bridgeID = room.bridgeID else { return false }
            return seenBridges.insert(bridgeID).inserted
        }
        guard !targets.isEmpty else { return }

        // Stamped only once there is real work to do, and only for the reason
        // that reads it. Stamping above the guard burned the throttle on the
        // first-foreground call that fires before `loadAll` has any rooms —
        // which then suppressed the `loadAll` pass that would have warmed
        // every bridge, reopening the stale-verdict window.
        if reason == .periodic { lastEntertainmentAvailabilityRefreshAt = Date() }

        entertainmentAvailabilityRefreshTask = Task(priority: .utility) { [weak self] in
            for room in targets {
                // force: true — the whole point is to notice a change the
                // caches already have a (wrong) answer for.
                await self?.warmEntertainmentCaches(for: room, force: true)
            }
            guard let self else { return }
            // Clear the handle FIRST, so the deferred re-run below is allowed
            // to take the slot. It cannot loop: the flag is cleared before the
            // re-run, and only a fresh `.userInitiated` call can set it again.
            self.entertainmentAvailabilityRefreshTask = nil
            if self.pendingUserInitiatedRefresh {
                self.pendingUserInitiatedRefresh = false
                self.refreshEntertainmentAvailability(reason: .userInitiated)
            }
        }
    }

    #if DEBUG
    /// Wait out any pass a load or a refresh gesture scheduled, so one test's
    /// detached warm cannot still be writing caches while the next asserts on
    /// them. A continuation handshake, not a timed wait.
    ///
    /// Drains to genuine quiescence — no task AND no deferred gesture. Nilling
    /// the slot before awaiting (as this used to) released the seat while the
    /// old pass was still running, so a refresh started during the await raced
    /// the one being awaited.
    func testAwaitEntertainmentAvailabilityRefresh() async {
        while true {
            if let inFlight = entertainmentAvailabilityRefreshTask {
                await inFlight.value
                continue
            }
            if pendingUserInitiatedRefresh {
                // Belt-and-braces: the running pass's tail normally consumes
                // this without ever yielding, so this branch should be
                // unreachable. Draining it here still terminates.
                pendingUserInitiatedRefresh = false
                refreshEntertainmentAvailability(reason: .userInitiated)
                continue
            }
            return
        }
    }
    #endif

    /// Per-bridge REST fetch + merge into `roomsByBridge` / `zonesByBridge` maps.
    /// Used by `loadAll` (may run concurrently with `deactivateStuckEntertainmentSessions`).
    private func fetchAndMergeAllBridges() async {
        // Return type: (bridgeID, rooms?, zones?, roomLightMap, zoneLightMap)
        // nil rooms/zones = fetch failed; keep existing data (stale-while-revalidate).
        await withTaskGroup(
            of: (String, [RoomDisplayItem]?, [RoomDisplayItem]?, [String: String], [String: String], [HueLight]?).self
        ) { group in
            for (bridgeID, client) in clients {
                group.addTask { [client, bridgeID] in
                    let __bridgeStart = Date()
                    do {
                        // D-016 migration: ensure THIS host is pinned before its fetch
                        // (a no-op once pinned — the steady state). Per-host so one offline
                        // unpinned bridge waits only on its own probe instead of blocking
                        // every bridge's first fetch, as the up-front global call used to.
                        // Unpinned + unreachable simply fails the fetch below (fails closed).
                        if let host = try? client.credentials().ip {
                            await BridgePinAcquirer.ensurePins(hosts: [host])
                        }
                        // 4 concurrent requests per bridge — eliminates N+1 pattern.
                        async let roomsFetch   = client.fetchRooms()
                        async let zonesFetch   = client.fetchZones()
                        async let lightsFetch  = client.fetchLights()
                        async let glFetch      = client.fetchGroupedLights()

                        let (rooms, zones, lights, groupedLights) =
                            try await (roomsFetch, zonesFetch, lightsFetch, glFetch)

                        let displayModels = RoomAndZoneDisplayModelBuilder.makeDisplayModels(
                            rooms: rooms,
                            zones: zones,
                            lights: lights,
                            groupedLights: groupedLights,
                            bridgeID: bridgeID
                        )

                        // Capture counts as constants to avoid capturing mutable vars
                        // across an async boundary (Swift 6 concurrency requirement).
                        let roomCount = displayModels.rooms.count
                        let zoneCount = displayModels.zones.count
                        await MainActor.run {
                            self.connectionStatus[bridgeID] = .connected
                            self.log.info("Bridge \(bridgeID): \(roomCount) rooms, \(zoneCount) zones")
                        }
                        StartupTimeline.mark(
                            "loadAll.bridge-fetch.ok",
                            "\(bridgeID) \(Int(Date().timeIntervalSince(__bridgeStart) * 1000))ms rooms=\(roomCount) zones=\(zoneCount)"
                        )
                        return (
                            bridgeID,
                            displayModels.rooms,
                            displayModels.zones,
                            displayModels.roomLightMap,
                            displayModels.zoneLightMap,
                            lights
                        )
                    } catch {
                        // URLError code distinguishes timeout (-1001) vs refused (-1004)
                        // vs no-route (-1009/NSURLErrorNotConnectedToInternet) — the
                        // no-route pattern on a LAN IP is the Local Network permission
                        // denial signature on a fresh install.
                        let code = (error as? URLError)?.code.rawValue ?? (error as NSError).code
                        StartupTimeline.mark(
                            "loadAll.bridge-fetch.FAIL",
                            "\(bridgeID) \(Int(Date().timeIntervalSince(__bridgeStart) * 1000))ms code=\(code) \(error.localizedDescription)"
                        )
                        await MainActor.run {
                            self.connectionStatus[bridgeID] = .error(error.localizedDescription)
                            self.log.error("Bridge \(bridgeID) load failed: \(error.localizedDescription)")
                        }
                        return (bridgeID, nil, nil, [:], [:], nil)  // keep existing data
                    }
                }
            }

            for await (bridgeID, rooms, zones, roomLightMap, zoneLightMap, lights) in group {
                if let rooms {
                    roomsByBridge[bridgeID] = rooms
                    for (k, v) in roomLightMap { lightIDToRoomID[k] = v }
                }
                if let zones {
                    zonesByBridge[bridgeID] = zones
                    for (k, v) in zoneLightMap { lightIDToZoneID[k] = v }
                }
                if let lights { lightsByBridge[bridgeID] = lights }
            }
        }
    }

    /// Lights for a room/zone drawn from the cache `loadAll` already populated.
    /// Lets RoomDetail paint immediately; the view still runs its own `loadLights()`
    /// in the background to refresh. Returns `[]` when there is no usable cache
    /// (demo mode, cache-miss, or a room restored from `preloadCached` whose
    /// `childResourceRefs` are empty) so the caller falls back to today's spinner.
    /// Filter mirrors `RoomDetailViewModel.lightBelongsToRoom`; map/sort mirror
    /// `loadLights` so the background refresh replaces the seed without a visible reorder.
    /// Raw lights cached by the last loadAll for a bridge — nil when never fetched
    /// (pre-loadAll, unknown bridge, demo mode). Capability blocks (effects_v2 etc.)
    /// are topology-stable, so a recent snapshot is authoritative for coverage
    /// resolution; callers gate freshness on `lastLoadedAt`.
    func cachedRawLights(for bridgeID: String?) -> [HueLight]? {
        guard !isDemoMode, let bridgeID else { return nil }
        return lightsByBridge[bridgeID]
    }

    /// Fill the raw-light cache from a fetch outside `fetchAndMergeAllBridges`.
    ///
    /// `warmEntertainmentCaches` has to fetch lights anyway to build the
    /// entertainment→light map; dropping them on the floor would leave
    /// `cachedRoomLightIDs` unanswerable on exactly the bridges whose `loadAll`
    /// failed, so availability could never progress past `.unknown` there.
    /// Only ever fills — never clears — so it cannot race a live load into an
    /// empty state.
    private func seedRawLightCache(bridgeID: String, lights: [HueLight]) {
        guard !isDemoMode, !lights.isEmpty else { return }
        lightsByBridge[bridgeID] = lights
    }

    func cachedLightItems(for room: RoomDisplayItem) -> [LightDisplayItem] {
        guard !isDemoMode,
              let bridgeID = room.bridgeID,
              let all = lightsByBridge[bridgeID],
              !room.childResourceRefs.isEmpty else { return [] }
        let refs = room.childResourceRefs
        return all
            .filter { light in
                refs.contains { ref in
                    (ref.rtype == "light"  && ref.rid == light.id) ||
                    (ref.rtype == "device" && light.owner?.rid == ref.rid)
                }
            }
            .map(LightDisplayItem.init(from:))
            .sorted { $0.name < $1.name }
    }

    // ──────────────────────────────────────────────
    // MARK: - Room Mutations

    /// - Note: Prefer `setRoom(_:isOn:)` — it accepts an explicit desired state,
    ///   avoiding the stale-capture bug where `item.isOn` may have changed since
    ///   the ForEach closure captured it (optimistic updates).
    @available(*, deprecated, renamed: "setRoom(_:isOn:)")
    func toggleRoom(_ item: RoomDisplayItem) {
        // Demo mode: update local state only, no network
        if isDemoMode {
            updateRoom(item.id, isOn: !item.isOn)
            return
        }
        guard let glID = item.groupedLightID,
              let client = clients[item.bridgeID ?? ""] else { return }

        let newState = !item.isOn
        updateRoom(item.id, isOn: newState)

        Task {
            do {
                try await client.setGroupedLight(id: glID, on: newState)
            } catch {
                // Roll back
                updateRoom(item.id, isOn: item.isOn)
                log.error("Toggle failed for room \(item.id): \(error.localizedDescription)")
            }
        }
    }

    /// Explicitly set on-state for a room.
    /// Unlike toggleRoom (which computes !item.isOn from a potentially stale capture),
    /// this takes the desired state directly — used by RoomCard's local @State onToggle.
    func setRoom(_ item: RoomDisplayItem, isOn desiredState: Bool) {
        if isDemoMode {
            updateRoom(item.id, isOn: desiredState)
            return
        }
        guard let glID = item.groupedLightID,
              let client = clients[item.bridgeID ?? ""] else { return }
        updateRoom(item.id, isOn: desiredState)
        // Block SSE from overwriting this optimistic update for 1.5 s
        pendingActionDeadlines[glID] = Date().addingTimeInterval(1.5)
        Task {
            do {
                try await client.setGroupedLight(id: glID, on: desiredState)
                scheduleStateRefresh()   // re-sync colors + confirmed state from bridge
            } catch {
                // Rollback: revert to the opposite of what we tried
                updateRoom(item.id, isOn: !desiredState)
                log.error("setRoom failed for \(item.id): \(error.localizedDescription)")
                showToast("Couldn't reach bridge — \(item.name) reverted")
            }
            // The 1.5s deadline expires on its own. Releasing it at PUT
            // completion re-opened the window for a stale grouped_light SSE
            // echo to flicker the card back (audit L-01).
        }
    }

    func setBrightness(_ brightness: Double, for item: RoomDisplayItem) {
        if isDemoMode {
            let clamped = max(1, min(100, brightness))
            updateRoom(item.id, isOn: true, brightness: clamped)
            return
        }
        guard let glID = item.groupedLightID,
              let client = clients[item.bridgeID ?? ""] else { return }

        let clamped = max(1, min(100, brightness))
        updateRoom(item.id, isOn: true, brightness: clamped)
        // Block SSE from overwriting during the PUT round-trip
        pendingActionDeadlines[glID] = Date().addingTimeInterval(1.5)

        Task {
            do {
                // Single PUT: on=true + brightness together — no "flash" at old brightness
                try await client.setGroupedLightState(id: glID, on: true, brightness: clamped)
                scheduleStateRefresh()   // re-sync colors + confirmed state from bridge
            } catch {
                updateRoom(item.id, isOn: item.isOn, brightness: item.brightness)
                log.error("Brightness failed for room \(item.id): \(error.localizedDescription)")
            }
            // Deadline expires naturally — see setRoom (audit L-01).
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Room & Zone CRUD
    // ──────────────────────────────────────────────

    /// Rename a room (name + archetype) on the bridge and update local state optimistically.
    func renameRoom(_ item: RoomDisplayItem, name: String, archetype: String) async {
        if isDemoMode {
            allRooms = allRooms.map { r in
                var updated = r
                if r.id == item.id { updated.name = name; updated.archetype = archetype }
                return updated
            }
            return
        }
        guard let client = clients[item.bridgeID ?? ""] else { return }
        // Optimistic update
        allRooms = allRooms.map { r in
            var updated = r
            if r.id == item.id { updated.name = name; updated.archetype = archetype }
            return updated
        }
        do {
            try await client.renameRoom(id: item.id, name: name, archetype: archetype)
            showToast("\(name) updated")
        } catch {
            // Rollback — restore the original item
            allRooms = allRooms.map { r in r.id == item.id ? item : r }
            log.error("renameRoom failed: \(error.localizedDescription)")
            showToast("Couldn't update \(item.name)")
        }
    }

    /// Delete a room from the bridge and remove it from the local list immediately.
    func deleteRoom(_ item: RoomDisplayItem) async {
        if isDemoMode {
            withAnimation { allRooms.removeAll { $0.id == item.id } }
            return
        }
        guard let client = clients[item.bridgeID ?? ""] else { return }
        // A running effect on a doomed room would keep PUT-ing to a deleted
        // group and leave a ghost Now-Playing entry. Exact identity (round
        // 4d): the same room id on another bridge is not being deleted.
        await stopEffectsForRemovedGroups(
            [RemovedGroupIdentity(bridgeID: item.bridgeID, roomID: item.id)])
        // Optimistic removal
        withAnimation { allRooms.removeAll { $0.id == item.id } }
        scheduleWidgetWrite()   // deleted groups otherwise linger in widgets
        do {
            try await client.deleteRoom(id: item.id)
            showToast("\(item.name) deleted")
        } catch {
            // Rollback — put it back (append; exact position isn't critical)
            withAnimation { allRooms.append(item) }
            scheduleWidgetWrite()
            log.error("deleteRoom failed: \(error.localizedDescription)")
            showToast("Couldn't delete \(item.name)")
        }
    }

    /// Rename a zone (name + archetype) on the bridge.
    func renameZone(_ item: RoomDisplayItem, name: String, archetype: String) async {
        if isDemoMode {
            allZones = allZones.map { z in
                var updated = z
                if z.id == item.id { updated.name = name; updated.archetype = archetype }
                return updated
            }
            return
        }
        guard let client = clients[item.bridgeID ?? ""] else { return }
        allZones = allZones.map { z in
            var updated = z
            if z.id == item.id { updated.name = name; updated.archetype = archetype }
            return updated
        }
        do {
            try await client.renameZone(id: item.id, name: name, archetype: archetype)
            showToast("\(name) updated")
        } catch {
            allZones = allZones.map { z in z.id == item.id ? item : z }
            log.error("renameZone failed: \(error.localizedDescription)")
            showToast("Couldn't update \(item.name)")
        }
    }

    /// Delete a zone from the bridge and remove it from the local list immediately.
    func deleteZone(_ item: RoomDisplayItem) async {
        if isDemoMode {
            withAnimation { allZones.removeAll { $0.id == item.id } }
            return
        }
        guard let client = clients[item.bridgeID ?? ""] else { return }
        // Exact identity (round 4d): deleting this zone on this bridge may
        // not stop the same zone id's effect on another bridge.
        await stopEffectsForRemovedGroups(
            [RemovedGroupIdentity(bridgeID: item.bridgeID, roomID: item.id)])
        withAnimation { allZones.removeAll { $0.id == item.id } }
        scheduleWidgetWrite()
        do {
            try await client.deleteZone(id: item.id)
            showToast("\(item.name) deleted")
        } catch {
            withAnimation { allZones.append(item) }
            scheduleWidgetWrite()
            log.error("deleteZone failed: \(error.localizedDescription)")
            showToast("Couldn't delete \(item.name)")
        }
    }

    /// Schedules a full state refresh 1.5 s after the last successful state change.
    /// Debounced: rapid interactions (e.g. brightness slider) produce exactly one reload.
    /// This ensures dominant colors and confirmed bridge state always match the cards.
    private func scheduleStateRefresh() {
        pendingStateRefreshTask?.cancel()
        pendingStateRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self else { return }
            await self.loadAll()
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Automation Execution
    // ──────────────────────────────────────────────

    /// Apply a named preset to ALL rooms across ALL bridges.
    /// Called by AppRootView when an automation notification fires (foreground or tap).
    /// Uses the same concurrent per-bridge task group pattern as turnAllOff().
    func applyAutomationPreset(id: String) async {
        guard let preset = AutomationPreset.find(id) else {
            log.warning("applyAutomationPreset: unknown preset '\(id)'")
            return
        }
        log.info("Automation executing preset '\(preset.id)' — brightness=\(preset.brightness) mirek=\(preset.mirek)")

        // Optimistic update so cards reflect the change instantly
        allRooms = allRooms.map { room in
            var r = room
            r.isOn       = true
            r.brightness = preset.brightness
            r.dominantMirek  = preset.mirek
            r.dominantColorX = nil
            r.dominantColorY = nil
            return r
        }
        rebuildAllRooms()

        // M-08: pace per-bridge (~10 cmd/sec) and surface failures — an
        // unpaced N-room burst hit the bridge throttle and silently dropped
        // rooms, leaving them in their old state with no feedback.
        await gatedBulkWrite(operation: "Automation preset") { client, glID in
            try await client.setGroupedLightEffect(
                id:         glID,
                on:         true,
                brightness: preset.brightness,
                xy:         nil,
                mirek:      preset.mirek,
                duration:   400
            )
        }
        log.info("Automation preset '\(preset.id)' applied to \(self.allRooms.count) rooms")
    }

    /// M-08 shared scaffold: one gated grouped_light command per room across
    /// every bridge, failures collected and surfaced — never silent partial
    /// application. All bulk paths (All Off, automation preset/effect) share
    /// this so a fix here fixes all of them.
    private func gatedBulkWrite(
        operation: String,
        perRoom: @escaping @Sendable (_ client: BridgeAPIClient, _ groupedLightID: String) async throws -> Void
    ) async {
        var failedRooms: [String] = []
        await withTaskGroup(of: String?.self) { group in
            for (bridgeID, roomItems) in roomsByBridge {
                guard let client = clients[bridgeID] else { continue }
                // Family Sharing: a granted bridge without the onOff feature
                // is excluded from bulk power writes (All Off, automation
                // fan-outs) — visible is not the same as controllable.
                guard guestFeatures(for: bridgeID).canPower else { continue }
                let gate = commandGate(for: bridgeID)
                for room in roomItems {
                    guard let glID = room.groupedLightID else { continue }
                    let roomName = room.name
                    group.addTask {
                        let error = await gate.send { try await perRoom(client, glID) }
                        return error == nil ? nil : roomName
                    }
                }
            }
            for await failedRoom in group {
                if let failedRoom { failedRooms.append(failedRoom) }
            }
        }
        reportBulkResult(operation: operation, failedRooms: failedRooms)
    }

    /// Surface a partial bulk-write failure to the UI (M-08).
    private func reportBulkResult(operation: String, failedRooms: [String]) {
        guard !failedRooms.isEmpty else { return }
        log.warning("\(operation): \(failedRooms.count) room(s) failed after retry")
        lastBulkFailure = BulkWriteFailure(operation: operation,
                                           roomNames: failedRooms.sorted(),
                                           at: Date())
    }

    // ──────────────────────────────────────────────
    // MARK: - Automation Effect Execution
    // ──────────────────────────────────────────────

    /// Applies a bridge-native HueEffect to every room on every bridge.
    /// Called by AppRootView when an automation notification fires with actionType == "effect".
    func applyAutomationEffect(id effectID: String) async {
        guard let effect = EffectLibrary.all.first(where: { $0.id == effectID }) else {
            log.warning("applyAutomationEffect: unknown effect '\(effectID)'")
            return
        }
        log.info("Automation executing effect '\(effect.name)' on all rooms")

        // M-08: pace per-bridge and surface failures (see gatedBulkWrite).
        let strategy = effect.strategy
        await gatedBulkWrite(operation: "Automation effect") { client, glID in
            switch strategy {
            case .bridgeNative(let effectName):
                // Use grouped_light directly — more reliable than fetching per-light IDs.
                // fetchLightIDsForGroup can return empty on some bridge versions,
                // causing the old code to silently fall back to a brightness-only PUT.
                try await client.setGroupedLightNativeEffect(id: glID, effect: effectName)
            case .oneShot, .gradual:
                try await client.setGroupedLightEffect(
                    id: glID, on: true, brightness: 70,
                    xy: nil, mirek: 300, duration: 400
                )
            case .appDriven:
                // App-driven effects need a foreground Task loop — not possible
                // from a notification. Apply a static warm fallback instead.
                try await client.setGroupedLightEffect(
                    id: glID, on: true, brightness: 70,
                    xy: nil, mirek: nil, duration: 400
                )
            }
        }
        log.info("Automation effect '\(effect.name)' applied to \(self.allRooms.count) rooms")
    }

    // ──────────────────────────────────────────────
    // MARK: - Cross-Bridge "All Off"
    // ──────────────────────────────────────────────

    /// Turn off every light on every active bridge simultaneously.
    func turnAllOff() async {
        // Optimistic update FIRST — cards flip instantly without waiting for network.
        // Each card's .onChange(of: room.isOn) syncs localIsOn when allRooms updates.
        // Family Sharing: rooms on a bridge whose grant lacks onOff keep their
        // state — gatedBulkWrite below skips those bridges, so flipping their
        // cards would show an off that never happened.
        allRooms = allRooms.map { room in
            guard guestFeatures(for: room.bridgeID).canPower else { return room }
            var r = room; r.isOn = false; return r
        }
        // Sync roomsByBridge cache so applySSEEvent sees consistent state
        for bridgeID in roomsByBridge.keys {
            guard guestFeatures(for: bridgeID).canPower,
                  var rooms = roomsByBridge[bridgeID] else { continue }
            rooms = rooms.map { room in var r = room; r.isOn = false; return r }
            roomsByBridge[bridgeID] = rooms
        }
        log.info("All Off: optimistic update applied, firing API calls…")
        // M-08: paced per-bridge with failure surfacing — All Off must reach
        // EVERY room; a silently dropped PUT left lights on with the card off.
        await gatedBulkWrite(operation: "All Off") { client, glID in
            try await client.setGroupedLight(id: glID, on: false)
        }
        log.info("All Off fired across \(self.clients.count) bridge(s)")
    }

    // ──────────────────────────────────────────────
    // MARK: - SSE (one per bridge)
    // ──────────────────────────────────────────────

    /// Returns an AsyncStream of raw SSE light-level updates from the orchestrator's
    /// existing bridge connections. Use this in RoomDetailViewModel instead of opening
    /// a second SSE connection to the same bridge.
    ///
    /// Only one subscriber at a time is supported (iPhone single-window constraint).
    /// Returns nil in demo mode (no SSE). The stream ends when the view disappears
    /// (SwiftUI .task cancellation propagates correctly).
    func subscribeToLightEvents() -> AsyncStream<[SSEResourceUpdate]>? {
        guard !isDemoMode else { return nil }
        // Proactively end any stale stream — its consumer is gone or about to be.
        lightEventContinuation?.finish()
        let token = UUID()
        lightEventSubscriberToken = token
        return AsyncStream { [weak self] continuation in
            self?.lightEventContinuation = continuation
            // onTermination is called from a Sendable context (off main actor).
            // Hop back to MainActor to safely nil the @MainActor-isolated property.
            // Token check: on a rapid room A→B switch, A's deferred termination
            // lands AFTER B subscribed — without it, B's continuation is nil'd
            // and room B never receives another SSE light update.
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.lightEventSubscriberToken == token else { return }
                    self.lightEventContinuation = nil
                }
            }
        }
    }

    /// Start SSE connections for all active clients.
    func startSSE() {
        guard !isDemoMode else { return }  // no SSE in demo mode
        for (bridgeID, client) in clients {
            guard sseTasks[bridgeID] == nil else { continue }
            sseTasks[bridgeID] = Task { [weak self, bridgeID, client] in
                await self?.runSSE(bridgeID: bridgeID, client: client)
            }
        }
        // Register one-time app-lifecycle observer (background → suspend, foreground → resume)
        if !lifecycleObserverStarted {
            lifecycleObserverStarted = true
            observeAppLifecycle()
        }
    }

    func stopSSE() {
        sseTasks.values.forEach { $0.cancel() }
        sseTasks.removeAll()
    }

    /// Call this when a NavigationLink push begins (e.g. room card tap).
    /// Suppresses allRooms/allZones rebuilds for 450 ms so the push animation
    /// is not interrupted by SSE-driven layout recalculations.
    /// Pending SSE rebuilds are flushed immediately after the window expires.
    func signalNavigationStarted() {
        isNavigating = true
        navigationResetTask?.cancel()
        navigationResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)   // matches push animation duration
            guard let self, !Task.isCancelled else { return }
            self.isNavigating = false
            if self.sseRebuildPendingRooms { self.rebuildAllRooms(); self.sseRebuildPendingRooms = false }
            if self.sseRebuildPendingZones { self.rebuildAllZones(); self.sseRebuildPendingZones = false }
        }
    }

    /// Observe UIApplication lifecycle via NotificationCenter to suspend SSE when backgrounded.
    /// Runs indefinitely for the lifetime of the orchestrator — do NOT call more than once.
    private func observeAppLifecycle() {
        Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: UIApplication.didEnterBackgroundNotification) {
                self?.log.info("App backgrounded — suspending SSE to reduce radio/CPU")
                self?.stopSSE()
            }
        }
        Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: UIApplication.willEnterForegroundNotification) {
                self?.log.info("App foregrounded — resuming SSE")
                self?.startSSE()
            }
        }
    }

    /// Run a persistent SSE connection for one bridge.
    ///
    /// Key energy improvements over the previous implementation:
    ///   • Uses shared `sseSession` (no URLSession leak per reconnect)
    ///   • Correct endpoint: /eventstream/clip/v2
    ///   • Lines via `bytes.lines` (no per-byte String allocation)
    ///   • While loop, not recursion (no stack growth on reconnect)
    ///   • Exponential backoff: 5s → 10s → 20s → 40s → 60s (capped)
    private func runSSE(bridgeID: String, client: BridgeAPIClient) async {
        guard let creds = try? client.credentials() else { return }

        // Correct Hue CLIP v2 SSE endpoint
        let urlStr = "https://\(creds.ip)/eventstream/clip/v2"
        guard let url = URL(string: urlStr) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(creds.token, forHTTPHeaderField: "hue-application-key")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        var retryDelay: UInt64 = 5_000_000_000   // 5 s initial
        let maxDelay:   UInt64 = 60_000_000_000  // 60 s ceiling

        while !Task.isCancelled {
            do {
                connectionStatus[bridgeID] = .connecting
                // L-09: the stream URL embeds the bridge LAN IP — log only the bridge id.
                log.info("SSE: Connecting [\(bridgeID, privacy: .public)]")

                let (bytes, _) = try await sseSession.bytes(for: request)
                connectionStatus[bridgeID] = .connected
                StartupTimeline.mark("sse.connected", bridgeID)
                retryDelay = 5_000_000_000   // reset on successful connection

                // ── Line-by-line processing ─────────────────────────────────────────
                // URLSession buffers internally and delivers complete lines.
                // Zero per-byte String allocations; CPU is idle between events.
                for try await line in bytes.lines {
                    guard !Task.isCancelled else { return }
                    guard line.hasPrefix("data:") else { continue }

                    let jsonStr = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    guard !jsonStr.isEmpty, let data = jsonStr.data(using: .utf8) else { continue }

                    if let events = try? Self.sseDecoder.decode([SSEEvent].self, from: data) {
                        var roomsMutated = false
                        var zonesMutated = false
                        for event in events {
                            let result = applySSEEvent(event, bridgeID: bridgeID)
                            if result.rooms { roomsMutated = true }
                            if result.zones { zonesMutated = true }
                        }
                        // Only rebuild what actually changed — avoids a full zone
                        // sort + filter on every brightness slider SSE event. Coalesced
                        // via scheduleSSERebuild so a burst (e.g. a dimmer ramp) collapses
                        // into one rebuild instead of a full allRooms rebuild per line.
                        if roomsMutated || zonesMutated {
                            scheduleSSERebuild(rooms: roomsMutated, zones: zonesMutated)
                        }
                        let rawUpdates = events.flatMap { $0.data }
                        if !rawUpdates.isEmpty {
                            lightEventContinuation?.yield(rawUpdates)
                        }
                    }
                }
                log.info("SSE: Stream ended cleanly on \(bridgeID)")

            } catch {
                guard !Task.isCancelled else { return }
                connectionStatus[bridgeID] = .error(error.localizedDescription)
                log.error("SSE error [\(bridgeID)]: \(error.localizedDescription)")
            }

            log.info("SSE: Reconnecting \(bridgeID) in \(retryDelay / 1_000_000_000)s")
            StartupTimeline.mark("sse.retry", "\(bridgeID) in \(retryDelay / 1_000_000_000)s")
            try? await Task.sleep(nanoseconds: retryDelay)
            retryDelay = min(retryDelay * 2, maxDelay)
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Physical controls (Round 3 G: Tap Dial DJ Mode)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private static let djModeDefaultsKey = "chromaglow.djModeEnabled"

    /// "DJ Mode": rotate a Tap Dial to nudge BPM, button 1 = tap tempo
    /// (long-press = downbeat resync), buttons 2–4 = punch pads on the
    /// room that's currently playing. Events ride the SSE stream the app
    /// already holds open — enabling this costs nothing extra.
    var djModeEnabled: Bool = UserDefaults.standard.bool(forKey: UnifiedOrchestrator.djModeDefaultsKey) {
        didSet {
            UserDefaults.standard.set(djModeEnabled, forKey: Self.djModeDefaultsKey)
            if djModeEnabled { Task { await self.loadButtonControlIDs() } }
        }
    }

    private var controlEngine = ControlMappingEngine()
    /// button resource UUID → physical control_id (1…4), across all bridges.
    private var buttonControlIDs: [String: Int] = [:]

    /// Resolves which physical button each SSE button UUID is. Cheap GET per
    /// bridge; refreshed whenever DJ Mode turns on.
    func loadButtonControlIDs() async {
        var map: [String: Int] = [:]
        for client in clients.values {
            guard let buttons = try? await client.fetchButtons() else { continue }
            for button in buttons {
                // No fallback: a guessed control_id would fire tap tempo (id 1)
                // and re-pin the clock on every press of an unmapped button.
                if let controlID = button.metadata?.control_id {
                    map[button.id] = controlID
                }
            }
        }
        buttonControlIDs = map
    }

    private func executeControlAction(_ action: ControlAction) {
        switch action {
        case .tapTempo:
            BeatClock.shared.tap()
        case .resyncDownbeat:
            BeatClock.shared.resyncDownbeat()
        case .nudgeBPM(let delta):
            let clock = BeatClock.shared
            guard clock.bpm > 0 else { return }
            clock.setBPM(clock.bpm + delta)   // pins — exactly what a twist means
        case .punchBurst(let slot):
            // Perform open: the dial drives the on-screen pads — same room by
            // construction (the mix is tied to that room's render loop), same
            // semantics, same WCAG ≤3 Hz strobe clamp in applyPunch.
            if let mix = activePerformanceMix {
                let pads: [PerformanceMixBox.PunchPad] = [.strobe, .blackout, .whiteBurst]
                mix.engagePunch(pads[max(0, min(pads.count - 1, slot))])
                return
            }
            // Otherwise: bridge-native burst on the most recently started
            // room; idle app = no-op.
            guard let entry = activeEffectEntries.last,
                  let room = allRooms.first(where: { $0.id == entry.id })
            else { return }
            // Fixed two-color pairs per pad slot (amber/white, red/blue, green/magenta).
            let pairs: [(a: CGPoint, b: CGPoint)] = [
                (CGPoint(x: 0.5500, y: 0.4100), CGPoint(x: 0.3127, y: 0.3290)),
                (CGPoint(x: 0.6400, y: 0.3300), CGPoint(x: 0.1500, y: 0.0600)),
                (CGPoint(x: 0.1700, y: 0.7000), CGPoint(x: 0.5400, y: 0.2300)),
            ]
            let pair = pairs[max(0, min(pairs.count - 1, slot))]
            Task {
                await SignalingService(orchestrator: self)
                    .punchBurst(room: room, a: pair.a, b: pair.b, durationMs: 1500)
            }
        case .punchRelease:
            activePerformanceMix?.releasePunch(hostNow: CACurrentMediaTime())
        case .none:
            break
        }
    }

    /// Is the app currently driving this EXACT bridge's group (room or zone)
    /// via a composition — REST (`compositionRuntimes`) or DTLS
    /// (`compositionEntRoomByBridge`)? Used to suppress SSE echo of our own
    /// ~8 Hz per-light PUTs, which would otherwise rebuild the dashboard at
    /// composition frame rate.
    ///
    /// Round 4e: EXACT bridge+room identity, never a room-id set. A room-only
    /// set conflated bridges sharing a room id: bridge A's composition
    /// suppressed bridge B's legitimate SSE, and after A stopped, B's ownership
    /// kept suppressing A. SSE streams are per-bridge, so every caller has the
    /// event's bridge in hand.
    private func isAppDrivenGroup(bridgeID: String, roomID: String) -> Bool {
        if compositionEntRoomByBridge[bridgeID] == roomID { return true }
        return compositionRuntimes[
            CompositionPlaybackKey(bridgeID: bridgeID, roomID: roomID)] != nil
    }

    /// Returns which of rooms/zones were mutated so callers can skip unnecessary rebuilds.
    @discardableResult
    func applySSEEvent(_ event: SSEEvent, bridgeID: String) -> (rooms: Bool, zones: Bool) {
        var roomsMutated = false
        var zonesMutated = false
        for update in event.data {
            switch update.type {

            // ── physical inputs (Round 3 G) ────────────────────────────────────
            case "button":
                guard djModeEnabled, let buttonEvent = update.button?.event,
                      let controlID = buttonControlIDs[update.id] else { continue }
                executeControlAction(
                    controlEngine.handleButton(controlID: controlID, event: buttonEvent))

            case "relative_rotary":
                guard djModeEnabled, let rotation = update.relativeRotary?.rotation else { continue }
                executeControlAction(
                    controlEngine.handleRotary(
                        clockwise: rotation.direction != "counter_clock_wise",
                        steps: rotation.steps ?? 0,
                        now: CACurrentMediaTime()))

            // ── scene (recall status — activation from ANY app/switch) ─────────
            case "scene":
                // Scene active state used to refresh only on loadAllScenes() +
                // the optimistic tap; recalls from the official Hue app or a
                // wall switch left stale ACTIVE badges until a manual refresh.
                guard let active = update.status?.active else { continue }
                if let idx = globalScenes.firstIndex(where: {
                    $0.bridgeSceneID == update.id && $0.bridgeID == bridgeID
                }) {
                    let isActive = active != "inactive"
                    guard globalScenes[idx].isActive != isActive else { continue }
                    var scenes = globalScenes
                    scenes[idx].isActive = isActive
                    if isActive {
                        // One active scene per group — mirror the optimistic
                        // tap's room-mate deactivation.
                        let roomID = scenes[idx].roomID
                        for i in scenes.indices
                        where i != idx && scenes[i].roomID == roomID && scenes[i].bridgeID == bridgeID {
                            scenes[i].isActive = false
                        }
                    }
                    globalScenes = scenes
                }

            // ── grouped_light ──────────────────────────────────────────────────
            case "grouped_light":
                if var rooms = roomsByBridge[bridgeID],
                   let idx = rooms.firstIndex(where: { $0.groupedLightID == update.id }) {
                    // Skip on/brightness if there is a pending optimistic action in flight.
                    // The SSE event pre-dates our PUT; applying it would cause a visible flicker.
                    let isPending = pendingActionDeadlines[update.id].map { Date() < $0 } ?? false
                    // Skip if the app is driving this room ON THIS BRIDGE via a
                    // composition — the echo of our own per-light PUTs would
                    // rebuild the dashboard at frame rate. Exact identity: another
                    // bridge's same-room-id composition must not suppress this one.
                    if !isPending && !isAppDrivenGroup(bridgeID: bridgeID, roomID: rooms[idx].id) {
                        if let on  = update.on?.on              { rooms[idx].isOn       = on  }
                        if let bri = update.dimming?.brightness { rooms[idx].brightness = bri }
                        roomsByBridge[bridgeID] = rooms
                        roomsMutated = true
                    }
                }
                if var zones = zonesByBridge[bridgeID],
                   let idx = zones.firstIndex(where: { $0.groupedLightID == update.id }) {
                    let isPending = pendingActionDeadlines[update.id].map { Date() < $0 } ?? false
                    if !isPending && !isAppDrivenGroup(bridgeID: bridgeID, roomID: zones[idx].id) {
                        if let on  = update.on?.on              { zones[idx].isOn       = on  }
                        if let bri = update.dimming?.brightness { zones[idx].brightness = bri }
                        zonesByBridge[bridgeID] = zones
                        zonesMutated = true
                    }
                }

            // ── light (dominant color + on-state cross-check) ──────────────────
            case "light":
                // Keep the per-light cache (RoomDetail's instant-render seed and
                // Studio's coverage source) live between loadAll fetches — this
                // runs for OFF events too, since the whole point is a truthful
                // seed. Lights in composition-driven rooms/zones are excluded so
                // our own ~8 Hz PUT echoes don't churn the cache. No rebuild is
                // triggered by this write (the cache is read imperatively, never
                // from a View body).
                let cacheRoomDriven = lightIDToRoomID[update.id]
                    .map { isAppDrivenGroup(bridgeID: bridgeID, roomID: $0) } ?? false
                let cacheZoneDriven = lightIDToZoneID[update.id]
                    .map { isAppDrivenGroup(bridgeID: bridgeID, roomID: $0) } ?? false
                if !cacheRoomDriven && !cacheZoneDriven,
                   var cachedLights = lightsByBridge[bridgeID],
                   let cacheIdx = cachedLights.firstIndex(where: { $0.id == update.id }) {
                    cachedLights[cacheIdx] = cachedLights[cacheIdx].applying(sseUpdate: update)
                    lightsByBridge[bridgeID] = cachedLights
                }

                let isNowOn = update.on?.on ?? true
                guard isNowOn else { continue }

                if var rooms = roomsByBridge[bridgeID],
                   let roomID = lightIDToRoomID[update.id],
                   !isAppDrivenGroup(bridgeID: bridgeID, roomID: roomID),
                   let idx = rooms.firstIndex(where: { $0.id == roomID }) {
                    var mutated = false
                    // A light explicitly turning ON proves the room is on even when
                    // the grouped_light event lags or never arrives (scene recall,
                    // per-light control from another app). ON-direction only —
                    // grouped_light events own the off aggregate. Skipped while an
                    // optimistic action on this room's grouped_light is in flight,
                    // so a pre-PUT echo can't flip a card the user just turned off.
                    let glPending = rooms[idx].groupedLightID
                        .flatMap { pendingActionDeadlines[$0] }
                        .map { Date() < $0 } ?? false
                    if update.on?.on == true && !rooms[idx].isOn && !glPending {
                        rooms[idx].isOn = true
                        mutated = true
                    }
                    if let xy = update.color?.xy {
                        rooms[idx].dominantColorX = xy.x
                        rooms[idx].dominantColorY = xy.y
                        rooms[idx].dominantMirek  = nil
                        mutated = true
                    } else if let mirek = update.colorTemp?.mirek {
                        rooms[idx].dominantColorX = nil
                        rooms[idx].dominantColorY = nil
                        rooms[idx].dominantMirek  = mirek
                        mutated = true
                    }
                    if mutated {
                        roomsByBridge[bridgeID] = rooms
                        roomsMutated = true
                    }
                }
                if var zones = zonesByBridge[bridgeID],
                   let zoneID = lightIDToZoneID[update.id],
                   !isAppDrivenGroup(bridgeID: bridgeID, roomID: zoneID),
                   let idx = zones.firstIndex(where: { $0.id == zoneID }) {
                    var mutated = false
                    // Same on-direction cross-check as rooms above.
                    let glPending = zones[idx].groupedLightID
                        .flatMap { pendingActionDeadlines[$0] }
                        .map { Date() < $0 } ?? false
                    if update.on?.on == true && !zones[idx].isOn && !glPending {
                        zones[idx].isOn = true
                        mutated = true
                    }
                    if let xy = update.color?.xy {
                        zones[idx].dominantColorX = xy.x
                        zones[idx].dominantColorY = xy.y
                        zones[idx].dominantMirek  = nil
                        mutated = true
                    } else if let mirek = update.colorTemp?.mirek {
                        zones[idx].dominantColorX = nil
                        zones[idx].dominantColorY = nil
                        zones[idx].dominantMirek  = mirek
                        mutated = true
                    }
                    if mutated {
                        zonesByBridge[bridgeID] = zones
                        zonesMutated = true
                    }
                }

            default:
                continue
            }
        }
        return (rooms: roomsMutated, zones: zonesMutated)
    }

    // ──────────────────────────────────────────────
    // MARK: - Toast
    // ──────────────────────────────────────────────

    /// Shows a brief error toast in the UI, then clears it after 3 seconds.
    func showToast(_ message: String) {
        toastMessage = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if toastMessage == message { toastMessage = nil }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Helpers
    // ──────────────────────────────────────────────

    /// Drop room/zone snapshots keyed by bridge ids with no live client —
    /// stale entries from a forgotten/re-paired bridge (or the SwiftData
    /// preload window) would otherwise merge as duplicate room ids whose
    /// controls silently no-op, with dictionary order picking the winner.
    /// Demo mode keeps its synthetic keys (no clients exist there).
    private func pruneStaleBridgeSnapshots() {
        guard !isDemoMode, !clients.isEmpty else { return }
        let liveBridgeIDs = Set(clients.keys)
        for staleID in roomsByBridge.keys where !liveBridgeIDs.contains(staleID) {
            roomsByBridge.removeValue(forKey: staleID)
        }
        for staleID in zonesByBridge.keys where !liveBridgeIDs.contains(staleID) {
            zonesByBridge.removeValue(forKey: staleID)
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Guest Access (Family Sharing Phase 3)
    // ──────────────────────────────────────────────

    /// Reload grants from SwiftData and re-apply everywhere: rebuilds (rooms/
    /// zones) and the scene list. Call after the invite accept flow writes a
    /// grant (BEFORE addBridge, per the GuestAccessGrantStore ordering
    /// contract) and after Bridge Manager deletes a bridge.
    func updateGuestGrants(from modelContext: ModelContext) {
        loadGuestGrants(from: modelContext)
        rebuildAllRooms()
        rebuildAllZones()
        refilterGlobalScenes()
    }

    /// Snapshot grants without triggering rebuilds — configure() calls this
    /// right before its own rebuilds so the FIRST rebuild is already
    /// filtered (no flash of forbidden rooms on a guest device).
    private func loadGuestGrants(from modelContext: ModelContext) {
        // Prune grants whose bridge record is gone entirely (removed, not
        // merely disabled) — a removed bridge must not leave phantom
        // guest-only state behind.
        let allRecordIDs = Set(
            ((try? modelContext.fetch(FetchDescriptor<BridgeRecord>())) ?? []).map(\.id)
        )
        _ = try? GuestAccessGrantStore.pruneOrphans(
            liveBridgeIDs: allRecordIDs, modelContext: modelContext
        )
        let grants = (try? GuestAccessGrantStore.allGrants(modelContext: modelContext)) ?? []
        guestGrantsByBridge = Dictionary(uniqueKeysWithValues: grants.map {
            ($0.bridgeRecordID, GuestGrantSnapshot(from: $0))
        })
        recomputeGuestAccessInfo()
    }

    /// The feature set the UI must honor for a bridge's content. Unrestricted
    /// for demo mode, nil bridge ids, and the owner's own (un-granted) bridges.
    func guestFeatures(for bridgeID: String?) -> GuestFeatureSet {
        guard !isDemoMode else { return .unrestricted }
        return GuestAccessPolicy.features(for: bridgeID, grants: guestGrantsByBridge)
    }

    /// True when this bridge came from a token invite (a grant exists) —
    /// the surfaces that must always be denied on granted bridges
    /// regardless of features (scene create/delete/rename/copy/move,
    /// automations, scene multi-select editing) key on this.
    func isGuestGrantedBridge(_ bridgeID: String?) -> Bool {
        guard !isDemoMode, let bridgeID else { return false }
        return guestGrantsByBridge[bridgeID] != nil
    }

    /// Route a client's explicit-unauthorized signal (401/403 on the pinned
    /// data plane) to the monitor. MainTabView decides what it means:
    /// cooperative wipe for a granted bridge, re-pair advice for an owned one.
    private func wireAuthorizationSignal(_ client: BridgeAPIClient) {
        let bridgeID = client.bridgeID
        client.onExplicitUnauthorized = {
            Task { @MainActor in
                BridgeAuthorizationMonitor.shared.reportExplicitUnauthorized(bridgeID: bridgeID)
            }
        }
    }

    private func recomputeGuestAccessInfo() {
        let liveIDs = Array(clients.keys)
        let hasAny = liveIDs.contains { guestGrantsByBridge[$0] != nil }
        let info = GuestAccessInfo(
            hasAnyGrant: !isDemoMode && hasAny,
            isGuestOnly: !isDemoMode && GuestAccessPolicy.isGuestOnly(
                liveBridgeIDs: liveIDs, grants: guestGrantsByBridge
            ),
            profileNames: Array(Set(
                liveIDs.compactMap { guestGrantsByBridge[$0]?.profileName }
            )).sorted()
        )
        if guestAccessInfo != info { guestAccessInfo = info }
    }

    /// THE choke point: prune disallowed groups from the per-bridge
    /// dictionaries IN PLACE. Runs inside every rebuild, right after
    /// pruneStaleBridgeSnapshots(), so every write site (loadAll merge,
    /// preload, SSE) and every consumer (allRooms/allZones, updateRoom,
    /// removeBridge's doomed-group list, the widget/watch/Siri publishers,
    /// deep-link resolution) inherits the filter from one place. SSE only
    /// mutates EXISTING entries, so a pruned room cannot be reintroduced
    /// between rebuilds.
    private func applyGuestAccessFilter() {
        guard !isDemoMode, !guestGrantsByBridge.isEmpty else { return }
        for (bridgeID, grant) in guestGrantsByBridge {
            if let rooms = roomsByBridge[bridgeID] {
                let filtered = GuestAccessPolicy.filterGroups(rooms, grant: grant)
                if filtered.count != rooms.count { roomsByBridge[bridgeID] = filtered }
            }
            if let zones = zonesByBridge[bridgeID] {
                let filtered = GuestAccessPolicy.filterGroups(zones, grant: grant)
                if filtered.count != zones.count { zonesByBridge[bridgeID] = filtered }
            }
        }
    }

    /// Scenes populate independently of the room rebuilds (loadAllScenes),
    /// so they get their own filter application — both there and when a
    /// grant arrives mid-session.
    private func refilterGlobalScenes() {
        guard !isDemoMode, !guestGrantsByBridge.isEmpty, !globalScenes.isEmpty else { return }
        let filtered = GuestAccessPolicy.filterScenes(globalScenes, grants: guestGrantsByBridge)
        if filtered.count != globalScenes.count { globalScenes = filtered }
    }

    #if DEBUG
    /// Test seams (mirror injectForTesting): set grants without SwiftData,
    /// and inspect the pruned dictionary — the policy must hold for the
    /// dictionaries, not just the merged arrays, because SSE lookups,
    /// updateRoom, and removeBridge read them directly.
    func testSetGuestGrants(_ grants: [String: GuestGrantSnapshot]) {
        guestGrantsByBridge = grants
        recomputeGuestAccessInfo()
        rebuildAllRooms()
        rebuildAllZones()
        refilterGlobalScenes()
    }

    func testRoomsByBridge() -> [String: [RoomDisplayItem]] { roomsByBridge }
    func testZonesByBridge() -> [String: [RoomDisplayItem]] { zonesByBridge }
    #endif

    /// Coalesce SSE-driven rebuilds behind one trailing ~150 ms task. A resetting
    /// debounce could starve updates during a continuous ramp, so this is a throttle:
    /// the first event fixes the deadline; later events only mark more work pending.
    private func scheduleSSERebuild(rooms: Bool, zones: Bool) {
        if rooms { sseRebuildPendingRooms = true }
        if zones { sseRebuildPendingZones = true }
        guard sseRebuildTask == nil else { return }
        sseRebuildTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self else { return }
            self.sseRebuildTask = nil
            // Clear each flag before rebuilding: if a rebuild re-buffers because
            // isNavigating is true, its flag stays set for navigationResetTask to drain.
            if self.sseRebuildPendingRooms { self.sseRebuildPendingRooms = false; self.rebuildAllRooms() }
            if self.sseRebuildPendingZones { self.sseRebuildPendingZones = false; self.rebuildAllZones() }
        }
    }

    private func rebuildAllRooms() {
        // Buffer during navigation push to avoid layout churn mid-animation.
        guard !isNavigating else {
            sseRebuildPendingRooms = true
            return
        }

        pruneStaleBridgeSnapshots()
        applyGuestAccessFilter()
        allRooms = DashboardDisplayModelBuilder.makeRooms(from: roomsByBridge)
        scheduleWidgetWrite()
    }

    private func rebuildAllZones() {
        guard !isNavigating else {
            sseRebuildPendingZones = true
            return
        }

        pruneStaleBridgeSnapshots()
        applyGuestAccessFilter()
        allZones = DashboardDisplayModelBuilder.makeZones(from: zonesByBridge)
        scheduleWidgetWrite()
    }

    /// Cancel-and-reschedule pattern: only fires ONE write 500 ms after the
    /// last mutation burst, rather than one write per SSE event.
    private func scheduleWidgetWrite() {
        widgetWriteTask?.cancel()
        widgetWriteTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            let roomSnaps = self.allRooms.map { r in
                WidgetRoomSnapshot(
                    id:             r.id,
                    name:           r.name,
                    archetype:      r.archetype,
                    isOn:           r.isOn,
                    brightness:     r.brightness,
                    lightCount:     r.lightCount,
                    groupedLightId: r.groupedLightID,
                    bridgeID:       r.bridgeID,
                    bridgeName:     r.bridgeID.flatMap { self.bridgeName(for: $0) }
                )
            }
            let zoneSnaps = self.allZones.map { z in
                WidgetRoomSnapshot(id: z.id, name: z.name, archetype: z.archetype,
                                   isOn: z.isOn, brightness: z.brightness,
                                   lightCount: z.lightCount, groupedLightId: z.groupedLightID,
                                   bridgeID: z.bridgeID,
                                   bridgeName: z.bridgeID.flatMap { self.bridgeName(for: $0) },
                                   kind: "zone")
            }
            let sceneSnaps = Self.scenesForPublish(
                hasLoaded: self.hasLoadedScenesOnce,
                live:      self.globalScenes,
                stored:    WidgetDataStore.shared.scenes
            )
            let outcome = WidgetDataStore.shared.write(rooms: roomSnaps, zones: zoneSnaps,
                                                       scenes: sceneSnaps,
                                                       reloadOnStructureChange: true)
            // Byte-identical snapshot → the watch push and Siri re-donation
            // are pure waste (SSE quiet-gaps during a bridge-side dynamic
            // scene scheduled them for hours). The store already stamped
            // freshness; nothing downstream can have changed.
            guard outcome.contentChanged else { return }
            WatchSessionManager.shared.push(
                rooms: roomSnaps,
                zones: zoneSnaps,
                scenes: sceneSnaps,
                bridges: WidgetDataStore.shared.bridges
            )
            // Room/zone/scene names just changed — re-donate so Siri's
            // parameterized phrases recognize them (rides this task's
            // existing 500ms debounce).
            HueAppShortcuts.updateAppShortcutParameters()
        }
    }

    /// Publish selection for the widget/watch scene snapshot. Until the first
    /// real scene load of the session, keep what is already stored — the
    /// launch-time publish fires from room/zone rebuilds before scenes exist,
    /// and clobbering the store with `[]` blanked scenes on every widget
    /// surface. After a genuine load the live list is the truth, INCLUDING
    /// an empty one (a user who deleted every scene must see that propagate).
    static func scenesForPublish(
        hasLoaded: Bool,
        live: [GlobalSceneItem],
        stored: [WidgetSceneSnapshot]
    ) -> [WidgetSceneSnapshot] {
        guard hasLoaded else { return stored }
        return live.map { s in
            WidgetSceneSnapshot(id: s.bridgeSceneID, name: s.name,
                                ownerGroupID: s.roomID, bridgeID: s.bridgeID)
        }
    }

    /// Re-derives dominant colors for every room and zone on `bridgeID`
    /// by fetching only /resource/light (cheap — no room/scene data needed).
    ///
    /// Called after scene activation (1.5 s delay) and after individual light
    /// color/CT commits to guarantee glow updates even when SSE is slow.
    func refreshDominantColors(for bridgeID: String) {
        guard let client = clients[bridgeID] else { return }
        Task {
            guard let lights = try? await client.fetchLights() else { return }
            await MainActor.run {
                // ── Rooms ──────────────────────────────────────────
                if var rooms = roomsByBridge[bridgeID] {
                    for idx in rooms.indices {
                        let room = rooms[idx]
                        guard room.isOn else {
                            rooms[idx].dominantColorX = nil
                            rooms[idx].dominantColorY = nil
                            rooms[idx].dominantMirek  = nil
                            continue
                        }
                        // Lights that belong to this room (using the existing reverse map)
                        let roomLights = lights.filter { lightIDToRoomID[$0.id] == room.id }
                        let onLights   = roomLights.filter { $0.on.on }
                        if let best = onLights
                            .filter({ $0.color != nil })
                            .max(by: { ($0.dimming?.brightness ?? 0) < ($1.dimming?.brightness ?? 0) }) {
                            rooms[idx].dominantColorX = best.color!.xy.x
                            rooms[idx].dominantColorY = best.color!.xy.y
                            rooms[idx].dominantMirek  = nil
                        } else if let best = onLights
                            .filter({ $0.color_temperature?.mirek != nil })
                            .max(by: { ($0.dimming?.brightness ?? 0) < ($1.dimming?.brightness ?? 0) }),
                            let mirek = best.color_temperature?.mirek {
                            rooms[idx].dominantColorX = nil
                            rooms[idx].dominantColorY = nil
                            rooms[idx].dominantMirek  = mirek
                        }
                    }
                    roomsByBridge[bridgeID] = rooms
                }
                // ── Zones ──────────────────────────────────────────
                if var zones = zonesByBridge[bridgeID] {
                    for idx in zones.indices {
                        let zone = zones[idx]
                        guard zone.isOn else {
                            zones[idx].dominantColorX = nil
                            zones[idx].dominantColorY = nil
                            zones[idx].dominantMirek  = nil
                            continue
                        }
                        let zoneLights = lights.filter { lightIDToZoneID[$0.id] == zone.id }
                        let onLights   = zoneLights.filter { $0.on.on }
                        if let best = onLights
                            .filter({ $0.color != nil })
                            .max(by: { ($0.dimming?.brightness ?? 0) < ($1.dimming?.brightness ?? 0) }) {
                            zones[idx].dominantColorX = best.color!.xy.x
                            zones[idx].dominantColorY = best.color!.xy.y
                            zones[idx].dominantMirek  = nil
                        } else if let best = onLights
                            .filter({ $0.color_temperature?.mirek != nil })
                            .max(by: { ($0.dimming?.brightness ?? 0) < ($1.dimming?.brightness ?? 0) }),
                            let mirek = best.color_temperature?.mirek {
                            zones[idx].dominantColorX = nil
                            zones[idx].dominantColorY = nil
                            zones[idx].dominantMirek  = mirek
                        }
                    }
                    zonesByBridge[bridgeID] = zones
                }
                rebuildAllRooms()
                rebuildAllZones()
                log.info("refreshDominantColors: done for bridge \(bridgeID)")
            }
        }
    }

    /// Update a room's state and trigger an immediate view re-render.
    ///
    /// Design: directly maps allRooms (the @Observable property SwiftUI watches)
    /// rather than routing through roomsByBridge → rebuildAllRooms → allRooms.
    /// The 3-link chain proved fragile across multiple Swift @Observable versions.
    ///
    /// allRooms = allRooms.map{} is a single full-array assignment — the most
    /// reliable @Observable notification pattern in Swift 5.9+.
    /// roomsByBridge is synced afterward to keep SSE and loadAll consistent.
    private func updateRoom(_ id: String, isOn: Bool? = nil, brightness: Double? = nil) {
        var anyChanged = false
        // Step 1a: direct allRooms update — guaranteed @Observable notification
        allRooms = allRooms.map { room in
            guard room.id == id else { return room }
            var updated = room
            if let on  = isOn       { updated.isOn       = on;  anyChanged = true }
            if let bri = brightness { updated.brightness = bri; anyChanged = true }
            return updated
        }
        // Step 1b: also update allZones — zones use the same RoomDisplayItem type
        allZones = allZones.map { zone in
            guard zone.id == id else { return zone }
            var updated = zone
            if let on  = isOn       { updated.isOn       = on;  anyChanged = true }
            if let bri = brightness { updated.brightness = bri; anyChanged = true }
            return updated
        }
        guard anyChanged else { return }
        // Step 2: sync roomsByBridge cache so SSE events and future loadAll merges
        // see consistent data. This is secondary — allRooms is already correct.
        for bridgeID in roomsByBridge.keys {
            guard var rooms = roomsByBridge[bridgeID],
                  let i = rooms.firstIndex(where: { $0.id == id }) else { continue }
            if let on  = isOn       { rooms[i].isOn       = on  }
            if let bri = brightness { rooms[i].brightness = bri }
            roomsByBridge[bridgeID] = rooms
        }
        // Step 3: sync zonesByBridge cache
        for bridgeID in zonesByBridge.keys {
            guard var zones = zonesByBridge[bridgeID],
                  let i = zones.firstIndex(where: { $0.id == id }) else { continue }
            if let on  = isOn       { zones[i].isOn       = on  }
            if let bri = brightness { zones[i].brightness = bri }
            zonesByBridge[bridgeID] = zones
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Computed Helpers
    // ──────────────────────────────────────────────

    var activeBridgeCount: Int { clients.count }

    var totalDeviceCount: Int { allRooms.reduce(0) { $0 + $1.lightCount } }

    /// Total light count across all rooms — displayed in More tab
    var totalLightCount: Int { allRooms.reduce(0) { $0 + $1.lightCount } }

    // ── Studio Mode — app-driven effect engines ──────────────────────────
    // Called by StudioViewModel for .appDriven cards.
    //
    // Transport selection:
    //   • Entertainment API (DTLS streaming @ 50fps) — for strobe, party, thunderstorm
    //   • REST API fallback (grouped_light @ 1/sec) — when no entertainment config exists
    //   • REST (slow cadence) — for ambient (0.2Hz changes, no need for streaming)
    //
    // Each engine reads its params from the `params` dictionary passed in.
    // Params are user-adjustable sliders; the engine loop polls them each frame.

    /// One app-driven Studio engine runtime per BRIDGE (round 4g). The record
    /// binds the loop task to the live param box and to the exact room that
    /// owns them, keyed by the Entertainment maps' bridge convention
    /// (`bridgeID ?? ""`), for two reasons:
    ///
    ///  1. The old single global slot meant starting a streaming card on
    ///     bridge 2 cancelled bridge 1's render loop — the hardware-confirmed
    ///     "second bridge kills the first bridge's stream" defect. The real
    ///     Hue constraint is one session per bridge, not one per app.
    ///  2. Carrying the owning roomID is what lets a stale stop — one that
    ///     resumes after a newer same-bridge start already took the key —
    ///     recognize that the runtime is no longer the one it was asked to
    ///     stop, and refuse to cancel it.
    private struct StudioEngineRuntime {
        let roomID: String
        let task: Task<Void, Never>
        let paramBox: StudioParamBox
    }
    @ObservationIgnored private var studioEngineRuntimesByBridge: [String: StudioEngineRuntime] = [:]

    /// Entertainment clients keyed by bridgeID — one per concurrent bridge session.
    /// Internal access so StudioViewModel can report transport mode in debug.
    var studioEntClients: [String: HueEntertainmentClient] = [:]

    /// WHICH app-driven look owns each bridge's Entertainment session (packet 7
    /// hardware follow-up).
    ///
    /// The map above answers "is a session installed here?" and nothing more.
    /// This one answers "whose is it?" — the question a composition has to ask
    /// before it may refuse, and the one a handoff has to ask before it may
    /// stop anything. Written only at the four install/teardown sites that
    /// already move `studioEntClients`, so the two can never drift apart.
    @ObservationIgnored private var studioEntOwnerByBridge: [String: StudioEntertainmentOwner] = [:]

    /// Which Entertainment sessions belong to ChromaGlow (packet 7) — the
    /// evidence that lets automatic cleanup stop our own orphaned sessions
    /// without ever touching a third party's. `var` only so a test suite can
    /// swap in an isolated store.
    @ObservationIgnored var entertainmentOwnership: EntertainmentSessionOwnership = .shared

    /// A session opened by `prepareEntertainment` that has not yet been
    /// committed. Exactly one of commit or rollback must claim it.
    @ObservationIgnored private var outstandingEntertainmentCandidates: [UUID: PreparedEntertainment] = [:]
    @ObservationIgnored private var entertainmentRollbackTasks: [UUID: Task<Void, Never>] = [:]

    #if DEBUG
    /// Test-injected hook run on each freshly built Entertainment client
    /// before `startSession` — how the production-path takeover tests stub
    /// the DTLS transport the simulator can never open. nil outside tests.
    @ObservationIgnored private var entertainmentClientConfigurator: ((HueEntertainmentClient) async -> Void)?
    #endif

    /// Consent tokens already acted on. A takeover authorizes exactly one
    /// start; without this a replayed confirmation could start a second time.
    @ObservationIgnored var consumedEntertainmentConsents: Set<UUID> = []

    /// Studio-handoff confirmations already acted on (packet 7 hardware
    /// follow-up).
    ///
    /// Deliberately its OWN ledger rather than a reuse of the set above. That
    /// one records permission to replace ANOTHER app's session; this one
    /// records permission to stop one of OUR OWN looks. Sharing a set would let
    /// one kind of answer spend the other's token — a "Take Over" tapped once
    /// silently satisfying a "Switch" that was never asked, or the reverse.
    @ObservationIgnored var consumedStudioHandoffRequests: Set<UUID> = []

    /// Foreign-takeover REQUESTS already acted on (hardware convergence A).
    ///
    /// A THIRD ledger, and it does not overlap either of the two above.
    /// `consumedEntertainmentConsents` records that a consent token bought a
    /// session — it is spent late, at the moment a session actually opens, so
    /// that a legitimate replay is not rejected before it can start. This one
    /// records that a specific "Take Over" tap was acted on at all, and is
    /// spent before the first await: `resolveForeignTakeover` suspends several
    /// times before reaching the stop, so two confirmations in flight together
    /// would otherwise both pass and both send one, the second landing on
    /// whatever had started in between.
    ///
    /// Kept apart from `consumedStudioHandoffRequests` for the reason that one
    /// already gives: a token spendable by the wrong question is not a token.
    @ObservationIgnored var consumedForeignTakeoverRequests: Set<UUID> = []

    /// Which Studio scope owns REST on each bridge (packet 3; round 4g:
    /// per-bridge). Keyed by the SENDER key convention (`bridgeID ?? "legacy"`)
    /// because these values are cleared against `restSender(for:)` and read by
    /// the All-Day suppression predicate, both of which spell bridgeless that
    /// way. A same-bridge room A → room B replacement must clear room A's
    /// scope (or its epoch stays valid and its queued batches keep writing
    /// over room B), but another bridge's Studio look keeps its scope and
    /// keeps running.
    private var studioRestScopesByBridge: [String: RestScope] = [:]

    /// Studio live-param writes (the customization-wiring debounced sends)
    /// share the room's Studio mailbox slot: repeated writes to the same
    /// endpoint where only the newest value matters — a slider scrub can never
    /// stack PUTs behind stale frames, and the stop/handoff clear()s also drop
    /// any pending param write before a new owner starts.
    ///
    /// Packet 3: scoped. The write lands on the ROOM's bridge sender under
    /// `.studio`, so it can no longer be dropped by another room's stop, and a
    /// Composer look on the same room keeps its own independent slot.
    /// Callers never construct a `RestScope` — that is this method's job.
    func enqueueStudioRestWrite(
        roomID: String,
        bridgeID: String?,
        _ work: @escaping RestSender.Work
    ) async {
        let scope = RestScope(roomID: roomID, owner: .studio)
        await restSender(for: bridgeID).enqueue(scope: scope, work)
    }

    /// Clear ONE bridge's recorded Studio scope on the sender that holds it,
    /// and forget it. Used by `startStudioMode` (before recording the new
    /// owner) and by the bridge-removal paths. Round 4g: per-bridge — clearing
    /// bridge A's owner must not touch bridge B's.
    private func clearStudioRestScope(bridgeKey: String) async {
        guard let scope = studioRestScopesByBridge[bridgeKey] else { return }
        await restSender(for: bridgeKey).clear(scope: scope)
        studioRestScopesByBridge.removeValue(forKey: bridgeKey)
    }
    // `studioGeneration` was deleted in packet 3. It was incremented on every
    // Studio start/stop and NEVER read — dead state that looked like a working
    // staleness guard. Studio staleness is now carried by the REST scope epoch
    // (`RestScope(.studio)`), which enqueued closures actually consult, and by
    // engine-runtime task cancellation for the engine loops.

    /// Per-EXACT-playback composition generation counters (round 4e: keyed by
    /// bridge+room, never bare roomID — a stop may only invalidate its own
    /// bridge's generation).
    private var compositionGenerations: [CompositionPlaybackKey: Int] = [:]
    /// Shared composition scheduler state (exact bridge+room runtimes, single
    /// bridge-fair ticker). Two bridges sharing one room id are two runtimes.
    private var compositionRuntimes: [CompositionPlaybackKey: CompositionRuntime] = [:]
    private var compositionOrder: [CompositionPlaybackKey] = []
    private var compositionSchedulerTask: Task<Void, Never>?

    /// Round 3 (C): the live Perform mix. Non-nil while PerformanceView is
    /// up. Keyed to its composition by deckA IDENTITY — the render loop
    /// whose paramBox === deckA blends through CompositionMixer; every
    /// other room renders normally. One property, both transports.
    var activePerformanceMix: PerformanceMixBox? = nil

    private enum CompositionSchedulerProfile {
        case balanced
        case ultraResponsive
    }
    /// Default profile tuned for low-power smoothness; keep ultra for future A/B.
    private let compositionSchedulerProfile: CompositionSchedulerProfile = .balanced

    private struct CompositionRuntime {
        let roomID: String
        let roomName: String
        /// **Entertainment-oriented bridge identity.** The `?? ""`-coerced
        /// nonoptional the Entertainment bookkeeping compares against — the
        /// `compositionRuntimes.values.contains { $0.bridgeID == … }` gates
        /// take a plain `String` bridge key, so this stays nonoptional for them.
        ///
        /// Recorded at start rather than re-derived from `allRooms` at read
        /// time: the snapshot can go stale mid-composition, and those gates must
        /// not mistake a stale lookup for "no composition on this bridge".
        /// `api` cannot answer this — it is a `HueAPIClient`, and only the
        /// `BridgeAPIClient` subclass carries a bridge identity.
        ///
        /// **Do not route the REST mailbox through this.** For a bridgeless room
        /// it is `""`, which is not nil — see `restBridgeIdentity`.
        let bridgeID: String
        /// **Composer REST sender identity.** The room's ORIGINAL optional
        /// bridge identity, captured before `startCompositionMode`'s `?? ""`
        /// coercion (packet 4). This is what every Composer mailbox path passes
        /// to `restSender(for:)`, which normalizes nil → the `"legacy"` key.
        ///
        /// The distinction is the whole point: `""` is NOT nil, so `?? "legacy"`
        /// never fired for it and a bridgeless room got its own private `""`
        /// sender while All-Day and Studio shared `"legacy"` — two mailboxes for
        /// one conceptual bridge.
        ///
        /// Enqueue (`runCompositionScheduler`), clear (`stopCompositionMode`),
        /// and any telemetry identity built on top of them must ALL key on this
        /// value. They move together or not at all: if enqueue used this while
        /// clear still used `bridgeID`, `clear(scope:)` would target a different
        /// actor and packet 3's cooperative cancellation would silently stop
        /// working for bridgeless rooms.
        let restBridgeIdentity: String?
        let api: HueAPIClient
        let groupedLightID: String
        /// Individual light IDs for per-light REST mode.
        /// When non-empty, each light gets its own color (cascade/wave visible).
        /// Fallback to grouped_light if empty.
        let lightIDs: [String]
        /// Round 3 (F): non-nil when the room has a gradient strip — its
        /// channels render ALONG the strip via gradient.points. nil keeps
        /// the flat per-light path byte-identical to before.
        var gradientMap: GradientChannelMap? = nil
        let paramBox: CompositionParamBox
        let tier: CompositionTier
        let gamut: HueColorUtils.Gamut
        let startTime: CFAbsoluteTime
        let generation: Int
        var nextDueAt: CFAbsoluteTime
        var wasInteracting: Bool
        var pendingSettle: Bool
        var interactionBurstUntil: CFAbsoluteTime?
        var sendCount: Int
        var lastSentX: Double?
        var lastSentY: Double?
        var lastSentBri: Double?
        var lastSentAt: CFAbsoluteTime?
    }

    // ── Composer telemetry (packet 4) ────────────────────────────
    //
    // The old enqueue-time telemetry (CompositionTelemetry / activeRESTCadence /
    // activeRESTCadenceByRoom) was deleted rather than repaired: its lag was
    // structurally 0.0, its "sends" counted enqueues the mailbox may discard,
    // and its global cadence was clobbered by whichever room recorded last.
    // What replaced it is completion-based: the pure CompositionSendLedger
    // records what the sender and the closures PROVED happened; this type owns
    // only session identity and publication.

    /// Published cadence, keyed by bridgeKey → roomID. Bridge-scoped so two
    /// rooms with the same ID on different bridges can never read each other's
    /// number; read through `activeRESTCadence(roomID:bridgeID:)` only.
    private(set) var activeRESTCadenceByBridgeRoom: [String: [String: Double]] = [:]

    /// The seconds-per-update the tray may show for this room, or nil for the
    /// honest no-data state ("updates a little slower"). `bridgeID` is the
    /// room's ORIGINAL optional identity; nil normalizes to "legacy" exactly
    /// like `restSender(for:)`, so the read key always matches the write key.
    func activeRESTCadence(roomID: String, bridgeID: String?) -> Double? {
        activeRESTCadenceByBridgeRoom[bridgeID ?? "legacy"]?[roomID]
    }

    /// Exact identity of one Composer telemetry session: the SAME bridge key
    /// the mailbox uses plus the Composer scope. Never keyed by roomID alone —
    /// identical room IDs on different bridges are different sessions.
    private struct ComposerTelemetrySessionKey: Hashable {
        let bridgeKey: String
        let scope: RestScope
    }

    /// Retained per-session value. `isRESTActive` marks the sessions whose
    /// composition actually installed a REST runtime — only those get the
    /// per-scheduler-pass publication refresh. Entertainment and bridge-stored
    /// sessions keep telemetry identity (stop must find them) but stay false.
    private struct ComposerTelemetrySession {
        let generation: Int
        var isRESTActive: Bool
    }

    /// Completion-based event book. Pure value type — every timestamp it sees
    /// comes from `compositionTelemetryNow`.
    @ObservationIgnored
    private var compositionSendLedger = CompositionSendLedger()

    /// The active telemetry sessions, retained INDEPENDENTLY of
    /// `compositionRuntimes` so stop and teardown work when the transport is
    /// Entertainment or bridge-stored and no REST runtime ever existed.
    @ObservationIgnored
    private var composerTelemetrySessions: [ComposerTelemetrySessionKey: ComposerTelemetrySession] = [:]

    /// The one not-yet-started token per (bridgeKey, scope). Installed BEFORE
    /// awaiting `enqueue` (so a fast dispatch can consume it via the started
    /// report), removed only by an equality-checked started/terminal report,
    /// and terminalized only on RestSender's own evidence.
    @ObservationIgnored
    private var composerPendingTokens: [ComposerTelemetrySessionKey: CompositionSendLedger.Token] = [:]

    /// Monotonic token mint. Uniqueness only — ordering claims come from the
    /// ledger's state machine, never from comparing sequences.
    @ObservationIgnored
    private var composerTokenSequence: UInt64 = 0

    // ── Rolling-subset rotation (packet 5) ───────────────────────
    //
    // A room with more eligible REST operations than one sweep may dispatch
    // is served in rotation instead of being truncated. The cursor walks the
    // eligible list in NON-WRAPPING partitions, so each rotation is an exact
    // ordered partition of [0, n) and no sweep straddles a boundary.

    private struct CompositionRotationState {
        let generation: Int
        /// Index of the next eligible operation to dispatch; 0 ≤ cursor < n.
        var cursor: Int
        /// n, captured when the state was created. Immutable for the session's
        /// life because `CompositionRuntime.lightIDs` is a `let` and
        /// `gradientMap` is assigned once — a mismatch means something broke
        /// that invariant, and the rotation resets rather than misbehaving.
        var eligibleOperationCount: Int
        /// Any failure seen in the rotation currently in progress. Cleared at
        /// each boundary.
        var currentRotationHadFailure: Bool
        /// Set ONCE, at the first boundary reached with zero failures anywhere
        /// in that rotation, and sticky thereafter.
        ///
        /// A rotation that merely ATTEMPTED every operation is not a rotation
        /// that delivered to every light: completion-only bookkeeping (packet
        /// 4) correctly withholds `lastSentX/Y/Bri` for a partially failed
        /// sweep, and if the delta gate were told "rotation complete" anyway
        /// it could quiesce a static look with a light still stranded. So the
        /// gate consults THIS, not the cursor alone.
        var hasCompletedInitialSuccessfulRotation: Bool
    }

    /// Rotation state, keyed EXACTLY like the telemetry sessions — never by
    /// roomID alone, so two rooms sharing an ID on different bridges hold two
    /// independent states at the same time. Internal scheduler state that no
    /// view reads, hence observation-ignored (contrast the degradation store).
    @ObservationIgnored
    private var compositionRotationStates: [ComposerTelemetrySessionKey: CompositionRotationState] = [:]

    // ── Transport degradation (packet 5) ─────────────────────────

    /// Private mutable state behind `CompositionDegradationSnapshot`. Fallback
    /// cause and rolling delivery are INDEPENDENT fields: writers set only
    /// their own, so neither can erase the other's truth.
    private struct CompositionDegradationState: Equatable {
        let generation: Int
        var fallbackReason: CompositionFallbackReason?
        var largeRoomEligibleOperations: Int?

        var snapshot: CompositionDegradationSnapshot {
            .init(fallbackReason: fallbackReason,
                  largeRoomEligibleOperations: largeRoomEligibleOperations)
        }
    }

    /// Deliberately NOT `@ObservationIgnored`.
    ///
    /// The tray's status sentence is a product requirement of this packet, so
    /// a degradation-only change has to invalidate `MixerTrayView` on its own.
    /// An ignored store read through an accessor would leave the sentence
    /// stale until some unrelated transport or cadence mutation happened to
    /// refresh the view. Reading this property inside
    /// `compositionDegradation(roomID:bridgeID:)` from a view body is what
    /// registers the Observation dependency.
    ///
    /// Trade-off accepted: invalidation is whole-property, so a write for one
    /// bridge re-evaluates a view reading another. Degradation writes happen
    /// at start, fallback and stop only — and the VALUE each key returns is
    /// still exactly its own.
    private var compositionDegradationStates: [ComposerTelemetrySessionKey: CompositionDegradationState] = [:]

    /// The ONE clock every telemetry event and publication refresh samples.
    /// A seam, not a convenience: tests inject a deterministic clock here, so
    /// cadence expiry is provable without a single wall-clock sleep.
    @ObservationIgnored
    private var compositionTelemetryNow: () -> CFAbsoluteTime = { CFAbsoluteTimeGetCurrent() }
    /// Per-bridge entertainment tasks — allows concurrent sessions across multiple bridges.
    private var compositionEntTasks: [String: Task<Void, Never>] = [:]
    /// Per-bridge active room IDs — guards against starting a second session on the same bridge.
    private var compositionEntRoomByBridge: [String: String] = [:]
    /// Per-bridge param boxes for mic-demand tracking. Weak so they don't prevent dealloc.
    private var compositionEntParamBoxes: [String: CompositionParamBox] = [:]

    /// Which room's composition currently owns the DTLS session on this bridge.
    /// The ownership maps are private because only this type may mutate them, but
    /// Studio has to be able to *ask* — without this, a Studio card tap could not
    /// tell "nobody is streaming here" from "a composition is", and the only way
    /// to find out was to tear the session down and see what broke.
    func compositionOwningEntertainment(onBridge bridgeID: String) -> String? {
        compositionEntRoomByBridge[bridgeID]
    }

    /// Which app-driven Studio look owns this bridge's Entertainment session,
    /// if any (packet 7 hardware follow-up).
    ///
    /// BOTH halves are required, and the client is the authority. A record that
    /// outlived its session must be inert evidence, not authority to stop
    /// something: answering from the record alone would let a stale entry send
    /// the user a "stop Strobe and start this?" question about a look that
    /// finished minutes ago, and then a stop nobody asked for.
    ///
    /// Returns nil for a Packet 8 recovered bridge-stored animation BY
    /// CONSTRUCTION — those run on the bridge's own firmware and never install
    /// a `studioEntClients` entry, so they can never be mistaken for a live
    /// DTLS owner here.
    func studioOwningEntertainment(onBridge bridgeID: String) -> StudioEntertainmentOwner? {
        guard studioEntClients[bridgeID] != nil else { return nil }
        return studioEntOwnerByBridge[bridgeID]
    }

    /// Whether a composition may take the Entertainment session on this bridge.
    ///
    /// Both conjuncts are scoped to the target bridge. The second one used to be
    /// `compositionRuntimes.isEmpty` — a *global* test, so a single REST
    /// composition anywhere silently demoted every later start on every bridge
    /// to REST. Bridge A's state may not decide bridge B's transport.
    ///
    /// The same-bridge REST block is deliberate and stays: a REST composition on
    /// this bridge may be writing to lights that also sit inside the entertainment
    /// area we are about to stream into, and DTLS and REST would fight over them.
    /// Resolving that precisely needs area membership, which this packet does not
    /// have yet — so we refuse rather than guess. (Composer 2 packet 1b revisits
    /// this as overlap-based arbitration.)
    private func canAcquireEntertainment(onBridge bridgeID: String) -> Bool {
        guard compositionEntRoomByBridge[bridgeID] == nil else { return false }
        return !compositionRuntimes.values.contains { $0.bridgeID == bridgeID }
    }

    #if DEBUG
    // Ownership seams (mirror `injectForTesting`): the maps are private because
    // only this type may mutate them in production, but the per-bridge gate is
    // exactly the kind of rule that regresses silently — so tests get a way to
    // stage ownership without a live bridge or a real DTLS handshake.

    /// Stage a REST composition on a bridge, as `startCompositionMode` would.
    ///
    /// `bridgeID` is optional so a test can stage a room with NO bridge — the
    /// case that exposed the `""`-vs-`"legacy"` mailbox split (packet 4). It
    /// reproduces production exactly: the nonoptional field takes `?? ""`, the
    /// mailbox identity keeps the original optional. Existing callers passing a
    /// plain `String` still compile.
    /// `lightIDs` defaults to empty (the grouped-fallback shape existing
    /// callers stage); pass a real list to arm the packet-5 rotation with a
    /// realistic eligible-operation count.
    func testStageRESTComposition(
        roomID: String, bridgeID: String?, api: HueAPIClient, generation: Int = 1,
        lightIDs: [String] = []
    ) {
        let playbackKey = CompositionPlaybackKey(bridgeID: bridgeID, roomID: roomID)
        setCompositionTransportClaim(.rest, for: playbackKey)
        compositionRuntimes[playbackKey] = CompositionRuntime(
            roomID: roomID,
            roomName: roomID,
            bridgeID: bridgeID ?? "",
            restBridgeIdentity: bridgeID,
            api: api,
            groupedLightID: "grouped-\(roomID)",
            lightIDs: lightIDs,
            paramBox: CompositionParamBox(
                palette: PaletteConfig(), motion: MotionConfig(),
                envelope: EnvelopeConfig(), reaction: ReactionConfig()
            ),
            tier: .runtimeOnly,
            gamut: .c,
            startTime: CFAbsoluteTimeGetCurrent(),
            generation: generation,
            nextDueAt: CFAbsoluteTimeGetCurrent(),
            wasInteracting: false,
            pendingSettle: false,
            interactionBurstUntil: nil,
            sendCount: 0,
            lastSentX: nil,
            lastSentY: nil,
            lastSentBri: nil,
            lastSentAt: nil
        )
        if !compositionOrder.contains(playbackKey) { compositionOrder.append(playbackKey) }
        // Packet 4: production start also opens the telemetry session and
        // marks it REST-active once the runtime is installed — stage the same.
        compositionGenerations[playbackKey] = generation
        let sessionKey = ComposerTelemetrySessionKey(
            bridgeKey: bridgeID ?? "legacy",
            scope: RestScope(roomID: roomID, owner: .composer))
        beginComposerTelemetrySession(sessionKey: sessionKey, generation: generation)
        markComposerTelemetrySessionRESTActive(
            sessionKey: sessionKey, eligibleOperations: lightIDs.count)
    }

    /// Run the PRODUCTION startup prime for a staged room, as issued by a
    /// specific generation — the seam behind the stale-prime and thrown-prime
    /// guards. Same method `startCompositionMode` calls; no parallel logic.
    func testPerformCompositionPrime(room: RoomDisplayItem, generation: Int) async {
        guard let api = hueClient(for: room.bridgeID),
              let groupedLightID = room.groupedLightID else { return }
        await performCompositionPrime(
            room: room, api: api, groupedLightID: groupedLightID,
            paramBox: CompositionParamBox(
                palette: PaletteConfig(), motion: MotionConfig(),
                envelope: EnvelopeConfig(), reaction: ReactionConfig()
            ),
            gamut: .c,
            nextGeneration: generation)
    }

    /// Stage composition ownership of a bridge's Entertainment session.
    /// Round 4e: optionally install a stubbed client and an inert stand-in
    /// render task, so a duplicate-room-id stop test can prove teardown
    /// touches exactly one bridge's task/client/mapping.
    func testStageEntertainmentOwner(
        roomID: String, bridgeID: String, client: HueEntertainmentClient? = nil
    ) {
        compositionEntRoomByBridge[bridgeID] = roomID
        setCompositionTransportClaim(
            .entertainment,
            for: CompositionPlaybackKey(bridgeID: bridgeID, roomID: roomID))
        if let client {
            studioEntClients[bridgeID] = client
            compositionEntTasks[bridgeID]?.cancel()
            compositionEntTasks[bridgeID] = Task {}
        }
    }

    /// Whether a bridge currently holds a composition Entertainment render
    /// task (round 4e) — read-only membership, for exact-teardown assertions.
    func testHasCompositionEntertainmentTask(forBridge bridgeID: String) -> Bool {
        compositionEntTasks[bridgeID] != nil
    }

    /// The exact `Task` handle currently installed for this bridge's
    /// composition Entertainment loop — handed to a test BEFORE any
    /// replacement, so the test holds the identity it means to await rather
    /// than re-reading a slot a replacement may already have overwritten.
    ///
    /// A pure slot read: the dictionary is not mutated, nothing is retained
    /// beyond the caller's own copy, nothing is awaited, and cancellation and
    /// replacement order are untouched. `Task` is a handle, not the job — a
    /// copy stays valid after the entry is replaced or removed, and copying
    /// it neither extends nor shortens the job's life.
    func testCaptureCompositionEntertainmentTask(forBridge bridgeID: String) -> Task<Void, Never>? {
        compositionEntTasks[bridgeID]
    }

    /// The per-bridge acquisition gate, exactly as `startCompositionMode` asks it.
    func testCanAcquireEntertainment(onBridge bridgeID: String) -> Bool {
        canAcquireEntertainment(onBridge: bridgeID)
    }

    /// roomID → bridgeID for every live REST composition runtime.
    /// Round 4e compat read: with the runtime map exactly keyed, a room id
    /// held by TWO bridges is ambiguous here and is omitted (fail closed) —
    /// collision tests must use the exact bridge+room seams instead.
    func testCompositionRuntimeBridges() -> [String: String] {
        var byRoom: [String: [String]] = [:]
        for (key, runtime) in compositionRuntimes {
            byRoom[key.roomID, default: []].append(runtime.bridgeID)
        }
        return byRoom.compactMapValues { $0.count == 1 ? $0[0] : nil }
    }

    // Scoped-mailbox seams (packet 3). `restSendersByBridge` and
    // `studioRestScopesByBridge` are private because only this type may route
    // work into them, but "one room's stop must not clear another's mailbox" is
    // precisely the rule that regressed — so tests get a way to enqueue into,
    // and inspect, the real senders the production paths use.

    /// The very sender a production call site would resolve for this bridge.
    /// Creates it lazily, exactly as production does.
    func testRestSender(for bridgeID: String?) -> RestSender {
        restSender(for: bridgeID)
    }

    /// Which bridges currently HAVE a sender. Used to prove a stop with no REST
    /// runtime does not conjure one (i.e. never guesses a bridge).
    func testRestSenderBridgeKeys() -> Set<String> {
        Set(restSendersByBridge.keys)
    }

    /// The recorded Studio REST owner on ONE bridge, if any (round 4g).
    func testStudioRestScope(forBridgeKey bridgeKey: String) -> RestScope? {
        studioRestScopesByBridge[bridgeKey]
    }

    /// Every recorded Studio REST owner, keyed by bridge (round 4g).
    func testStudioRestScopes() -> [String: RestScope] {
        studioRestScopesByBridge
    }

    /// Stage a Studio REST owner without running an engine loop.
    func testSetStudioRestScope(bridgeKey: String, roomID: String) {
        studioRestScopesByBridge[bridgeKey] = RestScope(roomID: roomID, owner: .studio)
    }

    // Engine-runtime seams (round 4g). Same rule: readers over the REAL
    // per-bridge map the production paths use, plus a stager for the
    // stale-stop tests — a runtime whose loop never runs, so ownership
    // verification can be proven without an engine.

    /// Whether a bridge currently holds an app-driven engine runtime.
    func testHasStudioEngineTask(forBridge bridgeKey: String) -> Bool {
        studioEngineRuntimesByBridge[bridgeKey] != nil
    }

    /// The room recorded as owning a bridge's engine runtime.
    func testStudioEngineRuntimeRoom(forBridge bridgeKey: String) -> String? {
        studioEngineRuntimesByBridge[bridgeKey]?.roomID
    }

    /// Whether a bridge's engine-loop task has been cancelled. nil when no
    /// runtime is installed.
    func testStudioEngineTaskIsCancelled(forBridge bridgeKey: String) -> Bool? {
        studioEngineRuntimesByBridge[bridgeKey]?.task.isCancelled
    }

    /// The live param values a bridge's engine loop currently reads.
    func testStudioParamBoxValues(forBridge bridgeKey: String) -> [String: Double]? {
        studioEngineRuntimesByBridge[bridgeKey]?.paramBox.values
    }

    /// Stage an engine runtime (inert task, real box) without running a loop.
    func testInstallStudioEngineRuntime(bridgeKey: String, roomID: String,
                                        values: [String: Double] = [:]) {
        studioEngineRuntimesByBridge[bridgeKey] = StudioEngineRuntime(
            roomID: roomID,
            task: Task {},
            paramBox: StudioParamBox(values: values, colors: [:]))
    }

    // Composer telemetry seams (packet 4). Same rule as the mailbox seams:
    // readers, a clock injector, and thin pass-throughs to the PRODUCTION
    // helpers and closure factories — never parallel implementations, so what
    // the tests prove is exactly what the scheduler runs.

    /// Inject a deterministic telemetry clock. tearDown must restore the
    /// production clock via `testResetCompositionTelemetryClock()`.
    func testSetCompositionTelemetryClock(_ clock: @escaping () -> CFAbsoluteTime) {
        compositionTelemetryNow = clock
    }

    func testResetCompositionTelemetryClock() {
        compositionTelemetryNow = { CFAbsoluteTimeGetCurrent() }
    }

    /// The ledger's view of one Composer session, as of the telemetry clock.
    func testComposerLedgerSnapshot(roomID: String, bridgeID: String?) -> CompositionSendLedger.Snapshot {
        compositionSendLedger.snapshot(
            bridgeKey: bridgeID ?? "legacy",
            scope: RestScope(roomID: roomID, owner: .composer),
            asOf: compositionTelemetryNow())
    }

    /// Every retained telemetry session's exact identity and status.
    func testComposerTelemetrySessions() -> [(bridgeKey: String, roomID: String, generation: Int, isRESTActive: Bool)] {
        composerTelemetrySessions.map {
            ($0.key.bridgeKey, $0.key.scope.roomID, $0.value.generation, $0.value.isRESTActive)
        }
    }

    /// The tracked not-yet-started token for one exact scope, if any.
    func testComposerPendingToken(roomID: String, bridgeID: String?) -> CompositionSendLedger.Token? {
        composerPendingTokens[ComposerTelemetrySessionKey(
            bridgeKey: bridgeID ?? "legacy",
            scope: RestScope(roomID: roomID, owner: .composer))]
    }

    /// The runtime's delta-gate send state — what completion bookkeeping moves.
    /// Round 4e compat read: exactly-one rule — nil when two bridges hold the
    /// room id (use the exact overload below under a collision).
    func testCompositionRuntimeSendState(roomID: String) -> (sendCount: Int, lastSentX: Double?, lastSentY: Double?, lastSentBri: Double?, lastSentAt: CFAbsoluteTime?)? {
        let matches = compositionRuntimes.filter { $0.key.roomID == roomID }
        guard matches.count == 1, let runtime = matches.first?.value else { return nil }
        return (runtime.sendCount, runtime.lastSentX, runtime.lastSentY,
                runtime.lastSentBri, runtime.lastSentAt)
    }

    /// EXACT bridge+room send state (round 4e).
    func testCompositionRuntimeSendState(bridgeID: String?, roomID: String) -> (sendCount: Int, lastSentX: Double?, lastSentY: Double?, lastSentBri: Double?, lastSentAt: CFAbsoluteTime?)? {
        compositionRuntimes[CompositionPlaybackKey(bridgeID: bridgeID, roomID: roomID)].map {
            ($0.sendCount, $0.lastSentX, $0.lastSentY, $0.lastSentBri, $0.lastSentAt)
        }
    }

    /// Run the SAME per-pass publication sweep the scheduler runs.
    func testRefreshComposerCadencePublications() {
        refreshAllActiveComposerCadencePublications()
    }

    /// Begin a telemetry session exactly as `startCompositionMode` does at its
    /// head; `isRESTActive: true` additionally stages the REST-runtime mark.
    /// `eligibleOperations` arms the packet-5 rotation exactly as production
    /// does; it is ignored unless `isRESTActive`.
    func testBeginComposerTelemetrySession(
        roomID: String, bridgeID: String?, generation: Int, isRESTActive: Bool,
        eligibleOperations: Int = 0
    ) {
        let sessionKey = ComposerTelemetrySessionKey(
            bridgeKey: bridgeID ?? "legacy",
            scope: RestScope(roomID: roomID, owner: .composer))
        beginComposerTelemetrySession(sessionKey: sessionKey, generation: generation)
        if isRESTActive {
            markComposerTelemetrySessionRESTActive(
                sessionKey: sessionKey, eligibleOperations: eligibleOperations)
        }
    }

    /// Rotation state for one exact (bridge, room) Composer session.
    func testCompositionRotationState(
        roomID: String, bridgeID: String?
    ) -> (cursor: Int, eligibleOperationCount: Int,
          hadFailure: Bool, completedSuccessfulRotation: Bool)? {
        let key = ComposerTelemetrySessionKey(
            bridgeKey: bridgeID ?? "legacy",
            scope: RestScope(roomID: roomID, owner: .composer))
        guard let s = compositionRotationStates[key] else { return nil }
        return (s.cursor, s.eligibleOperationCount,
                s.currentRotationHadFailure, s.hasCompletedInitialSuccessfulRotation)
    }

    /// The SAME immutable read model the tray consumes — never the private
    /// mutable state.
    func testCompositionDegradation(
        roomID: String, bridgeID: String?
    ) -> CompositionDegradationSnapshot? {
        compositionDegradation(roomID: roomID, bridgeID: bridgeID)
    }

    /// Record a fallback reason exactly as the production catch does.
    func testRecordCompositionFallback(
        roomID: String, bridgeID: String?, generation: Int,
        reason: CompositionFallbackReason
    ) {
        recordCompositionFallback(
            sessionKey: ComposerTelemetrySessionKey(
                bridgeKey: bridgeID ?? "legacy",
                scope: RestScope(roomID: roomID, owner: .composer)),
            reason: reason, generation: generation)
    }

    /// The production enqueue sequence against the REAL sender for this bridge.
    @discardableResult
    func testEnqueueComposerWork(
        roomID: String, bridgeID: String?, generation: Int,
        workBuilder: (CompositionSendLedger.Token) -> RestSender.Work
    ) async -> CompositionSendLedger.Token {
        await enqueueComposerWork(
            sessionKey: ComposerTelemetrySessionKey(
                bridgeKey: bridgeID ?? "legacy",
                scope: RestScope(roomID: roomID, owner: .composer)),
            generation: generation,
            sender: restSender(for: bridgeID),
            workBuilder: workBuilder)
    }

    /// Production closure factories — the closure a test enqueues is the
    /// closure the scheduler enqueues.
    func testMakeComposerGradientWork(
        token: CompositionSendLedger.Token, entries: [GradientChannelMap.Entry],
        frames: [LightFrame], api: HueAPIClient, gamut: HueColorUtils.Gamut,
        sentX: Double, sentY: Double, sentBri: Double
    ) -> RestSender.Work {
        makeComposerGradientWork(
            token: token, entries: entries, frames: frames, api: api, gamut: gamut,
            sentX: sentX, sentY: sentY, sentBri: sentBri)
    }

    func testMakeComposerPerLightWork(
        token: CompositionSendLedger.Token,
        targets: [(frameIndex: Int, lightID: String)],
        frames: [LightFrame], api: HueAPIClient, gamut: HueColorUtils.Gamut,
        sentX: Double, sentY: Double, sentBri: Double
    ) -> RestSender.Work {
        makeComposerPerLightWork(
            token: token, targets: targets, frames: frames, api: api,
            gamut: gamut, sentX: sentX, sentY: sentY, sentBri: sentBri)
    }

    func testMakeComposerGroupedWork(
        token: CompositionSendLedger.Token, groupedLightID: String,
        brightness: Double, xy: (x: Double, y: Double), api: HueAPIClient
    ) -> RestSender.Work {
        makeComposerGroupedWork(
            token: token, groupedLightID: groupedLightID,
            brightness: brightness, xy: xy, api: api)
    }

    /// Direct event reports through the production handlers, for tests that
    /// exercise the ledger/bookkeeping gates without a live closure.
    func testReportComposerStarted(_ token: CompositionSendLedger.Token) {
        composerWorkStarted(token)
    }

    func testReportComposerCompleted(
        token: CompositionSendLedger.Token, attemptedOperations: Int, failures: Int,
        sentX: Double? = nil, sentY: Double? = nil, sentBri: Double? = nil
    ) {
        composerWorkTerminated(
            token: token, kind: .completed,
            attemptedOperations: attemptedOperations, failures: failures,
            sentX: sentX, sentY: sentY, sentBri: sentBri)
    }

    func testReportComposerCancelled(
        token: CompositionSendLedger.Token, attemptedOperations: Int, failures: Int
    ) {
        composerWorkTerminated(
            token: token, kind: .cancelled,
            attemptedOperations: attemptedOperations, failures: failures)
    }

    /// The production rotation advance, so a test can prove the fences
    /// (generation, exact key, REST-active) reject a stale report without
    /// staging a whole closure.
    func testReportComposerRotationAdvanced(
        token: CompositionSendLedger.Token, attemptedOperations: Int, failures: Int
    ) {
        composerRotationAdvanced(
            token: token, attemptedOperations: attemptedOperations, failures: failures)
    }

    // Entertainment-area selection seams (packet 1b). Selection reads three
    // caches that are normally filled by network work; these let tests stage
    // each component independently — including the partial states that decide
    // `.unknown` vs `.noArea` vs `.noMatchingArea` — without a live bridge.

    /// Stage a bridge's entertainment caches.
    /// `membership: nil` stages the "we could not fetch it" state, which is
    /// deliberately different from a successfully-computed empty map.
    func testSeedEntertainmentCaches(
        bridgeID: String,
        configs: [EntertainmentConfig]?,
        membership: [String: String]?,
        fetched: Bool
    ) {
        if let configs { entertainmentConfigsByBridge[bridgeID] = configs }
        else { entertainmentConfigsByBridge.removeValue(forKey: bridgeID) }

        if let membership { entertainmentMembershipByBridge[bridgeID] = membership }
        else { entertainmentMembershipByBridge.removeValue(forKey: bridgeID) }

        if fetched { entertainmentConfigsFetchedBridges.insert(bridgeID) }
        else { entertainmentConfigsFetchedBridges.remove(bridgeID) }
    }

    /// The cached membership map for a bridge — nil when unknown/failed.
    func testEntertainmentMembership(forBridge bridgeID: String) -> [String: String]? {
        entertainmentMembershipByBridge[bridgeID]
    }

    /// The single start-time selection: config plus the channel IDs the render
    /// loop will be driven with. Both come from one config, by construction.
    func testEntertainmentStartPlan(
        for room: RoomDisplayItem,
        preferredConfigID: String? = nil
    ) -> (config: EntertainmentConfig, channelIDs: [UInt8])? {
        entertainmentStartPlan(for: room, preferredConfigID: preferredConfigID)
    }

    /// Whether this bridge currently holds a live Studio/Composer DTLS client.
    func testHasEntertainmentClient(forBridge bridgeID: String) -> Bool {
        studioEntClients[bridgeID] != nil
    }

    /// DEBUG frame-production proof: the installed client's total send
    /// attempts (nil when no client is installed). The stub transport drops
    /// every frame at the connection guard, so this counter is the only
    /// observable liveness signal a render loop has in tests.
    func testSendAttempts(forBridge bridgeID: String) async -> Int? {
        guard let client = studioEntClients[bridgeID] else { return nil }
        return await client.testSendAttempts
    }

    /// Stage a composition Entertainment claim on a bridge, so the guard-skip
    /// diagnostics can prove which condition an app-driven stop refused on.
    func testSetCompositionEntRoom(bridgeID: String, roomID: String) {
        compositionEntRoomByBridge[bridgeID] = roomID
    }

    /// The production answer to "which app-driven look owns this bridge?",
    /// asked exactly as `startCompositionMode` and the handoff gate ask it.
    func testStudioEntertainmentOwner(onBridge bridgeID: String) -> StudioEntertainmentOwner? {
        studioOwningEntertainment(onBridge: bridgeID)
    }

    /// Stage "Strobe owns bridge B" without a real DTLS handshake.
    ///
    /// Installs BOTH halves, because the production invariant is that they move
    /// together — a seam that wrote only the record would let a test assert
    /// against a state `studioOwningEntertainment` deliberately reports as nil.
    func testInstallStudioEntertainmentOwner(_ owner: StudioEntertainmentOwner,
                                             client: HueEntertainmentClient) {
        studioEntClients[owner.bridgeID] = client
        studioEntOwnerByBridge[owner.bridgeID] = owner
    }

    /// Packet 7: the composition bookkeeping that a start which never happened
    /// must leave completely alone.
    /// Round 4e compat read: exactly-one rule — nil when two bridges hold the
    /// room id (use the exact overload below under a collision).
    func testCompositionGeneration(roomID: String) -> Int? {
        let matches = compositionGenerations.filter { $0.key.roomID == roomID }
        guard matches.count == 1 else { return nil }
        return matches.first?.value
    }

    /// EXACT bridge+room generation (round 4e).
    func testCompositionGeneration(bridgeID: String?, roomID: String) -> Int? {
        compositionGenerations[CompositionPlaybackKey(bridgeID: bridgeID, roomID: roomID)]
    }

    /// The room-keyed DISPLAY aggregate — what the UI reads. Under a
    /// same-room-id collision this is the agreed transport, or nil when the
    /// exact claimants disagree (the aggregate never picks a winner).
    func testCompositionTransport(roomID: String) -> CompositionTransport? {
        compositionTransportByRoom[roomID]
    }

    /// EXACT bridge+room transport claim (round 4e) — the runtime truth the
    /// aggregate above is recomputed from.
    func testCompositionTransport(bridgeID: String?, roomID: String) -> CompositionTransport? {
        compositionTransportClaims[CompositionPlaybackKey(bridgeID: bridgeID, roomID: roomID)]
    }

    /// EXACT runtime existence (round 4e) — proof a live REST composition
    /// genuinely exists for this bridge+room, independent of presentation rows.
    func testHasCompositionRuntime(bridgeID: String?, roomID: String) -> Bool {
        compositionRuntimes[CompositionPlaybackKey(bridgeID: bridgeID, roomID: roomID)] != nil
    }

    /// EXACT scheduler membership (round 4e).
    func testCompositionOrderContains(bridgeID: String?, roomID: String) -> Bool {
        compositionOrder.contains(CompositionPlaybackKey(bridgeID: bridgeID, roomID: roomID))
    }

    /// Which room a bridge's Entertainment session is driving, if any (round
    /// 4e) — the exact map `stopCompositionMode`'s teardown is gated on.
    func testCompositionEntertainmentRoom(forBridge bridgeID: String) -> String? {
        compositionEntRoomByBridge[bridgeID]
    }

    /// The exact SSE-suppression predicate (round 4e) — true only when THIS
    /// bridge's group is app-driven.
    func testIsAppDrivenGroup(bridgeID: String, roomID: String) -> Bool {
        isAppDrivenGroup(bridgeID: bridgeID, roomID: roomID)
    }

    func testHasComposerTelemetrySession(roomID: String, bridgeID: String?) -> Bool {
        let key = ComposerTelemetrySessionKey(
            bridgeKey: bridgeID ?? "legacy",
            scope: RestScope(roomID: roomID, owner: .composer))
        return composerTelemetrySessions[key] != nil
    }

    /// Packet 2: the exact pre-upload cleanup the bridge-stored start path runs.
    /// Exposes the decision, not the store — tests stage manifests through the
    /// store's own public API and assert on what reaches each bridge's client.
    @discardableResult
    func testCleanupBridgeStoredForReplacement(
        roomID: String, bridgeID: String?, v1Client: HueV1Client
    ) async -> BridgeStoredReplacementReadiness {
        await cleanupBridgeStoredAnimationForReplacement(
            roomID: roomID, bridgeID: bridgeID, v1Client: v1Client)
    }

    // ── Bridge-stored reconciliation seams (packet 8) ────────────────────

    /// Drive one reconciliation pass deterministically — the PRODUCTION pass,
    /// with no throttle and no detached task in the way.
    func testReconcileBridgeStoredAnimations() async {
        await reconcileBridgeStoredAnimations()
    }

    /// Swap in an isolated store so a suite never reads or writes the real
    /// user's persisted animations — and so one test cannot clear another's.
    func injectForTesting(bridgeAnimationStore store: BridgeAnimationStore) {
        bridgeAnimationStore = store
    }

    /// Wait out any pass `loadAll` scheduled.
    ///
    /// `BridgeAnimationStore.shared` is a process-wide singleton, so a detached
    /// pass that outlives the test which started it would keep mutating the
    /// store while the NEXT test asserts on it. Draining is a continuation
    /// handshake, not a timed wait.
    func testDrainBridgeAnimationReconciliation() async {
        let inFlight = bridgeAnimationReconcileTask
        bridgeAnimationReconcileTask = nil
        await inFlight?.value
    }

    func testRecoveredBridgeAnimations() -> [RecoveredBridgeAnimationKey: RecoveredBridgeAnimation] {
        recoveredBridgeAnimations
    }

    /// Publish a recovered animation without a bridge read — for staging a
    /// "replacement already took this room" state inside a parked stop.
    func testPublishRecovered(manifest: BridgeAnimationManifest, bridgeID: String) {
        publishRecovered(decided: [
            RecoveredBridgeAnimationKey(bridgeID: bridgeID, manifestID: manifest.id):
                makeRecovered(manifest, bridgeID: bridgeID)
        ])
    }

    func testExactManifestIDs(bridgeID: String?, roomID: String) -> Set<UUID> {
        Set(exactManifests(bridgeID: bridgeID, roomID: roomID).map(\.id))
    }

    /// Round 4c: the exact ownership ledger — which manifests stand as this
    /// bridge's RUNNING claim on this room. Read-only; tests prove that
    /// destructive paths subtract exactly the destroyed identities.
    func testBridgeStoredChainOwnership(bridgeID: String, roomID: String) -> Set<UUID> {
        bridgeStoredChainOwnership[
            BridgeNativeOwnershipKey(bridgeKey: bridgeID, roomID: roomID)] ?? []
    }

    func testRoomOwnershipGeneration(bridgeID: String?, roomID: String) -> Int {
        roomOwnershipGeneration(bridgeID: bridgeID, roomID: roomID)
    }

    // ── All-Day seams (packet 6) ─────────────────────────────────────────
    //
    // Same rule as the mailbox seams above: readers and thin pass-throughs to
    // the PRODUCTION helpers, never parallel implementations. In particular
    // `testAllDayRestSender(for:)` returns the same Optional the production
    // accessor does — a seam that force-unwrapped it would hide exactly the
    // refusal these tests exist to prove.

    /// The All-Day mailbox for a bridge, or nil when All-Day may not write.
    func testAllDayRestSender(for bridgeID: String?) -> RestSender? {
        allDayRestSender(for: bridgeID)
    }

    /// Which bridges currently hold an All-Day mailbox. Read-only — asking does
    /// not create one (contrast the accessor above).
    func testAllDayRestSenderBridgeKeys() -> Set<String> {
        Set(allDayRestSendersByBridge.keys)
    }

    func testAllDayBlockedBridgeKeys() -> Set<String> {
        allDayBlockedBridgeKeys
    }

    func testAllDayTeardownInProgress() -> Bool {
        allDayTeardownInProgress
    }

    func testAllDayGeneration() -> Int {
        allDayGeneration
    }

    func testAllDayTaskIsRunning() -> Bool {
        allDayTask != nil
    }

    func testIsAllDayBridgeEligible(_ bridgeID: String?) -> Bool {
        isAllDayBridgeEligible(bridgeID)
    }

    /// Drive exactly one All-Day tick, deterministically — the production tick,
    /// not a copy, so what these tests prove is what the 5-minute loop runs.
    func testTickAllDayScenes(anchor: AllDayAnchor, generation: Int) async {
        await tickAllDayScenes(anchor: anchor, generation: generation)
    }

    /// Stage the generation a tick must match without spinning up the loop.
    func testSetAllDayGeneration(_ generation: Int) {
        allDayGeneration = generation
    }

    /// Tombstone a bridge exactly as `removeBridge` does, without running the
    /// whole removal (which needs credentials and SwiftData).
    func testBlockAllDayBridge(_ bridgeID: String) {
        allDayBlockedBridgeKeys.insert(bridgeID)
    }

    /// Lift it exactly as the two registration paths do — the PRODUCTION
    /// helper, so a test cannot prove a clear the real paths do not perform.
    func testClearAllDayBridgeTombstone(_ bridgeID: String) {
        clearAllDayBridgeTombstone(bridgeID)
    }

    /// Stage the forget-all gate without running forget-all itself.
    func testSetAllDayTeardownInProgress(_ inProgress: Bool) {
        allDayTeardownInProgress = inProgress
    }

    /// The suppression decision itself — a pure read, so it is testable as a
    /// predicate independently of the tick that consults it.
    func testIsAllDayWriteAllowed(bridgeID: String?, roomID: String) -> Bool {
        isAllDayWriteAllowed(bridgeID: bridgeID, roomID: roomID)
    }

    /// Which exact (bridge, room) pairs currently hold a bridge-native claim.
    func testBridgeNativeOwners() -> Set<BridgeNativeOwnershipKey> {
        Set(bridgeNativeOwners.keys)
    }
    #endif

    // MARK: Bridge-Stored Animation (v1 API)
    private let bridgeAnimationEngine = BridgeAnimationEngine()
    private var bridgeAnimationStore = BridgeAnimationStore.shared

    // ── Recovered bridge-stored animations (Composer 2 packet 8) ─────────
    //
    // A bridge-stored look runs on the bridge's own firmware, so it survives a
    // force-quit — that is the transport's whole point. But nothing used to
    // read the persisted manifests back at launch, so the animation kept
    // cycling while the app showed nothing running and offered no way to stop
    // it. The only escape was the Settings purge, which wipes every CG_
    // resource on the bridge including other rooms' live looks.

    /// Exact identity of one recovered animation. NEVER a room id alone — the
    /// same room id can be running on two bridges at once, and each must stay
    /// independently visible and independently stoppable.
    struct RecoveredBridgeAnimationKey: Hashable, Sendable {
        let bridgeID: String
        let manifestID: UUID
    }

    /// One manifest the BRIDGE ITSELF confirmed is still running.
    struct RecoveredBridgeAnimation: Identifiable, Equatable, Sendable {
        let manifest: BridgeAnimationManifest
        let bridgeID: String
        /// The live room, or nil when this room id no longer resolves on this
        /// bridge. nil is a first-class state, not an error: the animation is
        /// still running and must stay stoppable without guessing a room.
        let room: RoomDisplayItem?
        /// `room?.name` when the room resolves, else the manifest's persisted
        /// name — a deleted room must not make the row nameless.
        let roomName: String
        /// The current preset name when Studio has upgraded it, else the
        /// manifest's persisted name. A deleted preset must not make the
        /// running animation impossible to identify or stop.
        let displayName: String

        var key: RecoveredBridgeAnimationKey {
            RecoveredBridgeAnimationKey(bridgeID: bridgeID, manifestID: manifest.id)
        }
        var id: RecoveredBridgeAnimationKey { key }
    }

    /// THE authoritative reconciled registry. Written only by reconciliation
    /// and by the exact-identity stop. StudioViewModel mirrors it; it never
    /// decides liveness for itself.
    private(set) var recoveredBridgeAnimations: [RecoveredBridgeAnimationKey: RecoveredBridgeAnimation] = [:]

    /// Bumped on every publish. The ordering primitive: a Studio hydrate that
    /// ran before the first reconcile is re-driven by the publish, and one that
    /// already saw this generation is a no-op.
    private(set) var bridgeAnimationReconcileGeneration: Int = 0

    @ObservationIgnored private var bridgeAnimationReconcileTask: Task<Void, Never>?
    @ObservationIgnored private var lastBridgeAnimationReconcileAt: Date = .distantPast
    private static let bridgeAnimationReconcileInterval: TimeInterval = 60
    /// After an INCOMPLETE pass (a bridge did not answer, or a decision went
    /// stale) the clock backs off to 15 s rather than a full minute — "retry
    /// later" for an unreadable bridge should be soon, without becoming the
    /// ~1.5 s cadence `scheduleStateRefresh` drives `loadAll` at.
    private static let bridgeAnimationRetryInterval: TimeInterval = 15

    /// Throttled launch/foreground/refresh entry point. Mirrors
    /// `scheduleEntertainmentCleanup`, including the "already running" guard —
    /// two overlapping passes would read the same bridge twice.
    private func scheduleBridgeAnimationReconciliation() {
        guard bridgeAnimationReconcileTask == nil,
              // Zero cost for the overwhelming majority of users, who have
              // never uploaded a bridge-stored look.
              !bridgeAnimationStore.allManifests().isEmpty,
              Date().timeIntervalSince(lastBridgeAnimationReconcileAt)
                  > Self.bridgeAnimationReconcileInterval else { return }
        lastBridgeAnimationReconcileAt = Date()
        bridgeAnimationReconcileTask = Task(priority: .utility) { [weak self] in
            await self?.reconcileBridgeStoredAnimations()
            self?.bridgeAnimationReconcileTask = nil
        }
    }

    /// Reconcile every persisted manifest against what its OWN bridge reports.
    ///
    /// Read-only for anything still running: a verified live animation is never
    /// mutated here. Internal rather than private so tests drive the production
    /// pass directly, with no throttle and no task scheduling in the way.
    func reconcileBridgeStoredAnimations() async {
        let manifests = bridgeAnimationStore.allManifests()
        guard !manifests.isEmpty else {
            publishRecovered(decided: [:])
            return
        }

        // ── 1. Resolve each manifest to an EXACT registered bridge ────────
        var byBridge: [String: [BridgeAnimationManifest]] = [:]
        var complete = true
        for manifest in manifests {
            guard let bridgeID = resolvedBridgeID(for: manifest) else {
                // Unresolved or ambiguous: retain, no verdict, no entry, and
                // notably NO read — an unmapped manifest is not a licence to
                // poll every bridge looking for a home for it.
                complete = false
                continue
            }
            // ── 2. Legacy upgrade, only on a UNIQUE resolution ────────────
            let stamped = manifest.bridgeID == nil
                ? (bridgeAnimationStore.adoptBridgeID(bridgeID, forManifestID: manifest.id) ?? manifest)
                : manifest
            byBridge[bridgeID, default: []].append(stamped)
        }

        // ── 3. ONE batched read per bridge, bridges concurrent ────────────
        struct BridgeRead: Sendable {
            let bridgeID: String
            let inventory: BridgeAnimationInventory?
        }
        var reads: [String: BridgeAnimationInventory] = [:]
        await withTaskGroup(of: BridgeRead.self) { group in
            for (bridgeID, bridgeManifests) in byBridge {
                guard let api = hueClient(for: bridgeID),
                      let v1Client = try? api.makeV1Client() else {
                    complete = false
                    continue
                }
                let needScenes = bridgeManifests.contains { !$0.sceneIDs.isEmpty }
                let needLinks = bridgeManifests.contains { $0.resourcelinkID != nil }
                group.addTask {
                    // Each child swallows its OWN error. One offline bridge must
                    // never cancel, fail or delay another bridge's read.
                    let inventory = try? await v1Client.fetchAnimationInventory(
                        includeScenes: needScenes, includeResourcelinks: needLinks)
                    return BridgeRead(bridgeID: bridgeID, inventory: inventory)
                }
            }
            for await read in group {
                if let inventory = read.inventory { reads[read.bridgeID] = inventory }
            }
        }

        // ── 4. Verdict per manifest against its OWN bridge's snapshot ─────
        var decided: [RecoveredBridgeAnimationKey: RecoveredBridgeAnimation?] = [:]
        for (bridgeID, bridgeManifests) in byBridge {
            guard let inventory = reads[bridgeID] else {
                // UNKNOWN: retain every manifest on this bridge, claim nothing,
                // delete nothing, and try again on a later load or refresh.
                complete = false
                continue
            }
            for manifest in bridgeManifests {
                let key = RecoveredBridgeAnimationKey(bridgeID: bridgeID, manifestID: manifest.id)
                switch BridgeAnimationEngine.liveness(of: manifest, in: inventory) {
                case .live:
                    // Strictly read-only. Nothing below this line mutates the
                    // bridge for a manifest that is still running.
                    guard stillCurrent(manifest) else { complete = false; continue }
                    decided[key] = makeRecovered(manifest, bridgeID: bridgeID)

                case .indeterminate(let reason):
                    debugLog("[Composer] Manifest \(manifest.id) indeterminate: \(reason)")
                    complete = false

                case .notRunning(let residue) where residue.isEmpty:
                    // The bridge PROVED every named resource is absent.
                    guard stillCurrent(manifest) else { complete = false; continue }
                    forgetManifestRecord(id: manifest.id)
                    decided[key] = .some(nil)

                case .notRunning(let residue):
                    // Structurally incomplete: clean up ONLY the resources this
                    // manifest names and the bridge still holds. Never the
                    // global CG_ purge, which would tear down other rooms.
                    guard stillCurrent(manifest),
                          let api = hueClient(for: bridgeID),
                          let v1Client = try? api.makeV1Client() else {
                        complete = false
                        continue
                    }
                    let result = await bridgeAnimationEngine.stop(
                        manifest: manifest, v1Client: v1Client, only: residue)
                    if retireManifest(manifest, after: result) {
                        decided[key] = .some(nil)
                    } else {
                        complete = false
                    }
                }
            }
        }

        // ── 5. Publish ────────────────────────────────────────────────────
        publishRecovered(decided: decided)
        if !complete {
            lastBridgeAnimationReconcileAt = Date().addingTimeInterval(
                -(Self.bridgeAnimationReconcileInterval - Self.bridgeAnimationRetryInterval))
        }
    }

    private func makeRecovered(
        _ manifest: BridgeAnimationManifest,
        bridgeID: String
    ) -> RecoveredBridgeAnimation {
        // Only a room on THIS bridge may be adopted. A room id that matches on
        // another bridge is a different room that happens to share an id.
        let room = allRooms.first { $0.id == manifest.roomID && $0.bridgeID == bridgeID }
        // Always the PERSISTED name here. Studio holds the CompositionStore and
        // upgrades this to the live preset's name during the hydrate that
        // `publishRecovered` triggers, so a rename shows through immediately.
        // Carrying a previously-upgraded name forward instead would mean a
        // preset that was renamed and then DELETED kept displaying the old
        // preset's name rather than falling back to what the manifest recorded.
        return RecoveredBridgeAnimation(
            manifest: manifest,
            bridgeID: bridgeID,
            room: room,
            roomName: room?.name ?? manifest.roomName,
            displayName: manifest.presetName)
    }

    /// Apply this pass's decisions.
    ///
    /// A RECONCILE, not a rebuild, and it merges by exact manifest identity.
    /// It deliberately does NOT sweep entries the pass did not cover: a
    /// manifest saved AFTER the pass began is absent from the pass's input
    /// through no fault of its own, and dropping it would destroy the record of
    /// a look that is genuinely running. The only removals are decisions this
    /// pass actually reached, plus entries whose manifest is gone from the
    /// store right now — which is a fact read at apply time, not an inference
    /// about what the pass happened to see.
    private func publishRecovered(
        decided: [RecoveredBridgeAnimationKey: RecoveredBridgeAnimation?]
    ) {
        for (key, value) in decided {
            if let animation = value {
                let wasAlreadyOwner = recoveredBridgeAnimations[key] != nil
                recoveredBridgeAnimations[key] = animation
                // `addActiveEffect` replaces same-id rows, so re-publishing an
                // unchanged animation cannot produce a duplicate row.
                addActiveEffect(ActiveEffectEntry(recovered: animation))
                // Recovered as ACTIVE: reconciliation proved the chain live on
                // this exact bridge, which is the ownership ledger's standard
                // of evidence (round 4c) — and how it repopulates after a
                // relaunch. Idempotent for a re-confirmed owner. The ledger
                // write below also raises the exact `.bridgeStored` transport
                // claim (round 4e), which recomputes the room aggregate.
                recordBridgeStoredChainOwnership(
                    bridgeID: key.bridgeID,
                    roomID: animation.manifest.roomID,
                    manifestID: key.manifestID)
                // ONLY on genuine acquisition. The generation is what a parked
                // stop compares against before powering the room off, so an
                // idempotent refresh that re-confirms the SAME owner must not
                // move it — that would make every routine reconciliation look
                // like a replacement and silently suppress the room-off.
                // A replacement carries a new manifest id, hence a new key,
                // hence a genuine insert here.
                if !wasAlreadyOwner {
                    noteRoomOwnershipChange(bridgeID: key.bridgeID, roomID: animation.manifest.roomID)
                }
            } else {
                forgetRecoveredBridgeAnimation(key)
            }
        }
        for (key, animation) in recoveredBridgeAnimations
        where bridgeAnimationStore.manifest(id: key.manifestID) == nil {
            _ = animation
            forgetRecoveredBridgeAnimation(key)
        }

        bridgeAnimationReconcileGeneration &+= 1
        studioRecoveredHydrationHandler?()
    }

    /// Drop one recovered animation's app-side state. Never touches the bridge
    /// and never touches another key.
    private func forgetRecoveredBridgeAnimation(_ key: RecoveredBridgeAnimationKey) {
        guard let animation = recoveredBridgeAnimations.removeValue(forKey: key) else { return }
        removeActiveEffect(id: ActiveEffectEntry.recoveredID(manifestID: key.manifestID))
        // No longer recovered-as-active, so it is no longer the room's
        // running claim (round 4c). Exact by manifest id — the subtract also
        // lowers the exact transport claim when the ownership set empties
        // (round 4e), recomputing the room aggregate under the same
        // fail-closed evidence rule the old room-wide clear held.
        subtractBridgeStoredChainOwnership(manifestID: key.manifestID)
        // Round 4e: this row may itself have been the last evidence a
        // retained room label leaned on — recompute the display aggregate.
        recomputeCompositionTransportAggregate(roomID: animation.manifest.roomID)
        // The registry moved, so Studio's mirror is stale. Bumping the
        // generation is what lets its guarded hydrate run again — without it a
        // stopped animation keeps a Studio row that nothing can clear.
        bridgeAnimationReconcileGeneration &+= 1
        studioRecoveredHydrationHandler?()
    }

    /// Same, addressed by manifest id — used by the removal funnel, which knows
    /// the manifest but not necessarily which bridge resolved for it.
    private func forgetRecoveredBridgeAnimation(manifestID: UUID) {
        // Materialized first: `forgetRecoveredBridgeAnimation(_:)` mutates the
        // dictionary this iterates.
        let matching = recoveredBridgeAnimations.keys.filter { $0.manifestID == manifestID }
        for key in matching { forgetRecoveredBridgeAnimation(key) }
    }

    // `clearBridgeStoredTransportIfUnowned` was deleted in round 4e: the
    // `.bridgeStored` label's lifecycle now moves with the exact transport
    // claims (raised by the ownership ledger's record, lowered when an exact
    // bridge+room ownership set empties), and the room aggregate's recompute
    // carries the same fail-closed evidence rule this function held.

    /// Studio upgrades a recovered row's name once it can resolve the preset.
    /// The orchestrator holds no `CompositionStore`, so it publishes the
    /// manifest's persisted name first and this replaces it in place.
    func refreshRecoveredDisplayName(key: RecoveredBridgeAnimationKey, name: String) {
        guard let existing = recoveredBridgeAnimations[key], existing.displayName != name else { return }
        let updated = RecoveredBridgeAnimation(
            manifest: existing.manifest, bridgeID: existing.bridgeID, room: existing.room,
            roomName: existing.roomName, displayName: name)
        recoveredBridgeAnimations[key] = updated
        addActiveEffect(ActiveEffectEntry(recovered: updated))
    }

    /// Stop EXACTLY one recovered bridge-stored animation on EXACTLY its bridge.
    /// Returns true only when the bridge confirmed the resources are gone.
    ///
    /// Stale-stop protection is structural: the key carries the MANIFEST id,
    /// which `upload` regenerates on every start. A stop that began before a
    /// replacement was uploaded names an id the registry and store no longer
    /// hold, so it cannot touch the replacement's manifest, registry entry,
    /// Now-Playing row or Studio row.
    @discardableResult
    func stopRecoveredBridgeAnimation(
        _ key: RecoveredBridgeAnimationKey,
        turnOffLights: Bool = true
    ) async -> Bool {
        guard let animation = recoveredBridgeAnimations[key] else { return false }
        guard let manifest = bridgeAnimationStore.manifest(id: key.manifestID) else {
            // Nothing left to clean — the evidence is already gone.
            forgetRecoveredBridgeAnimation(key)
            return true
        }
        guard let api = hueClient(for: key.bridgeID), let v1Client = try? api.makeV1Client() else {
            // The manifest's bridge is not registered right now. RETAIN
            // everything: this manifest is the only record of live bridge
            // resources, the animation is still running, and dropping the
            // ownership state here would let All-Day start writing over it.
            toastMessage = "Couldn't stop \(animation.displayName) — its bridge isn't connected"
            return false
        }

        // Capture the exact ownership generation BEFORE the cleanup await.
        let token = RecoveredStopToken(
            bridgeID: key.bridgeID,
            roomID: manifest.roomID,
            manifestID: manifest.id,
            ownershipGeneration: roomOwnershipGeneration(bridgeID: key.bridgeID, roomID: manifest.roomID))

        let result = await bridgeAnimationEngine.stop(manifest: manifest, v1Client: v1Client)
        guard result == .removed else {
            toastMessage = "Couldn't stop \(animation.displayName) — the bridge didn't confirm"
            return false
        }
        guard retireManifest(manifest, after: result) else { return false }
        studioRecoveredHydrationHandler?()

        // Power-off is generation-safe. Between the cleanup and here, a
        // replacement or any other owner can have taken this exact bridge and
        // room; darkening it then would kill playback the user just started.
        guard turnOffLights, let groupedLightID = animation.room?.groupedLightID else { return true }
        guard roomOwnershipGeneration(bridgeID: key.bridgeID, roomID: manifest.roomID) == token.ownershipGeneration,
              isAllDayWriteAllowed(bridgeID: key.bridgeID, roomID: manifest.roomID) else {
            debugLog("[Composer] Skipping room-off for \(manifest.roomID) — a newer owner holds it")
            return true
        }
        try? await api.setGroupedLight(id: groupedLightID, on: false)
        return true
    }

    /// The exact identity a recovered stop carries across its awaits.
    struct RecoveredStopToken: Equatable {
        let bridgeID: String
        let roomID: String
        let manifestID: UUID
        let ownershipGeneration: Int
    }

    /// Remove ONLY the bridge-stored animations `roomID` owns on the bridge that
    /// `v1Client` talks to, using each manifest's recorded resource IDs as the
    /// ownership boundary (Composer 2 packet 2, Phase 0 item 4).
    ///
    /// What this deliberately does NOT do: enumerate `/schedules`, `/rules`,
    /// `/sensors`, `/scenes` or `/resourcelinks`, and never match on the `CG_`
    /// name prefix. Every bridge-stored start used to finish its per-room loop
    /// with `purgeAllChromaGlowResources`, which deletes every `CG_` resource on
    /// the bridge — so starting a look in room B tore down room A's live
    /// animation and left room A's manifest pointing at resources that no longer
    /// existed. The global purge is a recovery operation and now reaches the
    /// bridge only through the explicit Settings maintenance action.
    ///
    /// The bridge identity is stated by the caller and cross-checked against
    /// `v1Client.bridgeIP`: cleaning one bridge's manifests against another
    /// bridge's client stays structurally impossible.
    ///
    /// Packet 8 makes the result TYPED. A refused or unreachable delete used to
    /// be indistinguishable from a clean teardown, so the replacement uploaded
    /// a second sensor/rule-chain/schedule on top of a chain that was still
    /// firing — two recurring animations fighting over one room, with the app
    /// holding a record of only one of them.
    private func cleanupBridgeStoredAnimationForReplacement(
        roomID: String,
        bridgeID: String?,
        v1Client: HueV1Client
    ) async -> BridgeStoredReplacementReadiness {
        var retained: [UUID] = []
        var reason = ""
        for oldManifest in exactManifests(bridgeID: bridgeID, roomID: roomID)
        where oldManifest.bridgeIP == v1Client.bridgeIP || oldManifest.bridgeID != nil {
            debugLog("[Composer] Cleaning up previous bridge animation '\(oldManifest.presetName)' for room=\(roomID)")
            let result = await bridgeAnimationEngine.stop(manifest: oldManifest, v1Client: v1Client)
            if !retireManifest(oldManifest, after: result) {
                retained.append(oldManifest.id)
                reason = result == .removed ? "cleanup raced a change" : "the bridge didn't confirm cleanup"
            }
        }
        return retained.isEmpty ? .clear : .blocked(reason: reason, retained: retained)
    }

    /// Whether a bridge-stored replacement may be created.
    enum BridgeStoredReplacementReadiness: Equatable {
        /// Every exact old manifest for this bridge + room is removed or was
        /// already absent.
        case clear
        case blocked(reason: String, retained: [UUID])
    }

    // ── Exact manifest selection (packet 8) ──────────────────────────────

    /// The bridge-stored manifests that EXACTLY this bridge and room own.
    ///
    /// The sole destructive-selection authority. `compositionTransportByRoom`
    /// and every other roomID-only structure are explicitly NOT ownership: the
    /// same room id exists on two bridges, and after the store rekey the same
    /// preset legitimately has two manifests in one room id.
    ///
    /// - a recorded `bridgeID` is authoritative;
    /// - a legacy IP-only manifest matches only when its IP resolves UNIQUELY
    ///   to the caller's bridge;
    /// - ambiguous or unresolved identity yields nothing — retained, untouched;
    /// - a manifest on another bridge is never selected for sharing a room id.
    ///
    /// A `nil` caller `bridgeID` follows `hueClient(for:)`'s rule: it names the
    /// single bridge in a one-bridge home and names NOTHING when several are
    /// registered. Failing closed there is the point — a stop that cannot say
    /// which bridge must not delete on a guess.
    private func exactManifests(bridgeID: String?, roomID: String) -> [BridgeAnimationManifest] {
        guard let callerBridgeID = resolvedCallerBridgeID(bridgeID) else {
            debugLog("[Composer] No exact bridge identity for room=\(roomID) — retaining every manifest")
            return []
        }
        let callerIP = (try? clients[callerBridgeID]?.credentials())?.ip
        return bridgeAnimationStore.allManifests().filter { manifest in
            guard manifest.roomID == roomID else { return false }
            if let recorded = manifest.bridgeID { return recorded == callerBridgeID }
            // Legacy: the IP must resolve to exactly one registered bridge AND
            // that bridge must be the caller's.
            guard let callerIP, manifest.bridgeIP == callerIP else { return false }
            return clients.values.filter { (try? $0.credentials())?.ip == manifest.bridgeIP }.count == 1
        }
    }

    /// Normalize the caller's own bridge identity, or nil when it is not exact.
    private func resolvedCallerBridgeID(_ bridgeID: String?) -> String? {
        if let bridgeID { return clients[bridgeID] != nil ? bridgeID : nil }
        return clients.count == 1 ? clients.keys.first : nil
    }

    /// The bridge a manifest belongs to, or nil when the app cannot say WHICH.
    ///
    /// A recorded id must still be registered; a legacy IP resolves only on
    /// EXACTLY ONE match. Ambiguous fails closed: no upgrade, no verdict, no
    /// cleanup, no claim about whether the animation is running.
    private func resolvedBridgeID(for manifest: BridgeAnimationManifest) -> String? {
        if let recorded = manifest.bridgeID { return clients[recorded] != nil ? recorded : nil }
        let matches = clients.filter { (try? $0.value.credentials())?.ip == manifest.bridgeIP }
        guard matches.count == 1 else { return nil }
        return matches.first?.key
    }

    /// THE single manifest-removal funnel. Returns true only when the evidence
    /// was actually retired.
    ///
    /// Evidence may be dropped only once the bridge proved the resources are
    /// gone. `.partial` and `.bridgeUnreadable` are reasons to WAIT — before
    /// packet 8 an unresolvable client was treated as a reason to FORGET, which
    /// permanently destroyed the only record of an animation that keeps looping.
    @discardableResult
    private func retireManifest(
        _ manifest: BridgeAnimationManifest,
        after result: BridgeAnimationCleanupResult
    ) -> Bool {
        switch result {
        case .partial:
            debugLog("[Composer] Bridge refused part of the cleanup for manifest \(manifest.id) — retaining")
            return false
        case .bridgeUnreadable:
            debugLog("[Composer] Bridge unreadable during cleanup of manifest \(manifest.id) — retaining for retry")
            return false
        case .removed:
            // Freshness: a replacement may have taken this id's place while the
            // deletes were in flight. Only retire the exact value we cleaned.
            guard stillCurrent(manifest) else {
                debugLog("[Composer] Manifest \(manifest.id) changed during cleanup — leaving the newer record alone")
                return false
            }
            forgetManifestRecord(id: manifest.id)
            forgetRecoveredBridgeAnimation(manifestID: manifest.id)
            return true
        }
    }

    /// May a decision computed BEFORE an await still be applied?
    ///
    /// The manifest value is the fingerprint — it covers the id, both bridge
    /// identities and the complete named resource set, so a removal, a
    /// replacement or a different legacy upgrade all fail this check. A miss
    /// skips the decision and lets a later pass redo it; it never guesses.
    private func stillCurrent(_ snapshot: BridgeAnimationManifest) -> Bool {
        bridgeAnimationStore.manifest(id: snapshot.id) == snapshot
    }

    /// Which transport is driving each room's composition right now.
    enum CompositionTransport: Equatable {
        case entertainment   // DTLS streaming
        case rest            // app-driven REST scheduler
        case bridgeStored    // v1 rules chain on the bridge itself
    }
    /// Per-room transport DISPLAY AGGREGATE (absent key = no composition
    /// running there, or the exact claimants disagree). Written only at start /
    /// stop / failover — never per frame — so views may observe it freely.
    ///
    /// Round 4e: this map is COMPATIBILITY/DISPLAY state only, recomputed from
    /// `compositionTransportClaims` by the two helpers below — never written
    /// directly, and NEVER destructive authority. Two bridges sharing a room id
    /// keep the entry alive while either exact claim stands; if their claims
    /// disagree on transport, the entry is removed (ambiguous — the room-only
    /// key must not silently pick a winner).
    var compositionTransportByRoom: [String: CompositionTransport] = [:]

    /// EXACT transport ownership (round 4e): which transport each live
    /// bridge+room playback claims. Represents RUNNING ownership only — a
    /// saved-but-not-confirmed-running chain is inert and never claims
    /// (`.bridgeStored` claims move with the ownership ledger: first
    /// confirmed-running manifest adds the claim, and it falls only when the
    /// exact bridge+room ownership set empties).
    @ObservationIgnored
    private var compositionTransportClaims: [CompositionPlaybackKey: CompositionTransport] = [:]

    /// EXACT transport for one bridge+room — the read the customization surface
    /// needs, without exposing the claims map.
    ///
    /// `compositionTransportByRoom` is a recomputed DISPLAY aggregate that
    /// answers nil when two bridges' claims disagree, so a surface reading it by
    /// bare room id renders the wrong badge — or "unknown" — precisely when
    /// exact truth exists. That made Track A's identity guarantee false in the
    /// only case the guarantee exists for.
    ///
    /// Pure read. No writes, no mutation, no new state — it reads the exact
    /// claim that round 4e already records. The aggregate stays in place for
    /// consumers that legitimately have no bridge identity to offer.
    ///
    /// The aggregate fallback is reached ONLY for a nil bridgeID (legacy
    /// callers), never as a "close enough" answer for a known bridge: falling
    /// back there would silently reintroduce the collision.
    func compositionTransport(bridgeID: String?, roomID: String) -> CompositionTransport? {
        guard let bridgeID else { return compositionTransportByRoom[roomID] }
        return compositionTransportClaims[
            CompositionPlaybackKey(bridgeID: bridgeID, roomID: roomID)]
    }

    /// TEST SEAM: stage one exact transport claim (and the aggregate it
    /// recomputes) without running a real start. The claims map stays private —
    /// tests assert through `compositionTransport(bridgeID:roomID:)`, which is
    /// the API the UI actually uses.
    func testSeedCompositionTransportClaim(
        _ transport: CompositionTransport, bridgeID: String?, roomID: String
    ) {
        setCompositionTransportClaim(
            transport, for: CompositionPlaybackKey(bridgeID: bridgeID, roomID: roomID))
    }

    /// Write one exact transport claim, then recompute the room aggregate.
    private func setCompositionTransportClaim(
        _ transport: CompositionTransport, for key: CompositionPlaybackKey
    ) {
        compositionTransportClaims[key] = transport
        recomputeCompositionTransportAggregate(roomID: key.roomID)
    }

    /// Withdraw one exact transport claim, then recompute the room aggregate —
    /// another bridge's same-room-id claim keeps the room entry alive.
    /// `retainedManifestIDs` flows to the fail-closed evidence check: a
    /// just-saved inert chain is not the room's playing look.
    private func removeCompositionTransportClaim(
        for key: CompositionPlaybackKey, retainedManifestIDs: Set<UUID> = []
    ) {
        compositionTransportClaims.removeValue(forKey: key)
        recomputeCompositionTransportAggregate(
            roomID: key.roomID, retainedManifestIDs: retainedManifestIDs)
    }

    /// The ONLY writer of `compositionTransportByRoom`: no claimants → no
    /// entry; all claimants agree → that value; claimants disagree → no entry
    /// (ambiguous/unknown — callers that need the truth under a collision hold
    /// bridge identity and read the exact claim).
    ///
    /// One fail-closed exception, carried over from round 4c: a standing
    /// `.bridgeStored` label whose last exact claim fell is RETAINED while any
    /// bridge-stored evidence for the room still exists — a recovered
    /// animation, or a stored manifest (an unattributable legacy manifest
    /// counts: ambiguity retains). Display state may keep saying "maybe
    /// running"; it may never be the reason something is destroyed.
    private func recomputeCompositionTransportAggregate(
        roomID: String, retainedManifestIDs: Set<UUID> = []
    ) {
        let claims = Set(
            compositionTransportClaims
                .filter { $0.key.roomID == roomID }
                .map(\.value))
        if claims.count == 1, let agreed = claims.first {
            compositionTransportByRoom[roomID] = agreed
        } else if claims.isEmpty,
                  compositionTransportByRoom[roomID] == .bridgeStored,
                  roomHasBridgeStoredEvidence(
                      roomID: roomID, excluding: retainedManifestIDs) {
            // Fail closed: keep the label.
        } else {
            compositionTransportByRoom.removeValue(forKey: roomID)
        }
    }

    /// Any bridge-stored evidence still standing for this room id (round 4c's
    /// "nothing anywhere still claims the room" proof, shared by the aggregate
    /// retention above and `withdrawDestroyedBridgeStoredClaims`).
    private func roomHasBridgeStoredEvidence(
        roomID: String, excluding retainedManifestIDs: Set<UUID> = []
    ) -> Bool {
        recoveredBridgeAnimations.values.contains { $0.manifest.roomID == roomID }
            || bridgeAnimationStore.allManifests().contains {
                $0.roomID == roomID && !retainedManifestIDs.contains($0.id)
            }
    }

    // ── Exact bridge-stored chain ownership (round 4c) ───────────────────
    //
    // `compositionTransportByRoom` is roomID-keyed AGGREGATE state: two
    // bridges using the same room id share one entry, so it can never say
    // WHICH bridge's chain a room is claiming. This ledger can. It is THE
    // destructive-ownership evidence — predecessor proof, replacement
    // cleanup, and `previousLookRemovedSaveFailed` read it, never the
    // transport map.

    /// The bridge-stored chains currently standing as a room's RUNNING claim,
    /// per exact bridge. Only a chain confirmed running (save commit, ordinary
    /// play commit) or recovered as ACTIVE (reconciliation) enters; a
    /// saved-but-not-confirmed-running manifest is inert and never does.
    @ObservationIgnored
    private var bridgeStoredChainOwnership: [BridgeNativeOwnershipKey: Set<UUID>] = [:]

    /// Record a confirmed-running chain as the room's claim on this bridge.
    /// Round 4e: the exact `.bridgeStored` transport claim moves WITH the
    /// ledger — the first confirmed-running manifest for a bridge+room raises
    /// it (idempotent for later ones), and only the set emptying lowers it.
    private func recordBridgeStoredChainOwnership(
        bridgeID: String, roomID: String, manifestID: UUID
    ) {
        let key = BridgeNativeOwnershipKey(bridgeKey: bridgeID, roomID: roomID)
        bridgeStoredChainOwnership[key, default: []].insert(manifestID)
        setCompositionTransportClaim(
            .bridgeStored,
            for: CompositionPlaybackKey(bridgeKey: key.bridgeKey, roomID: key.roomID))
    }

    /// Subtract exactly one destroyed chain's identity, wherever it is
    /// recorded. Manifest ids are globally unique, so this is exact without
    /// needing the bridge to resolve at destruction time; a key survives
    /// while any OTHER recorded chain remains and disappears only when its
    /// set empties.
    private func subtractBridgeStoredChainOwnership(manifestID: UUID) {
        for (key, var owned) in bridgeStoredChainOwnership where owned.contains(manifestID) {
            owned.remove(manifestID)
            if owned.isEmpty {
                bridgeStoredChainOwnership.removeValue(forKey: key)
                // Round 4e: the exact bridge+room ownership set emptied — this
                // key's `.bridgeStored` transport claim falls with it (and
                // ONLY a bridge-stored claim: a REST/Entertainment claim on
                // the same key belongs to a different, live playback).
                let playbackKey = CompositionPlaybackKey(
                    bridgeKey: key.bridgeKey, roomID: key.roomID)
                if compositionTransportClaims[playbackKey] == .bridgeStored {
                    removeCompositionTransportClaim(for: playbackKey)
                }
            } else {
                bridgeStoredChainOwnership[key] = owned
            }
        }
    }
    /// EVERY entertainment config on a bridge, keyed by bridgeID.
    ///
    /// This used to hold one config per bridge — whichever the bridge happened to
    /// list first — which is how a Bedroom composition could stream into the
    /// Living Room's area. Selection is now a room-aware decision taken over the
    /// whole inventory at read time (`selectedEntertainmentConfig(for:)`), so the
    /// cache must keep all of it.
    ///
    /// Key absent = never fetched (or the fetch failed). Empty array = fetched,
    /// and the bridge genuinely has no areas.
    var entertainmentConfigsByBridge: [String: [EntertainmentConfig]] = [:]

    /// entertainmentServiceID → lightID, per bridge — the resolved membership map.
    ///
    /// Entertainment channel members reference *entertainment* services, not lights
    /// (see `EntertainmentAreaSelector`), so this join is what makes room-aware
    /// selection possible at all. It is warmed alongside the configs and read
    /// synchronously by availability.
    ///
    /// Key absent = unknown or a failed fetch. `[:]` = successfully computed and
    /// genuinely empty. The difference decides whether the UI may say no.
    var entertainmentMembershipByBridge: [String: [String: String]] = [:]

    /// Bridges whose entertainment configs we have **successfully** fetched.
    /// Assigning nil into `entertainmentConfigsByBridge` *removes* the key, so
    /// the dictionary alone cannot tell "this bridge has no area" apart from
    /// "we never looked" — and the difference decides whether the UI may say no.
    /// A fetch that throws or fails to decode must NOT insert here, or a bridge
    /// that times out reports "this bridge has no entertainment area yet".
    var entertainmentConfigsFetchedBridges: Set<String> = []

    /// The Entertainment Area that safely belongs to this room, or nil.
    ///
    /// Synchronous and cache-only — safe inside a menu builder or a view body.
    /// Returns nil (→ clean REST fallback) whenever the caches are not warm
    /// enough to answer, or no area safely matches. See `EntertainmentAreaSelector`
    /// for the selection contract.
    func selectedEntertainmentConfig(
        for room: RoomDisplayItem?,
        preferredConfigID: String? = nil
    ) -> EntertainmentConfig? {
        guard let room,
              let bridgeID = room.bridgeID,
              let configs = entertainmentConfigsByBridge[bridgeID], !configs.isEmpty,
              let membership = entertainmentMembershipByBridge[bridgeID],
              let roomLightIDs = cachedRoomLightIDs(for: room)
        else { return nil }

        return EntertainmentAreaSelector.select(
            roomLightIDs: roomLightIDs,
            configs: configs,
            entertainmentToLightMap: membership,
            preferredConfigID: preferredConfigID
        )
    }

    /// Convenience: the entertainment config that belongs to this room.
    /// Used to return whatever config the room's *bridge* had cached, which is
    /// the wrong-room defect; it now resolves through the room-aware selector.
    func activeEntertainmentConfig(for room: RoomDisplayItem?) -> EntertainmentConfig? {
        selectedEntertainmentConfig(for: room)
    }

    /// The room's light IDs from cache, or nil when we cannot answer yet.
    ///
    /// Nil for BOTH "no raw-light cache for this bridge" and "the refs resolved to
    /// nothing" — `preloadCached` builds rooms with empty `childResourceRefs`, so an
    /// empty resolution means "we don't know yet", never "this room matches no area".
    /// Reporting a definite no from a cold cache would disable a transport that
    /// works, which is the failure mode `EntertainmentAvailability` exists to avoid.
    private func cachedRoomLightIDs(for room: RoomDisplayItem) -> Set<String>? {
        guard let lights = cachedRawLights(for: room.bridgeID), !lights.isEmpty else { return nil }
        let ids = Set(CompositionLightResolver.resolveLightIDs(
            childResourceRefs: room.childResourceRefs,
            lights: lights
        ))
        return ids.isEmpty ? nil : ids
    }

    // MARK: - Entertainment availability
    //
    // Until now the only way to discover that a room could not stream was to
    // start an effect and watch it silently demote to REST. The transport menu
    // offered "Entertainment Area" whether or not the bridge could honour it.
    // These let the UI say so up front, and say *why*.

    enum EntertainmentAvailability: Equatable {
        case available(areaName: String)
        /// The bridge was paired without an entertainment client key. Nothing
        /// to do about it in-app: it needs a re-pair.
        case noClientKey
        /// The bridge has no entertainment area defined. The user can make one.
        case noArea
        /// The bridge HAS areas, but none of them safely covers this room — or the
        /// one that does cannot actually be streamed. Distinct from `noArea` on
        /// purpose: telling someone with three areas that they have none is a lie,
        /// and it sends them to build a fourth.
        case noMatchingArea
        /// Several areas could serve this room and only the user can say which
        /// (hardware convergence slice A). Streaming absolutely works here —
        /// reporting it as `noMatchingArea` was the defect: a bridge with an
        /// area over bedroom+bathroom and another over bedroom+hallway told the
        /// user that hallway and bathroom had no compatible area at all.
        case choiceRequired(count: Int)
        case noBridge
        /// We have not asked the bridge yet. Offer streaming rather than
        /// wrongly disabling it — `startCompositionMode` still falls back.
        case unknown

        /// Whether the transport option should be offered as usable.
        var canStream: Bool {
            switch self {
            case .available, .unknown, .choiceRequired: return true
            case .noClientKey, .noArea, .noMatchingArea, .noBridge: return false
            }
        }

        /// Why streaming is unavailable, in a sentence a user can act on.
        var reason: String? {
            switch self {
            case .available, .unknown:
                return nil
            case .choiceRequired(let count):
                // Not a refusal — an invitation. The row stays usable and the
                // start path opens the chooser.
                return "\(count) Entertainment Areas could cover this room. You'll be asked which one to use."
            case .noClientKey:
                return "This bridge was paired without streaming access. Re-pair it in Settings to enable Entertainment."
            case .noArea:
                return "This bridge has no entertainment area yet."
            case .noMatchingArea:
                // Covers both causes — no area contains this room's lights, and an
                // area that does but cannot be streamed — so it stays true either way.
                return "No Entertainment Area can safely stream to this room. Create or update an area for this room."
            case .noBridge:
                return "This room isn't on a reachable bridge."
            }
        }
    }

    /// Synchronous — safe to call while a menu is being built. Reads the
    /// Keychain and the config caches; never touches the network.
    ///
    /// The order of the rungs is the honesty contract. We only ever say a definite
    /// no when we actually know; every partial or failed cache answers `.unknown`,
    /// which still offers streaming and lets the start path fall back. Saying
    /// "no area" for a bridge that has three, or for one that merely timed out, is
    /// worse than a fallback the user never notices.
    func entertainmentAvailability(for room: RoomDisplayItem?) -> EntertainmentAvailability {
        guard let room, let bridgeID = room.bridgeID, hueClient(for: bridgeID) != nil else { return .noBridge }
        guard KeychainManager.shared.loadClientKey(for: bridgeID) != nil else { return .noClientKey }

        // Never asked, or the first ask failed.
        guard entertainmentConfigsFetchedBridges.contains(bridgeID),
              let configs = entertainmentConfigsByBridge[bridgeID] else { return .unknown }
        // Asked and answered: the bridge really has nothing.
        guard !configs.isEmpty else { return .noArea }
        // Membership absent means a failed or missing fetch — not "known empty".
        guard entertainmentMembershipByBridge[bridgeID] != nil else { return .unknown }
        // Room lights not resolvable yet — cold cache, not a verdict.
        guard cachedRoomLightIDs(for: room) != nil else { return .unknown }

        // The typed decision, not the optional. `select` answering nil covers
        // both "nothing here fits" and "several things fit and one of them is
        // yours to pick"; only the first is a refusal.
        switch cachedAreaDecision(for: room) {
        case .exact(let config):            return .available(areaName: config.name)
        case .choiceRequired(let options):  return .choiceRequired(count: options.count)
        case .noCompatible, .none:          return .noMatchingArea
        }
    }

    /// The exact-target decision from cache alone — synchronous, no network.
    ///
    /// Nil only when the caches cannot answer at all; the rungs above have
    /// already separated that from a real verdict.
    ///
    /// An EMPTY inventory is an answer, not a gap — the key being present is
    /// what says the bridge was asked and replied "none". Requiring
    /// `!configs.isEmpty` here would report a bridge with no areas as
    /// unreadable, turning an honest Room-mode fallback into a refusal.
    func cachedAreaDecision(
        for room: RoomDisplayItem?,
        selectedConfigID: String? = nil
    ) -> EntertainmentAreaSelector.ExactAreaDecision? {
        guard let room,
              let bridgeID = room.bridgeID,
              let configs = entertainmentConfigsByBridge[bridgeID],
              let membership = entertainmentMembershipByBridge[bridgeID],
              let roomLightIDs = cachedRoomLightIDs(for: room)
        else { return nil }

        return EntertainmentAreaSelector.decide(
            roomLightIDs: roomLightIDs,
            configs: configs,
            entertainmentToLightMap: membership,
            preferredConfigID: selectedConfigID
        )
    }

    /// Warms the entertainment caches for a room's bridge so
    /// `entertainmentAvailability` can stop answering `.unknown`.
    func refreshEntertainmentConfigs(for room: RoomDisplayItem?) async {
        await warmEntertainmentCaches(for: room)
    }

    /// Forget everything we believe about one bridge's entertainment inventory
    /// (packet 7 follow-up).
    ///
    /// The defect: creating, renaming, or deleting an area inside ChromaGlow's
    /// own Entertainment Areas screen left these caches holding the inventory
    /// from before the edit, and `entertainmentAvailability` answers from them
    /// synchronously — so a freshly created area still read as "this bridge has
    /// no entertainment area yet" and a force-quit was the only way to clear it.
    /// Dropping all three keys returns the bridge to honest `.unknown`, which
    /// still offers streaming and re-asks on the next warm.
    func invalidateEntertainmentCaches(forBridge bridgeID: String) {
        entertainmentConfigsByBridge.removeValue(forKey: bridgeID)
        entertainmentMembershipByBridge.removeValue(forKey: bridgeID)
        entertainmentConfigsFetchedBridges.remove(bridgeID)
    }

    /// Fetch whatever this bridge's entertainment caches are missing.
    ///
    /// Three components complete independently — the config inventory, the
    /// entertainment→light membership map, and the bridge's raw lights — so a
    /// partial success must never lock out a retry of the missing part. A single
    /// "did we fetch this bridge" flag would strand a bridge whose configs
    /// arrived but whose membership request failed: availability would sit on
    /// `.unknown` forever and no ordinary refresh would ever try again.
    ///
    /// `force: false` fetches only what is missing. `force: true` refreshes
    /// everything, but each component keeps its own last-known-good value if its
    /// refresh fails — a later failure never replaces valid configs with `[]` nor
    /// removes a valid membership map.
    func warmEntertainmentCaches(for room: RoomDisplayItem?, force: Bool = false) async {
        guard let bridgeID = room?.bridgeID,
              let api = hueClient(for: bridgeID),
              KeychainManager.shared.loadClientKey(for: bridgeID) != nil,
              let (ip, token) = try? api.credentials()
        else { return }

        let cachedLights = cachedRawLights(for: bridgeID)
        let needsConfigs = force || !entertainmentConfigsFetchedBridges.contains(bridgeID)
        let needsMembership = force || entertainmentMembershipByBridge[bridgeID] == nil
        let needsLights = force || cachedLights == nil || cachedLights?.isEmpty == true
        guard needsConfigs || needsMembership else { return }

        // Everything the child tasks touch is hoisted first: `api` is a Sendable
        // class and `manager` is a local value, so nothing reaches back into
        // MainActor state from inside the concurrent work.
        let manager = EntertainmentConfigManager()

        async let configsFetch: [EntertainmentConfig]? =
            needsConfigs ? (try? await manager.fetchConfigs(client: api)) : nil
        async let entServicesFetch: Data? =
            needsMembership
            ? (try? await api.get(path: "/clip/v2/resource/entertainment", ip: ip, token: token))
            : nil
        // Fetched whenever they are missing: the room-light resolution that
        // availability depends on reads the same cache, so a bridge whose
        // `loadAll` failed would otherwise never become answerable.
        async let lightsFetch: [HueLight]? =
            needsLights ? (try? await api.fetchLights()) : nil

        let fetchedConfigs = await configsFetch
        let entServicesData = await entServicesFetch
        let fetchedLights = await lightsFetch

        // Lights first — membership and room resolution both read them.
        if let fetchedLights, !fetchedLights.isEmpty {
            seedRawLightCache(bridgeID: bridgeID, lights: fetchedLights)
        }
        let lightsForMapping = fetchedLights ?? cachedRawLights(for: bridgeID) ?? []

        if let fetchedConfigs {
            entertainmentConfigsByBridge[bridgeID] = fetchedConfigs
            entertainmentConfigsFetchedBridges.insert(bridgeID)
        }
        // A failed configs fetch deliberately leaves the previous inventory and
        // the fetched marker alone: a transient error must not demote a bridge
        // we already know the answer for to "no area".

        if let entServicesData, !lightsForMapping.isEmpty {
            entertainmentMembershipByBridge[bridgeID] = EntertainmentAreaSelector.entertainmentToLightMap(
                entertainmentServiceOwners: EntertainmentAreaSelector.entertainmentServiceOwners(from: entServicesData),
                lights: lightsForMapping
            )
        }
        // Likewise: if the entertainment-service GET failed, or we still have no
        // lights to join against, the key stays as it was — absent (unknown) or
        // the last good map. It is never overwritten with an empty one.
    }

    /// Live param reference — StudioViewModel updates this dict, engine loops read it.
    /// Using a class wrapper so the Task closure captures a reference, not a copy.
    final class StudioParamBox: @unchecked Sendable {
        var values: [String: Double]
        var colors: [String: Color]
        init(values: [String: Double], colors: [String: Color]) {
            self.values = values
            self.colors = colors
        }
    }
    // Round 4g: the live box lives inside `studioEngineRuntimesByBridge`, so
    // param edits are routed to the EXACT bridge's engine. The box itself
    // stays @unchecked Sendable — engine loops keep reading it per frame from
    // their own tasks under its documented cross-actor-write contract.

    /// Update live params while an engine is running (called by StudioViewModel
    /// on slider change). With two bridges streaming at once, a slider edit
    /// follows the SELECTED room's bridge instead of whichever engine started
    /// last. Isolated (both this type and the caller are @MainActor), so the
    /// map read is safe and the call stays synchronous.
    ///
    /// Slice 2 production wiring: the write must ALSO name the room, and the
    /// runtime's owning room must match — the same guard the stop path has
    /// carried since round 4g. A bridge-only guard let a write authored on one
    /// room land on a sibling room's engine on the same bridge after the
    /// selection moved. The caller has already fenced on the full running
    /// identity (bridge + group + kind + look + generation); this room check
    /// is the orchestrator's own defense in depth, not the primary fence.
    func updateStudioParams(values: [String: Double], colors: [String: Color],
                            bridgeID: String?, roomID: String) {
        guard let runtime = studioEngineRuntimesByBridge[bridgeID ?? ""],
              runtime.roomID == roomID else { return }
        runtime.paramBox.values = values
        runtime.paramBox.colors = colors
    }

    /// Studio engine keys that stream over Entertainment. Only these can
    /// collide with another controller; the rest never open a session.
    static func studioEngineStreams(_ key: String) -> Bool {
        key == "strobe" || key == "party" || key == "thunderstorm"
    }

    @discardableResult
    func startStudioMode(
        key: String,
        room: RoomDisplayItem,
        params: [String: Double],
        colors: [String: Color],
        capturedPlan: EntertainmentTakeoverPlan? = nil,
        consent: EntertainmentConsent? = nil,
        preparedEntertainment: EntertainmentPreparation? = nil
    ) async -> PlaybackStartOutcome {
        // Same net as `apply`, scoped to THIS transaction's candidate: a
        // candidate that never reaches commit is stopped on the way out,
        // whichever exit is taken, and a concurrent start's candidate is never
        // touched. The defer reads the variable at scope exit, so it names
        // whatever this transaction actually prepared.
        var outstandingCandidateID: UUID?
        defer {
            if let outstandingCandidateID {
                rollbackUncommittedEntertainment(candidateID: outstandingCandidateID)
            }
        }

        // ── PREPARE ─────────────────────────────────────────────
        //
        // Resolve the room and acquire the session BEFORE touching anything.
        // A guard is not destructive, and failing one after a teardown used to
        // leave the user with the old look stopped and no new one started.
        guard let api = hueClient(for: room.bridgeID),
              let groupedLightID = room.groupedLightID else {
            return .failed(message: EntertainmentConsentCopy.bridgeUnreadable)
        }

        // The whole streaming acquisition happens here, while the previous
        // look is still running and every scope, task, and registry entry is
        // still intact. A third party discovered on the way out therefore
        // costs the user nothing: we return and they keep watching what they
        // were watching.
        var prepared: PreparedEntertainment?
        if Self.studioEngineStreams(key) {
            let preparation: EntertainmentPreparation
            if let preparedEntertainment {
                preparation = preparedEntertainment
            } else {
                preparation = await prepareEntertainment(for: room,
                                                         requestsEntertainment: true,
                                                         plan: capturedPlan,
                                                         consent: consent,
                                                         requester: .studio)
            }
            switch preparation {
            case .prepared(let candidate):
                prepared = candidate
                outstandingCandidateID = candidate.id
            case .needsForeignConsent(let snapshot, let targetConfigID):
                debugLog("[Handoff] '\(key)' needs a bridge another app is using — nothing torn down")
                return .needsForeignConsent(snapshot: snapshot, targetConfigID: targetConfigID)
            case .failed(let message):
                return .failed(message: message)
            case .heldByAnotherLook:
                // Structurally unreachable: `.studio` requesters are exempt
                // from the self-conflict refusal, precisely because the COMMIT
                // block below evicts this engine's own previous session.
                // Handled exhaustively anyway — a future requester change must
                // not silently fall into the room-mode arm.
                return .failed(message: EntertainmentHandoffCopy.alreadyStreaming)
            case .notNeeded, .unavailable:
                // No streamable area, or a genuine technical inability. Room
                // mode is the honest answer and the teardown below is fine.
                break
            }
        }

        // ── COMMIT ──────────────────────────────────────────────
        //
        // Past this line the start is going ahead, so destruction is safe —
        // and scoped to THIS room's bridge (round 4g). One engine per bridge
        // is the real constraint: starting on bridge 2 must not cancel bridge
        // 1's loop, clear its scope, or stop its session.
        let stopBid = room.bridgeID ?? ""
        if let previous = studioEngineRuntimesByBridge.removeValue(forKey: stopBid) {
            previous.task.cancel()
            // The same-bridge engine eviction the apply route already names
            // (`applyEngineSingleton`) but that no recorder ever observed: the
            // ViewModel's pre-stop loop only covers rooms in `runningEffects`,
            // so THIS eviction — the orchestrator's own — was unaudited.
            // Recorded after the cancel, so ordering is unchanged, and wrapped
            // whole: `recordStopAudit`'s body is DEBUG-only but its arguments
            // are not, and `stopAuditToken` would otherwise hash and allocate
            // in Release for a value that is immediately discarded.
            #if DEBUG
            recordStopAudit(StopAuditContext(route: .applyEngineSingleton,
                                             cardOrEffectID: key),
                            operation: .taskCancelled,
                            bridgeID: room.bridgeID, roomID: previous.roomID,
                            runtimeToken: Self.stopAuditToken(previous.paramBox))
            #endif
        }
        // Clear THIS bridge's previously recorded Studio scope and forget it —
        // even when the new card targets a different room on it. Clearing only
        // the incoming room would be the bug: a same-bridge room A -> room B
        // switch would leave room A's epoch valid and its already-queued
        // batches legal, and room A would keep writing over room B.
        await clearStudioRestScope(bridgeKey: room.bridgeID ?? "legacy")
        if let entClient = studioEntClients[stopBid], entClient !== prepared?.client {
            await entClient.stopSession()
            studioEntClients.removeValue(forKey: stopBid)
            // The record dies with the session it described. Leaving it behind
            // is what would let `studioOwningEntertainment` name a look that is
            // no longer streaming.
            studioEntOwnerByBridge.removeValue(forKey: stopBid)
        }
        // The final verification runs HERE, immediately before the commit —
        // after the eviction awaits above, so nothing can claim the bridge
        // between what was verified and what gets installed. A candidate that
        // fails it is already released; `committed` (not `prepared`) is what
        // the engine start below may use.
        var committed: PreparedEntertainment?
        if let prepared {
            switch await verifyAndCommitEntertainment(prepared) {
            case .committed:
                committed = prepared
                // Record WHOSE session this is, in the same breath as
                // installing it. Written from the committed plan rather than
                // a re-selection, so the recorded area is exactly the one
                // that was opened.
                studioEntOwnerByBridge[prepared.plan.bridgeID] = StudioEntertainmentOwner(
                    bridgeID: prepared.plan.bridgeID,
                    roomID: room.id,
                    engineKey: key,
                    configID: prepared.plan.targetConfigID
                )
            case .contested(let snapshot, let targetConfigID):
                // A proven foreign owner at the commit boundary. Starting the
                // REST engine underneath their show is exactly the quiet
                // overplay this flow exists to prevent — refuse and re-ask.
                studioEntOwnerByBridge.removeValue(forKey: stopBid)
                return .needsForeignConsent(snapshot: snapshot, targetConfigID: targetConfigID)
            case .verificationUnavailable:
                // Unknown is not verified. Nothing starts on a bridge whose
                // final state nobody saw — and no fallback, for the same
                // reason release-not-proven gets none.
                studioEntOwnerByBridge.removeValue(forKey: stopBid)
                return .failed(message: EntertainmentConsentCopy.bridgeUnreadable)
            case .releaseNotProven:
                // The target may STILL be streaming. REST writes underneath
                // an unreleased stream is the exact condition this flow
                // refuses everywhere else — start nothing, say so.
                studioEntOwnerByBridge.removeValue(forKey: stopBid)
                return .failed(message: EntertainmentAvailabilityCopy.couldNotStart)
            case .sessionFailed:
                // Observed dead and stayed down. The explicit refusal, not a
                // silent transport change (round 4) — the user asked to
                // stream, and "couldn't start, nothing changed" is the
                // honest answer.
                studioEntOwnerByBridge.removeValue(forKey: stopBid)
                return .failed(message: EntertainmentAvailabilityCopy.couldNotStart)
            }
        } else {
            // No prepared session means the engine is running on REST. An
            // engine on REST owns no Entertainment session, so any record
            // naming it here would be a claim to something it does not hold.
            studioEntOwnerByBridge.removeValue(forKey: stopBid)
        }

        // 5. Record the new owner BEFORE its first REST enqueue, so any later
        // start/stop can find and invalidate it.
        let studioRoomID = room.id
        let studioBridgeID = room.bridgeID
        studioRestScopesByBridge[studioBridgeID ?? "legacy"] =
            RestScope(roomID: studioRoomID, owner: .studio)
        noteRoomOwnershipChange(bridgeID: studioBridgeID, roomID: studioRoomID)

        // Create live param box (engine loop reads from this; the ViewModel
        // updates it through the bridge-keyed runtime installed below).
        let paramBox = StudioParamBox(values: params, colors: colors)

        // Every Entertainment-capable engine below warms this bridge's caches
        // itself rather than trusting that some UI surface already did. A Studio
        // card can be tapped without ever opening Composer or the transport menu,
        // and a cold cache would silently demote the card to REST forever.
        switch key {
        case "strobe", "party", "thunderstorm":
            await warmEntertainmentCaches(for: room, force: true)
        default:
            break
        }

        // The streaming engines share one shape: try Entertainment, and fall
        // back to REST only for a genuine technical inability. A foreign
        // conflict surfacing here (someone started streaming during our own
        // setup) must NOT become a quiet REST fallback — that would play over
        // their show instead of asking.
        // The session was acquired during PREPARE, so this only installs the
        // render loop. There is no second selection here to disagree with the
        // first: the channel ids come from the captured plan.
        func startStreamingEngine(
            entertainment: (HueEntertainmentClient, [UInt8]) -> Task<Void, Never>,
            rest: () -> Task<Void, Never>
        ) -> PlaybackStartOutcome {
            if let committed {
                studioEngineRuntimesByBridge[stopBid] = StudioEngineRuntime(
                    roomID: studioRoomID,
                    task: entertainment(committed.client, committed.channelIDs),
                    paramBox: paramBox)
                return .started(transport: .entertainment)
            }
            studioEngineRuntimesByBridge[stopBid] = StudioEngineRuntime(
                roomID: studioRoomID, task: rest(), paramBox: paramBox)
            return .started(transport: .rest)
        }

        switch key {
        case "strobe":
            // Try entertainment first for crisp on/off, fall back to REST
            return startStreamingEngine(
                entertainment: { entClient, channelIDs in
                    Task {
                        await self.runStrobeEntertainment(entClient: entClient, channelIDs: channelIDs, paramBox: paramBox)
                        await self.reconcileStudioSessionAfterLoop(
                            entClient: entClient, bridgeID: studioBridgeID, roomID: studioRoomID)
                    }
                },
                rest: {
                    Task { await self.runStrobeREST(roomID: studioRoomID, bridgeID: studioBridgeID, api: api, groupedLightID: groupedLightID, paramBox: paramBox) }
                }
            )

        case "party":
            return startStreamingEngine(
                entertainment: { entClient, channelIDs in
                    Task {
                        await self.runPartyEntertainment(entClient: entClient, channelIDs: channelIDs, paramBox: paramBox)
                        await self.reconcileStudioSessionAfterLoop(
                            entClient: entClient, bridgeID: studioBridgeID, roomID: studioRoomID)
                    }
                },
                rest: {
                    Task { await self.runPartyREST(roomID: studioRoomID, bridgeID: studioBridgeID, api: api, groupedLightID: groupedLightID, paramBox: paramBox) }
                }
            )

        case "thunderstorm":
            return startStreamingEngine(
                entertainment: { entClient, channelIDs in
                    Task {
                        await self.runThunderstormEntertainment(entClient: entClient, channelIDs: channelIDs, paramBox: paramBox)
                        await self.reconcileStudioSessionAfterLoop(
                            entClient: entClient, bridgeID: studioBridgeID, roomID: studioRoomID)
                    }
                },
                rest: {
                    Task { await self.runThunderstormREST(roomID: studioRoomID, bridgeID: studioBridgeID, api: api, groupedLightID: groupedLightID, paramBox: paramBox) }
                }
            )

        case "ambient":
            // Ambient is slow enough for REST (one change every few seconds)
            studioEngineRuntimesByBridge[stopBid] = StudioEngineRuntime(
                roomID: studioRoomID,
                task: Task {
                    await runAmbientREST(roomID: studioRoomID, bridgeID: studioBridgeID, api: api, groupedLightID: groupedLightID, paramBox: paramBox)
                },
                paramBox: paramBox)
            return .started(transport: .rest)

        default:
            let brightness = params["brightness"] ?? 80
            try? await api.setGroupedLightBrightness(id: groupedLightID, brightness: brightness)
            return .started(transport: .oneShot)
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Composition Engine
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private func anyCompositionNeedsMic() -> Bool {
        // R7 demand split: `.beat` needs no mic while a music service drives
        // the clock. Per-frame refresh means a drive starting/ending flips
        // demand within a frame — no extra plumbing.
        let serviceDriven = BeatClock.shared.isServiceDriven
        if compositionRuntimes.values.contains(where: {
            $0.paramBox.reaction.needsMicNow(serviceDriven: serviceDriven)
        }) {
            return true
        }
        // A mic-reactive preset cued on Perform's deck B isn't a runtime box
        // yet — it must still raise demand or it reads silence until promoted.
        if let mix = activePerformanceMix,
           mix.deckB?.reaction.needsMicNow(serviceDriven: serviceDriven) == true {
            return true
        }
        return compositionEntParamBoxes.values.contains {
            $0.reaction.needsMicNow(serviceDriven: serviceDriven)
        }
    }

    /// Last mic-demand value pushed to the audio engine. The composition render loops
    /// call refreshCompositionMicDemand every frame (up to 25Hz), but demand almost
    /// never changes frame-to-frame — skip the actor hop + Set mutation when unchanged.
    @ObservationIgnored private var lastComposerMicDemand: Bool?

    private func refreshCompositionMicDemand() async {
        let needed = anyCompositionNeedsMic()
        guard needed != lastComposerMicDemand else { return }
        lastComposerMicDemand = needed
        await AudioAnalysisEngine.shared.setDemand(.composerReaction, active: needed)
    }

    /// Start a composition render loop for the given room.
    /// Transport priority:
    ///   1. Bridge-stored (v1 rules chain) — if preset is eligible, upload to bridge. Close app, lights keep going.
    ///   2. Entertainment API (DTLS 25fps) — if entertainment area exists.
    ///   3. Per-light REST (~10 PUTs/sec) — fallback with per-light color variation.
    @discardableResult
    func startCompositionMode(
        room: RoomDisplayItem,
        paramBox: CompositionParamBox,
        gamutOverride: HueColorUtils.Gamut? = nil,
        preferEntertainment: Bool = true,
        tier: CompositionTier = .runtimeOnly,
        preset: CompositionPreset? = nil,
        capturedPlan: EntertainmentTakeoverPlan? = nil,
        consent: EntertainmentConsent? = nil,
        preparedEntertainment: EntertainmentPreparation? = nil
        // Round 4: there is deliberately NO strict-save mode here any more.
        // An explicit Save to Bridge never enters this function — it runs
        // `attemptBridgeStoredSave` directly, after its own zero-mutation
        // preflight — because everything below this signature (the generation
        // bump, the telemetry session, the ownership note) replaces the
        // room's CURRENT look, and a save that fails must leave that look
        // exactly as it found it.
    ) async -> PlaybackStartOutcome {
        // Scoped to THIS transaction's candidate — see startStudioMode.
        var outstandingCandidateID: UUID?
        defer {
            if let outstandingCandidateID {
                rollbackUncommittedEntertainment(candidateID: outstandingCandidateID)
            }
        }

        guard let api = hueClient(for: room.bridgeID),
              let groupedLightID = room.groupedLightID else {
            return .failed(message: EntertainmentConsentCopy.bridgeUnreadable)
        }

        // ── PREPARE ─────────────────────────────────────────────
        //
        // Acquire the session before ANY bookkeeping moves. Everything below —
        // the generation bump, the telemetry session, microphone demand,
        // spatial data, the parameter box — is state the user's current look
        // depends on, so a composition that must ask first has to leave the
        // room exactly as it found it.
        var preparedComposition: PreparedEntertainment?
        if preferEntertainment, let bridgeID = room.bridgeID,
           canAcquireEntertainment(onBridge: bridgeID) {
            let preparation: EntertainmentPreparation
            if let preparedEntertainment {
                preparation = preparedEntertainment
            } else {
                preparation = await prepareEntertainment(for: room,
                                                         requestsEntertainment: true,
                                                         plan: capturedPlan,
                                                         consent: consent,
                                                         requester: .composition)
            }
            switch preparation {
            case .prepared(let candidate):
                preparedComposition = candidate
                outstandingCandidateID = candidate.id
            case .needsForeignConsent(let snapshot, let targetConfigID):
                debugLog("[Handoff] Composition needs bridge \(bridgeID), which another app is using — nothing mutated")
                return .needsForeignConsent(snapshot: snapshot, targetConfigID: targetConfigID)
            case .failed(let message):
                return .failed(message: message)
            case .heldByAnotherLook:
                // One of our own app-driven looks is streaming this bridge.
                // Refuse the whole start rather than dropping to the room-mode
                // path below: REST writes here would land underneath a live
                // 25 fps stream and do nothing visible at all. Nothing has been
                // mutated yet, so the running look is untouched.
                debugLog("[Handoff] Composition refused bridge \(bridgeID) — a ChromaGlow look already streams it")
                return .failed(message: EntertainmentHandoffCopy.alreadyStreaming)
            case .notNeeded, .unavailable:
                break
            }
        }

        let roomID = room.id
        // Round 4e: the EXACT playback identity every runtime structure below
        // is keyed by — bridge+room, "legacy" normalization, same convention as
        // the telemetry key. Two bridges sharing a room id are two playbacks.
        let playbackKey = CompositionPlaybackKey(bridgeID: room.bridgeID, roomID: roomID)
        let nextGeneration = (compositionGenerations[playbackKey] ?? 0) + 1
        compositionGenerations[playbackKey] = nextGeneration
        // Packet 4: telemetry session identity is established HERE, from
        // nextGeneration directly — no CompositionRuntime required, so stop can
        // find this session even when the transport decision below lands on
        // Entertainment or bridge-stored and no REST runtime ever exists.
        // Key = the room's ORIGINAL optional bridge identity, normalized
        // exactly like restSender(for:). The session starts NOT-REST-active;
        // only the REST-runtime installation below flips it.
        let composerTelemetryKey = ComposerTelemetrySessionKey(
            bridgeKey: room.bridgeID ?? "legacy",
            scope: RestScope(roomID: roomID, owner: .composer))
        beginComposerTelemetrySession(
            sessionKey: composerTelemetryKey, generation: nextGeneration)
        noteRoomOwnershipChange(bridgeID: room.bridgeID, roomID: roomID)
        let startNeedsMic = paramBox.reaction.needsMicNow(
            serviceDriven: BeatClock.shared.isServiceDriven)
        let compositionGamut: HueColorUtils.Gamut
        if let gamutOverride {
            compositionGamut = gamutOverride
            if startNeedsMic {
                await AudioAnalysisEngine.shared.setDemand(.composerReaction, active: true)
                lastComposerMicDemand = true   // keep the per-frame refresh cache coherent
            }
        } else if startNeedsMic {
            async let gamutResolved = resolveCompositionGamut(for: room, api: api)
            async let micHeadStart: Bool = AudioAnalysisEngine.shared.setDemand(.composerReaction, active: true)
            _ = await micHeadStart
            lastComposerMicDemand = true   // keep the per-frame refresh cache coherent
            compositionGamut = await gamutResolved
        } else {
            compositionGamut = await resolveCompositionGamut(for: room, api: api)
        }
        debugLog(
            "[Composer] ▶ Start composition room='\(room.name)' id=\(roomID) gen=\(nextGeneration) groupedLightID=\(groupedLightID) preferEntertainment=\(preferEntertainment)"
        )

        // ── Select this ROOM's entertainment area BEFORE the transport decision ──
        // Both REST and DTLS paths benefit from spatial positions. The warm keeps
        // the inventory and the membership map current (an area edited in the Hue
        // app is picked up here); selection then happens once, from cache.
        await warmEntertainmentCaches(for: room, force: true)
        let entConfig = selectedEntertainmentConfig(for: room)

        // Resolve individual light IDs early — needed for REST spatial positions
        // AND for per-light REST mode later.
        let lightResolution = await resolveCompositionLights(for: room, api: api)
        let compositionLightIDs = lightResolution.lightIDs
        debugLog("[Composer] 🔍 Resolved \(compositionLightIDs.count) individual lights for per-light REST")

        if let entConfig {
            // Auto-detect principal angle when user hasn't set one
            if paramBox.motion.motionAngle < 0 {
                paramBox.motion.motionAngle = CompositionEngine.principalAngle(channels: entConfig.channels)
            }

            // ── Build lightID → position map ──
            // Entertainment channel members point to entertainment services (not light services).
            // Bridge the IDs: entertainment_service → device → light, from the map
            // the warm above already resolved for this bridge.
            let lightPositions = resolveEntertainmentLightPositions(
                config: entConfig, bridgeID: room.bridgeID
            )

            // Pre-compute spatial positions for REST path (lightID order)
            let restPositions = CompositionEngine.computeSpatialPositions(
                lightPositions: lightPositions,
                orderedLightIDs: compositionLightIDs,
                motionAngle: paramBox.motion.motionAngle
            )
            if !restPositions.isEmpty {
                paramBox.spatialPositions = restPositions
                paramBox.targetSpatialPositions = restPositions
                paramBox.spatialLerpProgress = 1.0
            }
            // Radial + angular geometry for the pulseCenter/spiral patterns
            // (REST light order; the DTLS branch overrides in channel order).
            let restGeometry = CompositionEngine.computeRadialAngular(
                lightPositions: lightPositions, orderedLightIDs: compositionLightIDs
            )
            paramBox.radialPositions = restGeometry.radial
            paramBox.angularPositions = restGeometry.angular
            debugLog("[Composer] 📐 Spatial positions computed: \(paramBox.spatialPositions.count) lights, angle=\(String(format: "%.0f", paramBox.motion.motionAngle))°")
        }

        // Prefer entertainment transport for dynamic compositions when possible.
        // One session per bridge — multiple bridges can run simultaneously.
        let bridgeID = room.bridgeID ?? ""
        if preferEntertainment,
           canAcquireEntertainment(onBridge: bridgeID) {
            // Mic (when reaction uses it) is already warming during gamut resolution above,
            // overlapping network time with FFT capture startup.
            //
            // The plan is taken — and its channel IDs validated — BEFORE any session
            // is opened. Opening first and checking channels afterwards used to leave
            // a live client parked in `studioEntClients` and the configuration left
            // started on the bridge whenever the area had no usable channels.
            // Acquired during PREPARE, above every mutation. Its captured
            // configuration and channel order drive the render loop directly,
            // so nothing re-selected here can disagree with what the user was
            // shown and consented to.
            if let prepared = preparedComposition {
                // The final verification, immediately before the commit. A
                // candidate that fails it is already released — and NO
                // failure here may become a quiet bridge-stored/REST
                // continuation (round 4): a contested bridge would play over
                // the other controller's show, an unproven release may still
                // be streaming, and even the observed session failure owes
                // the user the explicit refusal rather than a silently
                // different transport.
                switch await verifyAndCommitEntertainment(prepared) {
                case .committed:
                    break
                case .contested(let snapshot, let targetConfigID):
                    return .needsForeignConsent(snapshot: snapshot, targetConfigID: targetConfigID)
                case .verificationUnavailable:
                    return .failed(message: EntertainmentConsentCopy.bridgeUnreadable)
                case .releaseNotProven, .sessionFailed:
                    return .failed(message: EntertainmentAvailabilityCopy.couldNotStart)
                }
            }
            if let prepared = preparedComposition {
                let entClient = prepared.client
                let entConfig = prepared.config
                let channelIDs = prepared.channelIDs
                // Override with channel-ordered positions for DTLS transport
                let entPositions = CompositionEngine.computeSpatialPositionsForEntertainment(
                    channels: entConfig.channels,
                    motionAngle: paramBox.motion.motionAngle
                )
                if !entPositions.isEmpty {
                    paramBox.spatialPositions = entPositions
                    paramBox.targetSpatialPositions = entPositions
                }
                let entGeometry = CompositionEngine.computeRadialAngular(channels: entConfig.channels)
                paramBox.radialPositions = entGeometry.radial
                paramBox.angularPositions = entGeometry.angular
                compositionEntRoomByBridge[bridgeID] = roomID
                // A composition now owns this bridge's session, so no
                // app-driven look does. `commitEntertainment` above overwrote
                // `studioEntClients[bridgeID]`; leaving the old record standing
                // would point at a client that is gone.
                studioEntOwnerByBridge.removeValue(forKey: bridgeID)
                noteRoomOwnershipChange(bridgeID: bridgeID, roomID: roomID)
                setCompositionTransportClaim(.entertainment, for: playbackKey)
                compositionEntParamBoxes[bridgeID] = paramBox
                compositionEntTasks[bridgeID]?.cancel()
                let capturedRoom = room
                let capturedTier = tier
                compositionEntTasks[bridgeID] = Task { [weak self] in
                    guard let self else { return }
                    await self.runCompositionEntertainment(
                        entClient: entClient,
                        channelIDs: channelIDs,
                        paramBox: paramBox,
                        gamut: compositionGamut
                    )
                    // M-10 follow-through: the loop exits early when the
                    // client's bounded reconnect is exhausted. Fail the
                    // room over to the REST scheduler so the show keeps
                    // running instead of freezing on the last frame.
                    guard !Task.isCancelled, await entClient.isTerminallyFailed else { return }
                    await self.failCompositionEntertainmentToREST(
                        bridgeID: bridgeID, roomID: roomID, room: capturedRoom,
                        paramBox: paramBox, gamut: compositionGamut, tier: capturedTier
                    )
                }
                await refreshCompositionMicDemand()
                debugLog("[Composer] ⚡ Entertainment transport active for room='\(room.name)' bridge='\(bridgeID)'")
                return .started(transport: .entertainment)
            }
        }

        // ─── Try bridge-stored animation (v1 rules chain) ───
        // Only use bridge-stored for `bridgeOptimized` presets (static motion + steady envelope).
        // These are single stable color states — perfect for a 3s-interval rule chain.
        //
        // `runtimeOnly` and `hybrid` presets need the continuous REST/Entertainment scheduler
        // (120ms updates) to produce visible dynamic effects (cascade, wave, breathe, etc.).
        // Routing those through bridge upload caused the rule chain (min 3s/step) to completely
        // suppress the REST scheduler, making compositions appear frozen.
        if let preset, preset.canRunOnBridge,
           preset.capabilityTier == .bridgeOptimized,
           !compositionLightIDs.isEmpty {
            // The bridge/store work is the shared `attemptBridgeStoredSave`
            // core (round 4) — the same code the transactional Save to Bridge
            // uses, so the compensation and quarantine rules cannot drift
            // between the two entry points. This ORDINARY-PLAY caller maps
            // its results onto playback semantics; the strict save maps them
            // onto save semantics without ever entering this function.
            switch await attemptBridgeStoredSave(
                room: room, preset: preset, lightIDs: compositionLightIDs,
                gamut: compositionGamut, bridgeID: bridgeID, api: api) {
            case .saved(let owned):
                // Confirmed running — the ledger's standard of evidence
                // (round 4c). The savedNotConfirmedRunning branch below
                // deliberately does NOT record: an inert chain is not the
                // room's running claim. The record below also raises the
                // exact `.bridgeStored` transport claim (round 4e).
                recordBridgeStoredChainOwnership(
                    bridgeID: bridgeID, roomID: roomID, manifestID: owned.id)
                noteRoomOwnershipChange(bridgeID: bridgeID, roomID: roomID)
                debugLog("[Composer] ⚡ Bridge-stored animation active! \(owned.stepCount) steps, \(owned.intervalSeconds)s/step")
                debugLog("[Composer] ⚡ Close the app — lights will keep going!")
                await sendBridgeStoredPrimeFrame(
                    preset: preset, gamut: compositionGamut,
                    api: api, groupedLightID: groupedLightID, roomName: room.name)
                return .started(transport: .bridgeStored)  // Don't start app-driven scheduler

            case .savedNotConfirmedRunning:
                // The resources exist AND are tracked, but nothing is
                // running. Keep the manifest — it is the exact evidence that
                // makes them stoppable and recoverable — and say so rather
                // than claiming the look is playing. Round 4e: an inert chain
                // claims NO transport — no exact claim, no ledger entry, and
                // nothing surfaces in the room aggregate on its account
                // (round 4c's invariant, now structural).
                noteRoomOwnershipChange(bridgeID: bridgeID, roomID: roomID)
                return .failed(message: BridgeSaveCopy.savedNotConfirmedRunning)

            case .replacementBlocked:
                // Close the session this start opened, exactly as a stop
                // would — nothing was created, so nothing may be claimed.
                deactivateComposerTelemetrySession(
                    sessionKey: composerTelemetryKey, pendingRemovalReported: false)
                return .failed(
                    message: "Couldn't start \(preset.name) — the previous look is still on the bridge. Try again in a moment.")

            case .compensatedNothingRemains:
                deactivateComposerTelemetrySession(
                    sessionKey: composerTelemetryKey, pendingRemovalReported: false)
                return .failed(message: BridgeSaveCopy.saveFailedNothingRecorded)

            case .partialCleanup(_, _, let recoverable):
                deactivateComposerTelemetrySession(
                    sessionKey: composerTelemetryKey, pendingRemovalReported: false)
                return .failed(message: recoverable
                    ? BridgeSaveCopy.partialCleanupRecoverable
                    : BridgeSaveCopy.partialCleanupNotDurable)

            case .uploadFailed(let error):
                debugLog("[Composer] ⚠ Bridge-stored upload failed, falling back to app-driven: \(error.localizedDescription)")
                // Packet 5: carry the reason forward instead of dropping it in
                // a DEBUG log. The three cases stay DISTINCT all the way to the
                // sentence the user reads — "the bridge is full" is only ever
                // said when capacity was actually MEASURED short. Unknown
                // capacity means the app knows nothing, and a creation failure
                // after a passing preflight is not evidence of exhaustion
                // (preflight is a point-in-time check, not a reservation).
                //
                // Recorded against the session opened at the head of this
                // function, and merged — `markComposerTelemetrySessionRESTActive`
                // will add the large-room fact below without erasing this, and
                // this does not erase that.
                let reason: CompositionFallbackReason
                switch error {
                case BridgeAnimationError.bridgeCapacityInsufficient:
                    reason = .bridgeCapacityInsufficient
                case BridgeAnimationError.bridgeCapacityUnknown:
                    reason = .bridgeCapacityUnknown
                default:
                    reason = .bridgeStoredUploadFailed
                }
                recordCompositionFallback(
                    sessionKey: composerTelemetryKey,
                    reason: reason,
                    generation: nextGeneration)
                // Fall through to the REST path, which records `.rest` below.
            }
        }

        // Round 3 (F): expand gradient strips into virtual render channels
        // for the REST tier. One full-lights fetch at start only; nil map =
        // no strip in the room = existing flat path.
        var compositionGradientMap: GradientChannelMap? = nil
        if !compositionLightIDs.isEmpty,
           let allLights = try? await api.fetchLights() {
            let idSet = Set(compositionLightIDs)
            compositionGradientMap = GradientChannelMap.build(
                orderedLightIDs: compositionLightIDs,
                lights: allLights.filter { idSet.contains($0.id) }
            )
            if let map = compositionGradientMap {
                debugLog("[Composer][Gradient] 🌈 \(map.entries.filter(\.isGradient).count) strip(s) → \(map.totalChannels) channels")
                // Packet 5: the spatial/radial/angular arrays above were built
                // in PHYSICAL-LIGHT order, but `render` indexes them by
                // RENDER-CHANNEL index. Those coincide only while every light
                // owns exactly one channel; the moment a strip expands, every
                // light after it reads a neighbour's geometry. Re-index now,
                // repeating each light's value across the channels it owns, so
                // frames[k] and spatialPositions[k] describe the same physical
                // light. (The flat path never reaches here, and the DTLS
                // branch already returned with its own channel-order values.)
                paramBox.spatialPositions = CompositionEngine.expandToRenderChannels(
                    paramBox.spatialPositions, map: map)
                paramBox.targetSpatialPositions = CompositionEngine.expandToRenderChannels(
                    paramBox.targetSpatialPositions, map: map)
                paramBox.radialPositions = CompositionEngine.expandToRenderChannels(
                    paramBox.radialPositions, map: map)
                paramBox.angularPositions = CompositionEngine.expandToRenderChannels(
                    paramBox.angularPositions, map: map)
            }
        }

        setCompositionTransportClaim(.rest, for: playbackKey)
        compositionRuntimes[playbackKey] = CompositionRuntime(
            roomID: roomID,
            roomName: room.name,
            bridgeID: bridgeID,
            // The ORIGINAL optional, not the `?? ""` above — see the field's
            // doc comment. This is what every Composer mailbox path keys on.
            restBridgeIdentity: room.bridgeID,
            api: api,
            groupedLightID: groupedLightID,
            lightIDs: compositionLightIDs,
            gradientMap: compositionGradientMap,
            paramBox: paramBox,
            tier: tier,
            gamut: compositionGamut,
            startTime: CFAbsoluteTimeGetCurrent(),
            generation: nextGeneration,
            nextDueAt: CFAbsoluteTimeGetCurrent(),
            wasInteracting: false,
            pendingSettle: false,
            interactionBurstUntil: nil,
            sendCount: 0,
            lastSentX: nil,
            lastSentY: nil,
            lastSentBri: nil,
            lastSentAt: nil
        )
        if !compositionOrder.contains(playbackKey) {
            compositionOrder.append(playbackKey)
        }
        // Packet 4: this composition is genuinely REST — its telemetry session
        // becomes refresh-eligible. The Entertainment and bridge-stored returns
        // above never reach this line, so their sessions stay inactive.
        // Packet 5: this is also where the rotation is armed with the room's
        // real eligible-operation count (one per physical light / REST
        // operation — a strip is ONE, not one per point), and where a room too
        // large for a single sweep records that fact for the tray.
        markComposerTelemetrySessionRESTActive(
            sessionKey: composerTelemetryKey,
            eligibleOperations: compositionGradientMap?.entries.count
                ?? compositionLightIDs.count)

        // Prime immediately so newly started rooms visibly turn on without
        // waiting for the next round-robin scheduler slot.
        // KEPT a direct API call, outside RestSender and outside cadence
        // (packet 3 decision, restated in packet 4) — routing it through the
        // mailbox would alter startup latency and ordering.
        await refreshCompositionMicDemand()
        await performCompositionPrime(
            room: room, api: api, groupedLightID: groupedLightID,
            paramBox: paramBox, gamut: compositionGamut,
            nextGeneration: nextGeneration)

        ensureCompositionSchedulerRunning()
        await refreshCompositionMicDemand()
        debugLog("[Composer] 📡 Scheduled room='\(room.name)' on global composition ticker")
        return .started(transport: .rest)
    }

    /// The Composer startup prime — one direct grouped PUT so the room turns
    /// on immediately. Outside RestSender and outside cadence, by design.
    ///
    /// Packet 4: runtime bookkeeping happens only INSIDE the success path — a
    /// thrown prime records no send — and only for the runtime THIS prime was
    /// issued for: the network await suspends, and a stop+restart in that
    /// window installs a generation-(N+1) runtime that a generation-N prime
    /// must not touch.
    private func performCompositionPrime(
        room: RoomDisplayItem,
        api: HueAPIClient,
        groupedLightID: String,
        paramBox: CompositionParamBox,
        gamut: HueColorUtils.Gamut,
        nextGeneration: Int
    ) async {
        let roomID = room.id
        guard let firstFrame = CompositionEngine.render(
            time: 0,
            channelIDs: [0],
            params: paramBox,
            features: AudioAnalysisEngine.latestFeatures(),
            beat: BeatClock.snapshot(),
            hostNow: CACurrentMediaTime()
        ).first else { return }
        let xy = HueColorUtils.clampXYToGamut(x: firstFrame.x, y: firstFrame.y, gamut: gamut)
        let bri = max(1, firstFrame.brightness * 100.0)
        do {
            try await api.setGroupedLightEffect(
                id: groupedLightID, on: true,
                brightness: bri,
                xy: (xy.x, xy.y),
                mirek: nil,
                duration: 140
            )
            debugLog(
                "[Composer][Prime] ✅ room='\(room.name)' id=\(roomID) gen=\(nextGeneration) bri=\(String(format: "%.1f", bri)) xy=(\(String(format: "%.4f", xy.x)),\(String(format: "%.4f", xy.y)))"
            )
            let primeKey = CompositionPlaybackKey(bridgeID: room.bridgeID, roomID: roomID)
            if var runtime = compositionRuntimes[primeKey],
               runtime.generation == nextGeneration {
                runtime.lastSentX = xy.x
                runtime.lastSentY = xy.y
                runtime.lastSentBri = bri
                runtime.sendCount = 1
                runtime.lastSentAt = CFAbsoluteTimeGetCurrent()
                compositionRuntimes[primeKey] = runtime
            }
        } catch {
            debugLog("[Composer][Prime] ❌ room='\(room.name)' id=\(roomID) gen=\(nextGeneration) error=\(error)")
        }
    }

    /// Composition render loop via Entertainment API — per-light colors at 25fps.
    private func runCompositionEntertainment(
        entClient: HueEntertainmentClient,
        channelIDs: [UInt8],
        paramBox: CompositionParamBox,
        gamut: HueColorUtils.Gamut
    ) async {
        // Note: paramBox cleanup is handled by stopCompositionMode (keyed by bridgeID).
        let frameInterval: UInt64 = 40_000_000  // 40ms = 25fps
        let startTime = CFAbsoluteTimeGetCurrent()
        // Packet 5: the renderer now speaks render-channel INDICES (Int), not
        // one-byte DTLS ids. The wire ids stay in `channelIDs` and are never
        // re-derived from render output, so the retype introduces no new
        // conversion that could fail on this path.
        let renderChannelIDs = channelIDs.map(Int.init)

        while !Task.isCancelled {
            // Mid-session DTLS failure: once the client's bounded reconnect
            // (M-10) is exhausted, stop rendering into a dead socket — the
            // owning task's tail then fails this room over to REST.
            if await entClient.isTerminallyFailed { break }
            await refreshCompositionMicDemand()
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime

            // Render all channels in one frame — through the Perform mixer
            // when this composition is the live deck A (Round 3 C).
            let frames: [LightFrame]
            if let mix = activePerformanceMix, mix.deckA === paramBox {
                frames = CompositionMixer.renderMixed(
                    time: elapsed,
                    channelIDs: renderChannelIDs,
                    mix: mix,
                    features: AudioAnalysisEngine.latestFeatures(),
                    beat: BeatClock.snapshot(),
                    hostNow: CACurrentMediaTime()
                )
            } else {
                frames = CompositionEngine.render(
                    time: elapsed,
                    channelIDs: renderChannelIDs,
                    params: paramBox,
                    features: AudioAnalysisEngine.latestFeatures(),
                    beat: BeatClock.snapshot(),
                    hostNow: CACurrentMediaTime()
                )
            }

            // ── DTLS BOUNDARY (packet 5) ──
            // The wire ids are the ones the BRIDGE reported, validated
            // ALL-OR-NOTHING by EntertainmentAreaSelector.validatedChannelIDs
            // (`UInt8(exactly:)` on every channel, plus a uniqueness check)
            // before this plan was ever accepted: an area carrying a
            // channel_id outside UInt8, or a duplicate, yields nil there and
            // the room falls back to Room mode without opening a session.
            // They are deliberately NOT reconstructed from `frame.channelID`.
            //
            // Alignment is positional and must be exact — render emits one
            // frame per channel, in order. If that ever stops holding, send
            // NOTHING this frame rather than a partial or misaligned stream.
            guard frames.count == channelIDs.count else {
                assertionFailure(
                    "render returned \(frames.count) frames for \(channelIDs.count) channels")
                try? await Task.sleep(nanoseconds: frameInterval)
                continue
            }
            let channels = zip(channelIDs, frames).map { pair in
                let (id, frame) = pair
                let xy = HueColorUtils.clampXYToGamut(x: frame.x, y: frame.y, gamut: gamut)
                return (id: id, x: xy.x, y: xy.y, brightness: frame.brightness)
            }
            await entClient.send(channels: channels)

            try? await Task.sleep(nanoseconds: frameInterval)
        }
    }

    /// Mid-session DTLS→REST failover: called from the entertainment frame
    /// task's tail after its loop exits with the client terminally failed
    /// (bounded M-10 reconnect exhausted). Cleans this bridge's entertainment
    /// bookkeeping and re-enters startCompositionMode on the REST path with
    /// the SAME live paramBox, so user edits and mic demand carry over.
    private func failCompositionEntertainmentToREST(
        bridgeID: String,
        roomID: String,
        room: RoomDisplayItem,
        paramBox: CompositionParamBox,
        gamut: HueColorUtils.Gamut,
        tier: CompositionTier
    ) async {
        // Ownership check (generation-equivalent): stopCompositionMode or a
        // replacement start already cleaned this key — never resurrect.
        guard compositionEntRoomByBridge[bridgeID] == roomID else { return }
        debugLog("[Composer] ⚠ Entertainment session lost for room=\(roomID) — failing over to REST")
        // Re-entry below claims `.rest`; if its guard bails instead, the room
        // correctly reads "not running" rather than a phantom `.entertainment`.
        // Round 4e: withdraw only THIS playback's exact claim — a same-room-id
        // composition on another bridge keeps its claim and the aggregate.
        removeCompositionTransportClaim(
            for: CompositionPlaybackKey(bridgeID: room.bridgeID, roomID: roomID))
        compositionEntParamBoxes.removeValue(forKey: bridgeID)
        compositionEntTasks.removeValue(forKey: bridgeID)   // this task; loop already ended
        compositionEntRoomByBridge.removeValue(forKey: bridgeID)
        entertainmentConfigsByBridge.removeValue(forKey: bridgeID)
        entertainmentMembershipByBridge.removeValue(forKey: bridgeID)
        // Session teardown, not "this bridge has no area" — forget that we
        // asked, so availability reverts to .unknown rather than .noArea.
        // Dropping the inventory here is also what makes an area edited in the
        // Hue app take effect on the next start instead of only after a relaunch.
        entertainmentConfigsFetchedBridges.remove(bridgeID)
        if let entClient = studioEntClients[bridgeID] {
            await entClient.stopSession()   // no-op post-teardown (configID cleared)
            studioEntClients.removeValue(forKey: bridgeID)
        }
        // preferEntertainment: false — never reconnect-loop back into DTLS;
        // preset: nil — skip the bridge-stored branch, land in the REST
        // scheduler (startCompositionMode bumps the room generation, so all
        // existing guards hold).
        await startCompositionMode(
            room: room,
            paramBox: paramBox,
            gamutOverride: gamut,
            preferEntertainment: false,
            tier: tier,
            preset: nil
        )
        // Packet 5: record WHY this room is on Room mode, against the session
        // the re-entry above just opened. Written after the start (the start
        // clears any prior reason) and generation-fenced, so a late event from
        // a superseded run cannot republish. Unlike `transportFallback` — an
        // apply-time snapshot that is never re-set — this survives a
        // mid-session failover, which is the case that previously flipped the
        // badge to ROOM with no explanation at all.
        if let generation = compositionGenerations[
            CompositionPlaybackKey(bridgeID: room.bridgeID, roomID: roomID)] {
            recordCompositionFallback(
                sessionKey: ComposerTelemetrySessionKey(
                    bridgeKey: room.bridgeID ?? "legacy",
                    scope: RestScope(roomID: roomID, owner: .composer)),
                reason: .entertainmentUnavailable,
                generation: generation)
        }
    }

    /// Composition render loop via REST — group-level color + brightness.
    ///
    /// **Cadence:** Aligned with `SyncModeEngine` REST visualizer — `0.15s × roomCount`
    /// between sends for dynamic tiers (same bridge fairness model as the dedicated Sync tab).
    /// Avoid unconstrained fast loops (e.g. fixed 200ms × many rooms): that queues PUTs and
    /// causes multi‑second apparent lag. Prefer Entertainment (DTLS) when available.
    private func ensureCompositionSchedulerRunning() {
        guard compositionSchedulerTask == nil else { return }
        compositionSchedulerTask = Task { [weak self] in
            guard let self else { return }
            await self.runCompositionScheduler()
        }
    }

    // ── Composer telemetry helpers (packet 4) ────────────────────
    //
    // Reset and publication are SEPARATE responsibilities, and neither belongs
    // to the pure ledger: the session helper below owns identity, the refresh
    // helper owns what the tray is allowed to show. Every event and refresh
    // samples `compositionTelemetryNow` — never the wall clock directly.

    /// Open a telemetry session for one exact (bridgeKey, Composer scope).
    /// Clears the orchestrator's OWN stale tracking BEFORE install — a pending
    /// token left from an old generation or transport window must not survive
    /// to be misreported as a cancellation later. This does not infer sender
    /// supersession and does not touch RestSender.
    /// `isRESTActive` starts false; only the REST-runtime installation path
    /// flips it (`markComposerTelemetrySessionRESTActive`).
    private func beginComposerTelemetrySession(
        sessionKey: ComposerTelemetrySessionKey, generation: Int
    ) {
        composerPendingTokens.removeValue(forKey: sessionKey)
        composerTelemetrySessions.removeValue(forKey: sessionKey)
        compositionSendLedger.beginSession(
            bridgeKey: sessionKey.bridgeKey, scope: sessionKey.scope, generation: generation)
        removeComposerCadencePublication(sessionKey: sessionKey)
        // Packet 5: a new start inherits NOTHING from the old one. Rotation
        // restarts at cursor 0 with both flags down (it is re-created with the
        // real eligible count when REST activates), and no stale degradation
        // reason may survive into a session that has not earned it.
        compositionRotationStates.removeValue(forKey: sessionKey)
        compositionDegradationStates.removeValue(forKey: sessionKey)
        composerTelemetrySessions[sessionKey] =
            ComposerTelemetrySession(generation: generation, isRESTActive: false)
    }

    /// Flip the exact session to REST-active. Called only when
    /// `startCompositionMode` actually installs a REST runtime — Entertainment
    /// and bridge-stored sessions stay false and are never refresh-eligible.
    /// Packet 5 rides along: REST activation is also where the rotation is
    /// armed with the room's real eligible-operation count, and where a room
    /// too large for one sweep records that fact for the tray.
    private func markComposerTelemetrySessionRESTActive(
        sessionKey: ComposerTelemetrySessionKey,
        eligibleOperations: Int
    ) {
        guard let session = composerTelemetrySessions[sessionKey] else { return }
        composerTelemetrySessions[sessionKey]?.isRESTActive = true

        compositionRotationStates[sessionKey] = CompositionRotationState(
            generation: session.generation,
            cursor: 0,
            eligibleOperationCount: max(0, eligibleOperations),
            currentRotationHadFailure: false,
            hasCompletedInitialSuccessfulRotation: false)

        if eligibleOperations > CompositionRotationPlan.maxOperationsPerSweep {
            recordCompositionLargeRoom(
                sessionKey: sessionKey,
                eligibleOperations: eligibleOperations,
                generation: session.generation)
        }
    }

    // ── Degradation reads and writes (packet 5) ──────────────────

    /// The room's current transport-degradation truth, or nil when there is
    /// nothing to say. `bridgeID` is the room's ORIGINAL optional identity and
    /// normalizes nil → "legacy", exactly like `restSender(for:)` and
    /// `activeRESTCadence(roomID:bridgeID:)` — callers must pass the selected
    /// room's real bridge, never a global default.
    ///
    /// Returns the immutable snapshot; the mutable state stays private.
    func compositionDegradation(
        roomID: String, bridgeID: String?
    ) -> CompositionDegradationSnapshot? {
        let key = ComposerTelemetrySessionKey(
            bridgeKey: bridgeID ?? "legacy",
            scope: RestScope(roomID: roomID, owner: .composer))
        guard let state = compositionDegradationStates[key], !state.snapshot.isEmpty else {
            return nil
        }
        return state.snapshot
    }

    /// Record WHY this composition is not on its intended transport, without
    /// disturbing the large-room fact. Generation-fenced: a stale completion
    /// or a late fallback event from a superseded run cannot republish.
    private func recordCompositionFallback(
        sessionKey: ComposerTelemetrySessionKey,
        reason: CompositionFallbackReason,
        generation: Int
    ) {
        guard composerTelemetrySessions[sessionKey]?.generation == generation else { return }
        var state = compositionDegradationStates[sessionKey]
            ?? CompositionDegradationState(generation: generation,
                                           fallbackReason: nil,
                                           largeRoomEligibleOperations: nil)
        guard state.generation == generation else { return }
        state.fallbackReason = reason      // only this field — merge, never replace
        compositionDegradationStates[sessionKey] = state
    }

    /// Record that this room is served in rotation, without disturbing any
    /// fallback reason already recorded for the same generation.
    private func recordCompositionLargeRoom(
        sessionKey: ComposerTelemetrySessionKey,
        eligibleOperations: Int,
        generation: Int
    ) {
        guard composerTelemetrySessions[sessionKey]?.generation == generation else { return }
        var state = compositionDegradationStates[sessionKey]
            ?? CompositionDegradationState(generation: generation,
                                           fallbackReason: nil,
                                           largeRoomEligibleOperations: nil)
        guard state.generation == generation else { return }
        state.largeRoomEligibleOperations = eligibleOperations   // only this field
        compositionDegradationStates[sessionKey] = state
    }

    /// Deactivate one exact session, in the approved order:
    /// the caller has ALREADY consumed RestSender's pending-removal evidence
    /// and passes it here; (1) record the pending cancellation (0/0 — removed
    /// pending work never started) for the exact tracked token only when the
    /// sender reported the removal; (2) deactivate the ledger session;
    /// (3) drop the retained identity, pending tracker, and publication.
    /// Executing work stays governed by its probe; its later report dies in
    /// the deactivated ledger.
    private func deactivateComposerTelemetrySession(
        sessionKey: ComposerTelemetrySessionKey, pendingRemovalReported: Bool
    ) {
        if pendingRemovalReported, let pending = composerPendingTokens[sessionKey] {
            compositionSendLedger.cancelled(
                pending, at: compositionTelemetryNow(),
                attemptedOperations: 0, failures: 0)
        }
        if let session = composerTelemetrySessions[sessionKey] {
            compositionSendLedger.deactivateSession(
                bridgeKey: sessionKey.bridgeKey, scope: sessionKey.scope,
                generation: session.generation)
        }
        composerTelemetrySessions.removeValue(forKey: sessionKey)
        composerPendingTokens.removeValue(forKey: sessionKey)
        removeComposerCadencePublication(sessionKey: sessionKey)
        // Packet 5: rotation and degradation share this session's lifetime
        // exactly. Both fields of the degradation state clear together — there
        // is no partial teardown that could leave half a truth on screen.
        compositionRotationStates.removeValue(forKey: sessionKey)
        compositionDegradationStates.removeValue(forKey: sessionKey)
    }

    /// Publication refresh for one exact session: sample the clock, snapshot,
    /// then store the cadence — or REMOVE it, which is the whole point: a
    /// number the ledger can no longer justify must leave the screen.
    private func refreshComposerCadencePublication(
        sessionKey: ComposerTelemetrySessionKey
    ) {
        let snapshot = compositionSendLedger.snapshot(
            bridgeKey: sessionKey.bridgeKey, scope: sessionKey.scope,
            asOf: compositionTelemetryNow())
        if let cadence = snapshot.cadenceSeconds {
            activeRESTCadenceByBridgeRoom[sessionKey.bridgeKey, default: [:]][sessionKey.scope.roomID] = cadence
        } else {
            removeComposerCadencePublication(sessionKey: sessionKey)
        }
    }

    /// The per-scheduler-pass sweep: every retained REST-ACTIVE session, exact
    /// keys only. Eligibility comes from the retained session value itself —
    /// NEVER from `compositionTransportByRoom`, whose roomID-only key cannot
    /// tell identical room IDs on different bridges apart. This is what makes
    /// a published cadence expire when requests hang and no completion ever
    /// arrives to trigger an event-driven refresh.
    private func refreshAllActiveComposerCadencePublications() {
        for (sessionKey, session) in composerTelemetrySessions where session.isRESTActive {
            refreshComposerCadencePublication(sessionKey: sessionKey)
        }
    }

    private func removeComposerCadencePublication(
        sessionKey: ComposerTelemetrySessionKey
    ) {
        activeRESTCadenceByBridgeRoom[sessionKey.bridgeKey]?
            .removeValue(forKey: sessionKey.scope.roomID)
        if activeRESTCadenceByBridgeRoom[sessionKey.bridgeKey]?.isEmpty == true {
            activeRESTCadenceByBridgeRoom.removeValue(forKey: sessionKey.bridgeKey)
        }
    }

    /// This session's rotation cursor, arming or repairing the state first
    /// (packet 5).
    ///
    /// The eligible set is immutable for a session's life —
    /// `CompositionRuntime.lightIDs` is a `let` and `gradientMap` is assigned
    /// once at start — which is what makes the no-starvation argument a closed
    /// proof rather than a hope. `eligibleOperationCount` is stored so that
    /// invariant is *checked* rather than trusted: if it ever disagrees with
    /// the live count, the rotation restarts cleanly instead of slicing with a
    /// stale bound.
    private func rotationState(
        sessionKey: ComposerTelemetrySessionKey,
        generation: Int,
        eligibleOperationCount: Int
    ) -> Int {
        if let existing = compositionRotationStates[sessionKey],
           existing.generation == generation,
           existing.eligibleOperationCount == eligibleOperationCount {
            return existing.cursor
        }
        #if DEBUG
        if let existing = compositionRotationStates[sessionKey],
           existing.generation == generation,
           existing.eligibleOperationCount != eligibleOperationCount {
            print("""
            [Composer][Rotation] ⚠ eligible count changed mid-session for \
            room=\(sessionKey.scope.roomID) bridge=\(sessionKey.bridgeKey): \
            \(existing.eligibleOperationCount) → \(eligibleOperationCount); restarting rotation
            """)
        }
        #endif
        compositionRotationStates[sessionKey] = CompositionRotationState(
            generation: generation,
            cursor: 0,
            eligibleOperationCount: eligibleOperationCount,
            currentRotationHadFailure: false,
            hasCompletedInitialSuccessfulRotation: false)
        return 0
    }

    /// One batch finished dispatching — advance the rotation by exactly what
    /// it attempted, and remember whether any of it failed (packet 5).
    ///
    /// Called from inside the Composer closures, right after the batch's task
    /// group returns and BEFORE the inter-batch sleep, with the same
    /// `outcomes` array the telemetry accumulation uses. One source of
    /// evidence, two consumers: the cursor and `attemptedOperations` can never
    /// disagree about what was dispatched.
    ///
    /// Failed attempts DO advance the cursor — they were attempted, and the
    /// light gets its next turn on the next rotation rather than blocking the
    /// ones behind it — but they taint the rotation so the delta gate cannot
    /// quiesce a room that has not actually been delivered to (§ the
    /// `hasCompletedInitialSuccessfulRotation` doc).
    ///
    /// Rejected — mutating nothing — when the session is gone, is no longer
    /// REST-active, or when the generation no longer matches: exact key plus
    /// generation, never roomID alone, so an old closure on bridge A cannot
    /// move bridge B's cursor even for an identical room ID.
    private func composerRotationAdvanced(
        token: CompositionSendLedger.Token,
        attemptedOperations: Int,
        failures: Int
    ) {
        guard attemptedOperations > 0 else { return }
        let sessionKey = ComposerTelemetrySessionKey(
            bridgeKey: token.bridgeKey, scope: token.scope)
        guard let session = composerTelemetrySessions[sessionKey],
              session.isRESTActive,
              session.generation == token.generation,
              var state = compositionRotationStates[sessionKey],
              state.generation == token.generation,
              state.eligibleOperationCount > 0
        else { return }

        if failures > 0 { state.currentRotationHadFailure = true }

        let advance = CompositionRotationPlan.advance(
            cursor: state.cursor,
            eligibleCount: state.eligibleOperationCount,
            attemptedOperations: attemptedOperations)
        state.cursor = advance.cursor
        if advance.crossedRotationBoundary {
            // Quiescence requires a rotation that DELIVERED, not one that
            // merely attempted. A tainted rotation leaves the flag down, so
            // the gate stays open and the next rotation retries the room.
            if !state.currentRotationHadFailure {
                state.hasCompletedInitialSuccessfulRotation = true
            }
            state.currentRotationHadFailure = false
        }
        compositionRotationStates[sessionKey] = state
    }

    private func mintComposerToken(
        sessionKey: ComposerTelemetrySessionKey, generation: Int
    ) -> CompositionSendLedger.Token {
        composerTokenSequence &+= 1
        return CompositionSendLedger.Token(
            bridgeKey: sessionKey.bridgeKey, scope: sessionKey.scope,
            generation: generation, sequence: composerTokenSequence)
    }

    /// A closure began executing. Marked FIRST, before the first validity
    /// check — a probe-rejected sweep still STARTED, and pretending otherwise
    /// would resurrect the enqueue-counting lie this packet removes.
    private func composerWorkStarted(_ token: CompositionSendLedger.Token) {
        compositionSendLedger.started(token, at: compositionTelemetryNow())
        let sessionKey = ComposerTelemetrySessionKey(
            bridgeKey: token.bridgeKey, scope: token.scope)
        if composerPendingTokens[sessionKey] == token {
            composerPendingTokens.removeValue(forKey: sessionKey)
        }
        refreshComposerCadencePublication(sessionKey: sessionKey)
    }

    private enum ComposerTerminalKind { case completed, cancelled }

    /// A closure finished — normally or at a failed probe. ONE clock sample
    /// (`terminalAt`) serves both the ledger event and, when every bookkeeping
    /// gate passes, `runtime.lastSentAt` — the send time the scorer sees is
    /// the send time the ledger recorded.
    ///
    /// Runtime delta-gate state advances ONLY on an ACCEPTED, fully successful
    /// `completed`: the ledger accepted the transition (so duplicates and
    /// stale-generation stragglers change nothing), every dispatched operation
    /// succeeded, the runtime still exists, and both its generation AND its
    /// bridge identity match the token. Cancelled, partial, and all-failed
    /// items leave the frame eligible for re-send — that is the one
    /// intentional behavior change of this packet.
    private func composerWorkTerminated(
        token: CompositionSendLedger.Token,
        kind: ComposerTerminalKind,
        attemptedOperations: Int,
        failures: Int,
        sentX: Double? = nil,
        sentY: Double? = nil,
        sentBri: Double? = nil
    ) {
        let terminalAt = compositionTelemetryNow()
        let sessionKey = ComposerTelemetrySessionKey(
            bridgeKey: token.bridgeKey, scope: token.scope)

        // ACCEPTANCE FIRST. A rejected terminal (absent token, stale
        // generation, completed-before-started, duplicate) must not mutate the
        // pending tracker: that tracker is the teardown paths' map of what
        // RestSender may still be holding, and only the ledger's verdict — or
        // the sender's own clear/clearAll evidence — may consume it.
        let accepted: Bool
        switch kind {
        case .completed:
            accepted = compositionSendLedger.completed(
                token, at: terminalAt,
                attemptedOperations: attemptedOperations, failures: failures)
        case .cancelled:
            accepted = compositionSendLedger.cancelled(
                token, at: terminalAt,
                attemptedOperations: attemptedOperations, failures: failures)
        }
        // Defensive: an ACCEPTED terminal normally finds nothing here — the
        // started report already removed an executing token — but an accepted
        // pending cancellation consumes its tracker, and the equality check
        // keeps a newer token's slot safe either way.
        if accepted, composerPendingTokens[sessionKey] == token {
            composerPendingTokens.removeValue(forKey: sessionKey)
        }
        refreshComposerCadencePublication(sessionKey: sessionKey)

        // Round 4e: the runtime lookup IS the bridge fence now — the playback
        // key carries the token's own bridgeKey, so a same-room-id runtime on
        // another bridge can never absorb this terminal's send state. (The old
        // `restBridgeIdentity ?? "legacy" == token.bridgeKey` guard became
        // structural.)
        let runtimeKey = CompositionPlaybackKey(
            bridgeKey: token.bridgeKey, roomID: token.scope.roomID)
        guard kind == .completed,
              accepted,
              attemptedOperations > 0,
              failures == 0,
              var runtime = compositionRuntimes[runtimeKey],
              runtime.generation == token.generation
        else { return }
        if let sentX { runtime.lastSentX = sentX }
        if let sentY { runtime.lastSentY = sentY }
        if let sentBri { runtime.lastSentBri = sentBri }
        runtime.lastSentAt = terminalAt
        runtime.sendCount += 1
        compositionRuntimes[runtimeKey] = runtime
    }

    /// The production enqueue sequence, used verbatim by the scheduler AND the
    /// DEBUG seams — one code path, so what the tests prove is what ships.
    ///
    /// Ordering is load-bearing (packet 4): the ledger record and the pending
    /// tracker are installed BEFORE awaiting the actor, because the mailbox may
    /// dispatch the closure the moment it accepts it and the started report
    /// must find the tracker in place. Supersession trusts ONLY the returned
    /// `replacedPending`, applied to the PREVIOUSLY captured token — never to
    /// the one just installed.
    @discardableResult
    private func enqueueComposerWork(
        sessionKey: ComposerTelemetrySessionKey,
        generation: Int,
        sender: RestSender,
        workBuilder: (CompositionSendLedger.Token) -> RestSender.Work
    ) async -> CompositionSendLedger.Token {
        let token = mintComposerToken(sessionKey: sessionKey, generation: generation)
        let work = workBuilder(token)
        let previousToken = composerPendingTokens[sessionKey]
        compositionSendLedger.enqueued(token, at: compositionTelemetryNow())
        composerPendingTokens[sessionKey] = token
        let result = await sender.enqueue(scope: sessionKey.scope, work)
        if result.replacedPending, let previousToken {
            compositionSendLedger.superseded(previousToken)
        }
        refreshComposerCadencePublication(sessionKey: sessionKey)
        return token
    }

    // The three Composer REST closures, extracted so the scheduler and the
    // DEBUG seams build the IDENTICAL closure (packet 4). Shared contract:
    //   • packet 3 cancellation is untouched — `stillCurrent` before EVERY
    //     batch including the first; a failed probe reports `cancelled` with
    //     the operations accumulated so far and returns;
    //   • `started` is reported FIRST, before the first probe — a sweep the
    //     very first check rejects still started;
    //   • operations are counted where they are DISPATCHED: an entry with no
    //     frame, or a light beyond the frame array, `continue`s before
    //     `addTask` and counts nothing;
    //   • each task-group child returns its own outcome; successes/failures
    //     are aggregated AFTER awaiting the group — no shared mutable counters
    //     inside child tasks;
    //   • `sentX/Y/Bri` ride along so an accepted fully-successful completion
    //     can install the frame proxy as delta-gate state.

    /// `entries` is this SWEEP's subset of the room's gradient entries, in
    /// rotation order, each still carrying its ABSOLUTE `channelRange` into
    /// the full-room `frames` array (packet 5). One entry is one physical
    /// light and one REST operation, whether it is a single bulb or a
    /// five-point strip.
    private func makeComposerGradientWork(
        token: CompositionSendLedger.Token,
        entries: [GradientChannelMap.Entry],
        frames: [LightFrame],
        api: HueAPIClient,
        gamut: HueColorUtils.Gamut,
        sentX: Double, sentY: Double, sentBri: Double
    ) -> RestSender.Work {
        return { [weak self] stillCurrent in
            self?.composerWorkStarted(token)
            var attempted = 0
            var failures = 0

            let batchSize = CompositionRotationPlan.batchSize
            for batchStart in stride(from: 0, to: entries.count, by: batchSize) {
                guard await stillCurrent() else {
                    self?.composerWorkTerminated(
                        token: token, kind: .cancelled,
                        attemptedOperations: attempted, failures: failures)
                    return
                }
                let batchEnd = min(batchStart + batchSize, entries.count)
                let outcomes = await withTaskGroup(of: Bool.self) { group -> [Bool] in
                    for entry in entries[batchStart..<batchEnd] {
                        let entryFrames = entry.channelRange.compactMap { idx in
                            idx < frames.count ? frames[idx] : nil
                        }
                        // Unreachable since packet 5: the whole room is
                        // rendered, so frames.count == map.totalChannels and
                        // every absolute channelRange is in bounds. It must
                        // stay unreachable — a batch that dispatched fewer
                        // operations than its slice would pin the cursor and
                        // stall the rotation forever.
                        guard let first = entryFrames.first else {
                            assertionFailure(
                                "gradient entry \(entry.lightID) has no frames in a \(frames.count)-frame render")
                            continue
                        }
                        group.addTask {
                            do {
                                if entry.isGradient {
                                    let points = entryFrames.map { frame -> CGPoint in
                                        let xy = HueColorUtils.clampXYToGamut(
                                            x: frame.x, y: frame.y, gamut: gamut)
                                        return CGPoint(x: xy.x, y: xy.y)
                                    }
                                    let avgBri = entryFrames.map(\.brightness)
                                        .reduce(0, +) / Double(entryFrames.count)
                                    try await api.setLightGradient(
                                        id: entry.lightID,
                                        body: GradientBody(
                                            pointsXY: points,
                                            brightness: max(1, avgBri * 100.0),
                                            on: true,
                                            durationMs: 200))
                                } else {
                                    let xy = HueColorUtils.clampXYToGamut(
                                        x: first.x, y: first.y, gamut: gamut)
                                    try await api.setLightEffect(
                                        id: entry.lightID, on: true,
                                        brightness: max(1, first.brightness * 100.0),
                                        xy: (xy.x, xy.y),
                                        mirek: nil,
                                        duration: 200)
                                }
                                return true
                            } catch {
                                return false
                            }
                        }
                    }
                    var results: [Bool] = []
                    for await outcome in group { results.append(outcome) }
                    return results
                }
                // Packet 5: ONE piece of evidence, three consumers — telemetry
                // accumulation, the rotation cursor, and the rotation's
                // failure taint. Advanced here, after the group returns and
                // before the inter-batch sleep, never from a planned size.
                let attemptedThisBatch = outcomes.count
                let failuresThisBatch = outcomes.lazy.filter { !$0 }.count
                attempted += attemptedThisBatch
                failures += failuresThisBatch
                self?.composerRotationAdvanced(
                    token: token,
                    attemptedOperations: attemptedThisBatch,
                    failures: failuresThisBatch)
                if batchEnd < entries.count {
                    try? await Task.sleep(for: .milliseconds(80))
                }
            }
            #if DEBUG
            print("[Composer][REST] ✅ gradient-aware room=\(token.scope.roomID) dispatched=\(attempted) failures=\(failures)")
            #endif
            self?.composerWorkTerminated(
                token: token, kind: .completed,
                attemptedOperations: attempted, failures: failures,
                sentX: sentX, sentY: sentY, sentBri: sentBri)
        }
    }

    /// `targets` is this SWEEP's subset of the room's lights, in rotation
    /// order, each paired with its ABSOLUTE index into the full-room `frames`
    /// array (packet 5). Carrying the absolute index is what keeps
    /// frame↔light alignment an identity rather than an assumption once the
    /// dispatched set is no longer the whole room.
    private func makeComposerPerLightWork(
        token: CompositionSendLedger.Token,
        targets: [(frameIndex: Int, lightID: String)],
        frames: [LightFrame],
        api: HueAPIClient,
        gamut: HueColorUtils.Gamut,
        sentX: Double, sentY: Double, sentBri: Double
    ) -> RestSender.Work {
        return { [weak self] stillCurrent in
            self?.composerWorkStarted(token)
            var attempted = 0
            var failures = 0

            // Send each light its unique color — batched with concurrent
            // sends (bridge handles ~10/sec individual)
            let batchSize = CompositionRotationPlan.batchSize
            for batchStart in stride(from: 0, to: targets.count, by: batchSize) {
                guard await stillCurrent() else {
                    self?.composerWorkTerminated(
                        token: token, kind: .cancelled,
                        attemptedOperations: attempted, failures: failures)
                    return
                }
                let batchEnd = min(batchStart + batchSize, targets.count)
                let outcomes = await withTaskGroup(of: Bool.self) { group -> [Bool] in
                    for target in targets[batchStart..<batchEnd] {
                        // Unreachable since packet 5: the whole room is
                        // rendered, so frames.count == lightIDs.count and
                        // every absolute index is in bounds. It must stay
                        // unreachable — a batch that dispatched fewer
                        // operations than its slice would pin the cursor and
                        // stall the rotation forever.
                        guard target.frameIndex < frames.count else {
                            assertionFailure(
                                "light \(target.lightID) at index \(target.frameIndex) beyond a \(frames.count)-frame render")
                            continue
                        }
                        let lightID = target.lightID
                        let frame = frames[target.frameIndex]
                        let xy = HueColorUtils.clampXYToGamut(
                            x: frame.x, y: frame.y, gamut: gamut
                        )
                        let bri = max(1, frame.brightness * 100.0)
                        group.addTask {
                            do {
                                try await api.setLightEffect(
                                    id: lightID, on: true,
                                    brightness: bri,
                                    xy: (xy.x, xy.y),
                                    mirek: nil,
                                    duration: 200
                                )
                                return true
                            } catch {
                                return false
                            }
                        }
                    }
                    var results: [Bool] = []
                    for await outcome in group { results.append(outcome) }
                    return results
                }
                // Packet 5: same single piece of evidence as the gradient path
                // — telemetry, cursor, and failure taint all derive from it.
                let attemptedThisBatch = outcomes.count
                let failuresThisBatch = outcomes.lazy.filter { !$0 }.count
                attempted += attemptedThisBatch
                failures += failuresThisBatch
                self?.composerRotationAdvanced(
                    token: token,
                    attemptedOperations: attemptedThisBatch,
                    failures: failuresThisBatch)
                // Small gap between batches if more remain
                if batchEnd < targets.count {
                    try? await Task.sleep(for: .milliseconds(80))
                }
            }
            #if DEBUG
            print("[Composer][REST] ✅ per-light room=\(token.scope.roomID) dispatched=\(attempted) failures=\(failures)")
            #endif
            self?.composerWorkTerminated(
                token: token, kind: .completed,
                attemptedOperations: attempted, failures: failures,
                sentX: sentX, sentY: sentY, sentBri: sentBri)
        }
    }

    private func makeComposerGroupedWork(
        token: CompositionSendLedger.Token,
        groupedLightID: String,
        brightness: Double,
        xy: (x: Double, y: Double),
        api: HueAPIClient
    ) -> RestSender.Work {
        // One request, no loop — nothing to cancel between dispatches, so this
        // path ignores the probe (packet 3). Scope invalidation still prevents
        // it from STARTING once the room is stopped.
        return { [weak self] _ in
            self?.composerWorkStarted(token)
            do {
                try await api.setGroupedLightEffect(
                    id: groupedLightID, on: true,
                    brightness: brightness,
                    xy: (xy.x, xy.y),
                    mirek: nil,
                    duration: 200
                )
                #if DEBUG
                print("[Composer][REST] ✅ grouped room=\(token.scope.roomID) bri=\(String(format: "%.1f", brightness))")
                #endif
                self?.composerWorkTerminated(
                    token: token, kind: .completed,
                    attemptedOperations: 1, failures: 0,
                    sentX: xy.x, sentY: xy.y, sentBri: brightness)
            } catch {
                // Ran to its natural end and failed — a completed item with
                // one failure, not a cancellation.
                self?.composerWorkTerminated(
                    token: token, kind: .completed,
                    attemptedOperations: 1, failures: 1)
            }
        }
    }

    /// Stop one room's composition. `bridgeID` is the room's ORIGINAL optional
    /// bridge identity (packet 4) — the caller states it explicitly because no
    /// reliable room-only lookup exists: `compositionRuntimes` is absent for
    /// Entertainment and bridge-stored transports, and any roomID-only search
    /// would conflate identical room IDs on different bridges. nil normalizes
    /// to "legacy", exactly like `restSender(for:)`.
    func stopCompositionMode(roomID: String, bridgeID: String?) async {
        debugLog("[Handoff] Composer stop requested for roomID=\(roomID) bridge=\(bridgeID ?? "legacy")")
        // Round 4e: ONE exact playback identity drives every mutation below.
        // Only THIS bridge+room's generation is invalidated — bumping a bare
        // room id used to invalidate another bridge's live same-room-id
        // runtime, which the scheduler then evicted as stale.
        let playbackKey = CompositionPlaybackKey(bridgeID: bridgeID, roomID: roomID)
        compositionGenerations[playbackKey] = (compositionGenerations[playbackKey] ?? 0) + 1
        // The ONE identity every telemetry teardown step below uses: sender
        // clear, pending-token cancellation, ledger deactivation, retained-
        // session removal, and publication removal all key off this exact value.
        let sessionKey = ComposerTelemetrySessionKey(
            bridgeKey: bridgeID ?? "legacy",
            scope: RestScope(roomID: roomID, owner: .composer))

        // ─── Stop bridge-stored animation if active ───
        // M-07: tear down against the manifest's OWN bridge, never the
        // nondeterministic first client — a second bridge's animation would
        // otherwise loop forever while its manifest is dropped locally.
        // Packet 8: selection is EXACT — this bridge and this room, never every
        // manifest that happens to share the room id. `exactManifests` is the
        // sole destructive authority; `compositionTransportByRoom` is roomID-
        // keyed and is deliberately not consulted for ownership.
        for manifest in exactManifests(bridgeID: bridgeID, roomID: roomID) {
            guard let api = hueClient(for: bridgeID) ?? hueClient(forBridgeIP: manifest.bridgeIP),
                  let v1Client = try? api.makeV1Client() else {
                // Packet 8: RETAIN. "No registered client right now" is the
                // normal transient state at launch — the bridge may be asleep,
                // moved, or its fetch still in flight. The old code dropped the
                // manifest here, permanently destroying the only record of
                // resources that keep looping on that bridge.
                debugLog("[Handoff] ⚠ No registered client for manifest \(manifest.id) — retaining it")
                continue
            }
            let result = await bridgeAnimationEngine.stop(manifest: manifest, v1Client: v1Client)
            if !retireManifest(manifest, after: result) {
                debugLog("[Handoff] ⚠ Bridge did not confirm teardown of \(manifest.id) — retaining for retry")
            }
        }
        // Round 4e: withdraw only THIS playback's exact transport claim.
        // Another bridge's same-room-id claim — and therefore the room's
        // aggregate entry — survives. A `.bridgeStored` claim is NOT removed
        // here: it moves with the ownership ledger, which the manifest
        // retirement above already subtracted from (claim falls only when the
        // exact bridge+room ownership set emptied — a retained/unconfirmed
        // manifest keeps it, exactly as it keeps the ledger entry).
        if let claim = compositionTransportClaims[playbackKey], claim != .bridgeStored {
            removeCompositionTransportClaim(for: playbackKey)
        } else {
            // No live claim of ours to withdraw — still recompute: the
            // manifest retirement above may have destroyed the last
            // bridge-stored evidence a retained room label leaned on.
            recomputeCompositionTransportAggregate(roomID: roomID)
        }
        // Packet 3: clear ONLY this room's Composer scope. Packet 4: on the
        // bridge the CALLER named — the same identity the scheduler enqueues
        // on — never a bridge recovered from `allRooms`, manifests,
        // selected-room state, or dictionary order, all of which can go stale
        // mid-composition and would clear a mailbox on the wrong bridge
        // (silently leaving this room's stale frames queued and killing an
        // innocent room's).
        //
        // LOOK UP the sender; never create one here. An Entertainment or
        // bridge-stored composition may run on a bridge that never had REST
        // work, and stopping it must not conjure an empty mailbox actor just
        // to clear nothing. A missing sender simply means no pending work was
        // removed.
        var removedPending = false
        if let sender = restSendersByBridge[sessionKey.bridgeKey] {
            debugLog("[Handoff] Clearing Composer REST scope roomID=\(roomID) bridge=\(sessionKey.bridgeKey)")
            removedPending = await sender.clear(scope: sessionKey.scope)
        } else {
            debugLog("[Handoff] No REST sender for bridge=\(sessionKey.bridgeKey) — no mailbox to clear")
        }
        // Give Hue bridge firmware a brief settle window before any new owner starts writing.
        // KEPT AS-IS (packet 3): this is a practical settle window, not a formal
        // drain. `clear` above already invalidated the scope, so no LATER batch
        // can begin; a bounded in-flight drain belongs to the later ownership/
        // scheduler work, not here.
        try? await Task.sleep(for: .milliseconds(150))
        debugLog("[Handoff] REST scope cleared + settle delay complete for roomID=\(roomID)")
        // Stop the CALLER'S bridge's entertainment session — and only after
        // verifying that bridge's session is actually driving this room.
        // Round 4e: bridge-authoritative selection. The old reverse lookup
        // (`compositionEntRoomByBridge.first(where: { $0.value == roomID })`)
        // ignored the caller's bridge and picked by dictionary order, so with
        // two bridges sharing a room id an exact stop of bridge A could tear
        // down bridge B's DTLS task, client, and caches. `?? ""` is the
        // Entertainment maps' own key convention (written at start).
        let entBridgeKey = bridgeID ?? ""
        if compositionEntRoomByBridge[entBridgeKey] == roomID {
            let bid = entBridgeKey
            compositionEntParamBoxes.removeValue(forKey: bid)
            compositionEntTasks[bid]?.cancel()
            compositionEntTasks.removeValue(forKey: bid)
            compositionEntRoomByBridge.removeValue(forKey: bid)
            entertainmentConfigsByBridge.removeValue(forKey: bid)
            entertainmentMembershipByBridge.removeValue(forKey: bid)
            entertainmentConfigsFetchedBridges.remove(bid)   // see failCompositionEntertainmentToREST
            if let entClient = studioEntClients[bid] {
                await entClient.stopSession()
                studioEntClients.removeValue(forKey: bid)
            }
        }
        compositionRuntimes.removeValue(forKey: playbackKey)
        // Packet 4: DEACTIVATION, not merely reset — consume the sender's
        // pending-removal evidence gathered above, record the 0/0 pending
        // cancellation for the exact tracked token if the sender reported one,
        // deactivate the ledger session, and drop the retained identity and
        // publication for exactly this bridgeKey + scope. Reports from the
        // stopped generation are ignored from here on; a restart begins a
        // fresh session with its new runtime generation.
        deactivateComposerTelemetrySession(
            sessionKey: sessionKey, pendingRemovalReported: removedPending)
        compositionOrder.removeAll { $0 == playbackKey }
        if compositionRuntimes.isEmpty {
            compositionSchedulerTask?.cancel()
            compositionSchedulerTask = nil
        }
        await refreshCompositionMicDemand()
        // Re-sync this room's card to the bridge's confirmed state — while the
        // composition ran, its SSE echoes were suppressed (isAppDrivenGroup), so
        // the card is frozen at its pre-composition color until a refresh lands.
        scheduleStateRefresh()
        debugLog("[Handoff] Composer teardown complete for roomID=\(roomID)")
    }

    private func runCompositionScheduler() async {
        // ─────────────────────────────────────────────────────────────
        // Composer REST Scheduler — PER-LIGHT MAILBOX DESIGN
        //
        // Per-light mode: each light gets its OWN color from the
        // render engine. Cascade/wave/scatter patterns are now visible.
        // Bridge handles ~10 individual light PUTs/sec vs 1 grouped/sec.
        //
        // Packet 3: every send goes through the ROOM'S BRIDGE mailbox,
        // under RestScope(roomID, .composer). Latest-wins now applies
        // within that scope alone, so the bridge gets this room's NEWEST
        // per-light colors without another room's stop discarding them.
        //
        // The batch loops below are cooperatively cancellable: they check
        // `stillCurrent` before every batch, so stopping this room's
        // composition halts it within one already-dispatched batch instead
        // of letting 300-500 ms of stale writes land after the next look's
        // prime frame. Task.isCancelled cannot do this — the mailbox's
        // flush task is unstructured and never cancelled, so it is
        // permanently false in here.
        //
        // Fallback: if no individual light IDs were resolved, falls
        // back to grouped_light (same as before).
        // ─────────────────────────────────────────────────────────────
        let tickInterval: Duration = .milliseconds(120)

        while !Task.isCancelled {
            if compositionRuntimes.isEmpty {
                compositionSchedulerTask = nil
                return
            }

            await refreshCompositionMicDemand()

            // Packet 4: refresh EVERY REST-active session's publication once
            // per pass, BEFORE room selection — this is the expiry path. When
            // requests hang or a room is delta-skipped, no ledger event fires,
            // and without this sweep a stale cadence would sit on screen
            // forever. Deliberately not tied to the selected room: the room
            // that needs expiring is precisely the one not completing.
            refreshAllActiveComposerCadencePublications()

            let now = CFAbsoluteTimeGetCurrent()
            guard let playbackKey = nextCompositionRoomPriority(now: now),
                  let runtime = compositionRuntimes[playbackKey] else {
                try? await Task.sleep(for: tickInterval)
                continue
            }
            let roomID = playbackKey.roomID

            // Generation guard — don't send for stale/stopped playbacks.
            // Round 4e: keyed exactly, so a stop on one bridge can only ever
            // evict its own bridge's same-room-id runtime here.
            guard compositionGenerations[playbackKey] == runtime.generation else {
                compositionRuntimes.removeValue(forKey: playbackKey)
                compositionOrder.removeAll { $0 == playbackKey }
                continue
            }

            // Render the current frame — per-light when IDs are available
            let elapsed = now - runtime.startTime
            let lightCount = runtime.lightIDs.count
            let usePerLight = lightCount > 0

            // Build render channel indices: one per light for per-light mode,
            // or [0] for grouped. A gradient map expands strips into extra
            // channels so motion travels ALONG them (Round 3 F).
            //
            // Packet 5: the WHOLE room is always rendered, even when this
            // sweep will only dispatch part of it. `render` normalises each
            // light's spatial position by the channel count, so rendering 20
            // of 60 would tell light #43 it is light #3 of 20 and destroy
            // every wave, cascade and spatial pattern in the room. Render
            // full, dispatch partial. (These are Int render indices, never
            // DTLS channel ids — the old `UInt8(min(…, 20))` clamp existed
            // only to keep the trapping UInt8 initialiser safe, and that is
            // where the phantom 20-light limit came from.)
            let channelIDs: [Int] = {
                guard usePerLight else { return [0] }
                if let map = runtime.gradientMap {
                    return Array(0..<map.totalChannels)
                }
                return Array(0..<lightCount)
            }()

            let frames: [LightFrame]
            if let mix = activePerformanceMix, mix.deckA === runtime.paramBox {
                // Perform mixer at the same chokepoint (Round 3 C) — the
                // crossfade/pads work identically at REST cadence.
                frames = CompositionMixer.renderMixed(
                    time: elapsed,
                    channelIDs: channelIDs,
                    mix: mix,
                    features: AudioAnalysisEngine.latestFeatures(),
                    beat: BeatClock.snapshot(),
                    hostNow: CACurrentMediaTime()
                )
            } else {
                frames = CompositionEngine.render(
                    time: elapsed,
                    channelIDs: channelIDs,
                    params: runtime.paramBox,
                    features: AudioAnalysisEngine.latestFeatures(),
                    beat: BeatClock.snapshot(),
                    hostNow: CACurrentMediaTime()
                )
            }
            guard !frames.isEmpty else {
                try? await Task.sleep(for: tickInterval)
                continue
            }

            // Packet 3: this room's own mailbox slot, on its OWN bridge. The
            // bridge comes from the runtime (recorded at start), never from a
            // possibly-stale `allRooms` lookup.
            // `restBridgeIdentity`, NOT `bridgeID` — the nonoptional field
            // carries "" for a bridgeless room, which is not nil and so gets
            // its own sender instead of the shared "legacy" one. The clear
            // side in `stopCompositionMode` keys off the same value.
            let composerSender = restSender(for: runtime.restBridgeIdentity)
            let composerScope = RestScope(roomID: roomID, owner: .composer)

            // Packet 4: one token per enqueued work item, keyed exactly like
            // the mailbox. The closure itself is built by the same factory the
            // DEBUG seams expose, and the enqueue sequence (tracker installed
            // BEFORE the await, supersession only on the sender's word) lives
            // in enqueueComposerWork — one code path for production and tests.
            let sessionKey = ComposerTelemetrySessionKey(
                bridgeKey: runtime.restBridgeIdentity ?? "legacy",
                scope: composerScope)

            // Check if anything changed visually (use first frame as proxy)
            let firstFrame = frames[0]
            let firstXY = HueColorUtils.clampXYToGamut(x: firstFrame.x, y: firstFrame.y, gamut: runtime.gamut)
            let firstBri = max(1, firstFrame.brightness * 100.0)
            let colorDelta: Double = {
                guard let lx = runtime.lastSentX, let ly = runtime.lastSentY else { return .greatestFiniteMagnitude }
                return hypot(firstXY.x - lx, firstXY.y - ly)
            }()
            let briDelta = abs(firstBri - (runtime.lastSentBri ?? -999))
            // triggerRESTBurst's designed consumer (6d4e105's doc described
            // this read; it was never implemented — audit R9, F2). The gate
            // proxies "did anything change" through frame[0] alone, so a
            // user edit that barely moves light 0 (album colors / harmony /
            // revert on a static look) was skipped forever while every
            // other light stayed wrong. During the post-edit burst window,
            // send regardless. Same epoch on both sides: CFAbsoluteTime ==
            // seconds since 2001 == timeIntervalSinceReferenceDate.
            let userEditBurstActive = runtime.paramBox.forceRESTBurstUntil > now
            // Packet 5: the gate may only suppress a pass once the room has
            // been FULLY DELIVERED at least once, and only at a rotation
            // boundary. Mid-rotation (cursor != 0) the remaining lights still
            // need their turn; and a rotation that contained any failure
            // leaves `hasCompletedInitialSuccessfulRotation` down, so the room
            // re-rotates and retries instead of going quiet with a light
            // stranded — the case completion-only bookkeeping already refuses
            // to record, and which the gate must not overrule.
            //
            // For rooms of ≤ maxOperationsPerSweep the cursor is back at 0
            // after every sweep, so this is identical to the old behaviour
            // from the second pass onward.
            //
            // An EMPTY eligible set (the grouped fallback — no per-light IDs
            // resolved) is trivially complete: there is no rotation to finish,
            // `makeComposerGroupedWork` never reports a rotation advance, and
            // the flag could therefore never rise — see the predicate's doc.
            let rotation = compositionRotationStates[sessionKey]
            let rotationIncomplete = rotation.map {
                CompositionRotationPlan.deliveryIncomplete(
                    eligibleOperationCount: $0.eligibleOperationCount,
                    hasCompletedInitialSuccessfulRotation: $0.hasCompletedInitialSuccessfulRotation,
                    cursor: $0.cursor)
            } ?? false
            if !userEditBurstActive && !rotationIncomplete
                && colorDelta < 0.003 && briDelta < 1.0 {
                try? await Task.sleep(for: tickInterval)
                continue
            }

            // Capture values for the closure
            let capturedAPI = runtime.api
            let capturedGamut = runtime.gamut
            let sentX = firstXY.x
            let sentY = firstXY.y
            let sentBri = firstBri

            // Packet 5: which eligible operations this sweep dispatches. The
            // eligible list is one entry per PHYSICAL LIGHT / REST operation —
            // never a flattened render-channel index — so a five-point strip
            // is one slot costing one PUT, exactly as it costs one operation.
            // The slice is contiguous and does not wrap, so each rotation is
            // an exact ordered partition of the room.
            let eligibleCount = usePerLight
                ? (runtime.gradientMap.map { $0.entries.count } ?? lightCount)
                : 0
            let rotationCursor = rotationState(
                sessionKey: sessionKey,
                generation: runtime.generation,
                eligibleOperationCount: eligibleCount)
            let sweepSlice = CompositionRotationPlan.slice(
                cursor: rotationCursor, eligibleCount: eligibleCount)

            if usePerLight, let map = runtime.gradientMap, let slice = sweepSlice {
                // ── GRADIENT-AWARE PER-LIGHT MODE (Round 3 F) ──
                // Strips get ONE gradient.points PUT carrying their whole
                // channel range; flat lights keep the per-light PUT. Same
                // mailbox, same pacing profile as the flat path.
                // Entries keep their ABSOLUTE channelRange into `frames`.
                let subset = Array(map.entries[slice.range])
                await enqueueComposerWork(
                    sessionKey: sessionKey, generation: runtime.generation,
                    sender: composerSender
                ) { token in
                    makeComposerGradientWork(
                        token: token, entries: subset, frames: frames,
                        api: capturedAPI, gamut: capturedGamut,
                        sentX: sentX, sentY: sentY, sentBri: sentBri)
                }
            } else if usePerLight, let slice = sweepSlice {
                // ── PER-LIGHT MODE ──
                // Each light gets its own color. Cascade/wave patterns visible.
                // Bridge handles ~10 PUTs/sec for individual lights.
                // Each target carries its ABSOLUTE index into `frames`.
                let subset = slice.range.map {
                    (frameIndex: $0, lightID: runtime.lightIDs[$0])
                }
                await enqueueComposerWork(
                    sessionKey: sessionKey, generation: runtime.generation,
                    sender: composerSender
                ) { token in
                    makeComposerPerLightWork(
                        token: token, targets: subset, frames: frames,
                        api: capturedAPI, gamut: capturedGamut,
                        sentX: sentX, sentY: sentY, sentBri: sentBri)
                }
            } else {
                // ── GROUPED FALLBACK ──
                // No individual light IDs resolved — use grouped_light
                await enqueueComposerWork(
                    sessionKey: sessionKey, generation: runtime.generation,
                    sender: composerSender
                ) { token in
                    makeComposerGroupedWork(
                        token: token, groupedLightID: runtime.groupedLightID,
                        brightness: firstBri, xy: (firstXY.x, firstXY.y),
                        api: capturedAPI)
                }
            }

            // Scheduling state may advance at enqueue — but ONLY scheduling
            // state. The delta-gate values (lastSentX/Y/Bri, lastSentAt,
            // sendCount) now move in composerWorkTerminated, on an accepted
            // fully-successful completion. Re-read the runtime rather than
            // writing back the pre-enqueue copy: a fast completion may have
            // already recorded its bookkeeping during the await above, and a
            // stale whole-struct write would erase it.
            if var current = compositionRuntimes[playbackKey],
               current.generation == runtime.generation {
                current.nextDueAt = now + 0.12
                compositionRuntimes[playbackKey] = current
            }

            try? await Task.sleep(for: tickInterval)
        }
    }

    private func nextCompositionRoomPriority(now: CFAbsoluteTime) -> CompositionPlaybackKey? {
        var selectedKey: CompositionPlaybackKey?
        var selectedScore: Double = -.greatestFiniteMagnitude

        for playbackKey in compositionOrder {
            guard let runtime = compositionRuntimes[playbackKey] else { continue }
            guard let score = CompositionRoomPriorityScorer.score(
                now: now,
                input: .init(
                    nextDueAt: runtime.nextDueAt,
                    isColorPadInteracting: runtime.paramBox.isColorPadInteracting,
                    interactionBurstUntil: runtime.interactionBurstUntil,
                    pendingSettle: runtime.pendingSettle,
                    lastSentAt: runtime.lastSentAt,
                    startTime: runtime.startTime,
                    sendCount: runtime.sendCount
                )
            ) else {
                continue
            }

            if score > selectedScore {
                selectedScore = score
                selectedKey = playbackKey
            }
        }

        return selectedKey
    }

    private func resolveCompositionGamut(for room: RoomDisplayItem, api: HueAPIClient) async -> HueColorUtils.Gamut {
        guard let allLights = try? await api.fetchLights() else { return .c }
        let roomLights = CompositionLightResolver.resolveLights(
            childResourceRefs: room.childResourceRefs,
            lights: allLights
        )

        guard !roomLights.isEmpty else { return .c }
        var counts: [HueColorUtils.Gamut: Int] = [.a: 0, .b: 0, .c: 0]
        for light in roomLights {
            guard let raw = light.color?.gamut_type?.uppercased(),
                  let gamut = HueColorUtils.Gamut(rawValue: raw) else { continue }
            counts[gamut, default: 0] += 1
        }
        return counts.max(by: { $0.value < $1.value })?.key ?? .c
    }

    /// How a room's individual light ids resolved for the Composer paths.
    ///
    /// A bare `[]` used to mean three different things: a room with no
    /// lights, every ref a ghost, and a transient fetch failure. Ordinary
    /// playback treats them identically — nothing to drive — but an explicit
    /// Save to Bridge owes the user different sentences for "this room has
    /// no lights" and "the room's lights couldn't be confirmed", so the
    /// distinction must survive resolution.
    enum CompositionLightResolution {
        case lights([String])
        /// The room genuinely references no surviving lights.
        case noneInRoom
        /// The bridge could not be read. Membership is UNKNOWN, not empty.
        case unresolved

        /// The historic shape, for every path where the three cases rightly
        /// collapse to "nothing to drive".
        var lightIDs: [String] {
            if case .lights(let ids) = self { return ids }
            return []
        }
    }

    /// Resolve individual light IDs for a room/zone — used for per-light REST Composer mode.
    private func resolveCompositionLights(for room: RoomDisplayItem, api: HueAPIClient) async -> CompositionLightResolution {
        let refs = room.childResourceRefs
        guard !refs.isEmpty else { return .noneInRoom }

        // Zones reference lights directly — zero API calls (pinned by
        // ComposerFetchPathParityTests). A ref can still outlive its light
        // (L-29), so prune ghosts against the in-memory light cache, which
        // the same loadAll that produced these refs also filled; an absent
        // cache keeps the historic pass-through.
        if CompositionLightResolver.hasDirectLightReferences(childResourceRefs: refs) {
            let ids = CompositionLightResolver.resolveLightIDs(
                childResourceRefs: refs,
                lights: cachedRawLights(for: room.bridgeID) ?? []
            )
            return ids.isEmpty ? .noneInRoom : .lights(ids)
        }

        // Rooms reference devices — resolve via light.owner.rid
        guard let allLights = try? await api.fetchLights() else { return .unresolved }
        let ids = CompositionLightResolver.resolveLightIDs(
            childResourceRefs: refs,
            lights: allLights
        )
        return ids.isEmpty ? .noneInRoom : .lights(ids)
    }

    private func resolveCompositionLightIDs(for room: RoomDisplayItem, api: HueAPIClient) async -> [String] {
        await resolveCompositionLights(for: room, api: api).lightIDs
    }

    /// Resolve lightID → physical (x, z) position from an entertainment config.
    ///
    /// The entertainment→device→light join this used to perform inline now lives in
    /// `EntertainmentAreaSelector` and is cached per bridge by
    /// `warmEntertainmentCaches`, so positions and *area selection* read the same
    /// truth. Keeping a second copy of the algorithm here is what let the two drift:
    /// selection could pick one area while positions were resolved from another.
    /// Synchronous now — the two fetches it used to repeat on every start are done
    /// once during the warm.
    private func resolveEntertainmentLightPositions(
        config: EntertainmentConfig,
        bridgeID: String?
    ) -> [String: (x: Double, z: Double)] {
        guard let bridgeID, let membership = entertainmentMembershipByBridge[bridgeID] else { return [:] }
        let result = EntertainmentAreaSelector.lightPositions(
            for: config,
            entertainmentToLightMap: membership
        )
        debugLog("[Composer] 🗺️ Resolved \(result.count) light positions from entertainment config")
        return result
    }

    /// Full local teardown for "Forget All Bridges". Clearing only the
    /// Keychain left the in-memory clients (with tokens) fully functional
    /// until the app was relaunched — the UI kept controlling lights after
    /// a forget-all. Also clears the room/zone snapshots so a later re-pair
    /// cannot resurrect stale bridge ids through the SwiftData preload.
    func forgetAllBridges() async {
        // ── All-Day, SYNCHRONOUSLY, before this function's first `await` ──
        //
        // `await stopStudioMode()` below is the very first statement of the
        // original body, and it suspends. Without the gate, a `startAllDayScenes`
        // arriving in that window would build a fresh task and fresh senders
        // outside the snapshot we take here, and they would outlive the teardown
        // that was supposed to have removed them.
        allDayTeardownInProgress = true
        allDayScenesEnabled = false
        allDayGeneration &+= 1
        allDayTask?.cancel()
        allDayTask = nil
        let retiredAllDaySenders = Array(allDayRestSendersByBridge.values)
        allDayRestSendersByBridge.removeAll()
        bridgeNativeOwners.removeAll()

        await stopStudioMode()
        stopSSE()
        compositionSchedulerTask?.cancel()
        compositionSchedulerTask = nil
        compositionRuntimes.removeAll()
        compositionOrder.removeAll()
        widgetWriteTask?.cancel()
        clients.removeAll()
        commandGates.removeAll()
        // Packet 3: invalidate every scope on every sender BEFORE dropping the
        // senders — a sender released while a closure still holds a live epoch
        // would let that closure keep writing to a bridge we just forgot.
        // Packet 4: iterate ENTRIES — the dictionary key is the authoritative
        // bridge identity for the scopes each clearAll returns; recovering it
        // from anywhere else (roomID, allRooms, the sender object) can lie.
        for (bridgeKey, sender) in restSendersByBridge {
            let removedScopes = await sender.clearAll()
            for scope in removedScopes where scope.owner == .composer {
                deactivateComposerTelemetrySession(
                    sessionKey: ComposerTelemetrySessionKey(bridgeKey: bridgeKey, scope: scope),
                    pendingRemovalReported: true)
            }
        }
        restSendersByBridge.removeAll()
        // Forget-all leaves NO telemetry behind: sessions whose bridge never
        // had a REST sender (Entertainment-only compositions) are deactivated
        // here by exact key, and the publication map is emptied outright.
        for sessionKey in Array(composerTelemetrySessions.keys) {
            deactivateComposerTelemetrySession(
                sessionKey: sessionKey, pendingRemovalReported: false)
        }
        activeRESTCadenceByBridgeRoom.removeAll()
        studioRestScopesByBridge.removeAll()
        roomsByBridge.removeAll()
        zonesByBridge.removeAll()
        connectionStatus.removeAll()
        allRooms = []
        allZones = []
        globalScenes = []
        hasLoadedScenesOnce = false
        for sender in retiredAllDaySenders { await sender.clearAll() }
        // Drop the gate last. All-Day is deliberately NOT restarted here: the
        // user re-enables it, or the next launch does.
        allDayTeardownInProgress = false
        log.info("Forget-all: cleared clients, snapshots, and sessions")
    }

    func stopStudioMode() async {
        debugLog("[Handoff] Studio stop requested")
        let auditContext = StopAuditContext(route: .stopStudioMode)
        recordStopAudit(auditContext, operation: .stopStudioModeInvoked,
                        bridgeID: nil, roomID: nil,
                        outcomeReason: "runtimes=\(studioEngineRuntimesByBridge.count) clients=\(studioEntClients.count)")
        // Cancel every bridge's running loop task (strobe, etc.) — this is
        // the forget-all path, so ALL bridges' engines go down together.
        for (bid, runtime) in studioEngineRuntimesByBridge {
            runtime.task.cancel()
            recordStopAudit(auditContext, operation: .taskCancelled,
                            bridgeID: bid, roomID: runtime.roomID,
                            runtimeToken: Self.stopAuditToken(runtime.paramBox))
        }
        studioEngineRuntimesByBridge.removeAll()
        debugLog("[Handoff] Clearing every REST scope on every bridge sender")
        // This is the forget-all / stop-everything path, so a GLOBAL clear is
        // the correct semantics here — unlike stopCompositionMode and
        // stopAppDrivenStudioEffect, which must stay room-scoped.
        // Packet 4: entries, not values — each clearAll's returned scopes are
        // meaningful only against the bridge key that owns that sender. Every
        // dropped Composer scope records its 0/0 pending cancellation and its
        // exact session is deactivated; the remaining sessions on that bridge
        // (executing-only or idle) follow.
        for (bridgeKey, sender) in restSendersByBridge {
            let removedScopes = await sender.clearAll()
            for scope in removedScopes where scope.owner == .composer {
                deactivateComposerTelemetrySession(
                    sessionKey: ComposerTelemetrySessionKey(bridgeKey: bridgeKey, scope: scope),
                    pendingRemovalReported: true)
            }
            for sessionKey in Array(composerTelemetrySessions.keys)
            where sessionKey.bridgeKey == bridgeKey {
                deactivateComposerTelemetrySession(
                    sessionKey: sessionKey, pendingRemovalReported: false)
            }
        }
        // This is stop-EVERYTHING: sessions on bridges that never created a
        // REST sender (Entertainment-only, bridge-stored) are swept too — by
        // their EXACT retained keys, never by roomID, and without conjuring a
        // sender to do it. Afterwards no retained session, pending tracker, or
        // published cadence may remain anywhere.
        for sessionKey in Array(composerTelemetrySessions.keys) {
            deactivateComposerTelemetrySession(
                sessionKey: sessionKey, pendingRemovalReported: false)
        }
        composerPendingTokens.removeAll()
        activeRESTCadenceByBridgeRoom.removeAll()
        studioRestScopesByBridge.removeAll()
        // Small barrier so bridge transition buffers drain before a new startup sequence.
        // KEPT AS-IS (packet 3): a practical settle window, not a formal drain.
        try? await Task.sleep(for: .milliseconds(150))
        debugLog("[Handoff] REST scopes cleared + settle delay complete")
        debugLog("[Studio] ⏹ stopStudioMode() canceled every bridge's engine loop")

        // Stop all entertainment sessions (all bridges)
        for (bid, entClient) in studioEntClients {
            recordStopAudit(auditContext, operation: .clientStopSession,
                            bridgeID: bid, roomID: nil,
                            clientID: Self.stopAuditToken(entClient))
            let stopRequest = await entClient.stopSession()
            recordStopAudit(auditContext,
                            operation: stopRequest == .notSent
                                ? .actionStopSuppressed : .actionStopSent,
                            bridgeID: bid, roomID: nil,
                            clientID: Self.stopAuditToken(entClient),
                            outcomeReason: String(describing: stopRequest))
        }
        studioEntClients.removeAll()
        // Stop-everything: no session survives, so no ownership record may.
        studioEntOwnerByBridge.removeAll()
        compositionEntTasks.values.forEach { $0.cancel() }
        compositionEntTasks.removeAll()
        compositionEntRoomByBridge.removeAll()
        compositionEntParamBoxes.removeAll()
        entertainmentConfigsByBridge.removeAll()
        entertainmentMembershipByBridge.removeAll()
        entertainmentConfigsFetchedBridges.removeAll()

        // Also notify any mic engines
        NotificationCenter.default.post(name: .studioStopAll, object: nil)
        // Packet 8: recovered bridge-stored rows survive. This teardown stops
        // what the APP is driving; it sends no v1 delete, so those animations
        // are still running on their bridges and clearing their rows would be
        // a claim this function did not earn. They stop through the exact
        // manifest path, which is still reachable from Dashboard and Studio.
        let liveRowsBefore = activeEffectEntries.count
        activeEffectEntries.removeAll { $0.recovered == nil }
        if activeEffectEntries.count != liveRowsBefore {
            recordStopAudit(auditContext, operation: .nowPlayingRemoved,
                            bridgeID: nil, roomID: nil,
                            outcomeReason: "allLiveRows removed=\(liveRowsBefore - activeEffectEntries.count)")
        }
        // Stop-everything includes the firmware effects Studio started, so their
        // All-Day claims go with them.
        bridgeNativeOwners.removeAll()
        debugLog("[Handoff] Studio teardown complete")
    }

    /// Room-scoped teardown for ONE app-driven Studio effect (strobe, party,
    /// …). Round 4g: the engine runtime is keyed by BRIDGE and records its
    /// owning room, so this stop proves ownership before destroying anything.
    /// Every mutation below is gated on "the recorded owner is the exact
    /// bridge + room this stop was asked for" — a stale stop that resumes
    /// after a newer same-bridge start already took the key must leave the
    /// newer runtime, scope, session, and owner record untouched. The global
    /// `stopStudioMode()` (kept verbatim for forgetAllBridges) additionally
    /// cancels EVERY bridge's tasks, drops all entertainment configs, and
    /// wipes the whole Now-Playing registry — which silently killed other
    /// rooms' running compositions when one strobe was stopped. This variant
    /// touches only its own bridge's app-driven loop and entertainment
    /// session, and only when no composition owns that session.
    func stopAppDrivenStudioEffect(roomID: String, bridgeID: String?,
                                   context: StopAuditContext = .unattributed) async {
        debugLog("[Handoff] App-driven stop requested for roomID=\(roomID)")
        recordStopAudit(context, operation: .stopRequested,
                        bridgeID: bridgeID, roomID: roomID,
                        outcomeReason: "stopAppDrivenStudioEffect")
        let engineKey = bridgeID ?? ""
        // Cancel the engine loop ONLY when this exact bridge + room still owns
        // it. The check and the cancel are synchronous on this actor, so no
        // newer start can take the key between them.
        if let runtime = studioEngineRuntimesByBridge[engineKey], runtime.roomID == roomID {
            runtime.task.cancel()
            studioEngineRuntimesByBridge.removeValue(forKey: engineKey)
            recordStopAudit(context, operation: .taskCancelled,
                            bridgeID: bridgeID, roomID: roomID,
                            runtimeToken: Self.stopAuditToken(runtime.paramBox))
        }
        // Packet 3: clear ONLY this room's Studio scope, on the supplied
        // bridge — a global clear here is what let one strobe's stop discard
        // another room's queued Composer frame.
        let stoppedScope = RestScope(roomID: roomID, owner: .studio)
        await restSender(for: bridgeID).clear(scope: stoppedScope)
        // Drop the ownership record when it is the one we just stopped; leave
        // it alone if some other room has since become this bridge's owner.
        if studioRestScopesByBridge[bridgeID ?? "legacy"] == stoppedScope {
            studioRestScopesByBridge.removeValue(forKey: bridgeID ?? "legacy")
        }
        recordStopAudit(context, operation: .restScopeCleared,
                        bridgeID: bridgeID, roomID: roomID)
        // Small barrier so bridge transition buffers drain before a new owner starts.
        // KEPT AS-IS (packet 3): a practical settle window, not a formal drain.
        try? await Task.sleep(for: .milliseconds(150))
        // The loop may hold a DTLS session on its room's bridge. Stop it ONLY
        // if every one of these holds:
        //  • no composition owns that bridge's session — an app-driven effect
        //    that fell back to REST can coexist with a composition streaming
        //    on the same bridge, and that stream must survive this stop;
        //  • no newer engine runtime claimed the bridge while this stop was
        //    suspended above — the sleep is a real suspension point, and the
        //    successor's session is not ours to stop;
        //  • the recorded session owner, when one exists, is the exact room
        //    being stopped — a stale stop must not tear down another room's
        //    session on evidence it never held.
        if let bid = bridgeID,
           compositionEntRoomByBridge[bid] == nil,
           studioEngineRuntimesByBridge[bid] == nil,
           studioEntOwnerByBridge[bid].map({ $0.roomID == roomID }) ?? true,
           let entClient = studioEntClients[bid] {
            let auditClientID = Self.stopAuditToken(entClient)
            recordStopAudit(context, operation: .clientStopSession,
                            bridgeID: bid, roomID: roomID, clientID: auditClientID)
            let stopRequest = await entClient.stopSession()
            recordStopAudit(context,
                            operation: stopRequest == .notSent
                                ? .actionStopSuppressed : .actionStopSent,
                            bridgeID: bid, roomID: roomID, clientID: auditClientID,
                            outcomeReason: String(describing: stopRequest))
            studioEntClients.removeValue(forKey: bid)
            // Inside the SAME branch on purpose. A stop that did not release
            // the session (a composition owns it, or there was no client) must
            // keep the evidence — clearing the record unconditionally would
            // make a still-running owner invisible to the very question that
            // exists to protect it.
            studioEntOwnerByBridge.removeValue(forKey: bid)
        } else {
            // DEBUG audit only: name the exact reason the Entertainment
            // teardown was skipped. Pure re-reads of the same conditions the
            // guard above evaluated; production behavior is unchanged.
            let skipReason: String
            if let bid = bridgeID {
                if let compositionOwnerRoom = compositionEntRoomByBridge[bid] {
                    skipReason = "compositionClaim room=\(compositionOwnerRoom)"
                } else if studioEngineRuntimesByBridge[bid] != nil {
                    skipReason = "newerRuntimeClaimedBridge"
                } else if !(studioEntOwnerByBridge[bid].map({ $0.roomID == roomID }) ?? true) {
                    skipReason = "ownerRoomMismatch"
                } else {
                    skipReason = "noClientInstalled"
                }
            } else {
                skipReason = "nilBridgeID"
            }
            recordStopAudit(context, operation: .entertainmentGuardSkipped,
                            bridgeID: bridgeID, roomID: roomID,
                            outcomeReason: skipReason)
        }
        debugLog("[Handoff] App-driven teardown complete for roomID=\(roomID)")
    }

    // MARK: - Entertainment Setup Helpers

    /// Try to open an entertainment DTLS session for an ALREADY-SELECTED area.
    ///
    /// Takes the config rather than looking one up: the caller has already chosen
    /// it (and validated its channels) via `entertainmentStartPlan`, so there is no
    /// second selection here to disagree with the first, and no way to open a
    /// session for a config the render loop cannot drive.
    /// Returns the client if successful, nil if the connection failed.
    private func acquireEntertainment(
        room: RoomDisplayItem,
        plan: EntertainmentTakeoverPlan,
        consent: EntertainmentConsent? = nil,
        requester: EntertainmentRequester = .studio
    ) async -> EntertainmentStartResult {
        // The captured configuration, never a freshly selected one.
        let config = plan.capturedConfig
        guard let bridgeID = room.bridgeID,
              let api = hueClient(for: bridgeID),
              let clientKey = KeychainManager.shared.loadClientKey(for: bridgeID) else {
            return .unavailable(reason: .noBridgeCredentials)
        }

        // The choke point. Every Entertainment session in the app opens here,
        // so this is the one place that cannot be bypassed by a caller that
        // forgot to ask — including a future one.
        switch foreignConflictCheck(bridgeID: bridgeID,
                                    targetConfigID: config.id,
                                    consent: consent,
                                    snapshot: await entertainmentActivity(onBridge: bridgeID)) {
        case .clear:
            break
        case .needsConsent(let snapshot):
            // A foreign owner appeared between the caller's preflight and now.
            // Nothing has been mutated and nothing may be: falling back to
            // REST here would start playing over a show the user never agreed
            // to replace, just more quietly.
            return .needsForeignConsent(snapshot)
        case .refuse(let message):
            return .failed(message: message)
        }

        // The symmetric check (packet 7 hardware follow-up). The switch above
        // guards other apps' sessions; this guards our own. Without it a
        // composition opened a SECOND session on a bridge Strobe was already
        // streaming to — which either threw and was misread as an ordinary
        // technical failure (licensing a REST fallback under a live 25 fps
        // stream), or succeeded and orphaned Strobe's client with no stop.
        //
        // Studio is exempt because it evicts its own single-slot session a few
        // lines into its COMMIT block; a composition has no such slot and does
        // no such eviction.
        if requester == .composition,
           let owner = studioOwningEntertainment(onBridge: bridgeID) {
            debugLog("[Handoff] Composition wants bridge \(bridgeID), but '\(owner.engineKey)' in room \(owner.roomID) is streaming it — refusing rather than doubling up")
            return .unavailable(reason: .heldByAnotherChromaGlowLook)
        }

        do {
            let (ip, token) = try api.credentials()
            let entClient = HueEntertainmentClient(
                bridgeID: bridgeID,
                bridgeIP: ip,
                username: token,
                clientKeyHex: clientKey,
                restClient: api,
                ownership: entertainmentOwnership
            )
            #if DEBUG
            if let configure = entertainmentClientConfigurator {
                await configure(entClient)
            }
            #endif
            try await entClient.startSession(configID: config.id)

            // Verify, do not assume. `startSession` returning means the REST
            // activate was accepted and the handshake reported ready; this asks
            // the session itself whether it is actually streaming. Without it a
            // takeover could stop another app's show, fail to open its own, and
            // still publish ownership — which is exactly what the hardware pass
            // saw. Tear down rather than leave a half-open session behind.
            guard await entClient.hasStartedSession() else {
                debugLog("[Studio] Entertainment session never reached a usable state — refusing to claim it")
                await entClient.stopSession()
                noteTakeoverEvent(.chromaGlowSessionNotUsable, bridgeID: bridgeID, configID: config.id)
                noteTakeoverEvent(.nowPlayingWithheld, bridgeID: bridgeID, configID: nil)
                return .unavailable(reason: .streamingFailed)
            }
            noteTakeoverEvent(.chromaGlowSessionUsable, bridgeID: bridgeID, configID: config.id)

            // Deliberately NOT installed into studioEntClients here, and the
            // consent is deliberately NOT spent here. The final verification —
            // fresh bridge activity plus a second exact session-health check —
            // lives in `verifyAndCommitEntertainment`, immediately before the
            // commit, because there are suspension points between this return
            // and the caller's commit. A post-start read HERE could not see a
            // same-configuration reacquisition anyway: `startSession` has
            // already registered the target as process-owned, so the activity
            // reader classifies it as ours no matter who is streaming it.
            return .started(entClient)
        } catch {
            debugLog("[Studio] Entertainment start failed: \(error.localizedDescription) — falling back to REST")
            noteTakeoverEvent(.chromaGlowStartRequestFailed, bridgeID: bridgeID, configID: config.id)
            return .unavailable(reason: .streamingFailed)
        }
    }

    /// One of our streaming engines just stopped looping. If the session died
    /// rather than being cancelled, stop claiming it is playing.
    ///
    /// The composition path has always failed over here; the three Studio
    /// engines had no equivalent, so when the official Hue app reacquired the
    /// area their loops kept writing into a dead socket while Now Playing, the
    /// AREA badge and `studioOwningEntertainment` all went on reporting a live
    /// ChromaGlow stream. That is the "Take Over looked like it worked and then
    /// Hue took it straight back" symptom, seen from the inside.
    ///
    /// Deliberately narrow: it corrects what the app CLAIMS. It does not
    /// re-acquire, re-prompt, or arbitrate — that is Phase 2's job.
    private func reconcileStudioSessionAfterLoop(
        entClient: HueEntertainmentClient,
        bridgeID: String?,
        roomID: String
    ) async {
        let auditContext = StopAuditContext(route: .reconcileAfterLoop)
        // Same single await and the same outcomes as the original compound
        // guard — decomposed only so the DEBUG audit can say why this
        // invocation did (or did not) clean anything up.
        let terminallyFailed = await entClient.isTerminallyFailed
        guard terminallyFailed, let bridgeID else {
            recordStopAudit(auditContext, operation: .reconcileCleanup,
                            bridgeID: bridgeID, roomID: roomID,
                            clientID: Self.stopAuditToken(entClient),
                            outcomeReason: terminallyFailed
                                ? "skippedNilBridge" : "skippedClientHealthy")
            return
        }
        // Only if this exact client is still the installed owner. A loop that
        // ends after its session was already replaced must not tear down its
        // successor.
        guard studioEntClients[bridgeID] === entClient else {
            recordStopAudit(auditContext, operation: .reconcileCleanup,
                            bridgeID: bridgeID, roomID: roomID,
                            clientID: Self.stopAuditToken(entClient),
                            outcomeReason: "skippedClientReplaced")
            return
        }
        recordStopAudit(auditContext, operation: .reconcileCleanup,
                        bridgeID: bridgeID, roomID: roomID,
                        clientID: Self.stopAuditToken(entClient),
                        outcomeReason: "sessionLostCleanup")

        debugLog("[Takeover] Studio session on \(bridgeID) was lost — correcting the UI rather than claiming it still streams")
        noteTakeoverEvent(.sessionLostAfterOwnership, bridgeID: bridgeID,
                          configID: studioEntOwnerByBridge[bridgeID]?.configID)

        studioEntClients.removeValue(forKey: bridgeID)
        studioEntOwnerByBridge.removeValue(forKey: bridgeID)
        // The loop has already returned, so there is nothing to cancel — but
        // the runtime record must not outlive its session. Same identity
        // discipline as the client guard above: only this exact room's record,
        // never a successor's (round 4g).
        if studioEngineRuntimesByBridge[bridgeID]?.roomID == roomID {
            studioEngineRuntimesByBridge.removeValue(forKey: bridgeID)
        }
        recordStopAudit(auditContext, operation: .clientStopSession,
                        bridgeID: bridgeID, roomID: roomID,
                        clientID: Self.stopAuditToken(entClient))
        let stopRequest = await entClient.stopSession()
        recordStopAudit(auditContext,
                        operation: stopRequest == .notSent
                            ? .actionStopSuppressed : .actionStopSent,
                        bridgeID: bridgeID, roomID: roomID,
                        clientID: Self.stopAuditToken(entClient),
                        outcomeReason: String(describing: stopRequest))

        // The look is no longer streaming, so the row must stop saying it is
        // — exactly this bridge's row, never a same-room-id row on another.
        removeActiveEffect(bridgeID: bridgeID, roomID: roomID, context: auditContext)
        noteTakeoverEvent(.nowPlayingWithheld, bridgeID: bridgeID, configID: nil)
        toastMessage = EntertainmentConsentCopy.controllerResumed
    }

    // MARK: - Takeover instrumentation (hardware convergence slice A)
    //
    // Brian's device pass could tell that Take Over did not work, but not WHY:
    // the exact stop may have failed, the stop may have succeeded and Hue
    // reacquired, our own start may have failed, or ownership may simply have
    // been published too early. Those four have different fixes and the app
    // emitted nothing that separated them.
    //
    // Only observable facts are recorded. CLIP v2 does not name the controller
    // holding a configuration, so nothing here invents a foreign owner — the
    // vocabulary is limited to configuration activity, our own session state,
    // and the order the transitions were seen in.

    enum TakeoverEvent: String {
        case foreignStopRequestFailed
        /// The stop was accepted and the configuration was STILL active on the
        /// next read. No inactive state was ever observed, so this says exactly
        /// that: release not proven. It deliberately does NOT claim a
        /// reacquisition — that would assert a transition nobody watched.
        case foreignConfigurationRemainedActive
        /// An inactive state was actually observed. Everything below may only
        /// be recorded after this one.
        case foreignConfigurationStopped
        /// The SAME configuration was observed inactive and then active again
        /// before we committed. Hue Sync reclaiming what it just lost is the
        /// ordinary case, not the exotic one — but it is only recorded when the
        /// release was seen first.
        case foreignConfigurationReacquiredSameConfig
        /// A DIFFERENT configuration became active after an observed release.
        case foreignConfigurationReacquiredOtherConfig
        /// OUR release was requested but the target configuration was never
        /// observed inactive across the bounded post-release reads. The same
        /// honesty rule as `foreignConfigurationRemainedActive`, pointed at
        /// ourselves: "still active" here may simply be our own start not yet
        /// torn down, so no reacquisition — and no takeover prompt — may be
        /// built on it.
        case chromaGlowReleaseNotProven
        case chromaGlowStartRequestFailed
        case chromaGlowSessionNotUsable
        case chromaGlowSessionUsable
        case ownershipPublished
        case sessionLostAfterOwnership
        case nowPlayingWithheld
    }

    func noteTakeoverEvent(_ event: TakeoverEvent, bridgeID: String, configID: String?) {
        let target = configID.map { " config \($0)" } ?? ""
        debugLog("[Takeover] \(event.rawValue) — bridge \(bridgeID)\(target)")
        #if DEBUG
        takeoverEventLog.append(event)
        #endif
    }

    #if DEBUG
    /// Ordered, in-process record of the takeover transitions above. Lets a
    /// test assert WHICH failure happened, not merely that one did.
    private(set) var takeoverEventLog: [TakeoverEvent] = []
    func testResetTakeoverEventLog() { takeoverEventLog.removeAll() }
    #endif

    /// What the choke point decided about a foreign owner.
    private enum ForeignConflictVerdict {
        case clear
        case needsConsent(EntertainmentActivitySnapshot)
        case refuse(message: String)
    }

    /// Decide whether this start may proceed past a possible foreign owner.
    ///
    /// Consent is honoured only in the state that CAN follow a resolved
    /// takeover. `confirmForeignTakeover` performs the re-read and the exact
    /// stop, then hands over a token; by the time the token arrives here the
    /// foreign set must be empty — which covers both "we stopped it" and "it
    /// had already ended". Requiring the consented configuration to still be
    /// active would make a successful takeover contradict itself.
    private func foreignConflictCheck(
        bridgeID: String,
        targetConfigID: String,
        consent: EntertainmentConsent?,
        snapshot: EntertainmentActivitySnapshot?
    ) -> ForeignConflictVerdict {
        guard let snapshot else {
            // Unknown is not "nothing is running". Fail honestly rather than
            // evicting something we cannot see.
            return .refuse(message: EntertainmentConsentCopy.bridgeUnreadable)
        }

        guard let consent else {
            // No token: proceed only when nobody else is streaming.
            return snapshot.foreign.isEmpty ? .clear : .needsConsent(snapshot)
        }

        // A token authorizes exactly one request, on one bridge, for one
        // target area — and only once. A mismatched or spent token is not a
        // reason to re-ask; it is a bug or a replay, and it gets an honest
        // refusal rather than a second prompt that could loop.
        guard consent.bridgeID == bridgeID,
              consent.targetConfigID == targetConfigID else {
            return .refuse(message: EntertainmentConsentCopy.takeoverFailed)
        }
        guard !consumedEntertainmentConsents.contains(consent.requestID) else {
            debugLog("[Handoff] Consent \(consent.requestID) already spent — refusing to start twice")
            return .refuse(message: EntertainmentConsentCopy.takeoverFailed)
        }

        // The takeover must actually be resolved by the time the token gets
        // here. An empty foreign set is the only state that can follow one:
        // either the confirmation stopped the consented session, or it had
        // already ended on its own. Anything still streaming is something the
        // user never agreed to replace — so stale consent stops nothing, and
        // fresh consent is required.
        guard snapshot.foreign.isEmpty else {
            debugLog("[Handoff] Consent for \(consent.foreignConfigID) does not cover the \(snapshot.foreign.count) foreign session(s) now active — refusing")
            return .needsConsent(snapshot)
        }
        return .clear
    }

    /// Marks a consent token spent. Called once the takeover it authorized has
    /// been acted on, so a replayed confirm cannot start a second time.
    func consumeEntertainmentConsent(_ consent: EntertainmentConsent) {
        consumedEntertainmentConsents.insert(consent.requestID)
    }

    /// The Entertainment Area that safely belongs to this room, warming first.
    ///
    /// Room-shaped on purpose. The old bridge-only form returned `configs.first`,
    /// which is how a composition in one room streamed into another room's area;
    /// no bridge-only convenience is kept, because "any area on this bridge" is
    /// never a safe answer.
    private func findEntertainmentConfig(
        for room: RoomDisplayItem,
        preferredConfigID: String? = nil
    ) async -> EntertainmentConfig? {
        await warmEntertainmentCaches(for: room, force: true)
        return selectedEntertainmentConfig(for: room, preferredConfigID: preferredConfigID)
    }

    /// Everything a start attempt needs, chosen exactly once.
    ///
    /// Selection used to happen twice per Studio start — once to open the session,
    /// once more to read channel IDs — as two independent `configs.first` picks
    /// that only agreed by accident. One plan means the config ID handed to
    /// `startSession`, the channel IDs driving the render loop, and the spatial
    /// positions are guaranteed to describe the same area.
    ///
    /// Returns nil when no area safely matches OR when the selected area cannot
    /// produce usable channel IDs — so an unstreamable config can never get as far
    /// as opening a DTLS session.
    /// Routed through `decide`, not `select`: a room several areas could serve
    /// has no single start plan, and must not be given one silently. That case
    /// surfaces as `.choiceRequired` from `exactTargetDecision` instead.
    private func entertainmentStartPlan(
        for room: RoomDisplayItem,
        preferredConfigID: String? = nil
    ) -> (config: EntertainmentConfig, channelIDs: [UInt8])? {
        guard case .exact(let config)? = cachedAreaDecision(for: room, selectedConfigID: preferredConfigID),
              let channelIDs = EntertainmentAreaSelector.validatedChannelIDs(for: config)
        else { return nil }
        return (config, channelIDs)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Strobe Engine
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Strobe via Entertainment API — crisp on/off at 50fps streaming.
    /// Speed capped at 3Hz (WCAG 2.3.1 compliance).
    private func runStrobeEntertainment(
        entClient: HueEntertainmentClient,
        channelIDs: [UInt8],
        paramBox: StudioParamBox
    ) async {
        let frameInterval: UInt64 = 20_000_000  // 20ms = 50fps

        while !Task.isCancelled {
            // The session can die under us — the official Hue app reclaiming
            // the area is the ordinary way. Without this the loop streamed
            // into a dead socket forever while the UI kept claiming AREA.
            if await entClient.isTerminallyFailed { break }
            let p = paramBox.values
            let speed       = p["speed"]          ?? 50
            let peakBri     = (p["brightness"]    ?? 100) / 100.0
            let minBri      = (p["min_brightness"] ?? 0) / 100.0
            let dutyCycle   = (p["duty_cycle"]    ?? 50) / 100.0

            // Flash color — extract CIE xy from Color or default to white (D65)
            let xy = extractXY(from: paramBox.colors["flash_color"]) ?? (x: 0.3127, y: 0.3290)

            // Beat-locked: ON/OFF derived purely from clock phase each 20 ms
            // frame — zero drift, tempo changes land within one frame, and
            // wcagSafeBeatsPerCycle keeps the flash rate ≤3 Hz.
            let binding = BeatBinding.fromStudioValues(p)
            if let lock = BeatMath.liveLock(binding) {
                let phase = BeatMath.cyclePhase(at: CACurrentMediaTime(),
                                                snapshot: lock.snapshot,
                                                beatsPerCycle: lock.beatsPerCycle,
                                                phaseOffsetBeats: binding.phaseOffsetBeats)
                let bri = phase < dutyCycle ? peakBri : minBri
                await entClient.sendUniform(channelIDs: channelIDs, x: xy.x, y: xy.y, brightness: bri)
                try? await Task.sleep(nanoseconds: frameInterval)
                continue
            }

            // Speed 0–100 → 0.5–3.0 Hz (WCAG safe: never exceeds 3 flashes/sec)
            let hz = 0.5 + (speed / 100.0) * 2.5
            let period = 1.0 / hz
            let onDuration = period * dutyCycle
            let offDuration = period * (1.0 - dutyCycle)

            // ON phase
            let onFrames = max(1, Int(onDuration / 0.02))
            for _ in 0..<onFrames {
                guard !Task.isCancelled else { return }
                await entClient.sendUniform(channelIDs: channelIDs, x: xy.x, y: xy.y, brightness: peakBri)
                try? await Task.sleep(nanoseconds: frameInterval)
            }

            // OFF phase
            let offFrames = max(1, Int(offDuration / 0.02))
            for _ in 0..<offFrames {
                guard !Task.isCancelled else { return }
                await entClient.sendUniform(channelIDs: channelIDs, x: xy.x, y: xy.y, brightness: minBri)
                try? await Task.sleep(nanoseconds: frameInterval)
            }
        }
    }

    /// Strobe via REST — fallback when no entertainment config.
    /// Limited to ~1Hz by bridge rate limits. Shows toast suggesting entertainment setup.
    private func runStrobeREST(
        roomID: String,
        bridgeID: String?,
        api: HueAPIClient,
        groupedLightID: String,
        paramBox: StudioParamBox
    ) async {
        var on = true
        while !Task.isCancelled {
            let p = paramBox.values
            let peakBri = p["brightness"]     ?? 100
            let minBri  = p["min_brightness"] ?? 0

            let bri = on ? peakBri : max(1, minBri)

            await enqueueStudioRestWrite(roomID: roomID, bridgeID: bridgeID) { _ in
                try? await api.setGroupedLightEffect(
                    id: groupedLightID, on: bri > 1,
                    brightness: bri, xy: nil, mirek: nil,
                    duration: 0  // instant transition
                )
            }

            on.toggle()

            // Beat-locked REST: flip exactly on cycle boundaries, with the
            // beats-per-cycle floored so one flip never lands inside the
            // 900 ms REST cadence (maxHz = 1/0.9).
            let binding = BeatBinding.fromStudioValues(p)
            if let lock = BeatMath.liveLock(binding, maxHz: 1.0 / 0.9) {
                try? await BeatMath.sleepUntilNextCycle(
                    beatsPerCycle: lock.beatsPerCycle,
                    phaseOffsetBeats: binding.phaseOffsetBeats)
                if Task.isCancelled { break }
                continue
            }

            do {
                // REST rate limit: 900ms minimum between group commands
                try await Task.sleep(nanoseconds: 900_000_000)
            } catch { break }
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Party Engine
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Party via Entertainment — random color flashes at user-controlled speed.
    private func runPartyEntertainment(
        entClient: HueEntertainmentClient,
        channelIDs: [UInt8],
        paramBox: StudioParamBox
    ) async {
        let frameInterval: UInt64 = 20_000_000  // 50fps

        // Pre-built color palette: 8 vivid party colors (CIE xy)
        let palette: [(x: Double, y: Double)] = [
            (0.6400, 0.3300),  // Red
            (0.1500, 0.0600),  // Blue
            (0.1700, 0.7000),  // Green
            (0.3200, 0.1500),  // Purple
            (0.4500, 0.4100),  // Yellow
            (0.5400, 0.2300),  // Pink/Magenta
            (0.1600, 0.2300),  // Cyan
            (0.5600, 0.4000),  // Orange
        ]
        var colorIndex = 0

        while !Task.isCancelled {
            // The session can die under us — the official Hue app reclaiming
            // the area is the ordinary way. Without this the loop streamed
            // into a dead socket forever while the UI kept claiming AREA.
            if await entClient.isTerminallyFailed { break }
            let p = paramBox.values
            let speed       = p["speed"]          ?? 60
            let peakBri     = (p["brightness"]    ?? 90) / 100.0
            let minBri      = (p["min_brightness"] ?? 5) / 100.0
            let smoothness  = (p["smoothness"]    ?? 20) / 100.0
            // "Flash Color" biases every palette flash toward the chosen
            // tint (read live each cycle — no restart needed).
            let tint = extractXY(from: paramBox.colors["color"])

            // Beat-locked: color index AND hold/fade position both derived
            // from the clock each frame — the palette steps exactly on cycle
            // boundaries and the fade tracks the cycle, drift-free.
            let binding = BeatBinding.fromStudioValues(p)
            if let lock = BeatMath.liveLock(binding) {
                let now = CACurrentMediaTime()
                let idx = BeatMath.cycleIndex(at: now, snapshot: lock.snapshot,
                                              beatsPerCycle: lock.beatsPerCycle,
                                              phaseOffsetBeats: binding.phaseOffsetBeats)
                let phase = BeatMath.cyclePhase(at: now, snapshot: lock.snapshot,
                                                beatsPerCycle: lock.beatsPerCycle,
                                                phaseOffsetBeats: binding.phaseOffsetBeats)
                let color = Self.partyTinted(palette[((idx % palette.count) + palette.count) % palette.count], tint: tint)
                let hold = 1.0 - smoothness
                let bri: Double
                if phase < hold || smoothness <= 0 {
                    bri = peakBri
                } else {
                    let t = (phase - hold) / max(smoothness, 0.001)
                    bri = peakBri + (minBri - peakBri) * t
                }
                await entClient.sendUniform(channelIDs: channelIDs, x: color.x, y: color.y, brightness: bri)
                try? await Task.sleep(nanoseconds: frameInterval)
                continue
            }

            // Speed 0–100 → 0.5–3.0 Hz
            let hz = 0.5 + (speed / 100.0) * 2.5
            let period = 1.0 / hz
            let fadeFrames = max(1, Int(smoothness * period / 0.02))
            let holdFrames = max(1, Int((1.0 - smoothness) * period / 0.02))

            let color = Self.partyTinted(palette[colorIndex % palette.count], tint: tint)
            colorIndex += 1

            // Flash phase: hold at peak brightness
            for _ in 0..<holdFrames {
                guard !Task.isCancelled else { return }
                await entClient.sendUniform(channelIDs: channelIDs, x: color.x, y: color.y, brightness: peakBri)
                try? await Task.sleep(nanoseconds: frameInterval)
            }

            // Fade phase: linear fade from peak to min
            for i in 0..<fadeFrames {
                guard !Task.isCancelled else { return }
                let t = Double(i) / Double(fadeFrames)
                let bri = peakBri + (minBri - peakBri) * t
                await entClient.sendUniform(channelIDs: channelIDs, x: color.x, y: color.y, brightness: bri)
                try? await Task.sleep(nanoseconds: frameInterval)
            }
        }
    }

    /// Party via REST — fallback. Cycles colors at ~1/sec.
    private func runPartyREST(
        roomID: String,
        bridgeID: String?,
        api: HueAPIClient,
        groupedLightID: String,
        paramBox: StudioParamBox
    ) async {
        let palette: [(x: Double, y: Double)] = [
            (0.6400, 0.3300), (0.1500, 0.0600), (0.1700, 0.7000),
            (0.3200, 0.1500), (0.4500, 0.4100), (0.5400, 0.2300),
        ]
        var colorIndex = 0

        while !Task.isCancelled {
            let p = paramBox.values
            let bri = p["brightness"] ?? 90
            let smoothness = p["smoothness"] ?? 20
            let durationMs = Int(smoothness / 100.0 * 500)  // 0–500ms transition
            let tint = extractXY(from: paramBox.colors["color"])

            // Beat-locked REST: derive the palette index from the cycle count
            // and step exactly on boundaries (floored to the 1 s REST cadence).
            let binding = BeatBinding.fromStudioValues(p)
            let lock = BeatMath.liveLock(binding, maxHz: 1.0)
            let color: (x: Double, y: Double)
            if let lock {
                let idx = BeatMath.cycleIndex(at: CACurrentMediaTime(), snapshot: lock.snapshot,
                                              beatsPerCycle: lock.beatsPerCycle,
                                              phaseOffsetBeats: binding.phaseOffsetBeats)
                color = palette[((idx % palette.count) + palette.count) % palette.count]
            } else {
                color = palette[colorIndex % palette.count]
                colorIndex += 1
            }

            let tinted = Self.partyTinted(color, tint: tint)
            await enqueueStudioRestWrite(roomID: roomID, bridgeID: bridgeID) { _ in
                try? await api.setGroupedLightEffect(
                    id: groupedLightID, on: true,
                    brightness: bri, xy: (tinted.x, tinted.y), mirek: nil,
                    duration: durationMs
                )
            }

            if let lock {
                try? await BeatMath.sleepUntilNextCycle(
                    beatsPerCycle: lock.beatsPerCycle,
                    phaseOffsetBeats: binding.phaseOffsetBeats)
                if Task.isCancelled { break }
                continue
            }

            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)  // 1/sec rate limit
            } catch { break }
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Thunderstorm Engine
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Thunderstorm via Entertainment — ambient blue glow + random lightning strikes.
    private func runThunderstormEntertainment(
        entClient: HueEntertainmentClient,
        channelIDs: [UInt8],
        paramBox: StudioParamBox
    ) async {
        let frameInterval: UInt64 = 20_000_000  // 50fps
        // Deep blue ambient default
        let ambientXY = (x: 0.1548, y: 0.1220)

        while !Task.isCancelled {
            // The session can die under us — the official Hue app reclaiming
            // the area is the ordinary way. Without this the loop streamed
            // into a dead socket forever while the UI kept claiming AREA.
            if await entClient.isTerminallyFailed { break }
            let p = paramBox.values
            let frequency      = (p["frequency"]       ?? 50) / 100.0  // 0–1
            let flashIntensity = (p["flash_intensity"]  ?? 90) / 100.0
            let minBri         = (p["min_brightness"]   ?? 5) / 100.0

            // Ambient glow phase (variable duration based on frequency)
            // Higher frequency = shorter gaps between strikes
            let gapDuration = 2.0 - frequency * 1.8  // 0.2–2.0 seconds
            let gapFrames = max(5, Int(gapDuration / 0.02))

            for _ in 0..<gapFrames {
                guard !Task.isCancelled else { return }
                let ambientColor = extractXY(from: paramBox.colors["ambient_color"]) ?? ambientXY
                await entClient.sendUniform(channelIDs: channelIDs, x: ambientColor.x, y: ambientColor.y, brightness: minBri)
                try? await Task.sleep(nanoseconds: frameInterval)
            }

            // Beat-locked: keep streaming ambient frames until the next cycle
            // boundary so every strike opportunity lands on the grid. The
            // DTLS stream must never pause — waiting means sending ambient.
            let binding = BeatBinding.fromStudioValues(p)
            if BeatMath.liveLock(binding) != nil {
                let entrySnap = BeatClock.snapshot()
                let entryIdx = BeatMath.cycleIndex(at: CACurrentMediaTime(), snapshot: entrySnap,
                                                   beatsPerCycle: binding.beatsPerCycle,
                                                   phaseOffsetBeats: binding.phaseOffsetBeats)
                while !Task.isCancelled {
                    let snap = BeatClock.snapshot()
                    guard snap.bpm > 0 else { break }
                    if BeatMath.cycleIndex(at: CACurrentMediaTime(), snapshot: snap,
                                           beatsPerCycle: binding.beatsPerCycle,
                                           phaseOffsetBeats: binding.phaseOffsetBeats) != entryIdx { break }
                    let ambientColor = extractXY(from: paramBox.colors["ambient_color"]) ?? ambientXY
                    await entClient.sendUniform(channelIDs: channelIDs, x: ambientColor.x, y: ambientColor.y, brightness: minBri)
                    try? await Task.sleep(nanoseconds: frameInterval)
                }
                guard !Task.isCancelled else { return }
            }

            // Lightning strike — the storm's knobs, all params now (they were
            // literals; the defaults reproduce the old storm exactly):
            //   strike_rate  50 → chance 0.3 + 0.5·0.6 = 0.6, the old curve
            //   flash_length  3 → frames random 2…5, the old range
            //   afterglow     1 → frames random 1…2, the old range
            //   flash_color unset → D65 white, the old flash
            let strikeRate = (p["strike_rate"] ?? 50) / 100.0
            let strikeChance = 0.3 + strikeRate * 0.6  // 30%–90%
            guard Double.random(in: 0...1) < strikeChance else { continue }

            let flashXY = extractXY(from: paramBox.colors["flash_color"]) ?? (x: 0.3127, y: 0.3290)

            // Lightning flash: rapid bright frames with organic length jitter.
            let flashLength = Int(p["flash_length"] ?? 3)
            let flashFrames = Int.random(in: max(1, flashLength - 1)...(flashLength + 2))
            for _ in 0..<flashFrames {
                guard !Task.isCancelled else { return }
                await entClient.sendUniform(channelIDs: channelIDs, x: flashXY.x, y: flashXY.y, brightness: flashIntensity)
                try? await Task.sleep(nanoseconds: frameInterval)
            }

            // Afterglow at 40% intensity; 0 disables it outright.
            let afterglowBase = Int(p["afterglow"] ?? 1)
            let afterglow = afterglowBase == 0 ? 0 : Int.random(in: afterglowBase...(afterglowBase + 1))
            for _ in 0..<afterglow {
                guard !Task.isCancelled else { return }
                await entClient.sendUniform(channelIDs: channelIDs, x: flashXY.x, y: flashXY.y, brightness: flashIntensity * 0.4)
                try? await Task.sleep(nanoseconds: frameInterval)
            }
        }
    }

    /// Thunderstorm via REST — fallback. Random brightness spikes.
    private func runThunderstormREST(
        roomID: String,
        bridgeID: String?,
        api: HueAPIClient,
        groupedLightID: String,
        paramBox: StudioParamBox
    ) async {
        while !Task.isCancelled {
            let p = paramBox.values
            let frequency      = (p["frequency"]       ?? 50) / 100.0
            let flashIntensity = p["flash_intensity"]   ?? 90
            let minBri         = max(1, p["min_brightness"] ?? 5)
            // The REST storm used to ignore both colors — the DTLS path tinted
            // and REST silently didn't. Nil (user never picked one) still sends
            // no xy, preserving the old look for untouched cards.
            let ambientXY = extractXY(from: paramBox.colors["ambient_color"])
            let flashXY   = extractXY(from: paramBox.colors["flash_color"])

            // Ambient dim
            await enqueueStudioRestWrite(roomID: roomID, bridgeID: bridgeID) { _ in
                try? await api.setGroupedLightEffect(
                    id: groupedLightID, on: true,
                    brightness: minBri, xy: ambientXY, mirek: nil,
                    duration: 400
                )
            }

            // Wait for random gap
            let gap = UInt64((2.0 - frequency * 1.5) * 1_000_000_000)
            do { try await Task.sleep(nanoseconds: max(500_000_000, gap)) } catch { break }

            // Beat-locked REST: hold the strike until the next cycle boundary
            // (floored to 2 Hz so the alignment wait stays REST-friendly).
            let binding = BeatBinding.fromStudioValues(p)
            if let lock = BeatMath.liveLock(binding, maxHz: 2.0) {
                try? await BeatMath.sleepUntilNextCycle(
                    beatsPerCycle: lock.beatsPerCycle,
                    phaseOffsetBeats: binding.phaseOffsetBeats)
                if Task.isCancelled { break }
            }

            // Random lightning — strike_rate default 50 reproduces the old
            // frequency-driven chance exactly (0.3 + 0.5·0.5).
            let strikeRate = (p["strike_rate"] ?? 50) / 100.0
            let strikeChance = 0.3 + strikeRate * 0.5
            guard Double.random(in: 0...1) < strikeChance else { continue }

            await enqueueStudioRestWrite(roomID: roomID, bridgeID: bridgeID) { _ in
                try? await api.setGroupedLightEffect(
                    id: groupedLightID, on: true,
                    brightness: flashIntensity, xy: flashXY, mirek: nil,
                    duration: 0  // instant flash
                )
            }

            do { try await Task.sleep(nanoseconds: 200_000_000) } catch { break }
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Ambient Engine
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Ambient via REST — slow sine wave between min and max brightness.
    /// Smooth enough for REST since changes happen every ~1 second.
    private func runAmbientREST(
        roomID: String,
        bridgeID: String?,
        api: HueAPIClient,
        groupedLightID: String,
        paramBox: StudioParamBox
    ) async {
        var phase: Double = 0

        while !Task.isCancelled {
            let p = paramBox.values
            let speed       = p["speed"]          ?? 30
            let peakBri     = p["brightness"]     ?? 70
            let minBri      = max(1, p["min_brightness"] ?? 15)
            let warmth      = p["warmth"]         ?? 350
            let smoothness  = (p["smoothness"]    ?? 70) / 100.0

            // Speed 0–100 → period 8s (slow) to 2s (fast)
            let period = 8.0 - (speed / 100.0) * 6.0
            let dt = 1.0  // update every 1 second

            // Beat-locked: breathing phase derived from the clock (trough on
            // the cycle boundary, swelling into the bar) instead of the
            // accumulated free-run phase. Floored to ≥1 s cycles so the 1 s
            // REST cadence can actually draw the wave.
            let binding = BeatBinding.fromStudioValues(p)
            let sine: Double
            if let lock = BeatMath.liveLock(binding, maxHz: 1.0) {
                let cp = BeatMath.cyclePhase(at: CACurrentMediaTime(), snapshot: lock.snapshot,
                                             beatsPerCycle: lock.beatsPerCycle,
                                             phaseOffsetBeats: binding.phaseOffsetBeats)
                sine = sin(cp * 2.0 * .pi - .pi / 2.0)
            } else {
                phase += dt * (2.0 * .pi) / period
                sine = sin(phase)  // -1 to +1
            }

            // Brightness oscillation
            let range = peakBri - minBri
            let targetBri = minBri + (sine + 1.0) / 2.0 * range
            let clampedBri = max(1, min(100, targetBri))

            // Transition duration based on smoothness
            let transitionMs = Int(smoothness * 2000)  // 0–2000ms

            let mirek = Int(warmth.rounded())

            await enqueueStudioRestWrite(roomID: roomID, bridgeID: bridgeID) { _ in
                try? await api.setGroupedLightEffect(
                    id: groupedLightID, on: true,
                    brightness: clampedBri, xy: nil, mirek: mirek,
                    duration: transitionMs
                )
            }

            do {
                try await Task.sleep(nanoseconds: UInt64(dt * 1_000_000_000))
            } catch { break }
        }
    }

    // MARK: - Color Extraction Helper

    /// Extract CIE xy from a SwiftUI Color, or return nil for default handling.
    /// Party "Flash Color": bias a palette flash toward the user's tint
    /// (50% xy blend) — keeps the multi-color character while honoring the
    /// picker, which was previously never read by the party loops.
    nonisolated static func partyTinted(_ color: (x: Double, y: Double),
                                        tint: (x: Double, y: Double)?) -> (x: Double, y: Double) {
        guard let tint else { return color }
        return ((color.x + tint.x) / 2, (color.y + tint.y) / 2)
    }

    private func extractXY(from color: Color?) -> (x: Double, y: Double)? {
        guard let color else { return nil }
        let uiColor = UIColor(color)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
        uiColor.getHue(&h, saturation: &s, brightness: &b, alpha: nil)
        // If it's basically white (low saturation), return D65 white point
        if s < 0.05 { return (0.3127, 0.3290) }
        return HueColorUtils.xyFrom(hue: Double(h), saturation: Double(s), brightness: Double(b))
    }

    /// Returns the HueAPIClient for a specific bridge ID — used by RoomDetailViewModel
    /// to ensure the correct bridge credentials are used for per-light operations.
    func hueClient(for bridgeID: String?) -> HueAPIClient? {
        guard let id = bridgeID else {
            // nil bridgeID = a legacy pre-multi-bridge room (cached before
            // loadAll backfilled identities). Those can only exist in a
            // single-bridge home, so the sole registered client IS its
            // bridge; with several bridges nil stays unresolvable — guessing
            // would reintroduce the wrong-bridge class (M-07/H-05/M-18).
            return clients.count == 1 ? clients.values.first : nil
        }
        return clients[id]
    }

    /// Resolves a client by bridge LAN IP — for artifacts that recorded only
    /// the host (e.g. BridgeAnimationManifest.bridgeIP, M-07). Routing only;
    /// identity is still enforced by the pinned TLS evaluator on connect.
    func hueClient(forBridgeIP ip: String) -> HueAPIClient? {
        clients.values.first { (try? $0.credentials())?.ip == ip }
    }

    /// Display name for a registered bridge (used by pickers).
    func bridgeName(for bridgeID: String) -> String? {
        clients[bridgeID]?.bridgeName
    }

    /// What an explicit "Save to bridge" actually produced.
    ///
    /// Four outcomes, none of which may be represented by "it started playing".
    /// The ordinary composition start is allowed to fall back to app-driven
    /// playback when a bridge upload fails — that is a good default for a tap
    /// that meant "play this". It is a bad answer for a tap that meant "put
    /// this ON THE BRIDGE", because the user is then told a save succeeded when
    /// nothing was saved.
    enum BridgeSaveOutcome: Equatable {
        /// Resources created, manifest durable, chain confirmed started.
        case savedAndRunning(manifestID: UUID, bridgeID: String)
        /// Resources created and the manifest IS durable, but the chain did not
        /// start. Not a success and not a loss: the manifest is the exact
        /// evidence that keeps these resources stoppable, so it is retained and
        /// an exact Stop is offered immediately. `previousLookRemoved` reports
        /// whether this bridge's PROVEN bridge-stored predecessor was destroyed
        /// by the required replacement cleanup (round 4c). Round 4f: whether
        /// "nothing plays in the room now" is TRUE is a separate,
        /// cross-continuation question — `presentationFence` carries that
        /// authorization, and the caller must revalidate it at the moment it
        /// mutates presentation state (a newer playback may have taken this
        /// exact bridge+room while the save was suspended, or between this
        /// return and the caller's continuation).
        case savedNotConfirmedRunning(manifestID: UUID, bridgeID: String,
                                      previousLookRemoved: Bool,
                                      presentationFence: SavedLookPresentationFence?)
        /// Nothing was left on the bridge — either nothing was created, or what
        /// was created was cleaned up exactly.
        case nothingRecorded(reason: String)
        /// Creation partly succeeded and cleanup could not finish. Carries the
        /// exact identity — manifest and bridge — because that identity IS the
        /// user's only handle on what remains: the result sheet's Stop targets
        /// it directly. `recoverableAfterRelaunch` reports whether a durable
        /// quarantine record survived; false means the honest sentence is
        /// "recovery after closing the app is not guaranteed", never silence.
        case partialCleanupFailure(manifestID: UUID, bridgeID: String,
                                   recoverableAfterRelaunch: Bool, reason: String)
        /// Another save for this exact bridge + room is still in flight. This
        /// request performed ZERO bridge writes — two saves creating and
        /// replacing the same room's resources under each other is how a Stop
        /// button ends up pointed at the wrong manifest.
        case saveAlreadyInProgress(reason: String)
        /// The one exceptional state a failed save can leave (round 4b): the
        /// room was PLAYING a bridge-stored look, the required replacement
        /// cleanup removed that chain (two chains cannot coexist), and the
        /// new upload then failed — so nothing of OURS is on the bridge now.
        /// Typed, because every claim belonging to the former chain must fall
        /// with it: a notice-only report would leave the UI asserting a look
        /// that provably no longer exists. Round 4c: returned only for a
        /// PROVEN exact predecessor on `bridgeID` — the destroyed chain's own
        /// bridge — so the caller's cleanup can be exact too; another bridge's
        /// claim on the same room id can never produce this outcome. Round 4f:
        /// this case deliberately carries NO user-facing reason string. "The
        /// previous look was removed and nothing is playing" is a
        /// cross-continuation claim — a newer playback can own the room by the
        /// time the caller applies this outcome — so the wording must be
        /// chosen at apply time, from `presentationFence` revalidation, never
        /// frozen here.
        case previousLookRemovedSaveFailed(bridgeID: String,
                                           presentationFence: SavedLookPresentationFence?)
    }

    /// Authorization to withdraw a saved look's LIVE PRESENTATION mirrors —
    /// the VM's exact running row and its active `CompositionParamBox`
    /// (round 4f).
    ///
    /// Minted only when the orchestrator proved, in one synchronous
    /// main-actor turn, that the destroyed chain was the exact bridge+room's
    /// RUNNING look and that no newer playback took the key while the bridge
    /// operation was suspended. It is deliberately NOT defined by whether a
    /// Now Playing row happened to exist — it authorizes cleaning every
    /// presentation mirror, and a missing row must not protect a stale one.
    ///
    /// The token is revalidatable because the authorization itself can go
    /// stale: between the orchestrator's return and the caller's main-actor
    /// continuation, another task may start a new playback on the same exact
    /// key. Callers MUST pass it back through `presentationFenceHolds(_:)`
    /// immediately before mutating presentation state.
    struct SavedLookPresentationFence: Equatable, Sendable {
        let bridgeID: String
        let roomID: String
        /// `roomOwnershipGeneration(bridgeID:roomID:)` at authorization.
        let roomOwnershipGeneration: Int
        /// The exact `CompositionPlaybackKey` generation at authorization —
        /// nil means no runtime generation existed, and nil-versus-value is
        /// compared exactly on revalidation.
        let playbackGeneration: Int?
    }

    /// What the exact saved-look Stop actually did (round 4f).
    ///
    /// The old `Bool` conflated "already gone", "bridge unreachable",
    /// "retired an inert manifest" and "withdrew the room's running look" —
    /// so the caller could neither clean up a genuinely stopped look nor
    /// leave a live one alone. Each case now carries enough identity and
    /// truth for the caller to act exactly.
    enum SavedLookStopOutcome: Equatable {
        /// The bridge confirmed deletion and the manifest was retired.
        /// `removedRunningOwnership`: the manifest was in the ownership
        /// ledger when the stop began (an inert saved-not-confirmed manifest
        /// never is). `exactOwnershipSetEmptied`: this exact bridge+room's
        /// ownership set is now empty. `presentationFence`: non-nil is the
        /// (revalidatable) authorization to withdraw live presentation.
        case removed(manifestID: UUID, bridgeID: String, roomID: String,
                     removedRunningOwnership: Bool,
                     exactOwnershipSetEmptied: Bool,
                     presentationFence: SavedLookPresentationFence?)
        /// No manifest with that id exists. Nothing to remove is a success,
        /// not a failure.
        case alreadyAbsent
        /// The bridge could not be reached, refused part of the cleanup, or
        /// the manifest changed while the deletes were in flight. The
        /// manifest is retained; nothing was withdrawn.
        case failed

        /// Compatibility read for callers that only need success/failure —
        /// the same convention as `PlaybackStartOutcome.startedStreaming`.
        var succeeded: Bool {
            if case .failed = self { return false }
            return true
        }
    }

    /// Exact bridge+room pairs with a strict save in flight. Claimed before
    /// the first await (this class is @MainActor, so the claim is atomic),
    /// released in the same defer that returns the outcome.
    @ObservationIgnored private var strictSavesInFlight: Set<String> = []

    /// The bridge/store half of a bridge-stored save — and NOTHING of its
    /// playback half (round 4).
    ///
    /// Both entry points run exactly this: ordinary Play from inside
    /// `startCompositionMode` (which already replaced the room's look before
    /// calling, because playing IS a replacement), and the transactional
    /// Save to Bridge, which must leave the room's current look untouched
    /// until a saved chain is confirmed. One implementation, so the
    /// cleanup-readiness, compensation, and quarantine rules cannot drift
    /// between them.
    enum BridgeStoredAttempt {
        /// Resources created, manifest durable, chain confirmed started.
        case saved(BridgeAnimationManifest)
        /// Resources created and tracked; the chain did not start. The
        /// manifest is retained — it is the exact evidence that keeps the
        /// resources stoppable.
        case savedNotConfirmedRunning(BridgeAnimationManifest)
        /// The previous bridge look could not be provably cleaned up first.
        /// Nothing was created.
        case replacementBlocked
        /// The upload failed; nothing was created. Carries the error so the
        /// ordinary-play caller can classify its documented REST fallback.
        case uploadFailed(Error)
        /// The manifest did not persist, and compensation proved COMPLETE:
        /// nothing remains anywhere.
        case compensatedNothingRemains
        /// The manifest did not persist and compensation could NOT finish:
        /// the manifest is retained and quarantined (durably when possible).
        case partialCleanup(manifestID: UUID, bridgeID: String, recoverableAfterRelaunch: Bool)
    }

    /// Withdraw the claims of DESTROYED bridge-stored chain(s), exactly
    /// (round 4c). The ONE cleanup rule shared by the save-failure paths and
    /// the exact Stop, so their semantics cannot drift:
    ///
    /// - ownership: ONLY `destroyedManifestIDs` are subtracted at
    ///   (bridgeID, roomID); the key disappears only when its set empties, so
    ///   a surviving chain on the same bridge + room keeps its claim;
    /// - the live Now Playing row for exactly this bridge + room is removed
    ///   only when the CALLER'S `ownershipEvidence` proves a destroyed chain
    ///   was this key's running claim AND that key's ownership is now empty
    ///   AND `presentationFenceHeld` — another bridge's row for the same room
    ///   id is out of reach by key, recovered rows by construction;
    /// - transport (round 4e): only THIS bridge+room's exact `.bridgeStored`
    ///   claim falls, and only when its ownership set emptied. The roomID-keyed
    ///   entry is a display aggregate recomputed from the surviving exact
    ///   claims — another bridge's claim keeps it alive — with the round-4c
    ///   fail-closed rule intact: standing bridge-stored evidence (any bridge's
    ///   manifest — an ambiguous legacy manifest counts — or a recovered
    ///   animation) retains the label, excluding `retainedManifestIDs`, because
    ///   a just-saved inert chain is not the room's playing look.
    ///
    /// Round 4f: `ownershipEvidence` is REQUIRED and must be captured by the
    /// caller BEFORE its own destructive cleanup ran. This function must not
    /// read the ledger as evidence: by the time it runs, `retireManifest`
    /// (stop path) or the replacement cleanup (save paths) has already
    /// subtracted the destroyed chain, so a nil key here cannot distinguish
    /// "this chain WAS the running look and just emptied" from "this chain
    /// never ran at all" — and removing a live publication on a merely-nil
    /// key is exactly how an inert manifest's Remove used to unpublish the
    /// room's still-running REST look. `presentationFenceHeld` is the
    /// caller's proof that no newer playback took this exact key while its
    /// bridge operation was suspended; a broken fence withdraws ownership and
    /// stale claims but never the newer look's publication.
    private func withdrawDestroyedBridgeStoredClaims(
        bridgeID: String, roomID: String,
        destroyedManifestIDs: Set<UUID>,
        ownershipEvidence: Set<UUID>,
        presentationFenceHeld: Bool,
        retainedManifestIDs: Set<UUID> = []
    ) {
        let key = BridgeNativeOwnershipKey(bridgeKey: bridgeID, roomID: roomID)
        let destroyedWereRunningOwners =
            !ownershipEvidence.isDisjoint(with: destroyedManifestIDs)
        if var owned = bridgeStoredChainOwnership[key] {
            owned.subtract(destroyedManifestIDs)
            if owned.isEmpty {
                bridgeStoredChainOwnership.removeValue(forKey: key)
            } else {
                bridgeStoredChainOwnership[key] = owned
            }
        }
        if destroyedWereRunningOwners, bridgeStoredChainOwnership[key] == nil {
            if presentationFenceHeld {
                removeActiveEffect(bridgeID: bridgeID, roomID: roomID)
            }
            // Round 4e: the exact transport claim falls WITH the emptied
            // ownership set — only this bridge+room's `.bridgeStored` claim,
            // so another bridge's same-room-id claim (and therefore the
            // room aggregate) survives, and a newer `.rest`/`.entertainment`
            // claim on this key is never touched. The recompute inside
            // applies the round-4c fail-closed evidence rule, excluding the
            // just-saved inert manifests that are not the room's playing look.
            let playbackKey = CompositionPlaybackKey(
                bridgeKey: key.bridgeKey, roomID: key.roomID)
            if compositionTransportClaims[playbackKey] == .bridgeStored {
                removeCompositionTransportClaim(
                    for: playbackKey, retainedManifestIDs: retainedManifestIDs)
            }
        }
    }

    private func attemptBridgeStoredSave(
        room: RoomDisplayItem,
        preset: CompositionPreset,
        lightIDs: [String],
        gamut: HueColorUtils.Gamut,
        bridgeID: String,
        api: HueAPIClient
    ) async -> BridgeStoredAttempt {
        let v1Client: HueV1Client
        do { v1Client = try api.makeV1Client() }
        catch { return .uploadFailed(error) }

        // Clean up only what THIS room owns on THIS bridge (packet 2), and
        // REFUSE TO CREATE until that cleanup is provably complete (packet
        // 8). Two recurring rule chains driving one room is not an
        // accumulation risk to tidy up later — both keep firing, they fight
        // over every light, and the app has a record of only the newer one.
        let readiness = await cleanupBridgeStoredAnimationForReplacement(
            roomID: room.id, bridgeID: bridgeID, v1Client: v1Client)
        if case .blocked(let reason, let retained) = readiness {
            debugLog("[Composer] ⚠ Refusing bridge-stored upload for room=\(room.id): \(reason) (retained \(retained.count) manifest(s))")
            return .replacementBlocked
        }

        debugLog("[Composer] ⚡ Attempting bridge-stored upload for '\(preset.name)'")
        // M-04: the engine maps v2 UUIDs → v1 numeric ids via id_v1
        // identity, so it needs the v2 light objects. One retry — a
        // transient fetch failure here would silently demote the
        // "close the app, lights keep going" path to app-driven.
        var v2Lights = (try? await api.fetchLights()) ?? []
        if v2Lights.isEmpty {
            try? await Task.sleep(for: .milliseconds(300))
            v2Lights = (try? await api.fetchLights()) ?? []
        }
        if v2Lights.isEmpty {
            debugLog("[Composer] ⚠ Could not fetch lights for id_v1 mapping — the upload will refuse rather than guess")
        }

        let manifest: BridgeAnimationManifest
        do {
            manifest = try await bridgeAnimationEngine.upload(
                preset: preset,
                room: room,
                lightIDs: lightIDs,
                v2Lights: v2Lights,
                gamut: gamut,
                v1Client: v1Client
            )
        } catch {
            return .uploadFailed(error)
        }

        // ── Durable BEFORE running ────────────────────────
        //
        // Stamp the stable bridge identity here, where it is exact. The
        // engine only ever sees a client, which knows its host but not
        // which BridgeRecord it is — and an IP alone strands the
        // manifest the moment DHCP moves the bridge.
        let owned = manifest.adoptingBridgeID(bridgeID)

        // The manifest is the only thing that can name these resources
        // later, so it goes to disk before they are allowed to run. A
        // write that failed used to be indistinguishable from one that
        // worked, and the animation started regardless — which is how a
        // bridge ends up running a look the app cannot see or stop.
        guard bridgeAnimationStore.save(owned) else {
            debugLog("[Composer] Manifest for '\(preset.name)' did not persist — removing the resources it named")
            let cleanup = await bridgeAnimationEngine.stop(manifest: owned, v1Client: v1Client)

            if cleanup == .removed {
                // Compensation proved complete — the forget funnel's
                // standard of evidence is met, and nothing remains to name.
                forgetManifestRecord(id: owned.id)
                return .compensatedNothingRemains
            }

            // Compensation is INCOMPLETE: resources the manifest names may
            // still exist on the bridge, and this manifest is the only exact
            // handle on them. It is retained, and quarantined DURABLY before
            // the failure is reported: the normal persist just failed, so
            // only an independent record survives a relaunch to feed
            // reconciliation and the exact Stop.
            let durable = bridgeAnimationStore.quarantine(owned)
            return .partialCleanup(
                manifestID: owned.id, bridgeID: bridgeID,
                recoverableAfterRelaunch: durable)
        }

        // Only now may it start.
        do {
            try await bridgeAnimationEngine.activate(manifest: owned, v1Client: v1Client)
        } catch {
            debugLog("[Composer] '\(preset.name)' persisted but did not start: \(error.localizedDescription)")
            return .savedNotConfirmedRunning(owned)
        }
        return .saved(owned)
    }

    /// The bridge chain's step-0, sent immediately: the first bridge rule
    /// won't fire until the schedule ticks (up to a full cycle away), so the
    /// room turns on instantly instead of sitting dark.
    private func sendBridgeStoredPrimeFrame(
        preset: CompositionPreset,
        gamut: HueColorUtils.Gamut,
        api: HueAPIClient,
        groupedLightID: String,
        roomName: String
    ) async {
        let paramBox = CompositionParamBox(preset: preset)
        guard let firstFrame = CompositionEngine.render(
            time: 0, channelIDs: [0], params: paramBox
        ).first else { return }
        let primeXY = HueColorUtils.clampXYToGamut(x: firstFrame.x, y: firstFrame.y, gamut: gamut)
        let primeBri = max(1.0, firstFrame.brightness * 100.0)
        do {
            try await api.setGroupedLightEffect(
                id: groupedLightID, on: true,
                brightness: primeBri,
                xy: (primeXY.x, primeXY.y),
                mirek: nil,
                duration: 500
            )
            debugLog("[Composer][BridgePrime] ✅ room='\(roomName)' bri=\(String(format: "%.1f", primeBri))")
        } catch {
            debugLog("[Composer][BridgePrime] ⚠ Prime frame failed (bridge animation still active): \(error.localizedDescription)")
        }
    }

    /// Save a look onto the bridge — TRANSACTIONALLY with respect to whatever
    /// is playing (round 4).
    ///
    /// The previous shape delegated to `startCompositionMode`, whose very
    /// first playback mutations (the generation bump, the telemetry session,
    /// the ownership note) replace the room's current look — so a save that
    /// went on to FAIL had already invalidated the runtime it was supposed to
    /// be saving, and the scheduler removed the playing look as stale. Every
    /// preflight and the whole bridge/store attempt now run with ZERO
    /// playback mutations; the room's look is replaced only after a saved
    /// chain is CONFIRMED running on the bridge.
    ///
    /// Non-success outcomes and what they leave behind:
    /// - ineligible / busy / no-lights / unreadable / blocked / upload-failed
    ///   / compensated: nothing anywhere; the current look untouched.
    /// - `savedNotConfirmedRunning`: resources exist on the bridge but the
    ///   chain is NOT running (activation is the only thing that starts it),
    ///   so the current look keeps playing and is NOT replaced — the one
    ///   deliberate divergence from ordinary play, which has no look to
    ///   preserve. The manifest is retained and the result's exact Stop can
    ///   remove the inert resources immediately.
    /// - `partialCleanupFailure`: leftover resources, inert for the same
    ///   reason; current look untouched; quarantined handle carried.
    func saveLookToBridge(
        room: RoomDisplayItem,
        paramBox: CompositionParamBox,
        gamutOverride: HueColorUtils.Gamut?,
        preset: CompositionPreset
    ) async -> BridgeSaveOutcome {
        // Eligibility is answered HERE, not by silently taking another branch.
        // A reactive or moving look is not a bridge look, and the honest answer
        // is to say so — not to start it from the phone and call that a save.
        guard preset.canRunOnBridge else {
            return .nothingRecorded(reason: BridgeSaveCopy.ineligibleReactive)
        }
        guard preset.capabilityTier == .bridgeOptimized else {
            return .nothingRecorded(reason: BridgeSaveCopy.ineligibleMotion)
        }

        // One save per exact bridge + room. The first save owns the
        // transaction; a second one arriving while it is suspended must not
        // create or replace resources underneath it — it refuses, typed,
        // having touched nothing.
        let gateKey = "\(room.bridgeID ?? "legacy")|\(room.id)"
        guard !strictSavesInFlight.contains(gateKey) else {
            return .saveAlreadyInProgress(reason: BridgeSaveCopy.saveAlreadyInProgress)
        }
        strictSavesInFlight.insert(gateKey)
        defer { strictSavesInFlight.remove(gateKey) }

        // ── Preflight: zero playback mutations ──
        guard let bridgeID = room.bridgeID,
              let api = hueClient(for: bridgeID),
              let groupedLightID = room.groupedLightID else {
            return .nothingRecorded(reason: EntertainmentConsentCopy.bridgeUnreadable)
        }
        // The one claim a failed save CAN orphan (round 4b): a room whose
        // current look is itself bridge-stored. Replacement cleanup must
        // destroy that chain before the new upload can fail — two chains
        // cannot coexist — so a failure afterwards leaves nothing on the
        // bridge while the claims still assert the old look.
        //
        // Round 4c: the predecessor is EXACT identity, captured before any
        // bridge write. The ownership ledger names which manifests stand as
        // THIS bridge's running claim on THIS room, and the store must
        // corroborate every one of them; the roomID-keyed transport map
        // appears nowhere in this proof, because it cannot say which bridge —
        // bridge A's claim must never lend destructive authority to a save
        // targeting bridge B. An unresolvable legacy manifest in the room
        // fails the whole proof closed: identity that cannot be attributed
        // can neither prove a predecessor nor prove its absence.
        let predecessorChain = bridgeStoredChainOwnership[
            BridgeNativeOwnershipKey(bridgeKey: bridgeID, roomID: room.id)] ?? []
        let hadAmbiguousRoomManifest = bridgeAnimationStore.allManifests().contains {
            $0.roomID == room.id && resolvedBridgeID(for: $0) == nil
        }
        let provenExactPredecessor = !predecessorChain.isEmpty
            && !hadAmbiguousRoomManifest
            && predecessorChain.isSubset(
                of: Set(exactManifests(bridgeID: bridgeID, roomID: room.id).map(\.id)))
        // Round 4f: the presentation fence for the two destructive-failure
        // arms, captured before ANY suspension. The attempt below awaits the
        // bridge; a newer playback can take this exact bridge+room while it
        // is suspended, and destroying the predecessor's claims must then
        // leave the newer look's presentation alone. The fence is the same
        // exactness rule the stop path uses: ownership generation, exact
        // playback generation (nil preserved), and no standing live claim.
        let savePlaybackKey = CompositionPlaybackKey(
            bridgeKey: bridgeID, roomID: room.id)
        let fencedOwnershipGeneration = roomOwnershipGeneration(
            bridgeID: bridgeID, roomID: room.id)
        let fencedPlaybackGeneration = compositionGenerations[savePlaybackKey]
        func presentationFenceStillHeld() -> Bool {
            let standingClaim = compositionTransportClaims[savePlaybackKey]
            return roomOwnershipGeneration(bridgeID: bridgeID, roomID: room.id)
                    == fencedOwnershipGeneration
                && compositionGenerations[savePlaybackKey] == fencedPlaybackGeneration
                && standingClaim != .rest && standingClaim != .entertainment
        }
        func mintedPresentationFence() -> SavedLookPresentationFence {
            SavedLookPresentationFence(
                bridgeID: bridgeID, roomID: room.id,
                roomOwnershipGeneration: fencedOwnershipGeneration,
                playbackGeneration: fencedPlaybackGeneration)
        }
        let lightIDs: [String]
        switch await resolveCompositionLights(for: room, api: api) {
        case .noneInRoom:
            return .nothingRecorded(reason: BridgeSaveCopy.saveFailedNoLights)
        case .unresolved:
            return .nothingRecorded(reason: BridgeSaveCopy.saveFailedLightsUnresolved)
        case .lights(let ids):
            lightIDs = ids
        }
        let gamut: HueColorUtils.Gamut
        if let gamutOverride { gamut = gamutOverride }
        else { gamut = await resolveCompositionGamut(for: room, api: api) }

        // ── The attempt: bridge and manifest store only ──
        switch await attemptBridgeStoredSave(
            room: room, preset: preset, lightIDs: lightIDs,
            gamut: gamut, bridgeID: bridgeID, api: api) {

        case .saved(let owned):
            // ── COMMIT: only now does playback state change ──
            //
            // The chain is confirmed running on the bridge, so the app-driven
            // look must yield — two engines driving one room fight over every
            // light. This is the same replacement ordinary play performs at
            // its head, done at the tail instead, where failure can no longer
            // reach it.
            let roomID = room.id
            let playbackKey = CompositionPlaybackKey(
                bridgeID: room.bridgeID, roomID: roomID)
            let nextGeneration = (compositionGenerations[playbackKey] ?? 0) + 1
            compositionGenerations[playbackKey] = nextGeneration
            beginComposerTelemetrySession(
                sessionKey: ComposerTelemetrySessionKey(
                    bridgeKey: room.bridgeID ?? "legacy",
                    scope: RestScope(roomID: roomID, owner: .composer)),
                generation: nextGeneration)
            // Confirmed running — the ownership ledger's standard of
            // evidence (round 4c). This is the strict save's ONLY ledger
            // write; savedNotConfirmedRunning below never records. The record
            // also raises the exact `.bridgeStored` transport claim (4e).
            recordBridgeStoredChainOwnership(
                bridgeID: bridgeID, roomID: roomID, manifestID: owned.id)
            noteRoomOwnershipChange(bridgeID: bridgeID, roomID: roomID)
            debugLog("[Composer] ⚡ Bridge-stored animation active! \(owned.stepCount) steps, \(owned.intervalSeconds)s/step")
            await sendBridgeStoredPrimeFrame(
                preset: preset, gamut: gamut,
                api: api, groupedLightID: groupedLightID, roomName: room.name)
            return .savedAndRunning(manifestID: owned.id, bridgeID: bridgeID)

        case .savedNotConfirmedRunning(let owned):
            // The chain never started. For an app-driven current look this
            // means it keeps playing untouched; for a PROVEN bridge-stored
            // predecessor on this exact bridge, the replacement cleanup
            // already removed it, so exactly those claims are stale and fall
            // here — nothing is running. The new inert manifest is retained
            // as the exact stoppable identity but never enters the ownership
            // ledger, and a predecessor belonging to another bridge (or an
            // unproven one) clears NOTHING.
            let previousLookRemoved = provenExactPredecessor
                && exactManifests(bridgeID: bridgeID, roomID: room.id)
                    .allSatisfy { $0.id == owned.id }
            let fenceHeld = presentationFenceStillHeld()
            if previousLookRemoved {
                withdrawDestroyedBridgeStoredClaims(
                    bridgeID: bridgeID, roomID: room.id,
                    destroyedManifestIDs: predecessorChain,
                    ownershipEvidence: predecessorChain,
                    presentationFenceHeld: fenceHeld,
                    retainedManifestIDs: [owned.id])
            }
            return .savedNotConfirmedRunning(
                manifestID: owned.id, bridgeID: bridgeID,
                previousLookRemoved: previousLookRemoved,
                presentationFence: (previousLookRemoved && fenceHeld)
                    ? mintedPresentationFence() : nil)

        case .replacementBlocked:
            // Cleanup did NOT complete, so the previous chain (and its
            // claims) may genuinely survive — nothing to clear.
            return .nothingRecorded(reason: BridgeSaveCopy.saveFailedReplacementBlocked)

        case .uploadFailed, .compensatedNothingRemains:
            // Nothing new exists. If THIS bridge was provably playing a
            // bridge-stored look in this room, the required replacement
            // cleanup removed it before the failure — verify the exact chain
            // is provably gone and say THAT, typed, with every claim
            // belonging to it (and only it) cleared. A bare "nothing was
            // saved" notice would leave the UI asserting a look that no
            // longer exists — but a claim belonging to another bridge, or an
            // absence the store cannot prove exactly (an ambiguous legacy
            // manifest remains in the room), returns the ordinary honest
            // failure and clears NOTHING.
            if provenExactPredecessor,
               exactManifests(bridgeID: bridgeID, roomID: room.id).isEmpty,
               !bridgeAnimationStore.allManifests().contains(where: {
                   $0.roomID == room.id && resolvedBridgeID(for: $0) == nil
               }) {
                let fenceHeld = presentationFenceStillHeld()
                withdrawDestroyedBridgeStoredClaims(
                    bridgeID: bridgeID, roomID: room.id,
                    destroyedManifestIDs: predecessorChain,
                    ownershipEvidence: predecessorChain,
                    presentationFenceHeld: fenceHeld)
                return .previousLookRemovedSaveFailed(
                    bridgeID: bridgeID,
                    presentationFence: fenceHeld ? mintedPresentationFence() : nil)
            }
            return .nothingRecorded(reason: BridgeSaveCopy.saveFailedNothingRecorded)

        case .partialCleanup(let manifestID, let manifestBridgeID, let recoverable):
            let message = recoverable
                ? BridgeSaveCopy.partialCleanupRecoverable
                : BridgeSaveCopy.partialCleanupNotDurable
            return .partialCleanupFailure(
                manifestID: manifestID, bridgeID: manifestBridgeID,
                recoverableAfterRelaunch: recoverable, reason: message)
        }
    }

    /// May a returned presentation-withdrawal authorization still be applied?
    ///
    /// The token is minted in one synchronous main-actor turn, but its
    /// CONSUMER resumes in a later one — and between those turns another
    /// task can start a new playback on the same exact bridge+room. Studio
    /// calls this immediately before removing its running row and active
    /// composition box; a stale token preserves the newer look's mirrors.
    /// Same exactness rule as minting: ownership generation, exact playback
    /// generation (nil-versus-value compared exactly), and no standing live
    /// `.rest`/`.entertainment` claim on the key.
    func presentationFenceHolds(_ fence: SavedLookPresentationFence) -> Bool {
        let playbackKey = CompositionPlaybackKey(
            bridgeKey: fence.bridgeID, roomID: fence.roomID)
        let standingClaim = compositionTransportClaims[playbackKey]
        return roomOwnershipGeneration(bridgeID: fence.bridgeID, roomID: fence.roomID)
                == fence.roomOwnershipGeneration
            && compositionGenerations[playbackKey] == fence.playbackGeneration
            && standingClaim != .rest && standingClaim != .entertainment
    }

    /// Stop and remove exactly one saved look, by manifest identity.
    ///
    /// The immediate counterpart of the recovered-row Stop, for a look that was
    /// saved but never confirmed running: its resources exist and are tracked,
    /// so the user must be able to remove them NOW rather than waiting for a
    /// relaunch to surface a row.
    ///
    /// Exact by construction — the manifest names its own resources, and the
    /// bridge client is resolved from the manifest's recorded bridge id.
    ///
    /// Round 4f: the outcome is typed, because "removed" alone cannot say
    /// WHAT was removed. An inert saved-not-confirmed manifest and the
    /// room's confirmed-running bridge look retire through the same funnel,
    /// and only the ownership ledger — read BEFORE retirement destroys it —
    /// can tell them apart. The evidence capture, the retirement, the
    /// withdrawal and the fence verification all run in the same main-actor
    /// turn after the single bridge await, so nothing can change between
    /// them.
    @discardableResult
    func stopSavedBridgeLook(manifestID: UUID) async -> SavedLookStopOutcome {
        guard let manifest = bridgeAnimationStore.manifest(id: manifestID) else {
            // Already gone. Nothing to remove is a success, not a failure.
            return .alreadyAbsent
        }
        guard let bridgeID = resolvedBridgeID(for: manifest),
              let api = hueClient(for: bridgeID),
              let v1Client = try? api.makeV1Client() else {
            debugLog("[Composer] Cannot reach the bridge holding manifest \(manifestID) — retaining it")
            return .failed
        }
        // Round 4f: capture the destructive-ownership evidence and the
        // presentation fence BEFORE the bridge suspension. `retireManifest`
        // below funnels through `forgetManifestRecord`, which subtracts this
        // manifest from the ownership ledger — after that, the ledger can no
        // longer distinguish a confirmed-running chain whose entry just
        // emptied from an inert chain that never had one.
        let ownershipKey = BridgeNativeOwnershipKey(
            bridgeKey: bridgeID, roomID: manifest.roomID)
        let playbackKey = CompositionPlaybackKey(
            bridgeKey: bridgeID, roomID: manifest.roomID)
        let ownedBeforeRetirement = bridgeStoredChainOwnership[ownershipKey] ?? []
        let wasRunningOwner = ownedBeforeRetirement.contains(manifest.id)
        let fencedOwnershipGeneration = roomOwnershipGeneration(
            bridgeID: bridgeID, roomID: manifest.roomID)
        let fencedPlaybackGeneration = compositionGenerations[playbackKey]
        let result = await bridgeAnimationEngine.stop(manifest: manifest, v1Client: v1Client)
        // Freshness stays fail-closed: if the manifest changed while the
        // deletes were in flight, `retireManifest` retires nothing and the
        // captured evidence is discarded with it.
        guard retireManifest(manifest, after: result) else { return .failed }
        // Everything from the capture check to the withdrawal below is
        // synchronous on the main actor — no await separates the evidence
        // from the mutation it authorizes.
        let exactOwnershipSetEmptied =
            wasRunningOwner && bridgeStoredChainOwnership[ownershipKey] == nil
        let standingClaim = compositionTransportClaims[playbackKey]
        let presentationFenceHeld =
            roomOwnershipGeneration(bridgeID: bridgeID, roomID: manifest.roomID)
                == fencedOwnershipGeneration
            && compositionGenerations[playbackKey] == fencedPlaybackGeneration
            && standingClaim != .rest && standingClaim != .entertainment
        // Withdraw the room's claims only when they are THIS chain's claims
        // (round 4). Round 4c makes that exact: only the stopped manifest's
        // id is subtracted from its own bridge's ownership, the Now Playing
        // row falls only when that bridge's set emptied, and the shared
        // transport entry survives while ANY chain still claims the room.
        // Round 4f makes the emptying itself provable: the ledger membership
        // captured above is the evidence — a saved-but-not-confirmed
        // manifest is inert (never in the ledger) while the room's current
        // look keeps playing on REST, and removing the inert manifest must
        // not unpublish that look; stopping bridge B's chain must not
        // unpublish or unlabel bridge A's same-room-id one; and a newer
        // playback that took this exact key during the suspension keeps its
        // publication because the fence above no longer holds.
        withdrawDestroyedBridgeStoredClaims(
            bridgeID: bridgeID, roomID: manifest.roomID,
            destroyedManifestIDs: [manifest.id],
            ownershipEvidence: ownedBeforeRetirement,
            presentationFenceHeld: presentationFenceHeld)
        var presentationFence: SavedLookPresentationFence?
        if exactOwnershipSetEmptied, presentationFenceHeld {
            presentationFence = SavedLookPresentationFence(
                bridgeID: bridgeID, roomID: manifest.roomID,
                roomOwnershipGeneration: fencedOwnershipGeneration,
                playbackGeneration: fencedPlaybackGeneration)
            // The room's running look was THIS chain, and nothing newer took
            // the key — so the app-driven runtime the save-commit replaced
            // (generation already bumped there; the runtime itself was left
            // standing) is provably stale. Retire it exactly: this playback
            // key's runtime, scheduler membership and Composer telemetry
            // session, nothing else. A standing live claim means the runtime
            // belongs to a newer look and every piece of it survives.
            if compositionTransportClaims[playbackKey] == nil {
                compositionRuntimes.removeValue(forKey: playbackKey)
                compositionOrder.removeAll { $0 == playbackKey }
                if compositionRuntimes.isEmpty {
                    compositionSchedulerTask?.cancel()
                    compositionSchedulerTask = nil
                }
                deactivateComposerTelemetrySession(
                    sessionKey: ComposerTelemetrySessionKey(
                        bridgeKey: bridgeID,
                        scope: RestScope(roomID: manifest.roomID, owner: .composer)),
                    pendingRemovalReported: false)
            }
        }
        return .removed(
            manifestID: manifest.id, bridgeID: bridgeID, roomID: manifest.roomID,
            removedRunningOwnership: wasRunningOwner,
            exactOwnershipSetEmptied: exactOwnershipSetEmptied,
            presentationFence: presentationFence)
    }

    /// The ONE place a manifest record is dropped from the store.
    ///
    /// Packet 8's rule is that manifest evidence may only ever be destroyed
    /// through an exact-identity funnel, because a manifest is the sole record
    /// that can stop what it names. Every caller has already earned the right
    /// to forget — proved absence, a confirmed teardown, a purge report, or a
    /// write that never landed — and this keeps that right expressed in one
    /// place rather than scattered across four.
    private func forgetManifestRecord(id: UUID) {
        let roomID = bridgeAnimationStore.manifest(id: id)?.roomID
        bridgeAnimationStore.remove(id: id)
        // The evidence is gone, so no ownership claim may outlive it (round
        // 4c). Exact by manifest id — no other chain on any key is touched.
        subtractBridgeStoredChainOwnership(manifestID: id)
        // Round 4e: destroyed evidence may have been the only thing keeping a
        // retained room label alive — recompute the display aggregate.
        if let roomID {
            recomputeCompositionTransportAggregate(roomID: roomID)
        }
    }

    /// Every bridge this app can actually reach, in stable id order.
    var registeredBridgeIDs: [String] { clients.keys.sorted() }

    /// After a bridge sweep, forget only the manifests it PROVED it removed.
    ///
    /// The purge used to leave every manifest on disk, so the next
    /// reconciliation pass found their resources absent and pruned them as a
    /// side effect. Doing it here, from proof, keeps the ownership store honest
    /// at the moment of the deletion — and, more importantly, keeps the
    /// manifests whose resources may still exist. A refused delete or an
    /// unreadable category means something might still be running, and the
    /// manifest is the only thing that could ever stop it.
    ///
    /// Bridge-exact by construction: manifests are selected by resolved bridge
    /// id, so a sweep on one bridge can never forget another's records.
    @discardableResult
    func forgetManifestsProvenRemoved(
        by report: BridgeAnimationEngine.PurgeReport,
        onBridge bridgeID: String
    ) -> Int {
        var forgotten = 0
        for manifest in bridgeAnimationStore.allManifests() {
            guard resolvedBridgeID(for: manifest) == bridgeID else { continue }
            guard report.provesFullyRemoved(manifest) else {
                debugLog("[Settings] Retaining manifest \(manifest.id) — its resources were not proven removed")
                continue
            }
            forgetManifestRecord(id: manifest.id)
            forgetRecoveredBridgeAnimation(
                RecoveredBridgeAnimationKey(bridgeID: bridgeID, manifestID: manifest.id))
            forgotten += 1
        }
        return forgotten
    }

    /// A bridge label that is always safe to show a person.
    ///
    /// Never falls back to the IP. An address identifies a route, not a box on
    /// a shelf: during multi-bridge testing "192.0.2.4" tells the user nothing
    /// about which bridge is about to be changed, and printing it in a
    /// confirmation is how the wrong bridge gets approved.
    func bridgeLabel(for bridgeID: String) -> String {
        let name = bridgeName(for: bridgeID)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, !name.isEmpty { return name }
        return "your bridge"
    }

    /// Returns the first available working API client.
    /// Tries multi-bridge clients first (explicit credentials), then falls back
    /// to the legacy single-bridge keychain client.
    var primaryAPIClient: HueAPIClient? {
        // Multi-bridge: return first registered client (has explicit credentials)
        if let firstClient = clients.values.first {
            return firstClient
        }
        // Legacy single-bridge fallback: credentials loaded from keychain per-call
        return HueAPIClient()
    }

    /// All active bridge IDs — used by tabs (Automations, Devices) that need
    /// to fetch from every bridge and aggregate results.
    var allBridgeIDs: [String] { Array(clients.keys) }

    var overallConnectionStatus: BridgeConnectionStatus {
        let statuses = connectionStatus.values
        if statuses.allSatisfy({ if case .connected = $0 { return true }; return false }) { return .connected }
        if statuses.contains(where: { if case .error = $0 { return true }; return false }) { return .error("One or more bridges offline") }
        return .connecting
    }

    func rooms(for bridgeID: String) -> [RoomDisplayItem] {
        roomsByBridge[bridgeID] ?? []
    }

    // ──────────────────────────────────────────────
    // MARK: - Scenes (Stage 2B)
    // ──────────────────────────────────────────────

    /// Fetch all scenes from all active bridges in parallel.
    /// Results are merged, deduplicated (same room across duplicate bridges
    /// is fine — Hue scene UUIDs are bridge-local), and sorted:
    ///   active first → then alphabetical by name.
    func loadAllScenes() async {
        if isDemoMode {
            globalScenes = DemoDataProvider.globalScenes
            hasLoadedScenesOnce = true
            scheduleWidgetWrite()
            return
        }

        guard !clients.isEmpty else { return }

        // Reentrancy guard: loadAll's post-launch kick and the Scenes tab's
        // realize task can race; two merges would double-fetch every bridge.
        guard !isLoadingScenes else { return }
        isLoadingScenes = true
        defer { isLoadingScenes = false }

        var result: [GlobalSceneItem] = []

        await withTaskGroup(of: [GlobalSceneItem].self) { group in
            for (bridgeID, client) in clients {
                group.addTask {
                    guard let scenes = try? await client.fetchScenes() else { return [] }
                    return scenes.map { scene in
                        GlobalSceneItem(
                            id:            "\(bridgeID):\(scene.id)",
                            bridgeSceneID: scene.id,
                            name:          scene.metadata.name.sanitizedSceneName,
                            roomID:        scene.group.rid,
                            bridgeID:      bridgeID,
                            isActive:      scene.status?.active == "active"
                                        || scene.status?.active == "dynamic_palette",
                            isDynamic:     scene.isDynamic,
                            speed:         scene.speed ?? 0.5,
                            paletteXY:     scene.paletteXY
                        )
                    }
                }
            }
            for await items in group {
                result.append(contentsOf: items)
            }
        }

        // Active first, then alphabetical.
        // Preserve existing optimistic isActive flags — the bridge reports "no_effect"
        // for scenes that are genuinely active (fire-and-forget), so we merge: if a scene
        // is already marked active locally OR the bridge says active, keep it active.
        let existingActive = Set(globalScenes.filter { $0.isActive }.map { $0.id })
        // Family Sharing: scenes populate outside the room rebuilds, so the
        // grant filter applies here too — widgets/watch/Siri read the
        // published scene list and must inherit it.
        globalScenes = GuestAccessPolicy.filterScenes(result, grants: guestGrantsByBridge)
            .map { item in
                var s = item
                if existingActive.contains(s.id) { s.isActive = true }
                return s
            }
            .sorted {
                if $0.isActive != $1.isActive { return $0.isActive }
                return $0.name.localizedCompare($1.name) == .orderedAscending
            }

        log.info("Loaded \(self.globalScenes.count) scenes across \(self.clients.count) bridge(s)")

        // Scenes are now the truth — publish to widgets/watch (and re-donate
        // Siri scene phrases) through the debounced writer.
        hasLoadedScenesOnce = true
        scheduleWidgetWrite()
    }

    /// Activate a scene. Optimistic: marks it active locally, clears others
    /// in the same room, then fires the API call asynchronously.
    func activateGlobalScene(_ scene: GlobalSceneItem) {
        // Optimistic update via full-array replacement — avoids @Observable subscript bug
        // Deactivate all scenes in the SAME ROOM on the same bridge (the bridge will only
        // allow one active scene per room). Scenes in OTHER rooms stay as-is.
        var updated = globalScenes
        for i in updated.indices {
            if updated[i].roomID == scene.roomID && updated[i].bridgeID == scene.bridgeID {
                updated[i].isActive = (updated[i].id == scene.id)
            }
        }
        globalScenes = updated   // full assignment — reliably triggers @Observable

        guard let client = clients[scene.bridgeID] else { return }
        // After the client guard so demo mode never records usage.
        SceneUsageStore.shared.recordActivation(bridgeSceneID: scene.bridgeSceneID)
        Task {
            // Pass speed only for dynamic scenes; static scenes ignore the dynamics block.
            let speed: Double? = scene.isDynamic ? scene.speed : nil
            try? await client.activateScene(id: scene.bridgeSceneID, speed: speed)
            log.info("Activated scene '\(scene.name)' \(scene.isDynamic ? "@ speed \(String(format: "%.2f", scene.speed))" : "") on bridge \(scene.bridgeID)")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            refreshDominantColors(for: scene.bridgeID)
        }
    }

    /// Persist a new speed value for a dynamic scene.
    /// Full array swap so @Observable notifies SwiftUI immediately.
    func setSceneSpeed(_ scene: GlobalSceneItem, speed: Double) {
        var updated = globalScenes
        guard let idx = updated.firstIndex(where: { $0.id == scene.id }) else { return }
        updated[idx].speed = min(max(speed, 0.0), 1.0)
        globalScenes = updated
    }

    // ──────────────────────────────────────────────────────────────────────────
    // MARK: - Scene CRUD (Scenes Tab)
    // ──────────────────────────────────────────────────────────────────────────

    /// Optimistically removes the scene from globalScenes, then fires the bridge DELETE.
    func deleteGlobalScene(_ scene: GlobalSceneItem) {
        // Defense in depth (Family Sharing): the UI hides destructive scene
        // actions on granted bridges — this backstop keeps any missed
        // surface honest.
        guard !isGuestGrantedBridge(scene.bridgeID) else {
            toastMessage = "Not available with guest access"
            return
        }
        globalScenes.removeAll { $0.id == scene.id }
        scheduleWidgetWrite()
        guard let client = clients[scene.bridgeID] else { return }
        Task { try? await client.deleteScene(id: scene.bridgeSceneID) }
    }

    /// Optimistically renames the scene in globalScenes, then persists to the bridge.
    func renameGlobalScene(_ scene: GlobalSceneItem, to newName: String) async {
        guard !isGuestGrantedBridge(scene.bridgeID) else {
            toastMessage = "Not available with guest access"
            return
        }
        // Update locally first so the UI responds instantly
        if let idx = globalScenes.firstIndex(where: { $0.id == scene.id }) {
            var updated = globalScenes
            updated[idx] = GlobalSceneItem(
                id:            scene.id,
                bridgeSceneID: scene.bridgeSceneID,
                name:          newName,
                roomID:        scene.roomID,
                bridgeID:      scene.bridgeID,
                isActive:      scene.isActive,
                isDynamic:     scene.isDynamic,
                speed:         scene.speed,
                paletteXY:     scene.paletteXY
            )
            globalScenes = updated
            scheduleWidgetWrite()
        }
        guard let client = clients[scene.bridgeID] else { return }
        try? await client.renameScene(id: scene.bridgeSceneID, name: newName)
    }

    /// Fetch the given room/zone's lights from its bridge — the child-ref
    /// filter shared by scene capture and scene copy.
    func roomLights(for room: RoomDisplayItem) async throws -> [HueLight] {
        guard let bridgeID = room.bridgeID,
              let client   = clients[bridgeID] else {
            throw HueAPIError.missingCredentials
        }
        let allLights = try await client.fetchLights()

        // Filter to lights belonging to this room using its child resource refs
        let childIDs  = Set(room.childResourceRefs.map { $0.rid })
        let usesDirect = room.childResourceRefs.first?.rtype == "light"
        if usesDirect {
            // Zones and newer-firmware rooms reference lights directly
            return allLights.filter { childIDs.contains($0.id) }
        }
        // Older-firmware rooms reference devices — match via light.owner.rid
        return allLights.filter { light in
            guard let ownerRID = light.owner?.rid else { return false }
            return childIDs.contains(ownerRID)
        }
    }

    /// The long-press color wash: paint a room (or zone) with one color, or a
    /// harmony palette spread across its bulbs.
    ///
    /// `.none` is one grouped_light PUT — cheap, atomic, no per-light traffic.
    /// A harmony rule needs per-light writes (the whole point is adjacent bulbs
    /// wearing different anchors), so those go out in batches of 5 with 150ms
    /// gaps — the same pacing sendPerLightBatched established for effects.
    func applyColorWash(
        to room: RoomDisplayItem,
        rule: HarmonyRule,
        rootHue: Double,
        saturation: Double,
        brightness: Double
    ) async {
        guard let bridgeID = room.bridgeID, let api = clients[bridgeID] else { return }

        if rule == .none {
            let xy = HueColorUtils.xyFrom(hue: rootHue, saturation: saturation, brightness: 1.0)
            let clamped = HueColorUtils.clampXYToGamut(x: xy.x, y: xy.y, gamut: .c)
            guard let glID = room.groupedLightID else { return }
            try? await api.setGroupedLightEffect(
                id: glID, on: true, brightness: brightness,
                xy: (clamped.x, clamped.y), mirek: nil, duration: 400
            )
            return
        }

        guard let lights = try? await roomLights(for: room), !lights.isEmpty else { return }
        let assignments = RoomColorWashPlanner.plan(
            lights: lights, rule: rule,
            rootHue: rootHue, saturation: saturation, brightness: brightness
        )

        var start = 0
        while start < assignments.count {
            let batch = assignments[start ..< min(start + 5, assignments.count)]
            await withTaskGroup(of: Void.self) { group in
                for assignment in batch {
                    group.addTask {
                        switch assignment.action {
                        case .color(let x, let y, let bri):
                            try? await api.setLightState(id: assignment.lightID, on: true, brightness: bri)
                            try? await api.setLightColor(id: assignment.lightID, x: x, y: y)
                        case .colorTemp(let mirek, let bri):
                            try? await api.setLightState(id: assignment.lightID, on: true, brightness: bri)
                            try? await api.setLightColorTemp(id: assignment.lightID, mirek: mirek)
                        case .brightnessOnly(let bri):
                            try? await api.setLightState(id: assignment.lightID, on: true, brightness: bri)
                        }
                    }
                }
            }
            start += 5
            if start < assignments.count {
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        scheduleStateRefresh()
    }

    /// The Scenes tab's "Studio scenes" shelf: turn a scene-like Composer
    /// preset into a REAL bridge scene in the chosen room. Reuses the exporter
    /// recipe (palette sampled through `color(at:)`, gamut-clamped, speed
    /// mapped) so the scene matches what the Composer shows. Returns the new
    /// scene's id, or nil with no side effects.
    func addStudioSceneToRoom(preset: CompositionPreset, room: RoomDisplayItem) async -> String? {
        guard BridgeDynamicSceneExporter.ineligibilityReason(for: preset) == nil,
              let bridgeID = room.bridgeID,
              let api = clients[bridgeID],
              let lights = try? await roomLights(for: room),
              !lights.isEmpty
        else { return nil }

        let recipe = BridgeDynamicSceneExporter.recipe(for: preset, gamut: .c)
        let request = CreateSceneRequest.dynamicScene(
            name: preset.name,
            groupID: room.id,
            groupRtype: room.kind == .zone ? "zone" : "room",
            lights: lights,
            paletteXY: recipe.palette.map { (x: $0.x, y: $0.y) },
            brightness: recipe.brightness,
            speed: recipe.speed
        )
        guard let sceneID = try? await api.createSceneReturningID(request) else { return nil }
        SceneProvenanceStore.shared.markStudioExported(bridgeID: bridgeID, sceneID: sceneID)
        await loadAllScenes()
        return sceneID
    }

    /// Creates a new scene by snapshotting the current light states in the given room.
    /// Fetches all lights for the bridge, filters to this room's lights, and POSTs a scene.
    func createSceneFromRoom(name: String, room: RoomDisplayItem) async throws {
        guard let bridgeID = room.bridgeID,
              let client   = clients[bridgeID] else {
            throw HueAPIError.missingCredentials
        }
        // Defense in depth (Family Sharing): guests never create scenes on
        // granted bridges — the UI hides the entry points; this backstops it.
        guard !isGuestGrantedBridge(bridgeID) else {
            toastMessage = "Not available with guest access"
            throw HueAPIError.missingCredentials
        }
        let sceneLights = try await roomLights(for: room)

        let req = CreateSceneRequest.fromHueLights(
            name:       name,
            groupID:    room.id,
            groupRtype: room.kind == .zone ? "zone" : "room",
            lights:     sceneLights
        )
        try await client.createScene(req)
        // Refresh the scene list so the new scene appears immediately
        await loadAllScenes()
    }

    /// Fetch a scene's stored actions for the copy sheet's preview.
    func fetchSceneDetail(_ scene: GlobalSceneItem) async throws -> HueSceneDetail {
        guard let client = clients[scene.bridgeID] else {
            throw HueAPIError.missingCredentials
        }
        return try await client.fetchSceneDetail(id: scene.bridgeSceneID)
    }

    /// Copy (or move) a scene to another room/zone. Hue has no move API —
    /// this remaps the source actions onto the target group's lights via
    /// SceneCopyEngine, POSTs a NEW scene on the target's bridge (cross-
    /// bridge copies fall out naturally: the request is built fresh against
    /// target rids), then optionally deletes the original.
    /// Returns the created scene's bridge UUID so the caller can offer undo.
    @discardableResult
    func copyScene(
        detail: HueSceneDetail,
        source: GlobalSceneItem,
        to targetRoom: RoomDisplayItem,
        name: String,
        deleteOriginal: Bool
    ) async throws -> String {
        guard !isDemoMode else { throw HueAPIError.missingCredentials }
        guard let targetBridgeID = targetRoom.bridgeID,
              let targetClient   = clients[targetBridgeID] else {
            throw HueAPIError.missingCredentials
        }
        // Defense in depth (Family Sharing): no scene creation on a granted
        // target, no deletion from a granted source.
        guard !isGuestGrantedBridge(targetBridgeID),
              !(deleteOriginal && isGuestGrantedBridge(source.bridgeID)) else {
            toastMessage = "Not available with guest access"
            throw HueAPIError.missingCredentials
        }

        let targetLights = try await roomLights(for: targetRoom)
        let remapped = SceneCopyEngine.remap(detail: detail, targetLights: targetLights)
        let request = SceneCopyEngine.request(
            name: name,
            targetGroupID: targetRoom.id,
            targetRtype: targetRoom.kind == .zone ? "zone" : "room",
            remapped: remapped,
            detail: detail
        )
        let newSceneID = try await targetClient.createSceneReturningID(request)

        // Studio provenance follows the copy (same look, new identity).
        if SceneProvenanceStore.shared.isStudioScene(key: source.id) {
            SceneProvenanceStore.shared.markStudioExported(
                bridgeID: targetBridgeID, sceneID: newSceneID
            )
        }

        if deleteOriginal, let sourceClient = clients[source.bridgeID] {
            try? await sourceClient.deleteScene(id: source.bridgeSceneID)
            SceneProvenanceStore.shared.remove(key: source.id)
        }

        await loadAllScenes()
        return newSceneID
    }

    /// Update an existing scene's name and per-light actions.
    /// Used by the Scene Color Builder in edit mode.
    func updateScene(sceneID: String, bridgeID: String, name: String, lights: [LightDisplayItem]) async throws {
        guard let client = clients[bridgeID] else {
            throw HueAPIError.missingCredentials
        }
        nonisolated(unsafe) let actions: [[String: Any]] = lights.map { light in
            var action: [String: Any] = ["on": ["on": light.isOn]]
            if light.isOn {
                action["dimming"] = ["brightness": max(1, min(100, light.brightness))]
            }
            if let x = light.colorX, let y = light.colorY {
                action["color"] = ["xy": ["x": max(0, min(1, x)), "y": max(0, min(1, y))]]
            } else if light.colorX == nil, let mirek = light.colorTempMirek {
                let clamped = max(light.mirekMin, min(light.mirekMax, mirek))
                action["color_temperature"] = ["mirek": clamped]
            }
            return [
                "target": ["rid": light.id, "rtype": "light"],
                "action": action
            ]
        }
        try await client.updateScene(id: sceneID, name: name, actions: actions)
        await loadAllScenes()
    }
}

// MARK: - Entertainment Session Cleanup

/// Every ACTIVE Entertainment configuration on one bridge, partitioned by who
/// owns it (packet 7).
///
/// The whole set is represented on purpose. Reducing a bridge to "the active
/// configuration" is what let one arbitrary entry stand in for a mixed reality
/// — our stale session and a stranger's live show, indistinguishable.
struct EntertainmentActivitySnapshot: Equatable, Sendable {
    let bridgeID: String
    /// Active and streamed by THIS process right now. Never touch.
    let processOwned: Set<String>
    /// Active, recorded as ChromaGlow's, but not owned by this process —
    /// left behind by an unclean termination. Eligible for cleanup.
    let persistedOwned: Set<String>
    /// Active and not recorded by ChromaGlow at all: another app, a Sync Box,
    /// another controller. Never stopped without explicit user consent.
    let foreign: Set<String>

    var isQuiet: Bool { processOwned.isEmpty && persistedOwned.isEmpty && foreign.isEmpty }
}

extension UnifiedOrchestrator {

    /// WHICH ChromaGlow look owns a bridge's Entertainment session, and where it
    /// is running (packet 7 hardware follow-up).
    ///
    /// The defect this closes: app-driven ownership was recorded only as a
    /// VALUE in `studioEntClients[bridgeID]` — a live client and nothing else.
    /// The snapshot above calls such a session `processOwned`, which is exactly
    /// the classification that makes the foreign-consent flow a deliberate
    /// no-op, so "is that session ours, and whose look is it?" had no answer
    /// anywhere. A composition asking for the same bridge therefore opened a
    /// SECOND session on top of Strobe's.
    ///
    /// `configID` is part of the identity on purpose: an owner that restarted on
    /// a different area is a DIFFERENT owner, and a handoff the user authorized
    /// against the first must not silently stop the second.
    struct StudioEntertainmentOwner: Equatable, Sendable {
        let bridgeID: String
        let roomID: String
        /// "strobe" | "party" | "thunderstorm"
        let engineKey: String
        let configID: String
    }
}

/// Why an Entertainment start could not proceed for an ordinary technical
/// reason — never because of a foreign owner, which has its own result.
enum EntertainmentUnavailableReason: Equatable, Sendable {
    case noBridgeCredentials
    case streamingFailed
    /// One of ChromaGlow's own app-driven looks is already streaming to this
    /// bridge.
    ///
    /// Deliberately NOT lumped in with the technical reasons above. Every
    /// caller reads those as licence to fall back to room mode — and room mode
    /// here means REST writes landing underneath our own live 25 fps DTLS
    /// stream, which is precisely the "I tapped it and nothing happened"
    /// report. This is a refusal, not an inability.
    case heldByAnotherChromaGlowLook
}

/// Who is asking the choke point for a session (packet 7 hardware follow-up).
///
/// The two are not interchangeable. `startStudioMode` legitimately replaces its
/// OWN session on a bridge — app-driven engines share one global slot, so a
/// room A → room B switch is one engine moving, and it evicts the previous
/// client itself. A composition has no such slot and performs no such eviction,
/// so for it a live app-driven session on the bridge is always a conflict.
enum EntertainmentRequester: Equatable, Sendable {
    case studio
    case composition
}

/// The outcome of asking for an Entertainment session (packet 7).
///
/// Replaces an optional client. `nil` could not distinguish "streaming is not
/// possible here, fall back to room mode" from "another controller owns this
/// bridge" — so a foreign conflict silently became a REST fallback, which
/// starts playing over the other app's show just more quietly.
enum EntertainmentStartResult {
    case started(HueEntertainmentClient)
    /// A third party owns the bridge. NOTHING has been mutated.
    case needsForeignConsent(EntertainmentActivitySnapshot)
    case unavailable(reason: EntertainmentUnavailableReason)
    case failed(message: String)

    var client: HueEntertainmentClient? {
        if case .started(let c) = self { return c }
        return nil
    }

    /// True when a foreign owner blocks this start. Callers must not begin a
    /// REST or bridge-stored fallback while this is unresolved.
    var isForeignConflict: Bool {
        if case .needsForeignConsent = self { return true }
        return false
    }
}

/// How a playback start ended (packet 7).
///
/// A start used to be `Void`: the caller inferred the transport by peeking at
/// `studioEntClients` afterwards, and had no way at all to learn that another
/// controller had blocked it. A non-interactive caller therefore could not
/// refuse honestly — it just quietly did something else.
enum PlaybackStartOutcome: Equatable {
    enum Transport: Equatable { case entertainment, rest, bridgeStored, oneShot }

    case started(transport: Transport)
    /// A third party owns the bridge and the user has not been asked.
    /// NOTHING was mutated. An interactive surface should prompt; a
    /// non-interactive one must refuse and say so.
    case needsForeignConsent(snapshot: EntertainmentActivitySnapshot, targetConfigID: String)
    case failed(message: String)

    var startedStreaming: Bool { self == .started(transport: .entertainment) }

    var foreignConflict: (snapshot: EntertainmentActivitySnapshot, targetConfigID: String)? {
        if case .needsForeignConsent(let s, let t) = self { return (s, t) }
        return nil
    }
}

/// The exact, validated way a specific room would stream — frozen at the
/// moment the user was asked (packet 7).
///
/// A configuration id alone is not a plan. Between the prompt appearing and
/// the answer arriving the area can be deleted, re-scoped to different lights,
/// or lose the channels the render loop needs; replaying on the id alone would
/// then stream somewhere the user never saw, or quietly drop to room mode
/// after having stopped someone else's show. Freezing the whole plan makes
/// those cases detectable and refusable.
struct EntertainmentTakeoverPlan: Equatable, Sendable {

    /// One channel, captured whole. Ids alone would let the SAME area drive
    /// different lights, or drive them in a different place in the room —
    /// both invisible in a comparison of ids, both very visible on the wall.
    struct Channel: Equatable, Sendable {
        let id: UInt8
        /// The entertainment services this channel drives.
        let members: [String]
        let x: Double
        let y: Double
        let z: Double
    }

    let bridgeID: String
    let roomID: String
    let targetConfigID: String
    /// Validated and ORDERED at capture time — the render loop drives exactly
    /// these, in exactly this order.
    let channelIDs: [UInt8]
    /// Members and positions, so Composer's spatial mapping is frozen too.
    let channels: [Channel]

    init(bridgeID: String, roomID: String, config: EntertainmentConfig, channelIDs: [UInt8]) {
        self.bridgeID = bridgeID
        self.roomID = roomID
        self.targetConfigID = config.id
        self.channelIDs = channelIDs
        self.channels = config.channels.map {
            Channel(id: UInt8(clamping: $0.id),
                    members: $0.lightServiceIDs,
                    x: $0.position.x, y: $0.position.y, z: $0.position.z)
        }
    }

    /// True when a freshly resolved plan still describes the same stream —
    /// same area, same ordered channels, same members, same positions.
    func matches(config: EntertainmentConfig, channelIDs: [UInt8]) -> Bool {
        guard config.id == targetConfigID, channelIDs == self.channelIDs else { return false }
        let fresh = config.channels.map {
            Channel(id: UInt8(clamping: $0.id),
                    members: $0.lightServiceIDs,
                    x: $0.position.x, y: $0.position.y, z: $0.position.z)
        }
        return fresh == channels
    }

    /// The captured configuration, rebuilt for the render loop. Using this
    /// rather than re-selecting is what stops a cache refresh between consent
    /// and replay from quietly redirecting the stream.
    var capturedConfig: EntertainmentConfig {
        EntertainmentConfig(
            id: targetConfigID,
            name: "",
            channels: channels.map {
                EntertainmentChannel(id: Int($0.id),
                                     lightServiceIDs: $0.members,
                                     position: (x: $0.x, y: $0.y, z: $0.z))
            }
        )
    }
}

/// One user decision to replace one third-party session.
///
/// Fully bound and single-use. Produced only by the confirmation flow, after
/// it has stopped (or verified the absence of) the consented session.
struct EntertainmentConsent: Equatable, Sendable {
    let requestID: UUID
    let bridgeID: String
    /// The area the requested room will actually use.
    let targetConfigID: String
    /// The session the user agreed to replace.
    let foreignConfigID: String
}

/// User-facing copy for the takeover flow.
///
/// Kept together so the words stay reviewable in one place, and deliberately
/// free of protocol vocabulary: the person reading this owns lights, not a
/// streaming stack. No configuration ids and no third-party app names — the
/// bridge does not tell us who the other controller is, and guessing would be
/// worse than saying "another app".
enum EntertainmentConsentCopy {
    static let takeoverTitle = "Another app was controlling these lights — take over?"
    static let keepExisting  = "Keep Existing"
    static let takeOver      = "Take Over"
    static let takeoverFailed = "Couldn't take over these lights. The other app is still in control."
    static let bridgeUnreadable = "Couldn't reach your bridge, so nothing was changed."
    /// The session was ours and then it wasn't. Says what the user can see —
    /// their lights answering to something else — without naming an app the
    /// bridge never identified.
    static let controllerResumed = "Another app is controlling these lights again."
}

/// User-facing copy for ChromaGlow's own looks trading places on a bridge.
///
/// Deliberately NOT part of `EntertainmentConsentCopy`. Those words are about
/// replacing ANOTHER app — a stranger's show, where the default is to leave it
/// alone. These are about two of our own looks, where the user already owns
/// both and the question is only which one plays. One shared vocabulary would
/// make the more serious of the two questions read like the routine one.
enum EntertainmentHandoffCopy {
    static let switchTitle = "Switch lighting modes?"
    static let keepPlaying = "Keep Playing"
    static let switchLooks = "Switch"
    static let alreadyStreaming = "Another look is already streaming to this bridge."
    static let stopFailed = "Couldn't stop the look that's using this bridge, so nothing was changed."
    static let handoffFailed = "Couldn't switch looks on this bridge. Nothing was changed."
}

/// Why an explicit streaming request could not be honoured (packet 7 follow-up).
///
/// `noCompatibleArea` names Room mode on purpose. The app does still start —
/// but an explanation that omits the transport change is an unexplained
/// fallback, which is exactly the silence this copy exists to end: the user
/// asked for streaming, got something else, and was told nothing.
enum EntertainmentAvailabilityCopy {
    static let noCompatibleArea = "There's no compatible Entertainment Area for that room. Playing in Room mode instead."
    /// The same missing area, on a path where Room mode is NOT a legal answer.
    ///
    /// The handoff gate refuses instead of falling back, because a Room-mode
    /// start there would write to a bridge underneath our own live stream. The
    /// sentence therefore may not promise Room mode: naming a fallback that
    /// never happens is worse than naming none at all.
    static let noCompatibleAreaNothingChanged =
        "There's no compatible Entertainment Area for that room, so nothing was changed."
    static let couldNotCheck = "Streaming availability could not be checked right now."
    static let couldNotStart = "Streaming couldn't start for that room, so nothing was changed."
}

/// User-facing copy for choosing between Entertainment Areas.
///
/// Its own home, like every other prompt vocabulary in this file, and free of
/// protocol words for the same reason: the person reading it owns lights and
/// rooms, not configurations. Nothing here names a configuration id — the
/// chooser identifies areas the way the user named them in the Hue app.
enum EntertainmentAreaChoiceCopy {
    static let title = "Which lights should this play on?"
    static let message = "More than one Entertainment Area covers this room."
    static let cancel = "Cancel"
    /// Shown on a candidate that reaches beyond the requested room. The scope
    /// has to be stated BEFORE the tap, not explained after the lights change.
    static func expandsScope(room: String) -> String {
        "Also controls lights outside \(room)"
    }
    static func lightSummary(inRoom: Int, outside: Int) -> String {
        let lights = "\(inRoom) light\(inRoom == 1 ? "" : "s")"
        guard outside > 0 else { return lights }
        return "\(lights) here · \(outside) elsewhere"
    }
    static let staleSelection =
        "That Entertainment Area isn't available for this room any more, so nothing was changed."
}

/// User-facing copy for saving a look onto the bridge.
///
/// Four outcomes, kept distinct because they oblige the user to do four
/// different things. On hardware, effects were seen still running after a
/// force-close with no recovered row and no Stop anywhere — the app had no
/// vocabulary for "this is on the bridge now" versus "this stops when you
/// close me", so the user could not tell which state they were in.
///
/// No manifest ids, no resource ids, no REST or DTLS. A person who saved a
/// look wants to know where it lives and how to stop it.
enum BridgeSaveCopy {
    static let savedAndRunning = TransportVocabulary.bridgeRunTruth
    /// Resources exist and are tracked, but the chain did not start. NOT a
    /// success: claiming "running" here would send the user looking for lights
    /// that are not moving.
    static let savedNotConfirmedRunning =
        "Saved to your bridge, but it isn't confirmed running. You can stop it from the room's Now Playing row."
    static let saveFailedNothingRecorded =
        "Couldn't save that look to your bridge. Nothing was left behind."
    /// The honest worst case: creation partly succeeded and cleanup did not
    /// finish. Naming it is what makes it recoverable — silence here is what
    /// produces a resource set the user cannot find.
    static let saveFailedResourcesRemain =
        "Couldn't finish saving that look, and some of it may still be on your bridge. Use Clean Bridge Resources in Settings."
    /// A native Hue dynamic scene. Genuinely bridge-run — and genuinely NOT
    /// something ChromaGlow can stop, because no ownership manifest exists for
    /// it. Promising a Stop we cannot deliver is worse than saying so.
    static let savedAsSceneNotStoppable =
        "Saved to your bridge as a scene. It keeps playing with the app closed — start or stop it from Scenes, or in the Hue app."
    static let noLocalPreset =
        "This lives on your bridge only — no copy was added to My Creations."
    /// Said BEFORE anything is attempted. The bridge has no microphone, so a
    /// reactive look cannot live there — and starting it from the phone and
    /// calling that a save would be the lie this whole slice exists to remove.
    static let ineligibleReactive =
        "Looks that react to sound can't be saved to the bridge — the bridge has no microphone. Nothing was saved."
    static let ineligibleMotion =
        "This look moves in a way the bridge can't reproduce on its own, so it can't be saved there. Nothing was saved."
    /// The room resolved to zero lights — a real answer about the room, not a
    /// transport failure, and it must not read like one.
    static let saveFailedNoLights =
        "This room has no lights to save the look for. Nothing was saved."
    /// The bridge could not be read, so the room's membership is unknown.
    /// Deliberately a different sentence from the one above: "your room is
    /// empty" and "I couldn't check" call for different next steps.
    static let saveFailedLightsUnresolved =
        "Couldn't confirm this room's lights, so nothing was saved. Check the bridge connection and try again."
    /// The previous bridge look could not be provably cleaned up first. Save
    /// words, not start words — this is reached only through Save to Bridge.
    static let saveFailedReplacementBlocked =
        "Couldn't save — the previous look is still on the bridge. Try again in a moment."
    /// A save for this room is already running. The second tap changed
    /// nothing, and saying so beats two saves racing over the same lights.
    static let saveAlreadyInProgress =
        "This look is still being saved. Nothing extra was changed."
    /// Partial compensation, with a durable recovery record: some of the look
    /// is still on the bridge, an exact Remove is offered right now, and a
    /// relaunch will recover the same handle.
    static let partialCleanupRecoverable =
        "Couldn't finish saving that look — some of it is still on your bridge. Remove it now, or ChromaGlow will offer it again after a relaunch."
    /// Partial compensation AND the recovery record could not be written.
    /// The exact Remove still works right now; what cannot be promised is
    /// recovery after the app closes, and that is said plainly.
    static let partialCleanupNotDurable =
        "Couldn't finish saving that look — some of it is still on your bridge. Remove it now: if the app closes first, ChromaGlow may not be able to find it again."
    /// The exceptional replacement failure (round 4b): the room's previous
    /// bridge look had to be removed before the new one could be created,
    /// and the new one then failed. Both halves of that are said — what was
    /// lost, and that nothing runs on the bridge now.
    static let previousLookRemovedSaveFailed =
        "The previous bridge look was removed to make room, but the new one couldn't be saved. Nothing is playing on your bridge now."
    /// The same removal, but the new look DID save — it just isn't confirmed
    /// running (round 4c). Both halves are said: what was removed, and that
    /// the saved look is not playing.
    static let savedNotConfirmedPreviousLookRemoved =
        "The previous bridge look was removed to make room. The new one is saved to your bridge, but it isn't confirmed running — nothing is playing there now, and you can stop the saved look from here."
    /// Round 4f: the SAME bridge facts as `previousLookRemovedSaveFailed`,
    /// told when the presentation fence is nil or stale at apply time.
    /// Playback changed while the save was in flight — but a stale fence
    /// proves only the CHANGE: the newer look may itself have stopped by
    /// now, so this wording claims neither "nothing is playing" nor "a look
    /// is playing". Chosen at apply time from the revalidated fence, never
    /// frozen into the outcome.
    static let previousLookRemovedSaveFailedPlaybackChanged =
        "The previous bridge look was removed to make room, but the new one couldn't be saved. Playback changed while the save completed — ChromaGlow preserved the newer state."
    /// Round 4f: `savedNotConfirmedPreviousLookRemoved` under a nil or stale
    /// fence — the saved chain is durable and stoppable, and no claim is
    /// made about what is or isn't playing now.
    static let savedNotConfirmedPreviousLookRemovedPlaybackChanged =
        "The previous bridge look was removed to make room. The new one is saved to your bridge, but it isn't confirmed running. Playback changed while the save completed — ChromaGlow preserved the newer state. You can stop the saved look from here."
}

/// Safety refusals shared between Studio and Perform.
///
/// One literal, one home: two hand-typed copies of the same sentence drift the
/// moment either surface is edited, and a safety refusal that words itself
/// differently depending on where it fired reads like two different rules.
enum StudioSafetyCopy {
    static let strobeReduceMotion = "Strobe is unavailable while Reduce Motion is on."
}

extension UnifiedOrchestrator {

    /// The result of acting on the user's "Take Over".
    enum ForeignTakeoverResolution: Equatable {
        /// Clear to replay the original request with this token.
        case resolved(EntertainmentConsent)
        /// A different third-party session is now streaming; the user has not
        /// agreed to replace THIS one. Nothing was stopped.
        case changedOwner(EntertainmentActivitySnapshot)
        case failed(message: String)
    }

    /// Would starting Entertainment for this room mean replacing another
    /// controller? Purely a question — it mutates nothing.
    ///
    /// Every outcome is named. The first version answered with an optional,
    /// which collapsed "not asking for streaming", "nowhere to stream",
    /// "bridge is free", and "we could not read the bridge" into one `nil`
    /// that every caller then had to guess at — and the honest failures
    /// guessed wrong, falling through into destructive work.
    enum ForeignTakeoverPreflight: Equatable {
        /// This card never streams, so no third party can conflict with it.
        case notRequested
        /// No safely matching, streamable area for this room. The existing
        /// honest room-mode fallback is correct and allowed.
        case noStreamableArea
        /// Nobody else is on this bridge. Carries the frozen plan so the start
        /// and any later replay describe the same stream.
        case clear(plan: EntertainmentTakeoverPlan)
        /// Exactly one third-party session — the only shape that can be
        /// consented to, because consent must name what it replaces.
        case conflict(plan: EntertainmentTakeoverPlan, foreignConfigID: String)
        /// Several third-party sessions at once: nothing to name, so nothing
        /// to ask. Fail closed.
        case ambiguous
        /// The bridge could not be read. Unknown is not "free". Fail closed.
        case unreadable
        /// Several areas could serve this room (hardware convergence slice A).
        /// Deliberately NOT merged with `.ambiguous`: that one is about who
        /// owns the bridge and fails closed, this one is about which area the
        /// user meant and is answerable. One case for both would make a
        /// question the user can settle look like a refusal.
        case choiceRequired([EntertainmentAreaChoice])
        /// A previously chosen area no longer serves this room. Starts nothing.
        case staleSelection
    }

    /// Warm, resolve, and freeze this room's stream in one place — or nil when
    /// nothing safely matches.
    ///
    /// Extracted because two capture sites is exactly how the plan a user is
    /// SHOWN stops being the plan that gets STREAMED: each site does its own
    /// warm and its own selection, so a cache refresh landing between them lets
    /// the prompt describe one area while the start opens another. One capture
    /// site makes that divergence unrepresentable.
    func frozenStartPlan(for room: RoomDisplayItem,
                         selectedConfigID: String? = nil) async -> EntertainmentTakeoverPlan? {
        guard let bridgeID = room.bridgeID else { return nil }
        await warmEntertainmentCaches(for: room, force: true)
        guard let resolved = entertainmentStartPlan(for: room,
                                                    preferredConfigID: selectedConfigID) else { return nil }
        return EntertainmentTakeoverPlan(bridgeID: bridgeID, roomID: room.id,
                                         config: resolved.config, channelIDs: resolved.channelIDs)
    }

    /// One Entertainment Area, described the way a person picking one needs it.
    ///
    /// Everything here is user-facing. The bridge is named by its label, never
    /// its IP — an address is not an identity, and on a two-bridge home it is
    /// the one thing the user cannot map back to the box on the shelf.
    struct EntertainmentAreaChoice: Identifiable, Equatable, Sendable {
        var id: String { configID }
        let configID: String
        let areaName: String
        let bridgeID: String
        let bridgeLabel: String
        /// Rooms this area reaches, resolved from real room records. Never
        /// guessed: an unresolvable room is omitted rather than invented.
        let roomNames: [String]
        /// Lights it drives inside the room that was asked for.
        let lightCount: Int
        /// Lights it drives outside that room. Non-zero is the disclosure that
        /// selecting this area controls more than the user asked about.
        let extraLightCount: Int
        /// The exact stream this row promises, frozen when the sheet opened.
        ///
        /// A configuration id alone is not enough to keep that promise. While
        /// the sheet is open the area can be re-scoped to different lights or
        /// have its channels rearranged, and an answer replayed on the id would
        /// then open something the user never saw. Confirmation compares this
        /// whole value against a freshly resolved one.
        let plan: EntertainmentTakeoverPlan
        var expandsScope: Bool { extraLightCount > 0 }
    }

    /// The exact target for one streaming request — or the honest reason there
    /// isn't one yet (hardware convergence slice A).
    ///
    /// Six outcomes, deliberately not collapsed into an optional plan. They ask
    /// for six different things from the caller: start · ask the user · fall
    /// back to Room mode · fail closed · discard a stale choice · refuse to
    /// guess between owners. The optional that used to stand here made the
    /// honest failures indistinguishable from "nothing matches", which is how a
    /// room served by two areas came to report that it had none.
    enum ExactTargetDecision: Equatable {
        /// Exactly one safe area. Frozen and ready to start.
        case plan(EntertainmentTakeoverPlan)
        /// Several areas could serve this room. Only the user can choose.
        case choiceRequired([EntertainmentAreaChoice])
        /// Nothing on this bridge can stream to this room.
        case noCompatiblePlan
        /// The bridge could not be read. Unknown is not "free" and not "empty".
        case unreadableBridge
        /// A previously chosen area no longer serves this room — deleted,
        /// re-scoped, moved, or changed membership. Starts nothing.
        case staleSelection
        /// Several controllers hold this bridge. Nothing to name, nothing to ask.
        case ambiguousOwnership
    }

    /// Resolve a room to its exact stream target, forcing fresh bridge reads.
    ///
    /// `selectedConfigID` carries a choice the user already made. It is
    /// revalidated here rather than trusted: between the chooser appearing and
    /// this call the area can be deleted, re-scoped to different lights, or
    /// lose the channels the render loop needs, and replaying it then would
    /// stream somewhere nobody was ever shown.
    func exactTargetDecision(
        for room: RoomDisplayItem,
        selectedConfigID: String? = nil
    ) async -> ExactTargetDecision {
        guard let bridgeID = room.bridgeID else { return .noCompatiblePlan }
        await warmEntertainmentCaches(for: room, force: true)

        // Two different silences, and they must not be confused. The BRIDGE
        // failing to answer is unreadable — unknown is not "free", so it fails
        // closed. This room's lights failing to resolve is not: the bridge
        // spoke, we simply cannot name an area for this room, which is the
        // long-standing honest Room-mode fallback. Treating the second as the
        // first turns a working fallback into a refusal.
        guard entertainmentConfigsByBridge[bridgeID] != nil,
              entertainmentMembershipByBridge[bridgeID] != nil else {
            return .unreadableBridge
        }
        guard let decision = cachedAreaDecision(for: room, selectedConfigID: selectedConfigID) else {
            return selectedConfigID == nil ? .noCompatiblePlan : .staleSelection
        }

        switch decision {
        case .exact(let config):
            guard let channelIDs = EntertainmentAreaSelector.validatedChannelIDs(for: config) else {
                return selectedConfigID == nil ? .noCompatiblePlan : .staleSelection
            }
            return .plan(EntertainmentTakeoverPlan(bridgeID: bridgeID, roomID: room.id,
                                                   config: config, channelIDs: channelIDs))

        case .choiceRequired(let candidates):
            let choices = candidates.compactMap {
                areaChoice($0, bridgeID: bridgeID, room: room)
            }
            // Every candidate was eligibility-checked, so losing one here means
            // it cannot actually be streamed — and an option that cannot be
            // honoured must not be offered.
            return choices.isEmpty ? .noCompatiblePlan : .choiceRequired(choices)

        case .noCompatible:
            // A selection that no longer resolves is stale, not absent. The
            // distinction matters: "nothing fits" invites Room mode, while a
            // vanished choice must start nothing at all.
            return selectedConfigID == nil ? .noCompatiblePlan : .staleSelection
        }
    }

    /// Describe one candidate for the chooser. Rooms are resolved from real
    /// records on the SAME bridge — a room id that only exists on another
    /// bridge is not this area's room, and is never borrowed to fill the gap.
    private func areaChoice(
        _ candidate: EntertainmentAreaSelector.ExactAreaCandidate,
        bridgeID: String,
        room: RoomDisplayItem
    ) -> EntertainmentAreaChoice? {
        guard let channelIDs = EntertainmentAreaSelector.validatedChannelIDs(for: candidate.config)
        else { return nil }
        let membership = entertainmentMembershipByBridge[bridgeID] ?? [:]
        let areaLightIDs = EntertainmentAreaSelector.mappedLightIDs(
            for: candidate.config, entertainmentToLightMap: membership)

        var names: [String] = []
        for candidateRoom in allRooms where candidateRoom.bridgeID == bridgeID {
            guard let lights = cachedRawLights(for: bridgeID) else { break }
            let ids = Set(CompositionLightResolver.resolveLightIDs(
                childResourceRefs: candidateRoom.childResourceRefs, lights: lights))
            if !ids.isDisjoint(with: areaLightIDs) { names.append(candidateRoom.name) }
        }

        return EntertainmentAreaChoice(
            configID: candidate.config.id,
            areaName: candidate.config.name,
            bridgeID: bridgeID,
            bridgeLabel: bridgeLabel(for: bridgeID),
            roomNames: names.sorted(),
            lightCount: candidate.lightIDs.count,
            extraLightCount: candidate.extraLightIDs.count,
            plan: EntertainmentTakeoverPlan(bridgeID: bridgeID, roomID: room.id,
                                            config: candidate.config, channelIDs: channelIDs)
        )
    }

    func foreignTakeoverPreflight(
        for room: RoomDisplayItem,
        requestsEntertainment: Bool,
        selectedConfigID: String? = nil
    ) async -> ForeignTakeoverPreflight {
        guard requestsEntertainment, let bridgeID = room.bridgeID else { return .notRequested }

        // One resolution path for every entry point — the Streaming row, a
        // saved Streaming preset, Party, Thunderstorm. A second path that
        // "just picks something" is exactly how two surfaces come to disagree
        // about which area a room streams to.
        let plan: EntertainmentTakeoverPlan
        switch await exactTargetDecision(for: room, selectedConfigID: selectedConfigID) {
        case .plan(let resolved):          plan = resolved
        case .choiceRequired(let options): return .choiceRequired(options)
        case .staleSelection:              return .staleSelection
        case .noCompatiblePlan:            return .noStreamableArea
        case .unreadableBridge:            return .unreadable
        case .ambiguousOwnership:          return .ambiguous
        }

        guard let snapshot = await entertainmentActivity(onBridge: bridgeID) else {
            return .unreadable
        }
        if snapshot.foreign.isEmpty { return .clear(plan: plan) }
        guard snapshot.foreign.count == 1, let foreignConfigID = snapshot.foreign.first else {
            return .ambiguous
        }
        return .conflict(plan: plan, foreignConfigID: foreignConfigID)
    }

    /// A started but NOT-YET-INSTALLED Entertainment session.
    ///
    /// The session exists on the bridge; nothing in the app points at it yet.
    /// That gap is the whole point: it lets a caller learn that the start
    /// succeeded — or that a third party blocked it — while its previous look
    /// is still running and every piece of bookkeeping still intact.
    struct PreparedEntertainment {
        /// Identity of THIS transaction's candidate.
        ///
        /// `@MainActor` async methods are reentrant: two overlapping starts
        /// each suspend at their bridge reads, so both are in flight at once.
        /// A single "currently pending" slot let the second overwrite the
        /// first, after which one transaction's commit silently cleared the
        /// other's candidate — leaving a live session with nothing tracking
        /// it. Every commit and rollback names the exact candidate instead.
        let id = UUID()
        let client: HueEntertainmentClient
        let plan: EntertainmentTakeoverPlan
        /// The consent that authorized this candidate, if any. Carried to the
        /// commit so it is spent only on a session that actually committed —
        /// and so the final verification knows whether a release of this
        /// exact configuration was genuinely observed earlier.
        let consent: EntertainmentConsent?
        /// The captured configuration, not a freshly selected one.
        var config: EntertainmentConfig { plan.capturedConfig }
        var channelIDs: [UInt8] { plan.channelIDs }
    }

    /// The result of trying to prepare a session, before any commitment.
    enum EntertainmentPreparation {
        /// This start does not stream, or the room has no streamable area.
        /// The existing honest room-mode path is correct.
        case notNeeded
        case prepared(PreparedEntertainment)
        /// A third party owns the bridge. Nothing was mutated, on the bridge
        /// or in the app.
        case needsForeignConsent(snapshot: EntertainmentActivitySnapshot, targetConfigID: String)
        /// Genuine technical inability — room mode is the honest answer.
        case unavailable
        /// One of ChromaGlow's own app-driven looks is streaming this bridge
        /// (packet 7 hardware follow-up). Carries no payload: the current owner
        /// must be re-read at the moment it is acted on, never taken from a
        /// value that was true when the refusal was minted.
        case heldByAnotherLook
        case failed(message: String)
    }

    /// Prepare a session without committing to it (packet 7).
    ///
    /// This is the "prepare" half of prepare/start/commit. Callers run it
    /// BEFORE they tear anything down, so a foreign owner or a failed start
    /// costs the user nothing: the previous look keeps playing, generations do
    /// not advance, telemetry does not open, and no candidate is installed.
    func prepareEntertainment(
        for room: RoomDisplayItem,
        requestsEntertainment: Bool,
        plan capturedPlan: EntertainmentTakeoverPlan? = nil,
        consent: EntertainmentConsent? = nil,
        requester: EntertainmentRequester = .studio
    ) async -> EntertainmentPreparation {
        guard requestsEntertainment, room.bridgeID != nil else { return .notNeeded }

        // After consent, the frozen plan IS the plan. Re-selecting here is
        // exactly how a replay could end up streaming a different area than
        // the one the user agreed to take over.
        let plan: EntertainmentTakeoverPlan
        if let capturedPlan {
            plan = capturedPlan
        } else {
            await warmEntertainmentCaches(for: room, force: true)
            guard let resolved = entertainmentStartPlan(for: room) else { return .notNeeded }
            plan = EntertainmentTakeoverPlan(bridgeID: room.bridgeID!, roomID: room.id,
                                             config: resolved.config,
                                             channelIDs: resolved.channelIDs)
        }

        switch await acquireEntertainment(room: room, plan: plan, consent: consent,
                                          requester: requester) {
        case .started(let client):
            let candidate = PreparedEntertainment(client: client, plan: plan, consent: consent)
            // Outstanding until it is committed or rolled back.
            outstandingEntertainmentCandidates[candidate.id] = candidate
            return .prepared(candidate)
        case .needsForeignConsent(let snapshot):
            return .needsForeignConsent(snapshot: snapshot, targetConfigID: plan.targetConfigID)
        case .failed(let message):
            return .failed(message: message)
        case .unavailable(let reason):
            // Kept distinct all the way up. Collapsing our own live look into
            // the generic `.unavailable` is exactly how the caller would read
            // it as licence to start room mode underneath that look.
            if reason == .heldByAnotherChromaGlowLook { return .heldByAnotherLook }
            return .unavailable
        }
    }

    /// How the final pre-commit verification ended.
    enum EntertainmentCommitVerdict {
        /// Every verification passed; the session is installed and ownership
        /// published. The consent, if any, was spent here and nowhere else.
        case committed
        /// A foreign controller was proven at the commit boundary. The
        /// candidate was released; nothing is installed, nothing published,
        /// the consent unspent. The snapshot presents the contested
        /// configuration as foreign so the caller can re-prompt honestly.
        case contested(snapshot: EntertainmentActivitySnapshot, targetConfigID: String)
        /// The final activity read could not be taken. Unknown is not
        /// verified: the candidate was released and the caller must refuse
        /// with "nothing was changed" — no commit, no fallback, no prompt.
        case verificationUnavailable
        /// Our release was requested but the target was NEVER observed
        /// inactive. The configuration may genuinely still be active, so the
        /// caller must start NOTHING — REST writes underneath an unreleased
        /// stream is the exact condition refused everywhere else. No prompt
        /// either: nothing proved a foreign owner.
        case releaseNotProven
        /// The session died and the target was observed inactive and stayed
        /// inactive. A plain ChromaGlow session failure — the caller refuses
        /// with the explicit streaming-failed answer rather than silently
        /// changing transport. No prompt.
        case sessionFailed
    }

    /// How many fresh activity reads the post-release observation makes
    /// before giving up on ever seeing the target inactive.
    private static let postReleaseReadLimit = 3

    /// The final verification, immediately before commitment — fresh bridge
    /// activity combined with a second exact session-health check.
    ///
    /// This is the only place same-configuration reacquisition can be
    /// honestly detected, and even here it takes a full observed chain. An
    /// active target plus a dead client proves nothing by itself: our own
    /// `action=start` can leave the configuration active briefly after the
    /// DTLS session dies, and the activity reader classifies the target as
    /// ours because `startSession` registered it before activation. So when
    /// the exact client is found dead, this requests OUR release first (a
    /// stop request is never release proof — it can fail, and even a 2xx
    /// only means the bridge accepted it), then performs bounded fresh
    /// reads, and claims a reacquisition only for a target that was
    /// **observed inactive after our release and then observed active
    /// again**. A target never observed inactive is recorded exactly as
    /// that — release not proven — and raises no prompt.
    func verifyAndCommitEntertainment(_ prepared: PreparedEntertainment) async -> EntertainmentCommitVerdict {
        let bridgeID = prepared.plan.bridgeID
        let targetID = prepared.plan.targetConfigID

        // Fresh activity first, then the exact client. In this order a
        // healthy answer covers the read too: the session was alive after
        // the snapshot was taken.
        //
        // FAIL CLOSED on the read itself (round 4): an unreadable final
        // bridge state is UNKNOWN, not verified. Committing a healthy client
        // over a nil read would publish ownership on a bridge whose actual
        // occupancy nobody saw.
        guard let fresh = await entertainmentActivity(onBridge: bridgeID) else {
            debugLog("[Handoff] Final activity read on \(bridgeID) unavailable — releasing rather than committing unverified")
            outstandingEntertainmentCandidates.removeValue(forKey: prepared.id)
            await prepared.client.stopSession()
            noteTakeoverEvent(.nowPlayingWithheld, bridgeID: bridgeID, configID: nil)
            return .verificationUnavailable
        }
        let healthy = await prepared.client.hasStartedSession()

        // A DIFFERENT foreign configuration active at the boundary is
        // directly observed — no release gymnastics needed. The target is
        // EXCLUDED here (round 4): asynchronous terminal teardown can release
        // our own ledger entries before this read, making the target itself
        // read as foreign — and calling that "another configuration" would
        // bypass the observed-transition proof the same-target case requires.
        let foreignOthers = fresh.foreign.subtracting([targetID])
        if !foreignOthers.isEmpty {
            noteTakeoverEvent(.foreignConfigurationReacquiredOtherConfig,
                              bridgeID: bridgeID, configID: foreignOthers.first)
            debugLog("[Handoff] A controller claimed \(bridgeID) at the commit boundary — releasing rather than claiming ownership")
            outstandingEntertainmentCandidates.removeValue(forKey: prepared.id)
            await prepared.client.stopSession()
            noteTakeoverEvent(.nowPlayingWithheld, bridgeID: bridgeID, configID: nil)
            return .contested(snapshot: fresh, targetConfigID: targetID)
        }

        // The target reading as foreign — whatever the cause — means our
        // claim on it is not clean, so it takes the same observed-transition
        // path as a dead client. It is never labelled a reacquisition here.
        let targetAppearsForeign = fresh.foreign.contains(targetID)

        if healthy && !targetAppearsForeign {
            commitEntertainment(prepared)
            // The takeover has now actually produced a VERIFIED, COMMITTED
            // session, so the token is spent. Spending it earlier would burn
            // the user's consent on a session that died before commit.
            if let consent = prepared.consent { consumeEntertainmentConsent(consent) }
            return .committed
        }

        // The exact client is dead (or the target's ownership is no longer
        // cleanly ours). Request our release, then observe.
        outstandingEntertainmentCandidates.removeValue(forKey: prepared.id)
        let stopRequest = await prepared.client.stopSession()
        if stopRequest == .requestFailed {
            debugLog("[Handoff] Our own action=stop on \(targetID) failed — release can only be less certain")
        }

        // Bounded observation: was the target ever seen inactive, and did it
        // come back afterwards? Reads are what carry the truth here — the
        // count is small and fixed, and the tests drive it purely by staged
        // reads.
        var observedInactive = false
        var activeAfterInactive = false
        var lastRead: EntertainmentActivitySnapshot?
        for _ in 0..<Self.postReleaseReadLimit {
            guard let read = await entertainmentActivity(onBridge: bridgeID) else { continue }
            lastRead = read
            let targetActive = read.processOwned.contains(targetID)
                || read.persistedOwned.contains(targetID)
                || read.foreign.contains(targetID)
            if !targetActive {
                observedInactive = true
            } else if observedInactive {
                activeAfterInactive = true
                break
            }
        }

        noteTakeoverEvent(.nowPlayingWithheld, bridgeID: bridgeID, configID: nil)

        if activeAfterInactive, let lastRead {
            // The full observed chain for a SAME-configuration reacquisition:
            // the original foreign target was seen inactive at consent time,
            // our exact client died, our release request completed, the
            // target was again seen inactive, and then seen active. Only
            // with the consent-time observation is the reacquisition event
            // recorded; without it the re-prompt still happens, but nothing
            // asserts a transition nobody watched.
            if let consent = prepared.consent, consent.foreignConfigID == targetID {
                noteTakeoverEvent(.foreignConfigurationReacquiredSameConfig,
                                  bridgeID: bridgeID, configID: targetID)
            }
            debugLog("[Handoff] \(targetID) came back after our observed release on \(bridgeID) — asking rather than claiming")
            // Whatever the ledger says, a configuration active after our own
            // observed release is not ours. Present it as foreign so the
            // re-prompt tells the truth.
            let snapshot = EntertainmentActivitySnapshot(
                bridgeID: lastRead.bridgeID,
                processOwned: lastRead.processOwned.subtracting([targetID]),
                persistedOwned: lastRead.persistedOwned.subtracting([targetID]),
                foreign: lastRead.foreign.union([targetID])
            )
            return .contested(snapshot: snapshot, targetConfigID: targetID)
        }

        if observedInactive {
            // Died and stayed down: a ChromaGlow session failure, nothing
            // more. No prompt — there is no foreign owner to ask about.
            noteTakeoverEvent(.chromaGlowSessionNotUsable, bridgeID: bridgeID, configID: targetID)
            return .sessionFailed
        }
        // Never seen inactive. That may be another controller — or our own
        // start not yet torn down. Say only what was observed, and let the
        // caller start NOTHING: the configuration may genuinely still be
        // streaming, and REST writes underneath an unreleased stream is the
        // exact condition refused everywhere else.
        noteTakeoverEvent(.chromaGlowReleaseNotProven, bridgeID: bridgeID, configID: targetID)
        return .releaseNotProven
    }

    /// Install a prepared session — the "commit" half. In production this is
    /// called only from `verifyAndCommitEntertainment`, once every final
    /// verification has passed (guard 12 pins that); the transaction tests
    /// call it directly to prove the candidate-ledger semantics.
    ///
    /// Committing is also what marks the candidate no longer outstanding: a
    /// session is either installed here exactly once, or stopped by the
    /// rollback below. There is no third outcome in which it stays live with
    /// nothing pointing at it.
    func commitEntertainment(_ prepared: PreparedEntertainment) {
        // Only THIS candidate. Clearing "whatever is pending" would discard a
        // concurrent transaction's candidate and leak its session.
        outstandingEntertainmentCandidates.removeValue(forKey: prepared.id)
        studioEntClients[prepared.plan.bridgeID] = prepared.client
        // This IS the moment ownership becomes real — every verification has
        // passed and the session is now the app's. Recording it here rather
        // than at the caller keeps the event tied to the commit itself.
        noteTakeoverEvent(.ownershipPublished, bridgeID: prepared.plan.bridgeID,
                          configID: prepared.plan.targetConfigID)
    }

    /// Stop a session that was prepared but never committed.
    ///
    /// An uncommitted candidate is the worst kind of leak: live on the bridge,
    /// process-owned AND persisted, but absent from `studioEntClients` — so
    /// nothing drives it, nothing stops it, and the app's own cleanup skips it
    /// forever precisely because it looks owned. Stopping it here balances
    /// both ownership layers through the normal teardown.
    ///
    /// Safe to call unconditionally: after a successful commit there is
    /// nothing outstanding, so this is a no-op.
    func rollbackUncommittedEntertainment(candidateID: UUID) {
        // Claiming by removal is what makes this exactly-once: a second
        // rollback, or one that races a commit, finds nothing and does
        // nothing.
        guard let candidate = outstandingEntertainmentCandidates.removeValue(forKey: candidateID)
        else { return }
        debugLog("[Handoff] Rolling back an uncommitted Entertainment candidate on \(candidate.plan.bridgeID)")
        entertainmentRollbackTasks[candidateID] = Task { [weak self] in
            await candidate.client.stopSession()
            self?.entertainmentRollbackTasks.removeValue(forKey: candidateID)
        }
    }

    /// Re-resolve this room's start plan and confirm it still describes the
    /// stream the user was shown. Used immediately before a takeover stop.
    ///
    /// Re-resolves by the plan's OWN area id, then compares the whole value.
    ///
    /// This used to re-select blind, so that "still uniquely the winner" was
    /// part of the test. That question is now the user's to answer: on a bridge
    /// where two areas can serve one room, blind re-selection resolves to
    /// nothing and every takeover refuses itself. Naming the captured id asks
    /// the question that actually protects the user — is the area the user was
    /// SHOWN still an eligible, streamable area for this room — and
    /// `plan.matches` still fails closed on any change to its channels,
    /// members, or positions, so a re-scoped area cannot slip through.
    func revalidateTakeoverPlan(_ plan: EntertainmentTakeoverPlan,
                                room: RoomDisplayItem) async -> Bool {
        await warmEntertainmentCaches(for: room, force: true)
        guard let resolved = entertainmentStartPlan(for: room,
                                                    preferredConfigID: plan.targetConfigID)
        else { return false }
        return plan.matches(config: resolved.config, channelIDs: resolved.channelIDs)
    }

    /// Stop exactly the session the user consented to replace, and nothing
    /// else.
    ///
    /// This is the only place a third-party session is ever stopped, and it
    /// happens only after an explicit "Take Over". The bridge is re-read
    /// first, because the world may have moved between the prompt appearing
    /// and the user answering it.
    func resolveForeignTakeover(
        requestID: UUID,
        plan: EntertainmentTakeoverPlan,
        room: RoomDisplayItem,
        foreignConfigID: String
    ) async -> ForeignTakeoverResolution {
        let bridgeID = plan.bridgeID

        // 1. Spend the REQUEST token before the first await.
        //
        // Its own ledger, deliberately — a third one. `consumedEntertainmentConsents`
        // is spent much later, when a session actually opens, which is correct
        // for what it guards but useless here: this method suspends several
        // times before reaching it, so two confirmations in flight together
        // would both sail past and both send a stop, the second landing on
        // whatever started in between. Sharing a set with the Studio handoff
        // would let one kind of answer spend the other's token.
        guard !consumedForeignTakeoverRequests.contains(requestID) else {
            debugLog("[Handoff] Foreign takeover \(requestID) was already acted on — refusing to replay it")
            return .failed(message: EntertainmentConsentCopy.takeoverFailed)
        }
        consumedForeignTakeoverRequests.insert(requestID)

        guard let client = clients[bridgeID] else {
            return .failed(message: EntertainmentConsentCopy.bridgeUnreadable)
        }

        // Revalidate BEFORE stopping anything. If the area the user was shown
        // has been deleted, re-scoped away from this room, or lost the channels
        // the render loop needs, then taking over would stop someone else's
        // show and have nowhere to put ours — the worst possible trade.
        guard await revalidateTakeoverPlan(plan, room: room) else {
            debugLog("[Handoff] Captured start plan no longer valid for room \(plan.roomID) — refusing to stop anything")
            return .failed(message: EntertainmentConsentCopy.takeoverFailed)
        }

        guard let snapshot = await entertainmentActivity(onBridge: bridgeID) else {
            return .failed(message: EntertainmentConsentCopy.bridgeUnreadable)
        }

        let consent = EntertainmentConsent(requestID: requestID,
                                           bridgeID: bridgeID,
                                           targetConfigID: plan.targetConfigID,
                                           foreignConfigID: foreignConfigID)

        // Already gone. Nothing to stop — sending a redundant stop would be a
        // write nobody asked for.
        if snapshot.foreign.isEmpty {
            debugLog("[Handoff] Foreign session ended before confirmation — no stop needed")
            return .resolved(consent)
        }

        // More than one, or a different one: fail closed. Consent named ONE
        // session; it cannot be spread over whatever is streaming now.
        guard snapshot.foreign == [foreignConfigID] else {
            debugLog("[Handoff] Foreign owner changed before confirmation — stale consent stops nothing")
            return .changedOwner(snapshot)
        }

        do {
            let (ip, token) = try client.credentials()
            _ = try await client.put(
                path: "/clip/v2/resource/entertainment_configuration/\(foreignConfigID)",
                body: ["action": "stop"], ip: ip, token: token
            )
        } catch {
            // Never claim a takeover that did not happen.
            debugLog("[Handoff] Takeover stop failed: \(error.localizedDescription)")
            noteTakeoverEvent(.foreignStopRequestFailed, bridgeID: bridgeID, configID: foreignConfigID)
            noteTakeoverEvent(.nowPlayingWithheld, bridgeID: bridgeID, configID: nil)
            return .failed(message: EntertainmentConsentCopy.takeoverFailed)
        }

        // ── Verify the stop actually released the area ──────────────
        //
        // Sending a stop is not proof that stopping worked. The PUT returning
        // 2xx says the bridge accepted the request, not that the other
        // controller let go — and on hardware it frequently had not: Hue Sync
        // stayed in control, or took the area straight back. Publishing
        // ownership on the strength of the PUT is how ChromaGlow came to claim
        // a takeover the user could see had not happened.
        guard let after = await entertainmentActivity(onBridge: bridgeID) else {
            // Unknown is not "released". Refuse rather than start on top of a
            // session we cannot see.
            debugLog("[Handoff] Bridge unreadable immediately after the stop — claiming nothing")
            return .failed(message: EntertainmentConsentCopy.bridgeUnreadable)
        }

        if after.foreign.contains(foreignConfigID) {
            // Record ONLY what was observed.
            //
            // This single read cannot distinguish "the stop never released it"
            // from "it released and was reclaimed in the gap" — no inactive
            // state was ever seen, so claiming reacquisition here would be
            // inventing a transition. Both mean "start nothing"; only one of
            // them is a fact. Same-configuration reacquisition is recorded
            // later, in `acquireEntertainment`, where an inactive state HAS
            // been observed first.
            debugLog("[Handoff] \(foreignConfigID) is still active after its stop — release not proven, starting nothing")
            noteTakeoverEvent(.foreignConfigurationRemainedActive,
                              bridgeID: bridgeID, configID: foreignConfigID)
            noteTakeoverEvent(.nowPlayingWithheld, bridgeID: bridgeID, configID: nil)
            return .changedOwner(after)
        }

        noteTakeoverEvent(.foreignConfigurationStopped, bridgeID: bridgeID, configID: foreignConfigID)

        // A DIFFERENT controller arrived in the gap. The user agreed to replace
        // one specific session; this is not that session, and old consent may
        // not reach it.
        if !after.foreign.isEmpty {
            // The consented configuration WAS observed inactive above, so this
            // is a genuine reacquisition by a different session — a transition
            // we actually saw, not one we inferred.
            debugLog("[Handoff] A different session claimed \(bridgeID) after the stop — old consent stops nothing")
            noteTakeoverEvent(.foreignConfigurationReacquiredOtherConfig,
                              bridgeID: bridgeID, configID: after.foreign.first)
            noteTakeoverEvent(.nowPlayingWithheld, bridgeID: bridgeID, configID: nil)
            return .changedOwner(after)
        }

        return .resolved(consent)
    }

    /// The result of acting on the user's "Switch" for one of OUR OWN looks
    /// (packet 7 hardware follow-up).
    enum StudioHandoffResolution: Equatable {
        case resolved
        /// The look ended on its own before the answer arrived. Nothing to
        /// stop — a redundant stop is a write nobody asked for.
        case ownerGone
        /// A DIFFERENT app-driven look owns the bridge now. NOTHING was
        /// stopped: the user agreed to replace one specific look.
        case changedOwner(StudioEntertainmentOwner)
        case failed(message: String)
    }

    /// Stop exactly the ChromaGlow look the user agreed to replace, and nothing
    /// else (packet 7 hardware follow-up).
    ///
    /// The mirror of `resolveForeignTakeover` above, in the same order and for
    /// the same reasons — the only differences are whose session is being
    /// stopped and which ledger spends the token.
    func resolveStudioHandoff(requestID: UUID,
                              plan: EntertainmentTakeoverPlan,
                              room: RoomDisplayItem,
                              owner: StudioEntertainmentOwner) async -> StudioHandoffResolution {
        // 1. Spend the token BEFORE the first await. This method suspends
        //    several times, so two confirmations can be in flight together; a
        //    check performed after a suspension would let both pass and stop
        //    the look twice — the second stop landing on whatever started in
        //    between.
        guard !consumedStudioHandoffRequests.contains(requestID) else {
            debugLog("[Handoff] Studio handoff \(requestID) was already acted on — refusing to replay it")
            return .failed(message: EntertainmentHandoffCopy.handoffFailed)
        }
        consumedStudioHandoffRequests.insert(requestID)

        // 2. Revalidate the REQUESTED look's plan before stopping anything.
        //    Stopping a live look and only then discovering there is nowhere to
        //    put its replacement is the worst possible trade.
        guard await revalidateTakeoverPlan(plan, room: room) else {
            debugLog("[Handoff] Requested plan no longer valid for room \(plan.roomID) — refusing to stop anything")
            return .failed(message: EntertainmentHandoffCopy.handoffFailed)
        }

        // 3. Re-read the owner. Whole-value equality, not just the bridge: an
        //    owner that restarted on a different area, in a different room, or
        //    as a different engine is a different look, and consent named one.
        guard let current = studioOwningEntertainment(onBridge: plan.bridgeID) else {
            debugLog("[Handoff] The look on \(plan.bridgeID) ended before confirmation — no stop needed")
            return .ownerGone
        }
        guard current == owner else {
            debugLog("[Handoff] A different ChromaGlow look owns \(plan.bridgeID) now — stale confirmation stops nothing")
            return .changedOwner(current)
        }

        // 4. The official room-scoped teardown, given the OWNER's bridge — so
        //    this cannot reach any other bridge's session.
        await stopAppDrivenStudioEffect(roomID: owner.roomID, bridgeID: owner.bridgeID)

        // 5. Prove it actually released. `stopSession` cannot throw, so its
        //    return tells us nothing; the refcount is the only honest evidence
        //    that the DTLS session is really gone. If it is not, starting the
        //    replacement would put a second stream on the bridge — the exact
        //    defect this whole correction exists to prevent — so start nothing.
        guard studioEntClients[owner.bridgeID] == nil,
              !entertainmentOwnership.isProcessOwned(bridgeID: owner.bridgeID,
                                                     configID: owner.configID) else {
            debugLog("[Handoff] '\(owner.engineKey)' still holds \(owner.bridgeID) after its stop — refusing to start on top of it")
            return .failed(message: EntertainmentHandoffCopy.stopFailed)
        }

        return .resolved
    }

    /// Read one bridge's active Entertainment configurations and classify each.
    ///
    /// Returns nil when the bridge could not be read — "unknown", which is NOT
    /// the same as "nothing is running" and must never authorize stopping
    /// anything.
    func entertainmentActivity(onBridge bridgeID: String) async -> EntertainmentActivitySnapshot? {
        guard let client = clients[bridgeID] else { return nil }
        do {
            let (ip, token) = try client.credentials()
            let data = try await client.get(
                path: "/clip/v2/resource/entertainment_configuration",
                ip: ip, token: token
            )
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["data"] as? [[String: Any]] else { return nil }

            var processOwned: Set<String> = []
            var persistedOwned: Set<String> = []
            var foreign: Set<String> = []

            for config in items {
                guard let id = config["id"] as? String,
                      let status = config["status"] as? String,
                      status == "active" else { continue }

                if entertainmentOwnership.isProcessOwned(bridgeID: bridgeID, configID: id) {
                    processOwned.insert(id)
                } else if entertainmentOwnership.isPersisted(bridgeID: bridgeID, configID: id) {
                    persistedOwned.insert(id)
                } else {
                    foreign.insert(id)
                }
            }

            return EntertainmentActivitySnapshot(
                bridgeID: bridgeID,
                processOwned: processOwned,
                persistedOwned: persistedOwned,
                foreign: foreign
            )
        } catch {
            log.warning("Entertainment state read failed on \(bridgeID): \(error.localizedDescription)")
            return nil
        }
    }

    /// Clean up Entertainment sessions **ChromaGlow itself left active**.
    ///
    /// This runs unattended from `loadAll` on every launch, foreground, and
    /// state refresh, so it is the one path that must never surprise anyone.
    /// It used to stop EVERY active configuration that this process had not
    /// registered — which silently evicted a Hue Sync Box, another Hue app, or
    /// any other controller, without the user having asked for anything.
    ///
    /// Three classes, three behaviours:
    ///  - owned by this process  → skip; it is a live show
    ///  - persisted ChromaGlow   → ours, orphaned by an unclean exit; stop it
    ///  - foreign                → leave it completely alone. No stop, no
    ///    prompt, and not even a "stuck" warning: it is not stuck, it is
    ///    somebody else's.
    func deactivateStuckEntertainmentSessions() async {
        for (bridgeID, client) in clients {
            guard let snapshot = await entertainmentActivity(onBridge: bridgeID) else {
                // Unreadable bridge: keep every persisted record for this
                // bridge so a later pass can retry, and never infer anything
                // about the other bridges from this one's failure.
                continue
            }

            for id in snapshot.processOwned {
                log.info("Entertainment session \(id) is app-owned and active — skipping cleanup")
            }

            // Each stale ID is handled independently: one failing stop must not
            // skip the rest.
            for id in snapshot.persistedOwned.sorted() {
                // The snapshot is a photograph, and the bridge read that
                // produced it suspended. Asking "still recorded?" and "no owner
                // yet?" as two separate questions and THEN awaiting a stop is
                // not an authorization — it is two facts that were briefly
                // true, with a suspension in between during which a start can
                // complete.
                //
                // The claim makes the decision and the exclusive right to act
                // on it one indivisible step: while it is held, a start for
                // this exact bridge + configuration is refused rather than
                // silently created underneath an in-flight stop.
                guard let claim = entertainmentOwnership.beginStaleCleanup(
                    bridgeID: bridgeID, configID: id) else {
                    log.info("Not claiming \(id) on \(bridgeID) — it is owned, unrecorded, or already being cleaned up")
                    continue
                }
                defer { entertainmentOwnership.endStaleCleanup(claim) }

                log.warning("Found stale ChromaGlow entertainment session \(id) on bridge \(bridgeID) — deactivating")
                do {
                    let (ip, token) = try client.credentials()
                    let body: [String: Any] = ["action": "stop"]
                    _ = try await client.put(
                        path: "/clip/v2/resource/entertainment_configuration/\(id)",
                        body: body, ip: ip, token: token
                    )
                    // Only a CONFIRMED stop retires the record. If the stop
                    // failed the configuration may still be active, so the
                    // evidence is kept for the next launch to retry.
                    entertainmentOwnership.forgetPersisted(bridgeID: bridgeID, configID: id)
                    log.info("Deactivated stale entertainment session \(id)")
                } catch {
                    log.warning("Stale entertainment stop failed for \(id) on \(bridgeID) — keeping ownership record: \(error.localizedDescription)")
                }
            }

            // Prune records the bridge has proved are no longer active: the
            // configuration is inactive or absent entirely, so there is
            // nothing to stop and nothing left to remember.
            let stillActive = snapshot.processOwned
                .union(snapshot.persistedOwned)
                .union(snapshot.foreign)
            for id in entertainmentOwnership.persistedConfigIDs(onBridge: bridgeID)
            where !stillActive.contains(id) {
                entertainmentOwnership.forgetPersisted(bridgeID: bridgeID, configID: id)
                log.info("Pruned ownership record for inactive entertainment config \(id) on \(bridgeID)")
            }
        }
    }
}

// MARK: - All Day Scenes (Solar Curve)

/// Lightweight solar curve for "All Day Scenes".
/// - Computes sunrise/sunset from a one-time location anchor.
/// - Produces target brightness (% 1–100) + CCT (mirek) for grouped_light.
/// - Intentionally low-fidelity: it’s stable, predictable, and cheap to compute.
enum AllDayCurve {   // internal for the solar-instant regression test
    struct Output: Equatable {
        let brightnessPercent: Double
        let mirek: Int
    }

    static func output(at date: Date, lat: Double, lon: Double, timeZone: TimeZone) -> Output {
        let solar = SolarTimes(date: date, lat: lat, lon: lon, timeZone: timeZone)

        // If solar calc fails, fall back to a pleasant warm evening.
        guard let sunrise = solar.sunrise, let sunset = solar.sunset else {
            return Output(brightnessPercent: 35, mirek: 420)
        }

        // Normalize day progress:
        // - Night: warm + dim
        // - Day: cooler + brighter with a midday peak
        let t = date.timeIntervalSince1970
        let sr = sunrise.timeIntervalSince1970
        let ss = sunset.timeIntervalSince1970

        if t < sr || t > ss {
            // Night curve: 8pm–midnight dim warm, midnight–sunrise very dim.
            // (Simple; avoids harsh late-night brightness.)
            return Output(brightnessPercent: 12, mirek: 460)
        }

        let dayProgress = clamp01((t - sr) / max(1, (ss - sr)))
        let midday = 0.5
        let dist = abs(dayProgress - midday) / midday
        let peak = 1.0 - clamp01(dist)              // 0 at edges, 1 at midday
        let smoothPeak = peak * peak * (3 - 2 * peak) // smoothstep

        // Brightness: 28% morning/evening → 85% midday
        let bri = lerp(28, 85, smoothPeak)

        // Color temp: warm (450 mirek) at edges → cool (200 mirek) near midday
        let mirek = Int(round(lerp(450, 200, smoothPeak)))
        return Output(brightnessPercent: bri, mirek: clamp(mirek, 153, 500))
    }

    // MARK: - Solar times (NOAA-ish approximation)

    struct SolarTimes {
        let sunrise: Date?
        let sunset: Date?

        init(date: Date, lat: Double, lon: Double, timeZone: TimeZone) {
            // Based on NOAA sunrise equation, simplified for robustness.
            // Good enough for lighting transitions; not for astronomy.
            let calendar = Calendar(identifier: .gregorian)
            var cal = calendar
            cal.timeZone = timeZone

            let comps = cal.dateComponents([.year, .month, .day], from: date)
            guard let day = cal.date(from: comps) else {
                sunrise = nil; sunset = nil; return
            }

            let n = SolarTimes.dayOfYear(day, calendar: cal)
            sunrise = SolarTimes.compute(event: .sunrise, dayOfYear: n, lat: lat, lon: lon, date: day, tz: timeZone)
            sunset  = SolarTimes.compute(event: .sunset,  dayOfYear: n, lat: lat, lon: lon, date: day, tz: timeZone)
        }

        enum Event { case sunrise, sunset }

        private static func compute(event: Event, dayOfYear n: Int, lat: Double, lon: Double, date: Date, tz: TimeZone) -> Date? {
            // Constants
            let zenith: Double = 90.833 // official
            let lngHour = lon / 15.0

            let t: Double = {
                switch event {
                case .sunrise: return Double(n) + ((6 - lngHour) / 24)
                case .sunset:  return Double(n) + ((18 - lngHour) / 24)
                }
            }()

            // Sun's mean anomaly
            let M = (0.9856 * t) - 3.289

            // Sun's true longitude
            var L = M + (1.916 * sinDeg(M)) + (0.020 * sinDeg(2 * M)) + 282.634
            L = normalize360(L)

            // Right ascension
            var RA = atanDeg(0.91764 * tanDeg(L))
            RA = normalize360(RA)
            // Quadrant adjustment
            let Lquadrant  = floor(L / 90) * 90
            let RAquadrant = floor(RA / 90) * 90
            RA = RA + (Lquadrant - RAquadrant)
            RA = RA / 15

            // Declination
            let sinDec = 0.39782 * sinDeg(L)
            let cosDec = cos(asin(sinDec))

            // Local hour angle
            let cosH = (cosDeg(zenith) - (sinDec * sinDeg(lat))) / (cosDec * cosDeg(lat))
            if cosH > 1 || cosH < -1 { return nil } // polar day/night edge cases

            var H: Double
            switch event {
            case .sunrise: H = 360 - acosDeg(cosH)
            case .sunset:  H = acosDeg(cosH)
            }
            H = H / 15

            // Local mean time
            let T = H + RA - (0.06571 * t) - 6.622
            var UT = T - lngHour
            UT = fmod(UT + 24, 24)

            // Convert UT hours to the ABSOLUTE event instant: UTC midnight of
            // the anchor calendar day + UT seconds. The consumer compares
            // epoch seconds against Date(), so the result must be true
            // absolute time. The old base was startOfDay in the DEVICE
            // calendar plus the anchor offset — the two errors cancel only
            // while device tz == anchor tz; traveling shifted sunrise/sunset
            // by the tz difference (day/night inverted from Tokyo for a NY
            // home), and DST-transition days were off by an hour.
            let seconds = UT * 3600
            var anchorCal = Calendar(identifier: .gregorian)
            anchorCal.timeZone = tz
            var utcCal = Calendar(identifier: .gregorian)
            utcCal.timeZone = TimeZone(identifier: "UTC") ?? tz
            let dayComps = anchorCal.dateComponents([.year, .month, .day], from: date)
            guard let utcDay = utcCal.date(from: dayComps) else { return nil }
            return utcDay.addingTimeInterval(seconds)
        }

        private static func dayOfYear(_ date: Date, calendar: Calendar) -> Int {
            calendar.ordinality(of: .day, in: .year, for: date) ?? 1
        }
    }

    // MARK: - Math helpers

    private static func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
    private static func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { min(hi, max(lo, v)) }
    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
    private static func normalize360(_ x: Double) -> Double {
        var v = fmod(x, 360)
        if v < 0 { v += 360 }
        return v
    }

    private static func sinDeg(_ deg: Double) -> Double { sin(deg * .pi / 180) }
    private static func cosDeg(_ deg: Double) -> Double { cos(deg * .pi / 180) }
    private static func tanDeg(_ deg: Double) -> Double { tan(deg * .pi / 180) }
    private static func atanDeg(_ x: Double) -> Double { atan(x) * 180 / .pi }
    private static func acosDeg(_ x: Double) -> Double { acos(x) * 180 / .pi }
}

// MARK: - SSE Event Models

/// Shared JSON decoder for SSE message parsing.
/// Allocated once — avoids heap churn from JSONDecoder() per SSE line.
/// Safe: @MainActor serialisation means decode() is never called concurrently.
extension UnifiedOrchestrator {
    static let sseDecoder = JSONDecoder()
}

struct SSEEvent: Decodable {
    let type: String
    let data: [SSEResourceUpdate]
}

// MARK: - Stop-audit diagnostics types (PR #60 stop-isolation)
//
// Inert value types, defined unconditionally so the DEBUG-defaulted `context`
// parameters keep a single signature in both configurations. All storage and
// recording is #if DEBUG — in Release these types carry no behavior.
extension UnifiedOrchestrator {

    /// Which surface or internal path initiated a stop chain.
    enum StopAuditRoute: String, Sendable {
        case explicitStop             // Studio card / tray / param-sheet Stop
        case stopAll                  // Studio toolbar Stop All
        case nowPlaying               // Dashboard / Siri via LiveEffectStopTarget
        case applyReplacement         // apply: same-room replacement
        case applyEngineSingleton     // apply: same-bridge app-driven eviction
        case applyEntertainmentScoped // apply: same-bridge entertainment eviction
        case applyLightOverlap        // apply: same-bridge light-overlap eviction
        case reconcileAfterLoop       // engine-loop tail reconciliation
        case bridgeRemoval
        case stopStudioMode           // forget-all global teardown
        case handoff
        case unattributed
    }

    /// Immutable per-stop context, passed by value through the exact call
    /// chain — concurrent stops on two bridges can never overwrite or inherit
    /// one another's route.
    struct StopAuditContext: Sendable {
        let route: StopAuditRoute
        let cardOrEffectID: String?

        init(route: StopAuditRoute, cardOrEffectID: String? = nil) {
            self.route = route
            self.cardOrEffectID = cardOrEffectID
        }

        static let unattributed = StopAuditContext(route: .unattributed)
    }

    /// One destructive stop operation the audit can observe.
    enum StopAuditOperation: String, Sendable {
        case stopRequested
        case taskCancelled
        case restScopeCleared
        case entertainmentGuardSkipped
        case clientStopSession
        case actionStopSent
        case actionStopSuppressed
        case rowRemoved
        case nowPlayingRemoved
        case stopAllInvoked
        case stopStudioModeInvoked
        case reconcileCleanup
    }

    /// One recorded stop operation, with full identity and outcome.
    struct StopAuditEvent: Sendable {
        let sequence: Int
        let timestamp: Date
        let route: StopAuditRoute
        let bridgeID: String?
        let roomID: String?
        let cardOrEffectID: String?
        let runtimeToken: String?
        let clientID: String?
        let operation: StopAuditOperation
        let outcomeReason: String?
    }
}

/// DEBUG-only console diagnostics (house convention — prints are #if DEBUG,
/// see StartupTimeline). Release builds compile the call away, keeping room
/// names and bridge detail out of the release console.
fileprivate func debugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print(message())
    #endif
}
