// Composer2Events.swift
// ChromaGlow — Composer 2 lab (experimental).
//
// The reusable event generator: "every so often, something happens to some
// lights". Lightning, sparkles, fireworks, fireflies and ghosts are all
// instances of it. Scheduling is driven by a seeded generator that advances
// ONLY at opportunities (two draws each), so the same seed fires the same
// events at the same times regardless of frame rate, and audio can only tilt
// the probability — it never changes how many draws happen.
//
// v2.2 adds event SHAPES. `flash` is the original envelope. `lightning` is a
// physical model — a faint leader, a return stroke that hits hardest where
// the bolt lands, restrokes, the sky lit around it, and a long afterglow —
// built so that everything inside one strike stays under the
// photosensitivity gate (see `Composer2Lightning`). `firework` bursts in a
// colour and blooms outward with a crackling tail. `twinkle` and `glow` are
// soft rises for fireflies, fairy lights and apparitions.

import Foundation

// MARK: - Spec

struct Composer2EventSpec: Codable, Equatable {
    enum Timing: String, Codable, CaseIterable {
        case fixed
        case random
    }

    enum Targeting: String, Codable, CaseIterable {
        case all
        case randomCount = "random_count"
        case spatialBiased = "spatial_biased"
    }

    enum Modulation: String, Codable, CaseIterable {
        case brightness
        case color
        case motion
        case targets
    }

    /// What one event looks like.
    enum Shape: String, Codable, CaseIterable {
        /// A hold then a natural decay (the original shape).
        case flash
        /// A physical lightning strike: leader, return strokes, sky glow, afterglow.
        case lightning
        /// A coloured burst that blooms outward and crackles as it fades.
        case firework
        /// A soft rise and fall — fireflies, fairy lights, twinkling stars.
        case twinkle
        /// A slow swell and a long fade — something appearing in the dark.
        case glow
    }

    var timing: Timing = .random
    /// Seconds between opportunities when `timing == .fixed`.
    var interval: Double = 8
    var minDelay: Double = 4
    var maxDelay: Double = 14
    /// Chance an opportunity fires (0…1).
    var probability: Double = 1
    var burstMin: Int = 1
    var burstMax: Int = 3
    /// Seconds between flashes inside a burst.
    var spacingMin: Double = 0.34
    var spacingMax: Double = 0.6
    /// Seconds each flash holds before decaying.
    var durationMin: Double = 0.06
    var durationMax: Double = 0.14
    /// Natural decay after the hold (seconds to ~37 %).
    var decaySeconds: Double = 0.35
    var intensityMin: Double = 0.7
    var intensityMax: Double = 1
    var targeting: Targeting = .all
    var targetCount: Int = 1
    /// 0…1 how tightly a spatially-biased event hugs one spot.
    var spatialBias: Double = 0.5
    var cooldown: Double = 0
    /// Chance that a fired event is a "major" one (all lights, full intensity).
    var majorProbability: Double = 0
    var seed: UInt64? = nil
    var modulates: Set<Modulation> = [.brightness]
    /// Flash chromaticity when `.color` is modulated.
    var color: Composer2XY? = nil
    /// Colour-phase kick when `.motion` is modulated.
    var motionKick: Double = 0

    // v2.2
    var shape: Shape = .flash
    /// 0 = right overhead, 1 = far on the horizon (lightning): far strikes
    /// are dimmer, softer, wider and longer.
    var distance: Double = 0.35
    /// Seconds for an event to travel across the whole room from where it
    /// lands (0 = everywhere at once) — a rolling rumble, a blooming burst.
    var propagation: Double = 0
    /// Extra colours. Lightning: `[sky glow]`. Fireworks and twinkles: the
    /// colours to pick from, one per event.
    var colors: [Composer2XY] = []
    /// Storm cycle: seconds for activity to swell and fade again (0 = constant).
    var activityPeriod: Double = 0
    /// 0…1 how quiet the quiet end of the cycle is (fewer, farther events).
    var activityDepth: Double = 0

    init(timing: Timing = .random, interval: Double = 8, minDelay: Double = 4, maxDelay: Double = 14,
         probability: Double = 1, burstMin: Int = 1, burstMax: Int = 3,
         spacingMin: Double = 0.34, spacingMax: Double = 0.6,
         durationMin: Double = 0.06, durationMax: Double = 0.14, decaySeconds: Double = 0.35,
         intensityMin: Double = 0.7, intensityMax: Double = 1,
         targeting: Targeting = .all, targetCount: Int = 1, spatialBias: Double = 0.5,
         cooldown: Double = 0, majorProbability: Double = 0, seed: UInt64? = nil,
         modulates: Set<Modulation> = [.brightness], color: Composer2XY? = nil, motionKick: Double = 0,
         shape: Shape = .flash, distance: Double = 0.35, propagation: Double = 0,
         colors: [Composer2XY] = [], activityPeriod: Double = 0, activityDepth: Double = 0) {
        self.timing = timing
        self.interval = interval
        self.minDelay = minDelay
        self.maxDelay = maxDelay
        self.probability = probability
        self.burstMin = burstMin
        self.burstMax = burstMax
        self.spacingMin = spacingMin
        self.spacingMax = spacingMax
        self.durationMin = durationMin
        self.durationMax = durationMax
        self.decaySeconds = decaySeconds
        self.intensityMin = intensityMin
        self.intensityMax = intensityMax
        self.targeting = targeting
        self.targetCount = targetCount
        self.spatialBias = spatialBias
        self.cooldown = cooldown
        self.majorProbability = majorProbability
        self.seed = seed
        self.modulates = modulates
        self.color = color
        self.motionKick = motionKick
        self.shape = shape
        self.distance = distance
        self.propagation = propagation
        self.colors = colors
        self.activityPeriod = activityPeriod
        self.activityDepth = activityDepth
    }

