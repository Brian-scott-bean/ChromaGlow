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

    func testGateEnforcesTheSeventeenFramePeriodNotTheWCAGPeriod() {
        // The gate's period is the invariant's OWN unit — 17 frames = 0.34 s —
        // not the 1/3 s the WCAG rate implies. The 6.67 ms between them was
        // slack the cross-run path (card switch, restart) could not afford: no
        // frame plan stands behind it there, and the ledger stamps the moment an
        // onset is ADMITTED, not the moment the frame reaches the wire.
        XCTAssertEqual(FS.minOnsetLedgerPeriod,
                       Double(FS.minCycleFrames()) * FS.entertainmentFrameDuration,
                       accuracy: 1e-15)
        XCTAssertEqual(FS.minOnsetLedgerPeriod, 0.34, accuracy: 1e-15)
        XCTAssertGreaterThan(FS.minOnsetLedgerPeriod, FS.minOnsetPeriod,
                             "the enforced period must not be shorter than the planned one")

        var gate = FS.OnsetGate()
        XCTAssertNil(gate.lastOnset)
        XCTAssertTrue(gate.tryOnset(at: 10))
        XCTAssertEqual(gate.lastOnset, 10)
        XCTAssertFalse(gate.tryOnset(at: 10 + FS.minOnsetPeriod),
                       "1/3 s is NO LONGER admissible — 16.67 frames is not a thing the grid can render")
        XCTAssertEqual(gate.lastOnset, 10, "a refusal must not move the reference point")
        XCTAssertTrue(gate.tryOnset(at: 10 + FS.minOnsetLedgerPeriod),
                      "exactly 17 frames is admissible — the invariant is ≥, not >")
        XCTAssertEqual(gate.lastOnset ?? 0, 10 + FS.minOnsetLedgerPeriod, accuracy: 1e-12)
    }

    func testGateAdmitsAnArithmeticallyExactSeventeenFrameSpacingAtEveryGridPosition() {
        // `Double(n + 17) * 0.02 − Double(n) * 0.02` lands a couple of ULPs BELOW
        // `17 × 0.02` for a little over half of all n. `onsetComparisonTolerance`
        // exists for exactly that and for nothing else: 1 ns, seven orders of
        // magnitude under one frame, so it can never admit a 16-frame interval.
        XCTAssertEqual(FS.onsetComparisonTolerance, 1e-9, accuracy: 0)
        XCTAssertLessThan(FS.onsetComparisonTolerance, FS.entertainmentFrameDuration / 1_000_000)
        var stalledAtSeventeen: [Int] = []
        var admittedAtSixteen: [Int] = []
        for n in 0..<4_000 {
            var exact = FS.OnsetGate()
            _ = exact.tryOnset(at: Double(n) * fd)
            if !exact.tryOnset(at: Double(n + minFrames) * fd) { stalledAtSeventeen.append(n) }
            var short = FS.OnsetGate()
            _ = short.tryOnset(at: Double(n) * fd)
            if short.tryOnset(at: Double(n + minFrames - 1) * fd) { admittedAtSixteen.append(n) }
        }
        XCTAssertEqual(stalledAtSeventeen, [], "17 frames must be admitted at every grid position")
        XCTAssertEqual(admittedAtSixteen, [], "16 frames is the R1-Q defect and must never be admitted")
    }

    func testGateRefusesATimeThatMovesBACKWARDSAndKeepsItsReference() {
        // Every caller samples `CACurrentMediaTime()` OUTSIDE the ledger's lock,
        // so during the un-awaited cancel window two loop instances on one bridge
        // can present their samples out of order. The old `t >= last` qualifier
        // let an inverted sample fall through to `lastOnset = t`: it ADMITTED the
        // onset and re-based the reference backwards, so the next onset was
        // measured from a point in the past.
        var gate = FS.OnsetGate()
        XCTAssertTrue(gate.tryOnset(at: 100.0))
        XCTAssertFalse(gate.tryOnset(at: 99.9), "a backwards time is not a proven-safe interval")
        XCTAssertEqual(gate.lastOnset, 100.0, "the reference point may only ever move forward")
        XCTAssertFalse(gate.tryOnset(at: 0.0))
        XCTAssertFalse(gate.tryOnset(at: -1.0))
        XCTAssertEqual(gate.lastOnset, 100.0)

        // The concrete hazard: an inverted sample followed by one a hair later.
        // Re-basing on 99.9 would have made 100.24 look like a legal 0.34 s.
        XCTAssertFalse(gate.tryOnset(at: 100.24))
        XCTAssertTrue(gate.tryOnset(at: 100.34))

        // Same through the reference-typed ledger the loops actually share.
        let ledger = FS.OnsetLedger()
        XCTAssertTrue(ledger.tryOnset(at: 50.0))
        XCTAssertFalse(ledger.tryOnset(at: 49.5))
        XCTAssertEqual(ledger.lastOnset, 50.0)
        XCTAssertFalse(ledger.tryOnset(at: 49.5 + 0.34))
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
    // MARK: - Beat-branch rise gating (the R1-RG blocker)
    // ══════════════════════════════════════════════════════════════
    //
    // The beat branches used to gate on a CYCLE-INDEX change. But what a
    // photosensitive viewer perceives is not an index — it is the rendered
    // brightness going up. Both loops compute that brightness from live inputs
    // that can move WITHOUT the index moving, and every such move restored full
    // brightness with no gate call at all:
    //
    //   • Party, `phase < hold ? peak : ramp`: `phase` runs backwards on a
    //     BeatClock epoch correction (driveFromTrack/ingest, 1–2×/s against a
    //     playing track) and `hold` runs forward when smoothness is dragged down.
    //   • Strobe, `wantsBright ? peak : minBri`: raising min_brightness while the
    //     strobe sits in its dark half raises the rendered level with no duty
    //     flip to notice.
    //
    // Each model below mirrors the loop body frame-for-frame on the 20 ms grid
    // and measures RENDERED RISES, not gate calls. `riseGated: false`
    // reproduces the shipped-and-reviewed loop so the defect is pinned as a
    // failure, and `riseGated: true` mirrors the fix.

    func testPartyBeatEpochCorrectionCannotRestorePeakBrightnessUngated() {
        // 176 BPM × 1 beat (capped to ×1 — 2.933 Hz is just under the 2.941 Hz
        // ceiling, so the cycle is 17.05 frames), shipped smoothness 20. The
        // clock re-bases its epoch by +68 ms — an ordinary `driveFromTrack`
        // correction — and the phase snaps BACKWARDS out of the fade and into
        // the hold, restoring peak brightness inside one cycle index.
        //
        // Swept over every correction frame in a whole cycle, so the pin is the
        // BEHAVIOUR and not one lucky frame number.
        var worstUngated = Double.infinity
        for correctionFrame in 90..<120 {
            let snapshotAt: (Int) -> BeatSnapshot = { frame in
                BeatSnapshot(bpm: 176, beatEpoch: frame < correctionFrame ? 0 : 0.0682)
            }
            let ungated = partyBeatRenderedRises(frames: 400, riseGated: false,
                                                 snapshotAt: snapshotAt, smoothnessAt: { _ in 0.20 })
            worstUngated = min(worstUngated, minimumGap(ungated) ?? .infinity)

            let gated = partyBeatRenderedRises(frames: 400, riseGated: true,
                                               snapshotAt: snapshotAt, smoothnessAt: { _ in 0.20 })
            XCTAssertGreaterThan(gated.count, 2, "frame \(correctionFrame): the model must render flashes")
            assertOnsetsRespectTheFloor(gated, label: "party epoch correction @\(correctionFrame)")
        }
        XCTAssertLessThan(worstUngated, FS.minOnsetLedgerPeriod,
                          "the index-only gate must be SHOWN to let an epoch correction through ungated — otherwise this test proves nothing")
    }

    func testPartySmoothnessDragCannotRestorePeakBrightnessUngated() {
        // Smoothness dragged 100 → 0 late in the fade: `hold` jumps from 0 to
        // the whole cycle (and the `smoothness <= 0` arm fires), so the rendered
        // level goes 0.11 → 0.90 in a single frame with no index change to
        // notice it — and the genuine boundary a few frames later is admitted on
        // top of it. Swept over every drag frame in two cycles.
        let snapshotAt: (Int) -> BeatSnapshot = { _ in BeatSnapshot(bpm: 176, beatEpoch: 0) }
        var worstUngated = Double.infinity
        for dragFrame in 85..<120 {
            let smoothnessAt: (Int) -> Double = { $0 < dragFrame ? 1.0 : 0.0 }
            let ungated = partyBeatRenderedRises(frames: 400, riseGated: false,
                                                 snapshotAt: snapshotAt, smoothnessAt: smoothnessAt)
            worstUngated = min(worstUngated, minimumGap(ungated) ?? .infinity)

            let gated = partyBeatRenderedRises(frames: 400, riseGated: true,
                                               snapshotAt: snapshotAt, smoothnessAt: smoothnessAt)
            XCTAssertGreaterThan(gated.count, 2, "frame \(dragFrame): the model must render flashes")
            assertOnsetsRespectTheFloor(gated, label: "party smoothness drag @\(dragFrame)")
        }
        XCTAssertLessThan(worstUngated, FS.minOnsetLedgerPeriod,
                          "the index-only gate must be SHOWN to let a smoothness drag through ungated")
        XCTAssertLessThanOrEqual(worstUngated, FS.entertainmentFrameDuration + 1e-12,
                                 "the worst case is two rendered rises ONE FRAME apart — 50 Hz")
    }

    func testPartyBeatBranchSurvivesSeededEpochAndSmoothnessChurn() {
        // Both hazards at once, driven hard: a tempo change every ~2 s, an epoch
        // correction every ~0.5 s (both directions), and a smoothness drag every
        // ~1 s — for 200 s of frames at every tempo the ceiling admits.
        var rng = SeededGenerator(seed: 0xF1A5_04E7)
        var bpm = 120.0
        var epoch = 0.0
        var smoothness = 0.2
        var bpmByFrame: [Double] = []
        var epochByFrame: [Double] = []
        var smoothnessByFrame: [Double] = []
        for frame in 0..<10_000 {
            if frame % 101 == 0 { bpm = Double.random(in: 20...300, using: &rng) }
            if frame % 27 == 0 { epoch += Double.random(in: -0.25...0.25, using: &rng) }
            if frame % 53 == 0 { smoothness = Double.random(in: 0...1, using: &rng) }
            bpmByFrame.append(bpm)
            epochByFrame.append(epoch)
            smoothnessByFrame.append(smoothness)
        }
        let gated = partyBeatRenderedRises(
            frames: 10_000, riseGated: true,
            snapshotAt: { BeatSnapshot(bpm: bpmByFrame[$0], beatEpoch: epochByFrame[$0]) },
            smoothnessAt: { smoothnessByFrame[$0] })
        XCTAssertGreaterThan(gated.count, 10, "the churn model must have produced onsets")
        assertOnsetsRespectTheFloor(gated, label: "party churn")
    }

    func testStrobeBeatBranchGatesAMinBrightnessRaiseWhileDark() {
        // 120 BPM × 1 (2 Hz, 25 frames), duty 50 %. min_brightness is dragged
        // 0 → 50 at frame 65, which falls in the DARK half: no duty flip, so the
        // edge flag notices nothing and the light goes from off to half power
        // ungated — 10 frames (0.2 s) before the next genuine rising edge.
        let snapshot = BeatSnapshot(bpm: 120, beatEpoch: 0)
        let minBriAt: (Int) -> Double = { $0 < 65 ? 0.0 : 0.5 }

        let ungated = strobeBeatRenderedRises(frames: 400, riseGated: false, snapshot: snapshot,
                                              dutyCycle: 0.5, peakBri: 1.0, minBriAt: minBriAt)
        XCTAssertLessThan(minimumGap(ungated) ?? .infinity, FS.minOnsetLedgerPeriod,
                          "the edge-only gate must be shown to let the min_brightness raise through")

        let gated = strobeBeatRenderedRises(frames: 400, riseGated: true, snapshot: snapshot,
                                            dutyCycle: 0.5, peakBri: 1.0, minBriAt: minBriAt)
        XCTAssertGreaterThan(gated.count, 2, "the model must actually render flashes")
        assertOnsetsRespectTheFloor(gated, label: "strobe min_brightness raise")
    }

    // ══════════════════════════════════════════════════════════════
    // MARK: - Total conversions (no input traps a live loop)
    // ══════════════════════════════════════════════════════════════

    func testClampedIntSurvivesEveryDegenerateParamBoxValue() {
        // `Int(Double.nan)`, `Int(.infinity)` and `Int(1e300)` all TRAP. The
        // storm loop read `flash_length` and `afterglow` straight out of the
        // live param box through a bare `Int(_:)`, so the crash sat one corrupt
        // preset ahead of the ranges that were supposed to clamp it.
        let flash = { FS.clampedInt($0, default: 3, range: 1...60) }
        XCTAssertEqual(flash(.nan), 3, "NaN resolves to the caller's default")
        XCTAssertEqual(flash(.infinity), 3)
        XCTAssertEqual(flash(-Double.infinity), 3)
        XCTAssertEqual(flash(1e300), 60, "a finite monster clamps to the range, it does not trap")
        XCTAssertEqual(flash(-1e300), 1)
        XCTAssertEqual(flash(0), 1)
        XCTAssertEqual(flash(-7), 1)
        XCTAssertEqual(flash(1_000), 60)
        // Truncation toward zero, exactly like the `Int(_:)` it replaces.
        XCTAssertEqual(flash(3.9), 3)
        XCTAssertEqual(flash(3.0), 3)
        XCTAssertEqual(FS.clampedInt(-3.9, default: 0, range: -60...60), -3)

        let afterglow = { FS.clampedInt($0, default: 1, range: 0...60) }
        XCTAssertEqual(afterglow(.nan), 1)
        XCTAssertEqual(afterglow(0), 0, "0 still disables the afterglow outright")
        XCTAssertEqual(afterglow(-5), 0)
        XCTAssertEqual(afterglow(1e300), 60)

        // A default outside the range is itself clamped — the result is always
        // inside the range the caller stated.
        XCTAssertEqual(FS.clampedInt(.nan, default: 999, range: 1...60), 60)
        XCTAssertEqual(FS.clampedInt(.nan, default: -999, range: 1...60), 1)

        // And the ranges downstream accept whatever it returns.
        for raw in [Double.nan, .infinity, -Double.infinity, 1e300, -1e300, 0, 3, 61] {
            let fl = FS.clampedInt(raw, default: 3, range: 1...60)
            XCTAssertFalse(FS.ThunderstormPlan.flashFrameRange(flashLength: fl).isEmpty)
            let ag = FS.clampedInt(raw, default: 1, range: 0...60)
            XCTAssertFalse(FS.ThunderstormPlan.afterglowFrameRange(afterglow: ag).isEmpty)
        }
    }

    func testNonFinitePhaseOffsetCannotTrapTheCycleMath() {
        // `beat_phase` reaches the loops as a raw Double out of the param box.
        // `min(max(nan, -8), 8)` is still NaN (every NaN comparison is false), so
        // the clamp let it through and `BeatMath.cycleIndex` evaluated
        // `Int(floor(.nan))` — a trap on the render path, once per frame.
        for raw in [Double.nan, .infinity, -Double.infinity] {
            let binding = BeatBinding(mode: .beatLocked, beatsPerCycle: 1, phaseOffsetBeats: raw)
            XCTAssertEqual(binding.phaseOffsetBeats, 0, "\(raw) must resolve to no offset")
            XCTAssertTrue(binding.phaseOffsetBeats.isFinite)
        }
        // Through the param-box bridge the loops actually use, and all the way
        // into the two conversions that would trap.
        for raw in [Double.nan, .infinity, -Double.infinity] {
            let binding = BeatBinding.fromStudioValues([
                BeatBinding.studioModeKey: 1,
                BeatBinding.studioPerCycleKey: raw,
                BeatBinding.studioPhaseKey: raw,
            ])
            XCTAssertTrue(binding.phaseOffsetBeats.isFinite)
            XCTAssertTrue(binding.beatsPerCycle.isFinite)
            let snapshot = BeatSnapshot(bpm: 120, beatEpoch: 0)
            let idx = BeatMath.cycleIndex(at: 12.5, snapshot: snapshot,
                                          beatsPerCycle: binding.beatsPerCycle,
                                          phaseOffsetBeats: binding.phaseOffsetBeats)
            let phase = BeatMath.cyclePhase(at: 12.5, snapshot: snapshot,
                                            beatsPerCycle: binding.beatsPerCycle,
                                            phaseOffsetBeats: binding.phaseOffsetBeats)
            XCTAssertEqual(idx, 25)
            XCTAssertTrue((0..<1).contains(phase))
        }
        // A legal offset still survives untouched, and the range still clamps.
        XCTAssertEqual(BeatBinding(phaseOffsetBeats: 2.5).phaseOffsetBeats, 2.5)
        XCTAssertEqual(BeatBinding(phaseOffsetBeats: 99).phaseOffsetBeats, 8)
        XCTAssertEqual(BeatBinding(phaseOffsetBeats: -99).phaseOffsetBeats, -8)
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

    /// Smallest interval between successive entries, or nil for fewer than two.
    private func minimumGap(_ times: [Double]) -> Double? {
        guard times.count > 1 else { return nil }
        return (1..<times.count).map { times[$0] - times[$0 - 1] }.min()
    }

    private func assertOnsetsRespectTheFloor(_ times: [Double], label: String,
                                             file: StaticString = #filePath, line: UInt = #line) {
        for i in 1..<max(times.count, 1) {
            XCTAssertGreaterThanOrEqual(times[i] - times[i - 1],
                                        FS.minOnsetLedgerPeriod - FS.onsetComparisonTolerance,
                                        "\(label): rise \(i) at \(times[i]) is too close to \(times[i - 1])",
                                        file: file, line: line)
        }
    }

    /// Pure mirror of the beat branch of `runPartyEntertainment`, frame by frame
    /// on the 20 ms grid. Returns every host time at which the RENDERED
    /// brightness rose by more than `flashRiseEpsilon` — what a viewer sees, as
    /// opposed to what the loop happens to call a gate on.
    ///
    /// `riseGated: false` is the pre-fix loop (gate on cycle-index change only).
    private func partyBeatRenderedRises(
        frames: Int,
        riseGated: Bool,
        peakBri: Double = 0.90,
        minBri: Double = 0.05,
        snapshotAt: (Int) -> BeatSnapshot,
        smoothnessAt: (Int) -> Double
    ) -> [Double] {
        let ledger = FS.OnsetLedger()
        var renderedIdx: Int?
        var lastBri: Double?
        var rises: [Double] = []
        var frame = 0
        while frame < frames {
            let snapshot = snapshotAt(frame)
            let smoothness = smoothnessAt(frame)
            let perCycle = BeatMath.wcagSafeBeatsPerCycle(requested: 1, bpm: snapshot.bpm,
                                                          maxHz: FS.entertainmentMaxLockHz)
            let t = Double(frame) * fd
            let idx = BeatMath.cycleIndex(at: t, snapshot: snapshot, beatsPerCycle: perCycle)
            let phase = BeatMath.cyclePhase(at: t, snapshot: snapshot, beatsPerCycle: perCycle)
            let hold = 1.0 - smoothness
            let bri: Double
            if phase < hold || smoothness <= 0 {
                bri = peakBri
            } else {
                bri = peakBri + (minBri - peakBri) * ((phase - hold) / max(smoothness, 0.001))
            }
            let isRise = bri > (lastBri ?? -1) + FS.flashRiseEpsilon
            let needsGate = riseGated ? (idx != renderedIdx || isRise) : (idx != renderedIdx)
            if needsGate {
                // `streamUntilOnsetAdmitted`: hold the last streamed frame and
                // ask again next frame. A refusal is a delay, never a skip.
                var held = 0
                while !ledger.tryOnset(at: Double(frame + held) * fd,
                                       minPeriod: FS.minOnsetLedgerPeriod) {
                    held += 1
                    if frame + held >= frames { return rises }
                }
                frame += held
                renderedIdx = idx
            }
            if isRise { rises.append(Double(frame) * fd) }
            lastBri = bri
            frame += 1
        }
        return rises
    }

    /// Pure mirror of the beat branch of `runStrobeEntertainment`.
    /// `riseGated: false` is the pre-fix loop (gate on the duty EDGE only).
    private func strobeBeatRenderedRises(
        frames: Int,
        riseGated: Bool,
        snapshot: BeatSnapshot,
        dutyCycle: Double,
        peakBri: Double,
        minBriAt: (Int) -> Double
    ) -> [Double] {
        let ledger = FS.OnsetLedger()
        let perCycle = BeatMath.wcagSafeBeatsPerCycle(requested: 1, bpm: snapshot.bpm,
                                                      maxHz: FS.entertainmentMaxLockHz)
        var isBright = false
        var lastBri: Double?
        var rises: [Double] = []
        var frame = 0
        while frame < frames {
            let minBri = minBriAt(frame)
            let phase = BeatMath.cyclePhase(at: Double(frame) * fd, snapshot: snapshot,
                                            beatsPerCycle: perCycle)
            let wantsBright = phase < dutyCycle
            let bri = wantsBright ? peakBri : minBri
            let isRise = bri > (lastBri ?? -1) + FS.flashRiseEpsilon
            let edge = wantsBright && !isBright
            let needsGate = riseGated ? (edge || isRise) : edge
            if needsGate {
                var held = 0
                while !ledger.tryOnset(at: Double(frame + held) * fd,
                                       minPeriod: FS.minOnsetLedgerPeriod) {
                    held += 1
                    if frame + held >= frames { return rises }
                }
                frame += held
            }
            if isRise { rises.append(Double(frame) * fd) }
            isBright = wantsBright
            lastBri = bri
            frame += 1
        }
        return rises
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
