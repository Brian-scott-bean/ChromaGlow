// Composer2Palette.swift
// ChromaGlow — Composer 2 lab (experimental).
//
// Colour math and the palette primitive. Hue lights are driven by CIE xy
// chromaticity plus a separate brightness, so a palette here is a list of
// chromaticity stops. Interpolation happens in OKLab/OKLCh (perceptual, hue
// aware) so a blend from red to yellow does not pass through grey. Every
// output chromaticity is clamped to gamut C; the orchestrator clamps again
// to the room's real gamut before anything reaches a bulb.

import Foundation

// MARK: - Chromaticity

struct Composer2XY: Codable, Equatable, Hashable {
    var x: Double
    var y: Double

    static let d65 = Composer2XY(x: 0.3127, y: 0.3290)
    /// Warm incandescent white (≈2000 K) and cool daylight (≈6500 K).
    static let warmWhite = Composer2XY(x: 0.5268, y: 0.4133)
    static let coolWhite = Composer2XY(x: 0.3127, y: 0.3290)

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let x = (try? c.decode(Double.self, forKey: .x)) ?? Composer2XY.d65.x
        let y = (try? c.decode(Double.self, forKey: .y)) ?? Composer2XY.d65.y
        self.x = x.isFinite ? x : Composer2XY.d65.x
        self.y = y.isFinite ? y : Composer2XY.d65.y
    }

    var isFinite: Bool { x.isFinite && y.isFinite }

    func clamped(to gamut: HueColorUtils.Gamut = .c) -> Composer2XY {
        guard isFinite else { return .d65 }
        let p = HueColorUtils.clampXYToGamut(x: x, y: y, gamut: gamut)
        return Composer2XY(x: p.x, y: p.y)
    }
}

// MARK: - OKLab

struct Composer2Lab: Equatable {
    var l: Double
    var a: Double
    var b: Double

    var chroma: Double { (a * a + b * b).squareRoot() }
    var hue: Double { atan2(b, a) }   // radians, −π…π

    static let d65 = Composer2ColorMath.lab(fromXY: .d65)
}

enum Composer2ColorMath {
    /// Chromaticity (at unit luminance) → OKLab via XYZ. Pure, no UIKit.
    static func lab(fromXY xy: Composer2XY) -> Composer2Lab {
        guard xy.isFinite, xy.y > 1e-6 else { return Composer2Lab(l: 1, a: 0, b: 0) }
        let Y = 1.0
        let X = (Y / xy.y) * xy.x
        let Z = (Y / xy.y) * (1 - xy.x - xy.y)
        let l = 0.8189330101 * X + 0.3618667424 * Y - 0.1288597137 * Z
        let m = 0.0329845436 * X + 0.9293118715 * Y + 0.0361456387 * Z
        let s = 0.0482003018 * X + 0.2643662691 * Y + 0.6338517070 * Z
        let l_ = cbrt(Swift.max(0, l)), m_ = cbrt(Swift.max(0, m)), s_ = cbrt(Swift.max(0, s))
        return Composer2Lab(
            l: 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
            a: 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
            b: 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
        )
    }

    /// OKLab → chromaticity, gamut-clamped. Luminance is discarded (Hue
    /// brightness travels separately).
    static func xy(fromLab lab: Composer2Lab, gamut: HueColorUtils.Gamut = .c) -> Composer2XY {
        guard lab.l.isFinite, lab.a.isFinite, lab.b.isFinite else { return .d65 }
        let l_ = lab.l + 0.3963377774 * lab.a + 0.2158037573 * lab.b
        let m_ = lab.l - 0.1055613458 * lab.a - 0.0638541728 * lab.b
        let s_ = lab.l - 0.0894841775 * lab.a - 1.2914855480 * lab.b
        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
        let X =  1.2270138511 * l - 0.5577999807 * m + 0.2812561490 * s
        let Y = -0.0405801784 * l + 1.1122568696 * m - 0.0716766787 * s
        let Z = -0.0763812845 * l - 0.4214819784 * m + 1.5861632204 * s
        let sum = X + Y + Z
        guard sum > 1e-9, sum.isFinite else { return .d65 }
        return Composer2XY(x: X / sum, y: Y / sum).clamped(to: gamut)
    }

