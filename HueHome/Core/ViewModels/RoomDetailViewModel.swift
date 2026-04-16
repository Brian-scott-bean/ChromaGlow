// RoomDetailViewModel.swift
// HueHome Pro — Epic 3 / Story 3.1
//
// Fetches and manages individual light state for a single room.
// Matches lights to their room using childResourceRefs on the RoomDisplayItem,
// handling both rtype="light" (newer bridge firmware) and rtype="device" (owner-based, older firmware).

import Foundation
import OSLog
import SwiftUI

@Observable
@MainActor
final class RoomDetailViewModel {

    // MARK: State
    var lights:  [LightDisplayItem] = []
    var scenes:  [SceneDisplayItem] = []
    var isLoading: Bool = false
    var errorMessage: String? = nil
    var logLines: [String] = []

    // MARK: Room context
    let room: RoomDisplayItem

    // MARK: Dependencies
    private let api: HueAPIClient
    private let log = Logger(subsystem: "com.huehome.pro", category: "RoomDetail")

    // MARK: Init
    init(room: RoomDisplayItem, api: HueAPIClient = .shared) {
        self.room = room
        self.api  = api
    }

    // ──────────────────────────────────────────────
    // MARK: - Fetch
    // ──────────────────────────────────────────────

    /// Returns a two-way binding into the published lights array for use in navigationDestination.
    func lightBinding(for item: LightDisplayItem) -> Binding<LightDisplayItem>? {
        guard let idx = lights.firstIndex(where: { $0.id == item.id }) else { return nil }
        return Binding(
            get: { self.lights[idx] },
            set: { self.lights[idx] = $0 }
        )
    }

    func loadLights() async {

        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        appendLog("📡 Fetching lights for '\(room.name)'…")

        do {
            let allLights = try await api.fetchLights()
            appendLog("✅ Total lights from Bridge: \(allLights.count)")

            let roomLights = allLights.filter { lightBelongsToRoom($0) }
            appendLog("💡 '\(room.name)' → \(roomLights.count) light(s) matched")

            lights = roomLights.map { hl in
                LightDisplayItem(
                    id:              hl.id,
                    name:            hl.metadata.name,
                    archetype:       hl.metadata.archetype,
                    isOn:            hl.on.on,
                    brightness:      hl.dimming?.brightness ?? 100.0,
                    colorX:          hl.color?.xy.x,
                    colorY:          hl.color?.xy.y,
                    colorTempMirek:  hl.color_temperature?.mirek,
                    mirekMin:        hl.color_temperature?.mirek_schema?.mirek_minimum ?? 153,
                    mirekMax:        hl.color_temperature?.mirek_schema?.mirek_maximum ?? 500
                )
            }.sorted { $0.name < $1.name }

        } catch {
            let msg = error.localizedDescription
            appendLog("❌ Load failed: \(msg)")
            log.error("RoomDetail: \(msg, privacy: .public)")
            errorMessage = msg
        }

        isLoading = false
    }

    // ──────────────────────────────────────────────
    // MARK: - Toggle
    // ──────────────────────────────────────────────