    enum CodingKeys: String, CodingKey {
        case timing, interval, minDelay, maxDelay, probability, burstMin, burstMax
        case spacingMin, spacingMax, durationMin, durationMax, decaySeconds
        case intensityMin, intensityMax, targeting, targetCount, spatialBias
        case cooldown, majorProbability, seed, modulates, color, motionKick
        case shape, distance, propagation, colors, activityPeriod, activityDepth
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Composer2EventSpec()
        timing = (try? c.decode(Timing.self, forKey: .timing)) ?? d.timing
        interval = (try? c.decode(Double.self, forKey: .interval)) ?? d.interval
        minDelay = (try? c.decode(Double.self, forKey: .minDelay)) ?? d.minDelay
        maxDelay = (try? c.decode(Double.self, forKey: .maxDelay)) ?? d.maxDelay
        probability = (try? c.decode(Double.self, forKey: .probability)) ?? d.probability
        burstMin = (try? c.decode(Int.self, forKey: .burstMin)) ?? d.burstMin
        burstMax = (try? c.decode(Int.self, forKey: .burstMax)) ?? d.burstMax
        spacingMin = (try? c.decode(Double.self, forKey: .spacingMin)) ?? d.spacingMin
        spacingMax = (try? c.decode(Double.self, forKey: .spacingMax)) ?? d.spacingMax
        durationMin = (try? c.decode(Double.self, forKey: .durationMin)) ?? d.durationMin
        durationMax = (try? c.decode(Double.self, forKey: .durationMax)) ?? d.durationMax
        decaySeconds = (try? c.decode(Double.self, forKey: .decaySeconds)) ?? d.decaySeconds
        intensityMin = (try? c.decode(Double.self, forKey: .intensityMin)) ?? d.intensityMin
        intensityMax = (try? c.decode(Double.self, forKey: .intensityMax)) ?? d.intensityMax
        targeting = (try? c.decode(Targeting.self, forKey: .targeting)) ?? d.targeting
        targetCount = (try? c.decode(Int.self, forKey: .targetCount)) ?? d.targetCount
        spatialBias = (try? c.decode(Double.self, forKey: .spatialBias)) ?? d.spatialBias
        cooldown = (try? c.decode(Double.self, forKey: .cooldown)) ?? d.cooldown
        majorProbability = (try? c.decode(Double.self, forKey: .majorProbability)) ?? d.majorProbability
        seed = Composer2SeedCoding.decode(from: c, forKey: .seed)
        if let raw = try? c.decode([String].self, forKey: .modulates) {
            modulates = Set(raw.compactMap(Modulation.init(rawValue:)))
        } else {
            modulates = d.modulates
        }
        color = try? c.decode(Composer2XY.self, forKey: .color)
        motionKick = (try? c.decode(Double.self, forKey: .motionKick)) ?? d.motionKick
        shape = (try? c.decode(Shape.self, forKey: .shape)) ?? d.shape
        distance = (try? c.decode(Double.self, forKey: .distance)) ?? d.distance
        propagation = (try? c.decode(Double.self, forKey: .propagation)) ?? d.propagation
        colors = (try? c.decode([Composer2XY].self, forKey: .colors)) ?? d.colors
        activityPeriod = (try? c.decode(Double.self, forKey: .activityPeriod)) ?? d.activityPeriod
        activityDepth = (try? c.decode(Double.self, forKey: .activityDepth)) ?? d.activityDepth
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(timing, forKey: .timing)
        try c.encode(interval, forKey: .interval)
        try c.encode(minDelay, forKey: .minDelay)
        try c.encode(maxDelay, forKey: .maxDelay)
        try c.encode(probability, forKey: .probability)
        try c.encode(burstMin, forKey: .burstMin)
        try c.encode(burstMax, forKey: .burstMax)
        try c.encode(spacingMin, forKey: .spacingMin)
        try c.encode(spacingMax, forKey: .spacingMax)
        try c.encode(durationMin, forKey: .durationMin)
        try c.encode(durationMax, forKey: .durationMax)
        try c.encode(decaySeconds, forKey: .decaySeconds)
        try c.encode(intensityMin, forKey: .intensityMin)
        try c.encode(intensityMax, forKey: .intensityMax)
        try c.encode(targeting, forKey: .targeting)
        try c.encode(targetCount, forKey: .targetCount)
        try c.encode(spatialBias, forKey: .spatialBias)
        try c.encode(cooldown, forKey: .cooldown)
        try c.encode(majorProbability, forKey: .majorProbability)
        try Composer2SeedCoding.encode(seed, to: &c, forKey: .seed)
        try c.encode(modulates.map(\.rawValue).sorted(), forKey: .modulates)
        try c.encodeIfPresent(color, forKey: .color)
        try c.encode(motionKick, forKey: .motionKick)
        try c.encode(shape, forKey: .shape)
        try c.encode(distance, forKey: .distance)
        try c.encode(propagation, forKey: .propagation)
        if !colors.isEmpty { try c.encode(colors, forKey: .colors) }
        try c.encode(activityPeriod, forKey: .activityPeriod)
        try c.encode(activityDepth, forKey: .activityDepth)
    }

