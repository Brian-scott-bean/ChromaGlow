// MusicSourcePickerModelTests.swift
// HueHome Pro — Unit Tests
//
// MusicSourceCatalog (music integration R2): the row-availability matrix,
// stable ordering, the DriveSource user-facing names, and the build-31
// jargon guard applied to every string the picker can show.

import XCTest
@testable import HueHome

@MainActor
final class MusicSourcePickerModelTests: XCTestCase {

    private func kinds(demo: Bool = false, sim: Bool = false,
                       appleMusic: Bool = false, spotify: Bool = false) -> [MusicSourceOption.Kind] {
        MusicSourceCatalog.options(isDemoMode: demo, isSimulator: sim,
                                   appleMusicAvailable: appleMusic,
                                   spotifyAvailable: spotify).map(\.kind)
    }

    // MARK: Availability matrix

    func testMicIsAlwaysFirstAndAlwaysPresent() {
        XCTAssertEqual(kinds().first, .mic)
        XCTAssertEqual(kinds(demo: true, sim: true, appleMusic: true, spotify: true).first, .mic)
    }

    func testDeviceRealHomeShowsMicAndAutoDetect() {
        XCTAssertEqual(kinds(), [.mic, .shazam],
                       "no dead rows: streaming sources appear only when they can actually play; mic + auto-detect always can")
    }

    func testSampleTrackRequiresDemoModeOrSimulator() {
        XCTAssertEqual(kinds(demo: true), [.mic, .shazam, .demo])
        XCTAssertEqual(kinds(sim: true), [.mic, .shazam, .demo])
        XCTAssertFalse(kinds().contains(.demo))
    }

    func testAppleMusicAndSpotifyGateOnAvailability() {
        XCTAssertEqual(kinds(appleMusic: true), [.mic, .shazam, .appleMusic])
        XCTAssertEqual(kinds(appleMusic: true, spotify: true),
                       [.mic, .shazam, .appleMusic, .spotify])
        XCTAssertFalse(kinds(spotify: false).contains(.spotify))
    }

    func testFullMatrixOrderIsStable() {
        XCTAssertEqual(kinds(demo: true, appleMusic: true, spotify: true),
                       [.mic, .shazam, .demo, .appleMusic, .spotify])
    }

    // MARK: DriveSource user-facing names

    func testDriveSourceDisplayNames() {
        XCTAssertEqual(BeatClock.DriveSource.service.displayName, "Music",
                       "'service' is developer vocabulary and must never reach the user")
        XCTAssertEqual(BeatClock.DriveSource.tap.displayName, "Tap")
        XCTAssertEqual(BeatClock.DriveSource.manual.displayName, "Manual")
        XCTAssertEqual(BeatClock.DriveSource.audio.displayName, "Audio")
        XCTAssertEqual(BeatClock.DriveSource.none.displayName, "None")
    }

    // MARK: Jargon guard (build-31 vocabulary discipline)

    func testPickerCopyContainsNoJargon() {
        let jargon = ["(REST)", "[REST", "REST_ONE_SHOT", "ENT AREA", "Runtime-only REST",
                      "rate-capped", "mock data", "low-latency", "ultra-low-latency",
                      "Wi-Fi scan (mDNS)", "CT APPROX", "\"Onset\""]
        var copy = MusicSourceCatalog.options(isDemoMode: true, isSimulator: true,
                                              appleMusicAvailable: true, spotifyAvailable: true)
            .flatMap { [$0.title, $0.subtitle] }
        copy.append(MusicSourceCatalog.pandoraFootnote)
        copy.append(MusicSourceCatalog.tempoLookupTitle)
        copy.append(MusicSourceCatalog.tempoLookupFootnote)
        for text in copy {
            for term in jargon {
                XCTAssertFalse(text.contains(term), "jargon '\(term)' found in: \(text)")
            }
        }
    }

    // MARK: Toggle key stability

    func testTempoLookupKeyIsStable() {
        // @AppStorage in the picker and the resolver's UserDefaults read
        // must stay the same string forever.
        XCTAssertEqual(TrackTempoResolver.lookupEnabledKey, "music.tempoLookupEnabled")
    }
}
