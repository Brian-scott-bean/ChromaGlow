// HueColorUtils.swift
// ChromaGlow — Epic 3 / Story 3.3
//
// Bidirectional conversion between Hue's CIE 1931 xy colour space and SwiftUI Color/HSB.
// Uses the Wide Colour D65 matrix recommended by the Philips Hue developer docs.
//
// Reference: https://developers.meethue.com/develop/application-design-guidance/color-conversion-formulas-rgb-to-xy-and-back/

import SwiftUI

// MARK: - HueColorUtils

enum HueColorUtils {
    enum Gamut: String {
        case a = "A"
        case b = "B"
        case c = "C"
    }

    private typealias XY = (x: Double, y: Double)

    private static let gamutA: (r: XY, g: XY, b: XY) = (
        r: (0.704, 0.296),
        g: (0.2151, 0.7106),
        b: (0.138, 0.080)
    )

    private static let gamutB: (r: XY, g: XY, b: XY) = (
        r: (0.675, 0.322),
        g: (0.4091, 0.518),
        b: (0.167, 0.040)
    )

    private static let gamutC: (r: XY, g: XY, b: XY) = (
        r: (0.692, 0.308),
        g: (0.170, 0.700),
        b: (0.153, 0.048)
    )

    // ──────────────────────────────────────────────
    // MARK: - HSB → CIE xy
    // ──────────────────────────────────────────────

    /// Convert SwiftUI hue (0–1), saturation (0–1), brightness (0–1) to Hue CIE xy.
    static func xyFrom(hue: Double, saturation: Double, brightness: Double) -> (x: Double, y: Double) {
        // 1. HSB → sRGB
        let color = UIColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: nil)

        // 2. Gamma correction (sRGB → linear)
        let rL = linearise(Double(r))
        let gL = linearise(Double(g))
        let bL = linearise(Double(b))

        // 3. Linear RGB → XYZ (Wide Colour D65 matrix)
        let X = rL * 0.664511 + gL * 0.154324 + bL * 0.162028
        let Y = rL * 0.283881 + gL * 0.668433 + bL * 0.047685
        let Z = rL * 0.000088 + gL * 0.072310 + bL * 0.986039

        let sum = X + Y + Z
        guard sum > 0 else { return (0.3127, 0.3290) }   // D65 white point fallback

