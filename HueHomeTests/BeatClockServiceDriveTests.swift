// BeatClockServiceDriveTests.swift
// HueHome Pro — Unit Tests
//
// The BeatClock service drive (music integration R1): a playing track's
// position + known BPM steer the clock. Pins the priority order
// (tap/manual pin > service > audio), the phase math, gentle-vs-hard
// re-anchoring, and the fallback behavior when a session ends.
//
// All times are explicit — no CACurrentMediaTime, no flakiness.

import XCTest
@testable import HueHome

@MainActor
final class BeatClockServiceDriveTests: XCTestCase {

    override func tearDown() {
        // The snapshot mirror is process-global; leave it zeroed.
        BeatClock().clear()
        super.tearDown()
    }

    private func position(ms: Int, at t: Double, playing: Bool = true) -> PlaybackPosition {
        PlaybackPosition(positionMs: ms, capturedAt: t, isPlaying: playing)
    }

    // MARK: - Adoption + phase math

    func testFirstDriveAdoptsTempoAndPhase() {
        let clock = BeatClock()
        clock.driveFromTrack(bpm: 120, position: position(ms: 10_000, at: 100), now: 100)
        XCTAssertEqual(clock.bpm, 120)
        XCTAssertEqual(clock.source, .service)
        XCTAssertEqual(clock.confidence, 1.0)
        XCTAssertFalse(clock.isPinned)
        let snap = BeatClock.snapshot()
        // Track t=0 fell at host time 90 → grid phase 0 there, 0.5 mid-beat.
        XCTAssertEqual(snap.beatPhase(at: 90.0), 0, accuracy: 1e-9)
        XCTAssertEqual(snap.beatPhase(at: 90.25), 0.5, accuracy: 1e-9)
    }

    func testDriveExtrapolatesStalePositionSample() {
        let clock = BeatClock()
        // Sample captured 2 s ago: 10 s into the track at t=100, driven at t=102.
        clock.driveFromTrack(bpm: 120, position: position(ms: 10_000, at: 100), now: 102)
        // Track position now = 12 s → epoch = 102 − 12 = 90.
        XCTAssertEqual(BeatClock.snapshot().beatPhase(at: 90.0), 0, accuracy: 1e-9)
    }

    func testRepollJitterIsGentlyCorrected() {
        let clock = BeatClock()
        clock.driveFromTrack(bpm: 120, position: position(ms: 10_000, at: 100), now: 100)
        let before = BeatClock.snapshot().beatEpoch
        // Next poll implies the grid sits 50 ms later (within the 120 ms
        // resync threshold) — correction must clamp to ≤30 ms.
        clock.driveFromTrack(bpm: 120, position: position(ms: 19_950, at: 110), now: 110)
        let after = BeatClock.snapshot().beatEpoch
        XCTAssertEqual(after - before, 0.030, accuracy: 1e-9,
                       "50 ms of poll jitter must move the epoch by exactly the 30 ms cap")
    }

    func testSeekHardResyncsPastThreshold() {
        let clock = BeatClock()
        clock.driveFromTrack(bpm: 120, position: position(ms: 10_000, at: 100), now: 100)
        // Seek: the track grid now sits 200 ms off ours (> 120 ms threshold).
        clock.driveFromTrack(bpm: 120, position: position(ms: 24_800, at: 110), now: 110)
        // Hard re-anchor: epoch adopts the seek's grid outright (85.2).
        XCTAssertEqual(BeatClock.snapshot().beatEpoch, 85.2, accuracy: 1e-9)
    }

    func testOnGridSeekNeedsNoResync() {
        let clock = BeatClock()
        clock.driveFromTrack(bpm: 120, position: position(ms: 10_000, at: 100), now: 100)
        // A whole-beat jump lands exactly on the existing grid — phase error
        // 0, epoch unchanged, and that is correct (nothing to fix).
        clock.driveFromTrack(bpm: 120, position: position(ms: 15_000, at: 105), now: 105)
        XCTAssertEqual(BeatClock.snapshot().beatEpoch, 90.0, accuracy: 1e-9)
    }

    // MARK: - Rejection guards

    func testPausedPositionDoesNotDrive() {
        let clock = BeatClock()
        clock.driveFromTrack(bpm: 120, position: position(ms: 10_000, at: 100, playing: false), now: 100)
        XCTAssertEqual(clock.bpm, 0)
        XCTAssertEqual(clock.source, .none)
    }

