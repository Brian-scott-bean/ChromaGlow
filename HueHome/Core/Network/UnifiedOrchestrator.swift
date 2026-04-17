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

    /// True while an initial full-load is in flight for any bridge.
    var isLoading: Bool = false

    /// Non-nil during a full-load error (transient — cleared on next successful load).
    var errorMessage: String? = nil

    /// Whether to group rooms by bridge in the UI (user toggle).
    var groupByBridge: Bool = false

    /// Demo mode — true when exploring the app without a real Bridge.
    /// All state changes work locally; no network calls are made.
    var isDemoMode: Bool = false

    // MARK: - Internal

    /// Active bridge clients.  keyed by BridgeRecord.id
    private var clients: [String: BridgeAPIClient] = [:]

    /// Rooms per bridge — used for merge.  keyed by BridgeRecord.id
    private var roomsByBridge: [String: [RoomDisplayItem]] = [:]

    /// SSE tasks per bridge — cancelled when bridge is removed.
    private var sseTasks: [String: Task<Void, Never>] = [:]

    private let keychain = KeychainManager.shared
    private let log = Logger(subsystem: "com.huehome.pro", category: "UnifiedOrchestrator")

    // MARK: - Init

    init() {}

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

        // Build/update clients for active bridges
        for bridge in bridges where bridge.isActive {
            guard let creds = try? keychain.loadCredentials(for: bridge.id) else {
                log.warning("No credentials for bridge \(bridge.id) — skipping")
                connectionStatus[bridge.id] = .error("No credentials found")
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
                    brightness:        local.lastBrightness,
                    groupedLightID:    nil,   // unknown until live fetch
                    lightCount:        local.cachedLightCount,
                    bridgeID:          local.bridgeID,
                    childResourceRefs: []
                )
            }
        if !items.isEmpty {
            allRooms = items
            log.info("Preloaded \(items.count) rooms from SwiftData cache")
        }
    }

    /// Write current live room states back to SwiftData for next-launch preload.
    /// Called after every successful loadAll(). Non-blocking — errors are silently discarded.
    func writeCache(to context: ModelContext) {
        do {
            for room in allRooms {
                let id = room.id
                let descriptor = FetchDescriptor<HueLocalRoom>(
                    predicate: #Predicate { $0.roomID == id }
                )
                if let existing = try context.fetch(descriptor).first {
                    existing.cachedName       = room.name
                    existing.lastIsOn         = room.isOn
                    existing.lastBrightness   = room.brightness
                    existing.cachedLightCount = room.lightCount
                    existing.cachedArchetype  = room.archetype
                    existing.bridgeID         = room.bridgeID
                    existing.updatedAt        = Date()
                } else {
                    let local = HueLocalRoom(roomID: id, bridgeID: room.bridgeID)
                    local.cachedName       = room.name
                    local.lastIsOn         = room.isOn
                    local.lastBrightness   = room.brightness
                    local.cachedLightCount = room.lightCount
                    local.cachedArchetype  = room.archetype
                    context.insert(local)
                }
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
        // Only show loading indicator if we have no cached data to show yet
        let hadCachedData = !allRooms.isEmpty
        if !hadCachedData { isLoading = true }
        errorMessage = nil
        defer { isLoading = false }

        // Parallel fetch using TaskGroup
        await withTaskGroup(of: (String, [RoomDisplayItem]).self) { group in
            for (bridgeID, client) in clients {
                group.addTask { [client, bridgeID] in
                    do {
                        let rooms = try await client.fetchRooms()
                        let lights = try await client.fetchLights()

                        var items: [RoomDisplayItem] = []
                        for room in rooms {
                            var brightness = 100.0
                            var isOn = false

                            if let glID = room.groupedLightID,
                               let gl = try? await client.fetchGroupedLight(id: glID) {
                                isOn       = gl.on.on
                                brightness = gl.dimming?.brightness ?? 100
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
        // Persist state for instant next-launch startup
        if let ctx = cacheContext { writeCache(to: ctx) }
    }

    // ──────────────────────────────────────────────
    // MARK: - Room Mutations

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

    func setBrightness(_ brightness: Double, for item: RoomDisplayItem) {
        // Demo mode: update local state only, no network
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
                try await client.setGroupedLightBrightness(id: glID, brightness: clamped)
                if !item.isOn {
                    try await client.setGroupedLight(id: glID, on: true)
                }
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
        await withTaskGroup(of: Void.self) { group in
            for (bridgeID, roomItems) in roomsByBridge {
                guard let client = clients[bridgeID] else { continue }
                for room in roomItems where room.isOn {
                    guard let glID = room.groupedLightID else { continue }
                    group.addTask {
                        try? await client.setGroupedLight(id: glID, on: false)
                    }
                }
            }
        }
        // Optimistic: mark all as off
        allRooms = allRooms.map { room in
            var r = room
            r.isOn = false
            return r
        }
        log.info("All Off fired across \(self.clients.count) bridge(s)")
    }

    // ──────────────────────────────────────────────
    // MARK: - SSE (one per bridge)
    // ──────────────────────────────────────────────

    /// Start SSE connections for all active clients.
    func startSSE() {
        guard !isDemoMode else { return }  // no SSE in demo mode
        for (bridgeID, client) in clients {
            guard sseTasks[bridgeID] == nil else { continue }
            sseTasks[bridgeID] = Task { [weak self, bridgeID, client] in
                await self?.runSSE(bridgeID: bridgeID, client: client)
            }
        }
    }

    func stopSSE() {
        sseTasks.values.forEach { $0.cancel() }
        sseTasks.removeAll()
    }

    private func runSSE(bridgeID: String, client: BridgeAPIClient) async {
        guard let creds = try? client.credentials() else { return }
        let urlStr = "https://\(creds.ip)/clip/v2/resource"
        guard let url = URL(string: urlStr) else { return }

        var request = URLRequest(url: url)
        request.setValue(creds.token, forHTTPHeaderField: "hue-application-key")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        // Use the same cert-trust strategy as HueAPIClient — delegate trusts Hue's self-signed cert.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest  = 0
        config.timeoutIntervalForResource = 0
        let session = URLSession(
            configuration: config,
            delegate: HueCertTrustDelegate(),   // ← real cert trust, not a dummy URLProtocol
            delegateQueue: nil
        )

        do {
            let (stream, _) = try await session.bytes(for: request)
            connectionStatus[bridgeID] = .connected

            var buffer = ""
            for try await byte in stream {
                guard !Task.isCancelled else { break }
                let char = String(bytes: [byte], encoding: .utf8) ?? ""
                buffer += char

                if buffer.hasSuffix("\n\n") || buffer.hasSuffix("\r\n\r\n") {
                    processSSEChunk(buffer, bridgeID: bridgeID)
                    buffer = ""
                }
            }
        } catch {
            if !Task.isCancelled {
                connectionStatus[bridgeID] = .error(error.localizedDescription)
                log.error("SSE error on bridge \(bridgeID): \(error.localizedDescription)")
                // Retry after 5 seconds
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await runSSE(bridgeID: bridgeID, client: client)
            }
        }
    }

    private func processSSEChunk(_ chunk: String, bridgeID: String) {
        let lines = chunk.components(separatedBy: .newlines)
        for line in lines {
            guard line.hasPrefix("data:") else { continue }
            let jsonStr = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard let data = jsonStr.data(using: .utf8) else { continue }

            if let events = try? JSONDecoder().decode([SSEEvent].self, from: data) {
                for event in events {
                    applySSEEvent(event, bridgeID: bridgeID)
                }
            }
        }
    }

    private func applySSEEvent(_ event: SSEEvent, bridgeID: String) {
        for update in event.data {
            guard update.type == "grouped_light" else { continue }
            guard var rooms = roomsByBridge[bridgeID] else { continue }
            if let idx = rooms.firstIndex(where: { $0.groupedLightID == update.id }) {
                if let on = update.on?.on        { rooms[idx].isOn       = on }
                if let bri = update.dimming?.brightness { rooms[idx].brightness = bri }
                roomsByBridge[bridgeID] = rooms
                rebuildAllRooms()
            }
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
    }

    private func updateRoom(_ id: String, isOn: Bool? = nil, brightness: Double? = nil) {
        if let i = allRooms.firstIndex(where: { $0.id == id }) {
            if let on  = isOn       { allRooms[i].isOn       = on }
            if let bri = brightness { allRooms[i].brightness = bri }
        }
        // Also update per-bridge cache
        for bridgeID in roomsByBridge.keys {
            if let i = roomsByBridge[bridgeID]?.firstIndex(where: { $0.id == id }) {
                if let on  = isOn       { roomsByBridge[bridgeID]![i].isOn       = on }
                if let bri = brightness { roomsByBridge[bridgeID]![i].brightness = bri }
            }
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
}

// MARK: - SSE Event Models

private struct SSEEvent: Decodable {
    let type: String
    let data: [SSEResourceUpdate]
}
