// BeatTrackerTests.swift
// HueHome Pro — Unit Tests (Play Along P1)
//
// The production front end + tracker + clock on deterministic synthetic room
// music, scored the way the lights would have used the grid (latest clock
// before each true beat). The beat lab (docs/ios/play-along/beatlab) runs
// the same comparison with longer songs and the old tracker beside it.

import XCTest
@testable import HueHome

@MainActor
final class BeatTrackerTests: XCTestCase {

    private typealias Synth = PlayAlongTestSynth

    override func tearDown() {
        BeatClock().clear()   // the snapshot mirror is process-wide
        super.tearDown()
    }

    private func assertLocks(_ song: Synth.Song, file: StaticString = #filePath, line: UInt = #line) {
        let r = Synth.render(song)
        let score = Synth.score(Synth.track(r), beats: r.beats, bpm: song.bpm)
        XCTAssertGreaterThan(score.beatsScored, 20, file: file, line: line)
        XCTAssertGreaterThanOrEqual(score.tempoShare, 0.95, "tempo \(song.bpm)", file: file, line: line)
        XCTAssertLessThanOrEqual(score.medianAbsMs, 10, "median beat error \(song.bpm)", file: file, line: line)
        XCTAssertLessThanOrEqual(score.p90AbsMs, 25, "p90 beat error \(song.bpm)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(score.downbeatShare, 0.9, "bar 1 \(song.bpm)", file: file, line: line)
    }

    func testLocksRockAt120() {
        assertLocks(.init(bpm: 120, leadIn: 0.37, bars: 12))
    }

    func testLocksAFractionalTempo() {
        assertLocks(.init(bpm: 100.5, leadIn: 0.6, bars: 10))
    }

    func testLocksFourOnTheFloor() {
        assertLocks(.init(bpm: 124, leadIn: 0.3, bars: 13, kickOnAllFour: true))
    }

    /// The old tracker read a kick-heavy 128 as a different tempo entirely.
    func testLocksRockAt128() {
        assertLocks(.init(bpm: 128, leadIn: 0.21, bars: 14))
    }

    func testFirstLockComesWithinSevenSeconds() {
        let song = Synth.Song(bpm: 120, leadIn: 0.37, bars: 6)
        let r = Synth.render(song)
        let snaps = Synth.track(r)
        let locked = snaps.first { $0.snap.bpm > 0 && abs($0.snap.bpm / 120 - 1) < 0.02 }
        XCTAssertNotNil(locked)
        XCTAssertLessThanOrEqual(locked!.t - song.leadIn, 7)
    }

    // MARK: - Nothing to lock to

    private func confidentShare(_ snaps: [(t: Double, snap: BeatSnapshot, confidence: Double)]) -> Double {
        let after = snaps.filter { $0.t > 5 }
        guard !after.isEmpty else { return 0 }
        return Double(after.filter { $0.snap.bpm > 0 && $0.confidence >= 0.5 }.count) / Double(after.count)
    }

    func testNoConfidentBeatInSpeechLikeBursts() {
        let r = Synth.render(.init(bpm: 100, leadIn: 0.2, bars: 10, bursts: true))
        XCTAssertLessThanOrEqual(confidentShare(Synth.track(r)), 0.05)
    }

    func testNoConfidentBeatInRoomNoise() {
        let r = Synth.render(.init(bpm: 100, leadIn: 0.2, bars: 10, drums: false, bass: false, chords: false),
                             noise: 0.02)
        XCTAssertLessThanOrEqual(confidentShare(Synth.track(r)), 0.05)
    }

    /// Audit B4: a music service's tempo used to floor the tracker's
    /// confidence at 0.72 whenever its tempo matched — so room noise or
    /// speech, with a song playing somewhere the mic can't hear, read as a
    /// confident beat and the lock never let go. The service tempo still
    /// picks the tempo; only the room's own evidence makes it confident.
    func testAServiceTempoDoesNotMakeRoomNoiseABeat() {
        let r = Synth.render(.init(bpm: 100, leadIn: 0.2, bars: 10, drums: false, bass: false, chords: false),
                             noise: 0.02)
        XCTAssertLessThanOrEqual(confidentShare(Synth.track(r, prior: TempoPrior(bpm: 100, strength: 0.8))), 0.05)
    }

    func testAServiceTempoDoesNotMakeSpeechABeat() {
        let r = Synth.render(.init(bpm: 100, leadIn: 0.2, bars: 10, bursts: true))
        XCTAssertLessThanOrEqual(confidentShare(Synth.track(r, prior: TempoPrior(bpm: 100, strength: 0.8))), 0.05)
    }

    func testAServiceTempoStillLocksTheMusicItMatches() {
        let r = Synth.render(.init(bpm: 120, leadIn: 0.37, bars: 12))
        let snaps = Synth.track(r, prior: TempoPrior(bpm: 120, strength: 0.8))
        XCTAssertGreaterThanOrEqual(confidentShare(snaps), 0.8)
        XCTAssertEqual(snaps.last?.snap.bpm ?? 0, 120, accuracy: 1)
    }

    // MARK: - Metre

    /// Alone, the tracker prefers the lighting tempo (87 for a 174 track).
    /// A tempo the music service knows settles it.
    func testAKnownTempoSettlesTheMetre() {
        let r = Synth.render(.init(bpm: 174, leadIn: 0.12, bars: 24))
        let alone = Synth.track(r).last!.snap.bpm
        XCTAssertEqual(alone, 87, accuracy: 2, "half time on its own")
        let told = Synth.track(r, prior: TempoPrior(bpm: 174, strength: 0.8)).last!.snap.bpm
        XCTAssertEqual(told, 174, accuracy: 2)
    }

    // MARK: - Pure pieces

    func testSilenceStartsTheNextSongFresh() {
        let tracker = BeatTracker()
        var frames = OnsetFrames()
        frames.frameRate = 100
        frames.bandCount = OnsetFrameAnalyzer.bandCount
        for i in 0..<900 {
            let t = Double(i) / 100
            let quiet = (400..<500).contains(i)
            frames.times.append(t)
            frames.flux.append(i % 50 == 0 && !quiet ? 5 : 0.1)
            frames.low.append(0); frames.mid.append(0); frames.high.append(0)
            frames.energy.append(quiet ? 0.1 : 3)
            frames.bands.append(contentsOf: [Float](repeating: quiet ? 0.1 : 3, count: frames.bandCount))
        }
        _ = tracker.update(frames)
        XCTAssertEqual(tracker.windowFloor, 4.99, accuracy: 0.011, "the window restarts after the quiet second")
    }

    func testSameMeterRecognisesOctaves() {
        XCTAssertTrue(BeatTracker.isSameMeter(120, 120.5))
        XCTAssertTrue(BeatTracker.isSameMeter(87, 174))
        XCTAssertTrue(BeatTracker.isSameMeter(174, 87))
        XCTAssertFalse(BeatTracker.isSameMeter(120, 128))
        XCTAssertFalse(BeatTracker.isSameMeter(0, 120))
    }
}
