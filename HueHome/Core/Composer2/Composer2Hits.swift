// Composer2Hits.swift
// ChromaGlow — Composer 2 (Play Along: hits that move across the room)
//
// Where a beat lands in the room. A punch used to light every light at
// once; now it can travel:
//  • Roll: each beat launches a spot of light that glides across the room
//    along its long axis — the same way for a bar, then back the other way —
//    and the one bursts out from the middle (once the clock knows where bars
//    start). The first light lands ON the beat; the spot crosses the room
//    within half a beat and fades at the far side.
//  • Chase: each beat lands on the next light — or the next small group in
//    a big room — stepping along the axis and bouncing at the ends.
// Positions are the bridge's own (the Entertainment area, one point per
// gradient segment); without them the lights' order stands in.
//
// Safety, by construction: no single light is ever hit twice within the
// flash budget (0.34 s — the period the wire's gate enforces for the whole
// room). A hit followed by a different one (a turn, a burst) sweeps fast
// enough that every light is free before the next hit reaches it; a song
// too fast for that rolls on every other beat. A chase never hits the same
// light twice running, so it keeps every beat up to twice the whole-room
// rate. The flash limit measures the whole room, and a hit that moves
// raises it a little at a time; the engine's shaper and the wire's gate
// stay the authority over everything here. A spot carries the light of the
// lights it started on and no more as it moves (a wider ring shares it), so
// a beat raises the room's light once — never a burst of separate flashes.
//
// Pure: (travel, plan, hits, time) → a 0…1 level per light. No clocks.

import Foundation

enum Composer2Hits {

    /// A roll crosses the room in half a beat, kept within these seconds.
    static let rollShare = 0.5
    static let rollSeconds: ClosedRange<Double> = 0.12...0.4
    /// The one's burst reaches the farthest light in a third of a beat.
    static let burstShare = 0.35
    static let burstSeconds: ClosedRange<Double> = 0.1...0.3
    /// The spot keeps this much of its light by the far side of the room,
    /// then fades with the punch.
    static let sweepFade = 0.6
    /// Below this a sweep is all at once.
    static let instantSweep = 0.01
    /// Lights closer than this share of the sweep are one stop (hit together).
    static let stopTolerance = 0.02
    static let shortestFade = 0.08
    /// A moving hit is gone within this (so the next one can be seen).
    static let longestFade = 0.6
    /// The most steps a chase takes across a room; bigger rooms step in
    /// small groups so every beat still lands somewhere you can see.
    static let maxChaseSteps = 6
    /// Lights sit this share of the punch's strength lower between hits, so
    /// a moving hit stands out against the look instead of washing into it.
    /// It is steady (never a flash), and Dim Flashing Lights scales it with
    /// the punch.
    static let duckShare = 0.35
    /// The tempo a heard-hit source without a clock is timed as.
    static let fallbackBeat = 0.5
    /// The least time between two hits on the same light.
    static var refractory: Double { BeatMath.FlashSafety.minOnsetLedgerPeriod }
    /// Heard hits remembered (their waves may still be fading).
    static let onsetMemory = 12

    enum Pattern: Equatable {
        /// Every light at once.
        case all
        /// Along the axis, low end first.
        case forward
        /// Along the axis, high end first.
        case backward
        /// Out from the middle.
        case burst
        /// Only this chase group.
        case step(Int)
    }

    struct Hit: Equatable {
        /// Host time the first light is hit.
        let time: Double
        let pattern: Pattern
        /// Seconds from the first light to the last (0: all at once).
        let sweep: Double
    }

    // MARK: Plan (per geometry)

    /// Lights a sweep reaches together, `at` its share of the way.
    struct Stop: Equatable {
        let at: Double
        let lights: [Int]
    }

    struct Plan: Equatable {
        /// 0…1 along the room's long axis.
        let axis: [Double]
        /// Distance out from the light nearest the middle, in shares of the
        /// farthest light's distance from the middle (0…1).
        let radial: [Double]
        /// Chase group per light, ordered along the axis.
        let group: [Int]
        let groups: Int
        /// The stops a forward roll, a backward roll and a burst pass.
        let forward: [Stop]
        let backward: [Stop]
        let burst: [Stop]

        var count: Int { axis.count }

