// HueEffect.swift
// ChromaGlow — Effects Engine
//
// Defines all 14 built-in lighting effects, their parameter schemas,
// execution strategy, and persistence behaviour.
//
// Execution strategies:
//   .oneShot      — Single API call. Persists on bridge forever.
//   .appDriven    — Requires a running Task loop (app must be foregrounded).
//   .bridgeNative — Uses CLIP v2 `effects.effect` field. Persists after app closes.
//   .gradual      — Uses CLIP v2 `dynamics.duration` for a timed ramp. Persists after app closes.

import SwiftUI

// MARK: - EffectParam

/// A single configurable parameter. The UI renders controls dynamically from this schema.
enum EffectParam: Identifiable {
    case slider(     key: String, label: String, value: Double,
                     range: ClosedRange<Double>, step: Double, unit: String)
    case colorSwatch(key: String, label: String, color: Color)
    case colorPalette(key: String, label: String, colors: [Color], maxCount: Int)
    case toggle(     key: String, label: String, value: Bool)
    case segmented(  key: String, label: String, options: [String], selectedIndex: Int)
    case durationPicker(key: String, label: String, seconds: Int, options: [Int], formatter: (Int) -> String)

    var id: String {
        switch self {
        case .slider(let k, _, _, _, _, _):       return k
        case .colorSwatch(let k, _, _):           return k
        case .colorPalette(let k, _, _, _):       return k
        case .toggle(let k, _, _):                return k
        case .segmented(let k, _, _, _):          return k
        case .durationPicker(let k, _, _, _, _):  return k
        }
    }

    var key: String { id }

    var label: String {
        switch self {
        case .slider(_, let l, _, _, _, _):       return l
        case .colorSwatch(_, let l, _):           return l
        case .colorPalette(_, let l, _, _):       return l
        case .toggle(_, let l, _):                return l
        case .segmented(_, let l, _, _):          return l
        case .durationPicker(_, let l, _, _, _):  return l
        }
    }
}

// MARK: - EffectStrategy

enum EffectStrategy {
    /// Single API call — sets brightness, CT, or color. Bridge holds state indefinitely.
    case oneShot
    /// Rapid repeating Task loop on the app side. Cannot survive app backgrounding.
    case appDriven
    /// Sets `effects.effect` field on each bulb. Bridge loops the effect forever.
    case bridgeNative(effectName: String)
    /// Sets target state + `dynamics.duration` in ms. Bridge ramps over that time, persists.
    case gradual
}

// MARK: - HueEffect

struct HueEffect: Identifiable {
    let id:          String
    let name:        String
    let tagline:     String          // short description shown on card
    let icon:        String          // SF Symbol name
    let accentColor: Color
    let category:    EffectCategory
    let strategy:    EffectStrategy
    let params:      [EffectParam]

    /// Whether this effect requires the app to be foregrounded to keep running.
    var requiresForeground: Bool {
        if case .appDriven = strategy { return true }
        return false
    }
}

// MARK: - EffectCategory

enum EffectCategory: String, CaseIterable, Identifiable {
    case atmosphere = "Atmosphere"
    case dynamic    = "Dynamic"
    case gradual    = "Gradual"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .atmosphere: return "sparkles"
        case .dynamic:    return "waveform"
        case .gradual:    return "clock.fill"
        }
    }
}

// MARK: - Preset Palettes

enum PresetPalette: String, CaseIterable {
    case ocean     = "Ocean"
    case sunset    = "Sunset"
    case forest    = "Forest"
    case aurora    = "Aurora"
    case candy     = "Candy"
    case fire      = "Fire"
    case galaxy    = "Galaxy"
    case custom    = "Custom"

