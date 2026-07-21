// ShazamPolicyTests.swift
// HueHome Pro — Unit Tests
//
// ShazamSource's pure seams (music integration R4): match-snapshot →
// track/position mapping (predictedCurrentMatchOffset is the whole point)
// and the miss policy that decides when the song is really gone.

import XCTest
@testable import HueHome

final class ShazamPolicyTests: XCTestCase {

    // MARK: - Snapshot mapping

    func testSnapshotMapsToTrackAndPosition() {
        let snapshot = ShazamMatchSnapshot(
            title: "Golden Hour",
            artist: "Ava Lane",
            isrc: "QM123",
            appleMusicID: "1445959394",
            artworkURL: URL(string: "https://example.com/a.jpg"),
            predictedOffsetSeconds: 42.5
        )
        let track = snapshot.track()
        XCTAssertEqual(track.service, .shazamDetected)
        XCTAssertEqual(track.isrc, "QM123", "ISRC is the tempo-sidecar join key")
        XCTAssertNil(track.durationMs, "Shazam doesn't know the track length")

        let position = snapshot.position(capturedAt: 100)
        XCTAssertEqual(position.positionMs, 42_500,
                       "predictedCurrentMatchOffset IS the position in the track")
        XCTAssertEqual(position.capturedAt, 100)
        XCTAssertTrue(position.isPlaying, "a match means audio is playing")
    }

    func testNegativeOffsetClampsToZero() {
        let snapshot = ShazamMatchSnapshot(
            title: "T", artist: "A", isrc: nil, appleMusicID: nil,
            artworkURL: nil, predictedOffsetSeconds: -1.2
        )
        XCTAssertEqual(snapshot.position(capturedAt: 0).positionMs, 0)
    }

    // MARK: - Miss policy

    func testMatchesKeepResettingTheMissCounter() {
        var policy = ShazamMissPolicy(missesToClear: 3)
        XCTAssertFalse(policy.recordMiss())
        XCTAssertFalse(policy.recordMiss())
        policy.recordMatch()
        XCTAssertFalse(policy.recordMiss(), "a match must reset the countdown")
        XCTAssertFalse(policy.recordMiss())
        XCTAssertTrue(policy.recordMiss(), "third consecutive miss clears")
    }

    func testClearResetsTheCounterForTheNextSong() {
        var policy = ShazamMissPolicy(missesToClear: 2)
        XCTAssertFalse(policy.recordMiss())
        XCTAssertTrue(policy.recordMiss())
        XCTAssertFalse(policy.recordMiss(), "after clearing, the count starts over")
    }

    func testDefaultThresholdIsPatientEnough() {
        // ~6 no-match callbacks ≈ half a minute of unrecognized audio —
        // song gaps and quiet bridges must not flap the Now Playing bar.
        XCTAssertEqual(ShazamMissPolicy().missesToClear, 6)
    }
}