    static func mix(_ a: Composer2Lab, _ b: Composer2Lab, t: Double) -> Composer2Lab {
        let u = Composer2Math.clamp01(t)
        return Composer2Lab(l: Composer2Math.lerp(a.l, b.l, u),
                            a: Composer2Math.lerp(a.a, b.a, u),
                            b: Composer2Math.lerp(a.b, b.b, u))
    }

    /// OKLCh blend: lightness and chroma interpolate linearly, hue takes the
    /// shortest arc. An achromatic side (chroma < 0.02) adopts the other
    /// side's hue so a blend through white never spins the wheel.
    static func mixHueArc(_ a: Composer2Lab, _ b: Composer2Lab, t: Double) -> Composer2Lab {
        let u = Composer2Math.clamp01(t)
        let ca = a.chroma, cb = b.chroma
        let achromaticA = ca < 0.02, achromaticB = cb < 0.02
        if achromaticA && achromaticB { return mix(a, b, t: u) }
        var ha = a.hue, hb = b.hue
        if achromaticA { ha = hb }
        if achromaticB { hb = ha }
        var delta = hb - ha
        if delta > .pi { delta -= 2 * .pi }
        if delta < -.pi { delta += 2 * .pi }
        let h = ha + delta * u
        let c = Composer2Math.lerp(ca, cb, u)
        let l = Composer2Math.lerp(a.l, b.l, u)
        return Composer2Lab(l: l, a: c * cos(h), b: c * sin(h))
    }

    static func scaleChroma(_ lab: Composer2Lab, by factor: Double) -> Composer2Lab {
        let f = Composer2Math.clamp(factor, 0, 3)
        return Composer2Lab(l: lab.l, a: lab.a * f, b: lab.b * f)
    }
}

// MARK: - Palette model

struct Composer2PaletteStop: Codable, Equatable, Hashable {
    var x: Double
    var y: Double
    /// Explicit position along the palette (0…1). nil = evenly spaced.
    var position: Double?

    init(x: Double, y: Double, position: Double? = nil) {
        self.x = x
        self.y = y
        self.position = position
    }

    init(_ xy: Composer2XY, position: Double? = nil) {
        self.init(x: xy.x, y: xy.y, position: position)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = (try? c.decode(Double.self, forKey: .x)) ?? Composer2XY.d65.x
        y = (try? c.decode(Double.self, forKey: .y)) ?? Composer2XY.d65.y
        position = try? c.decode(Double.self, forKey: .position)
    }

    var xy: Composer2XY { Composer2XY(x: x, y: y) }
}

/// The colour source of one behavior layer: up to eight chromaticity stops
/// plus how they are traversed.
struct Composer2ColorSource: Codable, Equatable {
    enum Interpolation: String, Codable, CaseIterable {
        case linear
        case hueArc = "hue_arc"
        case stepped
        case softStepped = "soft_stepped"
    }

    enum Distribution: String, Codable, CaseIterable {
        /// The motion phase picks the colour (classic gradient travel).
        case motion
        /// Each light's position in the room picks the colour.
        case spatial
        /// Every light shows the same colour (phase 0).
        case uniform
        /// Each light picks a random stop, redrawn slowly.
        case randomPick = "random_pick"
        /// Colour follows brightness: dim = the first stop, bright = the
        /// last — embers that glow orange and burn yellow, lightning that
        /// flares white out of blue.
        case brightness
    }

    static let maxStops = 8

    var stops: [Composer2PaletteStop] = [
        Composer2PaletteStop(x: 0.5500, y: 0.3900),
        Composer2PaletteStop(x: 0.6400, y: 0.3300)
    ]
    var interpolation: Interpolation = .hueArc
    /// Chroma multiplier (0 = grey, 1 = as authored, up to 2).
    var saturation: Double = 1
    /// −1 (cool) … 1 (warm): pulls every stop toward a white point.
    var warmth: Double = 0
    var distribution: Distribution = .motion
    /// 0…1 slow per-light wander along the palette.
    var drift: Double = 0
    /// Phase 1 wraps back to the first stop (true) or holds the last (false).
    var cycle: Bool = true

