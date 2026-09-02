//
//  InstrumentControlMathTests.swift
//  HueHomeTests
//
//  Unified Customization Engine — Slice 2. Pins the pure gesture math the
//  knob/fader share, the shared exact-entry parser, and the real flash-rate
//  clamp. All pure — no views, no timing.
//

import XCTest
@testable import HueHome

final class InstrumentControlMathTests: XCTestCase {

    // ── Adaptive gain ───────────────────────────────────────────

    func testGainIsCoarseNearTheControl() {
        XCTAssertEqual(InstrumentControlMath.adaptiveGain(lateralDistance: 0), 1.0)
        XCTAssertEqual(InstrumentControlMath.adaptiveGain(lateralDistance: 59), 1.0)
        XCTAssertEqual(InstrumentControlMath.adaptiveGain(lateralDistance: -30), 1.0,
                       "distance is symmetric — either side of the axis")
    }

    func testGainDecreasesMonotonicallyWithDistance() {
        var last = 1.0
        for d in stride(from: 60.0, through: 600.0, by: 20.0) {
            let g = InstrumentControlMath.adaptiveGain(lateralDistance: d)
            XCTAssertLessThanOrEqual(g, last, "gain never increases as the finger moves away")
            last = g
        }
    }

    func testGainHasAFloorAndRecoversWhenTheFingerReturns() {
        XCTAssertEqual(InstrumentControlMath.adaptiveGain(lateralDistance: 100_000),
                       InstrumentControlMath.minGain)
        // Pure in the CURRENT distance: returning close restores coarse.
        XCTAssertEqual(InstrumentControlMath.adaptiveGain(lateralDistance: 10), 1.0)
    }

    // ── Value mapping + clamp ───────────────────────────────────

    func testFullTravelAtCoarseGainSweepsTheFullRange() {
        let delta = InstrumentControlMath.valueDelta(
            axisDelta: 220, travel: 220, range: 0...100, gain: 1.0)
        XCTAssertEqual(delta, 100, accuracy: 0.0001)
    }

    func testFineGainScalesTheDelta() {
        let delta = InstrumentControlMath.valueDelta(
            axisDelta: 220, travel: 220, range: 0...100, gain: 0.15)
        XCTAssertEqual(delta, 15, accuracy: 0.0001)
    }

    func testApplyingClampsAtBothEnds() {
        XCTAssertEqual(InstrumentControlMath.applying(delta: 500, to: 50, range: 0...100), 100)
        XCTAssertEqual(InstrumentControlMath.applying(delta: -500, to: 50, range: 0...100), 0)
    }

    // ── Semantic ticks ──────────────────────────────────────────

    func testLimitTickBeatsDefaultSnap() {
        XCTAssertEqual(InstrumentControlMath.semanticTick(
            previous: 99, new: 100, range: 0...100, defaultValue: 100), .limit)
    }

    func testDefaultSnapFiresOnCrossing() {
        XCTAssertEqual(InstrumentControlMath.semanticTick(
            previous: 48, new: 51, range: 0...100, defaultValue: 50), .defaultSnap)
        XCTAssertEqual(InstrumentControlMath.semanticTick(
            previous: 52, new: 49, range: 0...100, defaultValue: 50), .defaultSnap)
        XCTAssertNil(InstrumentControlMath.semanticTick(
            previous: 20, new: 30, range: 0...100, defaultValue: 50),
            "no tick without crossing — no buzzing")
    }

    func testStepTickFiresOnStepBoundaries() {
        XCTAssertEqual(InstrumentControlMath.semanticTick(
            previous: 10, new: 30, range: 0...100, stepCount: 4), .step(1))
        XCTAssertNil(InstrumentControlMath.semanticTick(
            previous: 30, new: 40, range: 0...100, stepCount: 4),
            "same step, no tick")
    }

    func testNoTickWhenValueUnchanged() {
        XCTAssertNil(InstrumentControlMath.semanticTick(
            previous: 50, new: 50, range: 0...100, defaultValue: 50))
    }

    // ── Exact entry (shared parser) ─────────────────────────────

    func testParseDraftClampsAndIgnoresUnitSuffixes() {
        XCTAssertEqual(StageDraftMath.parseDraft("64%", range: 0...100), 64)
        XCTAssertEqual(StageDraftMath.parseDraft("120 BPM", range: 20...300), 120)
        XCTAssertEqual(StageDraftMath.parseDraft("2700K", range: 153...500), 500,
                       "typing cannot escape the range")
        XCTAssertEqual(StageDraftMath.parseDraft("-5", range: 0...100), 0)
        XCTAssertNil(StageDraftMath.parseDraft("fast", range: 0...100))
    }

    func testStageSliderParserStaysTheSharedOne() {
        XCTAssertEqual(StageSlider.parseDraft("42", range: 0...100),
                       StageDraftMath.parseDraft("42", range: 0...100))
    }

    // ── The real flash clamp ────────────────────────────────────

    func testFlashSafetyClampsAnyHzToThree() {
        XCTAssertEqual(BeatMath.FlashSafety.clampedHz(3.0), 3.0)
        XCTAssertEqual(BeatMath.FlashSafety.clampedHz(2.0), 2.0)
        XCTAssertEqual(BeatMath.FlashSafety.clampedHz(10.0), 3.0)
        XCTAssertEqual(BeatMath.FlashSafety.clampedHz(-1.0), 0.0)
    }

    /// The defect the clamp closes: the catalog curve maps speed 0–100 into
    /// 0.5–3.0 Hz by arithmetic. If a wider speed ever reaches the engines
    /// (typed entry bug, widened range), the clamp — not the curve — holds
    /// the ceiling.
    func testWidenedSpeedCurveCannotExceedTheCeiling() {
        for speed in [0.0, 50.0, 100.0, 250.0, 1_000.0] {
            let hz = BeatMath.FlashSafety.clampedHz(0.5 + (speed / 100.0) * 2.5)
            XCTAssertLessThanOrEqual(hz, 3.0, "speed \(speed) escaped the ceiling")
        }
    }
}
