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

    // ── Studio Mode — delegates to existing effect/sync engines ──────────
    // Called by StudioViewModel for .appDriven cards.

    func startStudioMode(
        key: String,
        room: RoomDisplayItem,
        params: [String: Double],
        colors: [String: Color]
    ) async {
        // Route to the appropriate engine based on the key.
        // This delegates into the same EffectsEngine infrastructure that
        // the old EffectsView used — no logic duplication.
        guard let api = hueClient(for: room.bridgeID),
              let groupedLightID = room.groupedLightID else { return }

        switch key {
        case "mic":
            // Mic/music sync — reuse existing MicSyncEngine if available
            let sensitivity = params["sensitivity"] ?? 70
            let brightness  = params["brightness"]  ?? 80
            // Mic engine is managed inside SyncModeView's engine; bridge here via notification
            NotificationCenter.default.post(
                name: .studioStartMicSync,
                object: nil,
                userInfo: ["groupedLightID": groupedLightID, "sensitivity": sensitivity, "brightness": brightness]
            )
        case "strobe":
            let speed      = params["speed"]      ?? 50
            let brightness = params["brightness"] ?? 80
            let duration   = Int(1000 / max(1, speed / 10))
            await startStrobeLoop(api: api, groupedLightID: groupedLightID,
                                  brightness: brightness, intervalMs: duration)
        default:
            // For party, thunderstorm, gaming, ambient — apply a base grouped_light state
            // and mark as running. Full engine delegation in v0.16.0.
            let brightness = params["brightness"] ?? 80
            try? await api.setGroupedLightBrightness(id: groupedLightID, brightness: brightness)
        }
    }

    func stopStudioMode() async {
        NotificationCenter.default.post(name: .studioStopAll, object: nil)
        activeEffectEntries.removeAll()
    }

    private func startStrobeLoop(
        api: HueAPIClient,
        groupedLightID: String,
        brightness: Double,
        intervalMs: Int
    ) async {
        // Simple strobe: toggle on/off at interval. Runs until stopStudioMode() fires.
        let interval = Double(max(50, intervalMs)) / 1000.0
        var on = true
        while !Task.isCancelled {
            try? await api.setGroupedLight(id: groupedLightID, on: on)
            on.toggle()
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
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