        return (X / sum, Y / sum)
    }

    /// Clamp a CIE xy point to a Hue bulb gamut triangle.
    static func clampXYToGamut(x: Double, y: Double, gamut: Gamut) -> (x: Double, y: Double) {
        let p = (x: x.clamped(0, 1), y: y.clamped(0, 1))
        let triangle = triangle(for: gamut)
        if isInsideTriangle(point: p, triangle: triangle) {
            return p
        }
        return closestPointOnTriangle(point: p, triangle: triangle)
    }

    /// Convert a HarmonyEngine palette color to a gamut-clamped CodableColor.
    /// Used by the Composer Palette tab to write harmony-derived colors into
    /// the composition's PaletteConfig (color1/color2/color3).
    static func codableColor(
        from palette: HarmonyEngine.PaletteColor,
        gamut: Gamut
    ) -> CodableColor {
        let xy = xyFrom(hue: palette.hue, saturation: palette.saturation, brightness: palette.brightness)
        let clamped = clampXYToGamut(x: xy.x, y: xy.y, gamut: gamut)
        return CodableColor(x: clamped.x, y: clamped.y)
    }

    // ──────────────────────────────────────────────
    // MARK: - CIE xy → SwiftUI Color
    // ──────────────────────────────────────────────

    /// Convert Hue CIE xy + brightness (1–100) to a SwiftUI Color for display.
    static func color(fromX x: Double, y: Double, brightness: Double) -> Color {
        let (h, s, b) = hsb(fromX: x, y: y, brightness: brightness)
        return Color(hue: h, saturation: s, brightness: b)
    }

    /// Convert Hue CIE xy + brightness (1–100) to HSB components.
    static func hsb(fromX x: Double, y: Double, brightness: Double) -> (h: Double, s: Double, b: Double) {
        let bNorm = brightness / 100.0
        let z = 1.0 - x - y
        guard y > 0 else { return (0, 0, bNorm) }

        let Y = bNorm
        let X = (Y / y) * x
        let Z = (Y / y) * z

        // XYZ → linear sRGB (inverse Wide Colour D65 matrix)
        var r =  X * 1.656492 - Y * 0.354851 - Z * 0.255038
        var g = -X * 0.707196 + Y * 1.655397 + Z * 0.036152
        var b =  X * 0.051713 - Y * 0.121364 + Z * 1.011530

        // Clamp negatives introduced by gamut boundary
        let maxC = max(r, g, b, 1.0)
        r /= maxC; g /= maxC; b /= maxC
        r = max(0, r); g = max(0, g); b = max(0, b)

        // Reverse gamma (linear → sRGB)
        r = delinearise(r); g = delinearise(g); b = delinearise(b)

        // sRGB → HSB
        let uiColor = UIColor(red: r, green: g, blue: b, alpha: 1)
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0
        uiColor.getHue(&hue, saturation: &sat, brightness: &bri, alpha: nil)
        return (Double(hue), Double(sat), Double(bri))
    }

    // ──────────────────────────────────────────────
    // MARK: - Color Temperature Helpers
    // ──────────────────────────────────────────────

    /// Convert mirek to Kelvin.
    static func kelvin(from mirek: Int) -> Int { 1_000_000 / mirek }

    /// Convert mirek to a 0–1 slider value given the valid mirek range.
    /// 0 = warmest (max mirek), 1 = coolest (min mirek).
    static func sliderValue(mirek: Int, min: Int, max: Int) -> Double {
        let clamped = Swift.min(Swift.max(mirek, min), max)
        return 1.0 - Double(clamped - min) / Double(max - min)
    }

    /// Convert a 0–1 slider value back to mirek.
    static func mirek(fromSlider value: Double, min: Int, max: Int) -> Int {
        let raw = Int(Double(max) - value * Double(max - min))
        return Swift.min(Swift.max(raw, min), max)
    }

    /// Approximate SwiftUI display Color for a mirek value.
    /// Used for glow/card-tint where CIE xy is unavailable (white-ambiance bulbs).
    /// Linearly interpolates between 2000K amber and 6500K cool daylight.
    static func color(fromMirek mirek: Int) -> Color {
        let lo = 153.0, hi = 500.0
        let t = (Double(mirek).clamped(lo, hi) - lo) / (hi - lo)  // 0=cool, 1=warm
        // Warm anchor: 2700K amber;  Cool anchor: 6500K daylight blue
        let rW = 1.0, gW = 0.78, bW = 0.35
        let rC = 0.82, gC = 0.88, bC = 1.0
        return Color(red:   rW * t + rC * (1 - t),
                     green: gW * t + gC * (1 - t),
                     blue:  bW * t + bC * (1 - t))
    }

    /// Gradient colours for a color-temperature slider (warm → cool).
    static let colorTempGradient = Gradient(colors: [
        Color(red: 1.0, green: 0.67, blue: 0.26),   // 2000K candlelight
        Color(red: 1.0, green: 0.83, blue: 0.60),   // 2700K warm white
        Color(red: 1.0, green: 0.95, blue: 0.87),   // 4000K neutral
        Color(red: 0.90, green: 0.93, blue: 1.0),   // 5500K daylight
        Color(red: 0.78, green: 0.86, blue: 1.0),   // 6500K cool daylight
    ])

    // ──────────────────────────────────────────────
    // MARK: - Private Gamma
    // ──────────────────────────────────────────────

    private static func linearise(_ v: Double) -> Double {
        v > 0.04045 ? pow((v + 0.055) / 1.055, 2.4) : v / 12.92
    }

    private static func delinearise(_ v: Double) -> Double {
        let c = Swift.max(0, v)
        return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1.0 / 2.4) - 0.055
    }

    private static func triangle(for gamut: Gamut) -> (r: XY, g: XY, b: XY) {
        switch gamut {
        case .a: return gamutA
        case .b: return gamutB
        case .c: return gamutC
        }
    }

    private static func isInsideTriangle(point p: XY, triangle t: (r: XY, g: XY, b: XY)) -> Bool {
        let d1 = sign(p, t.r, t.g)
        let d2 = sign(p, t.g, t.b)
        let d3 = sign(p, t.b, t.r)
        let hasNeg = (d1 < 0) || (d2 < 0) || (d3 < 0)
        let hasPos = (d1 > 0) || (d2 > 0) || (d3 > 0)
        return !(hasNeg && hasPos)
    }

    private static func sign(_ p1: XY, _ p2: XY, _ p3: XY) -> Double {
        (p1.x - p3.x) * (p2.y - p3.y) - (p2.x - p3.x) * (p1.y - p3.y)
    }

    private static func closestPointOnTriangle(point p: XY, triangle t: (r: XY, g: XY, b: XY)) -> XY {
        let c1 = closestPointOnSegment(point: p, a: t.r, b: t.g)
        let c2 = closestPointOnSegment(point: p, a: t.g, b: t.b)
        let c3 = closestPointOnSegment(point: p, a: t.b, b: t.r)

        let d1 = squaredDistance(p, c1)
        let d2 = squaredDistance(p, c2)
        let d3 = squaredDistance(p, c3)

        if d1 <= d2 && d1 <= d3 { return c1 }
        if d2 <= d1 && d2 <= d3 { return c2 }
        return c3
    }

    private static func closestPointOnSegment(point p: XY, a: XY, b: XY) -> XY {
        let abx = b.x - a.x
        let aby = b.y - a.y
        let ab2 = abx * abx + aby * aby
        guard ab2 > 0 else { return a }
        let apx = p.x - a.x
        let apy = p.y - a.y
        let t = ((apx * abx + apy * aby) / ab2).clamped(0, 1)
        return (x: a.x + abx * t, y: a.y + aby * t)
    }

    private static func squaredDistance(_ p1: XY, _ p2: XY) -> Double {
        let dx = p1.x - p2.x
        let dy = p1.y - p2.y
        return dx * dx + dy * dy
    }
}

// MARK: - Double clamping helper (HueColorUtils internal use)
private extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double {
        Swift.min(Swift.max(self, lo), hi)
    }
}
