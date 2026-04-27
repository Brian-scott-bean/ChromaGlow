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
    private var api:        HueAPIClient? = nil
    private var isDemoMode: Bool          = false
    private let engine      = EffectEngine()
    private let log         = Logger(subsystem: "com.huehome.pro", category: "Effects")

    // MARK: - Configure

    @MainActor
    func configure(orchestrator: UnifiedOrchestrator) {
        isDemoMode = orchestrator.isDemoMode
        api = orchestrator.primaryAPIClient
        if selectedRoom == nil {
            selectedRoom = orchestrator.allRooms.first
        }
        let apiStatus = api != nil ? "set" : "nil"
        let roomName  = selectedRoom?.name ?? "none"
        log.info("[EffectsVM] configure done — api=\(apiStatus) room=\(roomName) demo=\(self.isDemoMode)")
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

    // MARK: - Activate

    @MainActor
    func activate() async {
        guard let effect = selectedEffect else { return }

        // ── Demo Mode ─────────────────────────────────────────────────────────
        if isDemoMode {
            let roomName = selectedRoom?.name ?? "all rooms"
            statusMessage     = "✦ Demo: '\(effect.name)' applied to \(roomName)"
            isRunning         = effect.requiresForeground
            runningEffectName = isRunning ? effect.name : nil
            return
        }

        guard let api else {
            statusMessage = "⚠ No active bridge connection"
            return
        }

        guard let room = selectedRoom, let groupedLightID = room.groupedLightID else {
            statusMessage = "⚠ Select a room to apply effects"
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

            statusMessage     = "Applying '\(effect.name)'…"
            isRunning         = false
            runningEffectName = nil

            try? await api.setGroupedLightEffect(
                id: groupedLightID, on: true,
                brightness: brightness,
                xy: xy, mirek: useColor ? nil : Int(mirekRaw),
                duration: fade
            )
            statusMessage = "'\(effect.name)' applied ✓"

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
                statusMessage = "'\(effect.name)' applied (limited)"
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
            statusMessage = "'\(effect.name)' running on bridge ✓ — persists after closing app"

        case .gradual:
            let durationSec   = paramState.durationValue("duration", default: 1800)
            let endBrightness = paramState.sliderValue("endBrightness", default: 90)
            let endMirek      = Int(paramState.sliderValue("endMirek",  default: 230))
            let turnOff       = paramState.boolValue("turnOff")

            isRunning         = false
            runningEffectName = nil
            statusMessage     = "'\(effect.name)' ramping over \(durationSec / 60) min…"

            try? await api.setGroupedLightEffect(
                id: groupedLightID, on: true,
                brightness: endBrightness, xy: nil, mirek: endMirek,
                duration: durationSec * 1000
            )
            statusMessage = "'\(effect.name)' running ✓ — persists after closing app"

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
