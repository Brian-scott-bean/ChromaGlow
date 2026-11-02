// SongStructure.swift
// ChromaGlow — Core/Audio ("it knows what's coming", step 1: build 920)
//
// Where we are in the song: a bar count that survives the clock's
// corrections, the phrase grid (most pop and dance music changes on 8-bar
// lines), and a history of what each bar sounded like — the ground the
// build/drop detector and the Conductor stand on.
//
//  • Song position. On the microphone, "bar 0" is wherever the clock first
//    locked, and the clock nudges its phase (≤ 30 ms a pass) and may
//    re-label the one by whole beats. The tracker counts bar lines as they
//    are PASSED, on whatever grid the clock holds at that moment, so the
//    count only ever moves forward: a re-label makes one bar a beat or two
//    longer or shorter, never a jump back. A new tempo (> 3 %) or about 4 s
//    without a trusted grid is a new song: the count starts again.
//  • Per-bar features, from the analyzer's frames (raw, NOT the auto-levelled
//    `level`, which flattens a build): energy (mean log band level), low and
//    high flux, onset density (drum hits per beat), spectral flatness, how
//    much the spectrum changed from the bar before, and the slow lanes (bass
//    line, drums playing; build 919).
//  • Phrases, in BEATS. Each beat line gets a novelty: how different the 8
//    beats after it are from the 8 before (their band levels and the slow
//    lanes). Local peaks of novelty are summed per position in a 32-beat
//    phrase (8 bars of 4), with a few phrases of memory; the phrase grid is
//    the position where changes keep happening. Counted in beats, not bars,
//    because the clock's "one" is right only about 40 % of the time on real
//    songs (beat lab): re-labelling the bar moves no beat line, so a phrase
//    grid in beats doesn't inherit that error — and where the music changes
//    is itself the best evidence of where the one is. A song that starts
//    from silence gives a prior: its first beat is a phrase start. Measured
//    in the beat lab (`run.sh -phrase`).
//
// Kept apart from BeatSnapshot (read everywhere, every frame): this is
// published through its own lock-guarded mirror and stamped on every
// AudioFeatures (`structure`), like the groove map.
//
// THREADING CONTRACT: `SongStructureTracker` has one writer (the tracker
// pass on the main actor). `SongStructure` is a value.

import Foundation

struct SongStructureTuning: Sendable, Equatable {
    /// Bars per phrase (4 beats each).
    var phraseBars = 8
    /// Phrases of memory for the phrase grid's scores.
    var memoryPhrases: Double = 3
    /// Beats on each side of a beat line its novelty compares.
    var noveltyBeats = 8
    /// Weight of the slow lanes (0…1 each) next to the band levels (log
    /// units, summed distance over 18 bands) in a beat line's novelty.
    var activityWeight: Float = 4
    /// The prior a song that starts from silence gives its first beat, in
    /// units of an above-average change.
    var onsetPrior: Double = 1
    /// Above-average changes before the phrase grid is fully trusted.
    var evidenceForConfidence: Double = 2
    /// A grid this much faster or slower is another song.
    var newTempoRatio = 0.03
    /// Seconds without a trusted grid before the song is over.
    var lostAfter = 4.0
    /// Frames this recent may still change (held drum hits are marked back).
    var settleSeconds = DrumLanes.settleSeconds
    /// The trusted grid: Play Along's threshold.
    var minPhaseConfidence = 0.5

    var phraseBeats: Int { max(1, phraseBars * 4) }

    static let standard = SongStructureTuning()
}

/// One finished bar, as it sounded.
struct SongBar: Sendable, Equatable {
    var start: Double
    var end: Double
    /// Mean log band level (the analyzer's `energy`): raw, not auto-levelled.
    var energy: Float = 0
    /// Mean rectified flux per frame, low (< 281 Hz) and high (≥ 2.8 kHz).
    var low: Float = 0
    var high: Float = 0
    /// Kick, snare and hi-hat hits per beat.
    var density: Float = 0
    /// Spectral flatness of the bar's mean band energies (0 tonal … 1 noise).
    var flatness: Float = 0
    /// Distance from the previous bar's band levels (0 for the first).
    var change: Float = 0
    /// The slow lanes, averaged over the bar.
    var bass: Float = 0
    var drums: Float = 0
    /// Mean band levels (log).
    var bands: [Float] = []
}

/// Where we are in the song (the published value).
struct SongStructure: Sendable, Equatable {
    /// Host time bar 0 began (0 = no song yet).
    var songStart: Double = 0
    /// Bars finished since `songStart` (on the clock's bar lines); the bar
    /// now playing has this index.
    var barsCompleted = 0
    /// Host time the latest finished bar ended (= the current bar's start).
    var currentBarStart: Double = 0
    var barSeconds: Double = 0
    /// Beats finished since the song's first beat line; the beat now playing
    /// has this index. Phrases are placed on beats (see the file header).
    var beatsCompleted = 0
    var currentBeatStart: Double = 0
    var beatSeconds: Double = 0
    var phraseBeats = 32
    /// Phrases start on beats whose index ≡ this (mod `phraseBeats`).
    var phraseOffset = 0
    /// 0…1: how clearly the changes keep landing on that phrase grid.
    var phraseConfidence: Double = 0