    /// The spec the generator actually runs: ordered ranges, sane floors.
    var sanitized: Composer2EventSpec {
        var s = self
        s.interval = Composer2Math.clamp(interval.isFinite ? interval : 8, 0.05, 3600)
        let delay = Composer2Math.orderedRange(minDelay, maxDelay)
        s.minDelay = Composer2Math.clamp(delay.lo, 0.05, 3600)
        s.maxDelay = Composer2Math.clamp(delay.hi, s.minDelay, 3600)
        s.probability = Composer2Math.clamp01(probability)
        let burst = Composer2Math.orderedRange(Swift.max(1, burstMin), Swift.max(1, burstMax))
        s.burstMin = Swift.min(burst.lo, 64)
        s.burstMax = Swift.min(burst.hi, 64)
        let spacing = Composer2Math.orderedRange(spacingMin, spacingMax)
        // A lightning restroke is a full re-rise of the room: it may never
        // come sooner than the flash budget allows.
        let spacingFloor = shape == .lightning ? BeatMath.FlashSafety.minOnsetLedgerPeriod + 0.02 : 0.02
        s.spacingMin = Composer2Math.clamp(spacing.lo, spacingFloor, 60)
        s.spacingMax = Composer2Math.clamp(spacing.hi, s.spacingMin, 60)
        let duration = Composer2Math.orderedRange(durationMin, durationMax)
        s.durationMin = Composer2Math.clamp(duration.lo, 0.01, 60)
        s.durationMax = Composer2Math.clamp(duration.hi, s.durationMin, 60)
        s.decaySeconds = Composer2Math.clamp(decaySeconds.isFinite ? decaySeconds : 0.35, 0.01, 60)
        let intensity = Composer2Math.orderedRange(Composer2Math.clamp01(intensityMin), Composer2Math.clamp01(intensityMax))
        s.intensityMin = intensity.lo
        s.intensityMax = intensity.hi
        s.targetCount = Swift.max(1, targetCount)
        s.spatialBias = Composer2Math.clamp01(spatialBias)
        s.cooldown = Composer2Math.clamp(cooldown.isFinite ? cooldown : 0, 0, 3600)
        s.majorProbability = Composer2Math.clamp01(majorProbability)
        s.motionKick = Composer2Math.clamp(motionKick.isFinite ? motionKick : 0, -1, 1)
        s.distance = Composer2Math.clamp01(distance)
        s.propagation = Composer2Math.clamp(propagation.isFinite ? propagation : 0, 0, 3)
        s.colors = colors.prefix(Composer2ColorSource.maxStops).map { $0.clamped(to: .c) }
        let period = activityPeriod.isFinite ? activityPeriod : 0
        s.activityPeriod = period <= 0 ? 0 : Composer2Math.clamp(period, 10, 3600)
        s.activityDepth = Composer2Math.clamp01(activityDepth)
        return s
    }

    /// A copy whose opportunities come `rate` times as often (Quick mode's
    /// "Frequency"). Only the schedule changes; each event is untouched.
    func withRate(_ rate: Double) -> Composer2EventSpec {
        let r = Composer2Math.clamp(rate.isFinite ? rate : 1, 0.25, 4)
        guard abs(r - 1) > 1e-9 else { return self }
        var s = self
        s.interval /= r
        s.minDelay /= r
        s.maxDelay /= r
        s.cooldown /= r
        return s
    }

    /// Mean seconds between opportunities (for the UI's "frequency").
    var meanDelay: Double {
        let s = sanitized
        return s.timing == .fixed ? s.interval : (s.minDelay + s.maxDelay) / 2
    }

    /// Storm-cycle activity at `time`, 1 = full. A raised cosine that starts
    /// at the quiet end, swells to full at mid-cycle and fades again — the
    /// storm rolls in and passes. Pure.
    func activity(at time: Double) -> Double {
        guard activityPeriod > 0, activityDepth > 0, time.isFinite else { return 1 }
        let p = Composer2Math.frac(time / activityPeriod)
        let swell = 0.5 - 0.5 * cos(2 * .pi * p)
        return Composer2Math.clamp01(1 - activityDepth * (1 - swell))
    }

    /// True when the event carries its own colour (a flash colour or a set
    /// of colours to pick from).
    var hasEventColor: Bool { color != nil || !colors.isEmpty }
}

// MARK: - Active event

struct Composer2ActiveEvent: Equatable {
    struct Flash: Equatable {
        let start: Double
        let holdEnd: Double
        let intensity: Double
    }

    let index: Int
    /// The scheduled opportunity time, never the frame that first saw it.
    let start: Double
    let flashes: [Flash]
    let decayTau: Double
    let end: Double
    let isMajor: Bool
    var targets: [Double]
    let color: Composer2XY?
    let motionKick: Double

    // v2.2 — shape parameters (defaults reproduce the original flash).
    var shape: Composer2EventSpec.Shape = .flash
    /// Peak level (lightning: dimmer when far).
    var peak: Double = 1
    /// Rise time of each stroke / burst.
    var attack: Double = Composer2ActiveEvent.attackSeconds
    /// Lightning: how much slower the lit sky rises than the bolt.
    var skyRiseSoftness: Double = 1
    /// Lightning: the share of the strike every light receives as sky glow.
    var skyShare: Double = 0
    /// Lightning: the level the channel glows at between restrokes.
    var strokeGlow: Double = 0
    /// Lightning: the fast fall right after a stroke.
    var fastTau: Double = 0.08
    /// Per-slot arrival delay (propagation).
    var delays: [Double] = []
    /// In-event shimmer depth, sized to the event's share of the room so the
    /// shimmer can never read as a new flash.
    var shimmerDepth: Double = 0
    var shimmerSeed: UInt64 = 0
    /// Lightning: a faint glow before the first stroke.
    var leader: Double = 0
    /// The event's own colours: the bolt / burst, and the sky around it.
    var coreLab: Composer2Lab? = nil
    var skyLab: Composer2Lab? = nil

