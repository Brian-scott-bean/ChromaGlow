// AppleMusicMappingTests.swift
// HueHome Pro — Unit Tests
//
// AppleMusicEntrySnapshot (music integration R3): the pure seam between
// MusicKit values and NowPlayingTrack, plus the poll-cadence truth table.
// MusicKit types can't be constructed in tests — everything behind the
// seam is what gets pinned.

import XCTest
@testable import HueHome

final class AppleMusicMappingTests: XCTestCase {

    func testFullSnapshotMapsToTrack() {
        let snapshot = AppleMusicEntrySnapshot(
            title: "Golden Hour",
            artistName: "Ava Lane",
            isrc: "QM123",
            appleMusicID: "1445959394",
            durationSeconds: 214.98,
            artworkURL: URL(string: "https://example.com/art.jpg")
        )
        let track = snapshot.track()
        XCTAssertEqual(track.service, .appleMusic)
        XCTAssertEqual(track.title, "Golden Hour")
        XCTAssertEqual(track.artist, "Ava Lane")
        XCTAssertEqual(track.isrc, "QM123")
        XCTAssertEqual(track.appleMusicID, "1445959394")
        XCTAssertEqual(track.durationMs, 214_980, "seconds must round to whole ms")
        XCTAssertEqual(track.artworkURL?.absoluteString, "https://example.com/art.jpg")
        XCTAssertNil(track.tempoHint, "Apple Music has no BPM — the resolver owns tempo")
    }

    func testSparseSnapshotMapsWithNils() {
        let track = AppleMusicEntrySnapshot(
            title: "Some Video", artistName: "", isrc: nil,
            appleMusicID: nil, durationSeconds: nil, artworkURL: nil
        ).track()
        XCTAssertNil(track.isrc)
        XCTAssertNil(track.durationMs)
        XCTAssertNil(track.artworkURL)
    }

    func testPollCadenceTruthTable() {
        XCTAssertTrue(AppleMusicEntrySnapshot.shouldPoll(isPlaying: true, isBackgrounded: false))
        XCTAssertFalse(AppleMusicEntrySnapshot.shouldPoll(isPlaying: false, isBackgrounded: false),
                       "paused → no poll (position can't move)")
        XCTAssertFalse(AppleMusicEntrySnapshot.shouldPoll(isPlaying: true, isBackgrounded: true),
                       "backgrounded → no poll (battery promise for Gate-B QA)")
        XCTAssertFalse(AppleMusicEntrySnapshot.shouldPoll(isPlaying: false, isBackgrounded: true))
    }
}