    static let none = SongStructure()

    var hasSong: Bool { songStart > 0 && barSeconds > 0 && beatSeconds > 0 }
    var phraseBars: Int { max(1, phraseBeats / 4) }

    /// The bar index (song position) playing at `t`.
    func bar(at t: Double) -> Int {
        guard hasSong else { return 0 }
        return barsCompleted + Int(floor((t - currentBarStart) / barSeconds))
    }

    /// The beat index playing at `t`.
    func beat(at t: Double) -> Int {
        guard hasSong else { return 0 }
        return beatsCompleted + Int(floor((t - currentBeatStart) / beatSeconds))
    }

    /// 0..<phraseBeats: the beat within its phrase at `t`.
    func beatInPhrase(at t: Double) -> Int {
        let p = max(1, phraseBeats)
        return (((beat(at: t) - phraseOffset) % p) + p) % p
    }

    /// 0..<phraseBars: the bar within its phrase at `t` (bars counted from
    /// the phrase's start, which may not be the clock's "one").
    func barInPhrase(at t: Double) -> Int { beatInPhrase(at: t) / 4 }

    /// 0..<1 through the phrase at `t`.
    func phraseProgress(at t: Double) -> Double {
        guard hasSong else { return 0 }
        let into = (t - currentBeatStart) / beatSeconds
        return (Double(beatInPhrase(at: t)) + into - floor(into)) / Double(max(1, phraseBeats))
    }

    /// Host time of the first phrase start strictly after `t` (0 = no song).
    func nextPhraseStart(after t: Double) -> Double {
        guard hasSong else { return 0 }
        let p = max(1, phraseBeats)
        var k = beat(at: t) + 1
        k += ((phraseOffset - k) % p + p) % p
        return currentBeatStart + Double(k - beatsCompleted) * beatSeconds
    }
}

final class SongStructureTracker {
    let tuning: SongStructureTuning
    /// The finished bars of this song (the last 64).
    private(set) var bars: [SongBar] = []
    private(set) var structure = SongStructure.none
    private var songBPM = 0.0
    private var lastBarLine = 0.0
    private var lastBeatLine = 0.0
    private var lastTrusted = 0.0
    /// Per finished beat: its mean band levels and slow lanes (the last 64).
    private var beatBands: [[Float]] = []
    private var beatActivity: [(bass: Float, drums: Float)] = []
    /// Novelty of recent beat lines, by beat index (the last few).
    private var novelty: [(beat: Int, value: Double)] = []
    private var scores: [Double]
    private var noveltyMean = 0.0
    private var noveltyCount = 0

    static let historyBars = 64
    static let historyBeats = 64

    init(tuning: SongStructureTuning = .standard) {
        self.tuning = tuning
        scores = [Double](repeating: 0, count: tuning.phraseBeats)
    }

    func reset() {
        bars = []
        structure = .none
        songBPM = 0
        lastBarLine = 0
        lastBeatLine = 0
        lastTrusted = 0
        beatBands = []
        beatActivity = []
        novelty = []
        scores = [Double](repeating: 0, count: tuning.phraseBeats)
        noveltyMean = 0
        noveltyCount = 0
    }

    /// One tracker pass: the analyzer's recent frames and the clock's grid.
    @discardableResult
    func update(_ frames: OnsetFrames, beat: BeatSnapshot) -> SongStructure {
        guard let newest = frames.times.last else { return structure }
        let horizon = newest - tuning.settleSeconds
        let trusted = beat.bpm > 0 && beat.phaseConfidence >= tuning.minPhaseConfidence && beat.beatsPerBar > 0
        guard trusted else {
            if structure.hasSong, horizon - lastTrusted > tuning.lostAfter { reset() }
            return structure
        }
        lastTrusted = horizon
        let beatSeconds = beat.beatInterval
        let barSeconds = beatSeconds * Double(beat.beatsPerBar)
        let sameSong = structure.hasSong && abs(beat.bpm / songBPM - 1) <= tuning.newTempoRatio
        if !sameSong {
            startSong(frames, beat: beat, horizon: horizon)
            return structure
        }
        songBPM = beat.bpm
        // Every grid line passed since the last one counted, at least half a
        // beat (bar) after it: a nudge or a re-label never counts one twice.
        var nextBeat = line(after: lastBeatLine + 0.5 * beatSeconds, epoch: beat.beatEpoch, period: beatSeconds)
        while nextBeat <= horizon {
            finishBeat(start: lastBeatLine, end: nextBeat, frames: frames)
            lastBeatLine = nextBeat
            nextBeat += beatSeconds
        }
        var nextBar = line(after: lastBarLine + 0.5 * barSeconds, epoch: beat.beatEpoch, period: barSeconds)
        while nextBar <= horizon {
            finishBar(start: lastBarLine, end: nextBar, frames: frames, beatSeconds: beatSeconds)
            lastBarLine = nextBar
            nextBar += barSeconds
        }
        structure.currentBarStart = lastBarLine
        structure.barSeconds = barSeconds
        structure.currentBeatStart = lastBeatLine
        structure.beatSeconds = beatSeconds
        return structure
    }

