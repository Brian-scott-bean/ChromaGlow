// EnvelopeStripMathTests.swift
// HueHome Pro — Unit Tests
//
// EnvelopeStripView's pure sampling: curve bounds for every shape at
// parameter extremes, the preview window clamp, thumbnail canon, playhead
// wrap, and swell's attack monotonicity.

import XCTest
@testable import HueHome

final class EnvelopeStripMathTests: XCTestCase {

    func testCurvePointsBoundedForAllShapesAtExtremes() {
        for shape in EnvelopeConfig.Shape.allCases {
            for (bpm, depth, attack, decay, duty) in [
                (20.0, 0.0, 0.0, 0.0, 10.0),
                (240.0, 100.0, 100.0, 100.0, 90.0),
                (60.0, 50.0, 50.0, 50.0, 50.0)
            ] {
                let env = EnvelopeConfig(shape: shape, bpm: bpm, depth: depth,
                                         attack: attack, decay: decay, dutyCycle: duty,
                                         minBrightness: 0, maxBrightness: 100)
                let points = EnvelopeStripMath.curvePoints(env)
                XCTAssertEqual(points.count, 48)
                for v in points {
                    XCTAssertTrue((0.0...1.0).contains(v),
                                  "\(shape) curve out of bounds: \(v)")
                }
            }
        }
    }

    func testPreviewWindowClampsFastBPMOnly() {
        let fast = EnvelopeConfig(shape: .pulse, bpm: 240)   // 0.25s period
        XCTAssertEqual(EnvelopeStripMath.previewWindow(fast),
                       LookPreviewMath.fastestAllowedPeriod, accuracy: 0.0001)
        let slow = EnvelopeConfig(shape: .breathe, bpm: 40)  // 1.5s period
        XCTAssertEqual(EnvelopeStripMath.previewWindow(slow), 1.5, accuracy: 0.0001)
        XCTAssertEqual(EnvelopeStripMath.previewWindow(EnvelopeConfig(shape: .flicker)),
                       3.0, accuracy: 0.0001)
    }

    func testThumbnailsAreCanonicalSixteenPoints() {
        for shape in EnvelopeConfig.Shape.allCases {
            let thumb = EnvelopeStripMath.thumbnail(for: shape)
            XCTAssertEqual(thumb.count, 16)
            XCTAssertTrue(thumb.allSatisfy { (0.0...1.0).contains($0) })
        }
        // Steady must be flat at max; pulse must actually switch.
        let steady = EnvelopeStripMath.thumbnail(for: .steady)
        XCTAssertTrue(steady.allSatisfy { abs($0 - 1.0) < 0.0001 })
        let pulse = EnvelopeStripMath.thumbnail(for: .pulse)
        XCTAssertTrue(pulse.contains { $0 > 0.9 } && pulse.contains { $0 < 0.1 })
    }

    func testPlayheadWrapsIntoUnitRange() {
        let env = EnvelopeConfig(shape: .breathe, bpm: 60)
        for t in stride(from: 0.0, through: 12.0, by: 0.37) {
            let p = EnvelopeStripMath.playheadPhase(time: t, envelope: env)
            XCTAssertTrue((0.0..<1.0).contains(p) || abs(p - 1.0) < 0.0001)
        }
    }

    func testSwellRisesMonotonicallyThroughItsAttack() {
        let env = EnvelopeConfig(shape: .swell, bpm: 60, depth: 100,
                                 attack: 100, decay: 50,
                                 minBrightness: 0, maxBrightness: 100)
        // attack 100 → riseEnd = 0.8 of the cycle; sample within it.
        let period = 60.0 / 60.0
        var last = -1.0
        for t in stride(from: 0.0, through: period * 0.75, by: period * 0.05) {
            let v = env.value(at: t)
            XCTAssertGreaterThanOrEqual(v + 0.0001, last, "swell dipped during attack")
            last = v
        }
    }
}
