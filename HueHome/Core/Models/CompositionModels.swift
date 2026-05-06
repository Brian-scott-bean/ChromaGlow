// CompositionModels.swift
// ChromaGlow — Composer v0.17.0
//
// Data models for the Composer dynamic scene creation engine.
// Four independent layers (Palette, Motion, Envelope, Reaction) compose
// to produce per-light CIE xy + brightness output at 25fps.

import SwiftUI

// MARK: - CodableColor (CIE 1931 xy)

/// A Codable wrapper for CIE 1931 xy chromaticity coordinates.
/// Used by PaletteConfig to store colors in a format the bridge understands natively.
struct CodableColor: Codable, Equatable {
    var x: Double  // CIE 1931 x (0.0–0.8)
    var y: Double  // CIE 1931 y (0.0–0.9)

    /// D65 white point — used as default / fallback.
    static let white = CodableColor(x: 0.3127, y: 0.3290)

    /// Warm white (~2700K candle).
    static let warmWhite = CodableColor(x: 0.4578, y: 0.4101)

    /// Create from SwiftUI Color via HueColorUtils.
    static func from(color: Color) -> CodableColor {
        let uiColor = UIColor(color)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
        uiColor.getHue(&h, saturation: &s, brightness: &b, alpha: nil)
        let xy = HueColorUtils.xyFrom(hue: Double(h), saturation: Double(s), brightness: Double(b))
        return CodableColor(x: xy.x, y: xy.y)
    }

    /// Linear interpolation between two CIE xy colors.
    func lerp(to other: CodableColor, t: Double) -> CodableColor {
        let t = min(1, max(0, t))
        return CodableColor(
            x: x + (other.x - x) * t,
            y: y + (other.y - y) * t
        )
    }
}

// MARK: - PaletteConfig

struct PaletteConfig: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable {
        case solid
        case gradient
        case spectrum
        case temperature
    }

    var mode: Mode = .gradient
    var color1: CodableColor = CodableColor(x: 0.5500, y: 0.3900)  // warm amber
    var color2: CodableColor = CodableColor(x: 0.6400, y: 0.3300)  // deep red
    var color3: CodableColor?
    var hueShift: Double = 0        // -180 to 180 degrees
    var saturation: Double = 100    // 0-100%
    var temperature: Int = 366      // 153-500 mirek (only used in .temperature mode)
    var randomize: Bool = false

    /// Resolve the output CIE xy color for a given phase position (0.0–1.0).
    /// Phase comes from the Motion layer — it says "where in the palette is this light?"
    func color(at phase: Double) -> CodableColor {
        let p = min(1, max(0, phase))

        switch mode {
        case .solid:
            return color1

        case .gradient:
            if let c3 = color3 {
                // 3-color gradient: c1 → c2 → c3
                if p < 0.5 {
                    return color1.lerp(to: c2, t: p * 2.0)
                } else {
                    return color2.lerp(to: c3, t: (p - 0.5) * 2.0)
                }
            }
            return color1.lerp(to: color2, t: p)

        case .spectrum:
            // Full hue wheel: phase 0–1 → hue 0–360°
            let hue = (p + hueShift / 360.0).truncatingRemainder(dividingBy: 1.0)
            let adjustedHue = hue < 0 ? hue + 1.0 : hue
            let sat = saturation / 100.0
            let xy = HueColorUtils.xyFrom(hue: adjustedHue, saturation: sat, brightness: 1.0)
            return CodableColor(x: xy.x, y: xy.y)

        case .temperature:
            // Temperature mode ignores phase — uniform mirek across all lights
            // Return a warm xy approximation based on mirek
            let normalized = Double(temperature - 153) / Double(500 - 153)  // 0=cool, 1=warm
            let coolXY = CodableColor(x: 0.3127, y: 0.3290)   // 6500K
            let warmXY = CodableColor(x: 0.5268, y: 0.4133)   // 2000K
            return coolXY.lerp(to: warmXY, t: normalized)
        }
    }

    /// Convenience accessor for the private lerp helper name used in gradient.
    private var c2: CodableColor { color2 }
}

// MARK: - MotionConfig

