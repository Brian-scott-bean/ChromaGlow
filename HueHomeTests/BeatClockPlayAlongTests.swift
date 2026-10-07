// BeatClockPlayAlongTests.swift
// HueHome Pro — Unit Tests (Play Along P1)
//
// BeatClock's tracker drive: phase and bar confidence, bar re-labels by whole
// beats, the user's "one" outranking every guess, and the music-service
// drive learning the track's beat offset instead of fighting the microphone
// back to track t=0 (measured 70–130 ms off before).

import XCTest
@testable import HueHome

@MainActor
final class BeatClockPlayAlongTests: XCTestCase {

    private var clock: BeatClock!

    override func setUp() {
        super.setUp()
        clock = BeatClock()
        clock.clear()
    }

    override func tearDown() {
        clock.clear()
        super.tearDown()
    }

    private func observation(bpm: Double = 120, lastBeat: Double, confidence: Double = 0.9,
                             barSlot: Int? = nil, barConfidence: Double = 0) -> BeatObservation {
        BeatObservation(bpm: bpm, lastBeat: lastBeat, tempoConfidence: confidence,
                        phaseConfidence: confidence, barSlot: barSlot, barConfidence: barConfidence)
    }

    /// Signed ms from the grid's nearest beat to `t`.
    private func phaseErrorMs(at t: Double) -> Double {
        let s = BeatClock.snapshot()
        let ph = s.beatPhase(at: t)
        return (ph < 0.5 ? ph : ph - 1) * s.beatInterval * 1000
    }

    func testFirstLockAdoptsTempoPhaseAndAConfidentBar() {
        // Downbeats two beats after the last beat: 10.0 + 2 × 0.5 = 11.0.
        clock.ingest(observation: observation(lastBeat: 10, barSlot: 2, barConfidence: 0.8))
        let s = BeatClock.snapshot()
        XCTAssertEqual(s.bpm, 120)
        XCTAssertEqual(s.beatPhase(at: 10), 0, accuracy: 1e-9)
        XCTAssertEqual(s.barPhase(at: 11), 0, accuracy: 1e-9)
        XCTAssertEqual(s.phaseConfidence, 0.9)
        XCTAssertEqual(s.barConfidence, 0.8)
        XCTAssertEqual(clock.source, .audio)
    }

    func testABarReLabelNeedsThreePassesAndNeverMovesABeat() {
        clock.ingest(observation: observation(lastBeat: 10))            // no bar opinion yet
        XCTAssertEqual(BeatClock.snapshot().barPhase(at: 10), 0, accuracy: 1e-9)
        // The tracker now says the one falls a beat after its last beat.
        for (pass, beat) in [10.5, 11.0].enumerated() {
            clock.ingest(observation: observation(lastBeat: beat, barSlot: (1 - pass * 1 + 4) % 4, barConfidence: 0.7))
        }
        XCTAssertEqual(BeatClock.snapshot().barPhase(at: 10), 0, accuracy: 1e-9, "two passes are not enough")
        clock.ingest(observation: observation(lastBeat: 11.5, barSlot: 3, barConfidence: 0.7))
        let s = BeatClock.snapshot()
        XCTAssertEqual(s.barPhase(at: 11.0), 0, accuracy: 1e-9, "the one moved to 11.0")
        XCTAssertEqual(s.barPhase(at: 13.0), 0, accuracy: 1e-9, "…and every two seconds after")
        XCTAssertEqual(s.beatPhase(at: 11.5), 0, accuracy: 1e-9, "beats stay where they were")
        XCTAssertEqual(s.barConfidence, 0.7)
    }

    func testTheUsersOneOutranksTheTracker() {
        clock.ingest(observation: observation(lastBeat: 10))
        clock.resyncDownbeat(now: 10.5)
        for beat in [11.0, 11.5, 12.0, 12.5] {
            clock.ingest(observation: observation(lastBeat: beat, barSlot: 0, barConfidence: 0.9))
        }
        XCTAssertEqual(BeatClock.snapshot().barPhase(at: 12.5), 0, accuracy: 1e-6)
        XCTAssertEqual(BeatClock.snapshot().barConfidence, 1)
    }