        func stops(_ pattern: Pattern) -> [Stop] {
            switch pattern {
            case .forward: return forward
            case .backward: return backward
            case .burst: return burst
            case .all, .step: return []
            }
        }

        init(geometry: Composer2SlotGeometry) {
            let n = geometry.count
            let projected = geometry.projection(kind: .principal, angleDegrees: 0)
            let axis = projected.count == n ? projected : geometry.linearIndex
            let distance = geometry.hasSpatialData
                ? geometry.radial
                // A line of lights: the middle of the line is the middle.
                : geometry.linearIndex.map { abs($0 * 2 - 1) }
            let steps = Swift.max(1, Swift.min(n, Composer2Hits.maxChaseSteps))
            let order = (0..<n).sorted { a, b in axis[a] < axis[b] || (axis[a] == axis[b] && a < b) }
            var group = Array(repeating: 0, count: n)
            for (rank, slot) in order.enumerated() {
                group[slot] = Swift.min(steps - 1, rank * steps / Swift.max(1, n))
            }
            // The light nearest the middle is hit on the one; a ring of
            // lights all as far out is hit all at once.
            let nearest = distance.min() ?? 0
            let radial = distance.count == n
                ? distance.map { Composer2Math.clamp01($0 - nearest) }
                : Array(repeating: 0, count: n)
            self.axis = axis
            self.radial = radial
            self.group = group
            self.groups = steps
            self.forward = Composer2Hits.stops(axis)
            self.backward = Composer2Hits.stops(axis.map { 1 - $0 })
            self.burst = Composer2Hits.stops(radial)
        }
    }

    /// Lights in order of `at`, those within `stopTolerance` of a stop's
    /// first light joined to it.
    static func stops(_ at: [Double]) -> [Stop] {
        let order = at.indices.sorted { at[$0] < at[$1] || (at[$0] == at[$1] && $0 < $1) }
        var stops: [Stop] = []
        var lights: [Int] = []
        var start = 0.0
        for i in order {
            if let first = lights.first, at[i] - at[first] > stopTolerance {
                stops.append(Stop(at: start, lights: lights))
                lights = []
            }
            if lights.isEmpty { start = at[i] }
            lights.append(i)
        }
        if !lights.isEmpty { stops.append(Stop(at: start, lights: lights)) }
        return stops
    }

    // MARK: Timing

    private static func usableBeat(_ beatInterval: Double) -> Double {
        beatInterval.isFinite && beatInterval > 0 ? beatInterval : fallbackBeat
    }

    /// A roll's own sweep at this tempo.
    static func rollSeconds(beatInterval: Double) -> Double {
        Composer2Math.clamp(rollShare * usableBeat(beatInterval), rollSeconds.lowerBound, rollSeconds.upperBound)
    }

    /// A burst's own sweep at this tempo.
    static func burstSeconds(beatInterval: Double) -> Double {
        Composer2Math.clamp(burstShare * usableBeat(beatInterval), burstSeconds.lowerBound, burstSeconds.upperBound)
    }

    /// The least time between two hits. A chase never hits the same light
    /// twice running, so its hits may come twice as fast as the budget. A
    /// roll reaches every light, so its hits are a budget apart — plus room
    /// for the shortest roll worth seeing before a turn.
    static func spacing(_ travel: Composer2AudioModulation.Travel) -> Double {
        switch travel {
        case .chase: return refractory / 2
        case .roll, .together: return refractory + rollSeconds.lowerBound / 2
        }
    }

    /// Beats from one hit to the next: 1, doubled until the hits are far
    /// enough apart (a song faster than about 150 BPM rolls on every other
    /// beat; a chase keeps every beat up to about 350).
    static func beatsPerHit(_ travel: Composer2AudioModulation.Travel, beatInterval: Double) -> Int {
        guard beatInterval.isFinite, beatInterval > 0 else { return 1 }
        let least = spacing(travel)
        var beats = 1
        while Double(beats) * beatInterval < least - 1e-9 && beats < 64 { beats *= 2 }
        return beats
    }