struct MotionConfig: Codable, Equatable {
    enum Pattern: String, Codable, CaseIterable {
        case `static`
        case cascade
        case wave
        case scatter
        case bounce
    }

    var pattern: Pattern = .cascade
    var speed: Double = 40          // 0-100 (maps to cycle period)
    var forward: Bool = true
    var spread: Double = 70         // 0-100
    var offset: Double = 50         // 0-100 (phase stagger between lights)
    var mirror: Bool = false

    /// Compute the phase position (0.0–1.0) for a specific light at a given time.
    /// This phase is fed into PaletteConfig.color(at:) to determine what color the light should be.
    func phase(lightIndex: Int, total: Int, time: Double) -> Double {
        guard total > 0 else { return 0 }

        // Speed 0-100 → period 20s (slowest) to 0.5s (fastest)
        let period = 20.0 - (speed / 100.0) * 19.5
        let normalizedTime = time / max(0.01, period)

        let position = Double(lightIndex) / Double(max(1, total - 1))
        let direction: Double = forward ? 1.0 : -1.0
        let stagger = (offset / 100.0)

        switch pattern {
        case .static:
            // Each light gets a fixed position in the palette (no animation)
            return position

        case .cascade:
            // Sequential sweep across lights
            let raw = (normalizedTime * direction + position * stagger)
                .truncatingRemainder(dividingBy: 1.0)
            return raw < 0 ? raw + 1.0 : raw

        case .wave:
            // Sinusoidal oscillation
            let sine = sin(2.0 * .pi * (normalizedTime * direction + position * stagger))
            return (sine + 1.0) / 2.0  // normalize to 0–1

        case .scatter:
            // Each light gets pseudo-random timing based on its index
            let seed = Double(lightIndex * 7919 + 1)  // prime-based seed per light
            let noise = sin(seed + normalizedTime * direction * 6.283)
            return (noise + 1.0) / 2.0

        case .bounce:
            // Ping-pong across light array
            let raw = (normalizedTime * direction * 2.0 + position * stagger)
                .truncatingRemainder(dividingBy: 2.0)
            let absRaw = abs(raw)
            return absRaw <= 1.0 ? absRaw : 2.0 - absRaw
        }
    }
}

// MARK: - EnvelopeConfig

struct EnvelopeConfig: Codable, Equatable {
    enum Shape: String, Codable, CaseIterable {
        case steady
        case breathe
        case heartbeat
        case pulse
        case flicker
        case swell
    }

    var shape: Shape = .breathe
    var bpm: Double = 60            // 20-240
    var depth: Double = 50          // 0-100 (how deep brightness dips)
    var attack: Double = 50         // 0-100 (rise speed)
    var decay: Double = 50          // 0-100 (fall speed)
    var dutyCycle: Double = 50      // 10-90 (on-time ratio, for pulse)
    var minBrightness: Double = 10  // 0-50 (floor)
    var maxBrightness: Double = 100 // 50-100 (ceiling)

    /// Compute brightness (0.0–1.0) at the given time.
    func value(at time: Double) -> Double {
        let minB = minBrightness / 100.0
        let maxB = maxBrightness / 100.0
        let d = depth / 100.0

        switch shape {
        case .steady:
            return maxB

        case .breathe:
            // Smooth cosine wave
            let period = 60.0 / max(1, bpm)
            let t = time.truncatingRemainder(dividingBy: period) / period
            let wave = (1.0 + cos(2.0 * .pi * t)) / 2.0  // 1→0→1
            return minB + (maxB - minB) * (1.0 - d + d * wave)

        case .heartbeat:
            // Double-peaked Gaussian (lub-dub)
            let period = 60.0 / max(1, bpm)
            let phase = time.truncatingRemainder(dividingBy: period) / period
            let lub = exp(-pow((phase - 0.15) / 0.04, 2))
            let dub = exp(-pow((phase - 0.35) / 0.06, 2)) * 0.55
            let envelope = min(1.0, lub + dub)
            return minB + (maxB - minB) * (1.0 - d + d * envelope)

        case .pulse:
            // Square wave with duty cycle
            let period = 60.0 / max(1, bpm)
            let t = time.truncatingRemainder(dividingBy: period) / period
            let duty = dutyCycle / 100.0
            let isOn = t < duty
            return isOn ? maxB : minB + (maxB - minB) * (1.0 - d)

        case .flicker:
            // Organic noise (candle-like) using layered sine waves
            let t = time
            let noise = sin(t * 12.9898) * 0.3 +
                        sin(t * 7.233 + 1.5) * 0.3 +
                        sin(t * 23.14 + 3.7) * 0.2 +
                        sin(t * 3.891 + 0.3) * 0.2
            let normalized = (noise + 1.0) / 2.0
            return minB + (maxB - minB) * (1.0 - d + d * normalized)

        case .swell:
            // Asymmetric rise/fall using attack/decay
            let period = 60.0 / max(1, bpm)
            let t = time.truncatingRemainder(dividingBy: period) / period
            let attackRatio = attack / 100.0
            let riseEnd = max(0.01, attackRatio * 0.8)

            var envelope: Double
            if t < riseEnd {
                // Rising phase
                envelope = t / riseEnd
            } else {
                // Falling phase
                let fallT = (t - riseEnd) / (1.0 - riseEnd)
                let decayRate = 1.0 + (decay / 100.0) * 4.0
                envelope = pow(1.0 - fallT, decayRate)
            }
            return minB + (maxB - minB) * (1.0 - d + d * envelope)
        }
    }
}