    var colors: [Color] {
        switch self {
        case .ocean:
            return [Color(hue: 0.55, saturation: 0.9, brightness: 0.9),
                    Color(hue: 0.60, saturation: 0.8, brightness: 0.7),
                    Color(hue: 0.50, saturation: 0.7, brightness: 0.8)]
        case .sunset:
            return [Color(hue: 0.06, saturation: 1.0, brightness: 1.0),
                    Color(hue: 0.04, saturation: 0.9, brightness: 0.9),
                    Color(hue: 0.75, saturation: 0.8, brightness: 0.7)]
        case .forest:
            return [Color(hue: 0.36, saturation: 0.8, brightness: 0.6),
                    Color(hue: 0.30, saturation: 0.6, brightness: 0.8),
                    Color(hue: 0.10, saturation: 0.7, brightness: 0.5)]
        case .aurora:
            return [Color(hue: 0.45, saturation: 0.9, brightness: 0.8),
                    Color(hue: 0.80, saturation: 0.8, brightness: 0.9),
                    Color(hue: 0.55, saturation: 0.7, brightness: 0.7)]
        case .candy:
            return [Color(hue: 0.92, saturation: 0.8, brightness: 1.0),
                    Color(hue: 0.55, saturation: 0.7, brightness: 1.0),
                    Color(hue: 0.14, saturation: 0.8, brightness: 1.0)]
        case .fire:
            return [Color(hue: 0.07, saturation: 1.0, brightness: 1.0),
                    Color(hue: 0.04, saturation: 0.9, brightness: 0.8),
                    Color(hue: 0.02, saturation: 1.0, brightness: 0.5)]
        case .galaxy:
            return [Color(hue: 0.70, saturation: 0.9, brightness: 0.8),
                    Color(hue: 0.80, saturation: 0.7, brightness: 0.6),
                    Color(hue: 0.60, saturation: 0.8, brightness: 0.9)]
        case .custom:
            return [.white, Color(hue: 0.6, saturation: 0.6, brightness: 0.9), .orange]
        }
    }
}

// MARK: - Effect Library

enum EffectLibrary {

    nonisolated(unsafe) static let all: [HueEffect] = atmosphere + dynamic + gradual

    // ─────────────────────────────────────────────
    // MARK: Atmosphere (one-shot, always persist)
    // ─────────────────────────────────────────────

