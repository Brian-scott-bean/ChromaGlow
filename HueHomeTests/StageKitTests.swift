// StageKitTests.swift
// HueHome Pro — Unit Tests
//
// Round 4 StageKit: the pattern-strip brightness signature is a pure
// function of (index, pattern, time) — bounded, deterministic, periodic,
// and visually distinct per pattern. No views, no clocks.

import XCTest
import SwiftUI
@testable import HueHome

final class StageKitTests: XCTestCase {

    private let allPatterns = MotionConfig.Pattern.allCases
    private let indices = Array(0..<StageStripMath.segmentCount)

    // ── Bounds ────────────────────────────────────────────────

    func testOpacityStaysInUnitIntervalForAllPatternsAndTimes() {
        for pattern in allPatterns {
            for i in indices {
                for t in stride(from: 0.0, through: 12.0, by: 0.05) {
                    let v = StageStripMath.opacity(index: i, pattern: pattern, time: t)
                    XCTAssertGreaterThanOrEqual(v, 0.0, "\(pattern) i\(i) t\(t)")
                    XCTAssertLessThanOrEqual(v, 1.0, "\(pattern) i\(i) t\(t)")
                }
            }
        }
    }

    func testOutOfRangeIndexIsClampedNotCrashing() {
        for pattern in allPatterns {
            _ = StageStripMath.opacity(index: -3, pattern: pattern, time: 1.0)
            _ = StageStripMath.opacity(index: 99, pattern: pattern, time: 1.0)
        }
    }

    // ── Determinism + wrap ────────────────────────────────────

    func testSameInputsProduceSameOutputs() {
        for pattern in allPatterns {
            for i in indices {
                let a = StageStripMath.opacity(index: i, pattern: pattern, time: 3.71)
                let b = StageStripMath.opacity(index: i, pattern: pattern, time: 3.71)
                XCTAssertEqual(a, b, "\(pattern) i\(i)")
            }
        }
    }

    /// Every pattern's signature is periodic — wrapping around its cycle
    /// produces the same value (large time offsets chosen as a common
    /// multiple of all pattern periods: 1.6, 1.8, 2.0, 2.1, 2.2, 2.4 divide
    /// 5544 evenly ⇒ ×10 scale: use LCM seconds = 5544/... simpler: check
    /// each pattern against its own known period).
    func testSignatureWrapsOverItsOwnPeriod() {
        let periods: [MotionConfig.Pattern: Double] = [
            .static: 1.0, .cascade: 1.8, .wave: 2.0, .spiral: 2.4,
            .chase: 1.6, .comet: 2.0, .pulseCenter: 2.0, .scatter: 1.8,
            .bounce: 2.2, .twinkle: 2.1,
        ]
        for (pattern, period) in periods {
            for i in indices {
                let t0 = 0.83
                let a = StageStripMath.opacity(index: i, pattern: pattern, time: t0)
                let b = StageStripMath.opacity(index: i, pattern: pattern, time: t0 + period * 3)
                XCTAssertEqual(a, b, accuracy: 1e-9, "\(pattern) i\(i) not periodic over \(period)")
            }
        }
    }

    // ── Distinct signatures ───────────────────────────────────

    /// At a fixed instant, each pattern's 8-segment vector should differ from
    /// every other pattern's (they'd be indistinguishable on the cards
    /// otherwise). Static is the only flat line.
    func testPatternsProduceDistinctSegmentVectors() {
        let t = 0.37
        var vectors: [MotionConfig.Pattern: [Double]] = [:]
        for pattern in allPatterns {
            vectors[pattern] = indices.map {
                StageStripMath.opacity(index: $0, pattern: pattern, time: t)
            }
        }
        let patterns = allPatterns
        for a in 0..<patterns.count {
            for b in (a + 1)..<patterns.count {
                let va = vectors[patterns[a]]!
                let vb = vectors[patterns[b]]!
                let distance = zip(va, vb).map { abs($0 - $1) }.reduce(0, +)
                XCTAssertGreaterThan(
                    distance, 0.05,
                    "\(patterns[a]) and \(patterns[b]) look identical at t=\(t)")
            }
        }
    }

    func testStaticIsFlatAndMidBright() {
        for i in indices {
            for t in [0.0, 1.3, 7.7] {
                XCTAssertEqual(
                    StageStripMath.opacity(index: i, pattern: .static, time: t),
                    StageStripMath.staticOpacity)
            }
        }
    }

    /// The traveling patterns must actually travel: the brightest segment
    /// changes over a half-period.
    func testTravelingPatternsMoveTheirHotCell() {
        for pattern in [MotionConfig.Pattern.cascade, .chase, .comet, .bounce] {
            func hottest(at t: Double) -> Int {
                indices.max { a, b in
                    StageStripMath.opacity(index: a, pattern: pattern, time: t)
                        < StageStripMath.opacity(index: b, pattern: pattern, time: t)
                }!
            }
            XCTAssertNotEqual(hottest(at: 0.05), hottest(at: 0.85), "\(pattern) hot cell never moved")
        }
    }

    // ── Swatch matching ───────────────────────────────────────

    /// Swatch selection uses tolerance matching because Color equality is
    /// unreliable across construction paths (hex string vs RGB components).
    func testSwatchMatchesSameColorAcrossConstructionPaths() {
        XCTAssertTrue(StageSwatchMath.matches(Color(hex: "#FF0000"), Color(red: 1, green: 0, blue: 0)))
        XCTAssertTrue(StageSwatchMath.matches(Color(hex: "#FFC107"), Color(hex: "#FFC107")))
    }

    func testSwatchRejectsDistinctColorsAndHonorsTolerance() {
        XCTAssertFalse(StageSwatchMath.matches(Color(hex: "#FF0000"), Color(hex: "#00FF00")))
        // Nearby but beyond default tolerance (~2.5/255 > 0.01).
        XCTAssertFalse(StageSwatchMath.matches(Color(red: 0.5, green: 0.5, blue: 0.5),
                                               Color(red: 0.52, green: 0.5, blue: 0.5)))
        // Same pair passes with a wider tolerance.
        XCTAssertTrue(StageSwatchMath.matches(Color(red: 0.5, green: 0.5, blue: 0.5),
                                              Color(red: 0.52, green: 0.5, blue: 0.5),
                                              tolerance: 0.05))
    }
}
