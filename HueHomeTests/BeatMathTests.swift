// BeatMathTests.swift
// HueHome Pro — Unit Tests
//
// Round 3 Universal Beat Panel: BeatBinding (snapping, migration-safe
// decode) and BeatMath (cycle phase/index/boundary, WCAG flash cap).
// Pure math — deterministic, no clocks, no audio.

import XCTest
@testable import HueHome

final class BeatMathTests: XCTestCase {

    // 120 BPM, epoch at t=0, 4/4 — beat interval 0.5 s.
    private let snap120 = BeatSnapshot(bpm: 120, beatEpoch: 0, beatsPerBar: 4)

    // MARK: - BeatBinding snapping / clamping

    func testSnappedStepPicksNearestAllowedValue() {
        XCTAssertEqual(BeatBinding.snappedStep(0.3), 0.25)
        XCTAssertEqual(BeatBinding.snappedStep(0.7), 0.5)
        XCTAssertEqual(BeatBinding.snappedStep(3.1), 4)
        XCTAssertEqual(BeatBinding.snappedStep(37), 8)
        XCTAssertEqual(BeatBinding.snappedStep(-5), 0.25)
        XCTAssertEqual(BeatBinding.snappedStep(.nan), 1)
    }

    func testInitSnapsAndClamps() {
        let b = BeatBinding(mode: .beatLocked, beatsPerCycle: 3.3, phaseOffsetBeats: 99)
        XCTAssertEqual(b.beatsPerCycle, 4)
        XCTAssertEqual(b.phaseOffsetBeats, 8)
        XCTAssertTrue(b.isActive)
        XCTAssertFalse(BeatBinding.off.isActive)
    }

    // MARK: - Migration-safe decode

    func testDecodeEmptyObjectYieldsDefaults() throws {
        let b = try JSONDecoder().decode(BeatBinding.self, from: Data("{}".utf8))
        XCTAssertEqual(b, .off)
    }

    func testDecodeWildValuesSelfSanitize() throws {
        let json = #"{"mode":"beatLocked","beatsPerCycle":37,"phaseOffsetBeats":-99}"#
        let b = try JSONDecoder().decode(BeatBinding.self, from: Data(json.utf8))
        XCTAssertEqual(b.mode, .beatLocked)
        XCTAssertEqual(b.beatsPerCycle, 8)
        XCTAssertEqual(b.phaseOffsetBeats, -8)
    }

    func testDecodeUnknownModeFallsBackToOff() throws {
        let json = #"{"mode":"laserRave","beatsPerCycle":2}"#
        let b = try JSONDecoder().decode(BeatBinding.self, from: Data(json.utf8))
        XCTAssertEqual(b.mode, .off)
        XCTAssertEqual(b.beatsPerCycle, 2)
    }

