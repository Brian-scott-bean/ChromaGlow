// SongEnergy.swift
// ChromaGlow — Core/Audio ("it knows what's coming", step 2: build 921)
//
// Where the song's energy is going: calm, groove, build, peak (the drop) or
// breakdown — and, in a build, WHEN the drop will land. Decided once a bar
// (and watched every beat for the gap before a drop) from the bar history
// SongStructureTracker keeps (build 920):
//  • level: this bar's loudness within the song's own range (the last 32
//    bars, 10th percentile … loudest);
//  • a build: the loudness climbing over 4 bars, the low end taken away
//    (the bass line or the sub-bass gone against the bars before), hits
//    getting denser (a snare roll doubling), and the top end turning to
//    noise (a riser) — the cues the literature names (research doc §4). Two
//    bars of it in a row enter the build (and freeze "the bars before" as
//    its reference); two bars without leave it;
//  • the drop is staged on the next phrase line (the phrase grid, build
//    920) — or, when the grid is unsure, the next 4-, 8- or 16-bar line from
//    the build's start — and CONFIRMED when the drums and the low end (the
//    bass line, or the sub-bass back to its pre-build level) come back, loud,
//    within a bar of it. If they don't, the state eases back: no drop.
//    A one-beat gap (the sound falling away just before a line) raises the
//    confidence that the drop is on the next one.
// No published method predicts a drop live (Yadati 2014: F 0.61 within ±3 s,
// offline), so this is a staged guess with an honest confidence; the
// Conductor (build 922) only does anything drastic at high confidence.
//
// THREADING CONTRACT: owned by SongStructureTracker (one writer).

import Foundation

enum SongEnergyState: String, Sendable, Equatable, CaseIterable {
    case unknown, calm, groove, build, peak, breakdown
}

struct SongEnergyTuning: Sendable, Equatable {
    /// Bars of history the song's level range is taken from.
    var rangeBars = 32
    /// Bars heard before any state but `unknown`.
    var minBars = 4
    /// Build score (0…1) to enter a build, two bars running; and below which
    /// two bars running leave it.
    var buildEnter = 0.5
    var buildEnterAtOnce = 0.7
    var buildLeave = 0.25
    /// The cues' weights in the build score.
    var riseWeight = 0.35
    var lowGoneWeight = 0.3
    var denserWeight = 0.2
    var riserWeight = 0.15
    /// A drop must arrive within this many bars after its line.
    var confirmBars = 1.0
    /// Bars after a drop before a new build may start.
    var quietAfterDrop = 4
    /// A beat whose band level falls by this much (log units, mean over the
    /// bands) against the 4 before it is a gap.
    var gapDrop: Float = 0.8
    var gapBoost = 0.3

    static let standard = SongEnergyTuning()
}

/// The song's energy now (part of the published SongStructure).
struct SongEnergy: Sendable, Equatable {
    var state: SongEnergyState = .unknown
    /// 0…1: where the latest bar's energy sits in the song's range.
    var level: Double = 0
    /// 0…1: the latest bar's build score.
    var buildScore: Double = 0
    /// Host time the build began (0 = not building).
    var buildStart: Double = 0
    /// The staged drop (host time; 0 = none) and how sure (0…1).
    var dropAt: Double = 0
    var dropConfidence: Double = 0
    /// The latest drop that came (host time; 0 = none yet).
    var lastDropAt: Double = 0

    static let none = SongEnergy()

    /// 0…1 through the build toward the staged drop at `t` (0 when none).
    func buildProgress(at t: Double) -> Double {
        guard state == .build, dropAt > buildStart, buildStart > 0 else { return 0 }
        return min(1, max(0, (t - buildStart) / (dropAt - buildStart)))
    }
}

final class SongEnergyTracker {
    let tuning: SongEnergyTuning
    private(set) var energy = SongEnergy.none
    private var aboveEnter = 0
    private var belowLeave = 0
    private var barsSinceDrop = Int.max / 2
    private var gapSeenAt = 0.0
    private var recentBeatLevels: [Float] = []

    init(tuning: SongEnergyTuning = .standard) { self.tuning = tuning }

    func reset() {
        energy = .none
        aboveEnter = 0
        belowLeave = 0
        barsSinceDrop = Int.max / 2
        gapSeenAt = 0
        recentBeatLevels = []
        reference = Reference()
        lastBuildBar = nil
        subLo = 0; subSpan = 1
    }

    /// A beat finished (`level` = its mean band level): watch for the gap —
    /// the sound falling away just before a line. A staged drop more than a
    /// bar away moves to where the gap ends; either way the call firms up.
    func beatFinished(level: Float, end: Double, structure: SongStructure) {
        defer {
            recentBeatLevels.append(level)
            if recentBeatLevels.count > 4 { recentBeatLevels.removeFirst() }
        }
        guard energy.state == .build, recentBeatLevels.count == 4 else { return }
        let before = recentBeatLevels.reduce(0, +) / 4
        if before - level >= tuning.gapDrop {
            gapSeenAt = end
            if energy.dropAt == 0 || energy.dropAt - end > structure.barSeconds { energy.dropAt = end }
            energy.dropConfidence = min(1, energy.dropConfidence + tuning.gapBoost)
        }
    }

