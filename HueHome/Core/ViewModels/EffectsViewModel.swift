// EffectsViewModel.swift
// HueHome Pro — Effects Tab
//
// Manages selected effect, live parameter state, room targeting,
// and delegates to EffectEngine for app-driven loops.

import SwiftUI
import OSLog

// MARK: - EffectParamState

/// Mutable live state for all parameter types.
/// Keyed by EffectParam.key.
struct EffectParamState {
    var sliders:       [String: Double]   = [:]
    var colors:        [String: Color]    = [:]
    var palettes:      [String: [Color]]  = [:]
    var toggles:       [String: Bool]     = [:]
    var segmented:     [String: Int]      = [:]
    var durations:     [String: Int]      = [:]
    var presetIndex:   [String: Int]      = [:]

    /// Load defaults from an effect's param schema
    mutating func load(from params: [EffectParam]) {
        for param in params {
            switch param {
            case .slider(let k, _, let v, _, _, _):
                sliders[k] = v
            case .colorSwatch(let k, _, let c):
                colors[k] = c
            case .colorPalette(let k, _, let cs, _):
                palettes[k] = cs
            case .toggle(let k, _, let v):
                toggles[k] = v
            case .segmented(let k, _, _, let i):
                segmented[k] = i
            case .durationPicker(let k, _, let s, _, _):
                durations[k] = s
            }
        }
    }

    func sliderValue(_ key: String, default d: Double = 0) -> Double { sliders[key] ?? d }
    func boolValue(_ key: String, default d: Bool = false) -> Bool { toggles[key] ?? d }
    func colorValue(_ key: String, default d: Color = .white) -> Color { colors[key] ?? d }
    func paletteValue(_ key: String) -> [Color] { palettes[key] ?? [] }
    func segmentIndex(_ key: String, default d: Int = 0) -> Int { segmented[key] ?? d }
    func durationValue(_ key: String, default d: Int = 900) -> Int { durations[key] ?? d }
}

// MARK: - EffectsViewModel

@Observable
@MainActor
final class EffectsViewModel {

    // MARK: State
    var selectedEffect:   HueEffect? = nil
    var selectedCategory: EffectCategory? = nil   // nil = show all
    var selectedRoomID:   String? = nil            // nil = all rooms on orchestrator
    var paramState:       EffectParamState = EffectParamState()
    var isRunning:        Bool = false
    var runningEffectName: String? = nil
    var statusMessage:    String? = nil

    // MARK: Dependencies
    private var bridgeClients: [(id: String, api: HueAPIClient)] = []
    private var isDemoMode:    Bool = false
    private let engine  = EffectEngine()
    private let log     = Logger(subsystem: "com.huehome.pro", category: "Effects")

    // MARK: - Configure

    func configure(bridgeIDs: [String], orchestrator: UnifiedOrchestrator) {
        isDemoMode    = orchestrator.isDemoMode
        bridgeClients = bridgeIDs.compactMap { id in
            guard let api = orchestrator.hueClient(for: id) else { return nil }
            return (id: id, api: api)
        }
    }

    // MARK: - Effect Selection

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

    func activate(lights: [LightDisplayItem]) async {
        guard let effect = selectedEffect else { return }

        if isDemoMode {
            statusMessage    = "✦ Demo: '\(effect.name)' activated on \(lights.count) light(s)"
            isRunning        = effect.requiresForeground
            runningEffectName = isRunning ? effect.name : nil
            log.info("Effects demo: \(effect.name, privacy: .public)")
            return
        }

        guard !bridgeClients.isEmpty else {
            statusMessage = "No active bridge"
            return
        }

        // Stop any existing effect first
        await stop(lights: lights)

        let api = bridgeClients.first!.api   // TODO: multi-bridge routing per light

        switch effect.strategy {

        // ── One-Shot ─────────────────────────────────────
        case .oneShot:
            let brightness = paramState.sliderValue("brightness", default: 70)
            let mirekRaw   = paramState.sliderValue("mirek",      default: 300)
            let fade       = Int(paramState.sliderValue("fade",   default: 1000))
            let color      = paramState.colorValue("color")
            let xy         = color.toCIExy()

            isRunning        = false
            runningEffectName = nil
            statusMessage    = "Applying '\(effect.name)'…"

            let capturedState = self.paramState
            await withTaskGroup(of: Void.self) { group in
                for light in lights {
                    group.addTask {
                        let useColor = light.supportsColor && color != .white
                        try? await api.setLightEffect(
                            id:         light.id,
                            on:         true,
                            brightness: brightness,
                            xy:         useColor ? xy : nil,
                            mirek:      useColor ? nil : (light.supportsColorTemp ? Int(mirekRaw) : nil),
                            duration:   fade
                        )
                    }
                }
            }
            _ = capturedState  // suppress unused warning
            statusMessage = "'\(effect.name)' applied ✓"

        // ── Bridge Native ─────────────────────────────────
        case .bridgeNative(let effectName):
            isRunning        = false
            runningEffectName = nil
            statusMessage    = "Applying '\(effect.name)' on bridge…"

            let nativeBrightness = paramState.sliderValue("brightness", default: 70)
            await withTaskGroup(of: Void.self) { group in
                for light in lights {
                    group.addTask {
                        try? await api.setLightNativeEffect(id: light.id, effect: effectName)
                        if nativeBrightness != 70 {
                            try? await api.setLightBrightness(id: light.id, brightness: nativeBrightness)
                        }
                    }
                }
            }
            statusMessage = "'\(effect.name)' running on bridge ✓ (persists after closing app)"

        // ── Gradual ───────────────────────────────────────
        case .gradual:
            let durationSec  = paramState.durationValue("duration", default: 1800)
            let durationMs   = durationSec * 1000
            let endBrightness = paramState.sliderValue("endBrightness", default: 90)
            let endMirek      = Int(paramState.sliderValue("endMirek", default: 230))
            let turnOff       = paramState.boolValue("turnOff")

            isRunning        = false
            runningEffectName = nil
            statusMessage    = "'\(effect.name)' ramping over \(durationSec / 60)min…"

            await withTaskGroup(of: Void.self) { group in
                for light in lights {
                    group.addTask {
                        try? await api.setLightEffect(
                            id:         light.id,
                            on:         true,
                            brightness: endBrightness,
                            xy:         nil,
                            mirek:      light.supportsColorTemp ? endMirek : nil,
                            duration:   durationMs
                        )
                    }
                }
            }
            statusMessage = "'\(effect.name)' running on bridge ✓ (persists after closing app)"

            if turnOff {
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(durationSec) * 1_000_000_000)
                    await withTaskGroup(of: Void.self) { g in
                        for light in lights { g.addTask { try? await api.setLight(id: light.id, on: false) } }
                    }
                }
            }

