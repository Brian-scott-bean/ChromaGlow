// BridgeDynamicSceneExporter.swift
// ChromaGlow — Composer → native Hue dynamic scene
//
// Maps a Composer `PaletteConfig` onto the colour palette a CLIP v2 dynamic
// scene cycles. Once uploaded the bridge runs the scene by itself: app closed,
// phone away, forever. That makes this the third engine, alongside DTLS
// streaming and per-light REST — and the only one that survives the app.
//
// The bridge crossfades between palette entries on its own, so the palette is a
// set of anchors, not a rendered animation. What matters is that the anchors are
// the colours the user actually sees in the Composer:
//
//   • solid       — one colour. There is nothing to cycle; `willAnimate` is false.
//   • gradient    — the 2 or 3 authored stops.
//   • spectrum    — samples around the hue wheel, honouring hueShift/saturation.
//   • temperature — one warm/cool point, derived from mirek.
//
// Everything is sampled through `PaletteConfig.color(at:)`, which is the single
// source of truth for "what colour does this palette show at phase p". Reading
// `color1`/`color2` directly — as the export used to — is wrong for spectrum and
// temperature, where those fields are not the displayed colours at all.

import Foundation

enum BridgeDynamicSceneExporter {

    /// CLIP v2 caps a scene's colour palette at 9 entries.
    static let maxPalettePoints = 9

    /// How finely the hue wheel is sampled in spectrum mode. Nine points is the
    /// cap and gives ~40° between anchors, which the bridge's crossfade reads as
    /// a continuous rainbow.
    static let spectrumSampleCount = 9

    /// Two xy points closer than this are the same colour to the eye; emitting
    /// both wastes a palette slot and makes the bridge pause on a colour.
    static let duplicateEpsilon = 0.004

    struct Recipe: Equatable {
        /// Gamut-clamped xy anchors, 1...9 entries.
        let palette: [PaletteXY]
        /// 0...1, what CLIP calls `speed`.
        let speed: Double
        /// 1...100.
        let brightness: Double

        /// A one-colour palette cannot cycle. The caller should say so rather
        /// than promising a scene that "loops on the bridge".
        var willAnimate: Bool { palette.count >= 2 }
    }

    struct PaletteXY: Equatable {
        let x: Double
        let y: Double
    }

    // MARK: - Recipe

    static func recipe(for preset: CompositionPreset, gamut: HueColorUtils.Gamut) -> Recipe {
        recipe(palette: preset.palette, motion: preset.motion, envelope: preset.envelope, gamut: gamut)
    }

    static func recipe(
        palette: PaletteConfig,
        motion: MotionConfig,
        envelope: EnvelopeConfig,
        gamut: HueColorUtils.Gamut
    ) -> Recipe {
        Recipe(
            palette: palettePoints(for: palette, gamut: gamut),
            speed: speed(for: motion),
            brightness: brightness(for: envelope)
        )
    }

    // MARK: - Palette

    static func palettePoints(for palette: PaletteConfig, gamut: HueColorUtils.Gamut) -> [PaletteXY] {
        let phases: [Double]
        switch palette.mode {
        case .solid, .temperature:
            // `color(at:)` ignores phase in both modes.
            phases = [0]

        case .gradient:
            // The authored stops. color(at:) walks c1 → c2 (→ c3) across 0...1,
            // so the stops land at these phases and the bridge fills between.
            phases = palette.color3 == nil ? [0, 1] : [0, 0.5, 1]

        case .spectrum:
            // Exclude 1.0: the wheel is periodic, so phase 1 repeats phase 0.
            phases = (0..<spectrumSampleCount).map { Double($0) / Double(spectrumSampleCount) }
        }

        let sampled = phases.map { phase -> PaletteXY in
            let color = palette.color(at: phase)
            let clamped = HueColorUtils.clampXYToGamut(x: color.x, y: color.y, gamut: gamut)
            return PaletteXY(x: clamped.x, y: clamped.y)
        }

        return Array(deduplicated(sampled).prefix(maxPalettePoints))
    }

    /// Drops consecutive near-identical anchors, and the wrap-around duplicate a
    /// periodic palette can produce between its last and first point.
    static func deduplicated(_ points: [PaletteXY]) -> [PaletteXY] {
        var result: [PaletteXY] = []
        for point in points where !result.contains(where: { isSameColor($0, point) }) {
            result.append(point)
        }
        return result
    }

    static func isSameColor(_ a: PaletteXY, _ b: PaletteXY) -> Bool {
        abs(a.x - b.x) < duplicateEpsilon && abs(a.y - b.y) < duplicateEpsilon
    }

    // MARK: - Speed & brightness

    /// Composer speed is 0...100; CLIP's is 0...1. The floor is not cosmetic: a
    /// dynamic scene at speed 0 stops cycling, which is not what "slow" means.
    static func speed(for motion: MotionConfig) -> Double {
        min(1.0, max(0.1, motion.speed / 100.0))
    }

    /// The envelope's ceiling. A bridge-cycled palette has no envelope of its
    /// own — it holds one brightness — so the ceiling is the honest choice: it
    /// is the brightness the scene reaches at its peak.
    static func brightness(for envelope: EnvelopeConfig) -> Double {
        min(100.0, max(1.0, envelope.maxBrightness))
    }

    // MARK: - Eligibility

    /// Why a preset cannot become a bridge-native scene, or nil if it can.
    /// A mic-reactive preset is the real exclusion: the bridge cannot hear.
    static func ineligibilityReason(for preset: CompositionPreset) -> String? {
        if preset.reaction.requiresMic {
            return "Scenes that react to sound need the app running — the bridge can't hear."
        }
        return nil
    }

    /// A one-colour palette has nothing to cycle. Saying "loops on the bridge"
    /// anyway would be a promise the scene cannot keep.
    static func successMessage(name: String, willAnimate: Bool) -> String {
        willAnimate
            ? "'\(name)' saved as a dynamic scene ✓ — find it in Scenes"
            : "'\(name)' saved as a static scene ✓ — a single colour has nothing to cycle"
    }
}