    nonisolated(unsafe) static let atmosphere: [HueEffect] = [
        HueEffect(
            id: "movie",
            name: "Movie",
            tagline: "Cinematic ambient lighting",
            icon: "film.fill",
            accentColor: Color(hue: 0.06, saturation: 0.9, brightness: 0.95),
            category: .atmosphere,
            strategy: .oneShot,
            params: [
                .slider(key: "brightness", label: "Brightness", value: 30, range: 15...60, step: 1, unit: "%"),
                .slider(key: "mirek",      label: "Warmth",     value: 380, range: 250...500, step: 10, unit: "K"),
                .slider(key: "fade",       label: "Fade In",    value: 2000, range: 0...8000, step: 500, unit: "ms"),
            ]
        ),
        HueEffect(
            id: "focus",
            name: "Focus",
            tagline: "Crisp daylight for deep work",
            icon: "scope",
            accentColor: Color(hue: 0.58, saturation: 0.7, brightness: 1.0),
            category: .atmosphere,
            strategy: .oneShot,
            params: [
                .slider(key: "brightness", label: "Brightness", value: 95, range: 70...100, step: 1, unit: "%"),
                .slider(key: "mirek",      label: "Coolness",   value: 200, range: 153...300, step: 10, unit: "K"),
                .slider(key: "fade",       label: "Fade In",    value: 1000, range: 0...5000, step: 500, unit: "ms"),
            ]
        ),
        HueEffect(
            id: "romance",
            name: "Romance",
            tagline: "Soft, intimate warmth",
            icon: "heart.fill",
            accentColor: Color(hue: 0.94, saturation: 0.8, brightness: 0.95),
            category: .atmosphere,
            strategy: .oneShot,
            params: [
                .slider(key: "brightness", label: "Brightness", value: 20,   range: 5...40,   step: 1,   unit: "%"),
                .colorSwatch(key: "color", label: "Color",      color: Color(hue: 0.94, saturation: 0.75, brightness: 0.8)),
                .slider(key: "fade",       label: "Fade In",    value: 3000, range: 0...8000, step: 500, unit: "ms"),
            ]
        ),
        HueEffect(
            id: "energize",
            name: "Energize",
            tagline: "Full brightness, alert white",
            icon: "bolt.fill",
            accentColor: Color(hue: 0.57, saturation: 0.9, brightness: 1.0),
            category: .atmosphere,
            strategy: .oneShot,
            params: [
                .slider(key: "brightness", label: "Brightness", value: 100,  range: 80...100, step: 1, unit: "%"),
                .slider(key: "mirek",      label: "Color Temp", value: 156,  range: 153...220, step: 5, unit: "K"),
                .slider(key: "fade",       label: "Fade In",    value: 500,  range: 0...3000, step: 250, unit: "ms"),
            ]
        ),
        HueEffect(
            id: "relax",
            name: "Relax",
            tagline: "Warm, easy-on-the-eyes glow",
            icon: "moon.stars.fill",
            accentColor: Color(hue: 0.09, saturation: 0.8, brightness: 0.9),
            category: .atmosphere,
            strategy: .oneShot,
            params: [
                .slider(key: "brightness", label: "Brightness", value: 45,   range: 20...70,  step: 1, unit: "%"),
                .slider(key: "mirek",      label: "Warmth",     value: 420,  range: 300...500, step: 10, unit: "K"),
                .slider(key: "fade",       label: "Fade In",    value: 2000, range: 0...6000, step: 500, unit: "ms"),
            ]
        ),
        HueEffect(
            id: "reading",
            name: "Reading",
            tagline: "Balanced light, easy on the eyes",
            icon: "book.fill",
            accentColor: Color(hue: 0.12, saturation: 0.6, brightness: 1.0),
            category: .atmosphere,
            strategy: .oneShot,
            params: [
                .slider(key: "brightness", label: "Brightness", value: 75,  range: 50...100, step: 1,  unit: "%"),
                .slider(key: "mirek",      label: "Color Temp", value: 280, range: 200...380, step: 10, unit: "K"),
                .slider(key: "fade",       label: "Fade In",    value: 1000, range: 0...4000, step: 500, unit: "ms"),
            ]
        ),
    ]

    // ─────────────────────────────────────────────
    // MARK: Dynamic (bridge-native OR app-driven)
    // ─────────────────────────────────────────────

