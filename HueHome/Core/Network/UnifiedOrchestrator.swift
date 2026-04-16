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
    /// Use bridgeID on RoomDisplayItem to attribute rooms to their bridge.
    var allRooms: [RoomDisplayItem] = []

    /// Per-bridge SSE connection status  (bridgeID → status)
    var connectionStatus: [String: BridgeConnectionStatus] = [:]

    /// True while an initial full-load is in flight for any bridge.
    var isLoading: Bool = false

    /// Non-nil during a full-load error (transient — cleared on next successful load).
    var errorMessage: String? = nil

    /// Whether to group rooms by bridge in the UI (user toggle).
    var groupByBridge: Bool = false

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
    // MARK: - Load All (Parallel)
    // ──────────────────────────────────────────────

    /// Fetch rooms from every active bridge concurrently; merge results.
    func loadAll() async {
        guard !clients.isEmpty else {
            allRooms = []
            return
        }
        isLoading = true
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
    }

    // ──────────────────────────────────────────────
    // MARK: - Room Mutations
    // ──────────────────────────────────────────────

    func toggleRoom(_ item: RoomDisplayItem) {
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

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest  = 0
        config.timeoutIntervalForResource = 0
        config.protocolClasses = [HueCertTrustProtocol.self]

        let session = URLSession(configuration: config)

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
        allRooms = roomsByBridge.values
            .flatMap { $0 }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
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

// MARK: - HueCertTrustProtocol
// Allows SSE URLSession to trust Hue Bridge self-signed cert

private final class HueCertTrustProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { false } // passthrough — delegate handles trust
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocolDidFinishLoading(self) }
    override func stopLoading() {}
}