    func testPreRound3PresetJSONDecodesWithNilBeat() throws {
        // A preset exactly as persisted before the `beat` field existed
        // (synthesized Codable always wrote all six collections).
        let json = #"""
        {"id":"p1","name":"Old","baseEffectID":"strobe",
         "sliders":{"speed":5},"toggles":{},"segmented":{},
         "durations":{},"colors":{},"palettes":{}}
        """#
        let p = try JSONDecoder().decode(SavedEffectPreset.self, from: Data(json.utf8))
        XCTAssertNil(p.beat)
        XCTAssertEqual(p.sliders["speed"], 5)
    }

    func testPresetBeatRoundTrips() throws {
        var p = SavedEffectPreset(name: "New", baseEffectID: "strobe")
        p.beat = BeatBinding(mode: .beatLocked, beatsPerCycle: 2, phaseOffsetBeats: 0.5)
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(SavedEffectPreset.self, from: data)
        XCTAssertEqual(back.beat, p.beat)
    }

    // MARK: - WCAG flash cap

    func testWcagCapSteps174BpmHalfBeatUpToOne() {
        // 174 BPM × ½-beat = 5.8 Hz > 3 Hz → must step to ×1 (2.9 Hz).
        XCTAssertEqual(BeatMath.wcagSafeBeatsPerCycle(requested: 0.5, bpm: 174), 1)
    }

    func testWcagCapAllowsSafeRequests() {
        XCTAssertEqual(BeatMath.wcagSafeBeatsPerCycle(requested: 1, bpm: 120), 1)   // 2 Hz
        XCTAssertEqual(BeatMath.wcagSafeBeatsPerCycle(requested: 0.5, bpm: 60), 0.5) // 2 Hz
        XCTAssertEqual(BeatMath.wcagSafeBeatsPerCycle(requested: 4, bpm: 174), 4)
    }

    func testWcagCapQuarterBeatAt120Bpm() {
        // 120 BPM × ¼ = 8 Hz → ½ = 4 Hz → 1 = 2 Hz. First safe step is 1.
        XCTAssertEqual(BeatMath.wcagSafeBeatsPerCycle(requested: 0.25, bpm: 120), 1)
    }

    func testWcagCapNoClockPassesThrough() {
        XCTAssertEqual(BeatMath.wcagSafeBeatsPerCycle(requested: 0.25, bpm: 0), 0.25)
    }

    // MARK: - Cycle phase / index / boundary

    func testCyclePhaseOneBeatCycle() {
        // interval 0.5 s → at t=0.25 we are half-way through beat 0.
        XCTAssertEqual(BeatMath.cyclePhase(at: 0.25, snapshot: snap120, beatsPerCycle: 1),
                       0.5, accuracy: 1e-9)
        XCTAssertEqual(BeatMath.cyclePhase(at: 0.5, snapshot: snap120, beatsPerCycle: 1),
                       0.0, accuracy: 1e-9)
    }

    func testCyclePhaseTwoBeatCycle() {
        // 2-beat cycle = 1.0 s → t=0.5 is half-way.
        XCTAssertEqual(BeatMath.cyclePhase(at: 0.5, snapshot: snap120, beatsPerCycle: 2),
                       0.5, accuracy: 1e-9)
    }

    func testPhaseOffsetShiftsTheGrid() {
        // Offset ½ beat: the cycle boundary moves from t=0 to t=0.25.
        XCTAssertEqual(BeatMath.cyclePhase(at: 0.25, snapshot: snap120,
                                           beatsPerCycle: 1, phaseOffsetBeats: 0.5),
                       0.0, accuracy: 1e-9)
    }

    func testCyclePhaseNegativeTimeWraps() {
        let phase = BeatMath.cyclePhase(at: -0.1, snapshot: snap120, beatsPerCycle: 1)
        XCTAssertGreaterThanOrEqual(phase, 0)
        XCTAssertLessThan(phase, 1)
        XCTAssertEqual(phase, 0.8, accuracy: 1e-9)   // -0.1/0.5 = -0.2 → 0.8
    }

    func testCycleIndexIncrementsAtBoundary() {
        XCTAssertEqual(BeatMath.cycleIndex(at: 0.49, snapshot: snap120, beatsPerCycle: 1), 0)
        XCTAssertEqual(BeatMath.cycleIndex(at: 0.51, snapshot: snap120, beatsPerCycle: 1), 1)
        XCTAssertEqual(BeatMath.cycleIndex(at: -0.1, snapshot: snap120, beatsPerCycle: 1), -1)
    }

    func testNextCycleBoundaryIsStrictlyAfterT() {
        // bar-length cycles (4 beats = 2 s): from t=0.1 the next bar starts at 2.0.
        let next = BeatMath.nextCycleBoundary(after: 0.1, snapshot: snap120, beatsPerCycle: 4)
        XCTAssertEqual(next, 2.0, accuracy: 1e-9)
        XCTAssertGreaterThan(next, 0.1)
        // One-beat cycles: from t=0.5 exactly, the next boundary is 1.0.
        let n2 = BeatMath.nextCycleBoundary(after: 0.5, snapshot: snap120, beatsPerCycle: 1)
        XCTAssertEqual(n2, 1.0, accuracy: 1e-9)
    }

    // MARK: - Free-running semantics

    func testFreeRunningWhenModeOff() {
        let binding = BeatBinding.off
        XCTAssertTrue(BeatMath.isFreeRunning(binding, snapshot: snap120))
        XCTAssertNil(BeatMath.cyclePhase(binding, snapshot: snap120, at: 1))
    }

    func testFreeRunningWhenNoClock() {
        let binding = BeatBinding(mode: .beatLocked, beatsPerCycle: 1)
        XCTAssertTrue(BeatMath.isFreeRunning(binding, snapshot: .none))
        XCTAssertNil(BeatMath.cyclePhase(binding, snapshot: .none, at: 1))
    }

    func testBoundBindingReturnsPhase() {
        let binding = BeatBinding(mode: .beatLocked, beatsPerCycle: 1)
        XCTAssertEqual(BeatMath.cyclePhase(binding, snapshot: snap120, at: 0.25) ?? -1,
                       0.5, accuracy: 1e-9)
    }

    // MARK: - BeatClock.setBeatsPerBar

    @MainActor
    func testSetBeatsPerBarClampsAndPublishes() {
        let clock = BeatClock()
        clock.setBPM(100, now: 10)
        clock.setBeatsPerBar(3)
        XCTAssertEqual(clock.beatsPerBar, 3)
        clock.setBeatsPerBar(99)
        XCTAssertEqual(clock.beatsPerBar, 12)
        clock.setBeatsPerBar(0)
        XCTAssertEqual(clock.beatsPerBar, 1)
    }
}