    static let attackSeconds: Double = 0.03

    /// Envelope 0…1 at `time` before target weighting (the flash shape; the
    /// other shapes are sampled per slot with `levels`).
    func envelope(at time: Double) -> Double {
        guard time >= start, time <= end else { return 0 }
        var e = 0.0
        for f in flashes {
            if time < f.start { continue }
            let value: Double
            if time < f.start + Composer2ActiveEvent.attackSeconds {
                value = f.intensity * (time - f.start) / Composer2ActiveEvent.attackSeconds
            } else if time <= f.holdEnd {
                value = f.intensity
            } else {
                value = f.intensity * exp(-(time - f.holdEnd) / decayTau)
            }
            e = Swift.max(e, value)
        }
        return Composer2Math.clamp01(e)
    }

    /// Level (0…1) and core share (0 = sky / surrounding glow colour, 1 = the
    /// event's core colour) for one slot.
    func levels(slot: Int, time: Double) -> (level: Double, core: Double) {
        guard slot >= 0, slot < targets.count, time <= end else { return (0, 0) }
        let w = targets[slot]
        let delay = slot < delays.count ? delays[slot] : 0
        switch shape {
        case .flash:
            guard w > 0 else { return (0, 1) }
            return (envelope(at: time) * w, 1)

        case .lightning:
            let bolt = w > 0 ? w * strokeLevel(at: time - delay * 0.4, riseSoftness: 1, fallSoftness: 1, shimmer: true) : 0
            let sky = skyShare > 0
                ? skyShare * strokeLevel(at: time - delay, riseSoftness: skyRiseSoftness, fallSoftness: 1.6, shimmer: false)
                : 0
            let level = Swift.max(bolt, sky) * peak
            guard level > 0 else { return (0, 0) }
            let core = bolt + sky > 1e-9 ? bolt / (bolt + sky) : 0
            return (Composer2Math.clamp01(level), Composer2Math.clamp01(core))

        case .firework:
            guard w > 0, let first = flashes.first else { return (0, 1) }
            let t = time - start - delay
            guard t >= 0 else { return (0, 1) }
            let hold = first.holdEnd - first.start
            var v: Double
            if t < attack {
                v = t / attack
            } else if t < attack + hold {
                v = 1
            } else {
                let tail = t - attack - hold
                v = exp(-tail / decayTau)
                if shimmerDepth > 0 {
                    // The crackle of a fading burst — shallow, so it never
                    // reads as a new flash.
                    let n = Composer2Noise.value1D(time * 17 + Double(slot) * 3.1, seed: shimmerSeed)
                    v *= 1 - shimmerDepth * n * Composer2Math.clamp01(tail / 0.25)
                }
            }
            // The first moments of a burst burn white-hot.
            let hot = Composer2Math.clamp01(1 - t / 0.18)
            return (Composer2Math.clamp01(v * w * peak * first.intensity), hot)

        case .twinkle, .glow:
            guard w > 0 else { return (0, 1) }
            var v = 0.0
            for f in flashes {
                let span = f.holdEnd - f.start
                guard span > 0 else { continue }
                let t = time - f.start - delay
                guard t >= 0 else { continue }
                if shape == .twinkle {
                    guard t <= span else { continue }
                    let s = sin(.pi * t / span)
                    v = Swift.max(v, f.intensity * s * s)
                } else {
                    let rise = Swift.max(0.15, span * 0.45)
                    let value: Double
                    if t < rise {
                        value = Composer2Math.smoothstep(t / rise)
                    } else if t <= span {
                        value = 1
                    } else {
                        value = exp(-(t - span) / decayTau)
                    }
                    v = Swift.max(v, f.intensity * value)
                }
            }
            return (Composer2Math.clamp01(v * w * peak), 1)
        }
    }

    /// Lightning: the strike's level at `t` — leader, strokes, the glow of
    /// the channel between strokes, and the afterglow. The sky's view of it
    /// rises no faster than the bolt and falls more slowly, without shimmer.
    func strokeLevel(at t: Double, riseSoftness: Double, fallSoftness: Double, shimmer: Bool) -> Double {
        guard let first = flashes.first, t >= start else { return 0 }
        if t < first.start {
            // The stepped leader: a faint, uneven glow before the stroke.
            guard leader > 0, shimmer else { return 0 }
            let u = (t - start) / Swift.max(1e-3, first.start - start)
            let n = Composer2Noise.value1D(t * 40, seed: shimmerSeed &+ 7)
            return leader * u * (0.6 + 0.4 * n)
        }
        // The stroke in charge: the latest one that has begun.
        var k = 0
        while k + 1 < flashes.count && flashes[k + 1].start <= t { k += 1 }
        let f = flashes[k]
        let rise = attack * riseSoftness
        let isLast = k == flashes.count - 1
        var v: Double
        if t < f.start + rise {
            // A restroke rises from the glow the previous stroke left.
            let from = k == 0 ? 0 : strokeGlow * flashes[k - 1].intensity
            let u = (t - f.start) / rise
            v = from + (f.intensity - from) * (riseSoftness > 1 ? Composer2Math.smoothstep(u) : u)
        } else if t <= f.holdEnd {
            v = f.intensity
            if shimmer && shimmerDepth > 0 {
                let n = Composer2Noise.value1D(t * 23 + Double(k) * 5.7, seed: shimmerSeed)
                v *= 1 - shimmerDepth * n
            }
        } else {
            let dt = t - f.holdEnd
            let fast = fastTau * fallSoftness
            if isLast {
                // A bright snap, then the long afterglow of lit cloud.
                v = f.intensity * (0.55 * exp(-dt / fast) + 0.45 * exp(-dt / (decayTau * fallSoftness)))
            } else {
                let glow = strokeGlow * f.intensity
                v = glow + (f.intensity - glow) * exp(-dt / fast)
            }
            if shimmer && shimmerDepth > 0 && dt < 0.2 {
                let n = Composer2Noise.value1D(t * 23 + Double(k) * 5.7, seed: shimmerSeed)
                v *= 1 - shimmerDepth * n * (1 - dt / 0.2)
            }
        }
        return Composer2Math.clamp01(v)
    }