    /// The first grid line (`epoch` + k × `period`) at or after `t`.
    private func line(after t: Double, epoch: Double, period: Double) -> Double {
        epoch + ceil((t - epoch) / period) * period
    }

    private func startSong(_ frames: OnsetFrames, beat: BeatSnapshot, horizon: Double) {
        reset()
        songBPM = beat.bpm
        lastTrusted = horizon
        let beatSeconds = beat.beatInterval
        let barSeconds = beatSeconds * Double(beat.beatsPerBar)
        // Bar 0 and beat 0 = the bar and beat now playing.
        lastBarLine = line(after: horizon - barSeconds + 1e-6, epoch: beat.beatEpoch, period: barSeconds)
        lastBeatLine = line(after: horizon - beatSeconds + 1e-6, epoch: beat.beatEpoch, period: beatSeconds)
        structure = SongStructure(songStart: lastBarLine, barsCompleted: 0, currentBarStart: lastBarLine,
                                  barSeconds: barSeconds, beatsCompleted: 0, currentBeatStart: lastBeatLine,
                                  beatSeconds: beatSeconds, phraseBeats: tuning.phraseBeats,
                                  phraseOffset: 0, phraseConfidence: 0)
        // A song that started from silence within the frames we still hold:
        // its first beat is the likeliest phrase start.
        if let onset = musicOnset(frames) {
            let onsetBeat = Int(((onset - lastBeatLine) / beatSeconds).rounded())
            let p = tuning.phraseBeats
            scores[((onsetBeat % p) + p) % p] += tuning.onsetPrior
            pickPhrase()
        }
    }

    /// The first sound after at least a second of silence, if the frames hold one.
    private func musicOnset(_ frames: OnsetFrames) -> Double? {
        guard frames.count > 100 else { return nil }
        let loud = frames.energy.max() ?? 0
        guard loud > 0 else { return nil }
        let gate = loud * BeatTracker.silenceRatio
        let need = Int(1.0 * frames.frameRate)
        var quiet = 0
        for i in 0..<frames.count {
            if frames.energy[i] < gate {
                quiet += 1
            } else {
                if quiet >= need { return frames.times[i] }
                quiet = 0
            }
        }
        return nil
    }

    /// The frames in [start, end): mean band levels and slow lanes.
    private func summary(_ frames: OnsetFrames, _ start: Double, _ end: Double)
        -> (count: Int, bands: [Float], linear: [Float], energy: Float, low: Float, high: Float, hits: Int,
            bass: Float, drums: Float) {
        let n = frames.bandCount
        var bands = [Float](repeating: 0, count: n), linear = [Float](repeating: 0, count: n)
        var count = 0, hits = 0
        var energy: Float = 0, low: Float = 0, high: Float = 0, bass: Float = 0, drums: Float = 0
        for i in 0..<frames.count where frames.times[i] >= start && frames.times[i] < end {
            count += 1
            energy += frames.energy[i]
            low += frames.low[i]
            high += frames.high[i]
            if frames.kick[i] > 0 { hits += 1 }
            if frames.snare[i] > 0 { hits += 1 }
            if frames.hat[i] > 0 { hits += 1 }
            if i < frames.bassActivity.count { bass += frames.bassActivity[i] }
            if i < frames.drumActivity.count { drums += frames.drumActivity[i] }
            for b in 0..<n {
                let level = frames.bands[i * n + b]
                bands[b] += level
                linear[b] += expm1f(level)
            }
        }
        if count > 0 {
            let c = Float(count)
            energy /= c; low /= c; high /= c; bass /= c; drums /= c
            for b in 0..<n { bands[b] /= c; linear[b] /= c }
        }
        return (count, bands, linear, energy, low, high, hits, bass, drums)
    }

    private func finishBeat(start: Double, end: Double, frames: OnsetFrames) {
        let s = summary(frames, start, end)
        beatBands.append(s.bands)
        beatActivity.append((s.bass, s.drums))
        if beatBands.count > Self.historyBeats {
            beatBands.removeFirst(beatBands.count - Self.historyBeats)
            beatActivity.removeFirst(beatActivity.count - Self.historyBeats)
        }
        structure.beatsCompleted += 1
        scorePhrases()
    }

