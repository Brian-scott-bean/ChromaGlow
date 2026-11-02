// GrooveMap.swift
// ChromaGlow — Core/Audio ("the room is the band", step 2: build 916)
//
// Where the kick, snare and hi-hat fall in the bar, learned from the drum
// lanes (DrumLanes) over the last few bars, so a drum look can light ON the
// drum. A hit the lanes hear is "now": by the time a frame shows it, the
// render lead (~0.1 s, OutputLatencyModel) plus the analysis hop have passed,
// so a purely reactive kick lands ≥ 0.12 s late. The beat punch never had
// that problem — it is predicted on the beat grid — and the groove map does
// the same for each drum: once a slot of the bar has been played bar after
// bar, its next hit is fired at its predicted time, and the lanes confirm or
// cancel. A predicted hit the music doesn't play (a fill, a break, a new
// song) suspends that drum's prediction until a played hit lands on the
// pattern again; meanwhile the drum falls back to what the lanes hear.
//
// The bar is cut in sixteenths (`slotsPerBeat` = 4) of the clock's grid;
// each slot keeps how often it was played (weight), how early or late
// (offset — swing and pushed beats) and how hard.
//
// THREADING CONTRACT: `GrooveMap` has one writer (the tracker pass on the
// main actor). `GroovePattern` is a value: published through a lock-guarded
// mirror and stamped on every AudioFeatures, so any render loop reads it.

import Foundation

/// The groove map's settings (swept in the beat lab, `run.sh -groove`).
struct GrooveTuning: Sendable, Equatable {
    /// A heard hit this close to a pattern slot is that slot's hit.
    var matchWindow = 0.06
    /// A slot is predicted when it was played in most recent bars.
    var minWeight: Float = 0.55
    /// Per bar: how fast a slot's weight follows what was played (~3 bars).
    var learnRate: Float = 0.35
    /// Per bar: how fast a drum's agreement (share of its predicted slots
    /// that were played) follows, and the least it may be to predict.
    var agreementRate: Float = 0.5
    var minAgreement: Float = 0.6
    /// Bars learned before anything is predicted.
    var minBars = 2
    /// Strong predicted slots missed in a row before a drum is suspended.
    var missesToSuspend = 2
    var strongWeight: Float = 0.8

    static let standard = GrooveTuning()
}

struct GroovePattern: Sendable, Equatable {
    static let slotsPerBeat = 4

    /// The grid the pattern was learned on (its bar 0 is the clock's).
    var bpm: Double = 0
    var beatEpoch: Double = 0
    var beatsPerBar: Int = 4
    /// Per drum (`DrumLanes.Kind` order) × slot, row-major.
    var weights: [Float] = []
    var offsets: [Float] = []
    var strengths: [Float] = []
    /// Per drum: may the lights fire it predicted.
    var live: [Bool] = [false, false, false]
    var matchWindow = GrooveTuning.standard.matchWindow
    var minWeight = GrooveTuning.standard.minWeight

    static let none = GroovePattern()

    var slots: Int { beatsPerBar * Self.slotsPerBeat }

    func weight(_ kind: DrumLanes.Kind, _ slot: Int) -> Float {
        let i = kind.rawValue * slots + slot
        return i < weights.count ? weights[i] : 0
    }

    /// True when `beat` is the grid this pattern was learned on: the same
    /// tempo (±3 %), metre and bar line (±¼ beat).
    func fits(_ beat: BeatSnapshot) -> Bool {
        guard bpm > 0, beat.bpm > 0, beat.beatsPerBar == beatsPerBar,
              abs(beat.bpm / bpm - 1) <= 0.03 else { return false }
        let bars = (beat.beatEpoch - beatEpoch) / (beat.beatInterval * Double(beatsPerBar))
        return abs(bars - bars.rounded()) * Double(beatsPerBar) <= 0.25
    }

    /// The drum's latest PREDICTED hit at or before `t` (within one bar), on
    /// the current grid `beat`. `whenLive` false: whether or not the lights
    /// may fire it (for telling a heard hit's slot).
    func lastPredicted(_ kind: DrumLanes.Kind, at t: Double, beat: BeatSnapshot,
                       whenLive: Bool = true) -> (time: Double, strength: Float)? {
        guard let g = geometry(beat), kind.rawValue < live.count, !whenLive || live[kind.rawValue], t.isFinite else { return nil }
        let here = (t - beat.beatEpoch) / g.slotLen
        guard abs(here) < 1e9 else { return nil }
        let current = Int(here.rounded(.down))
        // One slot ahead too: a slot played early may already have sounded.
        for index in stride(from: current + 1, through: current - slots, by: -1) {
            let i = kind.rawValue * slots + ((index % slots) + slots) % slots
            guard weights[i] >= minWeight else { continue }
            let time = beat.beatEpoch + Double(index) * g.slotLen + Double(offsets[i])
            if time <= t { return (time, strengths[i] * certainty(weights[i])) }
        }
        return nil
    }

    /// A slot played in every recent bar flashes at full strength; one barely
    /// over `minWeight` at half: a predicted hit that isn't played is a soft
    /// one.
    func certainty(_ weight: Float) -> Float {
        let span = max(1e-3, 1 - minWeight)
        return 0.5 + 0.5 * min(1, max(0, (weight - minWeight) / span))
    }