    /// The colour the event paints at a slot given its core share.
    func lab(core: Double) -> Composer2Lab? {
        switch (coreLab, skyLab) {
        case let (c?, s?): return Composer2ColorMath.mixHueArc(s, c, t: core)
        case let (c?, nil): return c
        case let (nil, s?): return s
        default: return nil
        }
    }
}

// MARK: - Generator state

struct Composer2EventState: Equatable {
    /// Stream A: advanced only at opportunities, exactly two draws each.
    private(set) var schedule: Composer2Rng
    private(set) var opportunityIndex: Int = 0
    private(set) var nextOpportunity: Double
    private(set) var active: Composer2ActiveEvent?
    private(set) var lastEventEnd: Double = -.infinity
    private(set) var firedCount: Int = 0

    /// Opportunities processed per `advance` call, bounding catch-up after a gap.
    static let maxCatchUp = 64
    /// A silent gap longer than this re-anchors the schedule instead of replaying.
    static let reanchorGap: Double = 60

    static func initial(spec rawSpec: Composer2EventSpec, eventSeed: UInt64, startTime: Double,
                        timingVariation: Double = 1) -> Composer2EventState {
        let spec = rawSpec.sanitized
        var rng = Composer2Rng(seed: Composer2Hash.mix(eventSeed, 0x5C))
        let u = rng.nextUnit()
        let first = Composer2EventState.delay(spec: spec, unit: u, timingVariation: timingVariation)
        return Composer2EventState(schedule: rng, nextOpportunity: (startTime.isFinite ? startTime : 0) + first)
    }

    private init(schedule: Composer2Rng, nextOpportunity: Double) {
        self.schedule = schedule
        self.nextOpportunity = nextOpportunity
    }

    static func delay(spec: Composer2EventSpec, unit: Double, timingVariation: Double) -> Double {
        if spec.timing == .fixed { return spec.interval }
        let mid = (spec.minDelay + spec.maxDelay) / 2
        let width = spec.maxDelay - spec.minDelay
        let v = Composer2Math.clamp01(timingVariation)
        return mid + (unit - 0.5) * width * v
    }

    /// Advance the schedule to `time`, firing every opportunity that came due.
    mutating func advance(to rawTime: Double, spec rawSpec: Composer2EventSpec, eventSeed: UInt64,
                          geometry: Composer2SlotGeometry, timingVariation: Double = 1,
                          probabilityBoost: Double = 0, forceOpportunity: Bool = false) {
        let time = rawTime.isFinite ? rawTime : nextOpportunity
        let spec = rawSpec.sanitized

        if let a = active, time >= a.end {
            lastEventEnd = a.end
            active = nil
        }
        if time - nextOpportunity > Composer2EventState.reanchorGap {
            nextOpportunity = time
        }
        if forceOpportunity {
            nextOpportunity = Swift.min(nextOpportunity, time)
        }

        var iterations = 0
        while time >= nextOpportunity && iterations < Composer2EventState.maxCatchUp {
            iterations += 1
            let opportunity = nextOpportunity
            let index = opportunityIndex
            opportunityIndex += 1
            let u1 = schedule.nextUnit()
            let u2 = schedule.nextUnit()
            let next = Composer2EventState.delay(spec: spec, unit: u1, timingVariation: timingVariation)
            nextOpportunity = opportunity + next

            // The storm cycle thins out the quiet end; it never changes how
            // many draws an opportunity takes.
            let activity = spec.activity(at: opportunity)
            let chance = Composer2Math.clamp01(spec.probability * activity + Composer2Math.clamp01(probabilityBoost))
            let afterCooldown = opportunity >= lastEventEnd + spec.cooldown
            guard u2 < chance, afterCooldown else { continue }

            let event = Composer2EventState.makeEvent(index: index, start: opportunity, spec: spec,
                                                      eventSeed: eventSeed, geometry: geometry,
                                                      activity: activity)
            active = event
            firedCount += 1
            lastEventEnd = event.end
            nextOpportunity = Swift.max(nextOpportunity, event.end + spec.cooldown)
        }
    }

    /// Per-light event envelope (0…1) at `time`.
    func sample(slot: Int, time: Double) -> Double {
        levels(slot: slot, time: time).level
    }

