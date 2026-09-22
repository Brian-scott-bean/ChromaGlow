// Composer2Rhythm.swift
// ChromaGlow — Composer 2 lab (experimental).
//
// The rhythm primitive: brightness over time. Replaces the narrower
// "envelope" idea — it covers smooth ambient breathing as well as short
// drum-hit bursts. Periods are floored at the realized-frame flash budget,
// so no rhythm can flash faster than the room's safety gate allows.

import Foundation

struct Composer2Rhythm: Codable, Equatable {
    enum Shape: String, Codable, CaseIterable {
        case steady
        case breathe
        case pulse
        case heartbeat
        case flicker
        case swell
        case burst
    }

    var shape: Shape = .steady
    var periodSeconds: Double = 4
    /// 0…1 rise speed share of the cycle.
    var attack: Double = 0.5
    /// 0…1 fall speed share of the cycle.
    var decay: Double = 0.5
    /// 0…1 how far the dip goes from max toward min.
    var depth: Double = 0.5
    /// 0…1 on-time share (pulse).
    var duty: Double = 0.5
    var minBrightness: Double = 0
    var maxBrightness: Double = 1
    /// 0…1 cycle offset.
    var phase: Double = 0
    /// 0 = free running; N = one cycle every N beats when a clock is running.
    var quantizeBeats: Double = 0
    /// Flicker noise rate in Hz (capped so crossings stay under the budget).
    var flickerRate: Double = 1.5

    init(shape: Shape = .steady, periodSeconds: Double = 4, attack: Double = 0.5, decay: Double = 0.5,
         depth: Double = 0.5, duty: Double = 0.5, minBrightness: Double = 0, maxBrightness: Double = 1,
         phase: Double = 0, quantizeBeats: Double = 0, flickerRate: Double = 1.5) {
        self.shape = shape
        self.periodSeconds = periodSeconds
        self.attack = attack
        self.decay = decay
        self.depth = depth
        self.duty = duty
        self.minBrightness = minBrightness
        self.maxBrightness = maxBrightness
        self.phase = phase
        self.quantizeBeats = quantizeBeats
        self.flickerRate = flickerRate
    }

    enum CodingKeys: String, CodingKey {
        case shape, periodSeconds, attack, decay, depth, duty, minBrightness, maxBrightness, phase, quantizeBeats, flickerRate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Composer2Rhythm()
        shape = (try? c.decode(Shape.self, forKey: .shape)) ?? d.shape
        periodSeconds = (try? c.decode(Double.self, forKey: .periodSeconds)) ?? d.periodSeconds
        attack = (try? c.decode(Double.self, forKey: .attack)) ?? d.attack
        decay = (try? c.decode(Double.self, forKey: .decay)) ?? d.decay
        depth = (try? c.decode(Double.self, forKey: .depth)) ?? d.depth
        duty = (try? c.decode(Double.self, forKey: .duty)) ?? d.duty
        minBrightness = (try? c.decode(Double.self, forKey: .minBrightness)) ?? d.minBrightness
        maxBrightness = (try? c.decode(Double.self, forKey: .maxBrightness)) ?? d.maxBrightness
        phase = (try? c.decode(Double.self, forKey: .phase)) ?? d.phase
        quantizeBeats = (try? c.decode(Double.self, forKey: .quantizeBeats)) ?? d.quantizeBeats
        flickerRate = (try? c.decode(Double.self, forKey: .flickerRate)) ?? d.flickerRate
    }

    static let minimumPeriod: Double = BeatMath.FlashSafety.minOnsetLedgerPeriod
    static let maximumPeriod: Double = 600
    static let maximumFlickerRate: Double = 2.5

    /// Where the heartbeat's second rise sits in its cycle (its humps peak at
    /// 0.08 and 0.32).
    static let heartbeatSecondRiseOffset: Double = 0.24

    /// The shortest legal cycle for this shape. Heartbeat's two rises are
    /// 0.24 of a cycle apart — NOT evenly spaced — so "twice the budget"
    /// (0.68 s) still put them 0.16 s apart; the floor now keeps the closer
    /// pair a whole flash budget apart.
    var sanitizedPeriodFloor: Double {
        shape == .heartbeat
            ? Composer2Rhythm.minimumPeriod / Composer2Rhythm.heartbeatSecondRiseOffset
            : Composer2Rhythm.minimumPeriod
    }

