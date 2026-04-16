// DashboardViewModel.swift
// HueHome Pro — Story 1.2 / 1.3
//
// Fetches rooms + lights on appear, then drives room-level on/off toggles.
// All network calls are logged for hardware debugging per project protocol.

import Foundation
import OSLog
import SwiftUI
import WidgetKit

// MARK: - Room Display Model

/// A UI-ready room combining the V2 room resource with its current grouped_light state.
struct RoomDisplayItem: Identifiable, Hashable {
    let id: String           // room.id
    let name: String
    let archetype: String?   // e.g. "living_room", "bedroom" — drives SF Symbol in Story 2.1+
    var isOn: Bool
    var brightness: Double   // 1–100 (Bridge rejects 0; use on=false to turn off)
    let groupedLightID: String?
    var lightCount: Int
    /// Raw child resource refs — used by RoomDetailViewModel to match individual lights.
    /// Contains entries with rtype "light" (newer firmware) or "device" (older firmware).
    let childResourceRefs: [(rid: String, rtype: String)]

    static func == (lhs: RoomDisplayItem, rhs: RoomDisplayItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - DashboardViewModel

@Observable
@MainActor
final class DashboardViewModel {

    // MARK: State
    var rooms: [RoomDisplayItem] = []
    var isLoading: Bool = false
    var errorMessage: String? = nil
    var logLines: [String] = []

    // MARK: Dependencies
    private let api: HueAPIClient
    private let log = Logger(subsystem: "com.huehome.pro", category: "Dashboard")

    // MARK: Init
    init(api: HueAPIClient = .shared) {
        self.api = api
    }

    // ──────────────────────────────────────────────
    // MARK: - Fetch
    // ──────────────────────────────────────────────

    func loadAll() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        appendLog("📡 Fetching rooms and lights from Bridge…")

        do {
            async let roomsFetch  = api.fetchRooms()
            async let lightsFetch = api.fetchLights()
            let (fetchedRooms, fetchedLights) = try await (roomsFetch, lightsFetch)

            appendLog("✅ Rooms: \(fetchedRooms.count) | Lights: \(fetchedLights.count)")
            log.info("Dashboard: \(fetchedRooms.count) rooms, \(fetchedLights.count) lights loaded.")

            // Build a lookup of light count per room
            var lightCountMap: [String: Int] = [:]
            for room in fetchedRooms {
                let count = room.children.filter { $0.rtype == "light" }.count
                lightCountMap[room.id] = count
            }

            // Fetch grouped_light state for each room (on/off + brightness)
            var displayItems: [RoomDisplayItem] = []
            for room in fetchedRooms {
                var isOn = false
                var brightness = 100.0

                if let glID = room.groupedLightID {
                    do {
                        let gl = try await api.fetchGroupedLight(id: glID)
                        isOn       = gl.on.on
                        brightness = gl.dimming?.brightness ?? 100.0
                        appendLog("💡 '\(room.metadata.name)' → \(isOn ? "ON" : "OFF") @ \(Int(brightness))%")
                    } catch {
                        appendLog("⚠️  Could not fetch grouped_light for '\(room.metadata.name)': \(error.localizedDescription)")
                    }
                }

                displayItems.append(RoomDisplayItem(
                    id:                 room.id,
                    name:               room.metadata.name,
                    archetype:          room.metadata.archetype,
                    isOn:               isOn,
                    brightness:         brightness,
                    groupedLightID:     room.groupedLightID,
                    lightCount:         lightCountMap[room.id] ?? 0,
                    childResourceRefs:  room.children.map { ($0.rid, $0.rtype) }
                ))
            }

            rooms = displayItems.sorted { $0.name < $1.name }
            appendLog("🏠 Dashboard ready — \(rooms.count) room(s) loaded.")
            writeWidgetData()   // keep widget in sync

        } catch {
            let msg = error.localizedDescription
            appendLog("❌ Load failed: \(msg)")
            log.error("Dashboard: Load failed — \(msg, privacy: .public).")
            errorMessage = msg
        }

        isLoading = false
    }

    // ──────────────────────────────────────────────
    // MARK: - Toggle
    // ──────────────────────────────────────────────

    func toggleRoom(_ item: RoomDisplayItem) {
        guard let glID = item.groupedLightID else {
            appendLog("⚠️  '\(item.name)' has no grouped_light resource — cannot toggle.")
            return
        }

        // Optimistic UI update
        let newState = !item.isOn
        if let idx = rooms.firstIndex(where: { $0.id == item.id }) {
            rooms[idx].isOn = newState
        }

        appendLog("🔄 Toggling '\(item.name)' → \(newState ? "ON" : "OFF")")

        Task {
            do {
                try await api.setGroupedLight(id: glID, on: newState)
                appendLog("✅ '\(item.name)' toggled \(newState ? "ON" : "OFF") successfully.")
                log.info("Dashboard: '\(item.name, privacy: .public)' set to \(newState, privacy: .public).")
                self.writeWidgetData()
            } catch {
                // Rollback optimistic update
                appendLog("❌ Toggle failed for '\(item.name)': \(error.localizedDescription)")
                log.error("Dashboard: Toggle failed — \(error.localizedDescription, privacy: .public).")
                if let idx = rooms.firstIndex(where: { $0.id == item.id }) {
                    rooms[idx].isOn = !newState
                }
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Brightness
    // ──────────────────────────────────────────────

    func setBrightness(_ brightness: Double, for item: RoomDisplayItem) {
        guard let glID = item.groupedLightID else {
            appendLog("⚠️  '\(item.name)' has no grouped_light resource — cannot set brightness.")
            return
        }

        let clamped = min(100, max(1, brightness))
        let previous = item.brightness

        // Optimistic update of brightness
        if let idx = rooms.firstIndex(where: { $0.id == item.id }) {
            rooms[idx].brightness = clamped
            // Auto-on when dragging from off state
            if !rooms[idx].isOn { rooms[idx].isOn = true }
        }

        appendLog("🌓 '\(item.name)' brightness → \(Int(clamped))%")

        Task {
            do {
                // If room was off, turn on first then set brightness
                if !item.isOn {
                    try await api.setGroupedLight(id: glID, on: true)
                }
                try await api.setGroupedLightBrightness(id: glID, brightness: clamped)
                appendLog("✅ '\(item.name)' brightness set to \(Int(clamped))%.")
                log.info("Dashboard: '\(item.name, privacy: .public)' brightness \(Int(clamped), privacy: .public)%.")
                self.writeWidgetData()
            } catch {
                // Rollback
                appendLog("❌ Brightness failed for '\(item.name)': \(error.localizedDescription)")
                log.error("Dashboard: Brightness failed — \(error.localizedDescription, privacy: .public).")
                if let idx = rooms.firstIndex(where: { $0.id == item.id }) {
                    rooms[idx].brightness = previous
                    rooms[idx].isOn = item.isOn
                }
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Widget Sync
    // ──────────────────────────────────────────────

    /// Write current room state + credentials to App Group UserDefaults,
    /// then signal WidgetKit to reload its timelines.
    private func writeWidgetData() {
        let snapshots = rooms.map { r in
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

        if let ip    = try? KeychainManager.shared.loadBridgeIP(),
           let token = try? KeychainManager.shared.loadAPIToken() {
            WidgetDataStore.shared.write(ip: ip, token: token)
        }

        WidgetCenter.shared.reloadAllTimelines()
        appendLog("📱 Widget data updated (\(snapshots.count) rooms).")
    }

    // ──────────────────────────────────────────────
    // MARK: - SSE Real-Time Sync
    // ──────────────────────────────────────────────

    /// Long-running — call from a SwiftUI .task{} so it auto-cancels on view disappear.
    /// Connects to the Bridge SSE stream and patches room state on every event.
    /// Retries with exponential backoff (1s → 2s → 4s … max 30s) on disconnection.
    func runSSE() async {
        guard let creds = try? api.credentials() else {
            appendLog("⚠️ SSE: No credentials saved — skipping live sync.")
            return
        }

        var backoffNs: UInt64 = 1_000_000_000   // 1 second

        while !Task.isCancelled {
            do {
                appendLog("📡 SSE: Connected — listening for Bridge events…")
                for try await updates in HueSSEService.shared.events(ip: creds.ip, token: creds.token) {
                    guard !Task.isCancelled else { return }
                    applySSEUpdates(updates)
                    backoffNs = 1_000_000_000   // reset on successful event
                }
                // Stream ended cleanly — bridge closed connection, retry immediately
            } catch {
                guard !Task.isCancelled else { return }
                appendLog("⚠️ SSE: \(error.localizedDescription) — retry in \(backoffNs / 1_000_000_000)s…")
                log.warning("SSE: \(error.localizedDescription, privacy: .public)")
            }

            guard !Task.isCancelled else { return }
            try? await Task.sleep(nanoseconds: backoffNs)
            backoffNs = min(backoffNs * 2, 30_000_000_000)   // cap at 30s
        }
    }

    private func applySSEUpdates(_ updates: [SSEResourceUpdate]) {
        for update in updates {
            if update.type == "grouped_light",
               let idx = rooms.firstIndex(where: { $0.groupedLightID == update.id }) {
                let name = rooms[idx].name
                if let on = update.on {
                    rooms[idx].isOn = on.on
                    appendLog("🔴 SSE: '\(name)' → \(on.on ? "ON" : "OFF")")
                }
                if let dimming = update.dimming {
                    rooms[idx].brightness = dimming.brightness
                    appendLog("🌓 SSE: '\(name)' brightness → \(Int(dimming.brightness))%")
                }
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Logging
    // ──────────────────────────────────────────────

    private func appendLog(_ message: String) {
        let ts = DateFormatter.logTime.string(from: Date())
        let line = "[\(ts)] \(message)"
        logLines.append(line)
        print(line)
    }
}


// MARK: - DateFormatter

private extension DateFormatter {
    static let logTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}