    /// The predicted time of the pattern slot nearest `time`, if one is
    /// within `matchWindow` (live or not).
    func slotTime(_ kind: DrumLanes.Kind, near time: Double, beat: BeatSnapshot) -> Double? {
        guard let g = geometry(beat), time.isFinite else { return nil }
        let here = (time - beat.beatEpoch) / g.slotLen
        guard abs(here) < 1e9 else { return nil }
        let nearest = Int(here.rounded())
        var best: Double?
        for index in (nearest - 1)...(nearest + 1) {
            let i = kind.rawValue * slots + ((index % slots) + slots) % slots
            guard weights[i] >= minWeight else { continue }
            let t = beat.beatEpoch + Double(index) * g.slotLen + Double(offsets[i])
            if abs(t - time) <= matchWindow, best.map({ abs(t - time) < abs($0 - time) }) ?? true { best = t }
        }
        return best
    }

    /// The drum's latest hit at `t`, heard or predicted. A heard hit within
    /// `matchWindow` of a pattern slot is reported at that slot's predicted
    /// time — the same identity the predicted hit had — so a hit is never
    /// fired twice, even when the drum's prediction switches on or off
    /// between the two. Other heard hits keep their own time.
    func latestHit(_ kind: DrumLanes.Kind, heardAt: Double, heardStrength: Float, beat: BeatSnapshot,
                   at t: Double) -> (time: Double, strength: Float) {
        var heard = (time: heardAt, strength: heardStrength)
        if heardAt > 0, let slot = slotTime(kind, near: heardAt, beat: beat) { heard.time = slot }
        guard let p = lastPredicted(kind, at: t, beat: beat) else { return heard }
        return heard.time > p.time ? heard : p
    }

    private func geometry(_ beat: BeatSnapshot) -> (slotLen: Double, Void)? {
        guard slots > 0, weights.count == 3 * slots, offsets.count == weights.count, strengths.count == weights.count,
              beat.phaseConfidence >= GrooveMap.minPhaseConfidence, fits(beat) else { return nil }
        let slotLen = beat.beatInterval / Double(Self.slotsPerBeat)
        guard slotLen > 0, slotLen.isFinite else { return nil }
        return (slotLen, ())
    }
}

final class GrooveMap: @unchecked Sendable {
    /// The grid must be trusted as Play Along trusts it
    /// (Composer2PlayAlongDirector.usablePhaseConfidence).
    static let minPhaseConfidence = 0.5

    let tuning: GrooveTuning

    init(tuning: GrooveTuning = .standard) {
        self.tuning = tuning
        reset()
    }

    private(set) var pattern = GroovePattern.none
    private var agreement: [Float] = [0.5, 0.5, 0.5]
    private var suspended: [Bool] = [false, false, false]
    private var misses: [Int] = [0, 0, 0]
    private var bars = 0
    /// End time of the last bar folded in; per drum, the grid time of the
    /// last slot judged (times, so a re-based epoch can't judge one twice).
    private var lastBarEnd = -Double.infinity
    private var lastJudged: [Double] = [-.infinity, -.infinity, -.infinity]

    func reset() {
        pattern = .none
        pattern.matchWindow = tuning.matchWindow
        pattern.minWeight = tuning.minWeight
        agreement = [0.5, 0.5, 0.5]
        suspended = [false, false, false]
        misses = [0, 0, 0]
        bars = 0
        lastBarEnd = -.infinity
        lastJudged = [-.infinity, -.infinity, -.infinity]
    }

