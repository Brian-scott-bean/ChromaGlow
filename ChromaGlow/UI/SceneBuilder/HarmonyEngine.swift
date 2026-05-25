// HarmonyEngine.swift
// ChromaGlow — P2 Scene Color Builder
//
// Pure color-theory logic for harmonic palette generation.
// No UI — takes a root hue + harmony rule and returns
// an array of (hue, saturation, brightness) tuples, one per light.
//
// Supported rules:
//   • complementary    — 2 colors, 180° apart
//   • triadic          — 3 colors, 120° apart
//   • analogous        — 3–5 colors, 30° apart
//   • splitComplementary — 3 colors (root + 2 flanking the complement)
//   • tetradic         — 4 colors, 90° apart

import Foundation

// MARK: - HarmonyRule

enum HarmonyRule: String, CaseIterable, Identifiable {
    case none               = "None"
    case complementary      = "Comp."
    case triadic            = "Triad"
    case analogous          = "Analog."
    case splitComplementary = "Split"
    case tetradic           = "Tetra"
    case monochromatic      = "Mono"
    case doubleComp         = "Dbl Comp."

    var id: String { rawValue }

    /// SF Symbol for the harmony picker chip.
    var icon: String {
        switch self {
        case .none:               return "paintbrush.fill"
        case .complementary:      return "circle.lefthalf.filled"
        case .triadic:            return "triangle.fill"
        case .analogous:          return "rainbow"
        case .splitComplementary: return "arrow.triangle.branch"
        case .tetradic:           return "square.fill"
        case .monochromatic:      return "circle.circle.fill"
        case .doubleComp:         return "square.split.2x2.fill"
        }
    }

    /// Number of unique anchor hues this rule produces.
    var anchorCount: Int {
        switch self {
        case .none:               return 1
        case .complementary:      return 2
        case .triadic:            return 3
        case .analogous:          return 3
        case .splitComplementary: return 3
        case .tetradic:           return 4
        case .monochromatic:      return 1
        case .doubleComp:         return 4
        }
    }
}

// MARK: - HarmonyEngine

enum HarmonyEngine {

    /// A single color in the palette.
    struct PaletteColor {
        var hue: Double         // 0–1 (SwiftUI convention)
        var saturation: Double  // 0–1
        var brightness: Double  // 0–1 (used for relative scaling; actual brightness comes from the pad)
    }

    // ──────────────────────────────────────────────
    // MARK: - Core: Compute Anchor Hues
    // ──────────────────────────────────────────────

    /// Returns the anchor hue offsets (0–1) for a given harmony rule.
    /// These are the "pure" hue positions on the color wheel.
    static func anchorHues(for rule: HarmonyRule, rootHue: Double) -> [Double] {
        switch rule {
        case .none, .monochromatic:
            return [rootHue]
        case .complementary:
            return [rootHue, wrap(rootHue + 0.5)]
        case .triadic:
            return [rootHue, wrap(rootHue + 1.0/3.0), wrap(rootHue + 2.0/3.0)]
        case .analogous:
            return [wrap(rootHue - 1.0/12.0), rootHue, wrap(rootHue + 1.0/12.0)]
        case .splitComplementary:
            return [rootHue, wrap(rootHue + 5.0/12.0), wrap(rootHue + 7.0/12.0)]
        case .tetradic:
            return [rootHue, wrap(rootHue + 0.25), wrap(rootHue + 0.5), wrap(rootHue + 0.75)]
        case .doubleComp:
            // Two complementary pairs: root ↔ complement, +60° ↔ its complement
            return [rootHue, wrap(rootHue + 1.0/6.0), wrap(rootHue + 0.5), wrap(rootHue + 2.0/3.0)]
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Distribute Colors Across Lights
    // ──────────────────────────────────────────────

    /// Generate a palette of `count` colors using the given harmony rule.
    ///
    /// When the number of lights exceeds the anchor count, extra lights are
    /// distributed evenly across the anchors with slight saturation/brightness
    /// variation so they remain visually distinct.
    ///
    /// - Parameters:
    ///   - rule:       The harmony rule to apply.
    ///   - rootHue:    Root hue (0–1).
    ///   - saturation: Base saturation from the color pad (0–1).
    ///   - brightness: Base brightness from the color pad (0–1).
    ///   - count:      Number of lights to generate colors for.
    /// - Returns: Array of `PaletteColor` (one per light, in order).
    static func palette(
        rule: HarmonyRule,
        rootHue: Double,
        saturation: Double,
        brightness: Double,
        count: Int
    ) -> [PaletteColor] {
        guard count > 0 else { return [] }

        // "None" = all lights get the same color
        if rule == .none {
            return Array(repeating: PaletteColor(
                hue: rootHue, saturation: saturation, brightness: brightness
            ), count: count)
        }

        // "Monochromatic" = same hue, varying saturation + brightness
        if rule == .monochromatic {
            var result: [PaletteColor] = []
            for i in 0..<count {
                let t = count > 1 ? Double(i) / Double(count - 1) : 0.5
                // Vary saturation from 40% to 100%, brightness from 100% to 50%
                let sat = 0.4 + t * 0.6 * saturation
                let bri = brightness * (1.0 - t * 0.5)
                result.append(PaletteColor(hue: rootHue, saturation: sat, brightness: max(0.2, bri)))
            }
            return result
        }

        let anchors = anchorHues(for: rule, rootHue: rootHue)

        // If lights == anchors, one-to-one mapping
        if count == anchors.count {
            return anchors.map { PaletteColor(hue: $0, saturation: saturation, brightness: brightness) }
        }

        // Distribute lights across anchors evenly
        var result: [PaletteColor] = []
        for i in 0..<count {
            let anchorIdx = i % anchors.count
            let hue = anchors[anchorIdx]

            // Slight variation for duplicate anchors
            let dupIndex = i / anchors.count  // 0 for first round, 1 for second, etc.
            let satVar = max(0.2, saturation - Double(dupIndex) * 0.12)
            let briVar = max(0.3, brightness - Double(dupIndex) * 0.10)

            result.append(PaletteColor(hue: hue, saturation: satVar, brightness: briVar))
        }

        return result
    }

    // ──────────────────────────────────────────────
    // MARK: - Helpers
    // ──────────────────────────────────────────────

    /// Wrap a hue value to the 0–1 range.
    private static func wrap(_ value: Double) -> Double {
        let v = value.truncatingRemainder(dividingBy: 1.0)
        return v < 0 ? v + 1.0 : v
    }
}