    /// Per-light level and core share at `time`.
    func levels(slot: Int, time: Double) -> (level: Double, core: Double) {
        guard let a = active, time >= a.start, time <= a.end else { return (0, 0) }
        return a.levels(slot: slot, time: time)
    }

    /// The event in flight, if any.
    var current: Composer2ActiveEvent? { active }

    /// Slot count changed underneath a running event — re-pick its targets.
    mutating func rebuildTargets(geometry: Composer2SlotGeometry, eventSeed: UInt64, spec rawSpec: Composer2EventSpec) {
        guard var a = active, a.targets.count != geometry.count else { return }
        let spec = rawSpec.sanitized
        let placed = Composer2EventState.placement(index: a.index, spec: spec, eventSeed: eventSeed,
                                                   geometry: geometry, isMajor: a.isMajor)
        a.targets = placed.weights
        a.delays = placed.distances.map { _ in 0 }
        active = a
    }

    // MARK: Event construction (stream B, per event)

    private static func makeEvent(index: Int, start: Double, spec: Composer2EventSpec,
                                  eventSeed: UInt64, geometry: Composer2SlotGeometry,
                                  activity: Double) -> Composer2ActiveEvent {
        switch spec.shape {
        case .flash:
            return makeFlash(index: index, start: start, spec: spec, eventSeed: eventSeed, geometry: geometry)
        case .lightning:
            return Composer2Lightning.makeStrike(index: index, start: start, spec: spec, eventSeed: eventSeed,
                                                 geometry: geometry, activity: activity)
        case .firework:
            return makeFirework(index: index, start: start, spec: spec, eventSeed: eventSeed, geometry: geometry)
        case .twinkle, .glow:
            return makeSoft(index: index, start: start, spec: spec, eventSeed: eventSeed, geometry: geometry)
        }
    }

    /// The original flash — the v2.0 behaviour, draw for draw.
    private static func makeFlash(index: Int, start: Double, spec: Composer2EventSpec,
                                  eventSeed: UInt64, geometry: Composer2SlotGeometry) -> Composer2ActiveEvent {
        var rng = Composer2Rng(seed: Composer2Hash.mix(eventSeed, UInt64(index)))
        let isMajor = spec.majorProbability > 0 && rng.nextUnit() < spec.majorProbability
        let count = isMajor ? spec.burstMax : rng.nextInt(in: spec.burstMin...spec.burstMax)
        var flashes: [Composer2ActiveEvent.Flash] = []
        flashes.reserveCapacity(count)
        var t = start
        for k in 0..<count {
            let hold = rng.next(in: spec.durationMin...spec.durationMax)
            let intensity = isMajor ? 1 : rng.next(in: spec.intensityMin...spec.intensityMax)
            flashes.append(.init(start: t, holdEnd: t + hold, intensity: intensity))
            if k + 1 < count {
                t = t + hold + rng.next(in: spec.spacingMin...spec.spacingMax)
            }
        }
        let tau = spec.decaySeconds * (isMajor ? 2.2 : 1)
        let lastHold = flashes.last?.holdEnd ?? start
        let end = lastHold + tau * log(100)
        let placed = placement(index: index, spec: spec, eventSeed: eventSeed, geometry: geometry, isMajor: isMajor)
        var event = Composer2ActiveEvent(index: index, start: start, flashes: flashes, decayTau: tau, end: end,
                                         isMajor: isMajor, targets: placed.weights, color: spec.color,
                                         motionKick: spec.motionKick)
        event.coreLab = spec.color.map { Composer2ColorMath.lab(fromXY: $0) }
        return event
    }

    private static func makeFirework(index: Int, start: Double, spec: Composer2EventSpec,
                                     eventSeed: UInt64, geometry: Composer2SlotGeometry) -> Composer2ActiveEvent {
        var rng = Composer2Rng(seed: Composer2Hash.mix(eventSeed, UInt64(index)))
        let isMajor = spec.majorProbability > 0 && rng.nextUnit() < spec.majorProbability
        let hold = rng.next(in: spec.durationMin...spec.durationMax)
        let intensity = isMajor ? 1 : rng.next(in: spec.intensityMin...spec.intensityMax)
        let palette = spec.colors.isEmpty ? (spec.color.map { [$0] } ?? []) : spec.colors
        let picked: Composer2XY? = palette.isEmpty ? nil : palette[rng.nextInt(in: 0...(palette.count - 1))]
        let tau = spec.decaySeconds * (isMajor ? 1.5 : 1)
        let placed = placement(index: index, spec: spec, eventSeed: eventSeed, geometry: geometry, isMajor: isMajor)
        let delays = placed.distances.map { $0 * spec.propagation }
        let end = start + (delays.max() ?? 0) + 0.05 + hold + tau * log(100)
        var event = Composer2ActiveEvent(index: index, start: start,
                                         flashes: [.init(start: start, holdEnd: start + hold, intensity: intensity)],
                                         decayTau: tau, end: end, isMajor: isMajor, targets: placed.weights,
                                         color: picked, motionKick: spec.motionKick)
        event.shape = .firework
        event.attack = 0.04
        event.delays = delays
        event.shimmerDepth = safeShimmerDepth(weights: placed.weights, sky: 0)
        event.shimmerSeed = Composer2Hash.mix(eventSeed, UInt64(index) &+ 0xF1AE)
        if let picked {
            let burst = Composer2ColorMath.lab(fromXY: picked)
            event.skyLab = burst
            event.coreLab = Composer2ColorMath.mix(burst, Composer2Lab.d65, t: 0.55)
        }
        return event
    }

