// Composer2Events.swift
// ChromaGlow — Composer 2 lab (experimental).
//
// The reusable event generator: "every so often, something happens to some
// lights". Lightning, sparkles and eerie flashes are all instances of it.
// Scheduling is driven by a seeded generator that advances ONLY at
// opportunities (two draws each), so the same seed fires the same events at
// the same times regardless of frame rate, and audio can only tilt the
// probability — it never changes how many draws happen.

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

    init(timing: Timing = .random, interval: Double = 8, minDelay: Double = 4, maxDelay: Double = 14,
         probability: Double = 1, burstMin: Int = 1, burstMax: Int = 3,
         spacingMin: Double = 0.34, spacingMax: Double = 0.6,
         durationMin: Double = 0.06, durationMax: Double = 0.14, decaySeconds: Double = 0.35,
         intensityMin: Double = 0.7, intensityMax: Double = 1,
         targeting: Targeting = .all, targetCount: Int = 1, spatialBias: Double = 0.5,
         cooldown: Double = 0, majorProbability: Double = 0, seed: UInt64? = nil,
         modulates: Set<Modulation> = [.brightness], color: Composer2XY? = nil, motionKick: Double = 0) {
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
    }

    enum CodingKeys: String, CodingKey {
        case timing, interval, minDelay, maxDelay, probability, burstMin, burstMax
        case spacingMin, spacingMax, durationMin, durationMax, decaySeconds
        case intensityMin, intensityMax, targeting, targetCount, spatialBias
        case cooldown, majorProbability, seed, modulates, color, motionKick
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
        s.spacingMin = Composer2Math.clamp(spacing.lo, 0.02, 60)
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
        return s
    }

    /// Mean seconds between opportunities (for the UI's "frequency").
    var meanDelay: Double {
        let s = sanitized
        return s.timing == .fixed ? s.interval : (s.minDelay + s.maxDelay) / 2
    }
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

    static let attackSeconds: Double = 0.03

    /// Envelope 0…1 at `time` before target weighting.
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

            let chance = Composer2Math.clamp01(spec.probability + Composer2Math.clamp01(probabilityBoost))
            let afterCooldown = opportunity >= lastEventEnd + spec.cooldown
            guard u2 < chance, afterCooldown else { continue }

            let event = Composer2EventState.makeEvent(index: index, start: opportunity, spec: spec,
                                                      eventSeed: eventSeed, geometry: geometry)
            active = event
            firedCount += 1
            lastEventEnd = event.end
            nextOpportunity = Swift.max(nextOpportunity, event.end + spec.cooldown)
        }
    }

    /// Per-light event envelope (0…1) at `time`.
    func sample(slot: Int, time: Double) -> Double {
        guard let a = active, slot >= 0, slot < a.targets.count else { return 0 }
        let w = a.targets[slot]
        guard w > 0 else { return 0 }
        return a.envelope(at: time) * w
    }

    /// The event in flight, if any.
    var current: Composer2ActiveEvent? { active }

    /// Slot count changed underneath a running event — re-pick its targets.
    mutating func rebuildTargets(geometry: Composer2SlotGeometry, eventSeed: UInt64, spec rawSpec: Composer2EventSpec) {
        guard var a = active, a.targets.count != geometry.count else { return }
        a.targets = Composer2EventState.targets(index: a.index, spec: rawSpec.sanitized, eventSeed: eventSeed,
                                                geometry: geometry, isMajor: a.isMajor)
        active = a
    }

    // MARK: Event construction (stream B, per event)

    private static func makeEvent(index: Int, start: Double, spec: Composer2EventSpec,
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
        let targets = Composer2EventState.targets(index: index, spec: spec, eventSeed: eventSeed,
                                                  geometry: geometry, isMajor: isMajor)
        return Composer2ActiveEvent(index: index, start: start, flashes: flashes, decayTau: tau, end: end,
                                    isMajor: isMajor, targets: targets, color: spec.color,
                                    motionKick: spec.motionKick)
    }

    private static func targets(index: Int, spec: Composer2EventSpec, eventSeed: UInt64,
                                geometry: Composer2SlotGeometry, isMajor: Bool) -> [Double] {
        let n = geometry.count
        guard n > 0 else { return [] }
        if isMajor || spec.targeting == .all { return Array(repeating: 1, count: n) }
        let seed = Composer2Hash.mix(Composer2Hash.mix(eventSeed, UInt64(index)), 0x7A46)
        switch spec.targeting {
        case .all:
            return Array(repeating: 1, count: n)
        case .randomCount:
            let k = Swift.max(1, Swift.min(n, spec.targetCount))
            let ranked = (0..<n).sorted {
                let a = Composer2Hash.unit(seed, $0), b = Composer2Hash.unit(seed, $1)
                return a < b || (a == b && $0 < $1)
            }
            var w = Array(repeating: 0.0, count: n)
            for i in ranked.prefix(k) { w[i] = 1 }
            return w
        case .spatialBiased:
            let focus = Int(Composer2Hash.unit(seed, -1) * Double(n)) % n
            let bias = spec.spatialBias
            let sigma = 0.15 + (1 - bias) * 2
            var w = Array(repeating: 0.0, count: n)
            for i in 0..<n {
                let d: Double
                if let p = geometry.point(i), let f = geometry.point(focus) {
                    d = hypot(p.x - f.x, p.z - f.z)
                } else {
                    d = abs(geometry.linearIndex[i] - geometry.linearIndex[focus])
                }
                let jitter = bias * 0.15 * (Composer2Hash.unit(seed, i, 1) - 0.5)
                w[i] = Composer2Math.clamp01(exp(-(d * d) / (2 * sigma * sigma)) + jitter)
            }
            w[focus] = 1
            return w
        }
    }
}