    func testOutOfRangeBPMIsRejectedNotClamped() {
        let clock = BeatClock()
        clock.driveFromTrack(bpm: 10, position: position(ms: 0, at: 100), now: 100)
        clock.driveFromTrack(bpm: 500, position: position(ms: 0, at: 100), now: 100)
        XCTAssertEqual(clock.bpm, 0, "garbage sidecar BPMs must not bend the clock")
        XCTAssertEqual(clock.source, .none)
    }

    // MARK: - Priority: pin > service > audio

    func testTapPinBeatsServiceDrive() {
        let clock = BeatClock()
        clock.driveFromTrack(bpm: 120, position: position(ms: 0, at: 100), now: 100)
        for i in 0..<4 { clock.tap(now: 200.0 + Double(i) * 0.6) }   // 100 BPM
        XCTAssertEqual(clock.source, .tap)
        clock.driveFromTrack(bpm: 128, position: position(ms: 5_000, at: 203), now: 203)
        XCTAssertEqual(clock.bpm, 100, accuracy: 0.5, "service must not override a tapped pin")
        XCTAssertEqual(clock.source, .tap)
    }

    func testIngestCannotStealWhileServiceHolds() {
        let clock = BeatClock()
        clock.driveFromTrack(bpm: 120, position: position(ms: 0, at: 100), now: 100)
        clock.ingest(estimate: TempoEstimate(bpm: 97, confidence: 0.9, lastBeatOffset: 0), endTime: 101)
        XCTAssertEqual(clock.bpm, 120, "mic guess must not override the track's known BPM")
        XCTAssertEqual(clock.source, .service)
        XCTAssertEqual(clock.confidence, 1.0, "service confidence display must not flap to the mic's")
    }

    func testUnpinReturnsToServiceWhileSessionActive() {
        let clock = BeatClock()
        clock.driveFromTrack(bpm: 120, position: position(ms: 0, at: 100), now: 100)
        clock.setBPM(90, now: 101)
        XCTAssertEqual(clock.source, .manual)
        clock.unpin(now: 102)
        XCTAssertEqual(clock.source, .service,
                       "unpin during an active music session returns to the service drive")
    }

    // MARK: - Session end

    func testEndServiceDriveFallsBackToAudioKeepingTempo() {
        let clock = BeatClock()
        clock.driveFromTrack(bpm: 120, position: position(ms: 0, at: 100), now: 100)
        clock.endServiceDrive()
        XCTAssertEqual(clock.source, .audio, "the look keeps running at the last tempo")
        XCTAssertEqual(clock.bpm, 120)
        // The mic pass may now retake the clock.
        clock.ingest(estimate: TempoEstimate(bpm: 97, confidence: 0.9, lastBeatOffset: 0), endTime: 105)
        XCTAssertEqual(clock.bpm, 97, accuracy: 0.01)
    }

    func testEndServiceDriveWithNoSessionIsNoOp() {
        let clock = BeatClock()
        clock.setBPM(110, now: 100)
        clock.endServiceDrive()
        XCTAssertEqual(clock.source, .manual)
        XCTAssertEqual(clock.bpm, 110)
    }

    func testClearResetsServiceHold() {
        let clock = BeatClock()
        clock.driveFromTrack(bpm: 120, position: position(ms: 0, at: 100), now: 100)
        clock.clear()
        XCTAssertEqual(clock.bpm, 0)
        clock.ingest(estimate: TempoEstimate(bpm: 97, confidence: 0.9, lastBeatOffset: 0), endTime: 105)
        XCTAssertEqual(clock.bpm, 97, accuracy: 0.01, "clear() must release the service hold")
        XCTAssertEqual(clock.source, .audio)
    }

    // MARK: - Mic phase-assist (R7: sidecar BPM carries no phase)

    func testMicPhaseAssistNudgesPhaseOnlyWhileServiceHolds() {
        let clock = BeatClock()
        clock.driveFromTrack(bpm: 120, position: position(ms: 0, at: 100), now: 100)  // epoch 100
        // Mic hears the actual beat 100 ms later than our grid claims.
        clock.ingest(estimate: TempoEstimate(bpm: 100, confidence: 0.9, lastBeatOffset: 0),
                     endTime: 101.1)
        XCTAssertEqual(clock.bpm, 120, "the track's known BPM must never yield to the mic guess")
        XCTAssertEqual(clock.source, .service)
        XCTAssertEqual(clock.confidence, 1.0, "confidence display stays the service's")
        XCTAssertEqual(BeatClock.snapshot().beatEpoch, 100.03, accuracy: 1e-9,
                       "phase converges toward the mic anchor at the 30 ms cap")
    }