    private static func makeSoft(index: Int, start: Double, spec: Composer2EventSpec,
                                 eventSeed: UInt64, geometry: Composer2SlotGeometry) -> Composer2ActiveEvent {
        var rng = Composer2Rng(seed: Composer2Hash.mix(eventSeed, UInt64(index)))
        let isMajor = spec.majorProbability > 0 && rng.nextUnit() < spec.majorProbability
        let count = isMajor ? spec.burstMax : rng.nextInt(in: spec.burstMin...spec.burstMax)
        var flashes: [Composer2ActiveEvent.Flash] = []
        var t = start
        for k in 0..<count {
            let span = rng.next(in: spec.durationMin...spec.durationMax)
            let intensity = isMajor ? 1 : rng.next(in: spec.intensityMin...spec.intensityMax)
            flashes.append(.init(start: t, holdEnd: t + span, intensity: intensity))
            if k + 1 < count { t += span + rng.next(in: spec.spacingMin...spec.spacingMax) }
        }
        let placed = placement(index: index, spec: spec, eventSeed: eventSeed, geometry: geometry, isMajor: isMajor)
        let delays = placed.distances.map { $0 * spec.propagation }
        let tau = spec.decaySeconds
        let tail = spec.shape == .glow ? tau * log(100) : 0
        let end = (flashes.last?.holdEnd ?? start) + (delays.max() ?? 0) + tail
        var event = Composer2ActiveEvent(index: index, start: start, flashes: flashes, decayTau: tau, end: end,
                                         isMajor: isMajor, targets: placed.weights, color: spec.color,
                                         motionKick: spec.motionKick)
        event.shape = spec.shape
        event.delays = delays
        if !spec.colors.isEmpty {
            let pick = spec.colors[rng.nextInt(in: 0...(spec.colors.count - 1))]
            event.coreLab = Composer2ColorMath.lab(fromXY: pick)
        } else {
            event.coreLab = spec.color.map { Composer2ColorMath.lab(fromXY: $0) }
        }
        return event
    }

    /// In-event shimmer depth (dimming units) that keeps the field's
    /// luminance swing under the gate's 10 % onset threshold with margin:
    /// the fewer lights an event covers, the deeper each may shimmer.
    static func safeShimmerDepth(weights: [Double], sky: Double) -> Double {
        guard !weights.isEmpty else { return 0 }
        let share = weights.map { Swift.max($0, sky) }.reduce(0, +) / Double(weights.count)
        let luminanceDepth = Swift.min(0.35, 0.07 / Swift.max(0.07, share))
        // Near full dimming, luminance moves ~2.6× as fast as dimming.
        return luminanceDepth / 2.6
    }

    struct Placement {
        var weights: [Double]
        /// 0…1 distance from where the event landed (for propagation).
        var distances: [Double]
        var focus: Int
    }

    /// Where an event lands and how strongly each light takes it. For the
    /// flash shape this is exactly the v2.0 targeting (same draws, same math).
    static func placement(index: Int, spec: Composer2EventSpec, eventSeed: UInt64,
                          geometry: Composer2SlotGeometry, isMajor: Bool,
                          spreadScale: Double = 1) -> Placement {
        let n = geometry.count
        guard n > 0 else { return Placement(weights: [], distances: [], focus: 0) }
        let seed = Composer2Hash.mix(Composer2Hash.mix(eventSeed, UInt64(index)), 0x7A46)
        let focus = Int(Composer2Hash.unit(seed, -1) * Double(n)) % n
        func distance(_ i: Int) -> Double {
            if let p = geometry.point(i), let f = geometry.point(focus) {
                return hypot(p.x - f.x, p.z - f.z)
            }
            return abs(geometry.linearIndex[i] - geometry.linearIndex[focus])
        }
        let raw = (0..<n).map(distance)
        let maxDistance = Swift.max(1e-6, raw.max() ?? 1)
        let distances = raw.map { $0 / maxDistance }
        if isMajor || spec.targeting == .all {
            return Placement(weights: Array(repeating: 1, count: n), distances: distances, focus: focus)
        }
        switch spec.targeting {
        case .all:
            return Placement(weights: Array(repeating: 1, count: n), distances: distances, focus: focus)
        case .randomCount:
            let k = Swift.max(1, Swift.min(n, spec.targetCount))
            let ranked = (0..<n).sorted {
                let a = Composer2Hash.unit(seed, $0), b = Composer2Hash.unit(seed, $1)
                return a < b || (a == b && $0 < $1)
            }
            var w = Array(repeating: 0.0, count: n)
            for i in ranked.prefix(k) { w[i] = 1 }
            return Placement(weights: w, distances: distances, focus: focus)
        case .spatialBiased:
            let bias = spec.spatialBias
            let sigma = (0.15 + (1 - bias) * 2) * Swift.max(1, spreadScale)
            var w = Array(repeating: 0.0, count: n)
            for i in 0..<n {
                let d = raw[i]
                let jitter = bias * 0.15 * (Composer2Hash.unit(seed, i, 1) - 0.5)
                w[i] = Composer2Math.clamp01(exp(-(d * d) / (2 * sigma * sigma)) + jitter)
            }
            w[focus] = 1
            return Placement(weights: w, distances: distances, focus: focus)
        }
    }
}

// MARK: - Lightning

