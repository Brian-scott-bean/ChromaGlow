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
    /// ID of scene currently being activated — drives spinner on RoomSceneChip.
    var activatingSceneID: String? = nil
    var isLoading: Bool = false
    var errorMessage: String? = nil
    var logLines: [String] = []
    /// Brief error for UI toast — auto-cleared after 3 s.
    var toastMessage: String? = nil

    // MARK: Multi-select state
    /// True while the user is in light-selection mode.
    var isSelecting: Bool = false
    /// IDs of lights currently checked in select mode.
    var selectedLightIDs: Set<String> = []
    /// Convenience: the LightDisplayItem objects for all checked IDs.
    var selectedLights: [LightDisplayItem] {
        lights.filter { selectedLightIDs.contains($0.id) }
    }

    // MARK: Room context
    let room: RoomDisplayItem

    // MARK: Dependencies
    private let api: HueAPIClient?
    private let isDemoMode: Bool
    private let log = Logger(subsystem: "com.lightshade.app", category: "RoomDetail")
    /// Called after a color/CT commit succeeds — injected by RoomDetailView
    /// to trigger orchestrator.refreshDominantColors(for: bridgeID).
    var onColorCommitted: (() -> Void)? = nil
    /// Debounce task — cancelled and replaced on every rapid color change.
    private var colorRefreshTask: Task<Void, Never>? = nil

    // MARK: Init
    /// - Parameters:
    ///   - api: The HueAPIClient for this room's bridge. Pass nil to run in demo mode.
    init(room: RoomDisplayItem, api: HueAPIClient? = nil, isDemoMode: Bool = false) {
        self.room       = room
        self.api        = api
        self.isDemoMode = isDemoMode || (api == nil)
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

        // Demo mode: load mock data instantly, no network
        if isDemoMode {
            appendLog("✦ Demo: loading mock lights for '\(room.name)'")
            lights = DemoDataProvider.lights(for: room.id)
            appendLog("✅ Demo: \(lights.count) light(s) loaded")
            isLoading = false
            return
        }

        appendLog("📡 Fetching lights for '\(room.name)'…")
        guard let api else {
            errorMessage = "No bridge client available"
            isLoading = false
            return
        }

        do {
            async let lightsFetch  = api.fetchLights()
            // If childResourceRefs were not cached (room loaded from preloadCached before
            // loadAll() completed), concurrently fetch the latest room children from the bridge.
            // This is the common "fast cold-start" path: cached room → tap → loadLights.
            let needsFallback = room.childResourceRefs.isEmpty
            async let roomsFetch: [HueRoom]? = needsFallback ? api.fetchRooms() : nil

            let allLights = try await lightsFetch
            appendLog("✅ Total lights from Bridge: \(allLights.count)")

            // Resolve the effective child refs — prefer cached, fall back to live fetch.
            var effectiveRefs = room.childResourceRefs
            if effectiveRefs.isEmpty {
                if let liveRooms = try? await roomsFetch,
                   let liveRoom = liveRooms.first(where: { $0.id == room.id }) {
                    effectiveRefs = liveRoom.children.map { ($0.rid, $0.rtype) }
                    appendLog("✅ Fetched \(effectiveRefs.count) child refs from bridge (refs were empty)")
                } else {
                    appendLog("⚠️ Could not resolve child refs — room may show no lights")
                }
            }

            let roomLights = allLights.filter { lightBelongsToRoom($0, refs: effectiveRefs) }
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
    // MARK: - Safe @Observable mutation helper
    // ──────────────────────────────────────────────

    /// Mutate a single light by ID via copy-mutate-assign.
    ///
    /// @Observable in iOS 17 uses _modify coroutines for subscript access.
    /// Nested _modify (array[i].property = value inside @Observable _modify)
    /// does NOT reliably fire the observation registrar on iOS 17, causing
    /// SwiftUI to skip re-renders after optimistic state changes.
    /// A full property assignment (lights = newArray) always fires the
    /// observation registrar, so we use this pattern everywhere.
    private func mutateLight(id: String, _ mutation: (inout LightDisplayItem) -> Void) {
        guard let idx = lights.firstIndex(where: { $0.id == id }) else { return }
        var arr = lights
        mutation(&arr[idx])
        lights = arr    // full assignment — guaranteed @Observable notification
    }

    // ──────────────────────────────────────────────
    // MARK: - Toggle
    // ──────────────────────────────────────────────
    // MARK: - Brightness
    // ──────────────────────────────────────────────

    /// Explicitly set on-state for a single light.
    /// Accepts the desired state directly — avoids the stale-capture bug where
    /// toggleLight(_:) computes !item.isOn from a frozen ForEach value type.
    func setLight(_ item: LightDisplayItem, isOn: Bool) {
        mutateLight(id: item.id) { $0.isOn = isOn }
        appendLog("🔄 Setting '\(item.name)' → \(isOn ? "ON" : "OFF")")
        if isDemoMode { return }
        Task {
            do {
                try await api?.setLight(id: item.id, on: isOn)
                appendLog("✅ '\(item.name)' → \(isOn ? "ON" : "OFF")")
            } catch {
                appendLog("❌ Set failed for '\(item.name)': \(error.localizedDescription)")
                mutateLight(id: item.id) { $0.isOn = !isOn }   // rollback
                showToast("Couldn't reach bridge — \(item.name) reverted")
            }
        }
    }

    func showToast(_ message: String) {
        toastMessage = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if toastMessage == message { toastMessage = nil }
        }
    }

    func setBrightness(_ brightness: Double, for item: LightDisplayItem) {
        let clamped  = min(100, max(1, brightness))
        let previous = item.brightness

        mutateLight(id: item.id) { $0.brightness = clamped; $0.isOn = true }
        appendLog("🌓 '\(item.name)' brightness → \(Int(clamped))%")

        // Demo mode: local state update is all we need
        if isDemoMode { return }

        Task {
            do {
                // Single API call: turn on + set brightness together
                // (avoids the flash where light turns on at old brightness first)
                try await api?.setLightState(id: item.id, on: true, brightness: clamped)
                appendLog("✅ '\(item.name)' brightness set to \(Int(clamped))%.")
                log.info("RoomDetail: '\(item.name, privacy: .public)' brightness \(Int(clamped), privacy: .public)%.")
            } catch {
                appendLog("❌ Brightness failed for '\(item.name)': \(error.localizedDescription)")
                mutateLight(id: item.id) { $0.brightness = previous; $0.isOn = item.isOn }
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
    /// Returns true if `light` belongs to this room.
    /// Accepts an explicit `refs` array so the caller can pass live-fetched children when
    /// `room.childResourceRefs` is empty (cached room pre-loadAll).
    private func lightBelongsToRoom(_ light: HueLight,
                                    refs: [(rid: String, rtype: String)]) -> Bool {
        for ref in refs {
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
        mutateLight(id: item.id) { $0.colorX = x; $0.colorY = y }
        appendLog("🎨 '\(item.name)' color → xy(\(String(format: "%.3f", x)), \(String(format: "%.3f", y)))")
        if isDemoMode { return }
        Task {
            do {
                try await api?.setLightColor(id: item.id, x: x, y: y)
                appendLog("✅ '\(item.name)' color committed.")
                scheduleColorRefresh()
            } catch {
                appendLog("❌ Color failed: \(error.localizedDescription)")
                mutateLight(id: item.id) { $0.colorX = item.colorX; $0.colorY = item.colorY }
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Color Temperature
    // ──────────────────────────────────────────────

    func setColorTemp(mirek: Int, for item: LightDisplayItem) {
        mutateLight(id: item.id) { $0.colorTempMirek = mirek }
        appendLog("🌡️ '\(item.name)' color temp → \(mirek) mirek (\(HueColorUtils.kelvin(from: mirek))K)")
        if isDemoMode { return }
        Task {
            do {
                try await api?.setLightColorTemp(id: item.id, mirek: mirek)
                appendLog("✅ '\(item.name)' color temp committed.")
                scheduleColorRefresh()
            } catch {
                appendLog("❌ Color temp failed: \(error.localizedDescription)")
                mutateLight(id: item.id) { $0.colorTempMirek = item.colorTempMirek }
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Glow refresh helper
    // ──────────────────────────────────────────────

    /// Debounced: cancels any pending refresh and schedules a new one 1.5 s
    /// from now — same delay as scene activation. Prevents rapid slider drags
    /// from firing many bridge fetches while the user is still adjusting.
    private func scheduleColorRefresh() {
        colorRefreshTask?.cancel()
        colorRefreshTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            onColorCommitted?()
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Multi-select
    // ──────────────────────────────────────────────

    /// Enter select mode, optionally pre-selecting one light (e.g. long-press).
    func enterSelectMode(preselecting id: String? = nil) {
        selectedLightIDs = id.map { [$0] } ?? []
        withAnimation(.spring(response: 0.3)) { isSelecting = true }
        HapticManager.shared.medium()
    }

    func exitSelectMode() {
        withAnimation(.spring(response: 0.3)) { isSelecting = false }
        selectedLightIDs.removeAll()
    }

    func toggleSelection(id: String) {
        if selectedLightIDs.contains(id) {
            selectedLightIDs.remove(id)
        } else {
            selectedLightIDs.insert(id)
        }
        HapticManager.shared.light()
    }

    func selectAll()     { selectedLightIDs = Set(lights.map(\.id)) }
    func clearSelection() { selectedLightIDs.removeAll() }

    /// Turn all selected lights on or off.
    func setSelectedLightsOn(_ on: Bool) {
        for light in selectedLights { setLight(light, isOn: on) }
    }

    /// Set brightness on all selected lights.
    func setSelectedLightsBrightness(_ pct: Double) {
        for light in selectedLights { setBrightness(pct, for: light) }
    }

    // ──────────────────────────────────────────────
    // MARK: - Scenes
    // ──────────────────────────────────────────────

    func loadScenes() async {
        // Demo mode: load mock scenes instantly
        if isDemoMode {
            appendLog("✦ Demo: loading mock scenes for '\(room.name)'")
            scenes = DemoDataProvider.scenes(for: room.id)
            appendLog("✅ Demo: \(scenes.count) scene(s) loaded")
            return
        }

        appendLog("🎬 Fetching scenes for '\(room.name)' (room.id = \(room.id))…")
        guard let api else { return }
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
        guard activatingSceneID == nil else { return }   // prevent double-tap
        // Optimistic: full-array map → reliably triggers @Observable on iOS 17
        scenes = scenes.map { s in var c = s; c.isActive = (s.id == item.id); return c }
        appendLog("🎬 Activating scene '\(item.name)'…")
        HapticManager.shared.medium()

        // Demo mode: local state update only
        if isDemoMode {
            appendLog("✦ Demo: scene '\(item.name)' activated")
            return
        }

        activatingSceneID = item.id
        Task {
            do {
                try await api?.activateScene(id: item.id)
                appendLog("✅ Scene '\(item.name)' activated.")
                log.info("RoomDetail: scene '\(item.name, privacy: .public)' activated.")
            } catch {
                appendLog("❌ Scene activation failed: \(error.localizedDescription)")
                scenes = scenes.map { s in var c = s; c.isActive = false; return c }
                showToast("Couldn't activate scene '\(item.name)'")
            }
            // Brief hold so user sees the active state before spinner clears
            try? await Task.sleep(nanoseconds: 600_000_000)
            activatingSceneID = nil
        }
    }

    /// Capture current light states and save as a new named scene on the Bridge.
    /// Returns true on success (caller dismisses the sheet).
    func createScene(name: String, lights selectedLights: [LightDisplayItem]) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !selectedLights.isEmpty else { return false }

        // Demo mode: pretend scene was created
        if isDemoMode {
            appendLog("✦ Demo: scene '\(trimmed)' created locally")
            scenes.append(SceneDisplayItem(id: UUID().uuidString, name: trimmed, isActive: false))
            return true
        }

        appendLog("✨ Creating scene '\(trimmed)' with \(selectedLights.count) light(s)…")

        let request = CreateSceneRequest.fromCurrentLights(
            name:       trimmed,
            groupID:    room.id,
            groupRtype: room.kind == .zone ? "zone" : "room",
            lights:     selectedLights
        )

        do {
            try await api?.createScene(request)
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

    /// Rename a scene on the Bridge and update the local strip optimistically.
    func renameScene(_ item: SceneDisplayItem, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let oldName = item.name
        // Optimistic update
        scenes = scenes.map { s in
            var c = s; if c.id == item.id { c.name = trimmed }; return c
        }
        appendLog("✏️ Renaming scene '\(oldName)' → '\(trimmed)'…")
        if isDemoMode {
            appendLog("✦ Demo: scene renamed locally")
            return
        }
        Task {
            do {
                try await api?.renameScene(id: item.id, name: trimmed)
                appendLog("✅ Scene renamed to '\(trimmed)'.")
            } catch {
                appendLog("❌ Rename failed: \(error.localizedDescription)")
                // Revert
                scenes = scenes.map { s in
                    var c = s; if c.id == item.id { c.name = oldName }; return c
                }
                showToast("Couldn't rename '\(oldName)'")
            }
        }
    }

    /// Delete a scene from the Bridge and remove it from the local strip.
    func deleteScene(_ item: SceneDisplayItem) {
        scenes.removeAll { $0.id == item.id }
        appendLog("🗑 Deleting scene '\(item.name)'…")

        if isDemoMode {
            appendLog("✦ Demo: scene '\(item.name)' removed locally")
            return
        }

        Task {
            do {
                try await api?.deleteScene(id: item.id)
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
    ///
    /// Subscribes to the ORCHESTRATOR's light-event bus instead of opening a second
    /// SSE connection to the bridge. The orchestrator's existing runSSE() already
    /// receives all event types (grouped_light + light); it forwards raw updates here
    /// via AsyncStream<[SSEResourceUpdate]>. This eliminates the dual-SSE problem.
    ///
    /// Fallback: if eventStream is nil (demo mode or no orchestrator), returns immediately.
    func runSSE(eventStream: AsyncStream<[SSEResourceUpdate]>?) async {
        guard !isDemoMode else { return }
        guard let stream = eventStream else {
            appendLog("⚠️ SSE: No event stream — skipping live sync.")
            return
        }
        appendLog("📡 SSE: Subscribed via orchestrator event bus for '\(room.name)'…")
        for await updates in stream {
            guard !Task.isCancelled else { return }
            applySSEUpdates(updates)
        }
        appendLog("📡 SSE: Event stream ended for '\(room.name)'.")
    }

    /// Applies SSE light-state updates as a single full-array swap.
    /// Batch all mutations into one new array then assign once —
    /// guarantees exactly one @Observable notification per SSE event.
    private func applySSEUpdates(_ updates: [SSEResourceUpdate]) {
        var arr = lights
        var changed = false
        for update in updates where update.type == "light" {
            guard let idx = arr.firstIndex(where: { $0.id == update.id }) else { continue }
            let name = arr[idx].name
            if let on = update.on {
                arr[idx].isOn = on.on
                appendLog("🔴 SSE: '\(name)' → \(on.on ? "ON" : "OFF")")
                changed = true
            }
            if let dimming = update.dimming {
                arr[idx].brightness = dimming.brightness
                appendLog("🌓 SSE: '\(name)' → \(Int(dimming.brightness))%")
                changed = true
            }
            if let color = update.color {
                arr[idx].colorX = color.xy.x
                arr[idx].colorY = color.xy.y
                changed = true
            }
            if let ct = update.colorTemp {
                arr[idx].colorTempMirek = ct.mirek
                changed = true
            }
        }
        // Single full-array assignment — one @Observable notification for entire batch
        if changed { lights = arr }
    }

    // ──────────────────────────────────────────────
    // MARK: - Logging
    // ──────────────────────────────────────────────

    private func appendLog(_ message: String) {
        #if DEBUG
        let ts   = DateFormatter.logTime.string(from: Date())
        let line = "[\(ts)] \(message)"
        // Cap at 150 entries — prevents unbounded memory growth from SSE events.
        // Oldest entries are dropped FIFO; the log view only shows recent activity anyway.
        if logLines.count >= 150 { logLines.removeFirst() }
        logLines.append(line)
        #endif  // DEBUG — logLines growth is debug-only; OSLog handles prod logging
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