    /// How long hit `pattern` takes to cross the room when the next hit,
    /// `gap` seconds later, is `next`.
    ///
    /// The rule that keeps every light a budget apart: whenever two hits in
    /// a row differ, every light the first reaches must be reached no later
    /// than `gap − refractory` after it, so the second can reach it from its
    /// own start. A roll that keeps going the same way may take longer — but
    /// no more than twice that, so the shortened roll before a turn still
    /// leaves every light a budget after the full roll before it.
    static func sweep(_ pattern: Pattern, next: Pattern, gap: Double, beatInterval: Double) -> Double {
        let free = Swift.max(0, gap - refractory)
        switch pattern {
        case .all, .step:
            return 0
        case .burst:
            return Swift.min(burstSeconds(beatInterval: beatInterval), free)
        case .forward, .backward:
            let full = Swift.min(rollSeconds(beatInterval: beatInterval), 2 * free)
            return next == pattern ? full : Swift.min(full, free)
        }
    }

    // MARK: Which hit goes where

    /// The pattern of hit number `index`, which falls on beat `beatIndex`.
    /// A roll goes one way for a bar and back the next; the one bursts when
    /// the clock knows where it is.
    static func pattern(_ travel: Composer2AudioModulation.Travel, index: Int, beatIndex: Int, beatsPerBar: Int,
                        knowsTheOne: Bool, groups: Int) -> Pattern {
        switch travel {
        case .together:
            return .all
        case .roll:
            let perBar = beatsPerBar > 0 ? beatsPerBar : 4
            if knowsTheOne, modulo(beatIndex, perBar) == 0 { return .burst }
            return modulo(floorDivide(beatIndex, perBar), 2) == 0 ? .forward : .backward
        case .chase:
            return .step(pingPong(index, count: groups))
        }
    }

    /// 0, 1, …, count − 1, count − 2, …, 1, 0, 1, … (always 0 for one step).
    static func pingPong(_ index: Int, count: Int) -> Int {
        guard count > 1 else { return 0 }
        let period = 2 * (count - 1)
        let p = modulo(index, period)
        return p < count ? p : period - p
    }

    private static func modulo(_ a: Int, _ m: Int) -> Int {
        let r = a % m
        return r < 0 ? r + m : r
    }

    private static func floorDivide(_ a: Int, _ m: Int) -> Int {
        (a - modulo(a, m)) / m
    }

    /// The hits on the beat grid that can still be lighting the room at `t`,
    /// oldest first. The first is the hit before them: it only decides
    /// whether its successor may reach a light (render with
    /// `firstIsReference`).
    static func beatHits(_ travel: Composer2AudioModulation.Travel, beat: BeatSnapshot, at t: Double,
                         groups: Int, fade: Double) -> [Hit] {
        guard beat.bpm > 0, beat.beatInterval.isFinite, beat.beatInterval > 0, t.isFinite else { return [] }
        let p = beat.beatInterval
        let every = beatsPerHit(travel, beatInterval: p)
        let gap = Double(every) * p
        let latest = Composer2Math.safeFloorInt((t - beat.beatEpoch) / gap)
        // Enough hits to cover the fade (to under 1 %) and the widest sweep.
        let reach = 5 * Composer2Math.clamp(fade, shortestFade, longestFade) + rollSeconds.upperBound
        let count = Swift.min(24, Int((reach / gap).rounded(.up)) + 2)
        let knowsTheOne = beat.barConfidence >= Composer2Quantizer.barConfidenceForBar
        func patternOf(_ j: Int) -> Pattern {
            pattern(travel, index: j, beatIndex: j * every, beatsPerBar: beat.beatsPerBar,
                    knowsTheOne: knowsTheOne, groups: groups)
        }
        var hits: [Hit] = []
        hits.reserveCapacity(count)
        var current = patternOf(latest - count + 1)
        for j in (latest - count + 1)...latest {
            let next = patternOf(j + 1)
            hits.append(Hit(time: beat.beatEpoch + Double(j * every) * p, pattern: current,
                            sweep: sweep(current, next: next, gap: gap, beatInterval: p)))
            current = next
        }
        return hits
    }