    /// One pass (~2 Hz): fold in every whole bar that has ended since the
    /// last pass, judge the predicted slots that have passed, and return
    /// the pattern to publish.
    @discardableResult
    func update(_ frames: OnsetFrames, beat: BeatSnapshot) -> GroovePattern {
        let trusted = beat.bpm > 0 && beat.beatInterval.isFinite && beat.phaseConfidence >= Self.minPhaseConfidence
        guard trusted, let newest = frames.times.last, frames.count == frames.kick.count,
              frames.count == frames.snare.count, frames.count == frames.hat.count else {
            for k in pattern.live.indices { pattern.live[k] = false }
            return pattern
        }
        if !pattern.fits(beat) || pattern.weights.count != 3 * beat.beatsPerBar * GroovePattern.slotsPerBeat {
            reset()
            let n = 3 * beat.beatsPerBar * GroovePattern.slotsPerBeat
            pattern.weights = [Float](repeating: 0, count: n)
            pattern.offsets = [Float](repeating: 0, count: n)
            pattern.strengths = [Float](repeating: 0, count: n)
        }
        // Follow the clock's small corrections; the bar line stays.
        pattern.bpm = beat.bpm
        pattern.beatEpoch = beat.beatEpoch
        pattern.beatsPerBar = beat.beatsPerBar

        let slots = pattern.slots
        let slotLen = beat.beatInterval / Double(GroovePattern.slotsPerBeat)
        let barLen = slotLen * Double(slots)
        let half = slotLen / 2
        // Lanes may mark a hit back on its onset frame a little later.
        let settled = newest - DrumLanes.settleSeconds
        let oldest = frames.times[0]
        let lanes = [frames.kick, frames.snare, frames.hat]

        // Hits per lane in [from, to): (time, strength).
        func hits(_ lane: Int, from: Double, to: Double) -> [(Double, Float)] {
            var out: [(Double, Float)] = []
            for i in 0..<frames.count where frames.times[i] >= from && frames.times[i] < to && lanes[lane][i] > 0 {
                out.append((frames.times[i], lanes[lane][i]))
            }
            return out
        }

        // 1. Whole bars that ended (and settled) since the last pass, inside
        //    the frames. A bar owns [start − ½ slot, end − ½ slot), so a hit
        //    just before the one counts as the one.
        let covered = Int(((oldest + half - beat.beatEpoch) / barLen).rounded(.up))
        let next = lastBarEnd.isFinite ? Int(((lastBarEnd - beat.beatEpoch) / barLen).rounded()) : covered
        var bar = max(covered, next)
        while true {
            let start = beat.beatEpoch + Double(bar) * barLen
            let end = start + barLen
            guard end - half <= settled else { break }
            fold(start: start, slotLen: slotLen, slots: slots,
                 lanes: (0..<3).map { hits($0, from: start - half, to: end - half) })
            lastBarEnd = end
            bar += 1
        }

        // 2. Predicted slots that have passed since the last pass: two strong
        //    ones missed in a row suspend the drum; a played one resumes it.
        for lane in 0..<3 {
            let floorIndex = Int(((max(oldest + tuning.matchWindow, settled - barLen) - beat.beatEpoch) / slotLen)
                .rounded(.up))
            var index = lastJudged[lane].isFinite
                ? max(floorIndex, Int(((lastJudged[lane] - beat.beatEpoch) / slotLen).rounded()) + 1) : floorIndex
            while true {
                let base = beat.beatEpoch + Double(index) * slotLen
                let i = lane * slots + ((index % slots) + slots) % slots
                let time = base + Double(pattern.offsets[i])
                guard time + tuning.matchWindow <= settled else { break }
                if pattern.weights[i] >= tuning.minWeight {
                    let played = !hits(lane, from: time - tuning.matchWindow,
                                       to: time + tuning.matchWindow).isEmpty
                    if played {
                        misses[lane] = 0
                        suspended[lane] = false
                    } else if pattern.weights[i] >= tuning.strongWeight {
                        misses[lane] += 1
                        if misses[lane] >= tuning.missesToSuspend { suspended[lane] = true }
                    }
                }
                lastJudged[lane] = base
                index += 1
            }
        }

        for lane in 0..<3 {
            let any = (0..<slots).contains { pattern.weights[lane * slots + $0] >= tuning.minWeight }
            pattern.live[lane] = any && bars >= tuning.minBars && agreement[lane] >= tuning.minAgreement && !suspended[lane]
        }
        return pattern
    }

    /// Fold one bar's hits into the pattern.
    private func fold(start: Double, slotLen: Double, slots: Int, lanes: [[(Double, Float)]]) {
        for lane in 0..<3 {
            var played = [Bool](repeating: false, count: slots)
            var offset = [Float](repeating: 0, count: slots)
            var strength = [Float](repeating: 0, count: slots)
            for (t, s) in lanes[lane] {
                let raw = Int(((t - start) / slotLen).rounded())
                let slot = ((raw % slots) + slots) % slots
                if !played[slot] || s > strength[slot] {
                    played[slot] = true
                    offset[slot] = Float(t - (start + Double(raw) * slotLen))
                    strength[slot] = s
                }
            }
            // Agreement: of the slots the pattern predicted, how many were played.
            var predicted = 0, confirmed = 0
            for slot in 0..<slots where pattern.weights[lane * slots + slot] >= tuning.minWeight {
                predicted += 1
                if played[slot] { confirmed += 1 }
            }
            if predicted > 0 {
                agreement[lane] += (Float(confirmed) / Float(predicted) - agreement[lane]) * tuning.agreementRate
            }
            for slot in 0..<slots {
                let i = lane * slots + slot
                pattern.weights[i] += ((played[slot] ? 1 : 0) - pattern.weights[i]) * tuning.learnRate
                if played[slot] {
                    // The first time a slot is played, take its timing outright.
                    let first = pattern.strengths[i] == 0
                    pattern.offsets[i] += (offset[slot] - pattern.offsets[i]) * (first ? 1 : 0.3)
                    pattern.strengths[i] += (strength[slot] - pattern.strengths[i]) * (first ? 1 : 0.3)
                }
            }
        }
        bars += 1
    }

    // MARK: - Published pattern (any thread)

    private static let mirrorLock = NSLock()
    nonisolated(unsafe) private static var mirror = GroovePattern.none

    static func published() -> GroovePattern {
        mirrorLock.lock()
        defer { mirrorLock.unlock() }
        return mirror
    }

    static func publish(_ pattern: GroovePattern) {
        mirrorLock.lock()
        mirror = pattern
        mirrorLock.unlock()
    }
}
