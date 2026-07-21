// MicDemandPolicyTests.swift
// HueHome Pro — Unit Tests
//
// The mic-demand split (music R7, external-review point #6): a `.beat`
// reaction CONSUMES the clock but only needs the microphone when nothing
// else is driving it. requiresMic keeps its static meaning — bridge
// eligibility (canRunOnBridge) must never change with the clock's driver.

import XCTest
@testable import HueHome

@MainActor
final class MicDemandPolicyTests: XCTestCase {

    private func reaction(_ source: ReactionConfig.Source) -> ReactionConfig {
        var config = ReactionConfig()
        config.source = source
        return config
    }

    func testMicFedSourcesAlwaysNeedTheMic() {
        for source: ReactionConfig.Source in [.micAmplitude, .micBass, .micMid, .micTreble, .onset] {
            XCTAssertTrue(reaction(source).requiresMicFeatures, "\(source)")
            XCTAssertTrue(reaction(source).needsMicNow(serviceDriven: true),
                          "\(source) data comes FROM the mic — a service drive changes nothing")
            XCTAssertTrue(reaction(source).needsMicNow(serviceDriven: false), "\(source)")
        }
    }

    func testBeatNeedsMicOnlyWithoutAServiceDrive() {
        let beat = reaction(.beat)
        XCTAssertFalse(beat.requiresMicFeatures)
        XCTAssertTrue(beat.needsMicNow(serviceDriven: false),
                      "audio-follow is the headline experience when nothing drives the clock")
        XCTAssertFalse(beat.needsMicNow(serviceDriven: true),
                       "Apple Music/Shazam driving the clock must not prompt for the microphone")
    }

    func testNonReactiveSourcesNeverNeedTheMic() {
        for source: ReactionConfig.Source in [.none, .tapTempo] {
            XCTAssertFalse(reaction(source).needsMicNow(serviceDriven: false), "\(source)")
            XCTAssertFalse(reaction(source).needsMicNow(serviceDriven: true), "\(source)")
        }
    }

    func testStaticRequiresMicIsUnchangedForBridgeEligibility() {
        // canRunOnBridge == !requiresMic — a .beat preset still can't run on
        // the bridge (it has no clock), so the STATIC property keeps .beat.
        XCTAssertTrue(reaction(.beat).requiresMic)
        XCTAssertTrue(reaction(.onset).requiresMic)
        XCTAssertFalse(reaction(.tapTempo).requiresMic)
    }
}