    private func finishBar(start: Double, end: Double, frames: OnsetFrames, beatSeconds: Double) {
        let s = summary(frames, start, end)
        let n = frames.bandCount
        var bar = SongBar(start: start, end: end, energy: s.energy, low: s.low, high: s.high,
                          bass: s.bass, drums: s.drums, bands: s.bands)
        if s.count > 0 {
            let beats = Float(max(0.25, (end - start) / max(beatSeconds, 1e-3)))
            bar.density = Float(s.hits) / beats
            // Flatness: geometric over arithmetic mean of the band energies.
            var logSum: Float = 0, sum: Float = 0
            for b in 0..<n { logSum += logf(s.linear[b] + 1e-6); sum += s.linear[b] }
            bar.flatness = n > 0 && sum > 0 ? min(1, expf(logSum / Float(n)) / (sum / Float(n))) : 0
        }
        if let previous = bars.last, previous.bands.count == n {
            var d: Float = 0
            for b in 0..<n { d += abs(s.bands[b] - previous.bands[b]) }
            bar.change = d
        }
        bars.append(bar)
        if bars.count > Self.historyBars { bars.removeFirst(bars.count - Self.historyBars) }
        structure.barsCompleted += 1
    }

    /// The novelty of the beat line `noveltyBeats` back (8 beats after it vs
    /// 8 before); a local peak of novelty is credited to its position in the
    /// phrase, and the phrase grid re-chosen.
    private func scorePhrases() {
        let w = max(1, tuning.noveltyBeats)
        guard beatBands.count >= 2 * w else { return }
        let n = beatBands.last?.count ?? 0
        guard n > 0 else { return }
        let total = beatBands.count
        var d: Float = 0
        for b in 0..<n {
            var after: Float = 0, before: Float = 0
            for j in (total - w)..<total { after += beatBands[j][b] }
            for j in (total - 2 * w)..<(total - w) { before += beatBands[j][b] }
            d += abs(after - before) / Float(w)
        }
        var bassDelta: Float = 0, drumDelta: Float = 0
        for j in (total - w)..<total { bassDelta += beatActivity[j].bass; drumDelta += beatActivity[j].drums }
        for j in (total - 2 * w)..<(total - w) { bassDelta -= beatActivity[j].bass; drumDelta -= beatActivity[j].drums }
        let value = Double(d + tuning.activityWeight * (abs(bassDelta) + abs(drumDelta)) / Float(w))
        let lineBeat = structure.beatsCompleted - w       // the beat the line starts
        novelty.append((lineBeat, value))
        if novelty.count > 4 { novelty.removeFirst(novelty.count - 4) }
        noveltyCount += 1
        noveltyMean += (value - noveltyMean) / Double(min(noveltyCount, 64))

        let p = tuning.phraseBeats
        let decay = 1 - 1 / max(1, tuning.memoryPhrases * Double(p))
        for i in scores.indices { scores[i] *= decay }
        // The line one beat back is a peak if it beats both neighbours.
        if novelty.count >= 3, noveltyMean > 1e-6 {
            let (prev, peak, next) = (novelty[novelty.count - 3], novelty[novelty.count - 2], novelty[novelty.count - 1])
            if peak.value >= prev.value && peak.value > next.value {
                scores[((peak.beat % p) + p) % p] += max(0, peak.value / noveltyMean - 1)
            }
        }
        pickPhrase()
    }

    private func pickPhrase() {
        guard let best = scores.indices.max(by: { scores[$0] < scores[$1] }) else { return }
        let total = scores.reduce(0, +)
        let second = scores.indices.filter { $0 != best }.map { scores[$0] }.max() ?? 0
        structure.phraseOffset = best
        // How much of the change lands on one position, by how much it beats
        // the runner-up, and how much evidence there is at all (the silence
        // prior alone is a guess, not a certainty).
        let share = total > 1e-9 ? scores[best] / total : 0
        let margin = scores[best] > 1e-9 ? (scores[best] - second) / scores[best] : 0
        let evidence = min(1, total / max(1e-9, tuning.evidenceForConfidence))
        structure.phraseConfidence = min(1, max(0, (0.5 * share + 0.5 * margin) * evidence))
    }

    // MARK: - Published mirror (render loops read it via AudioFeatures)

    private static let mirrorLock = NSLock()
    nonisolated(unsafe) private static var mirror = SongStructure.none

    static func published() -> SongStructure {
        mirrorLock.lock()
        defer { mirrorLock.unlock() }
        return mirror
    }

    static func publish(_ structure: SongStructure) {
        mirrorLock.lock()
        mirror = structure
        mirrorLock.unlock()
    }
}
