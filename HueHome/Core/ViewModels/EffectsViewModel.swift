// EffectsViewModel.swift
// CastChroma — Effects Tab
//
// Uses ObservableObject + @Published so SwiftUI reliably re-renders
// when selectedEffect, paramState, or status changes.

import SwiftUI
import Combine
import OSLog

// MARK: - EffectParamState

struct EffectParamState {
    var sliders:   [String: Double]  = [:]
    var colors:    [String: Color]   = [:]
    var palettes:  [String: [Color]] = [:]
    var toggles:   [String: Bool]    = [:]
    var segmented: [String: Int]     = [:]
    var durations: [String: Int]     = [:]

    mutating func load(from params: [EffectParam]) {
        for param in params {
            switch param {
            case .slider(let k, _, let v, _, _, _):         sliders[k]   = v
            case .colorSwatch(let k, _, let c):             colors[k]    = c
            case .colorPalette(let k, _, let cs, _):        palettes[k]  = cs
            case .toggle(let k, _, let v):                  toggles[k]   = v
            case .segmented(let k, _, _, let i):            segmented[k] = i
            case .durationPicker(let k, _, let s, _, _):    durations[k] = s
            }
        }
    }

    func sliderValue(_ key: String, default d: Double = 0)     -> Double { sliders[key]   ?? d }
    func boolValue  (_ key: String, default d: Bool = false)   -> Bool   { toggles[key]   ?? d }
    func colorValue (_ key: String, default d: Color = .white) -> Color  { colors[key]    ?? d }
    func paletteValue(_ key: String)                           -> [Color] { palettes[key]  ?? [] }
    func segmentIndex(_ key: String, default d: Int = 0)       -> Int    { segmented[key] ?? d }
    func durationValue(_ key: String, default d: Int = 900)    -> Int    { durations[key] ?? d }
}

// MARK: - EffectsViewModel

final class EffectsViewModel: ObservableObject {

    // MARK: Published State — drives SwiftUI re-renders
    @Published var selectedEffect:    HueEffect?       = nil
    @Published var selectedCategory:  EffectCategory?  = nil
    @Published var selectedRoom:      RoomDisplayItem? = nil
    @Published var paramState:        EffectParamState = EffectParamState()
    @Published var isRunning:         Bool             = false
    @Published var runningEffectName: String?          = nil
    @Published var statusMessage:     String?          = nil
    // MARK: Dependencies

    private var api:              HueAPIClient?        = nil
    private var isDemoMode:       Bool                 = false
    private weak var orchestrator: UnifiedOrchestrator? = nil
    private let engine            = EffectEngine()
    private let log               = Logger(subsystem: "com.lightshade.app", category: "Effects")
    private var cancellables      = Set<AnyCancellable>()
    private var reactivationTask: Task<Void, Never>?   = nil
    /// Prevents Combine sinks from being re-registered on every onAppear (tab switch).
    private var isConfigured      = false
    /// True while activate() is running — prevents syncWithOrchestrator() from
    /// clearing selectedEffect during the stop→apply cycle inside activate().
    private var isActivating      = false
    /// When set, activate() targets this room instead of selectedRoom.
    /// Used by applyToAllRooms() so it can reuse the full activate() code path
    /// without mutating the @Published selectedRoom (which would fire the Combine sink).
    private var activeRoomOverride: RoomDisplayItem? = nil

    /// When true, the $paramState debounce sink will NOT call activate().
    /// Set during room-switch param restoration to prevent the restored state
    /// from being auto-applied to the incoming room.
    private var suppressParamReapply = false

    // MARK: - Configure

