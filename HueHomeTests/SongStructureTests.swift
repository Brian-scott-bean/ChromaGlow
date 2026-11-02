// SongStructureTests.swift
// HueHome Pro — Unit Tests ("it knows what's coming", step 1: song position and phrases, build 920)
//
// The bar count that only moves forward, a new song on a new tempo or a lost
// grid, the phrase grid landing where the music changes, the prior a song
// starting from silence gives, the per-bar features, and the snapshot's
// arithmetic. Synthetic frames and grids; real-music numbers are the beat
// lab's `run.sh -phrase`.

import XCTest
@testable import HueHome

final class SongStructureTests: XCTestCase {

    private let bpm = 120.0
    private var barSeconds: Double { 4 * 60 / bpm }

    private func grid(epoch: Double = 0, bpm: Double = 120, confidence: Double = 1) -> BeatSnapshot {
        BeatSnapshot(bpm: bpm, beatEpoch: epoch, beatsPerBar: 4, phaseConfidence: confidence, barConfidence: 1)
    }

    /// What plays at time t: a level for every band, the slow lanes, and
    /// whether a drum hit lands on this 10 ms frame.
    private struct Sound { var level: Float; var bass: Float = 0; var drums: Float = 0; var hit = false }

    /// 100 Hz frames over [from, to).
    private func frames(from: Double, to: Double, _ sound: (Double) -> Sound) -> OnsetFrames {
        var f = OnsetFrames()
        f.bandCount = OnsetFrameAnalyzer.bandCount
        f.frameRate = 100
        // Frame times as exact hundredths (adding 0.01 over and over drifts
        // a frame at a bar line into the bar before).
        var k = Int((from * 100).rounded(.up))
        while Double(k) / 100 < to {
            let t = Double(k) / 100
            let s = sound(t)
            f.times.append(t)
            f.energy.append(s.level)
            f.flux.append(s.hit ? 2 : 0)
            f.low.append(s.hit ? 1 : 0)
            f.mid.append(0)
            f.high.append(s.hit ? 1 : 0)
            for b in 0..<f.bandCount { f.bands.append(s.level * (b < 4 ? 1 + s.bass : 1)) }
            f.kick.append(s.hit ? 1 : 0)
            f.snare.append(0)
            f.hat.append(0)
            f.bassActivity.append(s.bass)
            f.drumActivity.append(s.drums)
            k += 1
        }
        return f
    }

    /// Runs the tracker every 0.5 s from `start` to `end`, the engine's way:
    /// the last 12 s of frames and the clock's grid at that moment.
    @discardableResult
    private func run(_ tracker: SongStructureTracker, from start: Double, to end: Double,
                     grid: (Double) -> BeatSnapshot, _ sound: @escaping (Double) -> Sound) -> [SongStructure] {
        var out: [SongStructure] = []
        var now = start
        while now <= end {
            out.append(tracker.update(frames(from: max(0, now - 12), to: now, sound), beat: grid(now)))
            now += 0.5
        }
        return out
    }

    // MARK: - Song position

    func testTheBarCountOnlyMovesForward() {
        // 120 BPM; at 30 s the clock re-labels the one by a beat, and it
        // nudges its phase by 20 ms now and then.
        let tracker = SongStructureTracker()
        let snaps = run(tracker, from: 1, to: 60, grid: { t in
            let relabel = t >= 30 ? 0.5 : 0
            let nudge = (Int(t) % 7 == 0) ? 0.02 : 0
            return self.grid(epoch: relabel + nudge)
        }) { _ in Sound(level: 3) }
        let counts = snaps.map(\.barsCompleted)
        XCTAssertEqual(counts, counts.sorted(), "never backwards")
        XCTAssertTrue(zip(counts.dropFirst(), counts).allSatisfy { $0 - $1 <= 1 }, "never two bars in one pass")
        // 59 s at 2 s a bar ≈ 29 bars (one bar a beat longer at the re-label).
        XCTAssertEqual(Double(counts.last ?? 0), 29, accuracy: 1)
        XCTAssertEqual(tracker.bars.count, counts.last)
        let lengths = tracker.bars.map { $0.end - $0.start }
        XCTAssertTrue(lengths.allSatisfy { $0 > 1.4 && $0 < 2.6 }, "a re-label makes one bar a beat longer, no more")
    }

    func testANewTempoIsANewSong() {
        let tracker = SongStructureTracker()
        run(tracker, from: 1, to: 20, grid: { _ in self.grid() }) { _ in Sound(level: 3) }
        let before = tracker.structure
        XCTAssertGreaterThan(before.barsCompleted, 6)
        run(tracker, from: 20.5, to: 22, grid: { _ in self.grid(bpm: 128) }) { _ in Sound(level: 3) }
        XCTAssertNotEqual(tracker.structure.songStart, before.songStart)
        XCTAssertLessThanOrEqual(tracker.structure.barsCompleted, 1, "counting again")
        XCTAssertEqual(tracker.structure.barSeconds, 4 * 60 / 128, accuracy: 1e-9)
    }

    func testLosingTheGridEndsTheSong() {
        let tracker = SongStructureTracker()
        run(tracker, from: 1, to: 20, grid: { _ in self.grid() }) { _ in Sound(level: 3) }
        XCTAssertTrue(tracker.structure.hasSong)
        run(tracker, from: 20.5, to: 23, grid: { _ in self.grid(confidence: 0.2) }) { _ in Sound(level: 3) }
        XCTAssertTrue(tracker.structure.hasSong, "a moment without the grid is not the end")
        run(tracker, from: 23.5, to: 26, grid: { _ in self.grid(confidence: 0.2) }) { _ in Sound(level: 3) }
        XCTAssertFalse(tracker.structure.hasSong, "about 4 s without it is")
    }