    init(stops: [Composer2PaletteStop] = [
            Composer2PaletteStop(x: 0.5500, y: 0.3900),
            Composer2PaletteStop(x: 0.6400, y: 0.3300)
         ],
         interpolation: Interpolation = .hueArc,
         saturation: Double = 1,
         warmth: Double = 0,
         distribution: Distribution = .motion,
         drift: Double = 0,
         cycle: Bool = true) {
        self.stops = stops
        self.interpolation = interpolation
        self.saturation = saturation
        self.warmth = warmth
        self.distribution = distribution
        self.drift = drift
        self.cycle = cycle
    }

    enum CodingKeys: String, CodingKey {
        case stops, interpolation, saturation, warmth, distribution, drift, cycle
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Composer2ColorSource()
        stops = (try? c.decode([Composer2PaletteStop].self, forKey: .stops)) ?? defaults.stops
        interpolation = (try? c.decode(Interpolation.self, forKey: .interpolation)) ?? defaults.interpolation
        saturation = (try? c.decode(Double.self, forKey: .saturation)) ?? defaults.saturation
        warmth = (try? c.decode(Double.self, forKey: .warmth)) ?? defaults.warmth
        distribution = (try? c.decode(Distribution.self, forKey: .distribution)) ?? defaults.distribution
        drift = (try? c.decode(Double.self, forKey: .drift)) ?? defaults.drift
        cycle = (try? c.decode(Bool.self, forKey: .cycle)) ?? defaults.cycle
    }

    /// Stops as the engine sees them: finite, gamut-C, at most eight, never empty.
    var sanitizedStops: [Composer2PaletteStop] {
        var out: [Composer2PaletteStop] = []
        for stop in stops.prefix(Composer2ColorSource.maxStops) {
            let xy = stop.xy.isFinite ? stop.xy.clamped(to: .c) : .d65
            let pos = stop.position.map { Composer2Math.clamp01($0) }
            out.append(Composer2PaletteStop(xy, position: pos))
        }
        if out.isEmpty { out = [Composer2PaletteStop(.d65)] }
        return out
    }

    static func solid(_ xy: Composer2XY) -> Composer2ColorSource {
        Composer2ColorSource(stops: [Composer2PaletteStop(xy)])
    }

    static func stops(_ xys: [Composer2XY], interpolation: Interpolation = .hueArc) -> Composer2ColorSource {
        Composer2ColorSource(stops: xys.map { Composer2PaletteStop($0) }, interpolation: interpolation)
    }
}

// MARK: - Compiled palette

/// A palette compiled once per source change: stops converted to OKLab with
/// saturation and warmth applied, positions resolved. `sample` is what the
/// engine calls per light per frame.
struct Composer2CompiledPalette: Equatable {
    let labs: [Composer2Lab]
    let xys: [Composer2XY]
    let positions: [Double]
    let style: Composer2ColorSource.Interpolation
    let cycle: Bool

