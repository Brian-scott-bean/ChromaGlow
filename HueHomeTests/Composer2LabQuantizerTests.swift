// Composer2LabQuantizerTests.swift
// HueHome Pro — Unit Tests (Play Along P4)
//
// On the One: where changes land (bar, half bar, beat — never more than a
// bar away), when the play-along look takes over and lets go, and a look
// switch that crossfades onto the next bar line.

import XCTest
@testable import HueHome

@MainActor
final class Composer2LabQuantizerTests: XCTestCase {

    /// 120 BPM, epoch at 1000: beats every 0.5 s, bars every 2 s.
    private func clock(phase: Double = 0.9, bar: Double = 0.9) -> BeatSnapshot {
        BeatSnapshot(bpm: 120, beatEpoch: 1000, beatsPerBar: 4, phaseConfidence: phase, barConfidence: bar)
    }

    func testTheGridFollowsWhatTheClockKnows() {
        XCTAssertEqual(Composer2Quantizer.grid(for: clock(bar: 0.9)), .bar)
        XCTAssertEqual(Composer2Quantizer.grid(for: clock(bar: 0.3)), .halfBar)
        XCTAssertEqual(Composer2Quantizer.grid(for: clock(bar: 0.1)), .beat)
        XCTAssertNil(Composer2Quantizer.grid(for: clock(phase: 0.1)), "no trusted beat: change at once")
        XCTAssertNil(Composer2Quantizer.grid(for: .none))
    }

    func testBoundaries() {
        XCTAssertEqual(Composer2Quantizer.nextBoundary(after: 1000.7, beat: clock(), grid: .bar)!, 1002, accuracy: 1e-9)
        XCTAssertEqual(Composer2Quantizer.nextBoundary(after: 1000.7, beat: clock(), grid: .halfBar)!, 1001, accuracy: 1e-9)
        XCTAssertEqual(Composer2Quantizer.nextBoundary(after: 1000.7, beat: clock(), grid: .beat)!, 1001, accuracy: 1e-9)
        XCTAssertEqual(Composer2Quantizer.nextBoundary(after: 1002, beat: clock(), grid: .bar)!, 1004, accuracy: 1e-9,
                       "strictly after: a change asked ON the one lands on the next one")
    }

    func testALandingLeavesRoomForThePrerollAndNeverWaitsMoreThanABar() {
        let beat = clock()
        let preroll = Composer2Quantizer.preroll(for: beat)
        XCTAssertEqual(preroll, 0.25, accuracy: 1e-9)
        XCTAssertEqual(Composer2Quantizer.landing(after: 1000.5, beat: beat)!.time, 1002, accuracy: 1e-9)
        XCTAssertEqual(Composer2Quantizer.landing(after: 1001.9, beat: beat)!.time, 1004, accuracy: 1e-9,
                       "100 ms before the one is too late for a 250 ms crossfade")
        for t in stride(from: 1000.0, to: 1004.0, by: 0.05) {
            let wait = Composer2Quantizer.landing(after: t, beat: beat)!.time - t
            XCTAssertLessThanOrEqual(wait, 2 + preroll + 1e-9)
        }
    }

    // MARK: - Director

    func testPlayAlongWaitsForABeatThenLandsOnTheOne() {
        var director = Composer2PlayAlongDirector()
        director.requested = true
        XCTAssertEqual(director.update(at: 1000.3, beat: .none).weight, 0, "no beat yet: the plain look")
        let mix = director.update(at: 1000.5, beat: clock())
        XCTAssertEqual(mix.weight, 0)
        XCTAssertEqual(mix.bpm, 120)
        XCTAssertEqual(director.update(at: 1001.875, beat: clock()).weight, 0.5, accuracy: 0.01, "half way through the crossfade")
        XCTAssertEqual(director.update(at: 1002.0, beat: clock()).weight, 1, "fully playing along on the one")
        XCTAssertEqual(director.phase, .engaged)
    }

    func testTurningItOffGlidesBackOnTheOne() {
        var director = Composer2PlayAlongDirector()
        director.requested = true
        _ = director.update(at: 1000.5, beat: clock())
        _ = director.update(at: 1002.0, beat: clock())
        director.requested = false
        XCTAssertEqual(director.update(at: 1002.1, beat: clock()).weight, 1, "still playing along until the next one")
        XCTAssertEqual(director.update(at: 1004.0, beat: clock()).weight, 0, accuracy: 1e-9)
        _ = director.update(at: 1004.01, beat: clock())
        XCTAssertEqual(director.phase, .idle)
    }

    func testADropoutCoastsThenLetsGoAfterTwentySeconds() {
        var director = Composer2PlayAlongDirector()
        director.requested = true
        _ = director.update(at: 1000.5, beat: clock())
        _ = director.update(at: 1002.0, beat: clock())
        let lost = clock(phase: 0.1)
        XCTAssertEqual(director.update(at: 1005, beat: lost).weight, 1, "a dropout coasts on the last grid")
        XCTAssertEqual(director.update(at: 1024.9, beat: lost).weight, 1)
        _ = director.update(at: 1025.1, beat: lost)
        XCTAssertLessThan(director.update(at: 1026.5, beat: lost).weight, 1, "after 20 s it glides back")
        XCTAssertEqual(director.update(at: 1027.2, beat: lost).weight, 0)
    }

    func testANewSongsTempoRederives() {
        var director = Composer2PlayAlongDirector()
        director.requested = true
        _ = director.update(at: 1000.5, beat: clock())
        _ = director.update(at: 1002.0, beat: clock())
        let faster = BeatSnapshot(bpm: 128, beatEpoch: 1003, beatsPerBar: 4, phaseConfidence: 0.9, barConfidence: 0.9)
        XCTAssertEqual(director.update(at: 1004, beat: faster).bpm, 128)
    }

    // MARK: - A look switch on the one

    func testALookSwitchCrossfadesOntoTheNextBarLine() {
        func look(x: Double, y: Double) -> Composer2Composition {
            var layer = Composer2Layer.blank(name: "Solid")
            layer.color = Composer2ColorSource(stops: [Composer2PaletteStop(x: x, y: y)], distribution: .uniform)
            layer.motion = Composer2Motion(kind: .static)
            return Composer2Composition(name: "Solid", createdAt: Date(timeIntervalSince1970: 0), layers: [layer])
        }
        let red = Composer2LiveOutput(composition: look(x: 0.64, y: 0.33))
        let blue = Composer2LiveOutput(composition: look(x: 0.17, y: 0.07))
        let landing = Composer2LandingSource(outgoing: red, incoming: blue)
        let box = CompositionParamBox(palette: PaletteConfig(), motion: MotionConfig(), envelope: EnvelopeConfig(),
                                      reaction: ReactionConfig())
        func x(at host: Double) -> Double {
            landing.renderFrames(time: host - 1000, channelIDs: [0], params: box, features: .silent,
                                 beat: clock(), hostNow: host).first!.x
        }
        let redX = x(at: 1000.5)
        XCTAssertGreaterThan(redX, 0.5, "the old look until the preroll")
        XCTAssertEqual(x(at: 1001.6), redX, accuracy: 1e-6)
        let mid = x(at: 1001.875)
        XCTAssertTrue(mid < redX && mid > 0.2, "crossfading")
        XCTAssertLessThan(x(at: 1002.0), 0.25, "the new look owns the room on the one")
        XCTAssertTrue(landing.hasLanded)
    }
}