    @MainActor
    func configure(orchestrator: UnifiedOrchestrator) {
        // Always refresh transient dependencies (API client may change if a bridge is added/removed).
        self.orchestrator = orchestrator
        isDemoMode = orchestrator.isDemoMode
        api = orchestrator.primaryAPIClient
        if selectedRoom == nil {
            selectedRoom = orchestrator.allRooms.first
        }
        let apiStatus = api != nil ? "set" : "nil"
        let roomName  = selectedRoom?.name ?? "none"
        log.info("[EffectsVM] configure — api=\(apiStatus) room=\(roomName) demo=\(self.isDemoMode)")

        // Guard: only register Combine sinks once. Calling configure() on every
        // onAppear (tab switch) would otherwise stack duplicate sinks, causing
        // multiple activate() calls per param change → unexpected effect API calls.
        guard !isConfigured else { return }
        isConfigured = true


        // Live re-apply: whenever paramState changes (slider/color/toggle),
        // debounce 350ms then re-apply the current effect to the lights.
        $paramState
            .dropFirst()
            .debounce(for: .milliseconds(350), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self,
                      let effect = self.selectedEffect,
                      !effect.requiresForeground,
                      !self.suppressParamReapply   // skip auto-apply during room-switch restoration
                else { return }
                Task { await self.activate() }
            }
            .store(in: &cancellables)

        // Per-room effect state: clears selection on room-switch; restores
        // whatever was last applied to the incoming room.
        $selectedRoom
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newRoom in
                guard let self else { return }

                // Stop app-driven engine — single-slot, can't loop for two rooms.
                if self.isRunning {
                    Task { await self.stop() }
                }

                // Guard the $paramState debounce from firing activate() while we
                // restore state. Reset after 500 ms (past the 350 ms window).
                self.suppressParamReapply = true
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(500))
                    self?.suppressParamReapply = false
                }

                // Restore selection for the incoming room (visual only — no re-apply).
                if let roomID = newRoom?.id,
                   let entry   = self.orchestrator?.activeEffectEntries.first(where: { $0.id == roomID }),
                   let effect   = EffectLibrary.all.first(where: { $0.id == entry.effectID }) {
                    // Specific room has an active effect — restore its card selection.
                    self.selectedEffect = effect
                    var restored = EffectParamState()
                    restored.load(from: effect.params)
                    self.paramState = restored
                } else if newRoom == nil,
                          let entry = self.orchestrator?.activeEffectEntries.last,
                          let effect = EffectLibrary.all.first(where: { $0.id == entry.effectID }) {
                    // "All Rooms" selected — show the most recently applied effect as selected
                    // so the user can see what's running across all rooms.
                    self.selectedEffect = effect
                    var restored = EffectParamState()
                    restored.load(from: effect.params)
                    self.paramState = restored
                } else {
                    self.selectedEffect = nil
                    self.paramState     = EffectParamState()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Effect Selection

    @MainActor
    func select(_ effect: HueEffect) {
        selectedEffect = effect
        paramState     = EffectParamState()
        paramState.load(from: effect.params)
    }

    // MARK: - Computed Selection State

    /// Returns whether an effect is currently active for the given room context.
    /// - Specific room: that room has an entry with this effect ID.
    /// - All Rooms (nil): EVERY available room has an entry with this effect ID.
    @MainActor
    func isEffectActive(_ effectID: String, in room: RoomDisplayItem?) -> Bool {
        guard let entries = orchestrator?.activeEffectEntries else { return false }
        if let room {
            return entries.contains { $0.id == room.id && $0.effectID == effectID }
        } else {
            // All Rooms: selected only when the effect is running in every room with lights
            let allRoomIDs = Set(orchestrator?.allRooms.compactMap { $0.groupedLightID != nil ? $0.id : nil } ?? [])
            let activeRoomIDs = Set(entries.filter { $0.effectID == effectID }.map { $0.id })
            return !allRoomIDs.isEmpty && allRoomIDs.isSubset(of: activeRoomIDs)
        }
    }

    /// Tapping a selected card a second time deselects it.
    /// Scope: single room or all rooms depending on selectedRoom.
    @MainActor
    func deselect(effectID: String) {
        if isRunning {
            // App-driven: fully stop engine + clear entry
            Task { await stop() }
        } else if let room = selectedRoom {
            // ── Specific room ──────────────────────────────────────────────
            orchestrator?.removeActiveEffect(roomID: room.id)
            // Clear controls panel only if no other effect is now selected for this room
            selectedEffect = nil
            paramState     = EffectParamState()
        } else {
            // ── All Rooms ──────────────────────────────────────────────────
            // Remove every room that has this specific effect
            guard let entries = orchestrator?.activeEffectEntries else { return }
            let roomIDsToRemove = entries.filter { $0.effectID == effectID }.map { $0.id }
            for roomID in roomIDsToRemove {
                orchestrator?.removeActiveEffect(roomID: roomID)
            }
            selectedEffect = nil
            paramState     = EffectParamState()
        }
    }

    // MARK: - Filtered List

    var filteredEffects: [HueEffect] {
        guard let cat = selectedCategory else { return EffectLibrary.all }
        return EffectLibrary.all.filter { $0.category == cat }
    }

    // MARK: - Status Toast

    @MainActor
    func showStatus(_ message: String, autoClear: Bool = true) {
        statusMessage = message
        guard autoClear else { return }
        Task {
            try? await Task.sleep(for: .seconds(3))
            if statusMessage == message { statusMessage = nil }
        }
    }

    // MARK: - Activate

    @MainActor
    func activate() async {
        guard let effect = selectedEffect else { return }

        // ── Demo Mode ─────────────────────────────────────────────────────────
        if isDemoMode {
            let roomName = selectedRoom?.name ?? "all rooms"
            showStatus("✦ Demo: '\(effect.name)' applied to \(roomName)")
            isRunning         = effect.requiresForeground
            runningEffectName = isRunning ? effect.name : nil
            return
        }

        guard let api else {
            showStatus("⚠ No bridge connection — open Settings to re-pair")
            return
        }

        // Resolve the target room: explicit override > current selection > All Rooms
        let effectiveRoom = activeRoomOverride ?? selectedRoom
        guard let room = effectiveRoom, let groupedLightID = room.groupedLightID else {
            // selectedRoom == nil means "All Rooms" chip — apply to each room in sequence
            await applyToAllRooms(effect: effect)
            return
        }

        // Mark as activating so syncWithOrchestrator() doesn't clear the card
        // during the stop → apply cycle (stop() removes the entry, apply re-adds it).
        isActivating = true
        defer { isActivating = false }

        await stop()

        switch effect.strategy {

        case .oneShot:
            let brightness = paramState.sliderValue("brightness", default: 70)
            let mirekRaw   = paramState.sliderValue("mirek",      default: 300)
            let fade       = Int(paramState.sliderValue("fade",   default: 1000))
            let color      = paramState.colorValue("color")
            let useColor   = color != .white
            let xy         = useColor ? color.toCIExy() : nil

            statusMessage = "Applying '\(effect.name)'…"
            isRunning         = false
            runningEffectName = nil

            // Step 1: brightness + CT (or nothing if color) via grouped_light
            // Note: grouped_light does NOT support color.xy — must use per-light calls.
            try? await api.setGroupedLightEffect(
                id: groupedLightID, on: true,
                brightness: brightness,
                xy: nil,
                mirek: useColor ? nil : Int(mirekRaw),
                duration: fade
            )

            // Step 2: if a color is selected, set xy on each light individually
            if let xy {
                let lightIDs = (try? await api.fetchLightIDsForGroup(groupedLightID: groupedLightID)) ?? []
                await withTaskGroup(of: Void.self) { group in
                    for id in lightIDs {
                        group.addTask {
                            try? await api.setLightColor(id: id, x: xy.0, y: xy.1)
                        }
                    }
                }
            }

            showStatus("'\(effect.name)' applied ✓")
            setNowPlaying(effect)


        case .bridgeNative(let effectName):
            isRunning         = false
            runningEffectName = nil
            statusMessage     = "Fetching lights…"

            let lightIDs       = (try? await api.fetchLightIDsForGroup(groupedLightID: groupedLightID)) ?? []
            let brightness     = paramState.sliderValue("brightness", default: 70)

            if lightIDs.isEmpty {
                try? await api.setGroupedLightEffect(
                    id: groupedLightID, on: true,
                    brightness: brightness, xy: nil, mirek: nil, duration: 0
                )
                showStatus("'\(effect.name)' applied (limited)")
                return
            }

            statusMessage = "Applying '\(effect.name)' to \(lightIDs.count) lights…"
            await withTaskGroup(of: Void.self) { group in
                for id in lightIDs {
                    group.addTask {
                        try? await api.setLightNativeEffect(id: id, effect: effectName)
                        if brightness != 70 {
                            try? await api.setLightBrightness(id: id, brightness: brightness)
                        }
                    }
                }
            }
            showStatus("'\(effect.name)' running on bridge ✓ — persists after closing app")
            setNowPlaying(effect)

        case .gradual:
            let durationSec    = paramState.durationValue("duration",       default: 1800)
            let startBrightness = paramState.sliderValue("startBrightness", default: 1)
            let endBrightness  = paramState.sliderValue("endBrightness",    default: 90)
            let startMirek     = Int(paramState.sliderValue("startMirek",   default: 490))
            let endMirek       = Int(paramState.sliderValue("endMirek",     default: 230))
            let turnOff        = paramState.boolValue("turnOff")

            isRunning         = false
            runningEffectName = nil
            statusMessage     = "Preparing '\(effect.name)'…"

            // Step 1: clear any running native bridge effect per-light so the ramp can take over
            let lightIDs = (try? await api.fetchLightIDsForGroup(groupedLightID: groupedLightID)) ?? []
            if !lightIDs.isEmpty {
                await withTaskGroup(of: Void.self) { group in
                    for id in lightIDs {
                        group.addTask { try? await api.setLightNativeEffect(id: id, effect: "no_effect") }
                    }
                }
            }

            // Step 2: snap to start state immediately (instant, no duration)
            let hasStart = paramState.sliderValue("startBrightness", default: -1) >= 0
                        || paramState.sliderValue("startMirek",      default: -1) >= 0
            if hasStart {
                try? await api.setGroupedLightEffect(
                    id: groupedLightID, on: true,
                    brightness: startBrightness, xy: nil, mirek: startMirek,
                    duration: 0
                )
                // Small pause so bridge registers start before ramp begins
                try? await Task.sleep(for: .milliseconds(300))
            }

            // Step 3: ramp to end state over full duration
            statusMessage = "'\(effect.name)' ramping over \(durationSec / 60) min…"
            try? await api.setGroupedLightEffect(
                id: groupedLightID, on: true,
                brightness: endBrightness, xy: nil, mirek: endMirek,
                duration: durationSec * 1000
            )
            showStatus("'\(effect.name)' running ✓ — persists after closing app")
            setNowPlaying(effect)

            if turnOff {
                let capturedAPI  = api
                let capturedGLID = groupedLightID
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(durationSec) * 1_000_000_000)
                    try? await capturedAPI.setGroupedLight(id: capturedGLID, on: false)
                }
            }

        case .appDriven:
            statusMessage = "Fetching lights…"
            let lightIDs = (try? await api.fetchLightIDsForGroup(groupedLightID: groupedLightID)) ?? []
            guard !lightIDs.isEmpty else {
                statusMessage = "⚠ Could not fetch light IDs"
                return
            }

            let lights = lightIDs.map { id in
                LightDisplayItem(id: id, name: "Light", archetype: nil,
                                 isOn: true, brightness: 100,
                                 colorX: 0.32, colorY: 0.33,
                                 supportsColor: true,
                                 colorTempMirek: 300, mirekMin: 153, mirekMax: 500)
            }

            let palette   = buildPalette()
            let sync      = paramState.boolValue("sync")
            let flash     = paramState.boolValue("flash")
            let bpm       = paramState.sliderValue("bpm",            default: 120)
            let dutyCycle = paramState.sliderValue("dutyCycle",      default: 50) / 100.0
            let speed     = paramState.sliderValue("speed",          default: 5)
            let offDim    = paramState.sliderValue("offDim",         default: 0)
            let freqIdx   = paramState.segmentIndex("frequency")
            let baseXY    = paramState.colorValue("baseColor",       default: Color(hue: 0.6, saturation: 0.4, brightness: 0.25)).toCIExy()
            let flashXY   = paramState.colorValue("flashColor",      default: .white).toCIExy()
            let baseB     = paramState.sliderValue("baseBrightness", default: 15)
            let onXY      = paramState.colorValue("color",           default: .white).toCIExy()

            isRunning         = true
            runningEffectName = effect.name
            statusMessage     = "'\(effect.name)' running — keep app open"
            setNowPlaying(effect)

            let loop: @Sendable () async throws -> Void
            switch effect.id {
            case "strobe":
                loop = EffectLoops.strobe(lights: lights, api: api, bpm: bpm,
                                          dutyCycle: dutyCycle, onXY: onXY, offBrightness: offDim)
            case "party":
                loop = EffectLoops.party(lights: lights, api: api, speed: speed,
                                         palette: palette, sync: sync, flash: flash)
            case "thunderstorm":
                loop = EffectLoops.thunderstorm(lights: lights, api: api, frequencyIndex: freqIdx,
                                                baseXY: baseXY, flashXY: flashXY, baseBrightness: baseB)
            default:
                statusMessage = "Unknown effect: \(effect.id)"
                isRunning     = false
                return
            }
            await engine.start(effectID: effect.id, loop: loop)
        }
    }

    // MARK: - Stop

    @MainActor
    func stop() async {
        await engine.stop()
        isRunning         = false
        runningEffectName = nil
        statusMessage     = nil
        clearNowPlaying()
    }

    /// Called from EffectsView's onChange(of: orchestrator.activeEffectEntries).
    /// Clears the card selection when an effect is stopped externally
    /// (e.g. via the Stop button on the home page).
    @MainActor
    func syncWithOrchestrator(entries: [ActiveEffectEntry]) {
        // Never clear the card while activate() is mid-cycle (stop removes the entry,
        // then setNowPlaying re-adds it; clearing here would deselect the card).
        guard !isActivating else { return }
        guard let roomID = selectedRoom?.id,
              selectedEffect != nil,
              !entries.contains(where: { $0.id == roomID })
        else { return }
        // This room's effect was removed outside EffectsViewModel — clear the card.
        selectedEffect = nil
        paramState     = EffectParamState()
    }

    // MARK: - Now Playing Helpers

    @MainActor
    private func setNowPlaying(_ effect: HueEffect) {
        guard let orchestrator else { return }
        // Use override room when apply-to-all loops over rooms without publishing a room change
        let room = activeRoomOverride ?? selectedRoom
        guard let room else { return }
        orchestrator.addActiveEffect(ActiveEffectEntry(
            id:             room.id,
            roomName:       room.name,
            groupedLightID: room.groupedLightID,
            effectID:       effect.id,
            effectName:     effect.name,
            effectIcon:     effect.icon,
            isAppDriven:    effect.requiresForeground
        ))
    }

    /// Applies the current effect to every room that has a grouped light.
    /// Called from activate() when selectedRoom == nil ("All Rooms" chip).
    @MainActor
    private func applyToAllRooms(effect: HueEffect) async {
        guard let rooms = orchestrator?.allRooms else { return }
        let targets = rooms.filter { $0.groupedLightID != nil }
        guard !targets.isEmpty else {
            showStatus("⚠ No rooms with lights found")
            return
        }
        isActivating = true
        defer { isActivating = false }
        for room in targets {
            activeRoomOverride = room
            await activate()
        }
        activeRoomOverride = nil
        showStatus("'\(effect.name)' applied to all rooms ✓")
    }

    @MainActor
    private func clearNowPlaying() {
        // When applyToAllRooms is running, activeRoomOverride is the current iteration room.
        // Use it so we only remove THAT room's entry, preserving entries for rooms already done.
        // Fall back to selectedRoom for the normal single-room case.
        // Only removeAllActiveEffects() when both are nil (genuine "clear all" from stop/deselect).
        let roomID = activeRoomOverride?.id ?? selectedRoom?.id
        if let roomID {
            orchestrator?.removeActiveEffect(roomID: roomID)
        } else {
            orchestrator?.removeAllActiveEffects()
        }
    }

    // MARK: - Saved Presets

    /// Builds a SavedEffectPreset from the currently selected effect + param state.
    /// Returns nil if no effect is selected.
    func buildPresetData(name: String) -> SavedEffectPreset? {
        guard let effect = selectedEffect else { return nil }
        let encodedColors: [String: [Double]] = Dictionary(
            uniqueKeysWithValues: paramState.colors.map { (k, v) in (k, v.hsbaComponents()) }
        )
        let encodedPalettes: [String: [[Double]]] = Dictionary(
            uniqueKeysWithValues: paramState.palettes.map { (k, vs) in
                (k, vs.map { $0.hsbaComponents() })
            }
        )
        return SavedEffectPreset(
            name:         name,
            baseEffectID: effect.id,
            sliders:      paramState.sliders,
            toggles:      paramState.toggles,
            segmented:    paramState.segmented,
            durations:    paramState.durations,
            colors:       encodedColors,
            palettes:     encodedPalettes
        )
    }

    /// Restores a saved preset: loads the base effect, replaces all param values,
    /// and auto-applies the effect (for non-loop effects).
    @MainActor
    func loadPreset(_ preset: SavedEffectPreset) async {
        guard let effect = EffectLibrary.all.first(where: { $0.id == preset.baseEffectID })
        else { return }

        select(effect)  // initialises paramState from default params

        // Override with the saved snapshot
        paramState.sliders   = preset.sliders
        paramState.toggles   = preset.toggles
        paramState.segmented = preset.segmented
        paramState.durations = preset.durations
        paramState.colors    = Dictionary(
            uniqueKeysWithValues: preset.colors.map { (k, v) in (k, Color.fromHSBA(v)) }
        )
        paramState.palettes  = Dictionary(
            uniqueKeysWithValues: preset.palettes.map { (k, vs) in
                (k, vs.map { Color.fromHSBA($0) })
            }
        )

        // Auto-apply immediately (same behaviour as tapping the effect card)
        if !effect.requiresForeground {
            await activate()
        }
    }

    // MARK: - Palette

    private func buildPalette() -> [(Double, Double)] {
        let presetIdx = paramState.segmentIndex("preset")
        let preset    = PresetPalette.allCases[safeIndex: presetIdx] ?? .aurora
        let colors    = (preset == .custom)
            ? (paramState.palettes["palette"] ?? PresetPalette.aurora.colors)
            : preset.colors
        return colors.map { $0.toCIExy() }
    }
}

// MARK: - Color → CIE xy

extension Color {
    func toCIExy() -> (Double, Double) {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        let lin: (CGFloat) -> Double = { c in
            let c = Double(c)
            return c > 0.04045 ? pow((c + 0.055) / 1.055, 2.4) : c / 12.92
        }
        let rL = lin(r), gL = lin(g), bL = lin(b)
        let X = rL * 0.664511 + gL * 0.154324 + bL * 0.162028
        let Y = rL * 0.283881 + gL * 0.668433 + bL * 0.047685
        let Z = rL * 0.000088 + gL * 0.072310 + bL * 0.986039
        let sum = X + Y + Z
        guard sum > 0 else { return (0.32, 0.33) }
        return (X / sum, Y / sum)
    }
}

// MARK: - Safe Array subscript

extension Array {
    subscript(safeIndex index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
