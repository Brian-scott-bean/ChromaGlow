// EffectsViewModel.swift
// HueHome Pro — Effects Tab
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

    /// Tracks the last-applied effect per room so the UI can restore
    /// per-room selection state when the user switches between rooms.
    /// Key: RoomDisplayItem.id  Value: HueEffect.id
    private var appliedEffectPerRoom: [String: String] = [:]

    // MARK: - Configure

    @MainActor
    func configure(orchestrator: UnifiedOrchestrator) {
        self.orchestrator = orchestrator
        isDemoMode = orchestrator.isDemoMode
        api = orchestrator.primaryAPIClient
        if selectedRoom == nil {
            selectedRoom = orchestrator.allRooms.first
        }
        let apiStatus = api != nil ? "set" : "nil"
        let roomName  = selectedRoom?.name ?? "none"
        log.info("[EffectsVM] configure done — api=\(apiStatus) room=\(roomName) demo=\(self.isDemoMode)")

        // Live re-apply: whenever paramState changes (slider/color/toggle),
        // debounce 350ms then re-apply the current effect to the lights.
        $paramState
            .dropFirst()
            .debounce(for: .milliseconds(350), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self,
                      let effect = self.selectedEffect,
                      !effect.requiresForeground else { return }
                Task { await self.activate() }
            }
            .store(in: &cancellables)

        // Per-room effect state: when the user switches rooms, clear the current
        // selection and restore whatever was last applied to the new room.
        // This fixes the bug where selectedEffect bleeds across rooms, causing
        // a tap on the same card to toggle-off instead of apply.
        $selectedRoom
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newRoom in
                guard let self else { return }

                // If an app-driven effect is looping, stop it — the engine
                // can only run one room's effect at a time.
                if self.isRunning {
                    Task { await self.stop() }
                }

                // Restore the previously applied effect for the incoming room, or clear.
                if let roomID = newRoom?.id,
                   let effectID = self.appliedEffectPerRoom[roomID],
                   let effect   = EffectLibrary.all.first(where: { $0.id == effectID }) {
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

        guard let room = selectedRoom, let groupedLightID = room.groupedLightID else {
            showStatus("⚠ Select a room first")
            return
        }

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
        // For app-driven effects (isRunning == true), remove from room tracking
        // so switching back to this room doesn't falsely restore the stopped effect.
        if isRunning, let roomID = selectedRoom?.id {
            appliedEffectPerRoom.removeValue(forKey: roomID)
        }
        await engine.stop()
        isRunning         = false
        runningEffectName = nil
        statusMessage     = nil
        clearNowPlaying()
    }

    // MARK: - Now Playing Helpers

    @MainActor
    private func setNowPlaying(_ effect: HueEffect) {
        orchestrator?.activeEffectName        = effect.name
        orchestrator?.activeEffectIcon        = effect.icon
        orchestrator?.activeEffectIsAppDriven = effect.requiresForeground
        // Record which effect was applied to this room so we can restore
        // selection state when the user returns to this room later.
        if let roomID = selectedRoom?.id {
            appliedEffectPerRoom[roomID] = effect.id
        }
    }

    @MainActor
    private func clearNowPlaying() {
        orchestrator?.activeEffectName        = nil
        orchestrator?.activeEffectIcon        = nil
        orchestrator?.activeEffectIsAppDriven = false
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