/// A lightning strike, modelled on how one actually looks from a room.
///
/// A cloud-to-ground flash is a faint stepped leader, then a return stroke —
/// the blinding moment — then, typically, one to three restrokes down the
/// same channel, each rising from the glow the last one left, then a long
/// afterglow as the lit cloud fades. Close strikes are white, sudden and
/// local (the lights nearest the bolt blaze, the rest of the room is lit
/// around them); distant ones are dimmer, softer, wider, warmer and longer,
/// and roll across the room.
///
/// Built for the photosensitivity gate, not around it:
///  • Restrokes are full re-rises of the room, so they are spaced at least a
///    flash budget apart (`sanitized` floors the spacing).
///  • The gate holds a big rise that spans several frames, so a close
///    strike rises in ONE frame (bolt and sky together) and only a distant
///    strike — too dim to be an onset at all — rises softly or rolls.
///  • The flicker INSIDE a stroke is sized to the strike's share of the room
///    (`safeShimmerDepth`), so it moves the field's luminance by well under
///    the 10 % onset threshold.
/// The wire gate stays the authority; the strike is shaped so it rarely acts.
enum Composer2Lightning {
    /// Beyond this distance a strike is dim enough to rise softly and roll.
    static let softFrom: Double = 0.6

    static func makeStrike(index: Int, start: Double, spec: Composer2EventSpec, eventSeed: UInt64,
                           geometry: Composer2SlotGeometry, activity: Double) -> Composer2ActiveEvent {
        var rng = Composer2Rng(seed: Composer2Hash.mix(eventSeed, UInt64(index)))
        let isMajor = spec.majorProbability > 0 && rng.nextUnit() < spec.majorProbability
        // Distance: the spec's, varied per strike, pushed away at the quiet
        // end of a storm cycle; a major strike lands close.
        var d = Composer2Math.clamp01(spec.distance + (rng.nextUnit() - 0.5) * 0.3)
        d = 1 - (1 - d) * (0.35 + 0.65 * activity)
        if isMajor { d *= 0.4 }
        let soft = Composer2Math.clamp01((d - softFrom) / (1 - softFrom))

        let peakBase = isMajor ? 1 : rng.next(in: spec.intensityMin...spec.intensityMax)
        let peak = peakBase * Composer2Math.lerp(1, 0.32, d)
        let attack = Composer2Math.lerp(0.02, 0.16, soft)
        let leaderLength = d < softFrom ? rng.next(in: 0.05...0.11) : 0

        var strokes = isMajor ? spec.burstMax : rng.nextInt(in: spec.burstMin...spec.burstMax)
        if d > 0.7 { strokes = Swift.min(strokes, 2) }
        var flashes: [Composer2ActiveEvent.Flash] = []
        var t = start + leaderLength
        for k in 0..<strokes {
            let hold = rng.next(in: spec.durationMin...spec.durationMax) * Composer2Math.lerp(1, 2.4, d)
            let strength = k == 0 ? 1 : rng.next(in: 0.55...0.95)
            flashes.append(.init(start: t, holdEnd: t + attack + hold, intensity: strength))
            if k + 1 < strokes {
                t = t + attack + hold + rng.next(in: spec.spacingMin...spec.spacingMax)
            }
        }
        let afterglow = spec.decaySeconds * Composer2Math.lerp(1, 2.2, d) * (isMajor ? 1.6 : 1)
        let skyShare = Composer2Math.lerp(0.4, 0.9, d)
        let placed = Composer2EventState.placement(index: index, spec: spec, eventSeed: eventSeed,
                                                   geometry: geometry, isMajor: false,
                                                   spreadScale: 1 + 2 * d)
        // A major strike still lands somewhere: every light is lit, the bolt
        // side hardest.
        let weights = isMajor ? placed.weights.map { 0.55 + 0.45 * $0 } : placed.weights
        // Only a distant strike rolls across the room (see the type doc).
        let delays = placed.distances.map { $0 * spec.propagation * soft }
        let lastHold = flashes.last?.holdEnd ?? start
        let end = lastHold + (delays.max() ?? 0) + afterglow * 1.6 * 5

        var event = Composer2ActiveEvent(index: index, start: start, flashes: flashes, decayTau: afterglow,
                                         end: end, isMajor: isMajor, targets: weights, color: spec.color,
                                         motionKick: spec.motionKick)
        event.shape = .lightning
        event.peak = Composer2Math.clamp01(peak)
        event.attack = attack
        event.skyRiseSoftness = Composer2Math.lerp(1, 2.5, soft)
        event.skyShare = skyShare
        event.strokeGlow = Composer2Math.lerp(0.22, 0.4, d)
        event.fastTau = Composer2Math.lerp(0.07, 0.2, d)
        event.delays = delays
        event.leader = leaderLength > 0 ? 0.1 : 0
        event.shimmerSeed = Composer2Hash.mix(eventSeed, UInt64(index) &+ 0x11A7)
        event.shimmerDepth = Composer2EventState.safeShimmerDepth(weights: weights, sky: skyShare)
        let bolt = spec.color ?? Composer2XY(x: 0.27, y: 0.28)
        let sky = spec.colors.first ?? Composer2XY(x: 0.255, y: 0.225)
        // Distant strikes glow warmer through more air.
        let distantTint = Composer2XY(x: 0.34, y: 0.27)
        let skyXY = Composer2XY(x: Composer2Math.lerp(sky.x, distantTint.x, d * 0.55),
                                y: Composer2Math.lerp(sky.y, distantTint.y, d * 0.55))
        event.coreLab = Composer2ColorMath.lab(fromXY: bolt)
        event.skyLab = Composer2ColorMath.lab(fromXY: skyXY.clamped(to: .c))
        return event
    }
}
