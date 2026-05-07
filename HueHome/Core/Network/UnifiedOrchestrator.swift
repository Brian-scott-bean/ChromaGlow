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
/// DashboardView (menu) and EffectsViewModel (card sync) share the same state.
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
        let groupedIDs = allRooms.compactMap(\.groupedLightID)

        for glID in groupedIDs {
            await allDayRestSender.enqueue { [weak self] in
                guard let self else { return }
                guard self.allDayGeneration == generation else { return }
                guard let api = self.primaryAPIClient else { return }
                // grouped_light supports on/dimming/ct/color; we do CT + brightness here.
                try? await api.setGroupedLightEffect(
                    id: glID,
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

    // ── Zones (Stage 2B) ──────────────────────────────────────

    /// All zones across every active bridge, sorted alphabetically.
    /// Populated by loadAll(); updated via rebuildAllZones().
    var allZones: [RoomDisplayItem] = []

    // ── Active Effects (Now Playing) ─────────────────────────────────────────
    // Each room/zone can have an independently applied effect.
    // DashboardView reads this to build the Now Playing bar and per-room stop menu.
    // EffectsViewModel writes to it via add/remove helpers below.

    /// All rooms that currently have an effect applied.
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

    // MARK: - Internal

    /// Active bridge clients.  keyed by BridgeRecord.id
    /// @ObservationIgnored: views read allRooms, never clients directly.
    @ObservationIgnored
    private var clients: [String: BridgeAPIClient] = [:]

    /// Rooms per bridge — used for merge.  keyed by BridgeRecord.id
    private var roomsByBridge: [String: [RoomDisplayItem]] = [:]

    /// Zones per bridge — parallel to roomsByBridge.
    private var zonesByBridge: [String: [RoomDisplayItem]] = [:]

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

    /// Continuation for the orchestrator light-event bus.
    /// RoomDetailViewModel subscribes here instead of opening its own SSE connection.
    /// @ObservationIgnored: infrastructure — views never read this directly.
    @ObservationIgnored
    private var lightEventContinuation: AsyncStream<[SSEResourceUpdate]>.Continuation?

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
            delegate: HueCertTrustDelegate(),
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
            clients[bridge.id] = client
            connectionStatus[bridge.id] = .connecting
            // Write credentials to App Group so Siri Intents and widgets can reach them
            // without going through the main app process.
            WidgetDataStore.shared.write(ip: creds.ip, token: creds.token)
        }

        // Mark disabled bridges
        for bridge in bridges where !bridge.isActive {
            connectionStatus[bridge.id] = .disabled
        }
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
        clients[record.id] = client
        connectionStatus[record.id] = .connecting
        log.info("Added bridge \(record.id) (\(record.name)) to orchestrator")
    }

    /// Remove a bridge — cancels SSE, clears rooms, wipes credentials.
    func removeBridge(id: String) {
        sseTasks[id]?.cancel()
        sseTasks.removeValue(forKey: id)
        clients.removeValue(forKey: id)
        roomsByBridge.removeValue(forKey: id)
        connectionStatus.removeValue(forKey: id)
        keychain.deleteCredentials(for: id)
        rebuildAllRooms()
        log.info("Removed bridge \(id)")
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
        guard !items.isEmpty else { return }
        allRooms = items
        // CRITICAL: also populate roomsByBridge so updateRoom() and applySSEEvent()
        // can find rooms during the startup window before loadAll() completes.
        // Without this, toggles and SSE events silently do nothing because both
        // functions iterate/lookup roomsByBridge which would otherwise be empty.
        var byBridge: [String: [RoomDisplayItem]] = [:]
        for item in items {
            if let bid = item.bridgeID {
                byBridge[bid, default: []].append(item)
            }
        }
        roomsByBridge = byBridge
        log.info("Preloaded \(items.count) rooms from SwiftData cache (\(byBridge.keys.count) bridge(s))")
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

        // ── Clean up stuck entertainment sessions ──────────────────
        // Entertainment sessions lock the bridge and heavily throttle REST API.
        // If a previous app session crashed without calling stopSession(), the
        // bridge stays in entertainment mode. Deactivate ALL active sessions.
        await deactivateStuckEntertainmentSessions()

        // Return type: (bridgeID, rooms?, zones?, roomLightMap, zoneLightMap)
        // nil rooms/zones = fetch failed; keep existing data (stale-while-revalidate).
        await withTaskGroup(
            of: (String, [RoomDisplayItem]?, [RoomDisplayItem]?, [String: String], [String: String]).self
        ) { group in
            for (bridgeID, client) in clients {
                group.addTask { [client, bridgeID] in
                    do {
                        // 4 concurrent requests per bridge — eliminates N+1 pattern.
                        async let roomsFetch   = client.fetchRooms()
                        async let zonesFetch   = client.fetchZones()
                        async let lightsFetch  = client.fetchLights()
                        async let glFetch      = client.fetchGroupedLights()

                        let (rooms, zones, lights, groupedLights) =
                            try await (roomsFetch, zonesFetch, lightsFetch, glFetch)

                        let glByID = Dictionary(uniqueKeysWithValues:
                            groupedLights.map { ($0.id, $0) }
                        )

                        // ── Build room items ───────────────────────────────────────────
                        var roomItems: [RoomDisplayItem] = []
                        var roomLightMap: [String: String] = [:]  // lightID → roomID
                        for room in rooms {
                            var isOn = false
                            var brightness = 100.0
                            if let glID = room.groupedLightID, let gl = glByID[glID] {
                                isOn = gl.on.on
                                brightness = max(1, gl.dimming?.brightness ?? 100)
                            }
                            let roomLights = lights.filter { light in
                                room.children.contains { ref in
                                    ref.rid == light.id || ref.rid == (light.owner?.rid ?? "")
                                }
                            }
                            var dominantColorXY: (x: Double, y: Double)? = nil
                            var dominantMirek: Int? = nil
                            if isOn {
                                let onLights = roomLights.filter { $0.on.on }
                                if let best = onLights.filter({ $0.color != nil })
                                    .max(by: { ($0.dimming?.brightness ?? 0) < ($1.dimming?.brightness ?? 0) }) {
                                    dominantColorXY = (best.color!.xy.x, best.color!.xy.y)
                                } else if let best = onLights.filter({ $0.color_temperature?.mirek != nil })
                                    .max(by: { ($0.dimming?.brightness ?? 0) < ($1.dimming?.brightness ?? 0) }),
                                    let mirek = best.color_temperature?.mirek {
                                    dominantMirek = mirek
                                }
                            }
                            for light in roomLights { roomLightMap[light.id] = room.id }
                            roomItems.append(RoomDisplayItem(
                                id:                room.id,
                                name:              room.metadata.name,
                                archetype:         room.metadata.archetype,
                                isOn:              isOn,
                                brightness:        brightness,
                                groupedLightID:    room.groupedLightID,
                                lightCount:        roomLights.count,
                                bridgeID:          bridgeID,
                                childResourceRefs: room.children.map { ($0.rid, $0.rtype) },
                                dominantColorX:    dominantColorXY?.x,
                                dominantColorY:    dominantColorXY?.y,
                                dominantMirek:     dominantMirek
                            ))
                        }

                        // ── Build zone items ───────────────────────────────────────────
                        // Zone children are direct light refs (rtype:"light") —
                        // no device-owner fallback needed.
                        var zoneItems: [RoomDisplayItem] = []
                        var zoneLightMap: [String: String] = [:]  // lightID → zoneID
                        for zone in zones {
                            var isOn = false
                            var brightness = 100.0
                            if let glID = zone.groupedLightID, let gl = glByID[glID] {
                                isOn = gl.on.on
                                brightness = max(1, gl.dimming?.brightness ?? 100)
                            }
                            let zoneLights = lights.filter { light in
                                zone.children.contains { $0.rid == light.id }
                            }
                            var dominantColorXY: (x: Double, y: Double)? = nil
                            var dominantMirek: Int? = nil
                            if isOn {
                                let onLights = zoneLights.filter { $0.on.on }
                                if let best = onLights.filter({ $0.color != nil })
                                    .max(by: { ($0.dimming?.brightness ?? 0) < ($1.dimming?.brightness ?? 0) }) {
                                    dominantColorXY = (best.color!.xy.x, best.color!.xy.y)
                                } else if let best = onLights.filter({ $0.color_temperature?.mirek != nil })
                                    .max(by: { ($0.dimming?.brightness ?? 0) < ($1.dimming?.brightness ?? 0) }),
                                    let mirek = best.color_temperature?.mirek {
                                    dominantMirek = mirek
                                }
                            }
                            for light in zoneLights { zoneLightMap[light.id] = zone.id }
                            var item = RoomDisplayItem(
                                id:                zone.id,
                                name:              zone.metadata.name,
                                archetype:         zone.metadata.archetype,
                                isOn:              isOn,
                                brightness:        brightness,
                                groupedLightID:    zone.groupedLightID,
                                lightCount:        zoneLights.count,
                                bridgeID:          bridgeID,
                                childResourceRefs: zone.children.map { ($0.rid, $0.rtype) },
                                dominantColorX:    dominantColorXY?.x,
                                dominantColorY:    dominantColorXY?.y,
                                dominantMirek:     dominantMirek
                            )
                            item.kind = .zone
                            zoneItems.append(item)
                        }

                        // Capture counts as constants to avoid capturing mutable vars
                        // across an async boundary (Swift 6 concurrency requirement).
                        let roomCount = roomItems.count
                        let zoneCount = zoneItems.count
                        await MainActor.run {
                            self.connectionStatus[bridgeID] = .connected
                            self.log.info("Bridge \(bridgeID): \(roomCount) rooms, \(zoneCount) zones")
                        }
                        return (bridgeID, roomItems, zoneItems, roomLightMap, zoneLightMap)
                    } catch {
                        await MainActor.run {
                            self.connectionStatus[bridgeID] = .error(error.localizedDescription)
                            self.log.error("Bridge \(bridgeID) load failed: \(error.localizedDescription)")
                        }
                        return (bridgeID, nil, nil, [:], [:])  // keep existing data
                    }
                }
            }

            for await (bridgeID, rooms, zones, roomLightMap, zoneLightMap) in group {
                if let rooms {
                    roomsByBridge[bridgeID] = rooms
                    for (k, v) in roomLightMap { lightIDToRoomID[k] = v }
                }
                if let zones {
                    zonesByBridge[bridgeID] = zones
                    for (k, v) in zoneLightMap { lightIDToZoneID[k] = v }
                }
            }
        }

        rebuildAllRooms()
        rebuildAllZones()
        lastLoadedAt = Date()
        if let ctx = cacheContext { writeCache(to: ctx) }
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
        // Optimistic removal
        withAnimation { allRooms.removeAll { $0.id == item.id } }
        do {
            try await client.deleteRoom(id: item.id)
            showToast("\(item.name) deleted")
        } catch {
            // Rollback — put it back (append; exact position isn't critical)
            withAnimation { allRooms.append(item) }
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
        withAnimation { allZones.removeAll { $0.id == item.id } }
        do {
            try await client.deleteZone(id: item.id)
            showToast("\(item.name) deleted")
        } catch {
            withAnimation { allZones.append(item) }
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

        await withTaskGroup(of: Void.self) { group in
            for (bridgeID, roomItems) in roomsByBridge {
                guard let client = clients[bridgeID] else { continue }
                for room in roomItems {
                    guard let glID = room.groupedLightID else { continue }
                    group.addTask {
                        try? await client.setGroupedLightEffect(
                            id:         glID,
                            on:         true,
                            brightness: preset.brightness,
                            xy:         nil,
                            mirek:      preset.mirek,
                            duration:   400
                        )
                    }
                }
            }
        }
        log.info("Automation preset '\(preset.id)' applied to \(self.allRooms.count) rooms")
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

        await withTaskGroup(of: Void.self) { group in
            for (bridgeID, roomItems) in roomsByBridge {
                guard let client = clients[bridgeID] else { continue }
                for room in roomItems {
                    guard let glID = room.groupedLightID else { continue }
                    let capturedClient   = client
                    let capturedGLID     = glID
                    let capturedStrategy = effect.strategy
                    group.addTask {
                        switch capturedStrategy {
                        case .bridgeNative(let effectName):
                            // Use grouped_light directly — more reliable than fetching per-light IDs.
                            // fetchLightIDsForGroup can return empty on some bridge versions,
                            // causing the old code to silently fall back to a brightness-only PUT.
                            try? await capturedClient.setGroupedLightNativeEffect(
                                id: capturedGLID, effect: effectName
                            )
                        case .oneShot, .gradual:
                            try? await capturedClient.setGroupedLightEffect(
                                id: capturedGLID, on: true, brightness: 70,
                                xy: nil, mirek: 300, duration: 400
                            )
                        case .appDriven:
                            // App-driven effects need a foreground Task loop — not possible
                            // from a notification. Apply a static warm fallback instead.
                            try? await capturedClient.setGroupedLightEffect(
                                id: capturedGLID, on: true, brightness: 70,
                                xy: nil, mirek: nil, duration: 400
                            )
                        }
                    }
                }
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
        allRooms = allRooms.map { room in
            var r = room; r.isOn = false; return r
        }
        // Sync roomsByBridge cache so applySSEEvent sees consistent state
        for bridgeID in roomsByBridge.keys {
            guard var rooms = roomsByBridge[bridgeID] else { continue }
            rooms = rooms.map { room in var r = room; r.isOn = false; return r }
            roomsByBridge[bridgeID] = rooms
        }
        log.info("All Off: optimistic update applied, firing API calls…")
        // Fire API calls concurrently across all bridges
        await withTaskGroup(of: Void.self) { group in
            for (bridgeID, roomItems) in roomsByBridge {
                guard let client = clients[bridgeID] else { continue }
                for room in roomItems {
                    guard let glID = room.groupedLightID else { continue }
                    group.addTask {
                        try? await client.setGroupedLight(id: glID, on: false)
                    }
                }
            }
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
        return AsyncStream { [weak self] continuation in
            self?.lightEventContinuation = continuation
            // onTermination is called from a Sendable context (off main actor).
            // Hop back to MainActor to safely nil the @MainActor-isolated property.
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.lightEventContinuation = nil
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
                log.info("SSE: Connecting to \(urlStr, privacy: .public)")

                let (bytes, _) = try await sseSession.bytes(for: request)
                connectionStatus[bridgeID] = .connected
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
                        // sort + filter on every brightness slider SSE event.
                        if roomsMutated { rebuildAllRooms() }
                        if zonesMutated { rebuildAllZones() }
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
                log.error("SSE error [\(bridgeID)]: \(error.localizedDescription, privacy: .public)")
            }

            log.info("SSE: Reconnecting \(bridgeID) in \(retryDelay / 1_000_000_000)s")
            try? await Task.sleep(nanoseconds: retryDelay)
            retryDelay = min(retryDelay * 2, maxDelay)
        }
    }

    /// Returns which of rooms/zones were mutated so callers can skip unnecessary rebuilds.
    @discardableResult
    func applySSEEvent(_ event: SSEEvent, bridgeID: String) -> (rooms: Bool, zones: Bool) {
        var roomsMutated = false
        var zonesMutated = false
        for update in event.data {
            switch update.type {

            // ── grouped_light ──────────────────────────────────────────────────
            case "grouped_light":
                if var rooms = roomsByBridge[bridgeID],
                   let idx = rooms.firstIndex(where: { $0.groupedLightID == update.id }) {
                    // Skip on/brightness if there is a pending optimistic action in flight.
                    // The SSE event pre-dates our PUT; applying it would cause a visible flicker.
                    let isPending = pendingActionDeadlines[update.id].map { Date() < $0 } ?? false
                    if !isPending {
                        if let on  = update.on?.on              { rooms[idx].isOn       = on  }
                        if let bri = update.dimming?.brightness { rooms[idx].brightness = bri }
                        roomsByBridge[bridgeID] = rooms
                        roomsMutated = true
                    }
                }
                if var zones = zonesByBridge[bridgeID],
                   let idx = zones.firstIndex(where: { $0.groupedLightID == update.id }) {
                    let isPending = pendingActionDeadlines[update.id].map { Date() < $0 } ?? false
                    if !isPending {
                        if let on  = update.on?.on              { zones[idx].isOn       = on  }
                        if let bri = update.dimming?.brightness { zones[idx].brightness = bri }
                        zonesByBridge[bridgeID] = zones
                        zonesMutated = true
                    }
                }

            // ── light (dominant color) ─────────────────────────────────────────
            case "light":
                let isNowOn = update.on?.on ?? true
                guard isNowOn else { continue }

                if var rooms = roomsByBridge[bridgeID],
                   let roomID = lightIDToRoomID[update.id],
                   let idx = rooms.firstIndex(where: { $0.id == roomID }) {
                    if let xy = update.color?.xy {
                        rooms[idx].dominantColorX = xy.x
                        rooms[idx].dominantColorY = xy.y
                        rooms[idx].dominantMirek  = nil
                        roomsByBridge[bridgeID]   = rooms
                        roomsMutated = true
                    } else if let mirek = update.colorTemp?.mirek {
                        rooms[idx].dominantColorX = nil
                        rooms[idx].dominantColorY = nil
                        rooms[idx].dominantMirek  = mirek
                        roomsByBridge[bridgeID]   = rooms
                        roomsMutated = true
                    }
                }
                if var zones = zonesByBridge[bridgeID],
                   let zoneID = lightIDToZoneID[update.id],
                   let idx = zones.firstIndex(where: { $0.id == zoneID }) {
                    if let xy = update.color?.xy {
                        zones[idx].dominantColorX = xy.x
                        zones[idx].dominantColorY = xy.y
                        zones[idx].dominantMirek  = nil
                        zonesByBridge[bridgeID]   = zones
                        zonesMutated = true
                    } else if let mirek = update.colorTemp?.mirek {
                        zones[idx].dominantColorX = nil
                        zones[idx].dominantColorY = nil
                        zones[idx].dominantMirek  = mirek
                        zonesByBridge[bridgeID]   = zones
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

    private func rebuildAllRooms() {
        // Buffer during navigation push to avoid layout churn mid-animation.
        guard !isNavigating else { sseRebuildPendingRooms = true; return }
        var seen = Set<String>()
        allRooms = roomsByBridge.values
            .flatMap { $0 }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            .filter { seen.insert($0.id).inserted }
        scheduleWidgetWrite()
    }

    private func rebuildAllZones() {
        guard !isNavigating else { sseRebuildPendingZones = true; return }
        var seen = Set<String>()
        allZones = zonesByBridge.values
            .flatMap { $0 }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            .filter { seen.insert($0.id).inserted }
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
                    groupedLightId: r.groupedLightID
                )
            }
            let zoneSnaps = self.allZones.map { z in
                WidgetRoomSnapshot(id: z.id, name: z.name, archetype: z.archetype,
                                   isOn: z.isOn, brightness: z.brightness,
                                   lightCount: z.lightCount, groupedLightId: z.groupedLightID)
            }
            WidgetDataStore.shared.write(rooms: roomSnaps)
            if let ip    = WidgetDataStore.shared.bridgeIP,
               let token = WidgetDataStore.shared.token {
                WatchSessionManager.shared.push(
                    rooms: roomSnaps, zones: zoneSnaps, ip: ip, token: token
                )
            }
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

    /// Entertainment client for the current studio session.
    /// Internal access so StudioViewModel can report transport mode in debug.
    var studioEntClient: HueEntertainmentClient?

    /// Latest-wins REST sender for studio mode — prevents bridge command backlog.
    private let studioRestSender = RestSender()
    /// Generation counter for studio/composer engine loops.
    /// Increment on every start/stop; async closures must match to send.
    private var studioGeneration: Int = 0
    /// Per-room composition generation counters.
    private var compositionGenerations: [String: Int] = [:]
    /// Shared composition scheduler state (room-scoped runtimes, single bridge-fair ticker).
    private var compositionRuntimes: [String: CompositionRuntime] = [:]
    private var compositionOrder: [String] = []
    private var compositionSchedulerTask: Task<Void, Never>?

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
    private var compositionEntTask: Task<Void, Never>?
    private var compositionEntRoomID: String?
    /// Weak ref — entertainment composition loop reads reaction (mic demand). Cleared when ENT task ends.
    private weak var compositionEntertainmentParamBox: CompositionParamBox?

    // MARK: Bridge-Stored Animation (v1 API)
    private let bridgeAnimationEngine = BridgeAnimationEngine()
    private let bridgeAnimationStore = BridgeAnimationStore.shared
    /// Whether the active composition is running on the bridge (v1 rules chain).
    /// Exposed for UI badge display.
    var isBridgeStored: Bool = false
    /// Entertainment config for the active composition's room.
    /// Exposed so Studio UI can show spatial mini-map and direction dial.
    var activeEntertainmentConfig: EntertainmentConfig? = nil

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
    nonisolated(unsafe) private var activeParamBox: StudioParamBox?

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
        if let entClient = studioEntClient {
            await entClient.stopSession()
            studioEntClient = nil
        }

        guard let api = hueClient(for: room.bridgeID),
              let groupedLightID = room.groupedLightID else { return }

        // Create live param box (engine loop reads from this; ViewModel updates it)
        let paramBox = StudioParamBox(values: params, colors: colors)
        activeParamBox = paramBox

        switch key {
        case "mic":
            let sensitivity = params["sensitivity"] ?? 70
            let brightness  = params["brightness"]  ?? 80
            NotificationCenter.default.post(
                name: .studioStartMicSync,
                object: nil,
                userInfo: ["groupedLightID": groupedLightID, "sensitivity": sensitivity, "brightness": brightness]
            )

        case "gaming":
            // Gaming uses mic-reactive transient detection — delegate to SyncModeEngine
            let sensitivity = params["sensitivity"] ?? 70
            let brightness  = params["brightness"]  ?? 80
            NotificationCenter.default.post(
                name: .studioStartMicSync,
                object: nil,
                userInfo: ["groupedLightID": groupedLightID, "sensitivity": sensitivity, "brightness": brightness, "engine": "gaming"]
            )

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
        return compositionEntertainmentParamBox?.reaction.requiresMic == true
    }

    private func refreshCompositionMicDemand() async {
        await CompositionMicCapture.shared.syncDemand(anyCompositionNeedsMic())
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
                await CompositionMicCapture.shared.syncDemand(true)
            }
        } else if paramBox.reaction.requiresMic {
            async let gamutResolved = resolveCompositionGamut(for: room, api: api)
            async let micHeadStart: Void = CompositionMicCapture.shared.syncDemand(true)
            await micHeadStart
            compositionGamut = await gamutResolved
        } else {
            compositionGamut = await resolveCompositionGamut(for: room, api: api)
        }
        print(
            "[Composer] ▶ Start composition room='\(room.name)' id=\(roomID) gen=\(nextGeneration) groupedLightID=\(groupedLightID) preferEntertainment=\(preferEntertainment)"
        )

        // ── Fetch entertainment config BEFORE transport decision ──
        // Both REST and DTLS paths benefit from spatial positions.
        let entConfig = await findEntertainmentConfig(bridgeID: room.bridgeID)
        await MainActor.run { activeEntertainmentConfig = entConfig }

        // Resolve individual light IDs early — needed for REST spatial positions
        // AND for per-light REST mode later.
        let compositionLightIDs = await resolveCompositionLightIDs(for: room, api: api)
        print("[Composer] 🔍 Resolved \(compositionLightIDs.count) individual lights for per-light REST")

        if let entConfig {
            // Auto-detect principal angle when user hasn't set one
            if paramBox.motion.motionAngle == 0 {
                paramBox.motion.motionAngle = CompositionEngine.principalAngle(channels: entConfig.channels)
            }
            // Pre-compute spatial positions for REST path (lightID order)
            let restPositions = CompositionEngine.computeSpatialPositions(
                config: entConfig,
                orderedLightIDs: compositionLightIDs,
                motionAngle: paramBox.motion.motionAngle
            )
            if !restPositions.isEmpty {
                paramBox.spatialPositions = restPositions
                paramBox.targetSpatialPositions = restPositions
                paramBox.spatialLerpProgress = 1.0
            }
            print("[Composer] 📐 Spatial positions computed: \(paramBox.spatialPositions.count) lights, angle=\(String(format: "%.0f", paramBox.motion.motionAngle))°")
        }

        // Prefer entertainment transport for dynamic compositions when possible.
        // Only one entertainment composition may run at a time.
        if preferEntertainment,
           compositionEntRoomID == nil,
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
                    compositionEntRoomID = roomID
                    compositionEntertainmentParamBox = paramBox
                    compositionEntTask?.cancel()
                    compositionEntTask = Task { [weak self] in
                        guard let self else { return }
                        await self.runCompositionEntertainment(
                            entClient: entClient,
                            channelIDs: channelIDs,
                            paramBox: paramBox,
                            gamut: compositionGamut
                        )
                    }
                    await refreshCompositionMicDemand()
                    print("[Composer] ⚡ Entertainment transport active for room='\(room.name)'")
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
                    print("[Composer] Cleaning up previous bridge animation for \(oldManifest.presetName)")
                    await bridgeAnimationEngine.stop(manifest: oldManifest, v1Client: v1Client)
                    bridgeAnimationStore.remove(presetID: oldManifest.presetID, roomID: roomID)
                }

                // Purge any orphaned CG_ resources from previous test runs
                await bridgeAnimationEngine.purgeAllChromaGlowResources(v1Client: v1Client)

                print("[Composer] ⚡ Attempting bridge-stored upload for '\(preset.name)'")
                let manifest = try await bridgeAnimationEngine.upload(
                    preset: preset,
                    room: room,
                    lightIDs: compositionLightIDs,
                    gamut: compositionGamut,
                    v1Client: v1Client
                )
                bridgeAnimationStore.save(manifest)
                isBridgeStored = true
                print("[Composer] ⚡ Bridge-stored animation active! \(manifest.stepCount) steps, \(manifest.intervalSeconds)s/step")
                print("[Composer] ⚡ Close the app — lights will keep going!")

                // ── Immediate prime frame ──
                // The first bridge rule won't fire until the schedule ticks (up to cycleTotalSeconds away).
                // Send step-0 of the composition now so the room turns on instantly after the card tap.
                let paramBox = CompositionParamBox(preset: preset)
                if let firstFrame = CompositionEngine.render(
                    time: 0,
                    channelIDs: [0],
                    params: paramBox,
                    audioLevel: 0
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
                        print("[Composer][BridgePrime] ✅ room='\(room.name)' bri=\(String(format: "%.1f", primeBri))")
                    } catch {
                        print("[Composer][BridgePrime] ⚠ Prime frame failed (bridge animation still active): \(error.localizedDescription)")
                    }
                }
                return  // Don't start app-driven scheduler
            } catch {
                print("[Composer] ⚠ Bridge-stored upload failed, falling back to app-driven: \(error.localizedDescription)")
                isBridgeStored = false
                // Fall through to REST/Entertainment path
            }
        } else {
            isBridgeStored = false
        }

        compositionRuntimes[roomID] = CompositionRuntime(
            roomID: roomID,
            roomName: room.name,
            api: api,
            groupedLightID: groupedLightID,
            lightIDs: compositionLightIDs,
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
        let primeAudio = CompositionMicCapture.reactionAudioLevel(for: paramBox.reaction)
        if let firstFrame = CompositionEngine.render(
            time: 0,
            channelIDs: [0],
            params: paramBox,
            audioLevel: primeAudio
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
                print(
                    "[Composer][Prime] ✅ room='\(room.name)' id=\(roomID) gen=\(nextGeneration) bri=\(String(format: "%.1f", bri)) xy=(\(String(format: "%.4f", xy.x)),\(String(format: "%.4f", xy.y)))"
                )
            } catch {
                print("[Composer][Prime] ❌ room='\(room.name)' id=\(roomID) gen=\(nextGeneration) error=\(error)")
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
        print("[Composer] 📡 Scheduled room='\(room.name)' on global composition ticker")
    }

    /// Composition render loop via Entertainment API — per-light colors at 25fps.
    private func runCompositionEntertainment(
        entClient: HueEntertainmentClient,
        channelIDs: [UInt8],
        paramBox: CompositionParamBox,
        gamut: HueColorUtils.Gamut
    ) async {
        defer { compositionEntertainmentParamBox = nil }
        let frameInterval: UInt64 = 40_000_000  // 40ms = 25fps
        let startTime = CFAbsoluteTimeGetCurrent()

        while !Task.isCancelled {
            await refreshCompositionMicDemand()
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            let audioLevel = CompositionMicCapture.reactionAudioLevel(for: paramBox.reaction)

            // Render all channels in one frame
            let frames = CompositionEngine.render(
                time: elapsed,
                channelIDs: channelIDs,
                params: paramBox,
                audioLevel: audioLevel
            )

            // Convert to entertainment send format
            let channels = frames.map { frame in
                let xy = HueColorUtils.clampXYToGamut(x: frame.x, y: frame.y, gamut: gamut)
                return (id: frame.channelID, x: xy.x, y: xy.y, brightness: frame.brightness)
            }
            await entClient.send(channels: channels)

            try? await Task.sleep(nanoseconds: frameInterval)
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

    func stopCompositionMode(roomID: String) async {
        print("[Handoff] Composer stop requested for roomID=\(roomID)")
        compositionGenerations[roomID] = (compositionGenerations[roomID] ?? 0) + 1

        // ─── Stop bridge-stored animation if active ───
        // Search all manifests for this room and clean up
        for manifest in bridgeAnimationStore.allManifests() where manifest.roomID == roomID {
            // Create v1 client from the manifest's bridge IP + primary API token
            if let api = primaryAPIClient,
               let v1Client = try? api.makeV1Client() {
                await bridgeAnimationEngine.stop(manifest: manifest, v1Client: v1Client)
            }
            bridgeAnimationStore.remove(presetID: manifest.presetID, roomID: roomID)
        }
        isBridgeStored = false
        await MainActor.run { activeEntertainmentConfig = nil }

        print("[Handoff] Clearing studio REST sender mailbox for roomID=\(roomID)")
        await studioRestSender.clear()
        // Give Hue bridge firmware a brief settle window before any new owner starts writing.
        try? await Task.sleep(for: .milliseconds(150))
        print("[Handoff] REST mailbox cleared + settle delay complete for roomID=\(roomID)")
        if compositionEntRoomID == roomID {
            compositionEntertainmentParamBox = nil
            compositionEntTask?.cancel()
            compositionEntTask = nil
            compositionEntRoomID = nil
            if let entClient = studioEntClient {
                await entClient.stopSession()
                studioEntClient = nil
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
        print("[Handoff] Composer teardown complete for roomID=\(roomID)")
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
            let audioLevel = CompositionMicCapture.reactionAudioLevel(for: runtime.paramBox.reaction)
            let lightCount = runtime.lightIDs.count
            let usePerLight = lightCount > 0

            // Build channel IDs: one per light for per-light mode, or [0] for grouped
            let channelIDs: [UInt8] = usePerLight
                ? (0..<UInt8(min(lightCount, 20))).map { $0 }
                : [0]

            let frames = CompositionEngine.render(
                time: elapsed,
                channelIDs: channelIDs,
                params: runtime.paramBox,
                audioLevel: audioLevel
            )
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

            if usePerLight {
                // ── PER-LIGHT MODE ──
                // Each light gets its own color. Cascade/wave patterns visible.
                // Bridge handles ~10 PUTs/sec for individual lights.
                let capturedLightIDs = runtime.lightIDs
                let capturedFrames = frames

                await studioRestSender.enqueue { [weak self] in
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

                await studioRestSender.enqueue { [weak self] in
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
            // Not yet due: skip unless we're within a tiny grace window.
            if now + 0.004 < runtime.nextDueAt { continue }

            let isInteracting = runtime.paramBox.isColorPadInteracting
            let burstActive = runtime.interactionBurstUntil.map { now < $0 } ?? false
            let overdue = max(0, now - runtime.nextDueAt)
            let sinceLastSend = now - (runtime.lastSentAt ?? runtime.startTime)

            var score = 0.0
            if isInteracting { score += 1000 }
            if burstActive { score += 500 }
            if runtime.pendingSettle { score += 260 }
            score += min(220, overdue * 120)
            score += min(160, max(0, sinceLastSend - 1.4) * 45)
            // Small fairness nudge to avoid repeatedly preferring a single hot room.
            score -= min(60, Double(runtime.sendCount % 120) * 0.35)

            if score > selectedScore {
                selectedScore = score
                selectedRoomID = roomID
            }
        }

        return selectedRoomID
    }

    private func resolveCompositionGamut(for room: RoomDisplayItem, api: HueAPIClient) async -> HueColorUtils.Gamut {
        guard let allLights = try? await api.fetchLights() else { return .c }
        let refs = room.childResourceRefs

        let roomLights: [HueLight]
        if refs.contains(where: { $0.rtype == "light" }) {
            let lightIDs = Set(refs.filter { $0.rtype == "light" }.map(\.rid))
            roomLights = allLights.filter { lightIDs.contains($0.id) }
        } else {
            let deviceIDs = Set(refs.map(\.rid))
            roomLights = allLights.filter { light in
                guard let ownerRID = light.owner?.rid else { return false }
                return deviceIDs.contains(ownerRID)
            }
        }

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
        if refs.contains(where: { $0.rtype == "light" }) {
            return refs.filter { $0.rtype == "light" }.map { $0.rid }
        }

        // Rooms reference devices — resolve via light.owner.rid
        let deviceIDs = Set(refs.map { $0.rid })
        guard let allLights = try? await api.fetchLights() else { return [] }
        return allLights
            .filter { light in
                guard let ownerRID = light.owner?.rid else { return false }
                return deviceIDs.contains(ownerRID)
            }
            .map { $0.id }
    }

    func stopStudioMode() async {
        print("[Handoff] Studio stop requested")
        // Cancel the running loop task (strobe, etc.)
        activeStudioTask?.cancel()
        activeStudioTask = nil
        studioGeneration += 1
        print("[Handoff] Clearing studio REST sender mailbox")
        await studioRestSender.clear()
        // Small barrier so bridge transition buffers drain before a new startup sequence.
        try? await Task.sleep(for: .milliseconds(150))
        print("[Handoff] REST mailbox cleared + settle delay complete")
        activeParamBox = nil
        print("[Studio] ⏹ stopStudioMode() canceled active engine loop")

        // Stop entertainment session
        if let entClient = studioEntClient {
            await entClient.stopSession()
            studioEntClient = nil
        }

        // Also notify any mic engines
        NotificationCenter.default.post(name: .studioStopAll, object: nil)
        activeEffectEntries.removeAll()
        print("[Handoff] Studio teardown complete")
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
            studioEntClient = entClient
            return entClient
        } catch {
            print("[Studio] Entertainment start failed: \(error.localizedDescription) — falling back to REST")
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

            // Speed 0–100 → 0.5–3.0 Hz (WCAG safe: never exceeds 3 flashes/sec)
            let hz = 0.5 + (speed / 100.0) * 2.5
            let period = 1.0 / hz
            let onDuration = period * dutyCycle
            let offDuration = period * (1.0 - dutyCycle)

            // Flash color — extract CIE xy from Color or default to white (D65)
            let xy = extractXY(from: paramBox.colors["flash_color"]) ?? (x: 0.3127, y: 0.3290)

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

            // Speed 0–100 → 0.5–3.0 Hz
            let hz = 0.5 + (speed / 100.0) * 2.5
            let period = 1.0 / hz
            let fadeFrames = max(1, Int(smoothness * period / 0.02))
            let holdFrames = max(1, Int((1.0 - smoothness) * period / 0.02))

            let color = palette[colorIndex % palette.count]
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

            let color = palette[colorIndex % palette.count]
            colorIndex += 1

            await studioRestSender.enqueue {
                try? await api.setGroupedLightEffect(
                    id: groupedLightID, on: true,
                    brightness: bri, xy: (color.x, color.y), mirek: nil,
                    duration: durationMs
                )
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

            // Lightning strike — random chance based on frequency
            let strikeChance = 0.3 + frequency * 0.6  // 30%–90%
            guard Double.random(in: 0...1) < strikeChance else { continue }

            // Lightning flash: 2-5 rapid bright frames (white)
            let flashFrames = Int.random(in: 2...5)
            for _ in 0..<flashFrames {
                guard !Task.isCancelled else { return }
                // White flash
                await entClient.sendUniform(channelIDs: channelIDs, x: 0.3127, y: 0.3290, brightness: flashIntensity)
                try? await Task.sleep(nanoseconds: frameInterval)
            }

            // Quick afterglow (1-2 frames at half intensity)
            let afterglow = Int.random(in: 1...2)
            for _ in 0..<afterglow {
                guard !Task.isCancelled else { return }
                await entClient.sendUniform(channelIDs: channelIDs, x: 0.3127, y: 0.3290, brightness: flashIntensity * 0.4)
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

            // Ambient dim
            await studioRestSender.enqueue {
                try? await api.setGroupedLightEffect(
                    id: groupedLightID, on: true,
                    brightness: minBri, xy: nil, mirek: nil,
                    duration: 400
                )
            }

            // Wait for random gap
            let gap = UInt64((2.0 - frequency * 1.5) * 1_000_000_000)
            do { try await Task.sleep(nanoseconds: max(500_000_000, gap)) } catch { break }

            // Random lightning
            let strikeChance = 0.3 + frequency * 0.5
            guard Double.random(in: 0...1) < strikeChance else { continue }

            await studioRestSender.enqueue {
                try? await api.setGroupedLightEffect(
                    id: groupedLightID, on: true,
                    brightness: flashIntensity, xy: nil, mirek: nil,
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

            phase += dt * (2.0 * .pi) / period
            let sine = sin(phase)  // -1 to +1

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
        guard let id = bridgeID else { return nil }
        return clients[id]
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
            return
        }

        guard !clients.isEmpty else { return }

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
        globalScenes = result
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
        globalScenes.removeAll { $0.id == scene.id }
        guard let client = clients[scene.bridgeID] else { return }
        Task { try? await client.deleteScene(id: scene.bridgeSceneID) }
    }

    /// Optimistically renames the scene in globalScenes, then persists to the bridge.
    func renameGlobalScene(_ scene: GlobalSceneItem, to newName: String) async {
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
        }
        guard let client = clients[scene.bridgeID] else { return }
        try? await client.renameScene(id: scene.bridgeSceneID, name: newName)
    }

    /// Creates a new scene by snapshotting the current light states in the given room.
    /// Fetches all lights for the bridge, filters to this room's lights, and POSTs a scene.
    func createSceneFromRoom(name: String, room: RoomDisplayItem) async throws {
        guard let bridgeID = room.bridgeID,
              let client   = clients[bridgeID] else {
            throw HueAPIError.missingCredentials
        }
        // Fetch all lights from this bridge
        let allLights = try await client.fetchLights()

        // Filter to lights belonging to this room using its child resource refs
        let childIDs  = Set(room.childResourceRefs.map { $0.rid })
        let usesDirect = room.childResourceRefs.first?.rtype == "light"
        let roomLights: [HueLight]
        if usesDirect {
            // Zones and newer-firmware rooms reference lights directly
            roomLights = allLights.filter { childIDs.contains($0.id) }
        } else {
            // Older-firmware rooms reference devices — match via light.owner.rid
            roomLights = allLights.filter { light in
                guard let ownerRID = light.owner?.rid else { return false }
                return childIDs.contains(ownerRID)
            }
        }

        let req = CreateSceneRequest.fromHueLights(
            name:       name,
            groupID:    room.id,
            groupRtype: room.kind == .zone ? "zone" : "room",
            lights:     roomLights
        )
        try await client.createScene(req)
        // Refresh the scene list so the new scene appears immediately
        await loadAllScenes()
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