    init(_ source: Composer2ColorSource) {
        let stops = source.sanitizedStops
        let warmTarget = Composer2ColorMath.lab(fromXY: source.warmth >= 0 ? .warmWhite : .coolWhite)
        let warmAmount = Composer2Math.clamp01(abs(source.warmth)) * 0.6
        var labs: [Composer2Lab] = []
        var xys: [Composer2XY] = []
        for stop in stops {
            var lab = Composer2ColorMath.lab(fromXY: stop.xy)
            lab = Composer2ColorMath.scaleChroma(lab, by: source.saturation)
            if warmAmount > 0 { lab = Composer2ColorMath.mix(lab, warmTarget, t: warmAmount) }
            labs.append(lab)
            xys.append(Composer2ColorMath.xy(fromLab: lab))
        }
        // Positions: explicit values win, otherwise even spacing; sorted.
        // On a cycling palette the stops are spaced i/n so the LAST stop owns
        // a segment of the ring instead of sitting on the wrap point; a
        // holding palette runs edge to edge (i/(n-1)).
        let n = stops.count
        let ring = source.cycle && n > 1
        var pairs: [(pos: Double, index: Int)] = []
        for (i, stop) in stops.enumerated() {
            let even: Double
            if n <= 1 { even = 0 } else if ring { even = Double(i) / Double(n) } else { even = Double(i) / Double(n - 1) }
            pairs.append((stop.position ?? even, i))
        }
        pairs.sort { $0.pos < $1.pos || ($0.pos == $1.pos && $0.index < $1.index) }
        self.labs = pairs.map { labs[$0.index] }
        self.xys = pairs.map { xys[$0.index] }
        self.positions = pairs.map { $0.pos }
        self.style = source.interpolation
        self.cycle = source.cycle && n > 1
    }

    var stopCount: Int { labs.count }

    /// Colour at palette phase `t`. Cycling palettes wrap; holding palettes clamp.
    func sample(_ t: Double) -> Composer2Lab {
        let n = labs.count
        guard n > 1 else { return labs.first ?? Composer2Lab(l: 1, a: 0, b: 0) }
        let u = cycle ? Composer2Math.frac(t) : Composer2Math.clamp01(t)

        // A cycling palette whose first stop sits after 0 (explicit
        // positions) closes the ring on BOTH sides of the wrap point: phases
        // before the first stop blend in from the last stop instead of
        // clamping to the first (which left a hard seam at phase 0).
        if cycle, u < positions[0] {
            let lo = positions[n - 1] - 1
            let span = positions[0] - lo
            let local = span > 1e-9 ? Composer2Math.clamp01((u - lo) / span) : 0
            return blend(from: n - 1, to: 0, local: local)
        }

        // Locate the segment [positions[i], positions[i+1]] containing u; a
        // cycling palette closes the ring between the last stop and the first.
        var i = 0
        while i + 1 < n && positions[i + 1] <= u { i += 1 }
        let lo = positions[i]
        let hiIndex: Int
        let hi: Double
        if i + 1 < n {
            hiIndex = i + 1
            hi = positions[i + 1]
        } else if cycle {
            hiIndex = 0
            hi = positions[0] + 1
        } else {
            return labs[n - 1]
        }
        let span = hi - lo
        let local = span > 1e-9 ? Composer2Math.clamp01((u - lo) / span) : 0
        return blend(from: i, to: hiIndex, local: local)
    }

    /// The colour `local` (0…1) of the way from stop `i` to stop `j`.
    private func blend(from i: Int, to j: Int, local: Double) -> Composer2Lab {
        switch style {
        case .stepped:
            return labs[i]
        case .softStepped:
            // Hold the colour, then blend across the last 8 % of the segment.
            let band = 0.08
            if local < 1 - band { return labs[i] }
            let k = Composer2Math.smoothstep((local - (1 - band)) / band)
            return Composer2ColorMath.mixHueArc(labs[i], labs[j], t: k)
        case .linear:
            let a = xys[i], b = xys[j]
            let xy = Composer2XY(x: Composer2Math.lerp(a.x, b.x, local),
                                 y: Composer2Math.lerp(a.y, b.y, local))
            return Composer2ColorMath.lab(fromXY: xy)
        case .hueArc:
            return Composer2ColorMath.mixHueArc(labs[i], labs[j], t: local)
        }
    }

    func sampleXY(_ t: Double) -> Composer2XY {
        Composer2ColorMath.xy(fromLab: sample(t))
    }

    /// The colour of stop `index` (sorted order) — exact, no interpolation.
    func stopXY(_ index: Int) -> Composer2XY {
        guard !xys.isEmpty else { return .d65 }
        let i = Swift.min(Swift.max(0, index), xys.count - 1)
        return xys[i]
    }
}