    /// The wave a heard hit at `time` starts, after `previous` (the last
    /// wave), or nil when it comes too soon after it. Heard hits carry no
    /// bar and no next beat: a roll turns round only once the last wave has
    /// left every light a budget behind, and otherwise rolls the same way.
    static func heardWave(_ travel: Composer2AudioModulation.Travel, at time: Double, after previous: Hit?,
                          number: Int, groups: Int, beatInterval: Double) -> Hit? {
        guard time.isFinite else { return nil }
        if let previous, time - previous.time < spacing(travel) - 1e-9 { return nil }
        switch travel {
        case .together:
            return Hit(time: time, pattern: .all, sweep: 0)
        case .chase:
            return Hit(time: time, pattern: .step(pingPong(number, count: groups)), sweep: 0)
        case .roll:
            let full = rollSeconds(beatInterval: beatInterval)
            guard let previous else { return Hit(time: time, pattern: .forward, sweep: full) }
            let turn = time - previous.time - refractory >= previous.sweep - 1e-9
            let direction: Pattern
            switch previous.pattern {
            case .backward: direction = turn ? .forward : .backward
            default: direction = turn ? .backward : .forward
            }
            return Hit(time: time, pattern: direction, sweep: full)
        }
    }

    // MARK: Levels

    /// When hit `hit` reaches light `i` — its brightest moment — in seconds
    /// after it starts (nil: the hit skips this light).
    static func delay(_ hit: Hit, light i: Int, plan: Plan) -> Double? {
        let sweep = hit.sweep < instantSweep ? 0 : hit.sweep
        switch hit.pattern {
        case .all: return 0
        case .forward: return sweep * plan.axis[i]
        case .backward: return sweep * (1 - plan.axis[i])
        case .burst: return sweep * plan.radial[i]
        case .step(let g): return plan.group[i] == g ? 0 : nil
        }
    }

    /// Each light's 0…1 hit level at `t`.
    ///  • All at once and chase steps: an instant rise, then the punch's fade
    ///    (`decay`, capped).
    ///  • Sweeps: a spot that starts on the hit at full and glides from stop
    ///    to stop (two stops share it in between), keeping `sweepFade` of its
    ///    light by the far side, then fades there with the punch. A stop with
    ///    more lights than the first shares the first stop's light among
    ///    them, so a moving spot never adds light to the room.
    /// Safety net: a hit that would reach a light within `refractory` of the
    /// previous hit's arrival there skips that light (the sweeps above never
    /// let that happen on a steady grid). `hits[0]` is rendered only when
    /// `firstIsReference` is false.
    static func levels(plan: Plan, hits: [Hit], firstIsReference: Bool, at t: Double, decay: Double,
                       into out: inout [Double]) {
        let n = plan.count
        out.removeAll(keepingCapacity: true)
        out.append(contentsOf: repeatElement(0, count: n))
        guard n > 0, t.isFinite, !hits.isEmpty else { return }
        let tau = Composer2Math.clamp(decay.isFinite ? decay : 0.2, shortestFade, longestFade)
        let guardTime = refractory - 1e-9

        func light(_ i: Int, _ level: Double, hit m: Int) {
            guard level > out[i] else { return }
            if m > 0, let d = delay(hits[m], light: i, plan: plan),
               let p = delay(hits[m - 1], light: i, plan: plan),
               hits[m].time + d - (hits[m - 1].time + p) < guardTime {
                return
            }
            out[i] = level
        }

        for m in (firstIsReference ? 1 : 0)..<hits.count {
            let hit = hits[m]
            let age = t - hit.time
            guard age >= 0 else { continue }
            let stops = plan.stops(hit.pattern)
            if stops.isEmpty || hit.sweep < instantSweep {
                // All at once, a chase step, or a sweep with no time to move.
                let level = exp(-age / tau)
                for i in 0..<n {
                    if case .step(let g) = hit.pattern, plan.group[i] != g { continue }
                    light(i, level, hit: m)
                }
                continue
            }
            let first = Double(stops[0].lights.count)
            let end = stops[stops.count - 1].at
            let travelled = Swift.min(age / hit.sweep, end)
            let energy = pow(sweepFade, travelled) * exp(-Swift.max(0, age - end * hit.sweep) / tau)
            var k = 0
            while k + 1 < stops.count && stops[k + 1].at <= travelled { k += 1 }
            var share = 0.0
            if k + 1 < stops.count {
                let span = stops[k + 1].at - stops[k].at
                share = span > 1e-9 ? Composer2Math.clamp01((travelled - stops[k].at) / span) : 0
            }
            for (stop, weight) in [(stops[k], 1 - share), (k + 1 < stops.count ? stops[k + 1] : stops[k], share)]
            where weight > 0 {
                let each = energy * weight * Swift.min(1, first / Double(stop.lights.count))
                for i in stop.lights { light(i, each, hit: m) }
            }
        }
    }
}