    func testPhaseAssistIgnoresLowConfidenceEstimates() {
        let clock = BeatClock()
        clock.driveFromTrack(bpm: 120, position: position(ms: 0, at: 100), now: 100)
        clock.ingest(estimate: TempoEstimate(bpm: 100, confidence: 0.3, lastBeatOffset: 0),
                     endTime: 101.1)
        XCTAssertEqual(BeatClock.snapshot().beatEpoch, 100.0, accuracy: 1e-9)
    }

    func testStaleServiceDriveSelfHeals() {
        let clock = BeatClock()
        clock.driveFromTrack(bpm: 120, position: position(ms: 0, at: 100), now: 100)
        // The source died without endServiceDrive; 11 s later the mic pass
        // must be able to reclaim the clock.
        clock.ingest(estimate: TempoEstimate(bpm: 97, confidence: 0.9, lastBeatOffset: 0),
                     endTime: 111)
        XCTAssertEqual(clock.bpm, 97, accuracy: 0.01, "stale hold must release")
        XCTAssertEqual(clock.source, .audio)
        XCTAssertFalse(clock.isServiceDriven)
    }

    func testServiceHoldSurvivesWithinTimeout() {
        let clock = BeatClock()
        clock.driveFromTrack(bpm: 120, position: position(ms: 0, at: 100), now: 100)
        clock.ingest(estimate: TempoEstimate(bpm: 97, confidence: 0.9, lastBeatOffset: 0),
                     endTime: 105)
        XCTAssertEqual(clock.bpm, 120)
        XCTAssertTrue(clock.isServiceDriven(now: 105))
    }

    // MARK: - Stale-aware isServiceDriven (audit R9)

    func testIsServiceDrivenGoesStaleWithoutIngest() {
        let clock = BeatClock()
        clock.driveFromTrack(bpm: 120, position: position(ms: 0, at: 100), now: 100)
        XCTAssertTrue(clock.isServiceDriven(now: 109),
                      "a fresh drive reports service-driven")
        XCTAssertFalse(clock.isServiceDriven(now: 111),
                       "past the timeout the flag must clear WITHOUT an ingest — " +
                       "mic demand is suppressed by this very flag, so no ingest may come")
    }

    func testDriveRefreshKeepsServiceDrivenAlive() {
        let clock = BeatClock()
        clock.driveFromTrack(bpm: 120, position: position(ms: 0, at: 100), now: 100)
        clock.driveFromTrack(bpm: 120, position: position(ms: 9_000, at: 109), now: 109)
        XCTAssertTrue(clock.isServiceDriven(now: 118),
                      "each poll refreshes the hold's lease")
    }

    func testUnpinDuringStaleHoldFallsToAudio() {
        let clock = BeatClock()
        clock.driveFromTrack(bpm: 120, position: position(ms: 0, at: 100), now: 100)
        clock.tap(now: 101)   // pin freezes the drive refresh
        clock.unpin(now: 120) // 20 s later: the hold's lease is long dead
        XCTAssertEqual(clock.source, .audio,
                       "unpin after the drive died must not label a dead session 'Music'")
    }

    // MARK: - Pin blocks the phase nudge (audit R9)

    func testPinnedBlocksServiceHoldPhaseNudge() {
        let clock = BeatClock()
        clock.driveFromTrack(bpm: 120, position: position(ms: 0, at: 100), now: 100)  // epoch 100
        clock.tap(now: 100.2)   // pin re-anchors the epoch; serviceHold stays set
        let pinnedEpoch = BeatClock.snapshot().beatEpoch
        let pinnedConfidence = clock.confidence
        // Confident mic estimate 100 ms off the pinned grid — before the fix
        // this nudged the pinned epoch 30 ms per ingest.
        clock.ingest(estimate: TempoEstimate(bpm: 100, confidence: 0.9, lastBeatOffset: 0),
                     endTime: 101.1)
        XCTAssertEqual(BeatClock.snapshot().beatEpoch, pinnedEpoch, accuracy: 1e-9,
                       "the mic may not move a pinned epoch, service hold or not")
        XCTAssertEqual(clock.confidence, pinnedConfidence, accuracy: 1e-9,
                       "the confidence display stays the pin's while the hold is live")
    }

    // MARK: - Contract stability

    func testDriveSourceRawValuesAreStable() {
        XCTAssertEqual(BeatClock.DriveSource.none.rawValue, "none")
        XCTAssertEqual(BeatClock.DriveSource.tap.rawValue, "tap")
        XCTAssertEqual(BeatClock.DriveSource.manual.rawValue, "manual")
        XCTAssertEqual(BeatClock.DriveSource.audio.rawValue, "audio")
        XCTAssertEqual(BeatClock.DriveSource.service.rawValue, "service")
    }
}