    func toggleLight(_ item: LightDisplayItem) {
        let newState = !item.isOn
        if let idx = lights.firstIndex(where: { $0.id == item.id }) {
            lights[idx].isOn = newState
        }
        appendLog("🔄 Toggling '\(item.name)' → \(newState ? "ON" : "OFF")")

        Task {
            do {
                try await api.setLight(id: item.id, on: newState)
                appendLog("✅ '\(item.name)' → \(newState ? "ON" : "OFF")")
                log.info("RoomDetail: '\(item.name, privacy: .public)' set to \(newState, privacy: .public).")
            } catch {
                appendLog("❌ Toggle failed for '\(item.name)': \(error.localizedDescription)")
                log.error("RoomDetail: \(error.localizedDescription, privacy: .public)")
                if let idx = lights.firstIndex(where: { $0.id == item.id }) {
                    lights[idx].isOn = !newState   // rollback
                }
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Brightness
    // ──────────────────────────────────────────────

    func setBrightness(_ brightness: Double, for item: LightDisplayItem) {
        let clamped  = min(100, max(1, brightness))
        let previous = item.brightness

        if let idx = lights.firstIndex(where: { $0.id == item.id }) {
            lights[idx].brightness = clamped
            if !lights[idx].isOn { lights[idx].isOn = true }
        }
        appendLog("🌓 '\(item.name)' brightness → \(Int(clamped))%")

        Task {
            do {
                if !item.isOn {
                    try await api.setLight(id: item.id, on: true)
                }
                try await api.setLightBrightness(id: item.id, brightness: clamped)
                appendLog("✅ '\(item.name)' brightness set to \(Int(clamped))%.")
                log.info("RoomDetail: '\(item.name, privacy: .public)' brightness \(Int(clamped), privacy: .public)%.")
            } catch {
                appendLog("❌ Brightness failed for '\(item.name)': \(error.localizedDescription)")
                if let idx = lights.firstIndex(where: { $0.id == item.id }) {
                    lights[idx].brightness = previous
                    lights[idx].isOn = item.isOn
                }
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Room Membership Filter
    // ──────────────────────────────────────────────

    /// Returns true if the light belongs to this room.
    /// Handles both V2 firmware variants:
    ///   - Newer: room.children contains {rtype:"light", rid: light.id}
    ///   - Older: room.children contains {rtype:"device", rid: device_id}
    ///            and light.owner.rid == device_id
    private func lightBelongsToRoom(_ light: HueLight) -> Bool {
        for ref in room.childResourceRefs {
            if ref.rtype == "light" && ref.rid == light.id { return true }
            if ref.rtype == "device",
               let ownerID = light.owner?.rid,
               ownerID == ref.rid { return true }
        }
        return false
    }

    // ──────────────────────────────────────────────
    // MARK: - Color
    // ──────────────────────────────────────────────

    func setColor(x: Double, y: Double, for item: LightDisplayItem) {
        if let idx = lights.firstIndex(where: { $0.id == item.id }) {
            lights[idx].colorX = x
            lights[idx].colorY = y
        }
        appendLog("🎨 '\(item.name)' color → xy(\(String(format: "%.3f", x)), \(String(format: "%.3f", y)))")
        Task {
            do {
                try await api.setLightColor(id: item.id, x: x, y: y)
                appendLog("✅ '\(item.name)' color committed.")
            } catch {
                appendLog("❌ Color failed: \(error.localizedDescription)")
                if let idx = lights.firstIndex(where: { $0.id == item.id }) {
                    lights[idx].colorX = item.colorX
                    lights[idx].colorY = item.colorY
                }
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Color Temperature
    // ──────────────────────────────────────────────

    func setColorTemp(mirek: Int, for item: LightDisplayItem) {
        if let idx = lights.firstIndex(where: { $0.id == item.id }) {
            lights[idx].colorTempMirek = mirek
        }
        appendLog("🌡️ '\(item.name)' color temp → \(mirek) mirek (\(HueColorUtils.kelvin(from: mirek))K)")
        Task {
            do {
                try await api.setLightColorTemp(id: item.id, mirek: mirek)
                appendLog("✅ '\(item.name)' color temp committed.")
            } catch {
                appendLog("❌ Color temp failed: \(error.localizedDescription)")
                if let idx = lights.firstIndex(where: { $0.id == item.id }) {
                    lights[idx].colorTempMirek = item.colorTempMirek
                }
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Scenes
    // ──────────────────────────────────────────────

    func loadScenes() async {
        appendLog("🎬 Fetching scenes for '\(room.name)' (room.id = \(room.id))…")
        do {
            let all = try await api.fetchScenes()
            appendLog("🎬 Total scenes on Bridge: \(all.count)")

            // Log first few scene group.rids so the filter is debuggable
            for s in all.prefix(5) {
                appendLog("   scene '\(s.metadata.name)' → group.rid=\(s.group.rid) rtype=\(s.group.rtype)")
            }

            // Match only on rid — skip rtype check since some firmware
            // returns room scenes with rtype "zone" or omits rtype entirely.
            let roomScenes = all.filter { $0.group.rid == room.id }
            appendLog("✅ \(roomScenes.count) scene(s) matched for '\(room.name)'")
            scenes = roomScenes
                .map { s in
                    SceneDisplayItem(
                        id:       s.id,
                        name:     s.metadata.name,
                        isActive: s.status?.active == "active"
                    )
                }
                .sorted { $0.name < $1.name }
        } catch {
            appendLog("⚠️ Scenes load failed: \(error.localizedDescription)")
            log.warning("RoomDetail: scenes — \(error.localizedDescription, privacy: .public)")
            // Non-fatal: scenes are optional; lights still show
        }
    }

    func activateScene(_ item: SceneDisplayItem) {
        // Optimistic: mark this scene active, all others inactive
        for idx in scenes.indices {
            scenes[idx].isActive = (scenes[idx].id == item.id)
        }
        appendLog("🎬 Activating scene '\(item.name)'…")
        HapticManager.shared.medium()

        Task {
            do {
                try await api.activateScene(id: item.id)
                appendLog("✅ Scene '\(item.name)' activated.")
                log.info("RoomDetail: scene '\(item.name, privacy: .public)' activated.")
            } catch {
                appendLog("❌ Scene activation failed: \(error.localizedDescription)")
                // Rollback: clear all active states (actual state unknown after failure)
                for idx in scenes.indices { scenes[idx].isActive = false }
            }
        }
    }

    /// Capture current light states and save as a new named scene on the Bridge.
    /// Returns true on success (caller dismisses the sheet).
    func createScene(name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !lights.isEmpty else { return false }

        appendLog("✨ Creating scene '\(trimmed)' with \(lights.count) light(s)…")

        let request = CreateSceneRequest.fromCurrentLights(
            name:   trimmed,
            roomID: room.id,
            lights: lights
        )

        do {
            try await api.createScene(request)
            appendLog("✅ Scene '\(trimmed)' saved to Bridge.")
            log.info("RoomDetail: scene '\(trimmed, privacy: .public)' created.")
            await loadScenes()   // reload strip so new chip appears immediately
            return true
        } catch {
            appendLog("❌ Scene creation failed: \(error.localizedDescription)")
            log.error("RoomDetail: createScene — \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Delete a scene from the Bridge and remove it from the local strip.
    func deleteScene(_ item: SceneDisplayItem) {
        scenes.removeAll { $0.id == item.id }
        appendLog("🗑 Deleting scene '\(item.name)'…")

        Task {
            do {
                try await api.deleteScene(id: item.id)
                appendLog("✅ Scene '\(item.name)' deleted.")
            } catch {
                appendLog("❌ Delete failed: \(error.localizedDescription)")
                await loadScenes()   // restore strip on failure
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - SSE (color fields)
    // ──────────────────────────────────────────────

    /// Long-running — call from a SwiftUI .task{} so it auto-cancels on view disappear.
    /// Subscribes to "light" type SSE events and patches individual bulb state.
    func runSSE() async {
        guard let creds = try? api.credentials() else {
            appendLog("⚠️ SSE: No credentials — skipping live sync.")
            return
        }

        var backoffNs: UInt64 = 1_000_000_000

        while !Task.isCancelled {
            do {
                appendLog("📡 SSE: Subscribed to light events for '\(room.name)'…")
                for try await updates in HueSSEService.shared.events(ip: creds.ip, token: creds.token) {
                    guard !Task.isCancelled else { return }
                    applySSEUpdates(updates)
                    backoffNs = 1_000_000_000
                }
            } catch {
                guard !Task.isCancelled else { return }
                appendLog("⚠️ SSE: \(error.localizedDescription) — retry in \(backoffNs / 1_000_000_000)s…")
                log.warning("SSE: \(error.localizedDescription, privacy: .public)")
            }

            guard !Task.isCancelled else { return }
            try? await Task.sleep(nanoseconds: backoffNs)
            backoffNs = min(backoffNs * 2, 30_000_000_000)
        }
    }

    private func applySSEUpdates(_ updates: [SSEResourceUpdate]) {
        for update in updates {
            if update.type == "light",
               let idx = lights.firstIndex(where: { $0.id == update.id }) {
                let name = lights[idx].name
                if let on = update.on {
                    lights[idx].isOn = on.on
                    appendLog("🔴 SSE: '\(name)' → \(on.on ? "ON" : "OFF")")
                }
                if let dimming = update.dimming {
                    lights[idx].brightness = dimming.brightness
                    appendLog("🌓 SSE: '\(name)' → \(Int(dimming.brightness))%")
                }
                if let color = update.color {
                    lights[idx].colorX = color.xy.x
                    lights[idx].colorY = color.xy.y
                }
                if let ct = update.colorTemp {
                    lights[idx].colorTempMirek = ct.mirek
                }
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Logging
    // ──────────────────────────────────────────────

    private func appendLog(_ message: String) {
        let ts   = DateFormatter.logTime.string(from: Date())
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
