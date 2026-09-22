// Composer2Motion.swift
// ChromaGlow — Composer 2 lab (experimental).
//
// The motion primitive: how a behavior's colour phase and brightness weight
// travel through the room. Pure — `sample` is a function of (config, slot
// position, time, seed) and nothing else, so preview and live output agree.

import Foundation

struct Composer2Motion: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case `static`
        case flow
        case chase
        case wave
        case bounce
        case scatter
        case organic
    }

    /// Which room axis the motion travels along.
    enum AxisKind: String, Codable, CaseIterable {
        /// The axis of maximum spread (PCA) — "the long way through the room".
        case principal
        /// A user-chosen compass angle.
        case angle
        /// Outward from the centre.
        case radial
        /// Around the centre.
        case angular
    }

    enum Edge: String, Codable, CaseIterable {
        case wrap
        case bounce
        case clamp
    }

    var kind: Kind = .flow
    /// Seconds per cycle. Floored by the flash budget, capped at ten minutes.
    var periodSeconds: Double = 8
    var axisKind: AxisKind = .principal
    var angleDegrees: Double = 0
    /// 0…1 how far the phase is staggered across the room (0 = everything moves together).
    var spread: Double = 1
    var phaseOffset: Double = 0
    var reverse: Bool = false
    /// Fold the axis so the pattern plays inward from both ends.
    var mirror: Bool = false
    /// 0 = hard edges / stepped, 1 = fully smooth.
    var smoothness: Double = 0.5
    /// Width of the lit band, 0…1 of the room (1 = whole room lit, colour travels only).
    var travelWidth: Double = 1
    /// Chase spacing: 0 = continuous, N = the palette is held in N cells.
    var steps: Int = 0
    var edge: Edge = .wrap
    /// Organic spatial frequency (0.25 = broad, 4 = fine).
    var scale: Double = 1

    init(kind: Kind = .flow, periodSeconds: Double = 8, axisKind: AxisKind = .principal,
         angleDegrees: Double = 0, spread: Double = 1, phaseOffset: Double = 0,
         reverse: Bool = false, mirror: Bool = false, smoothness: Double = 0.5,
         travelWidth: Double = 1, steps: Int = 0, edge: Edge = .wrap, scale: Double = 1) {
        self.kind = kind
        self.periodSeconds = periodSeconds
        self.axisKind = axisKind
        self.angleDegrees = angleDegrees
        self.spread = spread
        self.phaseOffset = phaseOffset
        self.reverse = reverse
        self.mirror = mirror
        self.smoothness = smoothness
        self.travelWidth = travelWidth
        self.steps = steps
        self.edge = edge
        self.scale = scale
    }

    enum CodingKeys: String, CodingKey {
        case kind, periodSeconds, axisKind, angleDegrees, spread, phaseOffset, reverse, mirror
        case smoothness, travelWidth, steps, edge, scale
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Composer2Motion()
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? d.kind
        periodSeconds = (try? c.decode(Double.self, forKey: .periodSeconds)) ?? d.periodSeconds
        axisKind = (try? c.decode(AxisKind.self, forKey: .axisKind)) ?? d.axisKind
        angleDegrees = (try? c.decode(Double.self, forKey: .angleDegrees)) ?? d.angleDegrees
        spread = (try? c.decode(Double.self, forKey: .spread)) ?? d.spread
        phaseOffset = (try? c.decode(Double.self, forKey: .phaseOffset)) ?? d.phaseOffset
        reverse = (try? c.decode(Bool.self, forKey: .reverse)) ?? d.reverse
        mirror = (try? c.decode(Bool.self, forKey: .mirror)) ?? d.mirror
        smoothness = (try? c.decode(Double.self, forKey: .smoothness)) ?? d.smoothness
        travelWidth = (try? c.decode(Double.self, forKey: .travelWidth)) ?? d.travelWidth
        steps = (try? c.decode(Int.self, forKey: .steps)) ?? d.steps
        edge = (try? c.decode(Edge.self, forKey: .edge)) ?? d.edge
        scale = (try? c.decode(Double.self, forKey: .scale)) ?? d.scale
    }

    static let minimumPeriod: Double = BeatMath.FlashSafety.minOnsetLedgerPeriod
    static let maximumPeriod: Double = 600

    /// The period the engine actually runs: never faster than the flash budget.
    var sanitizedPeriod: Double {
        Composer2Math.clamp(periodSeconds, Composer2Motion.minimumPeriod, Composer2Motion.maximumPeriod)
    }

    /// A 0…1 "speed" for sliders (1 = fastest legal period, 0 = 60 s).
    var speedNormalized: Double {
        get {
            let lo = log(Composer2Motion.minimumPeriod), hi = log(60.0)
            return Composer2Math.clamp01(1 - (log(sanitizedPeriod) - lo) / (hi - lo))
        }
        set {
            let lo = log(Composer2Motion.minimumPeriod), hi = log(60.0)
            periodSeconds = exp(hi - Composer2Math.clamp01(newValue) * (hi - lo))
        }
    }

    // MARK: Sampling

    /// Colour phase (0…1) and brightness weight (0…1) for one light.
    ///
    /// - position: the light's 0…1 place along the motion axis.
    /// - cross: its 0…1 place across the axis (0.5 when unknown) — organic only.
    /// - time: motion time in seconds (already warped by speed modulation).
    func sample(slot: Int, position: Double, cross: Double, time: Double, seed: UInt64)
        -> (phase: Double, weight: Double) {
        let period = sanitizedPeriod
        let dir: Double = reverse ? -1 : 1
        let safeTime = time.isFinite ? time : 0
        let nt = dir * safeTime / period
        let p0 = Composer2Math.clamp01(position)
        let pos = mirror ? 1 - abs(2 * p0 - 1) : p0
        let spreadC = Composer2Math.clamp01(spread)
        let offset = Composer2Math.frac(phaseOffset)
        let width = Composer2Math.clamp(travelWidth, 0.05, 1)
        let soft = Composer2Math.clamp01(smoothness)

        switch kind {
        case .static:
            return (Composer2Math.frac(pos * spreadC + offset), 1)

        case .flow:
            let phase = Composer2Math.frac(nt + pos * spreadC + offset)
            return (phase, bandWeight(pos: pos, front: front(nt), width: width, soft: soft))

        case .wave:
            let phase = 0.5 + 0.5 * sin(2 * .pi * (nt + pos * spreadC + offset))
            return (Composer2Math.clamp01(phase), bandWeight(pos: pos, front: front(nt), width: width, soft: soft))

        case .bounce:
            let f = Composer2Motion.pingPong(nt)
            let phase = Composer2Math.frac(f + pos * spreadC + offset)
            let d = abs(pos - f)
            return (phase, bandWeight(distance: d, width: width, soft: soft))

        case .chase:
            var raw = Composer2Math.frac(nt + pos * spreadC + offset)
            if steps > 0 {
                let n = Double(Swift.min(64, steps))
                let quantized = floor(raw * n) / n
                raw = Composer2Math.lerp(quantized, raw, soft)
            }
            let weight: Double
            if width >= 0.999 {
                weight = 1
            } else {
                // Exponential tail behind the head, measured in the direction
                // the head is travelling RIGHT NOW. With bounce edges the
                // head reverses every half cycle; using the fixed direction
                // put the tail in front of the head on the way back.
                let f = front(nt)
                let travel: Double = edge == .bounce
                    ? (Composer2Math.frac(nt * 0.5) < 0.5 ? dir : -dir)
                    : dir
                var behind = (f - pos) * travel
                if edge == .wrap {
                    behind = Composer2Math.frac(behind)
                } else {
                    behind = behind < 0 ? 1 : behind
                }
                let tail = 0.05 + width * 0.6
                weight = Composer2Math.clamp01(exp(-behind / tail))
            }
            return (raw, weight)

        case .scatter:
            let salt = Composer2Hash.unit(seed, slot, 0, salt: 0x5CA7)
            let n = Composer2Noise.value1D(nt + salt * 97, seed: Composer2Hash.mix(seed, 0x5CA7))
            let phase = Composer2Math.frac(offset + n * (0.5 + 0.5 * spreadC))
            let sparkle = Composer2Noise.value1D(nt * 0.7 + 31.7 + salt * 53, seed: Composer2Hash.mix(seed, 0x5CA8))
            let weight = 1 - (1 - width) * (1 - Composer2Math.smoothstep(sparkle))
            return (phase, Composer2Math.clamp01(weight))

        case .organic:
            let s = Composer2Math.clamp(scale, 0.25, 4)
            let u = pos * s * 2 - nt
            let v = Composer2Math.clamp01(cross) * s * 2 + 0.37
            let n = Composer2Noise.fbm2D(u, v, seed: seed)
            let phase = Composer2Math.frac(offset + 0.25 * nt + (n - 0.5) * spreadC)
            let w = Composer2Noise.value2D(u + 11.3, v - 4.1, seed: Composer2Hash.mix(seed, 0x0261))
            let weight = 1 - (1 - width) * (1 - Composer2Math.smoothstep(w))
            return (phase, Composer2Math.clamp01(weight))
        }
    }

    // MARK: Helpers

    /// Where the moving front is on the 0…1 axis for a given normalized time.
    private func front(_ nt: Double) -> Double {
        switch edge {
        case .wrap, .clamp: return Composer2Math.frac(nt)
        case .bounce: return Composer2Motion.pingPong(nt)
        }
    }

    private func bandWeight(pos: Double, front: Double, width: Double, soft: Double) -> Double {
        let d: Double
        switch edge {
        case .wrap:
            let raw = abs(pos - front)
            d = Swift.min(raw, 1 - raw)
        case .bounce, .clamp:
            d = abs(pos - front)
        }
        return bandWeight(distance: d, width: width, soft: soft)
    }

    /// 1 inside the band, easing to 0 outside; `width` 1 covers the whole axis.
    private func bandWeight(distance d: Double, width: Double, soft: Double) -> Double {
        if width >= 0.999 { return 1 }
        let half = width / 2
        if d <= half { return 1 }
        let edgeWidth = Swift.max(0.02, half * (0.25 + soft * 1.5))
        return 1 - Composer2Math.smoothstep((d - half) / edgeWidth)
    }

    /// Triangle wave 0→1→0 with period 1 in `nt`.
    static func pingPong(_ nt: Double) -> Double {
        let f = Composer2Math.frac(nt * 0.5) * 2
        return f <= 1 ? f : 2 - f
    }
}
