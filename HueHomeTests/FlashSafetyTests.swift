//
//  FlashSafetyTests.swift
//  HueHomeTests
//
//  Slice 2 remediation — R1. Pins the ONE invariant every flash-class
//  Entertainment loop now depends on:
//
//     realized onset-to-onset spacing ≥ 17 frames (0.34 s) on the 20 ms
//     DTLS grid, on every legal path.
//
//  Every assertion here goes through the SAME `BeatMath.FlashSafety` entry
//  points the orchestrator's loops call — `StrobePlan.make`, `PartyPlan.make`,
//  `ThunderstormPlan.Budget`, `liveLock`'s cap and `OnsetLedger` — so a loop
//  cannot drift away from the math without failing a test. Pure and
//  deterministic: no Task.sleep, no XCTWaiter, no wait(for:), no usleep;
//  randomness comes from a seeded LCG.
//

import XCTest
@testable import HueHome

// MARK: - Deterministic RNG

/// SplitMix64 over an LCG state. Seeded, reproducible, and — unlike the
/// system generator — makes a "random" sweep a regression pin rather than a
/// flake.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407 }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class FlashSafetyTests: XCTestCase {

    private typealias FS = BeatMath.FlashSafety
    private let fd = BeatMath.FlashSafety.entertainmentFrameDuration
    private let minFrames = BeatMath.FlashSafety.minCycleFrames()

    // ══════════════════════════════════════════════════════════════
    // MARK: - Frame math
    // ══════════════════════════════════════════════════════════════

    func testMinCycleFramesIsSeventeenOnTheEntertainmentGrid() {
        XCTAssertEqual(FS.entertainmentFrameDuration, 0.02)
        XCTAssertEqual(FS.entertainmentFrameNanoseconds, 20_000_000,
                       "loops sleep this — it must equal the 20 ms grid the math plans on")
        XCTAssertEqual(FS.minOnsetPeriod, 1.0 / 3.0, accuracy: 1e-15)
        XCTAssertEqual(FS.minCycleFrames(), 17,
                       "16 frames is 0.32 s, which is FASTER than 3 Hz — the whole defect")
        XCTAssertLessThan(16.0 * FS.entertainmentFrameDuration, FS.minOnsetPeriod)
        XCTAssertGreaterThanOrEqual(17.0 * FS.entertainmentFrameDuration, FS.minOnsetPeriod)
    }

    func testMinCycleFramesRoundsUpOnAnyGrid() {
        XCTAssertEqual(FS.minCycleFrames(frameDuration: 0.04), 9)     // 0.36 s
        XCTAssertEqual(FS.minCycleFrames(frameDuration: 1.0 / 3.0), 1)
        XCTAssertEqual(FS.minCycleFrames(frameDuration: 0.01), 34)
        // Degenerate grids fall back to the Entertainment grid, never trap.
        XCTAssertEqual(FS.minCycleFrames(frameDuration: 0), 17)
        XCTAssertEqual(FS.minCycleFrames(frameDuration: -0.02), 17)
        XCTAssertEqual(FS.minCycleFrames(frameDuration: .nan), 17)
        XCTAssertEqual(FS.minCycleFrames(frameDuration: .infinity), 17)
    }

    func testEntertainmentLockCeilingIsExactlyFrameRealizable() {
        // 1 / (17 × 0.02) = 2.9412 Hz. Not a product preference: it is what
        // "≥ 17 frames per cycle" means expressed as a rate.
        XCTAssertEqual(FS.entertainmentMaxLockHz, 1.0 / 0.34, accuracy: 1e-12)
        XCTAssertLessThan(FS.entertainmentMaxLockHz, FS.maxFlashHz)
        XCTAssertEqual(FS.cycleFrames(hz: FS.entertainmentMaxLockHz), 17,
                       "the ceiling must plan to exactly the floor — no rounding slack")
        XCTAssertGreaterThanOrEqual(1.0 / FS.entertainmentMaxLockHz, FS.minOnsetPeriod)
    }

    func testCycleFramesNeverPlansFasterThanOneThirdOfASecond() {
        var hz = 0.01
        while hz <= 10.0 + 1e-9 {
            let frames = FS.cycleFrames(hz: hz)
            XCTAssertGreaterThanOrEqual(frames, minFrames, "hz \(hz)")
            XCTAssertGreaterThanOrEqual(Double(frames) * fd, FS.minOnsetPeriod - 1e-12, "hz \(hz)")
            hz += 0.01
        }
    }

    func testCycleFramesPinsTheShippedSpeedCurve() {
        // The user-visible consequence of planning a safe TOTAL: speed 100 is
        // 17 frames (was 15–16), speed 50 is 29 (was 28).
        XCTAssertEqual(FS.cycleFrames(hz: FS.StrobePlan.hz(speed: 100)), 17)
        XCTAssertEqual(FS.cycleFrames(hz: FS.StrobePlan.hz(speed: 50)), 29)
        XCTAssertEqual(FS.cycleFrames(hz: FS.StrobePlan.hz(speed: 0)), 100)   // 0.5 Hz → 2 s
    }

    func testCycleFramesSurvivesDegenerateInput() {
        for hz in [0.0, -1.0, -0.0, Double.nan, .infinity, -.infinity, 1e300, -1e300] {
            let frames = FS.cycleFrames(hz: hz)
            XCTAssertGreaterThanOrEqual(frames, minFrames, "hz \(hz)")
            XCTAssertLessThanOrEqual(frames, Int((1.0 / FS.slowestPlannedHz) / fd) + 1,
                                     "hz \(hz) must stay a finite, plannable cycle")
        }
        // The slowest plannable cycle is 10 s = 500 frames — bounded, so the
        // Int conversion can never trap and the loop can never hang.
        XCTAssertEqual(FS.cycleFrames(hz: 0), 500)
        XCTAssertEqual(FS.cycleFrames(hz: -1), 500)
        XCTAssertEqual(FS.cycleFrames(hz: .nan), 17)
        XCTAssertEqual(FS.cycleFrames(hz: .infinity), 17)
        XCTAssertEqual(FS.cycleFrames(hz: 3.0, frameDuration: .nan), 17)
    }

    func testSplitFramesAlwaysKeepsBothHalvesAliveAndTheTotalIntact() {
        for total in 2...200 {
            var fraction = -0.5
            while fraction <= 1.5 + 1e-9 {
                let split = FS.splitFrames(total: total, firstFraction: fraction)
                XCTAssertGreaterThanOrEqual(split.first, 1, "total \(total) f \(fraction)")
                XCTAssertGreaterThanOrEqual(split.second, 1, "total \(total) f \(fraction)")
                XCTAssertEqual(split.first + split.second, total, "total \(total) f \(fraction)")
                fraction += 0.1
            }
        }
        // NaN splits evenly rather than collapsing a half.
        let nanSplit = FS.splitFrames(total: 17, firstFraction: .nan)
        XCTAssertEqual(nanSplit.first + nanSplit.second, 17)
        XCTAssertGreaterThanOrEqual(nanSplit.first, 1)
        XCTAssertGreaterThanOrEqual(nanSplit.second, 1)
        // A total below 2 is raised to 2 — two parts each ≥ 1 frame need 2.
        XCTAssertEqual(FS.splitFrames(total: 1, firstFraction: 0.5).first, 1)
        XCTAssertEqual(FS.splitFrames(total: -5, firstFraction: 0.5).second, 1)
    }

    // ══════════════════════════════════════════════════════════════
    // MARK: - Strobe / Party free-run plans
    // ══════════════════════════════════════════════════════════════

    func testStrobePlanIsSafeAcrossEverySpeedAndDuty() {
        var speeds: [Double] = (0...100).map(Double.init)
        speeds.append(contentsOf: [250, 1000, -50])
        for speed in speeds {
            for dutyPercent in stride(from: 10.0, through: 90.0, by: 1.0) {
                let plan = FS.StrobePlan.make(speed: speed, dutyCycle: dutyPercent / 100.0)
                XCTAssertGreaterThanOrEqual(plan.totalFrames, minFrames,
                                            "speed \(speed) duty \(dutyPercent)")
                XCTAssertGreaterThanOrEqual(plan.onFrames, 1, "speed \(speed) duty \(dutyPercent)")
                XCTAssertGreaterThanOrEqual(plan.offFrames, 1, "speed \(speed) duty \(dutyPercent)")
                XCTAssertEqual(plan.onFrames + plan.offFrames, plan.totalFrames)
                XCTAssertGreaterThanOrEqual(Double(plan.totalFrames) * fd,
                                            FS.minOnsetPeriod - 1e-12)
            }
        }
    }

    func testStrobeSpeed100IsSeventeenFramesNotSixteen() {
        // The shipped defect: ON and OFF were floored INDEPENDENTLY, so duty 50
        // at speed 100 rendered Int(0.1667/0.02) = 8 + 8 = 16 frames (3.13 Hz),
        // and duty 10 rendered 1 + 15 = 16.
        let half = FS.StrobePlan.make(speed: 100, dutyCycle: 0.5)
        XCTAssertEqual(half.totalFrames, 17)
        XCTAssertEqual(half.onFrames, 9)
        XCTAssertEqual(half.offFrames, 8)
        for dutyPercent in stride(from: 10.0, through: 90.0, by: 10.0) {
            let plan = FS.StrobePlan.make(speed: 100, dutyCycle: dutyPercent / 100.0)
            XCTAssertEqual(plan.totalFrames, 17, "duty \(dutyPercent)")
        }
        XCTAssertEqual(FS.StrobePlan.hz(speed: 100), 3.0, accuracy: 1e-12)
        XCTAssertEqual(FS.StrobePlan.hz(speed: 0), 0.5, accuracy: 1e-12)
        XCTAssertEqual(FS.StrobePlan.hz(speed: 1_000), 3.0, accuracy: 1e-12,
                       "a widened catalog range cannot raise the ceiling")
        XCTAssertEqual(FS.StrobePlan.hz(speed: -50), 0.5, accuracy: 1e-12)
    }

    func testPartyPlanIsSafeAcrossEverySpeedAndSmoothness() {
        var speeds: [Double] = (0...100).map(Double.init)
        speeds.append(contentsOf: [250, 1000, -50])
        for speed in speeds {
            for smoothPercent in stride(from: 0.0, through: 100.0, by: 1.0) {
                let plan = FS.PartyPlan.make(speed: speed, smoothness: smoothPercent / 100.0)
                XCTAssertGreaterThanOrEqual(plan.totalFrames, minFrames,
                                            "speed \(speed) smoothness \(smoothPercent)")
                XCTAssertGreaterThanOrEqual(plan.holdFrames, 1)
                XCTAssertGreaterThanOrEqual(plan.fadeFrames, 1)
                XCTAssertEqual(plan.holdFrames + plan.fadeFrames, plan.totalFrames)
            }
        }
    }

    func testPartySmoothnessExtremesKeepBothPhasesAlive() {
        // Worst realized case on the shipped default (smoothness 20) used to be
        // 15 hold + 1 fade = 16 frames = 3.13 Hz.
        let noFade = FS.PartyPlan.make(speed: 100, smoothness: 0)
        XCTAssertEqual(noFade.holdFrames, 16)
        XCTAssertEqual(noFade.fadeFrames, 1)
        let allFade = FS.PartyPlan.make(speed: 100, smoothness: 1)
        XCTAssertEqual(allFade.holdFrames, 1)
        XCTAssertEqual(allFade.fadeFrames, 16)
        let shippedDefault = FS.PartyPlan.make(speed: 100, smoothness: 0.20)
        XCTAssertEqual(shippedDefault.totalFrames, 17)
        XCTAssertGreaterThanOrEqual(Double(shippedDefault.totalFrames) * fd, FS.minOnsetPeriod)
    }

    func testStrobeFreeRunOnsetSpacingSurvivesSeededParamChurn() {
        var rng = SeededGenerator(seed: 0xF1A5_5AFE)
        let ledger = FS.OnsetLedger()
        var frame = 0
        var lastOnsetFrame: Int?
        for cycle in 0..<500 {
            // Params churn EVERY cycle — a drag, an adaptive-gain flick, a
            // typed entry. The plan is read once per cycle, both halves from it.
            let speed = Double.random(in: -20...140, using: &rng)
            let duty = Double.random(in: 0.05...0.95, using: &rng)
            let plan = FS.StrobePlan.make(speed: speed, dutyCycle: duty)
            frame += holdFramesUntilAdmitted(ledger: ledger, from: frame)
            if let last = lastOnsetFrame {
                XCTAssertGreaterThanOrEqual(frame - last, minFrames,
                                            "cycle \(cycle) speed \(speed) duty \(duty)")
            }
            lastOnsetFrame = frame
            frame += plan.totalFrames
        }
    }

    func testPartyFreeRunOnsetSpacingSurvivesSeededParamChurn() {
        var rng = SeededGenerator(seed: 0x0C0F_FEE1)
        let ledger = FS.OnsetLedger()
        var frame = 0
        var lastOnsetFrame: Int?
        for cycle in 0..<500 {
            let speed = Double.random(in: -20...140, using: &rng)
            let smoothness = Double.random(in: -0.2...1.2, using: &rng)
            let plan = FS.PartyPlan.make(speed: speed, smoothness: smoothness)
            frame += holdFramesUntilAdmitted(ledger: ledger, from: frame)
            if let last = lastOnsetFrame {
                XCTAssertGreaterThanOrEqual(frame - last, minFrames,
                                            "cycle \(cycle) speed \(speed) smoothness \(smoothness)")
            }
            lastOnsetFrame = frame
            frame += plan.totalFrames
        }
    }

    // ══════════════════════════════════════════════════════════════
    // MARK: - Thunderstorm
    // ══════════════════════════════════════════════════════════════

    func testThunderstormKeepsTheLegacyGapCurveIncludingItsIEEEArtefact() {
        // frequency 1.0 → 2.0 − 1.8 = 0.19999999999999996, and
        // Int(9.999999999999998) truncates to 9. Preserved deliberately: the
        // storm must look the same; the Budget is what makes it safe.
        XCTAssertEqual(FS.ThunderstormPlan.requestedGapFrames(frequency: 1.0), 9)
        XCTAssertEqual(FS.ThunderstormPlan.requestedGapFrames(frequency: 0.0), 100)   // 2 s
        XCTAssertEqual(FS.ThunderstormPlan.requestedGapFrames(frequency: 0.5), 55)    // 1.1 s
        // Out-of-catalog input is clamped, never allowed to form a shorter gap.
        XCTAssertEqual(FS.ThunderstormPlan.requestedGapFrames(frequency: 2.5), 9)
        XCTAssertEqual(FS.ThunderstormPlan.requestedGapFrames(frequency: -3), 100)
        XCTAssertEqual(FS.ThunderstormPlan.requestedGapFrames(frequency: .nan), 55)
    }

    func testThunderstormLegacyWorstCaseWasFiveHertzAndTheBudgetMakesItSeventeenFrames() {
        // The shipped defect, documented exactly: frequency 100, flash_length 1,
        // afterglow 0 → 9 gap frames + 1 flash frame + 0 afterglow frames.
        let legacyRealizedFrames = 9 + 1 + 0
        XCTAssertEqual(legacyRealizedFrames, 10)
        XCTAssertEqual(Double(legacyRealizedFrames) * fd, 0.2, accuracy: 1e-12)
        XCTAssertEqual(1.0 / (Double(legacyRealizedFrames) * fd), 5.0, accuracy: 1e-12,
                       "10 frames is 5.0 Hz — 66 % over the photosensitivity ceiling")

        // Now: the strike leaves `since = 1`, so the budget owes 16 gap frames
        // and the realized spacing is 17.
        var budget = FS.ThunderstormPlan.Budget()
        budget.noteStrike(flashFrames: 1, afterglowFrames: 0)
        XCTAssertEqual(budget.framesSinceOnset, 1)
        XCTAssertEqual(budget.gapFrames(frequency: 1.0), 16)
        XCTAssertEqual(1 + 16, minFrames)

        // Card defaults at frequency 100 (flash_length 3 → ≥ 2 frames,
        // afterglow 1 → ≥ 1 frame): since = 3, gap = 14, spacing = 17.
        var defaults = FS.ThunderstormPlan.Budget()
        defaults.noteStrike(flashFrames: 2, afterglowFrames: 1)
        XCTAssertEqual(defaults.framesSinceOnset, 3)
        XCTAssertEqual(defaults.gapFrames(frequency: 1.0), 14)
        XCTAssertEqual(3 + 14, minFrames)
    }

    func testThunderstormFrameRangesMatchTheLegacyJitter() {
        XCTAssertEqual(FS.ThunderstormPlan.flashFrameRange(flashLength: 3), 2...5)
        XCTAssertEqual(FS.ThunderstormPlan.flashFrameRange(flashLength: 1), 1...3)
        XCTAssertEqual(FS.ThunderstormPlan.flashFrameRange(flashLength: 8), 7...10)
        XCTAssertEqual(FS.ThunderstormPlan.afterglowFrameRange(afterglow: 0), 0...0)
        XCTAssertEqual(FS.ThunderstormPlan.afterglowFrameRange(afterglow: 1), 1...2)
        XCTAssertEqual(FS.ThunderstormPlan.afterglowFrameRange(afterglow: 5), 5...6)
        // A hand-edited or corrupt value must not form an EMPTY range (which
        // `Int.random(in:)` traps on).
        XCTAssertEqual(FS.ThunderstormPlan.flashFrameRange(flashLength: 0), 1...3)
        XCTAssertEqual(FS.ThunderstormPlan.flashFrameRange(flashLength: -9), 1...3)
        XCTAssertEqual(FS.ThunderstormPlan.afterglowFrameRange(afterglow: -4), 0...0)
        for length in -20...80 {
            XCTAssertLessThanOrEqual(FS.ThunderstormPlan.flashFrameRange(flashLength: length).lowerBound,
                                     FS.ThunderstormPlan.flashFrameRange(flashLength: length).upperBound)
            XCTAssertLessThanOrEqual(FS.ThunderstormPlan.afterglowFrameRange(afterglow: length).lowerBound,
                                     FS.ThunderstormPlan.afterglowFrameRange(afterglow: length).upperBound)
        }
    }

    func testThunderstormWorstCaseSweepNeverFlashesFasterThanTheFloor() {
        var frequencies: [Double] = stride(from: 0.0, through: 1.0, by: 0.05).map { $0 }
        frequencies.append(2.5)   // out-of-catalog frequency 250
        for frequency in frequencies {
            for flashLength in 1...8 {
                for afterglowBase in 0...5 {
                    // Worst case = the SHORTEST legal strike: minimum flash and
                    // minimum afterglow leave the least credit behind.
                    let flash = FS.ThunderstormPlan.flashFrameRange(flashLength: flashLength).lowerBound
                    let glow = FS.ThunderstormPlan.afterglowFrameRange(afterglow: afterglowBase).lowerBound
                    var budget = FS.ThunderstormPlan.Budget()
                    let ledger = FS.OnsetLedger()
                    var frame = 0
                    var lastOnsetFrame: Int?
                    for strike in 0..<50 {
                        let gap = budget.gapFrames(frequency: frequency)
                        frame += gap
                        budget.noteAmbient(frames: gap)
                        let held = holdFramesUntilAdmitted(ledger: ledger, from: frame)
                        XCTAssertEqual(held, 0,
                                       "the frame budget alone must satisfy the wall clock — f \(frequency) flash \(flashLength) glow \(afterglowBase) strike \(strike)")
                        if let last = lastOnsetFrame {
                            XCTAssertGreaterThanOrEqual(
                                frame - last, minFrames,
                                "f \(frequency) flash \(flashLength) glow \(afterglowBase) strike \(strike)")
                        }
                        lastOnsetFrame = frame
                        frame += flash + glow
                        budget.noteStrike(flashFrames: flash, afterglowFrames: glow)
                    }
                }
            }
        }
    }

    func testThunderstormSeededSweepWithSkipsAndBeatWaitsStaysSafe() {
        var rng = SeededGenerator(seed: 0x5701_8AB1)
        var budget = FS.ThunderstormPlan.Budget()
        let ledger = FS.OnsetLedger()
        var frame = 0
        var lastOnsetFrame: Int?
        var strikesRendered = 0
        var opportunities = 0

        while strikesRendered < 400, opportunities < 5_000 {
            opportunities += 1
            let frequency = Double.random(in: 0...1, using: &rng)
            let gap = budget.gapFrames(frequency: frequency)
            frame += gap
            budget.noteAmbient(frames: gap)

            // Beat-locked alignment wait: 0…40 ambient frames on the wire.
            let beatWait = Int.random(in: 0...40, using: &rng)
            frame += beatWait
            budget.noteAmbient(frames: beatWait)

            // 30 % of opportunities skip the strike entirely.
            if Double.random(in: 0...1, using: &rng) < 0.30 { continue }

            let flashRange = FS.ThunderstormPlan.flashFrameRange(
                flashLength: Int.random(in: 1...8, using: &rng))
            let glowRange = FS.ThunderstormPlan.afterglowFrameRange(
                afterglow: Int.random(in: 0...5, using: &rng))
            let flash = Int.random(in: flashRange, using: &rng)
            let glow = Int.random(in: glowRange, using: &rng)

            frame += holdFramesUntilAdmitted(ledger: ledger, from: frame)
            if let last = lastOnsetFrame {
                XCTAssertGreaterThanOrEqual(frame - last, minFrames,
                                            "opportunity \(opportunities)")
                XCTAssertGreaterThanOrEqual(Double(frame - last) * fd,
                                            FS.minOnsetPeriod - 1e-12)
            }
            lastOnsetFrame = frame
            frame += flash + glow
            budget.noteStrike(flashFrames: flash, afterglowFrames: glow)
            strikesRendered += 1
        }
        XCTAssertEqual(strikesRendered, 400, "the sweep must actually render strikes")
        XCTAssertGreaterThan(opportunities, strikesRendered, "skips must actually happen")
    }

    func testSkippedStrikeAccumulatesCreditInsteadOfResettingIt() {
        var budget = FS.ThunderstormPlan.Budget()
        budget.noteStrike(flashFrames: 1, afterglowFrames: 0)
        XCTAssertEqual(budget.framesSinceOnset, 1)
        // Opportunity 1: 9 legacy gap frames are stretched to 16, then the
        // strike is SKIPPED. The credit must survive the `continue`.
        let firstGap = budget.gapFrames(frequency: 1.0)
        XCTAssertEqual(firstGap, 16)
        budget.noteAmbient(frames: firstGap)
        XCTAssertEqual(budget.framesSinceOnset, minFrames)
        // Opportunity 2 therefore owes nothing beyond the legacy curve.
        XCTAssertEqual(budget.gapFrames(frequency: 1.0), 9)
    }

    func testBudgetSaturatesWithoutOverflowing() {
        var budget = FS.ThunderstormPlan.Budget()
        XCTAssertEqual(budget.framesSinceOnset, minFrames, "the first strike is never delayed")
        budget.noteAmbient(frames: Int.max)
        XCTAssertEqual(budget.framesSinceOnset, minFrames)
        for _ in 0..<10_000 { budget.noteAmbient() }
        XCTAssertEqual(budget.framesSinceOnset, minFrames)
        budget.noteAmbient(frames: -5)
        XCTAssertEqual(budget.framesSinceOnset, minFrames, "a negative count is ignored, not subtracted")
        // A strike longer than the ceiling cannot bank credit either.
        budget.noteStrike(flashFrames: Int.max / 2, afterglowFrames: Int.max / 2)
        XCTAssertEqual(budget.framesSinceOnset, minFrames)
        budget.noteStrike(flashFrames: -3, afterglowFrames: -3)
        XCTAssertEqual(budget.framesSinceOnset, 0)
        XCTAssertEqual(budget.gapFrames(frequency: 1.0), minFrames)
    }

    // ══════════════════════════════════════════════════════════════
    // MARK: - Beat lock
    // ══════════════════════════════════════════════════════════════

    func testCappedBeatCycleIsNeverFasterThanTheCeilingAcrossEveryTempo() {
        for bpm in 20...300 {
            for requested in BeatBinding.allowedSteps {
                let atThreeHz = BeatMath.wcagSafeBeatsPerCycle(
                    requested: requested, bpm: Double(bpm), maxHz: FS.maxFlashHz)
                XCTAssertGreaterThanOrEqual(atThreeHz * 60.0 / Double(bpm),
                                            FS.minOnsetPeriod - 1e-12,
                                            "bpm \(bpm) step \(requested)")
                let atEntCeiling = BeatMath.wcagSafeBeatsPerCycle(
                    requested: requested, bpm: Double(bpm), maxHz: FS.entertainmentMaxLockHz)
                XCTAssertGreaterThanOrEqual(atEntCeiling * 60.0 / Double(bpm),
                                            Double(minFrames) * fd - 1e-12,
                                            "bpm \(bpm) step \(requested)")
                XCTAssertGreaterThanOrEqual(atEntCeiling, atThreeHz,
                                            "the tighter ceiling may only step UP, never down")
            }
        }
    }

    func testEntertainmentCeilingMovesExactlyThreeBandsUpADivision() {
        // The musical cost of the 2.94 Hz ceiling, pinned band by band: three
        // 3.5-BPM windows step to the next beat division — the same windows
        // where the old 3.0 Hz lock realized 16-frame (0.32 s) intervals.
        let ceiling = FS.entertainmentMaxLockHz
        func capped(_ bpm: Double, _ step: Double) -> Double {
            BeatMath.wcagSafeBeatsPerCycle(requested: step, bpm: bpm, maxHz: ceiling)
        }
        XCTAssertEqual(capped(176, 1), 1)
        XCTAssertEqual(capped(177, 1), 2)
        XCTAssertEqual(capped(88, 0.5), 0.5)
        XCTAssertEqual(capped(89, 0.5), 1)
        XCTAssertEqual(capped(44, 0.25), 0.25)
        XCTAssertEqual(capped(45, 0.25), 0.5)
        XCTAssertEqual(capped(300, 2), 2)
        // Below the bands nothing moves at all: the tighter ceiling only ever
        // touches a division that was ALREADY within 2 % of 3 Hz.
        XCTAssertEqual(capped(120, 1), 1)                       // 2.00 Hz
        XCTAssertEqual(capped(40, 0.25), 0.25)                  // 2.67 Hz
        XCTAssertEqual(capped(175, 1),
                       BeatMath.wcagSafeBeatsPerCycle(requested: 1, bpm: 175, maxHz: FS.maxFlashHz),
                       "outside the bands the 2.94 and 3.0 ceilings agree")
        // 60 BPM × ¼ beat is 4 Hz — the OLD 3 Hz ceiling already stepped it up.
        XCTAssertEqual(capped(60, 0.25), 0.5)
        XCTAssertEqual(BeatMath.wcagSafeBeatsPerCycle(requested: 0.25, bpm: 60,
                                                      maxHz: FS.maxFlashHz), 0.5)
    }

    func testUncappedConvenienceCyclePhaseStillRealizesSixteenFrames() {
        // Documents exactly why `BeatMath.cyclePhase(_ binding:snapshot:at:)`
        // carries a "never call this from a flash-class loop" warning: at
        // 180 BPM × 1 beat it reports a 3 Hz cycle that the 20 ms grid renders
        // as a 16-frame (0.32 s) interval — the R1-Q defect.
        let binding = BeatBinding(mode: .beatLocked, beatsPerCycle: 1)
        let snapshot = BeatSnapshot(bpm: 180, beatEpoch: 0)
        let gaps = risingEdgeGaps(frames: 1_000) { frame in
            (BeatMath.cyclePhase(binding, snapshot: snapshot, at: Double(frame) * self.fd) ?? 1) < 0.5
        }
        XCTAssertEqual(gaps.min(), 16, "the uncapped path realizes 0.32 s — faster than 3 Hz")

        // The capped path the loops actually use never does.
        let cappedPerCycle = BeatMath.wcagSafeBeatsPerCycle(
            requested: binding.beatsPerCycle, bpm: 180, maxHz: FS.entertainmentMaxLockHz)
        XCTAssertEqual(cappedPerCycle, 2, "180 BPM × 1 beat is above 2.94 Hz — step up")
        let cappedGaps = risingEdgeGaps(frames: 1_000) { frame in
            BeatMath.cyclePhase(at: Double(frame) * self.fd, snapshot: snapshot,
                                beatsPerCycle: cappedPerCycle,
                                phaseOffsetBeats: binding.phaseOffsetBeats) < 0.5
        }
        XCTAssertGreaterThanOrEqual(cappedGaps.min() ?? 0, minFrames)
    }

    func testTwentySecondsOfFramesAtEveryTempoAndDivisionStaysAboveTheFloor() {
        for bpm in 20...300 {
            let snapshot = BeatSnapshot(bpm: Double(bpm), beatEpoch: 0)
            for requested in BeatBinding.allowedSteps {
                let perCycle = BeatMath.wcagSafeBeatsPerCycle(
                    requested: requested, bpm: Double(bpm), maxHz: FS.entertainmentMaxLockHz)
                let gaps = risingEdgeGaps(frames: 1_000) { frame in
                    BeatMath.cyclePhase(at: Double(frame) * self.fd, snapshot: snapshot,
                                        beatsPerCycle: perCycle) < 0.5
                }
                XCTAssertGreaterThanOrEqual(gaps.min() ?? minFrames, minFrames,
                                            "bpm \(bpm) step \(requested) → \(perCycle)")
            }
        }
    }

    func testPhaseOffsetAndTempoNudgesCannotShortenTheRealizedInterval() {
        // A phase edit or a tempo nudge mid-flight retargets the boundary; the
        // ledger is what keeps the RESULT safe. Model: the lock is re-derived
        // every frame from a clock whose BPM churns.
        var rng = SeededGenerator(seed: 0xBEA7_10CC)
        let ledger = FS.OnsetLedger()
        var lastAdmitted: Int?
        var wasBright = false
        var bpm = 120.0
        var epoch = 0.0
        for frame in 0..<4_000 {
            if frame % 97 == 0 { bpm = Double.random(in: 20...300, using: &rng) }
            if frame % 211 == 0 { epoch += Double.random(in: -0.5...0.5, using: &rng) }
            let snapshot = BeatSnapshot(bpm: bpm, beatEpoch: epoch)
            let perCycle = BeatMath.wcagSafeBeatsPerCycle(
                requested: 1, bpm: bpm, maxHz: FS.entertainmentMaxLockHz)
            let bright = BeatMath.cyclePhase(at: Double(frame) * fd, snapshot: snapshot,
                                             beatsPerCycle: perCycle) < 0.5
            if bright, !wasBright {
                // The loop delays the onset until the ledger admits it. Time
                // only moves forward: hold frames streamed for the previous
                // onset are already on the wire, so a rising edge computed for
                // an earlier frame index can never be rendered before them.
                var onsetFrame = max(frame, lastAdmitted ?? frame)
                while !ledger.tryOnset(at: Double(onsetFrame) * fd) { onsetFrame += 1 }
                if let last = lastAdmitted {
                    XCTAssertGreaterThanOrEqual(onsetFrame - last, minFrames,
                                                "frame \(frame) bpm \(bpm)")
                }
                lastAdmitted = onsetFrame
            }
            wasBright = bright
        }
        XCTAssertNotNil(lastAdmitted, "the churn model must have produced onsets")
    }

    // ══════════════════════════════════════════════════════════════
    // MARK: - Onset gate / ledger
    // ══════════════════════════════════════════════════════════════

    func testGateAdmitsTheFirstOnsetAndOneExactlyAPeriodLater() {
        var gate = FS.OnsetGate()
        XCTAssertNil(gate.lastOnset)
        XCTAssertTrue(gate.tryOnset(at: 10))
        XCTAssertEqual(gate.lastOnset, 10)
        XCTAssertTrue(gate.tryOnset(at: 10 + FS.minOnsetPeriod),
                      "exactly 1/3 s is admissible — the invariant is ≥, not >")
        XCTAssertEqual(gate.lastOnset ?? 0, 10 + FS.minOnsetPeriod, accuracy: 1e-12)
    }

    func testGateRefusesThirtyTwoMillisecondsShortAndKeepsItsLastOnset() {
        var gate = FS.OnsetGate()
        XCTAssertTrue(gate.tryOnset(at: 10))
        XCTAssertFalse(gate.tryOnset(at: 10.32), "16 frames = 0.32 s is the R1-Q defect")
        XCTAssertEqual(gate.lastOnset, 10, "a refusal must not move the reference point")
        XCTAssertFalse(gate.tryOnset(at: 10.33))
        XCTAssertTrue(gate.tryOnset(at: 10.34), "17 frames = 0.34 s is admissible")
        XCTAssertEqual(gate.lastOnset, 10.34)
        // Non-finite times are refused: an unmeasurable interval is not a
        // proven-safe one.
        XCTAssertFalse(gate.tryOnset(at: .nan))
        XCTAssertFalse(gate.tryOnset(at: .infinity))
        XCTAssertEqual(gate.lastOnset, 10.34)
    }

    func testGateAbsorbsASixtyMillisecondStragglingFrameAtA340msPeriod() {
        // Per-frame `await` jitter is real: a frame can run 60 ms late. At a
        // 340 ms plan the gate must simply admit the late onset (no refusal,
        // no lost flash) — and an EARLY straggler must be delayed, not dropped.
        var gate = FS.OnsetGate()
        var admitted: [Double] = []
        var refusals = 0
        var t = 0.0
        for cycle in 0..<40 {
            if cycle == 7 { t += 0.06 }             // one frame runs 60 ms late
            if cycle == 19 { t -= 0.06 }            // and one arrives 60 ms early
            var attempt = t
            while !gate.tryOnset(at: attempt) {
                refusals += 1
                attempt += fd                        // delay by one frame, never skip
            }
            admitted.append(attempt)
            t = attempt + 0.34
        }
        XCTAssertEqual(admitted.count, 40, "every planned onset is delayed, never dropped")
        XCTAssertGreaterThan(refusals, 0, "the early straggler must actually be caught")
        for i in 1..<admitted.count {
            XCTAssertGreaterThanOrEqual(admitted[i] - admitted[i - 1],
                                        FS.minOnsetPeriod - 1e-12,
                                        "onset \(i)")
        }
    }

    func testBeatToFreeRunToggleCannotFlashTwiceInsideOneThirdOfASecond() {
        // The beat branch renders a rising edge at frame k; the user flips the
        // lock off and the free-run branch immediately wants its own onset.
        // Shared edge state plus the ledger push it to k + 17.
        let ledger = FS.OnsetLedger()
        let k = 250
        XCTAssertTrue(ledger.tryOnset(at: Double(k) * fd))
        var frame = k + 1
        while !ledger.tryOnset(at: Double(frame) * fd) { frame += 1 }
        XCTAssertEqual(frame, k + minFrames)
        XCTAssertGreaterThanOrEqual(Double(frame - k) * fd, FS.minOnsetPeriod - 1e-12)
    }

    func testOneLedgerIsSharedAcrossTwoLoopInstancesOnTheSameBridge() {
        // Stopping a card and starting another one restarts the loop with fresh
        // edge state — and would flash on its very first frame. The bridge's
        // ledger outlives both loops, so it cannot.
        let bridgeLedger = FS.OnsetLedger()

        // Loop instance A: one strobe onset at t = 5.0, then the card is stopped.
        XCTAssertTrue(bridgeLedger.tryOnset(at: 5.0))

        // Loop instance B (a different card, same bridge) starts immediately.
        XCTAssertFalse(bridgeLedger.tryOnset(at: 5.02))
        XCTAssertFalse(bridgeLedger.tryOnset(at: 5.30))
        var frame = 1
        while !bridgeLedger.tryOnset(at: 5.0 + Double(frame) * fd) { frame += 1 }
        XCTAssertEqual(frame, minFrames)

        // A ledger belonging to a DIFFERENT bridge is independent — one bridge's
        // flash must not stall another bridge's show.
        let otherBridge = FS.OnsetLedger()
        XCTAssertTrue(otherBridge.tryOnset(at: 5.02))
    }

    func testLedgerMirrorsTheGateAndExposesItsLastOnset() {
        let ledger = FS.OnsetLedger()
        XCTAssertNil(ledger.lastOnset)
        XCTAssertTrue(ledger.tryOnset(at: 1.0))
        XCTAssertEqual(ledger.lastOnset, 1.0)
        XCTAssertFalse(ledger.tryOnset(at: 1.2))
        XCTAssertEqual(ledger.lastOnset, 1.0)
        XCTAssertTrue(ledger.tryOnset(at: 1.4))
        // A caller may state a stricter period than the default.
        XCTAssertFalse(ledger.tryOnset(at: 1.8, minPeriod: 0.5))
        XCTAssertTrue(ledger.tryOnset(at: 1.9, minPeriod: 0.5))
    }

    // ══════════════════════════════════════════════════════════════
    // MARK: - Simulation helpers (pure; no clocks, no sleeps)
    // ══════════════════════════════════════════════════════════════

    /// Models `streamUntilOnsetAdmitted`: returns how many 20 ms hold frames a
    /// loop must stream from `frame` before the ledger admits an onset.
    private func holdFramesUntilAdmitted(ledger: BeatMath.FlashSafety.OnsetLedger,
                                         from frame: Int) -> Int {
        var held = 0
        while !ledger.tryOnset(at: Double(frame + held) * fd) {
            held += 1
            XCTAssertLessThanOrEqual(held, 64, "the gate must admit within a bounded wait")
            if held > 64 { break }
        }
        return held
    }

    /// Frame-index gaps between successive rising edges of `isBright`, sampled
    /// on the 20 ms grid — the realized inter-onset spacing a viewer sees.
    private func risingEdgeGaps(frames: Int, isBright: (Int) -> Bool) -> [Int] {
        var gaps: [Int] = []
        var last: Int?
        var wasBright = false
        for frame in 0..<frames {
            let bright = isBright(frame)
            if bright, !wasBright {
                if let last { gaps.append(frame - last) }
                last = frame
            }
            wasBright = bright
        }
        return gaps
    }
}