        // ── App Driven ────────────────────────────────────
        case .appDriven:
            let palette   = buildPalette(for: effect.id)
            let sync      = paramState.boolValue("sync")
            let flash     = paramState.boolValue("flash")
            let bpm       = paramState.sliderValue("bpm",       default: 120)
            let dutyCycle = paramState.sliderValue("dutyCycle", default: 50) / 100.0
            let speed     = paramState.sliderValue("speed",     default: 5)
            let offDim    = paramState.sliderValue("offDim",    default: 0)
            let freqIdx   = paramState.segmentIndex("frequency")
            let baseColor = paramState.colorValue("baseColor",  default: Color(hue: 0.6, saturation: 0.4, brightness: 0.25))
            let flashColor = paramState.colorValue("flashColor", default: .white)

            isRunning        = true
            runningEffectName = effect.name
            statusMessage    = "'\(effect.name)' running — live effect"

            let loop: @Sendable () async throws -> Void

            switch effect.id {
            case "strobe":
                let onXY  = paramState.colorValue("color", default: .white).toCIExy()
                loop = EffectLoops.strobe(lights: lights, api: api, bpm: bpm,
                                          dutyCycle: dutyCycle, onXY: onXY, offBrightness: offDim)
            case "party":
                loop = EffectLoops.party(lights: lights, api: api, speed: speed,
                                         palette: palette, sync: sync, flash: flash)
            case "thunderstorm":
                loop = EffectLoops.thunderstorm(
                    lights: lights, api: api, frequencyIndex: freqIdx,
                    baseXY: baseColor.toCIExy(), flashXY: flashColor.toCIExy(),
                    baseBrightness: paramState.sliderValue("baseBrightness", default: 15)
                )
            default:
                statusMessage = "Unknown app-driven effect: \(effect.id)"
                isRunning     = false
                return
            }

            await engine.start(effectID: effect.id, loop: loop)
        }
    }

    // MARK: - Stop

    func stop(lights: [LightDisplayItem]) async {
        await engine.stop()
        isRunning        = false
        runningEffectName = nil
        statusMessage    = nil
    }

    // MARK: - Palette Helper

    private func buildPalette(for effectID: String) -> [(Double, Double)] {
        // Use custom palette if set, otherwise fall back to preset
        let colors: [Color]
        if let custom = paramState.palettes["palette"], !custom.isEmpty {
            let presetIdx = paramState.segmentIndex("preset")
            // If preset != Custom, override with preset
            let preset = PresetPalette.allCases[safe: presetIdx] ?? .aurora
            colors = (preset == .custom) ? custom : preset.colors
        } else {
            colors = PresetPalette.aurora.colors
        }
        return colors.map { $0.toCIExy() }
    }
}

// MARK: - Color → CIE xy

extension Color {
    /// Approximate CIE 1931 xy from SwiftUI Color (via UIColor).
    /// Not colour-managed but good enough for Hue API calls.
    func toCIExy() -> (Double, Double) {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)

        // Gamma correction
        let rLin = r > 0.04045 ? pow((r + 0.055) / 1.055, 2.4) : r / 12.92
        let gLin = g > 0.04045 ? pow((g + 0.055) / 1.055, 2.4) : g / 12.92
        let bLin = b > 0.04045 ? pow((b + 0.055) / 1.055, 2.4) : b / 12.92

        // Wide-gamut D65
        let X = rLin * 0.664511 + gLin * 0.154324 + bLin * 0.162028
        let Y = rLin * 0.283881 + gLin * 0.668433 + bLin * 0.047685
        let Z = rLin * 0.000088 + gLin * 0.072310 + bLin * 0.986039

        let sum = X + Y + Z
        guard sum > 0 else { return (0.32, 0.33) }
        return (X / sum, Y / sum)
    }
}

// (safe subscript is declared in another file)