// MARK: - ReactionConfig

struct ReactionConfig: Codable, Equatable {
    enum Source: String, Codable, CaseIterable {
        case none
        case micAmplitude = "mic_amplitude"
        case micBass = "mic_bass"
        case micMid = "mic_mid"
        case micTreble = "mic_treble"
        case tapTempo = "tap_tempo"
    }

    enum Target: String, Codable, CaseIterable, Hashable {
        case brightness
        case color
        case speed
    }

    var source: Source = .none
    var sensitivity: Double = 70    // 0-100
    var targets: [Target] = [.brightness]
    var smoothing: Double = 30      // 0-100 (response lag)
    var intensity: Double = 70      // 0-100 (override strength)
    var threshold: Double = 10      // 0-100 (noise gate)

    /// Whether this reaction config requires microphone access.
    var requiresMic: Bool {
        switch source {
        case .micAmplitude, .micBass, .micMid, .micTreble: return true
        case .none, .tapTempo: return false
        }
    }

    /// Apply the reaction modifier to a base brightness value.
    /// audioLevel: 0.0–1.0 (normalized amplitude from mic or tap).
    func apply(baseBrightness: Double, audioLevel: Float, time: Double) -> Double {
        guard source != .none else { return baseBrightness }

        let level = Double(audioLevel)
        let sens = sensitivity / 100.0
        let thresh = threshold / 100.0
        let inten = intensity / 100.0

        // Apply threshold (noise gate)
        let gated = max(0, level - thresh) / max(0.01, 1.0 - thresh)

        // Apply sensitivity
        let reactive = min(1.0, gated * (0.5 + sens * 1.5))

        // Blend: base * (1 - intensity) + base * reactive * intensity
        if targets.contains(.brightness) {
            return baseBrightness * (1.0 - inten + inten * reactive)
        }
        return baseBrightness
    }
}

// MARK: - PresetCategory

enum PresetCategory: String, Codable, CaseIterable, Identifiable {
    case all        = "All"
    case ambient    = "Ambient"
    case energetic  = "Energetic"
    case holiday    = "Holiday"
    case myCreations = "My Creations"

    var id: String { rawValue }
}

// MARK: - CompositionPreset

struct CompositionPreset: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var icon: String              // SF Symbol name
    var accentColorHex: String    // Card accent color (hex string)
    var isBuiltIn: Bool           // Starter presets can't be permanently deleted
    var category: PresetCategory
    var seasonMonths: [Int]?      // e.g. [10] for October, [12, 1, 2] for winter

    var palette: PaletteConfig
    var motion: MotionConfig
    var envelope: EnvelopeConfig
    var reaction: ReactionConfig

    var createdAt: Date
    var updatedAt: Date

    /// Whether this preset is seasonally relevant right now.
    var isInSeason: Bool {
        guard let months = seasonMonths else { return false }
        let currentMonth = Calendar.current.component(.month, from: Date())
        return months.contains(currentMonth)
    }
}
