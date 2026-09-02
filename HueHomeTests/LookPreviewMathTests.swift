// LookPreviewMathTests.swift
// HueHome Pro — Unit Tests
//
// LookPreview's pure sampling: output bounds for every pattern × envelope
// shape at parameter extremes, the preview-only photosensitivity clamp
// (no preview may flash faster than the floor even at max speed/bpm), and
// spec equatability (card diffing relies on it).

import XCTest
import SwiftUI
@testable import HueHome

final class LookPreviewMathTests: XCTestCase {

    private func spec(pattern: MotionConfig.Pattern, shape: EnvelopeConfig.Shape,
                      speed: Double, bpm: Double, depth: Double = 100,
                      duty: Double = 10) -> LookPreviewSpec {
        LookPreviewSpec(
            palette: PaletteConfig(),
            pattern: pattern,
            speed: speed,
            envelope: EnvelopeConfig(shape: shape, bpm: bpm, depth: depth,
                                     attack: 100, decay: 100, dutyCycle: duty,
                                     minBrightness: 0, maxBrightness: 100),
            accent: .orange
        )
    }

    // ── Bounds: every pattern × shape × extremes stays in 0…1 ──

    func testSampleStaysInBoundsAcrossAllPatternsAndShapes() {
        for pattern in MotionConfig.Pattern.allCases {
            for shape in EnvelopeConfig.Shape.allCases {
                for (speed, bpm) in [(0.0, 20.0), (100.0, 240.0), (50.0, 60.0)] {
                    let s = spec(pattern: pattern, shape: shape, speed: speed, bpm: bpm)
                    for step in 0..<48 {
                        let t = Double(step) * 0.173
                        for i in 0..<8 {
                            let out = LookPreviewMath.sample(index: i, count: 8, spec: s, time: t)
                            XCTAssertTrue((0.0...1.0).contains(out.phase),
                                          "\(pattern)/\(shape) phase out of bounds")
                            XCTAssertTrue((0.0...1.0).contains(out.level),
                                          "\(pattern)/\(shape) level out of bounds")
                        }
                    }
                }
            }
        }
    }

    // ── Photosensitivity: previews never flash faster than the floor ──

    /// Counts full swings (level crossing above 0.65 after having been below
    /// 0.35) — a "flash" — sampled at 60fps over 8 seconds. The floor allows
    /// at most 1/0.75 ≈ 1.33 flashes/sec; assert a hard ≤ 2/sec envelope so
    /// the clamp has real margin under the 3Hz product bar.
    func testPreviewFlashRateIsClampedAtMaxSpeedAndBPM() {
        for pattern in MotionConfig.Pattern.allCases {
            for shape in EnvelopeConfig.Shape.allCases {
                let s = spec(pattern: pattern, shape: shape, speed: 100, bpm: 240)
                var flashes = 0
                var wasLow = false
                let duration = 8.0
                for step in 0..<Int(duration * 60) {
                    let t = Double(step) / 60.0
                    let level = LookPreviewMath.sample(index: 0, count: 8, spec: s, time: t).level
                    if level < 0.35 { wasLow = true }
                    if wasLow && level > 0.65 {
                        flashes += 1
                        wasLow = false
                    }
                }
                XCTAssertLessThanOrEqual(
                    Double(flashes) / duration, 2.0,
                    "\(pattern)/\(shape) preview flashes faster than the clamp allows"
                )
            }
        }
    }

    func testEnvelopeClampSlowsFastBPMOnly() {
        // 240 BPM = 0.25s period → must be slowed to the 0.75s floor.
        let fast = EnvelopeConfig(shape: .pulse, bpm: 240, depth: 100,
                                  dutyCycle: 50, minBrightness: 0, maxBrightness: 100)
        // One preview-clamped cycle should take 0.75s: on at t=0, off around
        // t=0.4 (past the 50% duty point of the stretched cycle).
        XCTAssertEqual(LookPreviewMath.envelopeValue(fast, at: 0.0), 1.0, accuracy: 0.001)
        XCTAssertEqual(LookPreviewMath.envelopeValue(fast, at: 0.45), 0.0, accuracy: 0.001)
        // 40 BPM = 1.5s period → slower than the floor, must be untouched.
        let slow = EnvelopeConfig(shape: .breathe, bpm: 40, depth: 100,
                                  minBrightness: 0, maxBrightness: 100)
        XCTAssertEqual(LookPreviewMath.envelopeValue(slow, at: 0.4),
                       slow.value(at: 0.4), accuracy: 0.000001)
    }

    // ── Static fallback ──

    func testStaticPhasesSpanTheStripEvenly() {
        let phases = LookPreviewMath.staticPhases(count: 8)
        XCTAssertEqual(phases.count, 8)
        XCTAssertEqual(phases.first ?? -1, 0.0, accuracy: 0.0001)
        XCTAssertEqual(phases.last ?? -1, 1.0, accuracy: 0.0001)
        XCTAssertEqual(LookPreviewMath.staticPhases(count: 1), [0.5])
    }