    /// A bar finished: re-decide the state, stage or confirm the drop.
    func barFinished(_ bars: [SongBar], structure: SongStructure) {
        barsSinceDrop += 1
        guard let bar = bars.last, bars.count >= tuning.minBars else { return }
        let window = bars.suffix(tuning.rangeBars)
        let sorted = window.map(\.loudness).sorted()
        let lo = Double(sorted[Int(Double(sorted.count - 1) * 0.1)])
        let hi = Double(sorted.last ?? 0)
        let span = max(0.05, hi - lo)
        energy.level = min(1, max(0, (Double(bar.loudness) - lo) / span))
        // The song's sub-bass range: the kick and the sub are what a drop brings
        // back (the bass-line lane also hears pads and chords at 141–375 Hz).
        let subs = window.map(\.sub).sorted()
        subLo = Double(subs[Int(Double(subs.count - 1) * 0.1)])
        subSpan = max(0.2, Double(subs.last ?? 0) - subLo)

        // ── The build cues, over the last four bars, against what came before
        // (frozen at the build's start once building, so a long build doesn't
        // become its own reference) ──
        let recent = Array(bars.suffix(4))
        let rise: Double = {
            guard recent.count >= 3 else { return 0 }
            let n = Double(recent.count)
            let xs = (0..<recent.count).map(Double.init)
            let mx = xs.reduce(0, +) / n, my = recent.reduce(0) { $0 + Double($1.loudness) } / n
            var num = 0.0, den = 0.0
            for (i, b) in recent.enumerated() { num += (xs[i] - mx) * (Double(b.loudness) - my); den += (xs[i] - mx) * (xs[i] - mx) }
            let slope = den > 0 ? num / den : 0           // log units per bar
            return min(1, max(0, slope / (span / 8)))     // an eighth of the range per bar = all in
        }()
        let before = energy.state == .build ? reference : Reference(bars.dropLast(4).suffix(4))
        let bassGone = min(1, max(0, (before.bass - Double(bar.bass)) / 0.5))
        let subGone = min(1, max(0, (before.sub - Double(bar.sub)) / 1.0))
        let lowGone = max(bassGone, subGone)
        let denser = min(1, max(0, (Double(bar.density) / max(0.25, before.density) - 1) / 1.5))
        let riser: Double = {
            guard let first = recent.first, recent.count >= 3 else { return 0 }
            let flat = Double(bar.flatness - first.flatness) / 0.1
            let high = Double(bar.high - first.high) / max(0.05, Double(first.high) + 0.05)
            return min(1, max(0, 0.5 * flat + 0.5 * high))
        }()
        var score = tuning.riseWeight * rise + tuning.lowGoneWeight * lowGone
            + tuning.denserWeight * denser + tuning.riserWeight * riser
        // The low end back at full: not a build.
        if lowGone < 0.2 && energy.level >= 0.8 { score *= 0.5 }
        energy.buildScore = min(1, score)

        let now = bar.end
        if energy.state == .build {
            // ── A staged drop: did it come? ──
            if energy.dropAt > 0, now >= energy.dropAt + 0.25 * structure.barSeconds {
                let landed = bars.suffix(2).first { $0.end > energy.dropAt && $0.start < energy.dropAt + tuning.confirmBars * structure.barSeconds }
                if let d = landed, isDrop(d, built: reference, lastBuildBar: lastBuildBar, lo: lo, span: span) {
                    energy.state = .peak
                    energy.lastDropAt = energy.dropAt
                    endBuild()
                    barsSinceDrop = 0
                    return
                }
                if now >= energy.dropAt + tuning.confirmBars * structure.barSeconds {
                    // It didn't come: ease back.
                    endBuild()
                    energy.state = settledState(bar, level: energy.level, bars: bars)
                    return
                }
            }
            if energy.dropAt == 0 || now < energy.dropAt { lastBuildBar = bar }
            maxScore = max(maxScore, energy.buildScore)
            // A staged build holds until its line. Before that it ends only if
            // the low end comes back in full (it resolved without a drop).
            let lowBack = reference.sub >= subLo + 0.5 * subSpan && Double(bar.sub) >= reference.sub - 0.2 && bar.drums >= 0.5
            if lowBack { belowLeave += 1 } else { belowLeave = 0 }
            if belowLeave >= 2, energy.dropAt == 0 || now < energy.dropAt - structure.barSeconds {
                endBuild()
                energy.state = settledState(bar, level: energy.level, bars: bars)
                return
            }
            maturity = max(maturity, denser)
            stageDrop(now: now, structure: structure)
            return
        }
        if energy.buildScore >= tuning.buildEnter, barsSinceDrop >= tuning.quietAfterDrop { aboveEnter += 1 } else { aboveEnter = 0 }
        // Two bars of build, or one unmistakable one.
        if aboveEnter >= 2 || (aboveEnter == 1 && energy.buildScore >= tuning.buildEnterAtOnce) {
            energy.state = .build
            energy.buildStart = bars[bars.count - aboveEnter].start
            // What the song was like before the build: the four bars before it.
            reference = Reference(bars.dropLast(2).suffix(4))
            lastBuildBar = bar
            maxScore = energy.buildScore
            maturity = denser
            belowLeave = 0
            stageDrop(now: now, structure: structure)
            return
        }
        energy.state = settledState(bar, level: energy.level, bars: bars)
    }