    func testDoubleTimeUnderAServiceHoldMayNotMoveThePhase() {
        clock.driveFromTrack(bpm: 87, position: PlaybackPosition(positionMs: 0, capturedAt: 100, isPlaying: true),
                             now: 100)
        let before = BeatClock.snapshot()
        // A tracker at 174 could be naming our off-beats.
        clock.ingest(observation: observation(bpm: 174, lastBeat: 100.3))
        XCTAssertEqual(BeatClock.snapshot().beatEpoch, before.beatEpoch)
    }

    /// The song's first beat lands 0.37 s in: the service grid (beat 1 at
    /// t=0) is 130 ms late. The mic pulls toward the truth; the drive learns
    /// the offset and stops pulling back — and keeps it when the mic stops.
    func testTheServiceDriveLearnsTheTracksBeatOffset() {
        let interval = 0.5, leadIn = 0.37, t0 = 100.0
        func trueBeat(nearest t: Double) -> Double {
            let k = ((t - t0 - leadIn) / interval).rounded(.down)
            return t0 + leadIn + k * interval
        }
        var t = t0
        while t < t0 + 20 {
            if Int((t - t0) * 10) % 10 == 0 {
                clock.driveFromTrack(bpm: 120, position: PlaybackPosition(positionMs: Int((t - t0) * 1000),
                                                                           capturedAt: t, isPlaying: true),
                                     now: t)
            }
            clock.ingest(observation: observation(lastBeat: trueBeat(nearest: t)))
            t += 0.5
        }
        XCTAssertLessThan(abs(phaseErrorMs(at: trueBeat(nearest: t) + interval)), 5, "locked to the real beat")
        XCTAssertNotNil(clock.serviceBeatOffset)

        // The mic goes quiet (headphones): the service alone now holds the
        // learned offset, no longer the t=0 guess.
        while t < t0 + 40 {
            clock.driveFromTrack(bpm: 120, position: PlaybackPosition(positionMs: Int((t - t0) * 1000),
                                                                       capturedAt: t, isPlaying: true),
                                 now: t)
            t += 1
        }
        XCTAssertLessThan(abs(phaseErrorMs(at: trueBeat(nearest: t) + interval)), 5)
        XCTAssertGreaterThanOrEqual(BeatClock.snapshot().phaseConfidence, 0.5)
    }

    func testATrackChangeForgetsTheOffsetAndTheUsersOne() {
        clock.driveFromTrack(bpm: 120, position: PlaybackPosition(positionMs: 0, capturedAt: 100, isPlaying: true),
                             beatOffset: 0.37, now: 100)
        XCTAssertNotNil(clock.serviceBeatOffset)
        clock.resyncDownbeat(now: 101)
        clock.endServiceDrive(trackChanged: true)
        XCTAssertNil(clock.serviceBeatOffset)
        clock.ingest(observation: observation(lastBeat: 105, barSlot: 1, barConfidence: 0.9))
        XCTAssertLessThan(BeatClock.snapshot().barConfidence, 1, "the next song's one is a guess again")
    }

    func testAPauseKeepsTheOffset() {
        clock.driveFromTrack(bpm: 120, position: PlaybackPosition(positionMs: 0, capturedAt: 100, isPlaying: true),
                             beatOffset: 0.37, now: 100)
        clock.endServiceDrive()
        XCTAssertNotNil(clock.serviceBeatOffset)
    }

    func testAServiceGridIsOnlyAPhaseGuess() {
        clock.driveFromTrack(bpm: 120, position: PlaybackPosition(positionMs: 0, capturedAt: 100, isPlaying: true),
                             now: 100)
        XCTAssertLessThan(BeatClock.snapshot().phaseConfidence, 0.5)
        clock.clear()
        clock.driveFromTrack(bpm: 120, position: PlaybackPosition(positionMs: 0, capturedAt: 100, isPlaying: true),
                             beatOffset: 0.37, now: 100)
        XCTAssertGreaterThanOrEqual(BeatClock.snapshot().phaseConfidence, 0.5, "a remembered offset is trusted")
        XCTAssertEqual(BeatClock.snapshot().beatPhase(at: 100.37), 0, accuracy: 1e-9)
    }
}