    var sanitizedPeriod: Double {
        Composer2Math.clamp(periodSeconds, sanitizedPeriodFloor, Composer2Rhythm.maximumPeriod)
    }

    var sanitizedFlickerRate: Double {
        Composer2Math.clamp(flickerRate, 0.1, Composer2Rhythm.maximumFlickerRate)
    }

    /// Tempo in beats per minute for the UI (one cycle = one beat).
    var bpm: Double {
        get { 60 / sanitizedPeriod }
        set { periodSeconds = 60 / Swift.max(1, newValue) }
    }

    var range: (lo: Double, hi: Double) {
        let r = Composer2Math.orderedRange(Composer2Math.clamp01(minBrightness), Composer2Math.clamp01(maxBrightness))
        let hi = r.hi
        let lo = Swift.max(r.lo, hi - Composer2Math.clamp01(depth) * (hi - r.lo))
        return (lo, hi)
    }

    /// Brightness 0…1 for one light.
    ///
    /// - cyclePhase: 0…1 position in the cycle (time / period, or beat-locked).
    /// - time: absolute rhythm time (flicker noise is time-based, not cycle-based).
    func value(cyclePhase: Double, time: Double, slot: Int, seed: UInt64) -> Double {
        let r = range
        if shape == .steady { return r.hi }
        let p = Composer2Math.frac(cyclePhase + phase)
        let curve: Double
        switch shape {
        case .steady:
            curve = 1

        case .breathe:
            let rise = Composer2Math.clamp(0.5 + (Composer2Math.clamp01(attack) - Composer2Math.clamp01(decay)) * 0.4, 0.1, 0.9)
            curve = p < rise
                ? Composer2Math.smoothstep(p / rise)
                : 1 - Composer2Math.smoothstep((p - rise) / (1 - rise))

        case .swell:
            let rise = Composer2Math.clamp(0.55 + Composer2Math.clamp01(attack) * 0.35, 0.3, 0.92)
            if p < rise {
                let s = Composer2Math.smoothstep(p / rise)
                curve = s * s
            } else {
                let fall = (p - rise) / (1 - rise)
                curve = 1 - Composer2Math.smoothstep(pow(fall, 0.6 + Composer2Math.clamp01(decay) * 0.8))
            }

        case .pulse:
            let on = Composer2Math.clamp(duty, 0.05, 0.95)
            let riseLen = 0.005 + Composer2Math.clamp01(attack) * 0.2 * on
            let fallLen = 0.005 + Composer2Math.clamp01(decay) * 0.2 * (1 - on)
            if p < on {
                curve = p < riseLen ? Composer2Math.smoothstep(p / riseLen) : 1
            } else {
                let q = p - on
                curve = q < fallLen ? 1 - Composer2Math.smoothstep(q / fallLen) : 0
            }

        case .heartbeat:
            let first = Composer2Rhythm.hump(p, start: 0.0, length: 0.16)
            let second = Composer2Rhythm.hump(p, start: Composer2Rhythm.heartbeatSecondRiseOffset, length: 0.16) * 0.7
            curve = Swift.max(first, second)

        case .flicker:
            let rate = sanitizedFlickerRate
            let salt = Composer2Hash.unit(seed, slot, 0, salt: 0xF11C)
            let t = time.isFinite ? time : 0
            let n1 = Composer2Noise.value1D(t * rate + salt * 31, seed: Composer2Hash.mix(seed, 0xF11C))
            let n2 = Composer2Noise.value1D(t * rate * 2.1 + 7 + salt * 13, seed: Composer2Hash.mix(seed, 0xF11D))
            curve = 0.7 * n1 + 0.3 * n2

        case .burst:
            let a = 0.02 + Composer2Math.clamp01(attack) * 0.08
            let tau = 0.05 + Composer2Math.clamp01(decay) * 0.3
            curve = p < a ? p / a : exp(-(p - a) / tau)
        }
        return Composer2Math.clamp01(r.lo + (r.hi - r.lo) * Composer2Math.clamp01(curve))
    }

    private static func hump(_ p: Double, start: Double, length: Double) -> Double {
        guard p >= start, p <= start + length else { return 0 }
        let s = sin(.pi * (p - start) / length)
        return s * s
    }
}
