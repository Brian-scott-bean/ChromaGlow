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
    let id: String           // RoomDisplayItem.id (used as the stable key)
    let roomName: String
    let groupedLightID: String?   // needed to stop bridge-native effects
    let effectID: String          // HueEffect.id
    let effectName: String        // display name
    let effectIcon: String        // SF Symbol
    let isAppDriven: Bool         // true → engine loop must keep running
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
    private let allDayRestSender = RestSender()

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
        guard allDayScenesEnabled, let anchor = loadAllDayAnchor() else { return }
        startAllDayScenes(anchor: anchor)
    }

    func startAllDayScenes(anchor: AllDayAnchor) {
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
        allDayScenesEnabled = false
        allDayGeneration &+= 1
        allDayTask?.cancel()
        allDayTask = nil
        Task { await allDayRestSender.clear() }
    }

    private func tickAllDayScenes(anchor: AllDayAnchor, generation: Int) async {
        guard allDayGeneration == generation else { return }
        guard !isDemoMode else { return }

        let tz = TimeZone(identifier: anchor.timeZoneID) ?? .current
        let now = Date()
        let output = AllDayCurve.output(at: now, lat: anchor.lat, lon: anchor.lon, timeZone: tz)

        // Apply to every room grouped_light with a smooth transition.
        // M-18 class: route each PUT to the room's OWN bridge, not the first.
        let targets = allRooms.compactMap { room -> (glID: String, bridgeID: String?)? in
            guard let glID = room.groupedLightID else { return nil }
            return (glID, room.bridgeID)
        }

        for target in targets {
            await allDayRestSender.enqueue { [weak self] in
                guard let self else { return }
                guard self.allDayGeneration == generation else { return }
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

    /// Removes one room's active effect entry.
    func removeActiveEffect(roomID: String) {
        activeEffectEntries.removeAll { $0.id == roomID }
    }

    /// Removes all active effect entries (Stop All).
    func removeAllActiveEffects() {
        activeEffectEntries.removeAll()
    }

    /// Studio owns effect teardown (per-light no_effect cleanup, engine loops,
    /// mailbox clears, settle delays) — a bare grouped-light PUT from another
    /// surface would leave the loop running underneath. @ObservationIgnored:
    /// installed once from StudioViewModel.configure, never read by views.
    @ObservationIgnored var studioStopHandler: (@MainActor (String, Bool) async -> Void)?

    /// Stop an effect from a non-Studio surface (Dashboard Now-Playing bar,
    /// Siri). `turnOffLights: true` is explicit-stop semantics — the room
    /// goes off, matching the Dashboard Stop button. `false` ends the effect
    /// but leaves lights at their current state (Siri's "stop the lights"
    /// promises exactly that). Still the ONLY sanctioned non-Studio stop path.
    func requestNowPlayingStop(roomID: String, turnOffLights: Bool = true) async {
        if let studioStopHandler {
            await studioStopHandler(roomID, turnOffLights)
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
    func testAwaitEntertainmentCleanup() async {
        await entertainmentCleanupTask?.value
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
        connectionStatus[record.id] = .connecting
        publishWidgetBridgeCredentials()
        // A just-granted bridge coming online can flip the guest-only shell.
        recomputeGuestAccessInfo()
        log.info("Added bridge \(record.id) (\(record.name)) to orchestrator")
    }

    /// Remove a bridge — stops its running effects, cancels SSE, clears
    /// rooms AND zones, wipes credentials + TLS pin.
    func removeBridge(id: String) async {
        // Stop running effects on this bridge's groups BEFORE dropping the
        // client, so teardown/no_effect PUTs can still reach the bridge.
        // Previously these were orphaned: a dead Now-Playing entry pointed at
        // a removed bridge while its render loop kept erroring against it.
        let doomedGroups = ((roomsByBridge[id] ?? []) + (zonesByBridge[id] ?? [])).map(\.id)
        await stopEffectsForRemovedGroups(doomedGroups)
        sseTasks[id]?.cancel()
        sseTasks.removeValue(forKey: id)
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

    /// Stop any running effects on rooms/zones that are about to disappear
    /// (bridge removal, room/zone delete). Routes through the sanctioned
    /// requestNowPlayingStop path so the owning engine loop, transport truth,
    /// and Studio's mirror tear down together. turnOffLights: false — the
    /// group is going away; a goodbye off-PUT is pointless (and unreachable
    /// once a removed bridge's client is dropped).
    /// (Internal, not private, so tests can drive it directly.)
    func stopEffectsForRemovedGroups(_ groupIDs: [String]) async {
        let doomed = Set(groupIDs)
        for entry in activeEffectEntries where doomed.contains(entry.id) {
            await requestNowPlayingStop(roomID: entry.id, turnOffLights: false)
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
        let __loadStart = Date()   // TEMP PERF DIAG
        StartupTimeline.mark("loadAll.begin", "bridges=\(clients.count)")
        defer { isLoading = false }

        // D-016 pin acquisition is now per-host inside fetchAndMergeAllBridges so a
        // single offline unpinned bridge no longer stalls every bridge's first fetch
        // up to ~10s. Pinned hosts (the steady state) are a synchronous no-op there.

        // Fetch every bridge (per-bridge pin acquisition happens inside). Stuck
        // entertainment-session cleanup no longer shares this await — it is deferred
        // and throttled below so it never delays first paint or fires per toggle.
        await fetchAndMergeAllBridges()
        StartupTimeline.mark("loadAll.fetch-done", "in \(Int(Date().timeIntervalSince(__loadStart) * 1000))ms — lights per bridge=\(lightsByBridge.mapValues { $0.count })")

        // Yield so any pending main-thread interactions (e.g. tab bar) run before
        // large @Observable room list updates from rebuildAllRooms/Zones.
        await Task.yield()

        rebuildAllRooms()
        rebuildAllZones()
        lastLoadedAt = Date()
        StartupTimeline.mark("loadAll.total", "\(Int(Date().timeIntervalSince(__loadStart) * 1000))ms → allRooms=\(allRooms.count)")
        // Scenes load lazily (Scenes tab realize), but the widget/watch
        // publisher must not preserve a stale snapshot all session. Fetch
        // once per cold session — detached from this await so the cold-start
        // critical section and the prewarm gate are untouched.
        if !hasLoadedScenesOnce {
            Task { [weak self] in await self?.loadAllScenes() }
        }
        scheduleEntertainmentCleanup()
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
            pendingActionDeadlines.removeValue(forKey: glID)   // release guard
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
            pendingActionDeadlines.removeValue(forKey: glID)   // release guard
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
        // group and leave a ghost Now-Playing entry.
        await stopEffectsForRemovedGroups([item.id])
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
        await stopEffectsForRemovedGroups([item.id])
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

    /// Group ids (room or zone) the app is currently driving via a composition — REST
    /// (`compositionRuntimes`) or DTLS (`compositionEntRoomByBridge`). Used to suppress
    /// SSE echo of our own ~8 Hz per-light PUTs, which would otherwise rebuild the
    /// dashboard at composition frame rate. Returns `[]` (no allocation) when nothing
    /// is playing, so applySSEEvent behavior is unchanged in the common case.
    private var appDrivenGroupIDs: Set<String> {
        guard !compositionRuntimes.isEmpty || !compositionEntRoomByBridge.isEmpty else { return [] }
        var ids = Set(compositionRuntimes.keys)
        ids.formUnion(compositionEntRoomByBridge.values)
        return ids
    }

    /// Returns which of rooms/zones were mutated so callers can skip unnecessary rebuilds.
    @discardableResult
    func applySSEEvent(_ event: SSEEvent, bridgeID: String) -> (rooms: Bool, zones: Bool) {
        var roomsMutated = false
        var zonesMutated = false
        // Rooms/zones the app is actively driving — their SSE echoes are our own PUTs.
        let driven = appDrivenGroupIDs
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
                    // Skip if the app is driving this room via a composition — the echo of
                    // our own per-light PUTs would rebuild the dashboard at frame rate.
                    if !isPending && !driven.contains(rooms[idx].id) {
                        if let on  = update.on?.on              { rooms[idx].isOn       = on  }
                        if let bri = update.dimming?.brightness { rooms[idx].brightness = bri }
                        roomsByBridge[bridgeID] = rooms
                        roomsMutated = true
                    }
                }
                if var zones = zonesByBridge[bridgeID],
                   let idx = zones.firstIndex(where: { $0.groupedLightID == update.id }) {
                    let isPending = pendingActionDeadlines[update.id].map { Date() < $0 } ?? false
                    if !isPending && !driven.contains(zones[idx].id) {
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
                let cacheRoomDriven = lightIDToRoomID[update.id].map(driven.contains) ?? false
                let cacheZoneDriven = lightIDToZoneID[update.id].map(driven.contains) ?? false
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
                   !driven.contains(roomID),
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
                   !driven.contains(zoneID),
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
            WidgetDataStore.shared.write(rooms: roomSnaps, zones: zoneSnaps, scenes: sceneSnaps)
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

    /// Stored reference to the running studio task (strobe, etc.)
    /// so stopStudioMode() can cancel it. Without this, loops run forever.
    private var activeStudioTask: Task<Void, Never>?

    /// Entertainment clients keyed by bridgeID — one per concurrent bridge session.
    /// Internal access so StudioViewModel can report transport mode in debug.
    var studioEntClients: [String: HueEntertainmentClient] = [:]

    /// Latest-wins REST sender for studio mode — prevents bridge command backlog.
    private let studioRestSender = RestSender()

    /// Studio live-param writes (StudioViewModel sendParam/sendColorParam)
    /// share the studio mailbox: repeated writes to the same endpoint where
    /// only the newest value matters — a slider scrub can never stack PUTs
    /// behind stale frames, and the stop/handoff clear()s also drop any
    /// pending param write before a new owner starts.
    func enqueueStudioRestWrite(_ work: @escaping @Sendable () async -> Void) async {
        await studioRestSender.enqueue(work)
    }
    /// Generation counter for studio/composer engine loops.
    /// Increment on every start/stop; async closures must match to send.
    private var studioGeneration: Int = 0
    /// Per-room composition generation counters.
    private var compositionGenerations: [String: Int] = [:]
    /// Shared composition scheduler state (room-scoped runtimes, single bridge-fair ticker).
    private var compositionRuntimes: [String: CompositionRuntime] = [:]
    private var compositionOrder: [String] = []
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

    private struct CompositionTelemetry {
        var sends: Int = 0
        var lagSumMs: Double = 0
        var maxLagMs: Double = 0
        var windowStart: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    }
    /// Latest observed REST cadence (seconds/update) for composition scheduler.
    /// Exposed for QA visibility in Studio UI.
    var activeRESTCadence: Double? = nil
    /// Per-room cadence in seconds/update.
    var activeRESTCadenceByRoom: [String: Double] = [:]
    @ObservationIgnored
    private var cadenceLastUIUpdateByRoom: [String: CFAbsoluteTime] = [:]
    private var compositionTelemetryByRoom: [String: CompositionTelemetry] = [:]
    /// Per-bridge entertainment tasks — allows concurrent sessions across multiple bridges.
    private var compositionEntTasks: [String: Task<Void, Never>] = [:]
    /// Per-bridge active room IDs — guards against starting a second session on the same bridge.
    private var compositionEntRoomByBridge: [String: String] = [:]
    /// Per-bridge param boxes for mic-demand tracking. Weak so they don't prevent dealloc.
    private var compositionEntParamBoxes: [String: CompositionParamBox] = [:]

    // MARK: Bridge-Stored Animation (v1 API)
    private let bridgeAnimationEngine = BridgeAnimationEngine()
    private let bridgeAnimationStore = BridgeAnimationStore.shared

    /// Which transport is driving each room's composition right now.
    enum CompositionTransport: Equatable {
        case entertainment   // DTLS streaming
        case rest            // app-driven REST scheduler
        case bridgeStored    // v1 rules chain on the bridge itself
    }
    /// Per-room transport truth (absent key = no composition running there).
    /// Written only at start / stop / failover — never per frame — so views
    /// may observe it freely. Replaces the old global `isBridgeStored` flag,
    /// which mislabeled every room whenever ANY room ran bridge-stored.
    var compositionTransportByRoom: [String: CompositionTransport] = [:]
    /// Entertainment configs keyed by bridgeID.
    /// StudioView reads the config for the currently selected room's bridge.
    var entertainmentConfigsByBridge: [String: EntertainmentConfig] = [:]

    /// Bridges whose entertainment configs we have actually asked about.
    /// Assigning nil into `entertainmentConfigsByBridge` *removes* the key, so
    /// the dictionary alone cannot tell "this bridge has no area" apart from
    /// "we never looked" — and the difference decides whether the UI may say no.
    var entertainmentConfigsFetchedBridges: Set<String> = []

    /// Convenience: returns the entertainment config for the given room's bridge.
    /// Replaces the old single-slot `activeEntertainmentConfig`.
    func activeEntertainmentConfig(for room: RoomDisplayItem?) -> EntertainmentConfig? {
        guard let bridgeID = room?.bridgeID else { return nil }
        return entertainmentConfigsByBridge[bridgeID]
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
        case noBridge
        /// We have not asked the bridge yet. Offer streaming rather than
        /// wrongly disabling it — `startCompositionMode` still falls back.
        case unknown

        /// Whether the transport option should be offered as usable.
        var canStream: Bool {
            switch self {
            case .available, .unknown: return true
            case .noClientKey, .noArea, .noBridge: return false
            }
        }

        /// Why streaming is unavailable, in a sentence a user can act on.
        var reason: String? {
            switch self {
            case .available, .unknown:
                return nil
            case .noClientKey:
                return "This bridge was paired without streaming access. Re-pair it in Settings to enable Entertainment."
            case .noArea:
                return "This bridge has no entertainment area yet."
            case .noBridge:
                return "This room isn't on a reachable bridge."
            }
        }
    }

    /// Synchronous — safe to call while a menu is being built. Reads the
    /// Keychain and the config cache; never touches the network.
    func entertainmentAvailability(for room: RoomDisplayItem?) -> EntertainmentAvailability {
        guard let bridgeID = room?.bridgeID, hueClient(for: bridgeID) != nil else { return .noBridge }
        guard KeychainManager.shared.loadClientKey(for: bridgeID) != nil else { return .noClientKey }

        if let config = entertainmentConfigsByBridge[bridgeID] {
            return .available(areaName: config.name)
        }
        return entertainmentConfigsFetchedBridges.contains(bridgeID) ? .noArea : .unknown
    }

    /// Warms the config cache for a room's bridge so `entertainmentAvailability`
    /// can stop answering `.unknown`. Cheap and idempotent: one GET per bridge.
    func refreshEntertainmentConfigs(for room: RoomDisplayItem?) async {
        guard let bridgeID = room?.bridgeID,
              !entertainmentConfigsFetchedBridges.contains(bridgeID),
              KeychainManager.shared.loadClientKey(for: bridgeID) != nil
        else { return }

        let config = await findEntertainmentConfig(bridgeID: bridgeID)
        entertainmentConfigsFetchedBridges.insert(bridgeID)
        if let config { entertainmentConfigsByBridge[bridgeID] = config }
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
    // @ObservationIgnored keeps this a STORED property so nonisolated(unsafe)
    // takes effect (@Observable otherwise rewrites it computed, where the
    // attribute is a no-op). Private and never view-observed; StudioParamBox
    // is @unchecked Sendable with its documented cross-actor-write contract.
    @ObservationIgnored nonisolated(unsafe) private var activeParamBox: StudioParamBox?

    /// Update live params while an engine is running (called by StudioViewModel on slider change).
    /// Nonisolated because StudioParamBox is @unchecked Sendable — safe for cross-actor writes.
    nonisolated func updateStudioParams(values: [String: Double], colors: [String: Color]) {
        activeParamBox?.values = values
        activeParamBox?.colors = colors
    }

    func startStudioMode(
        key: String,
        room: RoomDisplayItem,
        params: [String: Double],
        colors: [String: Color]
    ) async {
        // Cancel any previously running studio task first
        activeStudioTask?.cancel()
        activeStudioTask = nil
        studioGeneration += 1
        await studioRestSender.clear()
        let stopBid = room.bridgeID ?? ""
        if let entClient = studioEntClients[stopBid] {
            await entClient.stopSession()
            studioEntClients.removeValue(forKey: stopBid)
        }

        guard let api = hueClient(for: room.bridgeID),
              let groupedLightID = room.groupedLightID else { return }

        // Create live param box (engine loop reads from this; ViewModel updates it)
        let paramBox = StudioParamBox(values: params, colors: colors)
        activeParamBox = paramBox

        switch key {
        case "strobe":
            // Try entertainment first for crisp on/off, fall back to REST
            let entClient = await tryStartEntertainment(room: room)
            if let entClient {
                let config = await findEntertainmentConfig(bridgeID: room.bridgeID)
                let channelIDs = config?.channels.map { UInt8($0.id) } ?? [0]
                activeStudioTask = Task {
                    await runStrobeEntertainment(entClient: entClient, channelIDs: channelIDs, paramBox: paramBox)
                }
            } else {
                activeStudioTask = Task {
                    await runStrobeREST(api: api, groupedLightID: groupedLightID, paramBox: paramBox)
                }
            }

        case "party":
            let entClient = await tryStartEntertainment(room: room)
            if let entClient {
                let config = await findEntertainmentConfig(bridgeID: room.bridgeID)
                let channelIDs = config?.channels.map { UInt8($0.id) } ?? [0]
                activeStudioTask = Task {
                    await runPartyEntertainment(entClient: entClient, channelIDs: channelIDs, paramBox: paramBox)
                }
            } else {
                activeStudioTask = Task {
                    await runPartyREST(api: api, groupedLightID: groupedLightID, paramBox: paramBox)
                }
            }

        case "thunderstorm":
            let entClient = await tryStartEntertainment(room: room)
            if let entClient {
                let config = await findEntertainmentConfig(bridgeID: room.bridgeID)
                let channelIDs = config?.channels.map { UInt8($0.id) } ?? [0]
                activeStudioTask = Task {
                    await runThunderstormEntertainment(entClient: entClient, channelIDs: channelIDs, paramBox: paramBox)
                }
            } else {
                activeStudioTask = Task {
                    await runThunderstormREST(api: api, groupedLightID: groupedLightID, paramBox: paramBox)
                }
            }

        case "ambient":
            // Ambient is slow enough for REST (one change every few seconds)
            activeStudioTask = Task {
                await runAmbientREST(api: api, groupedLightID: groupedLightID, paramBox: paramBox)
            }

        default:
            let brightness = params["brightness"] ?? 80
            try? await api.setGroupedLightBrightness(id: groupedLightID, brightness: brightness)
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Composition Engine
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private func anyCompositionNeedsMic() -> Bool {
        if compositionRuntimes.values.contains(where: { $0.paramBox.reaction.requiresMic }) {
            return true
        }
        // A mic-reactive preset cued on Perform's deck B isn't a runtime box
        // yet — it must still raise demand or it reads silence until promoted.
        if let mix = activePerformanceMix, mix.deckB?.reaction.requiresMic == true {
            return true
        }
        return compositionEntParamBoxes.values.contains { $0.reaction.requiresMic }
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
    func startCompositionMode(
        room: RoomDisplayItem,
        paramBox: CompositionParamBox,
        gamutOverride: HueColorUtils.Gamut? = nil,
        preferEntertainment: Bool = true,
        tier: CompositionTier = .runtimeOnly,
        preset: CompositionPreset? = nil
    ) async {
        guard let api = hueClient(for: room.bridgeID),
              let groupedLightID = room.groupedLightID else { return }
        let roomID = room.id
        let nextGeneration = (compositionGenerations[roomID] ?? 0) + 1
        compositionGenerations[roomID] = nextGeneration
        let compositionGamut: HueColorUtils.Gamut
        if let gamutOverride {
            compositionGamut = gamutOverride
            if paramBox.reaction.requiresMic {
                await AudioAnalysisEngine.shared.setDemand(.composerReaction, active: true)
                lastComposerMicDemand = true   // keep the per-frame refresh cache coherent
            }
        } else if paramBox.reaction.requiresMic {
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

        // ── Fetch entertainment config BEFORE transport decision ──
        // Both REST and DTLS paths benefit from spatial positions.
        let entConfig = await findEntertainmentConfig(bridgeID: room.bridgeID)
        let capturedBridgeID = room.bridgeID ?? ""
        await MainActor.run {
            // A nil assignment removes the key, so record separately that we
            // asked — that is what lets the transport menu say "no area"
            // instead of hedging.
            entertainmentConfigsByBridge[capturedBridgeID] = entConfig
            entertainmentConfigsFetchedBridges.insert(capturedBridgeID)
        }

        // Resolve individual light IDs early — needed for REST spatial positions
        // AND for per-light REST mode later.
        let compositionLightIDs = await resolveCompositionLightIDs(for: room, api: api)
        debugLog("[Composer] 🔍 Resolved \(compositionLightIDs.count) individual lights for per-light REST")

        if let entConfig {
            // Auto-detect principal angle when user hasn't set one
            if paramBox.motion.motionAngle < 0 {
                paramBox.motion.motionAngle = CompositionEngine.principalAngle(channels: entConfig.channels)
            }

            // ── Build lightID → position map ──
            // Entertainment channel members point to entertainment services (not light services).
            // Bridge the IDs: entertainment_service → device → light.
            let lightPositions = await resolveEntertainmentLightPositions(
                config: entConfig, api: api
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
           compositionEntRoomByBridge[bridgeID] == nil,
           compositionRuntimes.isEmpty {
            // Mic (when reaction uses it) is already warming during gamut resolution above,
            // overlapping network time with FFT capture startup.
            let entClient = await tryStartEntertainment(room: room)
            if let entClient, let entConfig {
                let channelIDs = entConfig.channels.map { UInt8($0.id) }
                if !channelIDs.isEmpty {
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
                    compositionTransportByRoom[roomID] = .entertainment
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
                    return
                }
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
            do {
                let v1Client = try api.makeV1Client()

                // Clean up any existing bridge animation for this room first
                for oldManifest in bridgeAnimationStore.allManifests() where oldManifest.roomID == roomID {
                    debugLog("[Composer] Cleaning up previous bridge animation for \(oldManifest.presetName)")
                    await bridgeAnimationEngine.stop(manifest: oldManifest, v1Client: v1Client)
                    bridgeAnimationStore.remove(presetID: oldManifest.presetID, roomID: roomID)
                }

                // Purge any orphaned CG_ resources from previous test runs
                await bridgeAnimationEngine.purgeAllChromaGlowResources(v1Client: v1Client)

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
                    debugLog("[Composer] ⚠ Could not fetch lights for id_v1 mapping — running app-driven (stops when the app closes)")
                }
                let manifest = try await bridgeAnimationEngine.upload(
                    preset: preset,
                    room: room,
                    lightIDs: compositionLightIDs,
                    v2Lights: v2Lights,
                    gamut: compositionGamut,
                    v1Client: v1Client
                )
                bridgeAnimationStore.save(manifest)
                compositionTransportByRoom[roomID] = .bridgeStored
                debugLog("[Composer] ⚡ Bridge-stored animation active! \(manifest.stepCount) steps, \(manifest.intervalSeconds)s/step")
                debugLog("[Composer] ⚡ Close the app — lights will keep going!")

                // ── Immediate prime frame ──
                // The first bridge rule won't fire until the schedule ticks (up to cycleTotalSeconds away).
                // Send step-0 of the composition now so the room turns on instantly after the card tap.
                let paramBox = CompositionParamBox(preset: preset)
                if let firstFrame = CompositionEngine.render(
                    time: 0,
                    channelIDs: [0],
                    params: paramBox
                ).first {
                    let primeXY = HueColorUtils.clampXYToGamut(x: firstFrame.x, y: firstFrame.y, gamut: compositionGamut)
                    let primeBri = max(1.0, firstFrame.brightness * 100.0)
                    do {
                        try await api.setGroupedLightEffect(
                            id: groupedLightID, on: true,
                            brightness: primeBri,
                            xy: (primeXY.x, primeXY.y),
                            mirek: nil,
                            duration: 500
                        )
                        debugLog("[Composer][BridgePrime] ✅ room='\(room.name)' bri=\(String(format: "%.1f", primeBri))")
                    } catch {
                        debugLog("[Composer][BridgePrime] ⚠ Prime frame failed (bridge animation still active): \(error.localizedDescription)")
                    }
                }
                return  // Don't start app-driven scheduler
            } catch {
                debugLog("[Composer] ⚠ Bridge-stored upload failed, falling back to app-driven: \(error.localizedDescription)")
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
            }
        }

        compositionTransportByRoom[roomID] = .rest
        compositionRuntimes[roomID] = CompositionRuntime(
            roomID: roomID,
            roomName: room.name,
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
        if !compositionOrder.contains(roomID) {
            compositionOrder.append(roomID)
        }

        // Prime immediately so newly started rooms visibly turn on without
        // waiting for the next round-robin scheduler slot.
        await refreshCompositionMicDemand()
        if let firstFrame = CompositionEngine.render(
            time: 0,
            channelIDs: [0],
            params: paramBox,
            features: AudioAnalysisEngine.latestFeatures(),
            beat: BeatClock.snapshot(),
            hostNow: CACurrentMediaTime()
        ).first {
            let xy = HueColorUtils.clampXYToGamut(x: firstFrame.x, y: firstFrame.y, gamut: compositionGamut)
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
            } catch {
                debugLog("[Composer][Prime] ❌ room='\(room.name)' id=\(roomID) gen=\(nextGeneration) error=\(error)")
            }
            if var runtime = compositionRuntimes[roomID] {
                runtime.lastSentX = xy.x
                runtime.lastSentY = xy.y
                runtime.lastSentBri = bri
                runtime.sendCount = 1
                runtime.lastSentAt = CFAbsoluteTimeGetCurrent()
                compositionRuntimes[roomID] = runtime
            }
        }

        ensureCompositionSchedulerRunning()
        await refreshCompositionMicDemand()
        debugLog("[Composer] 📡 Scheduled room='\(room.name)' on global composition ticker")
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
                    params: paramBox,
                    features: AudioAnalysisEngine.latestFeatures(),
                    beat: BeatClock.snapshot(),
                    hostNow: CACurrentMediaTime()
                )
            }

            // Convert to entertainment send format
            let channels = frames.map { frame in
                let xy = HueColorUtils.clampXYToGamut(x: frame.x, y: frame.y, gamut: gamut)
                return (id: frame.channelID, x: xy.x, y: xy.y, brightness: frame.brightness)
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
        // Re-entry below records `.rest`; if its guard bails instead, the room
        // correctly reads "not running" rather than a phantom `.entertainment`.
        compositionTransportByRoom.removeValue(forKey: roomID)
        compositionEntParamBoxes.removeValue(forKey: bridgeID)
        compositionEntTasks.removeValue(forKey: bridgeID)   // this task; loop already ended
        compositionEntRoomByBridge.removeValue(forKey: bridgeID)
        entertainmentConfigsByBridge.removeValue(forKey: bridgeID)
        // Session teardown, not "this bridge has no area" — forget that we
        // asked, so availability reverts to .unknown rather than .noArea.
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

    func stopCompositionMode(roomID: String) async {
        debugLog("[Handoff] Composer stop requested for roomID=\(roomID)")
        compositionGenerations[roomID] = (compositionGenerations[roomID] ?? 0) + 1

        // ─── Stop bridge-stored animation if active ───
        // M-07: tear down against the manifest's OWN bridge, never the
        // nondeterministic first client — a second bridge's animation would
        // otherwise loop forever while its manifest is dropped locally.
        for manifest in bridgeAnimationStore.allManifests() where manifest.roomID == roomID {
            if let api = hueClient(forBridgeIP: manifest.bridgeIP),
               let v1Client = try? api.makeV1Client() {
                await bridgeAnimationEngine.stop(manifest: manifest, v1Client: v1Client)
            } else {
                // The manifest's bridge is no longer registered — no client can
                // ever clean it up, so drop the manifest instead of leaking it.
                // (Bridge-side CG_ leftovers age out via the purge path.)
                debugLog("[Handoff] ⚠ No registered client for bridge \(manifest.bridgeIP) — dropping manifest without bridge cleanup")
            }
            bridgeAnimationStore.remove(presetID: manifest.presetID, roomID: roomID)
        }
        compositionTransportByRoom.removeValue(forKey: roomID)
        debugLog("[Handoff] Clearing studio REST sender mailbox for roomID=\(roomID)")
        await studioRestSender.clear()
        // Give Hue bridge firmware a brief settle window before any new owner starts writing.
        try? await Task.sleep(for: .milliseconds(150))
        debugLog("[Handoff] REST mailbox cleared + settle delay complete for roomID=\(roomID)")
        // Stop entertainment session for this room's bridge (if any)
        let stopBridgeID = compositionEntRoomByBridge.first(where: { $0.value == roomID })?.key
        if let bid = stopBridgeID {
            compositionEntParamBoxes.removeValue(forKey: bid)
            compositionEntTasks[bid]?.cancel()
            compositionEntTasks.removeValue(forKey: bid)
            compositionEntRoomByBridge.removeValue(forKey: bid)
            entertainmentConfigsByBridge.removeValue(forKey: bid)
            entertainmentConfigsFetchedBridges.remove(bid)   // see failCompositionEntertainmentToREST
            if let entClient = studioEntClients[bid] {
                await entClient.stopSession()
                studioEntClients.removeValue(forKey: bid)
            }
        }
        compositionRuntimes.removeValue(forKey: roomID)
        compositionTelemetryByRoom.removeValue(forKey: roomID)
        activeRESTCadenceByRoom.removeValue(forKey: roomID)
        cadenceLastUIUpdateByRoom.removeValue(forKey: roomID)
        if activeRESTCadenceByRoom.isEmpty {
            activeRESTCadence = nil
        }
        compositionOrder.removeAll { $0 == roomID }
        if compositionRuntimes.isEmpty {
            compositionSchedulerTask?.cancel()
            compositionSchedulerTask = nil
        }
        await refreshCompositionMicDemand()
        // Re-sync this room's card to the bridge's confirmed state — while the
        // composition ran, its SSE echoes were suppressed (appDrivenGroupIDs), so
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
        // All sends go through studioRestSender (latest-wins mailbox).
        // The mailbox drops stale frames, so the bridge always gets
        // the NEWEST per-light colors.
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

            let now = CFAbsoluteTimeGetCurrent()
            guard let roomID = nextCompositionRoomPriority(now: now),
                  var runtime = compositionRuntimes[roomID] else {
                try? await Task.sleep(for: tickInterval)
                continue
            }

            // Generation guard — don't send for stale/stopped rooms
            guard compositionGenerations[roomID] == runtime.generation else {
                compositionRuntimes.removeValue(forKey: roomID)
                compositionOrder.removeAll { $0 == roomID }
                continue
            }

            // Render the current frame — per-light when IDs are available
            let elapsed = now - runtime.startTime
            let lightCount = runtime.lightIDs.count
            let usePerLight = lightCount > 0

            // Build channel IDs: one per light for per-light mode, or [0] for
            // grouped. A gradient map expands strips into extra channels so
            // motion travels ALONG them (Round 3 F).
            let channelIDs: [UInt8] = {
                guard usePerLight else { return [0] }
                if let map = runtime.gradientMap {
                    return (0..<UInt8(min(map.totalChannels, 20))).map { $0 }
                }
                return (0..<UInt8(min(lightCount, 20))).map { $0 }
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

            // Check if anything changed visually (use first frame as proxy)
            let firstFrame = frames[0]
            let firstXY = HueColorUtils.clampXYToGamut(x: firstFrame.x, y: firstFrame.y, gamut: runtime.gamut)
            let firstBri = max(1, firstFrame.brightness * 100.0)
            let colorDelta: Double = {
                guard let lx = runtime.lastSentX, let ly = runtime.lastSentY else { return .greatestFiniteMagnitude }
                return hypot(firstXY.x - lx, firstXY.y - ly)
            }()
            let briDelta = abs(firstBri - (runtime.lastSentBri ?? -999))
            if colorDelta < 0.003 && briDelta < 1.0 {
                try? await Task.sleep(for: tickInterval)
                continue
            }

            // Capture values for the closure
            let capturedAPI = runtime.api
            let capturedGen = runtime.generation
            let latestGen = compositionGenerations[roomID] ?? -1
            let capturedGamut = runtime.gamut

            if usePerLight, let map = runtime.gradientMap {
                // ── GRADIENT-AWARE PER-LIGHT MODE (Round 3 F) ──
                // Strips get ONE gradient.points PUT carrying their whole
                // channel range; flat lights keep the per-light PUT. Same
                // mailbox, same pacing profile as the flat path.
                let capturedMap = map
                let capturedFrames = frames

                await studioRestSender.enqueue {
                    guard capturedGen == latestGen else { return }

                    let batchSize = 5
                    let entries = capturedMap.entries
                    for batchStart in stride(from: 0, to: entries.count, by: batchSize) {
                        let batchEnd = min(batchStart + batchSize, entries.count)
                        await withTaskGroup(of: Void.self) { group in
                            for entry in entries[batchStart..<batchEnd] {
                                let entryFrames = entry.channelRange.compactMap { idx in
                                    idx < capturedFrames.count ? capturedFrames[idx] : nil
                                }
                                guard let first = entryFrames.first else { continue }
                                group.addTask {
                                    if entry.isGradient {
                                        let points = entryFrames.map { frame -> CGPoint in
                                            let xy = HueColorUtils.clampXYToGamut(
                                                x: frame.x, y: frame.y, gamut: capturedGamut)
                                            return CGPoint(x: xy.x, y: xy.y)
                                        }
                                        let avgBri = entryFrames.map(\.brightness)
                                            .reduce(0, +) / Double(entryFrames.count)
                                        try? await capturedAPI.setLightGradient(
                                            id: entry.lightID,
                                            body: GradientBody(
                                                pointsXY: points,
                                                brightness: max(1, avgBri * 100.0),
                                                on: true,
                                                durationMs: 200))
                                    } else {
                                        let xy = HueColorUtils.clampXYToGamut(
                                            x: first.x, y: first.y, gamut: capturedGamut)
                                        try? await capturedAPI.setLightEffect(
                                            id: entry.lightID, on: true,
                                            brightness: max(1, first.brightness * 100.0),
                                            xy: (xy.x, xy.y),
                                            mirek: nil,
                                            duration: 200)
                                    }
                                }
                            }
                        }
                        if batchEnd < entries.count {
                            try? await Task.sleep(for: .milliseconds(80))
                        }
                    }
                    #if DEBUG
                    print("[Composer][REST] ✅ gradient-aware room=\(roomID) entries=\(entries.count)")
                    #endif
                }
            } else if usePerLight {
                // ── PER-LIGHT MODE ──
                // Each light gets its own color. Cascade/wave patterns visible.
                // Bridge handles ~10 PUTs/sec for individual lights.
                let capturedLightIDs = runtime.lightIDs
                let capturedFrames = frames

                await studioRestSender.enqueue {
                    guard capturedGen == latestGen else { return }

                    // Send each light its unique color — batched with
                    // concurrent sends (bridge handles ~10/sec individual)
                    let batchSize = 5  // safe concurrent limit
                    for batchStart in stride(from: 0, to: capturedLightIDs.count, by: batchSize) {
                        let batchEnd = min(batchStart + batchSize, capturedLightIDs.count)
                        await withTaskGroup(of: Void.self) { group in
                            for i in batchStart..<batchEnd {
                                guard i < capturedFrames.count else { continue }
                                let lightID = capturedLightIDs[i]
                                let frame = capturedFrames[i]
                                let xy = HueColorUtils.clampXYToGamut(
                                    x: frame.x, y: frame.y, gamut: capturedGamut
                                )
                                let bri = max(1, frame.brightness * 100.0)
                                group.addTask {
                                    try? await capturedAPI.setLightEffect(
                                        id: lightID, on: true,
                                        brightness: bri,
                                        xy: (xy.x, xy.y),
                                        mirek: nil,
                                        duration: 200
                                    )
                                }
                            }
                        }
                        // Small gap between batches if more remain
                        if batchEnd < capturedLightIDs.count {
                            try? await Task.sleep(for: .milliseconds(80))
                        }
                    }
                    #if DEBUG
                    print("[Composer][REST] ✅ per-light room=\(roomID) lights=\(capturedLightIDs.count)")
                    #endif
                }
            } else {
                // ── GROUPED FALLBACK ──
                // No individual light IDs resolved — use grouped_light
                let capturedGLID = runtime.groupedLightID
                let capturedBri = firstBri
                let capturedXY = firstXY

                await studioRestSender.enqueue {
                    guard capturedGen == latestGen else { return }
                    try? await capturedAPI.setGroupedLightEffect(
                        id: capturedGLID, on: true,
                        brightness: capturedBri,
                        xy: (capturedXY.x, capturedXY.y),
                        mirek: nil,
                        duration: 200
                    )
                    #if DEBUG
                    print("[Composer][REST] ✅ grouped room=\(roomID) bri=\(String(format: "%.1f", capturedBri))")
                    #endif
                }
            }

            // Track what we enqueued (for delta skip)
            runtime.lastSentX = firstXY.x
            runtime.lastSentY = firstXY.y
            runtime.lastSentBri = firstBri
            runtime.lastSentAt = now
            runtime.sendCount += 1
            runtime.nextDueAt = now + 0.12
            compositionRuntimes[roomID] = runtime

            recordCompositionTelemetry(
                roomID: roomID,
                roomName: runtime.roomName,
                dueAt: now,
                sentAt: now
            )

            try? await Task.sleep(for: tickInterval)
        }
    }

    // Simplified cadence functions — mailbox handles actual rate limiting
    private func minimumComposerRESTInterval(roomCount: Int, tier: CompositionTier) -> Double {
        return 0.12 * Double(max(1, roomCount))
    }

    private func minimumComposerBurstFloor(roomCount: Int, tier: CompositionTier) -> Double {
        return 0.12 * Double(max(1, roomCount))
    }

    private func preferredComposerIdleInterval(roomCount: Int, tier: CompositionTier) -> Double {
        return 0.12 * Double(max(1, roomCount))
    }

    private func lowPowerIdleInterval(roomCount: Int, tier: CompositionTier) -> Double {
        return 0.25 * Double(max(1, roomCount))
    }

    private func recordCompositionTelemetry(roomID: String, roomName: String, dueAt: CFAbsoluteTime, sentAt: CFAbsoluteTime) {
        let lagMs = max(0, (sentAt - dueAt) * 1000)
        var metric = compositionTelemetryByRoom[roomID] ?? CompositionTelemetry(windowStart: sentAt)
        metric.sends += 1
        metric.lagSumMs += lagMs
        metric.maxLagMs = max(metric.maxLagMs, lagMs)

        let elapsed = max(0.001, sentAt - metric.windowStart)
        let cadenceSeconds = elapsed / Double(max(1, metric.sends))
        let lastUIUpdate = cadenceLastUIUpdateByRoom[roomID] ?? 0
        if sentAt - lastUIUpdate >= 1.5 {
            activeRESTCadenceByRoom[roomID] = cadenceSeconds
            activeRESTCadence = cadenceSeconds
            cadenceLastUIUpdateByRoom[roomID] = sentAt
        }

        if elapsed >= 5.0 {
            #if DEBUG
            let hz = Double(metric.sends) / elapsed
            let avgLag = metric.lagSumMs / Double(max(1, metric.sends))
            print(
                "[Composer][Telemetry] room='\(roomName)' id=\(roomID) hz=\(String(format: "%.2f", hz)) avgLagMs=\(String(format: "%.1f", avgLag)) maxLagMs=\(String(format: "%.1f", metric.maxLagMs))"
            )
            #endif
            metric = CompositionTelemetry(windowStart: sentAt)
        }
        compositionTelemetryByRoom[roomID] = metric
    }

    private func nextCompositionRoomPriority(now: CFAbsoluteTime) -> String? {
        var selectedRoomID: String?
        var selectedScore: Double = -.greatestFiniteMagnitude

        for roomID in compositionOrder {
            guard let runtime = compositionRuntimes[roomID] else { continue }
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
                selectedRoomID = roomID
            }
        }

        return selectedRoomID
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

    /// Resolve individual light IDs for a room/zone — used for per-light REST Composer mode.
    private func resolveCompositionLightIDs(for room: RoomDisplayItem, api: HueAPIClient) async -> [String] {
        let refs = room.childResourceRefs
        guard !refs.isEmpty else { return [] }

        // Zones reference lights directly — zero API calls
        if CompositionLightResolver.hasDirectLightReferences(childResourceRefs: refs) {
            return CompositionLightResolver.resolveLightIDs(
                childResourceRefs: refs,
                lights: []
            )
        }

        // Rooms reference devices — resolve via light.owner.rid
        guard let allLights = try? await api.fetchLights() else { return [] }
        return CompositionLightResolver.resolveLightIDs(
            childResourceRefs: refs,
            lights: allLights
        )
    }

    /// Resolve lightID → physical (x, z) position from an entertainment config.
    ///
    /// Entertainment channel members reference **entertainment** services (not light services).
    /// This function bridges the gap:
    ///   1. Fetch `/clip/v2/resource/entertainment` → entertainment service → device owner
    ///   2. Fetch lights → light → device owner
    ///   3. Match via shared device ID: entService → device → light
    ///   4. Return lightID → channel position
    private func resolveEntertainmentLightPositions(
        config: EntertainmentConfig,
        api: HueAPIClient
    ) async -> [String: (x: Double, z: Double)] {
        guard let (ip, token) = try? api.credentials() else { return [:] }

        // Fetch entertainment services and lights in parallel
        async let entServicesData = api.get(
            path: "/clip/v2/resource/entertainment",
            ip: ip, token: token
        )
        async let lightsFetch = api.fetchLights()

        guard let entData = try? await entServicesData,
              let lights = try? await lightsFetch else { return [:] }

        // Build entServiceID → deviceID from entertainment services
        var entServiceToDevice: [String: String] = [:]
        if let json = try? JSONSerialization.jsonObject(with: entData) as? [String: Any],
           let items = json["data"] as? [[String: Any]] {
            for item in items {
                guard let entID = item["id"] as? String,
                      let owner = item["owner"] as? [String: Any],
                      let deviceID = owner["rid"] as? String else { continue }
                entServiceToDevice[entID] = deviceID
            }
        }

        // Build deviceID → lightID from lights
        var deviceToLightID: [String: String] = [:]
        for light in lights {
            if let deviceID = light.owner?.rid {
                deviceToLightID[deviceID] = light.id
            }
        }

        // Map each channel's entertainment service members to light IDs with positions
        var result: [String: (x: Double, z: Double)] = [:]
        for channel in config.channels {
            for entServiceID in channel.lightServiceIDs {
                if let deviceID = entServiceToDevice[entServiceID],
                   let lightID = deviceToLightID[deviceID] {
                    result[lightID] = (x: channel.position.x, z: channel.position.z)
                }
            }
        }

        debugLog("[Composer] 🗺️ Resolved \(result.count) light positions from entertainment config")
        return result
    }

    /// Full local teardown for "Forget All Bridges". Clearing only the
    /// Keychain left the in-memory clients (with tokens) fully functional
    /// until the app was relaunched — the UI kept controlling lights after
    /// a forget-all. Also clears the room/zone snapshots so a later re-pair
    /// cannot resurrect stale bridge ids through the SwiftData preload.
    func forgetAllBridges() async {
        await stopStudioMode()
        stopSSE()
        compositionSchedulerTask?.cancel()
        compositionSchedulerTask = nil
        compositionRuntimes.removeAll()
        widgetWriteTask?.cancel()
        clients.removeAll()
        commandGates.removeAll()
        roomsByBridge.removeAll()
        zonesByBridge.removeAll()
        connectionStatus.removeAll()
        allRooms = []
        allZones = []
        globalScenes = []
        hasLoadedScenesOnce = false
        log.info("Forget-all: cleared clients, snapshots, and sessions")
    }

    func stopStudioMode() async {
        debugLog("[Handoff] Studio stop requested")
        // Cancel the running loop task (strobe, etc.)
        activeStudioTask?.cancel()
        activeStudioTask = nil
        studioGeneration += 1
        debugLog("[Handoff] Clearing studio REST sender mailbox")
        await studioRestSender.clear()
        // Small barrier so bridge transition buffers drain before a new startup sequence.
        try? await Task.sleep(for: .milliseconds(150))
        debugLog("[Handoff] REST mailbox cleared + settle delay complete")
        activeParamBox = nil
        debugLog("[Studio] ⏹ stopStudioMode() canceled active engine loop")

        // Stop all entertainment sessions (all bridges)
        for (bid, entClient) in studioEntClients {
            await entClient.stopSession()
            _ = bid
        }
        studioEntClients.removeAll()
        compositionEntTasks.values.forEach { $0.cancel() }
        compositionEntTasks.removeAll()
        compositionEntRoomByBridge.removeAll()
        compositionEntParamBoxes.removeAll()
        entertainmentConfigsByBridge.removeAll()
        entertainmentConfigsFetchedBridges.removeAll()

        // Also notify any mic engines
        NotificationCenter.default.post(name: .studioStopAll, object: nil)
        activeEffectEntries.removeAll()
        debugLog("[Handoff] Studio teardown complete")
    }

    /// Room-scoped teardown for ONE app-driven Studio effect (strobe, party,
    /// …). App-driven effects are single-slot — `StudioViewModel.apply` stops
    /// any other room's app-driven effect before starting, so the active loop
    /// always belongs to the stopping room. The global `stopStudioMode()`
    /// (kept verbatim for forgetAllBridges) additionally cancels EVERY room's
    /// composition tasks, drops all entertainment configs, and wipes the whole
    /// Now-Playing registry — which silently killed other rooms' running
    /// compositions when one strobe was stopped. This variant touches only
    /// the app-driven loop and its bridge's entertainment session, and only
    /// when no composition owns that session.
    func stopAppDrivenStudioEffect(roomID: String, bridgeID: String?) async {
        debugLog("[Handoff] App-driven stop requested for roomID=\(roomID)")
        activeStudioTask?.cancel()
        activeStudioTask = nil
        studioGeneration += 1
        await studioRestSender.clear()
        // Small barrier so bridge transition buffers drain before a new owner starts.
        try? await Task.sleep(for: .milliseconds(150))
        activeParamBox = nil
        // The loop may hold a DTLS session on its room's bridge. Stop it ONLY
        // if no composition owns that bridge's session — an app-driven effect
        // that fell back to REST can coexist with a composition streaming on
        // the same bridge, and that stream must survive this stop.
        if let bid = bridgeID,
           compositionEntRoomByBridge[bid] == nil,
           let entClient = studioEntClients[bid] {
            await entClient.stopSession()
            studioEntClients.removeValue(forKey: bid)
        }
        debugLog("[Handoff] App-driven teardown complete for roomID=\(roomID)")
    }

    // MARK: - Entertainment Setup Helpers

    /// Try to open an entertainment DTLS session for the given room.
    /// Returns the client if successful, nil if no entertainment config or connection failed.
    private func tryStartEntertainment(room: RoomDisplayItem, configID: String? = nil) async -> HueEntertainmentClient? {
        guard let bridgeID = room.bridgeID,
              let api = hueClient(for: bridgeID),
              let clientKey = KeychainManager.shared.loadClientKey(for: bridgeID),
              let config = await findEntertainmentConfig(bridgeID: bridgeID, preferredConfigID: configID) else {
            return nil
        }

        do {
            let (ip, token) = try api.credentials()
            let entClient = HueEntertainmentClient(
                bridgeIP: ip,
                username: token,
                clientKeyHex: clientKey,
                restClient: api
            )
            try await entClient.startSession(configID: config.id)
            let bid = room.bridgeID ?? ""
            studioEntClients[bid] = entClient
            return entClient
        } catch {
            debugLog("[Studio] Entertainment start failed: \(error.localizedDescription) — falling back to REST")
            return nil
        }
    }

    /// Find an entertainment config on the given bridge.
    private func findEntertainmentConfig(bridgeID: String?, preferredConfigID: String? = nil) async -> EntertainmentConfig? {
        guard let bid = bridgeID, let api = hueClient(for: bid) else { return nil }
        let manager = EntertainmentConfigManager()
        guard let configs = try? await manager.fetchConfigs(client: api) else { return nil }
        if let preferredConfigID,
           let matched = configs.first(where: { $0.id == preferredConfigID }) {
            return matched
        }
        return configs.first
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

            await studioRestSender.enqueue {
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
            await studioRestSender.enqueue {
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
            await studioRestSender.enqueue {
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

            await studioRestSender.enqueue {
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

            await studioRestSender.enqueue {
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
                            speed:         scene.speed ?? 0.5
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
                speed:         scene.speed
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

extension UnifiedOrchestrator {
    /// Deactivate any stuck entertainment sessions on all bridges.
    /// Entertainment sessions lock the bridge and throttle REST calls.
    /// Called on every loadAll() to ensure clean state.
    func deactivateStuckEntertainmentSessions() async {
        for (bridgeID, client) in clients {
            do {
                let (ip, token) = try client.credentials()
                let data = try await client.get(
                    path: "/clip/v2/resource/entertainment_configuration",
                    ip: ip, token: token
                )
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let items = json["data"] as? [[String: Any]] else { continue }

                for config in items {
                    guard let id = config["id"] as? String,
                          let status = config["status"] as? String,
                          status == "active" else { continue }

                    // M-06: never stop the app's OWN active session — loadAll
                    // runs on every launch/foreground/state-refresh, and this
                    // cleanup used to kill a running Studio/Composer/Sync show
                    // mid-stream (lights froze; the loop kept sending into a
                    // dead session).
                    if HueEntertainmentClient.isAppOwnedSession(configID: id) {
                        log.info("Entertainment session \(id) is app-owned and active — skipping cleanup")
                        continue
                    }

                    // This session is stuck active — deactivate it
                    log.warning("Found stuck entertainment session \(id) on bridge \(bridgeID) — deactivating")
                    let body: [String: Any] = ["action": "stop"]
                    _ = try await client.put(
                        path: "/clip/v2/resource/entertainment_configuration/\(id)",
                        body: body, ip: ip, token: token
                    )
                    log.info("Deactivated stuck entertainment session \(id)")
                }
            } catch {
                log.warning("Entertainment cleanup failed on \(bridgeID): \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - All Day Scenes (Solar Curve)

/// Lightweight solar curve for "All Day Scenes".
/// - Computes sunrise/sunset from a one-time location anchor.
/// - Produces target brightness (% 1–100) + CCT (mirek) for grouped_light.
/// - Intentionally low-fidelity: it’s stable, predictable, and cheap to compute.
private enum AllDayCurve {
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

            // Convert UT hours to local Date
            let seconds = UT * 3600
            let utcDay = Calendar(identifier: .gregorian).startOfDay(for: date)
            let utcDate = utcDay.addingTimeInterval(seconds)

            // Shift to timezone (date is already in tz; simplest is to rebuild using tz offset)
            let offset = TimeInterval(tz.secondsFromGMT(for: utcDate))
            return utcDate.addingTimeInterval(offset)
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

/// DEBUG-only console diagnostics (house convention — prints are #if DEBUG,
/// see StartupTimeline). Release builds compile the call away, keeping room
/// names and bridge detail out of the release console.
fileprivate func debugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print(message())
    #endif
}