    func testAccentFallbackWhenNoPalette() {
        let s = LookPreviewSpec(pattern: .wave, accent: .purple)
        XCTAssertEqual(LookPreviewMath.color(spec: s, phase: 0.3), Color.purple)
    }

    // ── Idle vs running rendering (static idle frame, animated running) ──

    /// Idle cards render one frame at a fixed time: deterministic (same
    /// input → same output), strictly positive, and not the degenerate t = 0
    /// frame every card would otherwise share.
    func testIdlePreviewHasDeterministicRepresentativeFrozenTime() {
        let frozen = LookPreviewMath.frozenTime
        XCTAssertGreaterThan(frozen, 0)
        XCTAssertEqual(frozen, LookPreviewMath.frozenTime)

        let s = spec(pattern: .wave, shape: .breathe, speed: 40, bpm: 60)
        let a = LookPreviewMath.sample(index: 0, count: 8, spec: s, time: frozen)
        let b = LookPreviewMath.sample(index: 0, count: 8, spec: s, time: frozen)
        XCTAssertEqual(a.phase, b.phase)
        XCTAssertEqual(a.level, b.level)

        // Representative, not degenerate: the default 60 BPM breathe sits at
        // mid-brightness, and the frame differs from t = 0 across the strip.
        let level0 = LookPreviewMath.sample(index: 0, count: 8, spec: s, time: 0).level
        XCTAssertNotEqual(a.level, level0, accuracy: 0.01)
        XCTAssertTrue((0.2...0.8).contains(a.level),
                      "frozen frame should be mid-cycle, got \(a.level)")
    }

    /// Idle parameters sit inside the Effects/Live at-rest band and well
    /// below running on every axis that reads as visual noise.
    func testIdleRenderingParametersAreSubstantiallyQuieterThanRunning() {
        let idleIntensity = LookPreviewMath.canvasIntensity(isRunning: false)
        let runIntensity  = LookPreviewMath.canvasIntensity(isRunning: true)
        // Peak canvas alpha is intensity × (0.35 + 0.65 × 1.0) = intensity.
        XCTAssertLessThanOrEqual(idleIntensity, 0.12,
                                 "idle peak alpha must stay in the engine-card band (≤0.175)")
        XCTAssertGreaterThanOrEqual(runIntensity / idleIntensity, 2.0)

        XCTAssertLessThan(LookPreviewMath.canvasRadiusScale(isRunning: false),
                          LookPreviewMath.canvasRadiusScale(isRunning: true))

        // Strip: idle swing (max − min) is at most a third of running's and
        // never drops below 0.35 so the palette stays legible.
        let idleMin = LookPreviewMath.stripOpacity(level: 0, isRunning: false)
        let idleMax = LookPreviewMath.stripOpacity(level: 1, isRunning: false)
        let runMin  = LookPreviewMath.stripOpacity(level: 0, isRunning: true)
        let runMax  = LookPreviewMath.stripOpacity(level: 1, isRunning: true)
        XCTAssertGreaterThanOrEqual(idleMin, 0.35)
        XCTAssertLessThanOrEqual(idleMax, 0.60)
        XCTAssertLessThanOrEqual((idleMax - idleMin) / (runMax - runMin), 1.0 / 3.0)

        // Out-of-range levels are clamped, never amplified.
        XCTAssertEqual(LookPreviewMath.stripOpacity(level: 2, isRunning: false), idleMax, accuracy: 0.0001)
        XCTAssertEqual(LookPreviewMath.stripOpacity(level: -1, isRunning: true), runMin, accuracy: 0.0001)
    }

    /// The selected/running card is unchanged: these are the literal values
    /// LookPreview shipped with before idle went static.
    func testRunningRenderingParametersAreRegressionLocked() {
        XCTAssertEqual(LookPreviewMath.canvasIntensity(isRunning: true), 0.55, accuracy: 0.0001)
        XCTAssertEqual(LookPreviewMath.canvasRadiusScale(isRunning: true), 0.45, accuracy: 0.0001)
        for level in stride(from: 0.0, through: 1.0, by: 0.25) {
            XCTAssertEqual(LookPreviewMath.stripOpacity(level: level, isRunning: true),
                           0.25 + 0.75 * level, accuracy: 0.0001)
        }
    }

    // ── Spec equatability (card diffing) ──

    func testSpecEquatability() {
        let a = spec(pattern: .wave, shape: .breathe, speed: 40, bpm: 60)
        var b = a
        XCTAssertEqual(a, b)
        b.speed = 41
        XCTAssertNotEqual(a, b)
    }
}
