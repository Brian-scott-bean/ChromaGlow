// UnifiedOrchestrator.swift
// HueHome Pro — Stage 2A Multi-Bridge
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

// MARK: - UnifiedOrchestrator

@Observable
@MainActor
final class UnifiedOrchestrator {

    // MARK: - Public State

    /// All rooms across every active bridge, sorted alphabetically.
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

    // MARK: - Internal

    /// Active bridge clients.  keyed by BridgeRecord.id
    /// @ObservationIgnored: views read allRooms, never clients directly.
    @ObservationIgnored
    private var clients: [String: BridgeAPIClient] = [:]

    /// Rooms per bridge — used for merge.  keyed by BridgeRecord.id
    /// Note: NOT @ObservationIgnored — the @Observable macro's subscript write-back
    /// behavior for @ObservationIgnored properties is subtly different across Swift
    /// toolchain versions. Views observe allRooms (the merged output), not this dict
    /// directly, so observation overhead here is negligible.
    private var roomsByBridge: [String: [RoomDisplayItem]] = [:]

    /// SSE tasks per bridge — cancelled when bridge is removed.
    /// @ObservationIgnored: purely infrastructure, no UI reads this.
    @ObservationIgnored
    private var sseTasks: [String: Task<Void, Never>] = [:]

    /// Continuation for the orchestrator light-event bus.
    /// RoomDetailViewModel subscribes here instead of opening its own SSE connection.
    /// @ObservationIgnored: infrastructure — views never read this directly.
    @ObservationIgnored
    private var lightEventContinuation: AsyncStream<[SSEResourceUpdate]>.Continuation?

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
    private let log = Logger(subsystem: "com.huehome.pro", category: "UnifiedOrchestrator")

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
            if let (ip, token) = keychain.migrateLegacyCredentials(to: legacyID) {
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
            allRooms = []
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

        // Parallel fetch using TaskGroup
        await withTaskGroup(of: (String, [RoomDisplayItem]).self) { group in
            for (bridgeID, client) in clients {
                group.addTask { [client, bridgeID] in
                    do {
                        // Parallel fetch: rooms + lights + ALL grouped_lights in 3 concurrent
                        // requests instead of 1 + N (one per room). Eliminates the N+1 pattern
                        // that caused high energy usage with large room counts.
                        async let roomsFetch   = client.fetchRooms()
                        async let lightsFetch  = client.fetchLights()
                        async let glFetch      = client.fetchGroupedLights()

                        let (rooms, lights, groupedLights) = try await (roomsFetch, lightsFetch, glFetch)

                        // Build lookup: groupedLightID → HueGroupedLight
                        let glByID = Dictionary(uniqueKeysWithValues:
                            groupedLights.map { ($0.id, $0) }
                        )

                        var items: [RoomDisplayItem] = []
                        for room in rooms {
                            var brightness = 100.0
                            var isOn = false

                            if let glID = room.groupedLightID, let gl = glByID[glID] {
                                isOn = gl.on.on
                                // Bridge reports brightness:0.0 for off grouped_lights.
                                // Clamp to 1 so we never store 0% — turning a room on
                                // from 0% brightness would make lights appear unresponsive.
                                let raw = gl.dimming?.brightness ?? 100
                                brightness = max(1, raw)
                            }

                            let lightCount = lights.filter { light in
                                room.children.contains { ref in
                                    ref.rid == light.id || ref.rid == (light.owner?.rid ?? "")
                                }
                            }.count

                            items.append(RoomDisplayItem(
                                id:                room.id,
                                name:              room.metadata.name,
                                archetype:         room.metadata.archetype,
                                isOn:              isOn,
                                brightness:        brightness,
                                groupedLightID:    room.groupedLightID,
                                lightCount:        lightCount,
                                bridgeID:          bridgeID,
                                childResourceRefs: room.children.map { ($0.rid, $0.rtype) }
                            ))
                        }
                        await MainActor.run {
                            self.connectionStatus[bridgeID] = .connected
                            self.log.info("Bridge \(bridgeID): loaded \(items.count) rooms")
                        }
                        return (bridgeID, items)
                    } catch {
                        await MainActor.run {
                            self.connectionStatus[bridgeID] = .error(error.localizedDescription)
                            self.log.error("Bridge \(bridgeID) load failed: \(error.localizedDescription)")
                        }
                        return (bridgeID, [])
                    }
                }
            }

            for await (bridgeID, rooms) in group {
                roomsByBridge[bridgeID] = rooms
            }
        }

        rebuildAllRooms()
        lastLoadedAt = Date()   // mark freshness — DashboardView reads this for debounce
        // Persist state for instant next-launch startup
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
        Task {
            do {
                try await client.setGroupedLight(id: glID, on: desiredState)
            } catch {
                // Rollback: revert to the opposite of what we tried
                updateRoom(item.id, isOn: !desiredState)
                log.error("setRoom failed for \(item.id): \(error.localizedDescription)")
                showToast("Couldn't reach bridge — \(item.name) reverted")
            }
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

        Task {
            do {
                // Single PUT: on=true + brightness together — no "flash" at old brightness
                try await client.setGroupedLightState(id: glID, on: true, brightness: clamped)
            } catch {
                updateRoom(item.id, isOn: item.isOn, brightness: item.brightness)
                log.error("Brightness failed for room \(item.id): \(error.localizedDescription)")
            }
        }
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
                        var mutated = false
                        for event in events {
                            if applySSEEvent(event, bridgeID: bridgeID) { mutated = true }
                        }
                        // Rebuild allRooms ONCE per SSE message, not once per event.
                        // Prevents burst of 3 events triggering 3 separate view re-renders.
                        if mutated { rebuildAllRooms() }
                        // Forward raw updates to RoomDetailViewModel (light-event bus).
                        // This eliminates the need for a second SSE stream per room view.
                        let rawUpdates = events.flatMap { $0.data }
                        if !rawUpdates.isEmpty {
                            lightEventContinuation?.yield(rawUpdates)
                        }
                    }
                }
                // Stream ended cleanly (bridge closed connection) — reconnect once.
                log.info("SSE: Stream ended cleanly on \(bridgeID)")

            } catch {
                guard !Task.isCancelled else { return }
                connectionStatus[bridgeID] = .error(error.localizedDescription)
                log.error("SSE error [\(bridgeID)]: \(error.localizedDescription, privacy: .public)")
            }

            // Exponential backoff before reconnect (applies to both error and clean-end)
            log.info("SSE: Reconnecting \(bridgeID) in \(retryDelay / 1_000_000_000)s")
            try? await Task.sleep(nanoseconds: retryDelay)
            retryDelay = min(retryDelay * 2, maxDelay)   // 5 → 10 → 20 → 40 → 60 → 60…
        }
    }

    /// Returns true if any room state was mutated (used to gate rebuildAllRooms).
    @discardableResult
    @discardableResult
    func applySSEEvent(_ event: SSEEvent, bridgeID: String) -> Bool {
        var mutated = false
        for update in event.data {
            guard update.type == "grouped_light" else { continue }
            guard var rooms = roomsByBridge[bridgeID] else { continue }
            if let idx = rooms.firstIndex(where: { $0.groupedLightID == update.id }) {
                if let on  = update.on?.on           { rooms[idx].isOn        = on  }
                if let bri = update.dimming?.brightness { rooms[idx].brightness = bri }
                roomsByBridge[bridgeID] = rooms
                mutated = true
            }
        }
        return mutated
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
        // Deduplicate by Hue resource ID — if the same physical bridge is registered
        // under multiple BridgeRecord entries (same IP, different UUID), each room still
        // appears only once. The first occurrence wins (sorted alphabetically overall).
        var seen = Set<String>()
        allRooms = roomsByBridge.values
            .flatMap { $0 }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            .filter { seen.insert($0.id).inserted }

        // Keep widget in sync on every state change (SSE events and loadAll).
        // Widget reads this via App Group UserDefaults; write is O(N) JSON encode.
        let snapshots = allRooms.map { r in
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
        WidgetDataStore.shared.write(rooms: snapshots)
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
        // Step 1: direct allRooms update — guaranteed @Observable notification
        allRooms = allRooms.map { room in
            guard room.id == id else { return room }
            var updated = room
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
    }

    // ──────────────────────────────────────────────
    // MARK: - Computed Helpers
    // ──────────────────────────────────────────────

    var activeBridgeCount: Int { clients.count }

    var totalDeviceCount: Int { allRooms.reduce(0) { $0 + $1.lightCount } }

    /// Returns the HueAPIClient for a specific bridge ID — used by RoomDetailViewModel
    /// to ensure the correct bridge credentials are used for per-light operations.
    func hueClient(for bridgeID: String?) -> HueAPIClient? {
        guard let id = bridgeID else { return nil }
        return clients[id]
    }

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
                            name:          scene.metadata.name,
                            roomID:        scene.group.rid,
                            bridgeID:      bridgeID,
                            isActive:      scene.status?.active == "active"
                        )
                    }
                }
            }
            for await items in group {
                result.append(contentsOf: items)
            }
        }

        // Active first, then alphabetical
        globalScenes = result.sorted {
            if $0.isActive != $1.isActive { return $0.isActive }
            return $0.name.localizedCompare($1.name) == .orderedAscending
        }

        log.info("Loaded \(self.globalScenes.count) scenes across \(self.clients.count) bridge(s)")
    }

    /// Activate a scene. Optimistic: marks it active locally, clears others
    /// in the same room, then fires the API call asynchronously.
    func activateGlobalScene(_ scene: GlobalSceneItem) {
        // Optimistic update via full-array replacement — avoids @Observable subscript bug
        var updated = globalScenes
        for i in updated.indices {
            if updated[i].roomID == scene.roomID && updated[i].bridgeID == scene.bridgeID {
                updated[i].isActive = (updated[i].id == scene.id)
            }
        }
        globalScenes = updated   // full assignment — reliably triggers @Observable

        guard let client = clients[scene.bridgeID] else { return }
        Task {
            try? await client.activateScene(id: scene.bridgeSceneID)
            log.info("Activated scene '\(scene.name)' on bridge \(scene.bridgeID)")
        }
    }
}

// MARK: - SSE Event Models

/// Shared JSON decoder for SSE message parsing.
/// Allocated once — avoids heap churn from JSONDecoder() per SSE line.
/// Safe: @MainActor serialisation means decode() is never called concurrently.
private extension UnifiedOrchestrator {
    static let sseDecoder = JSONDecoder()
}

private struct SSEEvent: Decodable {
    let type: String
    let data: [SSEResourceUpdate]
}