    nonisolated(unsafe) static let dynamic: [HueEffect] = [
        HueEffect(
            id: "colorloop",
            name: "Color Loop",
            tagline: "Endless cycling through your palette",
            icon: "circle.righthalf.filled",
            accentColor: Color(hue: 0.75, saturation: 0.8, brightness: 0.95),
            category: .dynamic,
            strategy: .bridgeNative(effectName: "colorloop"),
            params: [
                .slider(key: "speed",   label: "Speed",  value: 5,  range: 1...10, step: 0.5, unit: ""),
                .colorPalette(key: "palette", label: "Palette", colors: PresetPalette.aurora.colors, maxCount: 6),
                .segmented(key: "preset", label: "Preset", options: PresetPalette.allCases.map(\.rawValue), selectedIndex: 3),
                .toggle(key: "sync",    label: "Sync All Lights", value: true),
            ]
        ),
        HueEffect(
            id: "candle",
            name: "Candle",
            tagline: "Gentle organic flicker",
            icon: "flame.fill",
            accentColor: Color(hue: 0.08, saturation: 0.9, brightness: 0.95),
            category: .dynamic,
            strategy: .bridgeNative(effectName: "candle"),
            params: [
                .colorSwatch(key: "color",       label: "Flame Color",  color: Color(hue: 0.08, saturation: 0.85, brightness: 0.9)),
                .slider(key: "intensity",         label: "Flicker Intensity", value: 6, range: 1...10, step: 0.5, unit: ""),
                .slider(key: "minBrightness",     label: "Min Brightness",    value: 20, range: 5...60, step: 1, unit: "%"),
                .segmented(key: "speed",          label: "Speed",  options: ["Slow", "Medium", "Fast"], selectedIndex: 1),
            ]
        ),
        HueEffect(
            id: "fire",
            name: "Fire",
            tagline: "Intense, crackling fire simulation",
            icon: "flame",
            accentColor: Color(hue: 0.04, saturation: 1.0, brightness: 1.0),
            category: .dynamic,
            strategy: .bridgeNative(effectName: "fire"),
            params: [
                .slider(key: "intensity",    label: "Intensity",  value: 7,  range: 1...10, step: 0.5, unit: ""),
                .slider(key: "brightness",   label: "Max Brightness", value: 80, range: 30...100, step: 1, unit: "%"),
            ]
        ),
        HueEffect(
            id: "prism",
            name: "Prism",
            tagline: "Shifting rainbow spectrum",
            icon: "triangle",
            accentColor: Color(hue: 0.78, saturation: 0.85, brightness: 0.95),
            category: .dynamic,
            strategy: .bridgeNative(effectName: "prism"),
            params: [
                .slider(key: "speed",      label: "Speed",      value: 5, range: 1...10, step: 0.5, unit: ""),
                .slider(key: "brightness", label: "Brightness", value: 70, range: 30...100, step: 1, unit: "%"),
            ]
        ),
        HueEffect(
            id: "sparkle",
            name: "Sparkle",
            tagline: "Twinkling random flashes",
            icon: "sparkles",
            accentColor: Color(hue: 0.14, saturation: 0.7, brightness: 1.0),
            category: .dynamic,
            strategy: .bridgeNative(effectName: "sparkle"),
            params: [
                .slider(key: "speed",      label: "Sparkle Rate", value: 5,  range: 1...10, step: 0.5, unit: ""),
                .slider(key: "brightness", label: "Brightness",   value: 80, range: 30...100, step: 1, unit: "%"),
                .colorSwatch(key: "color", label: "Sparkle Color", color: .white),
            ]
        ),
        HueEffect(
            id: "strobe",
            name: "Strobe",
            tagline: "High-speed flash — full control",
            icon: "bolt.trianglebadge.exclamationmark.fill",
            accentColor: Color(hue: 0.60, saturation: 0.8, brightness: 1.0),
            category: .dynamic,
            strategy: .appDriven,
            params: [
                .slider(key: "bpm",        label: "Speed (BPM)",    value: 120,  range: 30...480, step: 10, unit: "BPM"),
                .slider(key: "dutyCycle",  label: "Duty Cycle",     value: 50,   range: 10...90, step: 5, unit: "%"),
                .colorSwatch(key: "color", label: "Flash Color",    color: .white),
                .slider(key: "offDim",     label: "Off Brightness", value: 0,    range: 0...30, step: 1, unit: "%"),
            ]
        ),
        HueEffect(
            id: "party",
            name: "Party",
            tagline: "Wild colors, pure chaos",
            icon: "party.popper.fill",
            accentColor: Color(hue: 0.85, saturation: 0.9, brightness: 1.0),
            category: .dynamic,
            strategy: .appDriven,
            params: [
                .slider(key: "speed",    label: "Speed",           value: 5,  range: 1...10, step: 0.5, unit: ""),
                .colorPalette(key: "palette", label: "Color Palette", colors: PresetPalette.candy.colors, maxCount: 6),
                .segmented(key: "preset", label: "Preset", options: PresetPalette.allCases.map(\.rawValue), selectedIndex: 4),
                .toggle(key: "sync",     label: "Sync All Lights", value: false),
                .toggle(key: "flash",    label: "Occasional Flash",value: true),
            ]
        ),
        HueEffect(
            id: "thunderstorm",
            name: "Thunderstorm",
            tagline: "Dramatic lightning + storm ambiance",
            icon: "cloud.bolt.rain.fill",
            accentColor: Color(hue: 0.60, saturation: 0.55, brightness: 0.85),
            category: .dynamic,
            strategy: .appDriven,
            params: [
                .segmented(key: "frequency",    label: "Lightning Frequency", options: ["Rare", "Occasional", "Frequent"], selectedIndex: 1),
                .colorSwatch(key: "baseColor",  label: "Ambient Color", color: Color(hue: 0.60, saturation: 0.4, brightness: 0.25)),
                .colorSwatch(key: "flashColor", label: "Flash Color",   color: Color(hue: 0.62, saturation: 0.1, brightness: 1.0)),
                .slider(key: "baseBrightness",  label: "Ambient Brightness", value: 15, range: 5...40, step: 1, unit: "%"),
            ]
        ),
    ]