    // MARK: - Phrases

    func testPhrasesLandWhereTheMusicChanges() {
        // Sections of 8 bars, the first starting on song bar 3: loud with the
        // bass and drums, then quiet without, and so on.
        let tracker = SongStructureTracker()
        let sectionStart = 3 * barSeconds
        run(tracker, from: 1, to: 100, grid: { _ in self.grid() }) { t in
            let section = Int(floor((t - sectionStart) / (8 * self.barSeconds)))
            let full = ((section % 2) + 2) % 2 == 0
            return Sound(level: full ? 4 : 2, bass: full ? 1 : 0, drums: full ? 1 : 0, hit: full && Int(t * 100) % 50 == 0)
        }
        let s = tracker.structure
        XCTAssertGreaterThan(s.phraseConfidence, 0.3)
        // The next phrase start the tracker expects is a section start.
        let now = 100.0
        let next = s.nextPhraseStart(after: now)
        let k = ((next - sectionStart) / (8 * barSeconds))
        XCTAssertEqual(k, k.rounded(), accuracy: 0.01, "phrases start where the sections do")
        XCTAssertGreaterThan(next, now)
        XCTAssertLessThanOrEqual(next - now, 8 * barSeconds + 1e-9)
    }

    func testASongFromSilenceStartsAPhrase() {
        // Silence, then music from 4.0 s (a bar line); the clock locks at 9 s.
        let tracker = SongStructureTracker()
        run(tracker, from: 9, to: 11, grid: { _ in self.grid() }) { t in Sound(level: t < 4 ? 0 : 3) }
        let s = tracker.structure
        XCTAssertTrue(s.hasSong)
        // The beat the music started on is a phrase start — a guess, not a certainty.
        XCTAssertEqual(s.beatInPhrase(at: 4.0 + 0.1), 0)
        XCTAssertGreaterThan(s.phraseConfidence, 0.2)
        XCTAssertLessThanOrEqual(s.phraseConfidence, 0.5)
        XCTAssertEqual(s.nextPhraseStart(after: 11), 4.0 + 8 * barSeconds, accuracy: 1e-6)
    }

    // MARK: - What each bar sounded like

    func testBarFeatures() {
        let tracker = SongStructureTracker()
        // Bars alternate: level 3, a hit every half second (one per beat), the
        // bass line and drums playing; then level 1 and nothing.
        run(tracker, from: 1, to: 30, grid: { _ in self.grid() }) { t in
            let odd = Int(floor(t / self.barSeconds)) % 2 == 1
            return odd ? Sound(level: 1) : Sound(level: 3, bass: 1, drums: 0.8, hit: Int((t * 100).rounded()) % 50 == 0)
        }
        let bars = tracker.bars
        XCTAssertGreaterThan(bars.count, 8)
        for bar in bars.suffix(6) {
            let odd = Int(floor((bar.start + 0.01) / barSeconds)) % 2 == 1
            if odd {
                XCTAssertEqual(bar.energy, 1, accuracy: 0.03)
                XCTAssertEqual(bar.density, 0, accuracy: 0.01)
                XCTAssertEqual(bar.bass, 0, accuracy: 0.03)
            } else {
                XCTAssertEqual(bar.energy, 3, accuracy: 0.03)
                XCTAssertEqual(bar.density, 1, accuracy: 0.05, "a hit per beat")
                XCTAssertEqual(bar.bass, 1, accuracy: 0.03)
                XCTAssertEqual(bar.drums, 0.8, accuracy: 0.03)
            }
            XCTAssertGreaterThan(bar.change, 10, "every bar changes from the one before")
            XCTAssertTrue((0...1).contains(bar.flatness))
        }
    }

    // MARK: - The snapshot

    func testTheSnapshotsArithmetic() {
        // 120 BPM: bars of 2 s, beats of 0.5 s; phrases start on beats ≡ 8 (mod 32).
        let s = SongStructure(songStart: 10, barsCompleted: 5, currentBarStart: 20, barSeconds: 2,
                              beatsCompleted: 20, currentBeatStart: 20, beatSeconds: 0.5,
                              phraseBeats: 32, phraseOffset: 8, phraseConfidence: 0.8)
        XCTAssertEqual(s.bar(at: 20.5), 5)
        XCTAssertEqual(s.bar(at: 23), 6)
        XCTAssertEqual(s.beat(at: 20.6), 21)
        XCTAssertEqual(s.beatInPhrase(at: 20.6), 13)
        XCTAssertEqual(s.barInPhrase(at: 20.6), 3)
        XCTAssertEqual(s.phraseBars, 8)
        XCTAssertEqual(s.phraseProgress(at: 20.75), (13 + 0.5) / 32, accuracy: 1e-9)
        // Beat 40 (≡ 8 mod 32) starts at 20 + 20 × 0.5 = 30.
        XCTAssertEqual(s.nextPhraseStart(after: 20.6), 30, accuracy: 1e-9)
        XCTAssertEqual(s.nextPhraseStart(after: 30), 46, accuracy: 1e-9, "strictly after")
        XCTAssertEqual(SongStructure.none.nextPhraseStart(after: 5), 0)
        XCTAssertEqual(AudioFeatures().structure, .none)
    }
}