    /// The bars before a build: its low end and how busy its drums were.
    private struct Reference {
        var bass = 0.0, sub = 0.0, density = 0.25
        init() {}
        init<C: Collection>(_ bars: C) where C.Element == SongBar {
            guard !bars.isEmpty else { return }
            let n = Double(bars.count)
            bass = bars.reduce(0) { $0 + Double($1.bass) } / n
            sub = bars.reduce(0) { $0 + Double($1.sub) } / n
            density = max(0.25, bars.reduce(0) { $0 + Double($1.density) } / n)
        }
    }
    private var reference = Reference()
    private var maxScore = 0.0
    /// How "late" the build sounds: its hits against the bars before it
    /// (a snare roll at sixteenths, not quarters) — tells a 16-bar build's
    /// midpoint from its end.
    private var maturity = 0.0
    private var subLo = 0.0, subSpan = 1.0
    private var lastBuildBar: SongBar?

    /// The drop: drums in, the kick and sub-bass back (to where they were
    /// before the build, or well above the build's last bar, and in the top
    /// half of the song's sub range), and loud — near the song's loudest, so
    /// a verse coming back is "back", not a drop.
    private func isDrop(_ d: SongBar, built ref: Reference, lastBuildBar: SongBar?, lo: Double, span: Double) -> Bool {
        guard d.drums >= 0.4, Double(d.loudness) >= lo + 0.7 * span,
              Double(d.sub) >= subLo + 0.5 * subSpan else { return false }
        return Double(d.sub) >= ref.sub - 0.3 || (lastBuildBar.map { d.sub - $0.sub >= 0.8 } ?? false)
    }

    private func endBuild() {
        lastBuildBar = nil
        maxScore = 0
        maturity = 0
        energy.buildStart = 0
        energy.dropAt = 0
        energy.dropConfidence = 0
        aboveEnter = 0
        belowLeave = 0
    }

    /// Where the drop lands: the next phrase line (build 920) — builds end
    /// on one in dance music — with the confidence scaled by how sure the
    /// phrase grid is. When the grid is unsure and the clock's bar line is
    /// within a beat of that phrase line, the bar line wins (a drop lands on
    /// a downbeat). With no phrase grid at all: the next 4-, 8- or 16-bar
    /// line from the build's start.
    private func stageDrop(now: Double, structure: SongStructure) {
        guard structure.hasSong else { return }
        let bar = structure.barSeconds, beat = structure.beatSeconds
        var at = 0.0
        let phraseLine = structure.nextPhraseStart(after: now - 0.25 * beat)
        if structure.phraseConfidence > 0, phraseLine > 0 {
            at = phraseLine
            if structure.phraseConfidence < 0.5, structure.currentBarStart > 0 {
                let barLine = structure.currentBarStart + ((at - structure.currentBarStart) / bar).rounded() * bar
                if abs(barLine - at) <= 1.01 * beat, barLine > now { at = barLine }
            }
        } else {
            for bars in [4.0, 8, 16] where energy.buildStart + bars * bar > now {
                at = energy.buildStart + bars * bar
                break
            }
        }
        // A gap seen in the last beat or two keeps its "now".
        if gapSeenAt > 0, now - gapSeenAt < 2 * beat, energy.dropAt > 0 { at = min(at, energy.dropAt) }
        energy.dropAt = at
        // How sure: the strongest build evidence so far, the phrase grid's
        // confidence, and how late the build sounds (its hits against the
        // bars before it) — a 16-bar build's midpoint is a phrase line too.
        let evidence = max(maxScore, energy.buildScore)
        energy.dropConfidence = min(1, evidence * (0.4 + 0.6 * structure.phraseConfidence) * (0.3 + 0.7 * maturity) * 1.8)
    }

    /// Not building: the state the bar's level and instrumentation say.
    private func settledState(_ bar: SongBar, level: Double, bars: [SongBar]) -> SongEnergyState {
        if bar.drums >= 0.5 && level >= 0.75 { return .peak }
        let hadDrums = bars.dropLast().contains { $0.drums >= 0.5 }
        if bar.drums < 0.3 && hadDrums { return .breakdown }
        if level < 0.3 { return .calm }
        return .groove
    }
}