    // ─────────────────────────────────────────────
    // MARK: Gradual (bridge-native ramps via duration)
    // ─────────────────────────────────────────────

    nonisolated(unsafe) static let gradual: [HueEffect] = [
        HueEffect(
            id: "sunrise",
            name: "Sunrise",
            tagline: "Gentle dawn — warm to bright daylight",
            icon: "sunrise.fill",
            accentColor: Color(hue: 0.10, saturation: 0.85, brightness: 1.0),
            category: .gradual,
            strategy: .gradual,
            params: [
                .durationPicker(key: "duration", label: "Duration",
                                seconds: 1800, options: [900, 1800, 2700, 3600],
                                formatter: { "\($0 / 60) min" }),
                .slider(key: "startBrightness", label: "Start Brightness",  value: 1,   range: 0...15,  step: 1,  unit: "%"),
                .slider(key: "endBrightness",   label: "End Brightness",    value: 90,  range: 60...100, step: 1, unit: "%"),
                .slider(key: "startMirek",      label: "Start Warmth",      value: 490, range: 400...500, step: 10, unit: "K"),
                .slider(key: "endMirek",        label: "End Color Temp",    value: 230, range: 153...380, step: 10, unit: "K"),
            ]
        ),
        HueEffect(
            id: "sunset",
            name: "Sunset",
            tagline: "Fade to warm dusk, then darkness",
            icon: "sunset.fill",
            accentColor: Color(hue: 0.06, saturation: 0.95, brightness: 0.95),
            category: .gradual,
            strategy: .gradual,
            params: [
                .durationPicker(key: "duration", label: "Duration",
                                seconds: 1800, options: [900, 1800, 3600, 5400],
                                formatter: { "\($0 / 60) min" }),
                .slider(key: "endBrightness",   label: "End Brightness",    value: 10, range: 0...30,  step: 1, unit: "%"),
                .slider(key: "endMirek",        label: "End Warmth",        value: 490, range: 380...500, step: 10, unit: "K"),
                .toggle(key: "turnOff",         label: "Turn Off at End",   value: true),
            ]
        ),
        HueEffect(
            id: "winddown",
            name: "Wind Down",
            tagline: "Slow dim to near-dark for sleep",
            icon: "moon.zzz.fill",
            accentColor: Color(hue: 0.70, saturation: 0.6, brightness: 0.75),
            category: .gradual,
            strategy: .gradual,
            params: [
                .durationPicker(key: "duration", label: "Duration",
                                seconds: 1200, options: [600, 1200, 1800],
                                formatter: { "\($0 / 60) min" }),
                .slider(key: "endBrightness",   label: "End Brightness",    value: 3,   range: 0...15,  step: 1, unit: "%"),
                .slider(key: "endMirek",        label: "End Warmth",        value: 500, range: 420...500, step: 10, unit: "K"),
                .toggle(key: "turnOff",         label: "Turn Off at End",   value: false),
            ]
        ),
    ]
}
