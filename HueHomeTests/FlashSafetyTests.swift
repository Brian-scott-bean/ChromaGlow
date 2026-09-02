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


// MARK: - Gate-level shorthand

private extension BeatMath.FlashSafety.OnsetGate {
    /// `admit` followed by the `commit` production ALWAYS makes (Guard 14(i)):
    /// delivered, at the same instant. The gate-level tests below used a bare
    /// `admit` as shorthand; since safety round 5 a stamped rise is in flight
    /// until its commit and holds every later onset, so the shorthand has to
    /// say what production says.
    @discardableResult
    mutating func admitDelivered(frame: BeatMath.FlashSafety.WireFrame, at t: Double)
        -> BeatMath.FlashSafety.Reservation {
        let reservation = admit(frame: frame, at: t)
        commit(reservation, delivered: true, at: t)
        return reservation
    }
}

// MARK: - The gate a wire model drives

/// One reserve/commit pair, with the reservation held inside the gate so a
/// model can drive the production gate and a replica of the PREVIOUS one
/// through the same code path and compare what a viewer saw.
///
/// (Declared at file scope because Swift has no nested protocols; nothing but
/// `WireModel` and the two conformances below use it.)
protocol ModelledOnsetGate {
    mutating func reserve(_ frame: BeatMath.FlashSafety.WireFrame, at t: Double)
        -> (onWire: BeatMath.FlashSafety.WireFrame, admitted: Bool)
    mutating func settle(delivered: Bool, at t: Double)
    /// The bridge is showing something this gate did not put there (a session
    /// stop, an explicit group-off) — what `stopSession()` paths now tell the
    /// production ledger (review round, D-2).
    mutating func forgetWire()
}

/// The shipped gate, driven exactly as `emitGatedFrame` drives it.
struct ProductionOnsetGate: ModelledOnsetGate {
    var gate = BeatMath.FlashSafety.OnsetGate()
    private var pending: BeatMath.FlashSafety.Reservation?

    mutating func reserve(_ frame: BeatMath.FlashSafety.WireFrame, at t: Double)
        -> (onWire: BeatMath.FlashSafety.WireFrame, admitted: Bool) {
        let reservation = gate.admit(frame: frame, at: t,
                                     minPeriod: BeatMath.FlashSafety.minOnsetLedgerPeriod)
        pending = reservation
        return (reservation.frame, reservation.wasAdmitted)
    }

    mutating func settle(delivered: Bool, at t: Double) {
        guard let reservation = pending else { return }
        gate.commit(reservation, delivered: delivered, at: t)
        pending = nil
    }

    mutating func forgetWire() { gate.forgetWire() }
}

/// **The gate as it stood before the fifth review round**, kept here for the
/// same reason the legacy loop models below are kept: a fix whose regression
/// test cannot fail on the code it replaced is a fix nobody can check.
///
/// Two things differ from the shipped gate, and only two — both consequences of
/// reading a refused send as an OUTAGE rather than as a frame that changed
/// nothing:
///
///  • `settle(delivered: false)` drops the wire state (`lastEmitted = nil`,
///    trough 0) instead of restoring what the send never displaced; and
///  • a cold refusal holds black at the **requested** chromaticity, so a
///    refusal to flash saturated red is itself a WCAG red flash against the
///    frame the bridge is still showing.
///
/// There is no silence clock, so nothing here ever forgets the wire on time.
struct LegacyForgetOnDropGate: ModelledOnsetGate {
    typealias Frame = BeatMath.FlashSafety.WireFrame
    private typealias FS = BeatMath.FlashSafety

    private var lastOnset: Double?
    private var lastEmitted: Frame?
    private var trough: Double = 0
    private var pendingStamp: Double?
    private var pendingPriorOnset: Double?

    private static let tol = BeatMath.FlashSafety.onsetComparisonTolerance

    private mutating func tryOnset(at t: Double) -> Bool {
        guard t.isFinite else { return false }
        if let last = lastOnset {
            guard t >= last else { return false }
            if t - last < FS.minOnsetLedgerPeriod - Self.tol { return false }
        }
        lastOnset = t
        return true
    }

    private func isCandidate(_ frame: Frame) -> Bool {
        guard let last = lastEmitted else { return false }
        let luminance = frame.relativeLuminance
        if luminance - trough >= FS.onsetRiseThreshold - Self.tol { return true }
        guard frame.chromaDistance(to: last) > FS.onsetColorDelta,
              frame.isSaturatedRed || last.isSaturatedRed else { return false }
        return abs(luminance - last.relativeLuminance) >= FS.redFlashLuminanceDelta - Self.tol
    }

    private mutating func record(_ frame: Frame, resettingTrough: Bool) {
        lastEmitted = frame
        let luminance = frame.relativeLuminance
        trough = resettingTrough ? luminance : min(trough, luminance)
    }

    mutating func reserve(_ frame: Frame, at t: Double) -> (onWire: Frame, admitted: Bool) {
        let prior = lastOnset
        pendingPriorOnset = prior
        pendingStamp = nil

        guard let last = lastEmitted else {
            guard frame.relativeLuminance >= FS.onsetRiseThreshold - Self.tol else {
                record(frame, resettingTrough: true)
                return (frame, true)
            }
            if prior == nil {
                if tryOnset(at: t) { pendingStamp = lastOnset }
                record(frame, resettingTrough: true)
                return (frame, true)
            }
            guard tryOnset(at: t) else {
                // The defect: black at the REQUESTED chromaticity.
                let black = Frame(x: frame.x, y: frame.y, brightness: 0)
                record(black, resettingTrough: true)
                return (black, false)
            }
            pendingStamp = lastOnset
            record(frame, resettingTrough: true)
            return (frame, true)
        }

        guard isCandidate(frame) else {
            record(frame, resettingTrough: false)
            return (frame, true)
        }
        guard tryOnset(at: t) else { return (last, false) }
        pendingStamp = lastOnset
        record(frame, resettingTrough: true)
        return (frame, true)
    }

    mutating func settle(delivered: Bool, at t: Double) {
        guard delivered else {
            if let stamped = pendingStamp, lastOnset == stamped { lastOnset = pendingPriorOnset }
            // The defect: a frame nobody saw makes the wire unknowable.
            lastEmitted = nil
            trough = 0
            return
        }
        guard let stamped = pendingStamp, lastOnset == stamped,
              t.isFinite, t > stamped else { return }
        lastOnset = t
    }

    mutating func forgetWire() { lastEmitted = nil }
}

/// The field a viewer receives from ONE per-channel composition frame, written
/// from the definition and sharing no line with `FlashSafety.fieldFrame`.
///
/// Transcribes the same three statements the production reduction is documented
/// in — mean of the channels' relative luminances, luminance-weighted mean
/// chromaticity, and the CIE L* cube inverted to express that luminance as a
/// dimming level — with every coefficient and threshold written out as a bare
/// literal. If the shipped reduction and this one ever disagree, the composition
/// models below grade a wire the shipped gate did not measure, and the rate
/// assertions fail.
///
/// (File scope because `WireModel` is nested and cannot reach the test class's
/// own `viewer*` helpers; those and this deliberately duplicate the arithmetic
/// rather than share it.)
private func viewerFieldFrame(
    _ channels: [(x: Double, y: Double, brightness: Double)]
) -> BeatMath.FlashSafety.WireFrame {
    func drive(_ x: Double, _ y: Double) -> (r: Double, g: Double, b: Double) {
        guard x.isFinite, y.isFinite, y > 0 else { return (0, 0, 0) }
        let bigX = x / y, bigZ = (1.0 - x - y) / y
        var r =  3.2404542 * bigX - 1.5371385 - 0.4985314 * bigZ
        var g = -0.9692660 * bigX + 1.8760108 + 0.0415560 * bigZ
        var b =  0.0556434 * bigX - 0.2040259 + 1.0572252 * bigZ
        r = max(r, 0); g = max(g, 0); b = max(b, 0)
        let peak = max(r, max(g, b))
        guard peak > 0 else { return (0, 0, 0) }
        return (r / peak, g / peak, b / peak)
    }
    func luminance(_ x: Double, _ y: Double, _ bri: Double) -> Double {
        let c = drive(x, y)
        let chroma = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
        guard bri.isFinite, bri > 0 else { return 0 }
        let l = (100.0 * min(max(bri, 0), 1) + 16.0) / 116.0
        return chroma * min(1, max(0, l * l * l))
    }
    guard !channels.isEmpty else {
        return BeatMath.FlashSafety.WireFrame(x: 0.3127, y: 0.3290, brightness: 0)
    }
    // Non-finite coordinates resolve to D65 and non-finite brightness to 0, the
    // same totality the production frame applies before it weighs anything.
    let safe = channels.map { c -> (x: Double, y: Double, brightness: Double) in
        (x: c.x.isFinite ? c.x : 0.3127,
         y: c.y.isFinite ? c.y : 0.3290,
         brightness: c.brightness.isFinite ? min(max(c.brightness, 0), 1) : 0)
    }
    let lums = safe.map { luminance($0.x, $0.y, $0.brightness) }
    let n = Double(safe.count)
    let fieldLuminance = lums.reduce(0, +) / n
    let total = lums.reduce(0, +)
    let fx: Double, fy: Double
    if total > 0 {
        fx = zip(safe, lums).reduce(0) { $0 + $1.0.x * $1.1 } / total
        fy = zip(safe, lums).reduce(0) { $0 + $1.0.y * $1.1 } / total
    } else {
        fx = safe.reduce(0) { $0 + $1.x } / n
        fy = safe.reduce(0) { $0 + $1.y } / n
    }
    let c = drive(fx, fy)
    let chroma = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
    guard chroma > 0 else {
        return BeatMath.FlashSafety.WireFrame(x: fx, y: fy, brightness: 0)
    }
    let dim = min(1, max(0, fieldLuminance / chroma))
    let bri = dim > 0 ? min(1, max(0, (116.0 * cbrt(dim) - 16.0) / 100.0)) : 0
    return BeatMath.FlashSafety.WireFrame(x: fx, y: fy, brightness: bri)
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
            assertOnsetsRespectTheFloor(gated, label: "party epoch correction @\(correctionFrame)",
                                       atLeast: 3)
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
            assertOnsetsRespectTheFloor(gated, label: "party smoothness drag @\(dragFrame)", atLeast: 3)
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
        assertOnsetsRespectTheFloor(gated, label: "party churn", atLeast: 11)
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
        assertOnsetsRespectTheFloor(gated, label: "strobe min_brightness raise", atLeast: 3)
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
    // MARK: - The frame gate (second pass): the ledger measures the WIRE
    // ══════════════════════════════════════════════════════════════
    //
    // Every hole the second pass found shares one cause: the ledger gated the
    // transitions a loop COMPUTED and not the frames it EMITTED. `admit(frame:at:)`
    // closes the category by asking one question of every frame that reaches the
    // wire — is this brighter than the trough since the last admitted onset (or a
    // palette step at a level a viewer can see)? — and answering with the frame to
    // send, which for a refusal is the frame the bridge is ALREADY showing.

    func testFrameGateAdmitsTheFirstFrameOfABridgesLife() {
        // There is no last frame to hold and no realized onset to be too close
        // to, so the first frame of a COLD ledger must be emitted: refusing it
        // would mean streaming nothing, and a paused DTLS stream lets the bridge
        // fall back to its own light state mid-effect.
        var gate = FS.OnsetGate()
        XCTAssertNil(gate.lastEmitted)
        let first = FS.WireFrame(x: 0.3127, y: 0.3290, brightness: 0.90)
        XCTAssertEqual(gate.admit(frame: first, at: 100.0).verdict, .emit(first))
        XCTAssertEqual(gate.lastEmitted, first)
        XCTAssertEqual(gate.luminanceTroughSinceOnset, first.relativeLuminance, accuracy: 1e-12)
        // ...and STAMPED, because the unknown prior wire state reads as black and
        // white at dimming 0.90 is 0.76 of maximum luminance out of black.
        // Without the stamp a two-frame run followed by a card switch realizes
        // its first MEASURED rise 0.06 s later.
        XCTAssertEqual(gate.lastOnset, 100.0)

        // A first frame BELOW the threshold is not a rise out of black, so it is
        // not stamped — the storm's 0.05 ambient must not delay its first strike.
        // In LUMINANCE that ambient is 0.001 of maximum, not the 0.05 a dimming
        // rule would have compared.
        var dim = FS.OnsetGate()
        let ambient = FS.WireFrame(x: 0.1548, y: 0.1220, brightness: 0.05)
        XCTAssertLessThan(ambient.relativeLuminance, FS.onsetRiseThreshold)
        XCTAssertEqual(dim.admit(frame: ambient, at: 100.0).verdict, .emit(ambient))
        XCTAssertNil(dim.lastOnset)
        let strike = FS.WireFrame(x: 0.3127, y: 0.3290, brightness: 0.90)
        XCTAssertEqual(dim.admit(frame: strike, at: 100.02).verdict, .emit(strike),
                       "the first strike of a session is never delayed")
        XCTAssertEqual(dim.lastOnset, 100.02)
    }

    func testFrameGateLetsFallsAndSubThresholdRisesThroughUngated() {
        // (0.3, 0.3) is a pale off-white: 0.79 of maximum luminance at full
        // drive, so every dimming level below is scaled by that.
        var gate = FS.OnsetGate()
        let full = FS.WireFrame(x: 0.3, y: 0.3, brightness: 1.0)
        _ = gate.admit(frame: full, at: 0)

        // A fall passes and LOWERS the trough.
        let dark = FS.WireFrame(x: 0.3, y: 0.3, brightness: 0.20)
        XCTAssertEqual(gate.admit(frame: dark, at: 0.02).verdict, .emit(dark))
        XCTAssertEqual(gate.luminanceTroughSinceOnset, dark.relativeLuminance, accuracy: 1e-12)

        // A sub-threshold rise passes and does NOT raise the trough. 0.20 → 0.35
        // is a 0.15 DIMMING step — larger than the 0.10 threshold read as
        // dimming — but only 0.044 of maximum luminance, which is what the eye
        // receives and what the rule is stated in.
        let nudge = FS.WireFrame(x: 0.3, y: 0.3, brightness: 0.35)
        XCTAssertGreaterThan(nudge.brightness - dark.brightness, FS.onsetRiseThreshold)
        XCTAssertLessThan(nudge.relativeLuminance - dark.relativeLuminance, FS.onsetRiseThreshold)
        XCTAssertEqual(gate.admit(frame: nudge, at: 0.04).verdict, .emit(nudge))
        XCTAssertEqual(gate.luminanceTroughSinceOnset, dark.relativeLuminance, accuracy: 1e-12,
                       "the trough is the floor a rise is measured from — a rise cannot move it up")

        // One more step is only 0.060 of maximum luminance above the frame
        // before it, but 0.103 above the TROUGH — a candidate. That is defect
        // M3, closed structurally: no per-frame slew limit can see this.
        let second = FS.WireFrame(x: 0.3, y: 0.3, brightness: 0.47)
        XCTAssertLessThan(second.relativeLuminance - nudge.relativeLuminance,
                          FS.onsetRiseThreshold)
        XCTAssertGreaterThanOrEqual(second.relativeLuminance - dark.relativeLuminance,
                                    FS.onsetRiseThreshold)
        XCTAssertEqual(gate.admit(frame: second, at: 0.06).verdict, .hold(nudge))
    }

    func testTopOfRangeDimmingStepIsAQuarterScaleLuminanceFlash() {
        // H-1, concretely. 0.901 → 1.000 is a 0.099 DIMMING step, under a 0.10
        // dimming threshold — and 0.235 of maximum relative luminance, more than
        // twice the WCAG limit. The old rule let it through every time.
        let low = FS.WireFrame(x: 0.3127, y: 0.3290, brightness: 0.901)
        let high = FS.WireFrame(x: 0.3127, y: 0.3290, brightness: 1.0)
        XCTAssertLessThan(high.brightness - low.brightness, FS.onsetRiseThreshold)
        XCTAssertEqual(high.relativeLuminance - low.relativeLuminance, 0.2348, accuracy: 0.002)

        var gate = FS.OnsetGate()
        _ = gate.admitDelivered(frame: low, at: 0)
        XCTAssertEqual(gate.admitDelivered(frame: high, at: 0.02).verdict, .hold(low),
                       "a 23 % luminance rise 20 ms after the last frame is a flash")
        XCTAssertEqual(gate.admitDelivered(frame: high, at: 0.34).verdict, .emit(high))
    }

    func testAChromaStepThatRaisesLuminanceWhileDimmingFallsIsAnOnset() {
        // H-2/M-3, concretely. Saturated blue at dimming 0.90 is 0.055 of
        // maximum luminance; white at dimming 0.85 is 0.66. A dimming rule reads
        // that step as a DECAY (0.90 → 0.85) and the old chroma rule exempted it
        // as one. In luminance it is a 0.60 rise — six times the threshold.
        let blue = FS.WireFrame(x: 0.15, y: 0.06, brightness: 0.90)
        let white = FS.WireFrame(x: 0.3127, y: 0.3290, brightness: 0.85)
        XCTAssertLessThan(white.brightness, blue.brightness)
        XCTAssertEqual(blue.relativeLuminance, 0.0551, accuracy: 0.001)
        XCTAssertEqual(white.relativeLuminance, 0.6598, accuracy: 0.001)

        // Seeded with a realized onset at t = 0, so there is something for the
        // step to be too close to. Blue at dimming 0.90 is BELOW the threshold
        // in luminance, so it is not itself stamped.
        var gate = FS.OnsetGate(lastOnset: 0)
        XCTAssertEqual(gate.admit(frame: blue, at: 0).verdict, .emit(blue))
        XCTAssertEqual(gate.lastOnset, 0, "a 0.055 first frame is not a rise out of black")
        XCTAssertEqual(gate.admit(frame: white, at: 0.02).verdict, .hold(blue))
        XCTAssertEqual(gate.admit(frame: white, at: 0.34).verdict, .emit(white))

        // And the reverse — white → blue at RISING dimming — is a luminance fall
        // and passes straight through, exactly as any other fall does.
        var reverse = FS.OnsetGate(lastOnset: 0)
        _ = reverse.admit(frame: white, at: 0.34)
        XCTAssertEqual(reverse.admit(frame: blue, at: 0.36).verdict, .emit(blue))
    }

    func testFrameGateHoldsTheLastEMITTEDFrameUntilThePeriodPasses() {
        var gate = FS.OnsetGate()
        let dark = FS.WireFrame(x: 0.64, y: 0.33, brightness: 0.0)
        _ = gate.admitDelivered(frame: dark, at: 10.0)
        let flash = FS.WireFrame(x: 0.64, y: 0.33, brightness: 1.0)
        XCTAssertEqual(gate.admitDelivered(frame: flash, at: 10.02).verdict, .emit(flash))
        XCTAssertEqual(gate.lastOnset, 10.02)

        // Down and straight back up, 4 frames later.
        _ = gate.admitDelivered(frame: dark, at: 10.04)
        for n in 3...16 {
            let t = 10.02 + Double(n) * fd
            XCTAssertEqual(gate.admitDelivered(frame: flash, at: t).verdict, .hold(dark),
                           "frame \(n): a refusal must repeat the frame ALREADY on the wire")
        }
        XCTAssertEqual(gate.admitDelivered(frame: flash, at: 10.02 + Double(minFrames) * fd).verdict,
                       .emit(flash), "17 frames later it is admissible")

        // The hold frame carries COLOUR as well as brightness (defect L1: the
        // old hold used `lastColor?.x ?? color.x`, so a party palette step put
        // the NEW colour on the wire while refusing the onset that step WAS).
        var party = FS.OnsetGate()
        let red = FS.WireFrame(x: 0.64, y: 0.33, brightness: 0.90)
        _ = party.admitDelivered(frame: red, at: 20.0)
        let blue = FS.WireFrame(x: 0.15, y: 0.06, brightness: 0.90)
        XCTAssertEqual(party.admitDelivered(frame: blue, at: 20.02).verdict, .hold(red))
        XCTAssertEqual(party.admitDelivered(frame: blue, at: 20.02).frame.x, 0.64)
    }

    func testChromaticityGovernsOnlyTheWCAGRedFlash() {
        // Party's red → blue at constant dimming is a luminance FALL (0.21 → 0.07
        // of maximum), so the general rule does not see it — but WCAG's red flash
        // does, and it is the only rule chromaticity has of its own.
        var party = FS.OnsetGate()
        let red = FS.WireFrame(x: 0.64, y: 0.33, brightness: 1.0)
        let blue = FS.WireFrame(x: 0.15, y: 0.06, brightness: 1.0)
        XCTAssertTrue(red.isSaturatedRed)
        XCTAssertFalse(blue.isSaturatedRed)
        XCTAssertLessThan(blue.relativeLuminance, red.relativeLuminance)
        _ = party.admitDelivered(frame: red, at: 0)
        XCTAssertEqual(party.admitDelivered(frame: blue, at: 0.02).verdict, .hold(red))
        XCTAssertEqual(party.admitDelivered(frame: blue, at: 0.34).verdict, .emit(blue))

        // A chroma step with NO red endpoint and a falling luminance is not an
        // onset at all: the storm's white afterglow giving way to its blue
        // ambient must pass straight through, or every strike would hold its
        // afterglow for 0.34 s. In the old model this needed a
        // `lastAdmittedBrightness` exemption; in luminance it needs nothing.
        var storm = FS.OnsetGate()
        let flash = FS.WireFrame(x: 0.3127, y: 0.3290, brightness: 0.90)
        _ = storm.admitDelivered(frame: flash, at: 0)
        let afterglow = FS.WireFrame(x: 0.3127, y: 0.3290, brightness: 0.36)
        _ = storm.admitDelivered(frame: afterglow, at: 0.02)
        let ambient = FS.WireFrame(x: 0.1548, y: 0.1220, brightness: 0.05)
        XCTAssertFalse(afterglow.isSaturatedRed)
        XCTAssertFalse(ambient.isSaturatedRed)
        XCTAssertEqual(storm.admitDelivered(frame: ambient, at: 0.04).verdict, .emit(ambient))

        // The case the afterglow floor creates: with the afterglow floored at
        // `max(0.4 × 0.50, 0.30)` the step to ambient is exactly level in
        // DIMMING — and still a luminance fall, because white carries 5.7× the
        // luminance of the storm's blue at the same dimming.
        var floored = FS.OnsetGate()
        let strike = FS.WireFrame(x: 0.3127, y: 0.3290, brightness: 0.50)
        _ = floored.admitDelivered(frame: strike, at: 0)
        let glow = FS.WireFrame(x: 0.3127, y: 0.3290, brightness: 0.30)
        _ = floored.admitDelivered(frame: glow, at: 0.02)
        let stormBlue = FS.WireFrame(x: 0.1548, y: 0.1220, brightness: 0.30)
        XCTAssertEqual(stormBlue.brightness, glow.brightness)
        XCTAssertLessThan(stormBlue.relativeLuminance, glow.relativeLuminance)
        XCTAssertEqual(floored.admitDelivered(frame: stormBlue, at: 0.04).verdict, .emit(stormBlue),
                       "a level-dimming colour step DOWN in luminance is decay, not an onset")

        // A red step with no luminance change at all — black to black — is not a
        // red flash: the rule needs 0.02 of luminance movement.
        var off = FS.OnsetGate()
        let black = FS.WireFrame(x: 0.64, y: 0.33, brightness: 0.0)
        _ = off.admitDelivered(frame: black, at: 0)
        let blackBlue = FS.WireFrame(x: 0.15, y: 0.06, brightness: 0.0)
        XCTAssertTrue(black.isSaturatedRed)
        XCTAssertEqual(off.admitDelivered(frame: blackBlue, at: 0.02).verdict, .emit(blackBlue))
    }

    func testFrameGateRefusesABackwardsOrNonFiniteTimeWithoutMovingTheWire() {
        var gate = FS.OnsetGate()
        let dark = FS.WireFrame(x: 0.3, y: 0.3, brightness: 0.0)
        _ = gate.admit(frame: dark, at: 100.0)
        let bright = FS.WireFrame(x: 0.3, y: 0.3, brightness: 1.0)
        _ = gate.admit(frame: bright, at: 100.02)
        _ = gate.admit(frame: dark, at: 100.04)

        XCTAssertEqual(gate.admit(frame: bright, at: 99.0).verdict, .hold(dark),
                       "a backwards sample is not a proven-safe interval")
        XCTAssertEqual(gate.admit(frame: bright, at: .nan).verdict, .hold(dark))
        XCTAssertEqual(gate.admit(frame: bright, at: .infinity).verdict, .hold(dark))
        XCTAssertEqual(gate.lastOnset, 100.02, "the reference point may only ever move forward")
        XCTAssertEqual(gate.lastEmitted, dark, "a refusal leaves the wire state alone")

        // A non-finite BRIGHTNESS cannot poison the trough either: every NaN
        // comparison is false, so a NaN trough would answer "not a rise" forever.
        let poison = FS.WireFrame(x: .nan, y: .infinity, brightness: .nan)
        XCTAssertEqual(poison.brightness, 0)
        XCTAssertEqual(poison.x, 0.3127)
        XCTAssertEqual(poison.y, 0.3290)
        XCTAssertEqual(poison.relativeLuminance, 0)
    }

    func testLedgerExposesTheWireStateItRecords() {
        let ledger = FS.OnsetLedger()
        XCTAssertNil(ledger.lastEmitted)
        let f = FS.WireFrame(x: 0.3, y: 0.3, brightness: 0.7)
        XCTAssertEqual(ledger.admit(frame: f, at: 1.0).verdict, .emit(f))
        XCTAssertEqual(ledger.lastEmitted, f)
        XCTAssertEqual(ledger.luminanceTroughSinceOnset, f.relativeLuminance, accuracy: 1e-12)
        let dim = FS.WireFrame(x: 0.3, y: 0.3, brightness: 0.1)
        _ = ledger.admit(frame: dim, at: 1.02)
        XCTAssertEqual(ledger.luminanceTroughSinceOnset, dim.relativeLuminance, accuracy: 1e-12)
        XCTAssertEqual(ledger.admit(frame: f, at: 1.04).verdict, .hold(dim))
    }

    // ══════════════════════════════════════════════════════════════
    // MARK: - The luminance model (third pass, H-1/H-2/M-3)
    // ══════════════════════════════════════════════════════════════

    func testTheGateConstantsAreThePinnedWCAGValues() {
        XCTAssertEqual(FS.onsetRiseThreshold, 0.10, accuracy: 1e-15,
                       "WCAG 2.3.1 general flash: 10 % of MAXIMUM RELATIVE LUMINANCE")
        XCTAssertEqual(FS.redFlashLuminanceDelta, 0.02, accuracy: 1e-15)
        XCTAssertEqual(FS.saturatedRedFraction, 0.8, accuracy: 1e-15)
        XCTAssertEqual(FS.onsetColorDelta, 0.02, accuracy: 1e-15)
        // The 2 % `flashRiseEpsilon` it replaces was a per-FRAME slew limit: at
        // 50 fps a ramp just under it climbs 0.95 of full scale per second and
        // was never a candidate at all (defect M3). The threshold is measured
        // from the trough, so no ramp rate can evade it.
        XCTAssertGreaterThan(FS.onsetRiseThreshold, 0.019 * 5)
        XCTAssertLessThan(FS.onsetColorDelta, 0.13,
                          "Party's closest palette pair must still read as a step")
        XCTAssertLessThan(FS.redFlashLuminanceDelta, FS.onsetRiseThreshold,
                          "the red flash is hazardous BELOW the general threshold — that is its point")
    }

    func testChromaticityLuminanceFactorsArePinnedAtTheirSRGBValues() {
        // sRGB primaries and the sRGB luminance coefficients, so a saturated
        // primary lands exactly on its own coefficient. These numbers are the
        // whole reason a blue flash and a white flash are not the same flash.
        func factor(_ xy: (x: Double, y: Double)) -> Double {
            FS.chromaticityLuminanceFactor(x: xy.x, y: xy.y)
        }
        XCTAssertEqual(factor((0.3127, 0.3290)), 1.000, accuracy: 0.002, "D65 white")
        XCTAssertEqual(factor((0.6400, 0.3300)), 0.2126, accuracy: 0.002, "saturated red")
        XCTAssertEqual(factor((0.1700, 0.7000)), 0.7155, accuracy: 0.002, "Party green")
        XCTAssertEqual(factor((0.1500, 0.0600)), 0.0722, accuracy: 0.002, "saturated blue")
        XCTAssertEqual(factor((0.4500, 0.4100)), 0.5407, accuracy: 0.002, "Party yellow")
        XCTAssertEqual(factor((0.1548, 0.1220)), 0.1763, accuracy: 0.002, "the storm's blue ambient")

        // White carries 13.8× the luminance of saturated blue at the same
        // dimming — the ratio a dimming-only rule assumed was 1.
        XCTAssertEqual(factor((0.3127, 0.3290)) / factor((0.1500, 0.0600)), 13.8, accuracy: 0.2)

        // Degenerate coordinates resolve to black instead of dividing by zero.
        XCTAssertEqual(factor((0.3, 0)), 0)
        XCTAssertEqual(factor((.nan, .nan)), 0)
    }

    func testDimmingLuminanceIsTheCIECubeAndIsExactlyZeroWhenOff() {
        XCTAssertEqual(FS.dimmingLuminance(0), 0, "off is off, not the cube's 0.0026 offset")
        XCTAssertEqual(FS.dimmingLuminance(1), 1, accuracy: 1e-12)
        XCTAssertEqual(FS.dimmingLuminance(0.5), 0.1842, accuracy: 0.0005)
        XCTAssertEqual(FS.dimmingLuminance(0.9), 0.7630, accuracy: 0.0005)
        // Monotone, bounded, and total on every input a param box can hold.
        var previous = -1.0
        for step in 0...100 {
            let value = FS.dimmingLuminance(Double(step) / 100.0)
            XCTAssertGreaterThanOrEqual(value, previous)
            XCTAssertLessThanOrEqual(value, 1)
            previous = value
        }
        for raw in [Double.nan, .infinity, -.infinity, -1, 1e300] {
            let value = FS.dimmingLuminance(raw)
            XCTAssertTrue(value.isFinite, "\(raw)")
            XCTAssertTrue((0...1).contains(value), "\(raw)")
        }
    }

    func testSaturatedRedIsTheOnlyChromaticityWithARuleOfItsOwn() {
        XCTAssertTrue(FS.WireFrame(x: 0.64, y: 0.33, brightness: 0.5).isSaturatedRed)
        XCTAssertFalse(FS.WireFrame(x: 0.3127, y: 0.3290, brightness: 0.5).isSaturatedRed)
        XCTAssertFalse(FS.WireFrame(x: 0.15, y: 0.06, brightness: 0.5).isSaturatedRed)
        XCTAssertFalse(FS.WireFrame(x: 0.17, y: 0.70, brightness: 0.5).isSaturatedRed)
        XCTAssertFalse(FS.WireFrame(x: 0.32, y: 0.15, brightness: 0.5).isSaturatedRed,
                       "purple is half blue — not a red flash")
        XCTAssertEqual(FS.redDriveFraction(x: 0.3127, y: 0.3290), 1.0 / 3.0, accuracy: 0.005)
    }

    func testTheProductionLuminanceAgreesWithTheIndependentMeasurement() {
        // `WireFrame.relativeLuminance` and the test suite's own `viewerLuminance`
        // are separate transcriptions of the same definition. Every model below
        // is graded by the second one, so they have to agree.
        var probes: [FS.WireFrame] = []
        for xy in Self.partyPalette + [Self.stormAmbient, Self.stormFlash, (x: 0.3, y: 0.3)] {
            for step in 0...20 {
                probes.append(FS.WireFrame(x: xy.x, y: xy.y, brightness: Double(step) / 20.0))
            }
        }
        for probe in probes {
            XCTAssertEqual(probe.relativeLuminance, viewerLuminance(probe), accuracy: 1e-12,
                           "xy (\(probe.x), \(probe.y)) at \(probe.brightness)")
            XCTAssertEqual(FS.redDriveFraction(x: probe.x, y: probe.y),
                           viewerRedFraction(probe), accuracy: 1e-12)
        }
    }

    // ══════════════════════════════════════════════════════════════
    // MARK: - The second pass's scenarios, rendered frame by frame
    // ══════════════════════════════════════════════════════════════
    //
    // Each of these runs the SAME loop model twice: once through the shipped
    // pre-fix mechanism (`legacy…`, which gates computed transitions and
    // assembles its own hold frames) and once through `WireModel`, which is a
    // frame-for-frame mirror of `emitGatedFrame` / `emitOnsetFrame`. Both
    // produce a list of EMITTED frames, and both are measured by the same
    // `realizedOnsets`, which re-derives the WCAG rule from the wire alone and
    // never asks either gate anything.

    func testCrossRunMinBrightnessRaiseIsNotItselfAnUngatedRise() {
        // Blocker B1. A run at min_brightness 0 is replaced by a run at
        // min_brightness 50 (catalog 0…50, both legal). The old hold frame was
        // `lastBri ?? minBri` and a fresh loop's `lastBri` is nil, so the frame
        // streamed to REFUSE the new run's onset was itself 0.50 on the wire.
        let legacy = legacyStrobeFreeRunAcrossARunBoundary(minA: 0.0, minB: 0.50)
        XCTAssertLessThan(minimumGap(realizedOnsets(legacy)) ?? .infinity,
                          FS.minOnsetLedgerPeriod,
                          "B1 must be SHOWN on the pre-fix model, or this test proves nothing")

        let model = WireModel()
        modelStrobeFreeRun(model, cycles: 3, speed: 100, duty: 0.5, peak: 1.0, minBri: 0.0)
        // ...and the card is stopped four frames into its DARK half, which is
        // where the switch has to happen for the old hold frame to be a rise.
        let plan = FS.StrobePlan.make(speed: 100, dutyCycle: 0.5)
        model.emitOnset(1.0)
        for _ in 1..<plan.onFrames { model.emit(1.0) }
        model.emitOnset(0.0)
        for _ in 1..<4 { model.emit(0.0) }
        let switchFrame = model.frame
        modelStrobeFreeRun(model, cycles: 4, speed: 100, duty: 0.5, peak: 1.0, minBri: 0.50)
        let onsets = realizedOnsets(model.wire)
        XCTAssertGreaterThan(onsets.count, 3, "the model must actually flash")
        assertOnsetsRespectTheFloor(onsets, label: "B1 cross-run min_brightness 0 → 50", atLeast: 4)

        // And concretely: the frame that REFUSES the new run's onset is the dark
        // frame the bridge is already showing, not the new run's 0.50 floor.
        XCTAssertEqual(model.wire[switchFrame - 1].frame.brightness, 0.0)
        XCTAssertEqual(model.wire[switchFrame].frame.brightness, 0.0, accuracy: 1e-12,
                       "the refusing frame must be the frame the bridge is already showing")
    }

    func testThunderstormAfterglowToAmbientRiseIsHeldNotStreamed() {
        // H1. flash_intensity 50 and min_brightness 30 (both in range): the
        // afterglow renders 0.4 × 0.50 = 0.20 and the very next ambient frame
        // renders 0.30 — a +0.10 rise two frames after the strike. The old
        // ambient-raise gate compared against the previous AMBIENT, not against
        // the last EMITTED frame, so it could not see it.
        let legacy = legacyStorm(strikes: 6, frequency: 1.0, flashIntensity: 0.50,
                                 minBri: 0.30, flashFrames: 2, afterglowFrames: 1)
        XCTAssertLessThan(minimumGap(realizedOnsets(legacy)) ?? .infinity,
                          FS.minOnsetLedgerPeriod,
                          "H1 must be SHOWN on the pre-fix model")

        // The fix is in two parts, and only the first is load-bearing for
        // safety. The ledger measures the wire, so it would HOLD that climb — but
        // holding it costs the storm a second admitted onset per strike and
        // halves its cadence. Flooring the afterglow at the ambient it returns to
        // removes the climb instead, so a strike decays monotonically and the
        // ledger has nothing to hold. The ledger remains the backstop.
        let strikes = 8
        let model = WireModel()
        modelStorm(model, strikes: strikes, frequency: 1.0, flashIntensity: 0.50,
                   minBri: 0.30, flashFrames: 2, afterglowFrames: 1)
        let onsets = realizedOnsets(model.wire)
        assertOnsetsRespectTheFloor(onsets, label: "H1 storm FI 50 / min 30 / afterglow 1",
                                    atLeast: strikes)
        XCTAssertEqual(onsets.count, strikes,
                       "ONE admitted onset per strike — the return to ambient is no longer one")

        // The afterglow never dips below the ambient it hands back to, so the
        // whole strike is a monotone fall: 0.50 → 0.50 → 0.30 → 0.30…
        let afterglowBri = max(0.50 * 0.4, 0.30)
        XCTAssertEqual(afterglowBri, 0.30, accuracy: 1e-12)
        XCTAssertEqual(model.wire.map(\.frame.brightness).min(), 0.30,
                       "nothing on the wire is dimmer than the ambient level")
        let strikeAt = model.wire.firstIndex { $0.frame.brightness >= 0.50 - 1e-12 }
        XCTAssertNotNil(strikeAt)
        if let k = strikeAt {
            for n in (k + 1)..<min(k + minFrames, model.wire.count) {
                XCTAssertLessThanOrEqual(model.wire[n].frame.brightness,
                                         model.wire[n - 1].frame.brightness + 1e-12,
                                         "frame \(n - k) after the strike is a CLIMB, not a decay")
            }
        }

        // And the shipped default storm is untouched by the floor: 0.4 × 0.90 is
        // already well above its 0.05 ambient.
        let defaultStorm = WireModel()
        modelStorm(defaultStorm, strikes: 6, frequency: 0.5, flashIntensity: 0.90,
                   minBri: 0.05, flashFrames: 3, afterglowFrames: 1)
        XCTAssertEqual(realizedOnsets(defaultStorm.wire).count, 6)
        assertOnsetsRespectTheFloor(realizedOnsets(defaultStorm.wire), label: "default storm", atLeast: 6)
    }

    func testStrobeWithBrightnessBelowMinBrightnessGatesTheRisingOFFEdge() {
        // H2. brightness 1 with min_brightness 50 (1…100 vs 0…50, both legal):
        // the ON edge is a FALL and the OFF edge is the rise. The old gate
        // stamped the ON edge — `onFrames` before the real rise — so a run at
        // duty 90 followed by a run at duty 10 realized 0.08 s.
        let legacy = legacyStrobeInvertedAcrossARunBoundary(dutyA: 0.9, dutyB: 0.1)
        let legacyGap = minimumGap(realizedOnsets(legacy)) ?? .infinity
        XCTAssertLessThan(legacyGap, FS.minOnsetLedgerPeriod,
                          "H2 must be SHOWN on the pre-fix model")
        XCTAssertLessThanOrEqual(legacyGap, 0.10 + 1e-12,
                                 "the reported worst case is ~0.08 s")

        let model = WireModel()
        modelStrobeFreeRun(model, cycles: 3, speed: 100, duty: 0.9, peak: 0.01, minBri: 0.50)
        modelStrobeFreeRun(model, cycles: 3, speed: 100, duty: 0.1, peak: 0.01, minBri: 0.50)
        let onsets = realizedOnsets(model.wire)
        XCTAssertGreaterThan(onsets.count, 2, "the inverted strobe must still flash")
        assertOnsetsRespectTheFloor(onsets, label: "H2 inverted strobe, duty 90 → 10", atLeast: 3)
    }

    func testACumulativeRampNoPerFrameEpsilonCouldSeeIsGatedByTheTrough() {
        // M3. 0.019 per frame never trips a 0.02 per-FRAME epsilon, and at 50 fps
        // it is 0.95 of full scale per second. Measured from the trough it is a
        // candidate within six frames, and the wire becomes a staircase.
        let step = 0.019
        XCTAssertLessThan(step, 0.02, "the ramp must be invisible to the epsilon it replaces")
        let model = WireModel()
        model.emit(0.0)
        for k in 1...250 { model.emit(min(1.0, Double(k) * step)) }
        let onsets = realizedOnsets(model.wire)
        XCTAssertGreaterThan(onsets.count, 1, "the ramp must still be rendered, in steps")
        assertOnsetsRespectTheFloor(onsets, label: "cumulative 0.019/frame ramp", atLeast: 2)

        // The realized slew: at most one `onsetRiseThreshold` step per
        // `minOnsetLedgerPeriod`, i.e. under 0.30 of full scale per second —
        // against the 0.95 the same ramp used to realize.
        let span = model.wire.last!.time - model.wire.first!.time
        XCTAssertLessThanOrEqual(Double(onsets.count), span / FS.minOnsetLedgerPeriod + 1)
    }

    func testThunderstormDoesNotBlackOutOrStallOnItsFirstIteration() {
        // M4. The old ambient-raise gate compared `minBri` against a nil
        // `lastAmbientBri`, so EVERY start looked like a raise: the storm
        // streamed hold frames at `lastAmbientBri ?? 0` — a literal blackout —
        // and delayed its first strike behind them.
        // On a CARD SWITCH the bridge's ledger already holds a recent onset, so
        // the raise gate actually waits — and what it streamed while waiting was
        // `lastAmbientBri ?? 0`: a full 17 frames of black.
        let legacy = legacyStorm(strikes: 1, frequency: 0.5, flashIntensity: 0.90,
                                 minBri: 0.05, flashFrames: 3, afterglowFrames: 1,
                                 seedOnset: 0.0)
        XCTAssertEqual(legacy.prefix { $0.frame.brightness == 0 }.count, minFrames,
                       "the pre-fix storm really did open a card switch with 0.34 s of black")

        let switched = WireModel()
        modelStrobeFreeRun(switched, cycles: 2, speed: 100, duty: 0.5, peak: 1.0, minBri: 0.0)
        let handoff = switched.frame
        modelStorm(switched, strikes: 3, frequency: 0.5, flashIntensity: 0.90,
                   minBri: 0.05, flashFrames: 3, afterglowFrames: 1)
        XCTAssertEqual(switched.wire[handoff].frame.brightness, 0.05,
                       "the storm's first frame after a switch is the ambient it asked for")
        XCTAssertEqual(switched.wire[handoff...].prefix { $0.frame.brightness == 0 }.count, 0,
                       "no blackout: 0.05 above a trough of 0 is not a candidate at all")
        assertOnsetsRespectTheFloor(realizedOnsets(switched.wire),
                                    label: "M4 storm after a card switch", atLeast: 4)

        // Cold start: the first frame is the ambient, and the first strike lands
        // on the budget's own gap — 0.05 is below the threshold, so the very
        // first frame of the bridge's life is not stamped either.
        let model = WireModel()
        modelStorm(model, strikes: 4, frequency: 0.5, flashIntensity: 0.90,
                   minBri: 0.05, flashFrames: 3, afterglowFrames: 1)
        XCTAssertEqual(model.wire.first?.frame.brightness, 0.05)
        let requestedGap = FS.ThunderstormPlan.requestedGapFrames(frequency: 0.5)
        XCTAssertEqual(model.wire.firstIndex { $0.frame.brightness >= 0.90 - 1e-12 }, requestedGap)
        assertOnsetsRespectTheFloor(realizedOnsets(model.wire), label: "M4 storm cold start", atLeast: 4)
    }

    func testPartyFreeRunPaletteStepsStayAFloorApartAcrossARunBoundary() {
        // L1 in situ: a card switch restarts the loop on a new palette colour,
        // and the frames streamed while that step waits are the PREVIOUS colour
        // at the PREVIOUS level.
        let model = WireModel()
        modelPartyFreeRun(model, cycles: 4, speed: 100, smoothness: 0.20,
                          peak: 0.90, minBri: 0.05, startIndex: 0)
        let switchFrame = model.frame
        modelPartyFreeRun(model, cycles: 4, speed: 100, smoothness: 0.20,
                          peak: 0.90, minBri: 0.05, startIndex: 3)
        XCTAssertEqual(model.wire[switchFrame].frame.x,
                       model.wire[switchFrame - 1].frame.x,
                       "a refused palette step must not put the new colour on the wire")
        assertOnsetsRespectTheFloor(realizedOnsets(model.wire), label: "L1 party run boundary", atLeast: 6)

        // Constant DIMMING (peak == min) is not constant luminance: the palette
        // itself swings from saturated blue (0.07 of maximum) to Party's green
        // (0.72), so at full drive most steps are luminance onsets and the
        // steps to and from red are WCAG red flashes. Both kinds are still a
        // floor apart. (This is the case the old model needed a chroma onset
        // rule for; the luminance model reads it directly.)
        let flat = WireModel()
        modelPartyFreeRun(flat, cycles: 8, speed: 100, smoothness: 0.20,
                          peak: 1.0, minBri: 1.0, startIndex: 0)
        let flatOnsets = realizedOnsets(flat.wire)
        assertOnsetsRespectTheFloor(flatOnsets, label: "flat party palette steps", atLeast: 5)
        XCTAssertGreaterThan(realizedRedFlashes(flat.wire).count, 0,
                             "a flat party's step off saturated red is a WCAG red flash")

        // The same palette at a LOW dimming carries so little luminance that no
        // step reaches either threshold — which is the honest answer, not a
        // hole: at dimming 0.25 the whole palette spans 0.003…0.032 of maximum.
        let dimFlat = WireModel()
        modelPartyFreeRun(dimFlat, cycles: 8, speed: 100, smoothness: 0.20,
                          peak: 0.25, minBri: 0.25, startIndex: 0)
        let dimSpan = dimFlat.wire.map { viewerLuminance($0.frame) }
        XCTAssertLessThan((dimSpan.max() ?? 0) - (dimSpan.min() ?? 0), FS.onsetRiseThreshold)
        for time in realizedOnsets(dimFlat.wire) {
            XCTFail("a sub-threshold palette swing is not an onset (at \(time))")
        }
    }

    func testSeededParamChurnThroughTheFrameGateNeverRealizesAFastOnset() {
        // Everything at once, on one bridge, across run boundaries: strobe,
        // party and the storm take turns on the SAME ledger while every param
        // the second pass named is churned — including the inverted brightness
        // ≤ min_brightness case and the H1 afterglow/ambient pair.
        //
        // Fifth review round: the transport churns too. A dozen seeded outages
        // are scattered across the run, so every switch between effects, every
        // run boundary and every hold has a chance of landing next to a frame
        // the transport refused — the case where the gate's model of the wire
        // and the wire itself can come apart.
        var rng = SeededGenerator(seed: 0x5EC0_4DEA)
        let model = WireModel()
        var outageStart = Int.random(in: 5...40, using: &rng)
        for _ in 0..<12 {
            let length = Int.random(in: 1...9, using: &rng)
            model.dropWindows.append(outageStart..<(outageStart + length))
            outageStart += length + Int.random(in: 40...160, using: &rng)
        }
        for _ in 0..<30 {
            switch Int.random(in: 0...2, using: &rng) {
            case 0:
                modelStrobeFreeRun(model, cycles: Int.random(in: 1...3, using: &rng),
                                   speed: Double.random(in: 0...100, using: &rng),
                                   duty: Double.random(in: 0...1, using: &rng),
                                   peak: Double.random(in: 0.01...1, using: &rng),
                                   minBri: Double.random(in: 0...0.5, using: &rng))
            case 1:
                modelPartyFreeRun(model, cycles: Int.random(in: 1...3, using: &rng),
                                  speed: Double.random(in: 0...100, using: &rng),
                                  smoothness: Double.random(in: 0...1, using: &rng),
                                  peak: Double.random(in: 0.01...1, using: &rng),
                                  minBri: Double.random(in: 0...1, using: &rng),
                                  startIndex: Int.random(in: 0...7, using: &rng))
            default:
                modelStorm(model, strikes: Int.random(in: 1...3, using: &rng),
                           frequency: Double.random(in: 0...1, using: &rng),
                           flashIntensity: Double.random(in: 0.01...1, using: &rng),
                           minBri: Double.random(in: 0...0.5, using: &rng),
                           flashFrames: Int.random(in: 1...8, using: &rng),
                           afterglowFrames: Int.random(in: 0...3, using: &rng))
            }
        }
        let onsets = realizedOnsets(model.wire)
        XCTAssertGreaterThan(onsets.count, 20, "the churn must have produced onsets")
        assertOnsetsRespectTheFloor(onsets, label: "cross-effect seeded churn on one bridge",
                                    atLeast: 20)
    }

    // ══════════════════════════════════════════════════════════════
    // MARK: - Reserve / commit: the ledger may not run ahead of the wire
    // ══════════════════════════════════════════════════════════════
    //
    // `send(channels:)` is fire-and-forget: `guard case .streaming = state, let
    // conn = connection else { return }` silently drops every frame while the
    // DTLS connection is re-establishing, and `isTerminallyFailed` stays false
    // for the whole reconnect budget, so nothing else in the loop can tell.
    // `admit` therefore only RESERVES; `commit` is what makes the reservation
    // true — or rolls it back and forgets the wire.

    func testADroppedSendRollsBackTheStampAndRestoresTheWire() {
        // Fifth review round. A send the transport refused never reached the
        // bridge, so the bridge is STILL SHOWING THE LAST DELIVERED FRAME: the
        // gate rolls the whole reservation back — the stamp AND the wire state —
        // rather than declaring the wire unknown on the strength of one frame.
        var gate = FS.OnsetGate()
        let dark = FS.WireFrame(x: 0.3127, y: 0.3290, brightness: 0.0)
        let bright = FS.WireFrame(x: 0.3127, y: 0.3290, brightness: 0.90)

        // A realized onset at t = 0, delivered; then a fall, delivered.
        let first = gate.admit(frame: bright, at: 0)
        gate.commit(first, delivered: true, at: 0)
        XCTAssertEqual(gate.lastOnset, 0)
        let fall = gate.admit(frame: dark, at: 0.02)
        gate.commit(fall, delivered: true, at: 0.02)
        XCTAssertEqual(gate.lastEmitted, dark)
        XCTAssertEqual(gate.luminanceTroughSinceOnset, 0, accuracy: 1e-12)
        XCTAssertEqual(gate.lastDeliveredAt, 0.02)

        // The next onset is admitted at 0.34 — and DROPPED.
        let dropped = gate.admit(frame: bright, at: 0.34)
        XCTAssertTrue(dropped.wasAdmitted)
        XCTAssertEqual(gate.lastOnset, 0.34, "the reservation stamps provisionally")
        gate.commit(dropped, delivered: false, at: 0.34)
        XCTAssertEqual(gate.lastOnset, 0, "a frame nobody saw is not a realized onset")
        XCTAssertEqual(gate.lastEmitted, dark,
                       "a frame nobody saw did not change the wire either — the bridge is still showing the last DELIVERED frame")
        XCTAssertEqual(gate.luminanceTroughSinceOnset, 0, accuracy: 1e-12,
                       "and the true trough survives, or every rise measured after it is short")
        XCTAssertEqual(gate.lastDeliveredAt, 0.02, "the silence clock did not move: nothing was delivered")

        // A silence of a whole period IS an outage, and that is what makes the
        // wire unknown. The next admit forgets it before deciding anything.
        let afterSilence = gate.admit(frame: dark, at: 0.02 + FS.minOnsetLedgerPeriod)
        XCTAssertEqual(gate.lastEmitted, dark, "the frame this admit itself recorded")
        gate.commit(afterSilence, delivered: false, at: 0.02 + FS.minOnsetLedgerPeriod)
        XCTAssertNil(gate.lastEmitted,
                     "the forget happened at the TOP of that admit, so rolling the admit back restores 'unknown' — a rollback may not un-do a fact about the transport")
        XCTAssertEqual(gate.lastOnset, 0, "and the realized-onset clock never moved")

        // An INTERLEAVED admit (the un-awaited cancel window) means this
        // reservation is no longer the gate's latest word about the wire, so
        // restoring it would be a guess: forget instead.
        var shared = FS.OnsetGate()
        let mine = shared.admit(frame: bright, at: 10.0)
        let theirs = shared.admit(frame: dark, at: 10.0)
        shared.commit(mine, delivered: false, at: 10.0)
        XCTAssertNil(shared.lastEmitted,
                     "a rollback that cannot be the latest word forgets the wire (conservative)")
        shared.commit(theirs, delivered: true, at: 10.0)
    }

    func testASilentWireIsForgottenAfterAWholePeriodAndTheReconnectRiseIsTheStamp() {
        // The hole a blanket "restore the pre-drop state" would reopen. A DTLS
        // reconnect spends >= 300 ms in backoff and the bridge reverts to its own
        // light state meanwhile; handing the returning stream a BRIGHT lastEmitted
        // and its trough would make the first frame back a non-candidate, and a
        // fall-then-rise two frames later would be measured from a fresh trough
        // and admitted against the OLD stamp — two realized onsets 40 ms apart.
        var gate = FS.OnsetGate()
        let white = FS.WireFrame(x: 0.3127, y: 0.3290, brightness: 0.90)
        let black = FS.WireFrame(x: 0.3127, y: 0.3290, brightness: 0.0)

        let first = gate.admit(frame: white, at: 0)
        gate.commit(first, delivered: true, at: 0)
        XCTAssertEqual(gate.lastOnset, 0)
        XCTAssertEqual(gate.lastDeliveredAt, 0)

        // Nothing reaches the transport for a whole period. The next frame is
        // therefore a FIRST frame: gated against the last realized onset, and
        // stamped, because the wire it is measured against is unknown.
        let back = 0.02 + FS.minOnsetLedgerPeriod
        let returning = gate.admit(frame: white, at: back)
        XCTAssertTrue(returning.wasAdmitted)
        XCTAssertEqual(gate.lastOnset ?? 0, back, accuracy: 1e-12,
                       "the reconnect rise is itself the onset, and it carries the stamp")
        gate.commit(returning, delivered: true, at: back)

        // ...so the fall-and-rise behind it is refused, and the hold is the
        // black frame already on the wire.
        let fall = gate.admit(frame: black, at: back + fd)
        XCTAssertTrue(fall.wasAdmitted)
        gate.commit(fall, delivered: true, at: back + fd)
        let second = gate.admit(frame: white, at: back + 2 * fd)
        XCTAssertFalse(second.wasAdmitted,
                       "a rise 40 ms after the reconnect rise is REFUSED, not realized")
        XCTAssertEqual(second.verdict, .hold(black))
        gate.commit(second, delivered: true, at: back + 2 * fd)
    }

    func testAColdRefusalHoldsBlackAtTheLastKNOWNChromaticityNotTheRequestedOne() {
        // Black at the REQUESTED chromaticity is not a fall on the wire: against
        // the frame the bridge is still showing it is a chroma STEP, and a step
        // to saturated red with a luminance change is a WCAG red flash — the
        // refusal to flash would be a flash. Black at the colour already there
        // is a pure fall against a known wire and black against an unknown one.
        var gate = FS.OnsetGate()
        let green = FS.WireFrame(x: 0.1700, y: 0.7000, brightness: 1.0)
        let red = FS.WireFrame(x: 0.6400, y: 0.3300, brightness: 1.0)

        let lit = gate.admit(frame: green, at: 0)
        gate.commit(lit, delivered: true, at: 0)
        XCTAssertEqual(gate.lastKnownFrame, green)

        // The wire becomes unknown (a card switch tearing the session down).
        gate.forgetWire()
        XCTAssertNil(gate.lastEmitted)
        XCTAssertEqual(gate.lastKnownFrame, green, "what was DRIVEN survives; what is SHOWN does not")

        let refused = gate.admit(frame: red, at: 0.10)
        XCTAssertFalse(refused.wasAdmitted)
        XCTAssertEqual(refused.verdict,
                       .hold(FS.WireFrame(x: 0.1700, y: 0.7000, brightness: 0)),
                       "the hold is black at GREEN — holding black at the requested red would be the red flash the refusal exists to prevent")
    }

    func testTheColdPathAppliesTheRedFlashRuleAgainstTheLastKnownFrame() {
        // The in-catalog Thunderstorm mechanism at gate level: a white strike at
        // dimming 0.20 carries 0.030 of maximum luminance, which is under the
        // general threshold, so cold candidacy on absolute luminance alone
        // emitted it unstamped — and the red ambient frame behind it was then
        // stamped as a first onset. Two red flashes, one frame apart.
        var gate = FS.OnsetGate()
        let redAmbient = FS.WireFrame(x: 0.6400, y: 0.3300, brightness: 0.01)
        let whiteStrike = FS.WireFrame(x: 0.3127, y: 0.3290, brightness: 0.20)
        XCTAssertLessThan(whiteStrike.relativeLuminance, FS.onsetRiseThreshold,
                          "the strike is under the GENERAL threshold — that is the whole point")

        let ambient = gate.admit(frame: redAmbient, at: 0)
        gate.commit(ambient, delivered: true, at: 0)
        XCTAssertNil(gate.lastOnset, "a 0.0007 ambient frame is no flash — nothing is stamped")

        gate.forgetWire()
        let strike = gate.admit(frame: whiteStrike, at: 0.02)
        XCTAssertTrue(strike.wasAdmitted)
        XCTAssertEqual(gate.lastOnset ?? -1, 0.02, accuracy: 1e-12,
                       "a red flash below the general threshold is still a flash, and the cold path must stamp it")
        gate.commit(strike, delivered: true, at: 0.02)

        // And the step back to red one frame later is refused.
        let back = gate.admit(frame: redAmbient, at: 0.04)
        XCTAssertFalse(back.wasAdmitted)
        XCTAssertEqual(back.verdict, .hold(whiteStrike))
    }

    func testAColdLedgerStillEmitsItsFirstFrameUnconditionally() {
        // No prior stamp means there is no realized onset to be too close to,
        // and refusing the frame would mean streaming nothing at all.
        var cold = FS.OnsetGate()
        let bright = FS.WireFrame(x: 0.3127, y: 0.3290, brightness: 1.0)
        let r = cold.admit(frame: bright, at: 500.0)
        XCTAssertEqual(r.verdict, .emit(bright))
        XCTAssertEqual(cold.lastOnset, 500.0)
    }

    func testDeliveryMovesTheStampForwardToTheDeliveryTime() {
        // H-3: `admit` decides on a clock sample taken BEFORE the send and the
        // frame reaches the transport an actor hop later. Stamping at decision
        // time permits a realized spacing shorter than the enforced period.
        var gate = FS.OnsetGate()
        let bright = FS.WireFrame(x: 0.3127, y: 0.3290, brightness: 1.0)
        let dark = FS.WireFrame(x: 0.3127, y: 0.3290, brightness: 0.0)
        let first = gate.admit(frame: bright, at: 0)
        gate.commit(first, delivered: true, at: 0.06)   // 60 ms of actor jitter
        XCTAssertEqual(gate.lastOnset ?? 0, 0.06, accuracy: 1e-12,
                       "the reference point is where the frame reached the wire")

        let fall = gate.admit(frame: dark, at: 0.08)
        gate.commit(fall, delivered: true, at: 0.08)
        // A second onset decided at 0.34 is now measured from 0.06, not from 0.
        let early = gate.admit(frame: bright, at: 0.34)
        XCTAssertFalse(early.wasAdmitted)
        gate.commit(early, delivered: true, at: 0.34)
        let late = gate.admit(frame: bright, at: 0.40)
        XCTAssertTrue(late.wasAdmitted)
        gate.commit(late, delivered: true, at: 0.40)
        XCTAssertGreaterThanOrEqual(0.40 - 0.06, FS.minOnsetLedgerPeriod - 1e-9)
        // A delivery time that runs BACKWARDS (or is unmeasurable) never moves
        // the reference point back.
        let after = gate.admit(frame: dark, at: 0.42)
        gate.commit(after, delivered: true, at: .nan)
        XCTAssertEqual(gate.lastOnset ?? 0, 0.40, accuracy: 1e-12)
    }

    // ══════════════════════════════════════════════════════════════
    // MARK: - The reconnect (blocker B-1), on all three loops
    // ══════════════════════════════════════════════════════════════
    //
    // Each of these runs the SAME loop model twice on the same drop window:
    // once with `ledgerIgnoresDrops` (the shipped ledger, which commits every
    // reservation as delivered and so runs ahead of the wire) and once through
    // the reserve/commit ledger. Both are graded by `realizedOnsets`, which sees
    // only DELIVERED frames — dropped frames are not on the wire, so the light
    // simply held its last state across the gap.

    /// The window is four frames starting at the second cycle's onset frame:
    /// the ON edge is admitted, dropped, and the wire comes back 0.08 s later
    /// showing the rise that the ledger has already stopped tracking.
    private func strobeAcrossAReconnect(ignoringDrops: Bool) -> [Emission] {
        let model = WireModel()
        model.ledgerIgnoresDrops = ignoringDrops
        model.dropWindow = 17..<21
        modelStrobeFreeRun(model, cycles: 5, speed: 100, duty: 0.5, peak: 1.0, minBri: 0.0)
        return model.wire
    }

    private func partyAcrossAReconnect(ignoringDrops: Bool) -> [Emission] {
        let model = WireModel()
        model.ledgerIgnoresDrops = ignoringDrops
        model.dropWindow = 17..<21
        modelPartyFreeRun(model, cycles: 5, speed: 100, smoothness: 0.20,
                          peak: 0.90, minBri: 0.05, startIndex: 0)
        return model.wire
    }

    private func stormAcrossAReconnect(ignoringDrops: Bool) -> [Emission] {
        let model = WireModel()
        model.ledgerIgnoresDrops = ignoringDrops
        model.dropWindow = 26..<28
        modelStorm(model, strikes: 5, frequency: 1.0, flashIntensity: 0.90,
                   minBri: 0.05, flashFrames: 3, afterglowFrames: 1)
        return model.wire
    }

    func testStrobeSurvivesAReconnectMidHold() {
        let shipped = strobeAcrossAReconnect(ignoringDrops: true)
        XCTAssertLessThan(minimumGap(realizedOnsets(shipped)) ?? .infinity,
                          FS.minOnsetLedgerPeriod,
                          "B-1 must be SHOWN on the ledger that ignores dropped sends")

        let fixed = strobeAcrossAReconnect(ignoringDrops: false)
        assertOnsetsRespectTheFloor(realizedOnsets(fixed), label: "strobe across a reconnect",
                                    atLeast: 3)
    }

    func testPartySurvivesAReconnectMidHold() {
        let shipped = partyAcrossAReconnect(ignoringDrops: true)
        XCTAssertLessThan(minimumGap(realizedOnsets(shipped)) ?? .infinity,
                          FS.minOnsetLedgerPeriod,
                          "B-1 must be SHOWN on the ledger that ignores dropped sends")

        let fixed = partyAcrossAReconnect(ignoringDrops: false)
        assertOnsetsRespectTheFloor(realizedOnsets(fixed), label: "party across a reconnect",
                                    atLeast: 3)
    }

    func testThunderstormSurvivesAReconnectMidStrike() {
        let shipped = stormAcrossAReconnect(ignoringDrops: true)
        XCTAssertLessThan(minimumGap(realizedOnsets(shipped)) ?? .infinity,
                          FS.minOnsetLedgerPeriod,
                          "B-1 must be SHOWN on the ledger that ignores dropped sends")

        let fixed = stormAcrossAReconnect(ignoringDrops: false)
        assertOnsetsRespectTheFloor(realizedOnsets(fixed), label: "storm across a reconnect",
                                    atLeast: 3)
    }

    func testEveryLoopSurvivesEveryDropWindowPosition() {
        // The window above is one position. Sweep every start frame across two
        // whole cycles and every length up to a whole cycle, on all three loops.
        // The reserve/commit ledger has to hold for all of them.
        //
        // Fifth review round: the non-vacuity bar is 3 onsets, not 1. "One onset"
        // satisfies every spacing rule there is by having no pair to measure, so
        // a sweep that only demanded one was a sweep that could not fail on a
        // gate that had stopped admitting anything. The storm arm also varies its
        // ambient and flash chromaticities, because a saturated-red endpoint on
        // either side of the outage is the case the red-flash rule governs and
        // the shipped palette (blue ambient, white flash) never exercises.
        for start in 0..<40 {
            for length in 1...17 {
                let window = start..<(start + length)

                let strobe = WireModel()
                strobe.dropWindow = window
                modelStrobeFreeRun(strobe, cycles: 6, speed: 100, duty: 0.5,
                                   peak: 1.0, minBri: 0.0)
                assertOnsetsRespectTheFloor(realizedOnsets(strobe.wire),
                                            label: "strobe drop \(window)", atLeast: 3)

                let party = WireModel()
                party.dropWindow = window
                modelPartyFreeRun(party, cycles: 6, speed: 100, smoothness: 0.20,
                                  peak: 0.90, minBri: 0.05, startIndex: 0)
                assertOnsetsRespectTheFloor(realizedOnsets(party.wire),
                                            label: "party drop \(window)", atLeast: 3)

                let palette = Self.stormPalettes[(start + length) % Self.stormPalettes.count]
                let storm = WireModel()
                storm.dropWindow = window
                modelStorm(storm, strikes: 6, frequency: 1.0, flashIntensity: 0.90,
                           minBri: 0.05, flashFrames: 3, afterglowFrames: 1,
                           ambient: palette.ambient, flash: palette.flash)
                assertOnsetsRespectTheFloor(realizedOnsets(storm.wire),
                                            label: "storm \(palette.name) drop \(window)",
                                            atLeast: 3)
            }
        }
    }

    func testSeededRampsSurviveEveryDropWindowPosition() {
        // The drop-window sweep above steps a plan's own edges past an outage.
        // A RAMP is the other shape, and it is the one the trough exists for: a
        // chromaticity-and-level drag climbs by less per frame than any rule can
        // see and is a flash only cumulatively, so a gate that loses the true
        // trough across a dropped frame under-measures every rise after it and
        // never finds out. Seeded ramps × every drop position, graded by the
        // independent viewer, with the pre-fix gate run on the same scenarios so
        // the pin cannot be vacuous.
        var rng = SeededGenerator(seed: 0x9A5F_1D07)
        var scenarios = 0
        var legacyViolations = 0
        var legacyWorstFrames = Double.infinity
        var fixedWorstFrames = Double.infinity

        var ramps = 0
        var draws = 0
        while ramps < 12, draws < 200 {
            draws += 1
            let from = Self.partyPalette[Int.random(in: 0..<Self.partyPalette.count, using: &rng)]
            let to = Self.partyPalette[Int.random(in: 0..<Self.partyPalette.count, using: &rng)]
            let briFrom = Double.random(in: 0.30...1.0, using: &rng)
            let briTo = Double.random(in: 0.30...1.0, using: &rng)
            let span = Int.random(in: 20...45, using: &rng)

            let baseline = WireModel()
            modelRamp(baseline, from: from, to: to, briFrom: briFrom, briTo: briTo,
                      frames: span, cycles: 6)
            let baselineOnsets = realizedOnsets(baseline.wire).count
            // A drawn ramp that does not flash at all (two palette entries a
            // long way apart in hue but not in luminance, at a low drive) is not
            // a scenario — it is an absence of one. Draw again rather than sweep
            // a run whose spacing assertion has nothing to measure.
            guard baselineOnsets >= 5 else { continue }
            ramps += 1

            for start in stride(from: 0, to: 6 * span, by: 7) {
                for length in [1, 3, 7, 17] {
                    scenarios += 1
                    let window = start..<(start + length)

                    let fixed = WireModel()
                    fixed.dropWindow = window
                    modelRamp(fixed, from: from, to: to, briFrom: briFrom, briTo: briTo,
                              frames: span, cycles: 6)
                    let onsets = realizedOnsets(fixed.wire)
                    // An outage FREEZES the light, so it genuinely removes
                    // onsets from the wire: a window of `length` frames can hide
                    // at most one onset per 17 frames of it, plus the one it
                    // straddles. The bar is what is left after that — never a
                    // number that lets "the gate stopped admitting anything"
                    // pass as a spacing success.
                    let hidden = length / FS.minCycleFrames() + 1
                    assertOnsetsRespectTheFloor(
                        onsets,
                        label: "ramp \(from)→\(to) bri \(briFrom)→\(briTo) span \(span) drop \(window)",
                        atLeast: max(1, min(3, baselineOnsets - hidden)))
                    if let gap = minimumGap(onsets) {
                        fixedWorstFrames = min(fixedWorstFrames, gap / fd)
                    }

                    let legacy = WireModel()
                    legacy.gate = LegacyForgetOnDropGate()
                    legacy.dropWindow = window
                    modelRamp(legacy, from: from, to: to, briFrom: briFrom, briTo: briTo,
                              frames: span, cycles: 6)
                    if let gap = minimumGap(realizedOnsets(legacy.wire)),
                       gap < FS.minOnsetLedgerPeriod - FS.onsetComparisonTolerance {
                        legacyViolations += 1
                        legacyWorstFrames = min(legacyWorstFrames, gap / fd)
                    }
                }
            }
        }

        XCTAssertEqual(ramps, 12, "the seeded draw must find 12 ramps that actually flash")
        // Measured (fifth review round): 1380 scenarios; forget-on-drop
        // violated 115 of them, worst realized spacing 1 frame; restore-on-drop
        // worst 17 frames — the floor exactly, on every scenario.
        XCTAssertEqual(scenarios, 1380, "the sweep's size is part of what it proves")
        XCTAssertGreaterThanOrEqual(legacyViolations, 115,
                                    "the forget-on-drop gate must FAIL this sweep, or it pins nothing")
        XCTAssertLessThanOrEqual(legacyWorstFrames, 1.5,
                                 "and it must fail HARD — a one-frame realized pair")
        XCTAssertGreaterThanOrEqual(fixedWorstFrames,
                                    Double(FS.minCycleFrames()) - 1e-6,
                                    "\(scenarios) scenarios, worst realized spacing \(fixedWorstFrames) frames")
    }

    func testAPartyTintDragAcrossADroppedSendNeverRealizesAFastRedFlash() {
        // BLOCKER B1, measured. Party beat-locked at brightness 100 while a tint
        // drag walks the colour green → red. Under forget-on-drop, a refused send
        // made the wire "unknown" and the next refusal held BLACK AT THE
        // REQUESTED CHROMATICITY: against the red frame the bridge was still
        // showing, that black is a WCAG red flash nothing stamped, and it zeroed
        // the viewer's trough, so the very next admitted red frame was a
        // full-scale rise ONE frame later.
        var scenarios = 0
        var legacyViolations = 0
        var legacyWorstFrames = Double.infinity
        var fixedWorstFrames = Double.infinity

        for start in 0..<100 {
            let window = start..<(start + 5)
            scenarios += 1

            let fixed = WireModel()
            fixed.dropWindow = window
            modelPartyTintDrag(fixed, cycles: 7, peak: 1.0, minBri: 0.05)
            let onsets = realizedOnsets(fixed.wire)
            assertOnsetsRespectTheFloor(onsets, label: "party tint drag, drop \(window)",
                                        atLeast: 3)
            if let gap = minimumGap(onsets) { fixedWorstFrames = min(fixedWorstFrames, gap / fd) }

            let legacy = WireModel()
            legacy.gate = LegacyForgetOnDropGate()
            legacy.dropWindow = window
            modelPartyTintDrag(legacy, cycles: 7, peak: 1.0, minBri: 0.05)
            if let gap = minimumGap(realizedOnsets(legacy.wire)),
               gap < FS.minOnsetLedgerPeriod - FS.onsetComparisonTolerance {
                legacyViolations += 1
                legacyWorstFrames = min(legacyWorstFrames, gap / fd)
            }
        }

        // Measured: 100 scenarios; forget-on-drop violated 11, worst realized
        // spacing ONE frame (the black-at-requested-red hold, then the red frame
        // behind it); restore-on-drop worst 17 frames.
        XCTAssertGreaterThanOrEqual(legacyViolations, 11,
                                    "B1 must be SHOWN on the forget-on-drop gate")
        XCTAssertLessThanOrEqual(legacyWorstFrames, 1.5,
                                 "B1's worst case is a ONE-frame realized pair")
        XCTAssertGreaterThanOrEqual(fixedWorstFrames, Double(FS.minCycleFrames()) - 1e-6,
                                    "\(scenarios) scenarios, worst realized spacing \(fixedWorstFrames) frames")
    }

    func testABlueToCyanRampWithOneDroppedFrameKeepsItsTrueTrough() {
        // BLOCKER B2, measured, at the exact shape the reviewer's sweep found:
        // blue (0.15, 0.06) → cyan (0.16, 0.23) at brightness 100, one dropped
        // frame. Forget-on-drop re-based the trough UPWARD to the frame it
        // recorded on the cold path, discarding the pre-drop floor, so the climb
        // that followed was measured from too high and the viewer saw onsets
        // three frames apart.
        let blue = (x: 0.1500, y: 0.0600)
        let cyan = (x: 0.1600, y: 0.2300)
        var legacyViolations = 0
        var legacyWorstFrames = Double.infinity
        var fixedWorstFrames = Double.infinity

        for drop in 20..<140 {
            let window = drop..<(drop + 1)

            let fixed = WireModel()
            fixed.dropWindow = window
            modelRamp(fixed, from: blue, to: cyan, briFrom: 1.0, briTo: 1.0,
                      frames: 40, cycles: 6)
            let onsets = realizedOnsets(fixed.wire)
            assertOnsetsRespectTheFloor(onsets, label: "blue→cyan ramp, drop at \(drop)",
                                        atLeast: 3)
            if let gap = minimumGap(onsets) { fixedWorstFrames = min(fixedWorstFrames, gap / fd) }

            let legacy = WireModel()
            legacy.gate = LegacyForgetOnDropGate()
            legacy.dropWindow = window
            modelRamp(legacy, from: blue, to: cyan, briFrom: 1.0, briTo: 1.0,
                      frames: 40, cycles: 6)
            if let gap = minimumGap(realizedOnsets(legacy.wire)),
               gap < FS.minOnsetLedgerPeriod - FS.onsetComparisonTolerance {
                legacyViolations += 1
                legacyWorstFrames = min(legacyWorstFrames, gap / fd)
            }
        }

        // Measured: 120 single-frame drops; forget-on-drop violated 13 of them,
        // worst realized spacing 10 frames; restore-on-drop worst 17 frames.
        XCTAssertGreaterThanOrEqual(legacyViolations, 13,
                                    "B2 must be SHOWN on the forget-on-drop gate")
        XCTAssertLessThan(legacyWorstFrames, Double(FS.minCycleFrames()),
                          "ONE dropped frame is enough to realize a short pair without the fix")
        XCTAssertGreaterThanOrEqual(fixedWorstFrames, Double(FS.minCycleFrames()) - 1e-6,
                                    "worst realized spacing \(fixedWorstFrames) frames")
    }

    func testInCatalogThunderstormWithARedAmbientSurvivesASingleDroppedFrame() {
        // The reviewer's in-catalog reproduction: flash_intensity 20,
        // min_brightness 1, frequency 100, flash_length 1, afterglow 0, ambient
        // colour saturated red, flash colour white. The strike carries 0.030 of
        // maximum luminance — UNDER the general threshold — so under
        // forget-on-drop the cold path emitted it unconditionally and unstamped,
        // and the red ambient frame behind it was then stamped as a FIRST onset:
        // two red flashes one frame apart, from one dropped ambient frame.
        let red = (x: 0.6400, y: 0.3300)
        let white = (x: 0.3127, y: 0.3290)
        var legacyViolations = 0
        var legacyWorstFrames = Double.infinity
        var fixedWorstFrames = Double.infinity
        var scenarios = 0

        for drop in 0..<60 {
            scenarios += 1
            let window = drop..<(drop + 1)

            let fixed = WireModel()
            fixed.dropWindow = window
            modelStorm(fixed, strikes: 8, frequency: 1.0, flashIntensity: 0.20,
                       minBri: 0.01, flashFrames: 1, afterglowFrames: 0,
                       ambient: red, flash: white)
            let onsets = realizedOnsets(fixed.wire)
            assertOnsetsRespectTheFloor(onsets, label: "red-ambient storm, drop at \(drop)",
                                        atLeast: 3)
            if let gap = minimumGap(onsets) { fixedWorstFrames = min(fixedWorstFrames, gap / fd) }

            let legacy = WireModel()
            legacy.gate = LegacyForgetOnDropGate()
            legacy.dropWindow = window
            modelStorm(legacy, strikes: 8, frequency: 1.0, flashIntensity: 0.20,
                       minBri: 0.01, flashFrames: 1, afterglowFrames: 0,
                       ambient: red, flash: white)
            if let gap = minimumGap(realizedOnsets(legacy.wire)),
               gap < FS.minOnsetLedgerPeriod - FS.onsetComparisonTolerance {
                legacyViolations += 1
                legacyWorstFrames = min(legacyWorstFrames, gap / fd)
            }
        }

        // Measured: 60 single-frame drop positions; forget-on-drop violated 36
        // of them, worst realized spacing ONE frame; restore-on-drop worst 17.
        XCTAssertGreaterThanOrEqual(legacyViolations, 36,
                                    "the in-catalog storm reproduction must FAIL on the forget-on-drop gate")
        XCTAssertLessThanOrEqual(legacyWorstFrames, 1.5,
                                 "a single dropped ambient frame realized two red flashes ONE frame apart")
        XCTAssertGreaterThanOrEqual(fixedWorstFrames, Double(FS.minCycleFrames()) - 1e-6,
                                    "\(scenarios) scenarios, worst realized spacing \(fixedWorstFrames) frames")
    }

    func testTheStormSkipAndBeatWaitBranchesStreamRealFramesAndStaySafe() {
        // Both branches emit ambient frames onto the wire; neither used to be
        // modelled through the gate at all — the sweeps that covered them did
        // frame ARITHMETIC and never put a frame anywhere.
        let model = WireModel()
        let rendered = modelStorm(model, strikes: 24, frequency: 1.0, flashIntensity: 0.90,
                                  minBri: 0.05, flashFrames: 3, afterglowFrames: 1,
                                  beatWaitFrames: 11, skipEvery: 3)
        XCTAssertEqual(rendered, 16, "one opportunity in three is skipped")
        let onsets = realizedOnsets(model.wire)
        assertOnsetsRespectTheFloor(onsets, label: "storm with beat waits and skips",
                                    atLeast: rendered)
        XCTAssertEqual(onsets.count, rendered,
                       "one realized onset per rendered strike — no skip and no wait adds one")

        // A skip only ever makes the next spacing LONGER: the opportunity after
        // a skipped one carries the credit the skip accumulated.
        XCTAssertGreaterThan(minimumGap(onsets) ?? 0, FS.minOnsetLedgerPeriod - 1e-9)
    }

    // ══════════════════════════════════════════════════════════════
    // MARK: - BeatClock audio ingest (L3)
    // ══════════════════════════════════════════════════════════════

    @MainActor
    func testAudioIngestClampsTheEstimateIntoTheLegalTempoWindow() {
        // `ingest` assigned `estimate.bpm` raw while `tap()` and `driveFromTrack`
        // both hold themselves to 20…300. Downstream, `BeatMath.cycleIndex`
        // evaluates `Int(floor(...))` on a position derived from `60 / bpm`: a
        // near-zero estimate makes that position enormous and the conversion
        // TRAPS, on the render path, once per frame.
        let fast = BeatClock()
        fast.clear()
        fast.ingest(estimate: TempoEstimate(bpm: 100_000, confidence: 1.0, lastBeatOffset: 0),
                    endTime: 10.0)
        XCTAssertEqual(fast.bpm, 300)

        let slow = BeatClock()
        slow.clear()
        slow.ingest(estimate: TempoEstimate(bpm: 0.0001, confidence: 1.0, lastBeatOffset: 0),
                    endTime: 10.0)
        XCTAssertEqual(slow.bpm, 20)

        // The follow-up path (already locked to audio) clamps too.
        let follow = BeatClock()
        follow.clear()
        follow.ingest(estimate: TempoEstimate(bpm: 128, confidence: 1.0, lastBeatOffset: 0),
                      endTime: 10.0)
        XCTAssertEqual(follow.bpm, 128)
        follow.ingest(estimate: TempoEstimate(bpm: 1e9, confidence: 1.0, lastBeatOffset: 0),
                      endTime: 10.5)
        XCTAssertEqual(follow.bpm, 300)

        // And the value the loops actually consume can no longer trap.
        let snap = BeatSnapshot(bpm: follow.bpm, beatEpoch: 0)
        XCTAssertEqual(BeatMath.cycleIndex(at: 1.0, snapshot: snap, beatsPerCycle: 1), 5)
        follow.clear()
    }

    // ══════════════════════════════════════════════════════════════
    // MARK: - Simulation helpers (pure; no clocks, no sleeps)
    // ══════════════════════════════════════════════════════════════

    /// One frame as it reached the wire, with the grid time it reached it at.
    struct Emission: Equatable {
        let time: Double
        let frame: BeatMath.FlashSafety.WireFrame
    }

    /// Pure mirror of `UnifiedOrchestrator.emitGatedFrame` / `emitOnsetFrame` —
    /// the ONLY way any model below puts a frame on the wire, exactly as those
    /// two are now the only way the orchestrator does. One 20 ms frame per call,
    /// held or not, DELIVERED or not.
    ///
    /// The transport is modelled, not assumed. `send(channels:)` is
    /// fire-and-forget and silently drops every frame while the DTLS connection
    /// is re-establishing, so "the frame the gate decided on" and "the frame on
    /// the wire" are two different lists, and only the second one is what a
    /// viewer sees. `dropWindow` is that reconnect: frames whose index falls in
    /// it are refused by the transport and never appear in `wire`.
    final class WireModel {
        /// The production gate by default; the reconnect tests swap in
        /// `LegacyForgetOnDropGate` to show what the fix replaced.
        var gate: any ModelledOnsetGate = ProductionOnsetGate()
        /// The loop's own cadence. The uniform flash loops sleep one 20 ms
        /// Entertainment quantum inside `emitGatedFrame`; the COMPOSITION loop
        /// keeps its own 40 ms (25 fps) sleep and gates without sleeping, so its
        /// model has to advance the clock at 40 ms or it would grade a run twice
        /// as fast as the one that ships. Default unchanged, so every existing
        /// model below is untouched.
        var fd = BeatMath.FlashSafety.entertainmentFrameDuration
        private(set) var frame = 0
        private(set) var wire: [Emission] = []
        private(set) var dropped = 0

        /// Frame indices the transport refuses (a reconnect).
        var dropWindow: Range<Int>?

        /// Several outages in one run — what a seeded churn needs, because a
        /// single window over a few thousand frames tests one position.
        var dropWindows: [Range<Int>] = []

        /// The PRE-FIX ledger: it commits every reservation as delivered, so it
        /// runs ahead of the wire across a drop exactly as the shipped one did
        /// (blocker B-1). Only the reconnect tests set this, and only to show
        /// the defect they close.
        var ledgerIgnoresDrops = false

        var time: Double { Double(frame) * fd }
        private var transportAccepts: Bool {
            if let window = dropWindow, window.contains(frame) { return false }
            return !dropWindows.contains { $0.contains(frame) }
        }

        /// `emitGatedFrame`. Returns true only if the REQUESTED frame actually
        /// reached the wire — `landedOnWire`, not `wasAdmitted`.
        @discardableResult
        func emit(_ brightness: Double, x: Double = 0.3127, y: Double = 0.3290) -> Bool {
            let decided = gate.reserve(
                BeatMath.FlashSafety.WireFrame(x: x, y: y, brightness: brightness), at: time)
            let delivered = transportAccepts
            // A dropped frame never reaches the bridge, so it never appears on
            // the wire AND the bridge goes on showing the last frame that did:
            // the viewer below reads `wire` as a held level across the gap,
            // which is exactly what a fixture does during a DTLS reconnect.
            if delivered {
                wire.append(Emission(time: time, frame: decided.onWire))
            } else {
                dropped += 1
            }
            gate.settle(delivered: ledgerIgnoresDrops || delivered, at: time)
            frame += 1
            return decided.admitted && (ledgerIgnoresDrops || delivered)
        }

        /// `emitOnsetFrame`: hold until the requested frame itself lands. The
        /// production helper ends only on cancellation or a dead session; the
        /// model needs a finite bound only so a broken gate fails the test
        /// instead of hanging it.
        func emitOnset(_ brightness: Double, x: Double = 0.3127, y: Double = 0.3290) {
            for _ in 0..<512 {
                if emit(brightness, x: x, y: y) { return }
            }
            XCTFail("emitOnsetFrame never landed — the gate must admit within a bounded wait")
        }

        /// The last PER-CHANNEL frame the transport accepted — what a `.hold`
        /// re-sends. Mirrors `lastEmitted` in `runCompositionEntertainment`, and
        /// for the same reason: only a delivered frame is what the bridge shows.
        private var lastEmittedChannels: [(x: Double, y: Double, brightness: Double)]?

        /// Pure mirror of `UnifiedOrchestrator.emitGatedCompositionFrame` — one
        /// per-channel composition frame, reserve → send → commit, no sleep.
        ///
        /// What lands in `wire` is the INDEPENDENTLY reduced field frame of the
        /// channels that reached the transport, so `realizedOnsets` grades what a
        /// viewer standing in the room received. Production's own
        /// `FlashSafety.fieldFrame` is used for the RESERVE (that is the code
        /// under test) and never for the measurement.
        @discardableResult
        func emitComposition(_ channels: [(x: Double, y: Double, brightness: Double)]) -> Bool {
            let decided = gate.reserve(
                BeatMath.FlashSafety.fieldFrame(channels: channels), at: time)
            let onWire: [(x: Double, y: Double, brightness: Double)]
            if decided.admitted {
                onWire = channels
            } else if let lastEmittedChannels {
                onWire = lastEmittedChannels
            } else {
                // COLD refusal: the ledger's OWN hold frame — black at the last
                // KNOWN chromaticity — on every channel (D-3), exactly as
                // production's `case .hold(let held)` branch spreads it.
                onWire = channels.map { _ in
                    (x: decided.onWire.x, y: decided.onWire.y, brightness: decided.onWire.brightness)
                }
            }
            let delivered = transportAccepts
            if delivered {
                wire.append(Emission(time: time, frame: viewerFieldFrame(onWire)))
                lastEmittedChannels = onWire
            } else {
                dropped += 1
            }
            gate.settle(delivered: ledgerIgnoresDrops || delivered, at: time)
            frame += 1
            return decided.admitted && (ledgerIgnoresDrops || delivered)
        }

        /// **The composition loop as it SHIPPED before this slice** — straight to
        /// the transport, no ledger, delivery answer discarded. Kept for the same
        /// reason `LegacyForgetOnDropGate` is: a fix whose regression test cannot
        /// fail on the code it replaced is a fix nobody can check.
        func emitUngatedComposition(_ channels: [(x: Double, y: Double, brightness: Double)]) {
            if transportAccepts {
                wire.append(Emission(time: time, frame: viewerFieldFrame(channels)))
            } else {
                dropped += 1
            }
            frame += 1
        }

        /// Pure mirror of the REST scheduler's gate (review round, D-1): reserve
        /// on the field frame; a REFUSAL writes NOTHING and rolls the reservation
        /// back (the lights keep showing the last delivered frame, which is what
        /// `.hold` means on a transport with state); an admission is "sent" and
        /// committed on the transport's word. `fd` is the scheduler's 120 ms tick.
        @discardableResult
        func emitRESTComposition(_ channels: [(x: Double, y: Double, brightness: Double)]) -> Bool {
            let decided = gate.reserve(
                BeatMath.FlashSafety.fieldFrame(channels: channels), at: time)
            guard decided.admitted else {
                gate.settle(delivered: false, at: time)
                frame += 1
                return false
            }
            let delivered = transportAccepts
            if delivered {
                wire.append(Emission(time: time, frame: viewerFieldFrame(channels)))
                lastEmittedChannels = channels
            } else {
                dropped += 1
            }
            gate.settle(delivered: ledgerIgnoresDrops || delivered, at: time)
            frame += 1
            return delivered
        }

        /// **The REST scheduler as it SHIPPED** — 120 ms ticks straight into the
        /// mailbox, no ledger.
        func emitUngatedRESTComposition(_ channels: [(x: Double, y: Double, brightness: Double)]) {
            if transportAccepts {
                wire.append(Emission(time: time, frame: viewerFieldFrame(channels)))
            } else {
                dropped += 1
            }
            frame += 1
        }

        /// The bridge restores its OWN light state (a session stop, an explicit
        /// group-off): a black frame the viewer sees and the ledger did not put
        /// there. Advances the clock by one frame.
        func bridgeReverted() {
            wire.append(Emission(time: time, frame: BeatMath.FlashSafety.WireFrame(
                x: 0.3127, y: 0.3290, brightness: 0)))
            frame += 1
        }

        /// What the production stop paths now tell the ledger (D-2). The
        /// loop-local held frame dies with the loop task on a restart — a new
        /// loop instance starts with `lastEmitted == nil` — so it is cleared
        /// here too; the ledger's own memory is what survives.
        func forgetWire() {
            gate.forgetWire()
            lastEmittedChannels = nil
        }

        /// Advance the clock without emitting — the teardown / restart gap.
        func idle(_ frames: Int = 1) { frame += frames }
    }

    // ── The viewer's measurement, written from the DEFINITION ──
    //
    // Nothing below calls `WireFrame.relativeLuminance`, `WireFrame.chromaDistance`,
    // `OnsetGate`, or any `FlashSafety` constant — the CIE xy distance is
    // re-derived here too (fifth review round), so the measurement shares no
    // line of code with the thing it measures. It transcribes the model the
    // rules are stated in —
    // CIE xy → linear sRGB at full drive, the sRGB luminance coefficients, and
    // CIE L* → Y for the dimming level — and the thresholds as bare literals. If
    // the production luminance model and this one ever disagree, or if any
    // mechanism realizes two onsets inside 0.34 s, these find it, and they find
    // it on the pre-fix models too, which never consult the frame gate at all.

    /// Linear sRGB drive for a chromaticity, normalized so the largest channel
    /// is 1.0 — the colour as a fixture at full drive renders it.
    private func viewerDrive(_ f: BeatMath.FlashSafety.WireFrame)
        -> (r: Double, g: Double, b: Double) {
        guard f.y > 0 else { return (0, 0, 0) }
        let bigX = f.x / f.y
        let bigZ = (1.0 - f.x - f.y) / f.y
        var r =  3.2404542 * bigX - 1.5371385 - 0.4985314 * bigZ
        var g = -0.9692660 * bigX + 1.8760108 + 0.0415560 * bigZ
        var b =  0.0556434 * bigX - 0.2040259 + 1.0572252 * bigZ
        r = max(r, 0); g = max(g, 0); b = max(b, 0)
        let peak = max(r, max(g, b))
        guard peak > 0 else { return (0, 0, 0) }
        return (r / peak, g / peak, b / peak)
    }

    /// Relative luminance of an emitted frame, 0…1 of maximum.
    private func viewerLuminance(_ f: BeatMath.FlashSafety.WireFrame) -> Double {
        let c = viewerDrive(f)
        let chroma = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
        guard f.brightness > 0 else { return 0 }
        let lStar = (100.0 * min(max(f.brightness, 0), 1) + 16.0) / 116.0
        return chroma * min(1, max(0, lStar * lStar * lStar))
    }

    private func viewerRedFraction(_ f: BeatMath.FlashSafety.WireFrame) -> Double {
        let c = viewerDrive(f)
        let sum = c.r + c.g + c.b
        return sum > 0 ? c.r / sum : 0
    }

    /// Onsets a VIEWER would see, re-derived from the DELIVERED frames alone:
    ///  • a climb of ≥ 0.10 in relative luminance above the lowest luminance
    ///    since the previous onset (WCAG general flash), or
    ///  • a chromaticity step to or from saturated red with a luminance change
    ///    of ≥ 0.02 in either direction (WCAG red flash).
    private func onsetsOnTheWire(_ wire: [Emission]) -> (all: [Double], red: [Double]) {
        guard let first = wire.first else { return ([], []) }
        let epsilon = 1e-9
        var all: [Double] = []
        var red: [Double] = []
        var trough = viewerLuminance(first.frame)
        var last = first.frame
        for e in wire.dropFirst() {
            let luminance = viewerLuminance(e.frame)
            let rise = luminance - trough >= 0.10 - epsilon
            let dx = e.frame.x - last.x, dy = e.frame.y - last.y
            let chromaStep = (dx * dx + dy * dy).squareRoot()
            let redFlash = chromaStep > 0.02
                && (viewerRedFraction(e.frame) >= 0.8 - epsilon
                    || viewerRedFraction(last) >= 0.8 - epsilon)
                && abs(luminance - viewerLuminance(last)) >= 0.02 - epsilon
            if rise || redFlash {
                all.append(e.time)
                if redFlash, !rise { red.append(e.time) }
                trough = luminance
            } else {
                trough = min(trough, luminance)
            }
            last = e.frame
        }
        return (all, red)
    }

    private func realizedOnsets(_ wire: [Emission]) -> [Double] { onsetsOnTheWire(wire).all }
    private func realizedRedFlashes(_ wire: [Emission]) -> [Double] { onsetsOnTheWire(wire).red }

    // ── Loop models: every frame through `WireModel`, nothing beside it ──

    /// `runStrobeEntertainment`'s free-run branch.
    private func modelStrobeFreeRun(_ w: WireModel, cycles: Int, speed: Double,
                                    duty: Double, peak: Double, minBri: Double,
                                    x: Double = 0.3127, y: Double = 0.3290) {
        for _ in 0..<cycles {
            let plan = FS.StrobePlan.make(speed: speed, dutyCycle: duty)
            w.emitOnset(peak, x: x, y: y)
            for _ in 1..<max(plan.onFrames, 1) { w.emit(peak, x: x, y: y) }
            w.emitOnset(minBri, x: x, y: y)
            for _ in 1..<max(plan.offFrames, 1) { w.emit(minBri, x: x, y: y) }
        }
    }

    /// `runPartyEntertainment`'s free-run branch.
    private func modelPartyFreeRun(_ w: WireModel, cycles: Int, speed: Double,
                                   smoothness: Double, peak: Double, minBri: Double,
                                   startIndex: Int) {
        for c in 0..<cycles {
            let plan = FS.PartyPlan.make(speed: speed, smoothness: smoothness)
            let color = Self.partyPalette[(startIndex + c) % Self.partyPalette.count]
            w.emitOnset(peak, x: color.x, y: color.y)
            for _ in 1..<max(plan.holdFrames, 1) { w.emit(peak, x: color.x, y: color.y) }
            for i in 0..<plan.fadeFrames {
                let t = Double(i) / Double(plan.fadeFrames)
                w.emit(peak + (minBri - peak) * t, x: color.x, y: color.y)
            }
        }
    }

    /// `runThunderstormEntertainment`, budget and all — including the two
    /// branches that render ambient frames without rendering a strike, which the
    /// arithmetic-only sweeps could not see because they never emitted anything:
    ///
    ///  • the **beat-alignment wait** (`beatWaitFrames`), which streams ambient
    ///    until the next cycle boundary — real frames on the real wire, and the
    ///    place the storm spends most of its time under a slow lock; and
    ///  • the **`strikeChance` skip** (`skipEvery`), which falls through WITHOUT
    ///    touching the budget, so its credit carries into the next opportunity.
    ///
    /// `opportunities` counts strike OPPORTUNITIES; `strikes` (the return value)
    /// counts the ones that actually rendered.
    @discardableResult
    private func modelStorm(_ w: WireModel, strikes: Int, frequency: Double,
                            flashIntensity: Double, minBri: Double,
                            flashFrames: Int, afterglowFrames: Int,
                            beatWaitFrames: Int = 0, skipEvery: Int? = nil,
                            ambient: (x: Double, y: Double) = FlashSafetyTests.stormAmbient,
                            flash: (x: Double, y: Double) = FlashSafetyTests.stormFlash) -> Int {
        var budget = FS.ThunderstormPlan.Budget()
        var rendered = 0
        for opportunity in 0..<strikes {
            for _ in 0..<budget.gapFrames(frequency: frequency) {
                w.emit(minBri, x: ambient.x, y: ambient.y)
                budget.noteAmbient()
            }
            for _ in 0..<max(beatWaitFrames, 0) {
                w.emit(minBri, x: ambient.x, y: ambient.y)
                budget.noteAmbient()
            }
            if let skipEvery, skipEvery > 0, opportunity % skipEvery == skipEvery - 1 {
                continue    // the strike is skipped; the budget keeps its credit
            }
            var landed = false
            var guardCount = 0
            while !landed {
                landed = w.emit(flashIntensity, x: flash.x, y: flash.y)
                if !landed { budget.noteAmbient() }
                guardCount += 1
                if guardCount > 512 { XCTFail("the strike never landed"); return rendered }
            }
            for _ in 1..<max(flashFrames, 1) {
                w.emit(flashIntensity, x: flash.x, y: flash.y)
            }
            for _ in 0..<afterglowFrames {
                w.emit(max(flashIntensity * 0.4, minBri), x: flash.x, y: flash.y)
            }
            budget.noteStrike(flashFrames: flashFrames, afterglowFrames: afterglowFrames)
            rendered += 1
        }
        return rendered
    }

    static let partyPalette: [(x: Double, y: Double)] = [
        (0.6400, 0.3300), (0.1500, 0.0600), (0.1700, 0.7000), (0.3200, 0.1500),
        (0.4500, 0.4100), (0.5400, 0.2300), (0.1600, 0.2300), (0.5600, 0.4000),
    ]
    static let stormAmbient = (x: 0.1548, y: 0.1220)
    static let stormFlash = (x: 0.3127, y: 0.3290)

    /// Ambient/flash chromaticity pairs the storm is swept over. The shipped
    /// pair never puts saturated red on either side of an outage, which is the
    /// only case the WCAG red-flash rule governs — and the case where a flash
    /// UNDER the general threshold is still a flash.
    static let stormPalettes: [(name: String, ambient: (x: Double, y: Double),
                                flash: (x: Double, y: Double))] = [
        ("blue/white", stormAmbient, stormFlash),
        ("red/white", (x: 0.6400, y: 0.3300), stormFlash),
        ("blue/red", stormAmbient, (x: 0.6400, y: 0.3300)),
    ]

    /// A live drag: chromaticity AND level ramp together, one step per frame,
    /// reversing each cycle. Nothing here waits for the gate — a finger on a
    /// slider does not — so every refusal is a held frame the viewer still sees.
    private func modelRamp(_ w: WireModel, from: (x: Double, y: Double),
                           to: (x: Double, y: Double),
                           briFrom: Double, briTo: Double, frames: Int, cycles: Int) {
        let span = max(frames, 2)
        for c in 0..<max(cycles, 1) {
            for i in 0..<span {
                let t = Double(i) / Double(span - 1)
                let u = c % 2 == 0 ? t : 1 - t
                w.emit(briFrom + (briTo - briFrom) * u,
                       x: from.x + (to.x - from.x) * u,
                       y: from.y + (to.y - from.y) * u)
            }
        }
    }

    /// Party beat-locked at the realizable ceiling while a tint drag walks the
    /// colour green → red across the run. The colour is a function of the wire
    /// frame, not of the cycle: a finger keeps moving while the gate holds.
    private func modelPartyTintDrag(_ w: WireModel, cycles: Int,
                                    peak: Double, minBri: Double) {
        let green = (x: 0.1700, y: 0.7000)
        let red = (x: 0.6400, y: 0.3300)
        let cycleFrames = FS.minCycleFrames()
        let total = max(cycles * cycleFrames - 1, 1)
        func tint() -> (x: Double, y: Double) {
            let u = min(1.0, Double(w.frame) / Double(total))
            return (x: green.x + (red.x - green.x) * u, y: green.y + (red.y - green.y) * u)
        }
        for _ in 0..<cycles {
            var c = tint()
            w.emitOnset(peak, x: c.x, y: c.y)
            let hold = max(cycleFrames / 2, 1)
            for _ in 1..<hold {
                c = tint()
                w.emit(peak, x: c.x, y: c.y)
            }
            let fade = max(cycleFrames - hold, 1)
            for i in 0..<fade {
                c = tint()
                let t = Double(i) / Double(fade)
                w.emit(peak + (minBri - peak) * t, x: c.x, y: c.y)
            }
        }
    }

    // ── Pre-fix models: what the SHIPPED loops streamed ──
    //
    // These reproduce the mechanism the second pass indicted — a gate on the
    // transition the loop COMPUTED, plus a hold frame the CALLER assembled — so
    // each blocker is pinned as a measured failure rather than asserted in prose.

    /// The old per-frame rise epsilon. Deleted from `FlashSafety`; kept here as a
    /// literal because these models exist to reproduce code that no longer exists.
    private static let legacyRiseEpsilon = 0.02

    /// Two strobe runs on one bridge, the second raising `min_brightness` — the
    /// pre-fix loop, hold frames included (blocker B1).
    private func legacyStrobeFreeRunAcrossARunBoundary(minA: Double, minB: Double) -> [Emission] {
        let ledger = FS.OnsetLedger()
        var wire: [Emission] = []
        var frame = 0
        func send(_ bri: Double) {
            wire.append(Emission(time: Double(frame) * fd,
                                 frame: FS.WireFrame(x: 0.3127, y: 0.3290, brightness: bri)))
            frame += 1
        }
        let plan = FS.StrobePlan.make(speed: 100, dutyCycle: 0.5)
        for (runIndex, minBri) in [minA, minB].enumerated() {
            var lastBri: Double?          // a NEW loop instance starts with none
            for cycle in 0..<(runIndex == 0 ? 4 : 3) {
                while !ledger.tryOnset(at: Double(frame) * fd) { send(lastBri ?? minBri) }
                lastBri = 1.0
                for _ in 0..<plan.onFrames { send(1.0) }
                lastBri = minBri
                // Run A is stopped four frames into its last dark half.
                for _ in 0..<((runIndex == 0 && cycle == 3) ? 4 : plan.offFrames) { send(minBri) }
            }
        }
        return wire
    }

    /// Two inverted-strobe runs (brightness ≤ min_brightness) at different duty
    /// cycles — the pre-fix loop stamping the ON edge, which is the FALL (H2).
    private func legacyStrobeInvertedAcrossARunBoundary(dutyA: Double, dutyB: Double) -> [Emission] {
        let ledger = FS.OnsetLedger()
        var wire: [Emission] = []
        var frame = 0
        func send(_ bri: Double) {
            wire.append(Emission(time: Double(frame) * fd,
                                 frame: FS.WireFrame(x: 0.3127, y: 0.3290, brightness: bri)))
            frame += 1
        }
        for duty in [dutyA, dutyB] {
            var lastBri: Double?
            for _ in 0..<3 {
                let plan = FS.StrobePlan.make(speed: 100, dutyCycle: duty)
                while !ledger.tryOnset(at: Double(frame) * fd) { send(lastBri ?? 0.50) }
                lastBri = 0.01
                for _ in 0..<plan.onFrames { send(0.01) }
                lastBri = 0.50
                for _ in 0..<plan.offFrames { send(0.50) }
            }
        }
        return wire
    }

    /// The pre-fix storm: an ambient-RAISE gate that compares against the
    /// previous ambient (nil on the first iteration — the M4 blackout) and no
    /// gate at all on the afterglow → ambient climb (H1).
    private func legacyStorm(strikes: Int, frequency: Double, flashIntensity: Double,
                             minBri: Double, flashFrames: Int, afterglowFrames: Int,
                             seedOnset: Double? = nil) -> [Emission] {
        let ledger = FS.OnsetLedger(lastOnset: seedOnset)
        var budget = FS.ThunderstormPlan.Budget()
        var lastAmbientBri: Double?
        var wire: [Emission] = []
        var frame = 0
        func send(_ bri: Double, _ xy: (x: Double, y: Double)) {
            wire.append(Emission(time: Double(frame) * fd,
                                 frame: FS.WireFrame(x: xy.x, y: xy.y, brightness: bri)))
            frame += 1
        }
        for _ in 0..<strikes {
            if minBri > (lastAmbientBri ?? -1) + Self.legacyRiseEpsilon {
                var held = 0
                while !ledger.tryOnset(at: Double(frame) * fd) {
                    send(lastAmbientBri ?? 0, Self.stormAmbient)
                    held += 1
                }
                budget.noteAmbient(frames: held)
            }
            lastAmbientBri = minBri
            for _ in 0..<budget.gapFrames(frequency: frequency) {
                send(minBri, Self.stormAmbient)
                budget.noteAmbient()
            }
            while !ledger.tryOnset(at: Double(frame) * fd) { send(minBri, Self.stormAmbient) }
            for _ in 0..<flashFrames { send(flashIntensity, Self.stormFlash) }
            for _ in 0..<afterglowFrames { send(flashIntensity * 0.4, Self.stormFlash) }
            budget.noteStrike(flashFrames: flashFrames, afterglowFrames: afterglowFrames)
        }
        return wire
    }

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

    /// The floor assertion, and — required, never defaulted — the assertion that
    /// the model produced onsets to measure. "No onsets at all" satisfies every
    /// spacing rule there is, so a spacing assertion without a count is a test
    /// that passes when the effect stops working.
    private func assertOnsetsRespectTheFloor(_ times: [Double], label: String, atLeast: Int,
                                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(times.count, atLeast,
                                    "\(label): only \(times.count) onsets — the model must actually flash",
                                    file: file, line: line)
        for i in 1..<max(times.count, 1) {
            XCTAssertGreaterThanOrEqual(times[i] - times[i - 1],
                                        FS.minOnsetLedgerPeriod - FS.onsetComparisonTolerance,
                                        "\(label): rise \(i) at \(times[i]) is too close to \(times[i - 1])",
                                        file: file, line: line)
        }
    }

    /// Pure mirror of the beat branch of `runPartyEntertainment`, frame by frame
    /// on the 20 ms grid. Returns every host time at which the EMITTED brightness
    /// realized a WCAG rise — what a viewer sees, as opposed to what the loop
    /// happens to call a gate on.
    ///
    /// `riseGated: false` is the pre-fix loop (gate on cycle-index change only,
    /// hold frame assembled by the caller); `riseGated: true` routes every frame
    /// through the frame gate, exactly as the shipped loop now does.
    private func partyBeatRenderedRises(
        frames: Int,
        riseGated: Bool,
        peakBri: Double = 0.90,
        minBri: Double = 0.05,
        snapshotAt: (Int) -> BeatSnapshot,
        smoothnessAt: (Int) -> Double
    ) -> [Double] {
        let ledger = FS.OnsetLedger()
        let model = WireModel()
        var legacyWire: [Emission] = []
        var renderedIdx: Int?
        var lastColor: (x: Double, y: Double)?
        var lastBri: Double?
        var frame = 0
        func brightness(_ frame: Int) -> (color: (x: Double, y: Double), bri: Double, idx: Int) {
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
            let palette = Self.partyPalette
            return (palette[((idx % palette.count) + palette.count) % palette.count], bri, idx)
        }

        if riseGated {
            while model.frame < frames {
                let f = brightness(model.frame)
                model.emit(f.bri, x: f.color.x, y: f.color.y)
            }
            return realizedOnsets(model.wire)
        }

        while frame < frames {
            let f = brightness(frame)
            // The SHIPPED pre-fix gate: the cycle index, and nothing else.
            if f.idx != renderedIdx {
                while !ledger.tryOnset(at: Double(frame) * fd) {
                    legacyWire.append(Emission(
                        time: Double(frame) * fd,
                        frame: FS.WireFrame(x: lastColor?.x ?? f.color.x,
                                            y: lastColor?.y ?? f.color.y,
                                            brightness: lastBri ?? minBri)))
                    frame += 1
                    if frame >= frames { return realizedOnsets(legacyWire) }
                }
                renderedIdx = f.idx
            }
            legacyWire.append(Emission(time: Double(frame) * fd,
                                       frame: FS.WireFrame(x: f.color.x, y: f.color.y,
                                                           brightness: f.bri)))
            lastColor = f.color
            lastBri = f.bri
            frame += 1
        }
        return realizedOnsets(legacyWire)
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
        let perCycle = BeatMath.wcagSafeBeatsPerCycle(requested: 1, bpm: snapshot.bpm,
                                                      maxHz: FS.entertainmentMaxLockHz)
        func level(_ frame: Int) -> Double {
            let phase = BeatMath.cyclePhase(at: Double(frame) * fd, snapshot: snapshot,
                                            beatsPerCycle: perCycle)
            return phase < dutyCycle ? peakBri : minBriAt(frame)
        }
        func wantsBright(_ frame: Int) -> Bool {
            BeatMath.cyclePhase(at: Double(frame) * fd, snapshot: snapshot,
                                beatsPerCycle: perCycle) < dutyCycle
        }

        if riseGated {
            let model = WireModel()
            while model.frame < frames { model.emit(level(model.frame)) }
            return realizedOnsets(model.wire)
        }

        let ledger = FS.OnsetLedger()
        var wire: [Emission] = []
        var isBright = false
        var lastBri: Double?
        var frame = 0
        while frame < frames {
            let bri = level(frame)
            let edge = wantsBright(frame) && !isBright
            if edge {
                while !ledger.tryOnset(at: Double(frame) * fd) {
                    wire.append(Emission(time: Double(frame) * fd,
                                         frame: FS.WireFrame(x: 0.3127, y: 0.3290,
                                                             brightness: lastBri ?? minBriAt(frame))))
                    frame += 1
                    if frame >= frames { return realizedOnsets(wire) }
                }
            }
            wire.append(Emission(time: Double(frame) * fd,
                                 frame: FS.WireFrame(x: 0.3127, y: 0.3290, brightness: bri)))
            isBright = wantsBright(frame)
            lastBri = bri
            frame += 1
        }
        return realizedOnsets(wire)
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

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Composer (Slice 3): the per-channel loop joins the same gate
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    //
    // `runCompositionEntertainment` streamed straight to the transport at 25 fps
    // with no ledger and discarded the delivery `Bool`. Two authored looks put a
    // realized flash above the ceiling on the wire:
    //
    //  • `.pulse` is a SQUARE wave at `bpm/60` Hz (`EnvelopeConfig.value(at:)`),
    //    and `bpm` is authored to 240 → 4 Hz, full depth, every light together.
    //  • `.flicker` carries an unconditional `sin(t · 23.14)` ≈ 3.68 Hz component
    //    at ANY bpm.
    //
    // The loop is per-channel, so it cannot use `emitGatedFrame`. It reduces the
    // frame to the field a viewer receives and reserves on THAT. Everything below
    // grades the wire with `realizedOnsets`, which re-derives the WCAG rules from
    // the delivered frames alone.

    /// One channel's worth of the composition loop's per-frame output, gamut
    /// clamp omitted (these fixtures are already in gamut).
    private func compositionChannels(
        box: CompositionParamBox, time: Double, channels: Int
    ) -> [(x: Double, y: Double, brightness: Double)] {
        CompositionEngine
            .render(time: time, channelIDs: Array(0..<channels), params: box)
            .map { (x: $0.x, y: $0.y, brightness: $0.brightness) }
    }

    /// Drives the composition ENT loop's frame production through the gate at
    /// its real 40 ms cadence. `gated: false` models the loop as it shipped —
    /// straight to the transport, no ledger — so every rate assertion below can
    /// be shown to FAIL on the code it replaced.
    private func compositionWire(
        envelope: EnvelopeConfig,
        palette: PaletteConfig = PaletteConfig(),
        motion: MotionConfig = MotionConfig(pattern: .static),
        channels: Int = 4,
        seconds: Double = 6.0,
        gated: Bool = true,
        dropWindow: Range<Int>? = nil,
        model: WireModel? = nil
    ) -> WireModel {
        let m = model ?? WireModel()
        m.fd = 0.04                      // 25 fps, the composition loop's own cadence
        m.dropWindow = dropWindow
        let box = CompositionParamBox(
            palette: palette, motion: motion, envelope: envelope, reaction: ReactionConfig())
        let frames = Int((seconds / 0.04).rounded())
        for i in 0..<frames {
            let chans = compositionChannels(box: box, time: Double(i) * 0.04, channels: channels)
            if gated {
                m.emitComposition(chans)
            } else {
                m.emitUngatedComposition(chans)
            }
        }
        return m
    }

    /// The REST scheduler's frame production through its gate at its real
    /// 120 ms tick. `gated: false` is the scheduler as it shipped.
    private func restCompositionWire(
        envelope: EnvelopeConfig,
        palette: PaletteConfig = PaletteConfig(),
        motion: MotionConfig = MotionConfig(pattern: .static),
        channels: Int = 4,
        seconds: Double = 6.0,
        gated: Bool = true
    ) -> WireModel {
        let m = WireModel()
        m.fd = 0.12                      // the REST scheduler's tick
        let box = CompositionParamBox(
            palette: palette, motion: motion, envelope: envelope, reaction: ReactionConfig())
        let ticks = Int((seconds / 0.12).rounded())
        for i in 0..<ticks {
            let chans = compositionChannels(box: box, time: Double(i) * 0.12, channels: channels)
            if gated { m.emitRESTComposition(chans) } else { m.emitUngatedRESTComposition(chans) }
        }
        return m
    }

    // ── The REST scheduler (review round, D-1) ──

    func testPulseAtTwoFortyBpmRealizesAboveThreeHzOverUngatedREST() {
        // The REST scheduler as it shipped: 120 ms ticks, no ledger. A 250 ms
        // square sampled on a 120 ms grid alternates nearly every tick.
        let onsets = realizedOnsets(
            restCompositionWire(envelope: EnvelopeConfig(shape: .pulse, bpm: 240, depth: 100,
                                                         minBrightness: 0, maxBrightness: 100),
                                gated: false).wire)
        XCTAssertGreaterThan(onsets.count, 6, "a 4 Hz square wave must realize onsets to grade")
        XCTAssertLessThan(minimumGap(onsets) ?? .infinity,
                          BeatMath.FlashSafety.minOnsetLedgerPeriod,
                          "the ungated REST scheduler must breach the ceiling, or the fix is untested")
    }

    func testPulseAtTwoFortyBpmIsGatedToThreeHzOverREST() {
        let onsets = realizedOnsets(
            restCompositionWire(envelope: EnvelopeConfig(shape: .pulse, bpm: 240, depth: 100,
                                                         minBrightness: 0, maxBrightness: 100)).wire)
        assertOnsetsRespectTheFloor(onsets, label: "REST composition .pulse @ 240 bpm", atLeast: 3)
    }

    func testFlickerIsGatedToThreeHzOverREST() {
        let onsets = realizedOnsets(
            restCompositionWire(envelope: EnvelopeConfig(shape: .flicker, bpm: 20, depth: 100,
                                                         minBrightness: 0, maxBrightness: 100),
                                seconds: 10).wire)
        assertOnsetsRespectTheFloor(onsets, label: "REST composition .flicker", atLeast: 1)
    }

    func testEveryAuthoredEnvelopeShapeAtEveryTempoRespectsTheFloorOverREST() {
        for shape in EnvelopeConfig.Shape.allCases {
            for bpm in [20.0, 60, 137, 180, 240] {
                let wire = restCompositionWire(envelope: EnvelopeConfig(shape: shape, bpm: bpm, depth: 100,
                                                                        minBrightness: 0, maxBrightness: 100),
                                               seconds: 8).wire
                if shape != .steady {
                    XCTAssertGreaterThan(luminanceSpan(wire), 0.1,
                        "REST \(shape) @ \(bpm): the gated wire never moved")
                }
                assertOnsetsRespectTheFloor(realizedOnsets(wire), label: "REST \(shape) @ \(bpm) bpm", atLeast: 0)
            }
        }
    }

    /// A refused REST tick writes NOTHING — no black, no hold frame — and the
    /// reservation is rolled back, so the next admissible frame is admitted on
    /// the real onset clock rather than against a phantom.
    func testARefusedRESTTickWritesNothingAndRollsBack() {
        let m = WireModel()
        m.fd = 0.12
        let bright = Array(repeating: (x: 0.3127, y: 0.3290, brightness: 1.0), count: 4)
        let dark = Array(repeating: (x: 0.3127, y: 0.3290, brightness: 0.0), count: 4)
        // The viewer's detector seeds its trough from the first delivered
        // frame, so the wire starts dark and the first ONSET is the rise at
        // t = 0.12.
        XCTAssertTrue(m.emitRESTComposition(dark), "t=0.00: the wire starts dark")
        XCTAssertTrue(m.emitRESTComposition(bright), "t=0.12: the first onset is admitted")
        XCTAssertTrue(m.emitRESTComposition(dark), "t=0.24: a fall is always admitted")
        let before = m.wire.count
        XCTAssertFalse(m.emitRESTComposition(bright), "t=0.36: a rise 0.24 s after the onset is refused")
        XCTAssertEqual(m.wire.count, before, "…and NOTHING reached the transport")
        XCTAssertTrue(m.emitRESTComposition(bright), "t=0.48: admitted on the real clock")
        let onsets = realizedOnsets(m.wire)
        XCTAssertEqual(onsets.count, 2, "\(onsets)")
        XCTAssertGreaterThanOrEqual(minimumGap(onsets) ?? 0, BeatMath.FlashSafety.minOnsetLedgerPeriod - 1e-9)
    }

    // ── Restart inside the period (review round, D-2) ──

    /// A composition stops (the bridge restores its own state — black) and a
    /// fast restart streams its first bright frame 0.25 s after the previous
    /// onset. With the wire FORGOTTEN at the stop, the ledger takes the cold
    /// path, refuses, and holds black; the realized wire shows no sub-period
    /// pair. Without the forget (the ledger still modelling the pre-stop bright
    /// frame) the same bright frame is "not a candidate" and goes out
    /// unstamped — a 4 Hz pair on the wire. Both halves, so the fix is checked
    /// against the defect.
    func testARestartInsideThePeriodCannotFlashOnceTheWireIsForgotten() {
        let bright = Array(repeating: (x: 0.3127, y: 0.3290, brightness: 1.0), count: 4)
        let dark = Array(repeating: (x: 0.3127, y: 0.3290, brightness: 0.0), count: 4)
        func run(forgetting: Bool) -> [Double] {
            let m = WireModel()
            m.fd = 0.05
            m.emitComposition(dark)        // t = 0.00, the wire starts dark
            m.emitComposition(bright)      // t = 0.05, admitted onset
            m.bridgeReverted()             // t = 0.10, the stop: bridge shows black
            if forgetting { m.forgetWire() }
            m.idle(2)                      // t = 0.15, 0.20 teardown / handshake
            m.emitComposition(bright)      // t = 0.25, the restart's first frame (0.20 s after the onset)
            m.emitComposition(bright)      // t = 0.30
            m.emitComposition(bright)      // t = 0.35
            m.emitComposition(bright)      // t = 0.40, admissible again (0.35 s)
            m.emitComposition(bright)      // t = 0.45
            return realizedOnsets(m.wire)
        }
        let defect = run(forgetting: false)
        XCTAssertLessThan(minimumGap(defect) ?? .infinity, BeatMath.FlashSafety.minOnsetLedgerPeriod,
                          "without forgetting the wire at the stop, the restart flashes — the defect must be reproducible")
        let fixed = run(forgetting: true)
        assertOnsetsRespectTheFloor(fixed, label: "restart 0.25 s after the previous onset", atLeast: 2)
    }

    // ── A forget outlives a late rollback (safety round 2, #2) ──

    /// `stopCompositionMode` forgets the wire; an executing sweep's late
    /// `cancelled 0/0` then rolls its reservation back. Before this round the
    /// rollback restored `lastEmitted` — the bright frame the stop had just
    /// turned off — and the restart's first bright frame went out unstamped.
    /// The ledger now refuses to restore a wire model a forget predates.
    func testALateRollbackCannotRestoreAWireAForgetPredates() {
        var gate = ProductionOnsetGate()
        let bright = BeatMath.FlashSafety.WireFrame(x: 0.3127, y: 0.3290, brightness: 1.0)
        let dark = BeatMath.FlashSafety.WireFrame(x: 0.3127, y: 0.3290, brightness: 0.0)
        _ = gate.reserve(dark, at: 0.00); gate.settle(delivered: true, at: 0.00)
        _ = gate.reserve(bright, at: 0.05); gate.settle(delivered: true, at: 0.05)   // onset
        // The sweep's reservation is taken (bright, not a candidate against
        // a bright wire — emitted), the stop forgets, and only THEN does the
        // sweep's terminal roll it back.
        let pending = gate.reserve(bright, at: 0.10)
        XCTAssertTrue(pending.admitted)
        gate.forgetWire()
        gate.settle(delivered: false, at: 0.20)
        // The restart's first bright frame, 0.20 s after the onset: against a
        // FORGOTTEN wire it is a cold candidate inside the period → held.
        let restart = gate.reserve(bright, at: 0.25)
        XCTAssertFalse(restart.admitted, "the rollback restored the pre-stop wire model — the restart's rise went out unstamped")
        XCTAssertEqual(restart.onWire.brightness, 0, accuracy: 1e-9, "…and the hold is black")
    }

    // ── The projected field (safety round 2, #3) ──

    /// A rotation sweep dispatches a SLICE of the room; the wire's field is
    /// every light as last delivered with the slice replaced. The reservation
    /// must be taken on that — reserving on the whole-room render let a stale
    /// slice's real rise (a dark light lit by a frame the render called a
    /// non-candidate) reach the wire unmeasured.
    func testTheProjectedFieldIsWhatTheWireShows() {
        // Three slices: A (0…1) bright, B (2…3) dark, C (4) bright — what a
        // gated pulse leaves behind. The next sweep sends 0.6 to slice B.
        let last: [Int: (x: Double, y: Double, brightness: Double)] = [
            0: (0.3127, 0.3290, 1.0), 1: (0.3127, 0.3290, 1.0),
            2: (0.3127, 0.3290, 0.0), 3: (0.3127, 0.3290, 0.0),
            4: (0.3127, 0.3290, 1.0),
        ]
        let sweep = [(index: 2, x: 0.3127, y: 0.3290, brightness: 0.6),
                     (index: 3, x: 0.3127, y: 0.3290, brightness: 0.6)]
        let projected = BeatMath.FlashSafety.projectedField(lastDelivered: last, sweep: sweep)
        // The wire after the sweep, reduced INDEPENDENTLY:
        var wireAfter = last
        for s in sweep { wireAfter[s.index] = (s.x, s.y, s.brightness) }
        let viewer = viewerFieldFrame(wireAfter.keys.sorted().map { wireAfter[$0]! })
        let reserved = BeatMath.FlashSafety.fieldFrame(channels: projected)
        XCTAssertEqual(reserved.relativeLuminance, viewer.relativeLuminance, accuracy: 1e-6,
                       "the reserved field must be the field the wire will show")
        // A never-delivered light reads as the sweep's own frame.
        let fresh = BeatMath.FlashSafety.projectedField(lastDelivered: [:], sweep: sweep)
        XCTAssertEqual(fresh.count, 2)
        XCTAssertEqual(fresh[0].brightness, 0.6, accuracy: 1e-12)
    }

    /// The reviewer's scenario: with the reservation on the whole-room render
    /// the 0.6 frame is a fall from the render's own bright trough and passes
    /// unstamped while the wire RISES on the dark slice; on the projected
    /// field it is the rise it really is, and inside the period it is held.
    func testAStaleSliceRiseIsMeasuredOnTheProjectedField() {
        let white = (x: 0.3127, y: 0.3290)
        let last: [Int: (x: Double, y: Double, brightness: Double)] = [
            0: (white.x, white.y, 1.0), 1: (white.x, white.y, 1.0),
            2: (white.x, white.y, 0.0), 3: (white.x, white.y, 0.0),
            4: (white.x, white.y, 1.0),
        ]
        // The ledger has just stamped an onset for slice A at t = 0.
        var gate = ProductionOnsetGate()
        _ = gate.reserve(BeatMath.FlashSafety.fieldFrame(channels: [(white.x, white.y, 0.0)]), at: -0.5)
        gate.settle(delivered: true, at: -0.5)
        _ = gate.reserve(BeatMath.FlashSafety.fieldFrame(
            channels: BeatMath.FlashSafety.projectedField(lastDelivered: last, sweep: [])), at: 0.0)
        gate.settle(delivered: true, at: 0.0)
        // t = 0.12: the sweep lights slice B (dark → 0.6).
        let sweepB = [(index: 2, x: white.x, y: white.y, brightness: 0.6),
                      (index: 3, x: white.x, y: white.y, brightness: 0.6)]
        let projected = BeatMath.FlashSafety.projectedField(lastDelivered: last, sweep: sweepB)
        let decided = gate.reserve(BeatMath.FlashSafety.fieldFrame(channels: projected), at: 0.12)
        XCTAssertFalse(decided.admitted,
            "lighting two dark lights of five is a field rise inside the period — it must be refused")
    }

    // ── Two frame sources on one bridge (safety round 3, #1) ──

    /// The reviewer's scenario, on the production gate: room B (5 lights,
    /// REST) and room A (3 lights, REST) alternate on one bridge's ledger.
    /// With ONE wire model, A's bright field after B's bright field read as
    /// "no rise" and went out unstamped 0.20 s after B's onset — 4 Hz in
    /// room A. With per-source wire state, A's first bright frame is A's own
    /// cold rise, measured against the SHARED onset clock: refused, and the
    /// next admissible A onset is ≥ 0.34 s after B's.
    func testTwoSourcesOnOneBridgeAreJudgedAgainstTheirOwnWires() {
        let white = (x: 0.3127, y: 0.3290)
        func field(_ bri: Double, lights: Int) -> BeatMath.FlashSafety.WireFrame {
            BeatMath.FlashSafety.fieldFrame(channels: Array(repeating: (white.x, white.y, bri), count: lights))
        }
        let ledger = BeatMath.FlashSafety.OnsetLedger()
        let a = BeatMath.FlashSafety.restSource(roomID: "room-a")
        let b = BeatMath.FlashSafety.restSource(roomID: "room-b")
        // B: dark, then bright at t = 0.00 (stamped, delivered at 0.06).
        var r = ledger.admit(frame: field(0, lights: 5), source: b, at: -0.5)
        ledger.commit(r, delivered: true, at: -0.44)
        r = ledger.admit(frame: field(1, lights: 5), source: b, at: 0.00)
        XCTAssertTrue(r.wasAdmitted); ledger.commit(r, delivered: true, at: 0.06)
        // A's very first frame: bright, 0.20 s after B's onset. A's own wire
        // is unknown — a cold candidate — and the shared clock refuses it.
        r = ledger.admit(frame: field(1, lights: 3), source: a, at: 0.20)
        XCTAssertFalse(r.wasAdmitted,
            "room A's rise was judged against room B's bright field and went out unstamped — 4 Hz in room A")
        ledger.commit(r, delivered: false, at: 0.20)   // REST refusal: nothing sent
        // B falls; A retries at 0.45 — admissible against the shared clock.
        r = ledger.admit(frame: field(0, lights: 5), source: b, at: 0.25)
        ledger.commit(r, delivered: true, at: 0.31)
        r = ledger.admit(frame: field(1, lights: 3), source: a, at: 0.45)
        XCTAssertTrue(r.wasAdmitted, "0.45 s after B's onset, A's rise is admitted on the shared clock")
        ledger.commit(r, delivered: true, at: 0.51)
        // …and B's next bright frame at 0.60 is judged against B's OWN dark
        // wire (a rise) and the shared clock (0.09 s after A's stamp): refused.
        r = ledger.admit(frame: field(1, lights: 5), source: b, at: 0.60)
        XCTAssertFalse(r.wasAdmitted, "B's rise inside A's period must be refused on the shared clock")
        ledger.commit(r, delivered: false, at: 0.60)
        // A's steady bright frame at 0.70 is NOT a candidate against A's own
        // bright wire — emitted unstamped, as a non-flash should be.
        r = ledger.admit(frame: field(1, lights: 3), source: a, at: 0.70)
        XCTAssertTrue(r.wasAdmitted, "a source's unchanged field is not a rise against ITS OWN wire")
        ledger.commit(r, delivered: true, at: 0.76)
    }

    /// The Entertainment session and a REST room share the clock, not the
    /// wire: a Strobe's frame after a REST sweep is measured against the
    /// Strobe's own last frame.
    func testEntertainmentAndRESTSourcesShareTheClockNotTheWire() {
        let white = (x: 0.3127, y: 0.3290)
        let ledger = BeatMath.FlashSafety.OnsetLedger()
        let ent = BeatMath.FlashSafety.entertainmentSource
        let rest = BeatMath.FlashSafety.restSource(roomID: "room-a")
        let dark = BeatMath.FlashSafety.WireFrame(x: white.x, y: white.y, brightness: 0)
        let bright = BeatMath.FlashSafety.WireFrame(x: white.x, y: white.y, brightness: 1)
        // Strobe ON at 0.00 (stamped), stays on.
        var r = ledger.admit(frame: dark, source: ent, at: -0.5); ledger.commit(r, delivered: true, at: -0.5)
        r = ledger.admit(frame: bright, source: ent, at: 0.00); XCTAssertTrue(r.wasAdmitted)
        ledger.commit(r, delivered: true, at: 0.00)
        // A REST sweep on another room, dark → its own cold non-candidate, emitted.
        r = ledger.admit(frame: dark, source: rest, at: 0.10); XCTAssertTrue(r.wasAdmitted)
        ledger.commit(r, delivered: true, at: 0.16)
        // The Strobe's next ON frame at 0.12 is judged against ITS OWN bright
        // wire: not a candidate, emitted — no blackout (round 2, #4).
        r = ledger.admit(frame: bright, source: ent, at: 0.12)
        XCTAssertTrue(r.wasAdmitted, "the Strobe's ON phase was cut black by the REST room's frame")
        XCTAssertEqual(r.frame.brightness, 1, accuracy: 1e-9)
        ledger.commit(r, delivered: true, at: 0.12)
        // The REST room's bright frame at 0.20 IS a rise on its own wire and
        // is inside the Strobe's period: refused on the shared clock.
        r = ledger.admit(frame: bright, source: rest, at: 0.20)
        XCTAssertFalse(r.wasAdmitted)
        ledger.commit(r, delivered: false, at: 0.20)
    }

    // ── A batched REST sweep and the clock (safety round 4) ──

    /// The reviewer's scenario, on the production ledger: a 15-light REST
    /// room is admitted at t = 0 and its three batches of PUTs land at 0.08,
    /// 0.24 and 0.40. Before round 4 the stamp stayed at the ADMIT time, so
    /// a Strobe on the same bridge was admitted at 0.34 — 0.26 s after the
    /// first lamps rose and 0.06 s before the last ones. The clock now moves
    /// with each realized batch: the Strobe waits for 0.40 + 0.34.
    func testARESTSweepsClockMovesToWhenItsLampsRose() {
        let white = (x: 0.3127, y: 0.3290)
        let ledger = BeatMath.FlashSafety.OnsetLedger()
        let ent = BeatMath.FlashSafety.entertainmentSource
        let rest = BeatMath.FlashSafety.restSource(roomID: "room-r")
        let dark = BeatMath.FlashSafety.WireFrame(x: white.x, y: white.y, brightness: 0)
        let bright = BeatMath.FlashSafety.WireFrame(x: white.x, y: white.y, brightness: 1)
        // Both sources dark and known.
        var r = ledger.admit(frame: dark, source: ent, at: -0.5); ledger.commit(r, delivered: true, at: -0.5)
        r = ledger.admit(frame: dark, source: rest, at: -0.4); ledger.commit(r, delivered: true, at: -0.34)
        // The room's rise is admitted (stamped) at 0.00 …
        let sweep = ledger.admit(frame: bright, source: rest, at: 0.00)
        XCTAssertTrue(sweep.wasAdmitted)
        // … and its lamps rise batch by batch.
        XCTAssertTrue(ledger.noteRealized(sweep, at: 0.08))
        XCTAssertTrue(ledger.noteRealized(sweep, at: 0.24))
        XCTAssertEqual(ledger.lastOnset ?? -1, 0.24, accuracy: 1e-9, "the clock is where the lamps last rose")
        // The Strobe's ON frame at 0.34: 0.34 s after the ADMIT, 0.10 s after
        // the second batch rose — refused.
        r = ledger.admit(frame: bright, source: ent, at: 0.34)
        XCTAssertFalse(r.wasAdmitted, "the Strobe was admitted against the sweep's admit time, not its lamps")
        ledger.commit(r, delivered: true, at: 0.34)   // the hold frame goes out
        XCTAssertTrue(ledger.noteRealized(sweep, at: 0.40), "a refused frame does not take the clock")
        ledger.commit(sweep, delivered: true, at: 0.40)
        XCTAssertEqual(ledger.lastOnset ?? -1, 0.40, accuracy: 1e-9)
        r = ledger.admit(frame: bright, source: ent, at: 0.60)
        XCTAssertFalse(r.wasAdmitted, "0.20 s after the last batch rose")
        ledger.commit(r, delivered: true, at: 0.60)
        r = ledger.admit(frame: bright, source: ent, at: 0.74)
        XCTAssertTrue(r.wasAdmitted, "0.34 s after the last lamps rose, the Strobe's onset is admitted")
        ledger.commit(r, delivered: true, at: 0.74)
    }

    /// If another source stamps the clock between two of a sweep's batches
    /// (a slow bridge stretched the batches past the period), the sweep's
    /// remaining lamps would rise inside THAT onset's period: `beginRealizing`
    /// refuses the next batch BEFORE it is dispatched, and a batch that was
    /// already on its way when the clock changed hands still records its
    /// rise — a fact about the wire whoever owns the clock (round 5).
    func testASweepThatLostTheClockSendsNoFurtherBatch() {
        let white = (x: 0.3127, y: 0.3290)
        let ledger = BeatMath.FlashSafety.OnsetLedger()
        let ent = BeatMath.FlashSafety.entertainmentSource
        let rest = BeatMath.FlashSafety.restSource(roomID: "room-r")
        let dark = BeatMath.FlashSafety.WireFrame(x: white.x, y: white.y, brightness: 0)
        let bright = BeatMath.FlashSafety.WireFrame(x: white.x, y: white.y, brightness: 1)
        var r = ledger.admit(frame: dark, source: ent, at: -0.5); ledger.commit(r, delivered: true, at: -0.5)
        r = ledger.admit(frame: dark, source: rest, at: -0.4); ledger.commit(r, delivered: true, at: -0.34)
        let sweep = ledger.admit(frame: bright, source: rest, at: 0.00)
        XCTAssertTrue(sweep.wasAdmitted)
        XCTAssertTrue(ledger.noteRealized(sweep, at: 0.08))
        // A stalled second batch; the Strobe's onset at 0.42 is legitimately
        // 0.34 s after the lamps that HAVE risen — admitted, the clock is its.
        r = ledger.admit(frame: bright, source: ent, at: 0.42)
        XCTAssertTrue(r.wasAdmitted)
        ledger.commit(r, delivered: true, at: 0.42)
        // A batch already in flight lands at 0.45: 0.03 s after the Strobe's
        // onset. Its rise IS recorded — the clock moves to 0.45 — and the
        // sweep learns it no longer owns the clock.
        XCTAssertFalse(ledger.noteRealized(sweep, at: 0.45),
            "a sweep that lost the clock between batches went on lighting lamps inside the other onset's period")
        XCTAssertEqual(ledger.lastOnset ?? -1, 0.45, accuracy: 1e-9,
            "a rise that happened is recorded whoever owns the clock (round 5)")
        // The next batch is refused BEFORE dispatch.
        XCTAssertFalse(ledger.beginRealizing(sweep), "the sweep must send no further batch")
        // An UNSTAMPED sweep (no rise) is never held back by ownership.
        ledger.commit(sweep, delivered: true, at: 0.45)
        let steady = ledger.admit(frame: bright, source: rest, at: 0.60)
        XCTAssertTrue(steady.wasAdmitted)
        XCTAssertTrue(ledger.noteRealized(steady, at: 0.66), "a frame that is not a rise has no clock to lose")
        ledger.commit(steady, delivered: true, at: 0.66)
    }

    /// The in-flight window (safety round 5, HIGH): a REST sweep is admitted
    /// at 0.00 but a slow bridge lands its first batch at 0.50. Before round 5
    /// the Strobe on the same bridge was admitted at 0.34 — 0.16 s BEFORE the
    /// REST lamps rose. A stamped rise that has not yet been realized holds
    /// every other source's onsets; each further batch re-opens the hold from
    /// its dispatch until its lamps report up.
    func testAnUnrealizedStampHoldsEveryOtherSource() {
        let white = (x: 0.3127, y: 0.3290)
        let ledger = BeatMath.FlashSafety.OnsetLedger()
        let ent = BeatMath.FlashSafety.entertainmentSource
        let rest = BeatMath.FlashSafety.restSource(roomID: "room-r")
        let dark = BeatMath.FlashSafety.WireFrame(x: white.x, y: white.y, brightness: 0)
        let bright = BeatMath.FlashSafety.WireFrame(x: white.x, y: white.y, brightness: 1)
        var r = ledger.admit(frame: dark, source: ent, at: -0.5); ledger.commit(r, delivered: true, at: -0.5)
        r = ledger.admit(frame: dark, source: rest, at: -0.4); ledger.commit(r, delivered: true, at: -0.34)
        let sweep = ledger.admit(frame: bright, source: rest, at: 0.00)
        XCTAssertTrue(sweep.wasAdmitted)
        // The first batch is on its way. The Strobe's ON frame at 0.34 is
        // 0.34 s after the ADMIT — and an unknown time before the lamps rise.
        r = ledger.admit(frame: bright, source: ent, at: 0.34)
        XCTAssertFalse(r.wasAdmitted, "the Strobe was admitted while a REST rise was still in flight")
        ledger.commit(r, delivered: true, at: 0.34)
        // The batch lands at 0.50: the clock is 0.50 and the hold is over.
        XCTAssertTrue(ledger.noteRealized(sweep, at: 0.50))
        r = ledger.admit(frame: bright, source: ent, at: 0.60)
        XCTAssertFalse(r.wasAdmitted, "0.10 s after the lamps rose")
        ledger.commit(r, delivered: true, at: 0.60)
        // The second batch is dispatched at 0.58 (after the 80 ms sleep) and
        // re-opens the hold: the Strobe at 0.84 — 0.34 s after batch one —
        // is still refused, because batch two is on its way.
        XCTAssertTrue(ledger.beginRealizing(sweep))
        r = ledger.admit(frame: bright, source: ent, at: 0.84)
        XCTAssertFalse(r.wasAdmitted, "a further batch in flight is a rise nobody has seen yet")
        ledger.commit(r, delivered: true, at: 0.84)
        XCTAssertTrue(ledger.noteRealized(sweep, at: 0.90))
        // Nothing in flight, 0.34 s after the last lamps rose: admitted, and
        // the clock is the Strobe's — the sweep's third batch is refused
        // BEFORE it is dispatched.
        r = ledger.admit(frame: bright, source: ent, at: 1.24)
        XCTAssertTrue(r.wasAdmitted)
        XCTAssertFalse(ledger.beginRealizing(sweep), "the clock changed hands — no further batch")
        // …but the Strobe's send is DROPPED: its stamp rolls back to 0.90,
        // and with it the clock returns to the sweep, which may go on.
        ledger.commit(r, delivered: false, at: 1.25)
        XCTAssertEqual(ledger.lastOnset ?? -1, 0.90, accuracy: 1e-9)
        XCTAssertTrue(ledger.beginRealizing(sweep),
            "a rolled-back stamp must hand the clock back to the sweep whose stamp is current again")
        XCTAssertTrue(ledger.noteRealized(sweep, at: 1.30))
        ledger.commit(sweep, delivered: true, at: 1.31)
        // A ROLLED-BACK stamp holds nothing: the Strobe's dropped frame at
        // 1.65 frees the clock for the room's next rise.
        r = ledger.admit(frame: dark, source: ent, at: 1.58); ledger.commit(r, delivered: true, at: 1.58)
        r = ledger.admit(frame: bright, source: ent, at: 1.65)
        XCTAssertTrue(r.wasAdmitted)
        ledger.commit(r, delivered: false, at: 1.65)
        let next = ledger.admit(frame: bright, source: rest, at: 1.67)
        XCTAssertTrue(next.wasAdmitted, "a rolled-back stamp must not hold the wire hostage")
        ledger.commit(next, delivered: true, at: 1.73)
    }

    /// A rising sweep that half-landed: two of four lamps refused the PUT.
    /// The admission recorded the whole rise; the wire shows half of it. The
    /// source's wire is corrected to what landed, so the retry that lights
    /// the other two is a rise on the wire — refused inside the period, not
    /// sent unstamped as "no change".
    func testAPartialDeliveryCorrectsTheSourceWire() {
        let white = (x: 0.3127, y: 0.3290)
        func field(_ bris: [Double]) -> BeatMath.FlashSafety.WireFrame {
            BeatMath.FlashSafety.fieldFrame(channels: bris.map { (white.x, white.y, $0) })
        }
        let ledger = BeatMath.FlashSafety.OnsetLedger()
        let rest = BeatMath.FlashSafety.restSource(roomID: "room-r")
        var r = ledger.admit(frame: field([0, 0, 0, 0]), source: rest, at: -0.5)
        ledger.commit(r, delivered: true, at: -0.44)
        // The sweep: all four to full. Admitted, stamped at 0.00.
        r = ledger.admit(frame: field([1, 1, 1, 1]), source: rest, at: 0.00)
        XCTAssertTrue(r.wasAdmitted)
        ledger.commit(r, delivered: true, at: 0.06)
        // Lamps 2 and 3 failed: the wire shows [1, 1, 0, 0].
        ledger.correctWire(source: rest, frame: field([1, 1, 0, 0]))
        // The next tick projects the whole room bright again — a rise of half
        // the field 0.12 s after the stamp. Refused.
        r = ledger.admit(frame: field([1, 1, 1, 1]), source: rest, at: 0.12)
        XCTAssertFalse(r.wasAdmitted,
            "the retry read as 'no change' against a wire that claimed the whole rise — lamps 2 and 3 lit unmeasured")
        ledger.commit(r, delivered: false, at: 0.12)
        // …and admitted once the period has passed.
        r = ledger.admit(frame: field([1, 1, 1, 1]), source: rest, at: 0.40)
        XCTAssertTrue(r.wasAdmitted)
        ledger.commit(r, delivered: true, at: 0.46)
        // A wire forgotten since the admission stays unknown: no correction.
        ledger.forgetWire()
        ledger.correctWire(source: rest, frame: field([1, 1, 1, 1]))
        XCTAssertNil(ledger.lastEmitted, "a correction must not resurrect a forgotten wire")
    }

    // ── Cold refusal chroma (review round, D-3) ──

    /// A cold refusal — no delivered per-channel frame to repeat — sends the
    /// ledger's own hold frame: black at the last KNOWN chromaticity, not at
    /// the requested one. Black at the requested colour was a chroma step
    /// against the frame the bridge was still showing.
    func testAColdRefusalHoldsTheLastKnownChromaticity() {
        let dark = Array(repeating: (x: 0.3127, y: 0.3290, brightness: 0.0), count: 4)
        let red = Array(repeating: (x: 0.675, y: 0.322, brightness: 1.0), count: 4)
        // Green, not blue: a saturated blue at full drive carries ~0.07 relative
        // luminance and is not a candidate at all; the refusal needs a REAL rise.
        let green = Array(repeating: (x: 0.17, y: 0.70, brightness: 1.0), count: 4)
        let m = WireModel()
        m.fd = 0.05
        m.emitComposition(dark)    // t = 0.00
        m.emitComposition(red)     // t = 0.05: admitted, last known = red
        m.forgetWire()             // the stop
        m.idle(2)                  // t = 0.10, 0.15
        XCTAssertFalse(m.emitComposition(green), "t = 0.20: a bright rise 0.15 s after the onset is refused")
        let held = m.wire.last!.frame
        XCTAssertEqual(held.brightness, 0, accuracy: 1e-9, "the hold is black")
        XCTAssertEqual(held.x, 0.675, accuracy: 0.02, "…at the last KNOWN (red) chromaticity, not the requested green")
        XCTAssertEqual(held.y, 0.322, accuracy: 0.02)
        assertOnsetsRespectTheFloor(realizedOnsets(m.wire), label: "cold refusal", atLeast: 1)
    }

    // ── The field reduction ──

    func testFieldFrameOfAUniformFrameIsThatFrame() {
        // The property that lets a composition share one ledger with Strobe: on
        // a uniform frame the reduction must be the IDENTITY, or the two loops
        // would be gated on different numbers for the same wire.
        for bri in [0.0, 0.13, 0.5, 0.901, 1.0] {
            for (x, y) in [(0.3127, 0.3290), (0.675, 0.322), (0.17, 0.70), (0.167, 0.04)] {
                let uniform = Array(repeating: (x: x, y: y, brightness: bri), count: 7)
                let field = BeatMath.FlashSafety.fieldFrame(channels: uniform)
                let one = BeatMath.FlashSafety.WireFrame(x: x, y: y, brightness: bri)
                XCTAssertEqual(field.x, one.x, accuracy: 1e-12)
                XCTAssertEqual(field.y, one.y, accuracy: 1e-12)
                XCTAssertEqual(field.relativeLuminance, one.relativeLuminance, accuracy: 1e-12,
                               "uniform reduction must be the identity at bri=\(bri) xy=(\(x),\(y))")
            }
        }
    }

    func testFieldLuminanceIsTheMeanNotTheMaximum() {
        // Eight lights, one at full, seven dark: the field moved by an eighth,
        // and gating it as though the whole room flashed would refuse motion
        // that no viewer perceives as a flash.
        var chans = Array(repeating: (x: 0.3127, y: 0.3290, brightness: 0.0), count: 8)
        chans[0].brightness = 1.0
        let field = BeatMath.FlashSafety.fieldFrame(channels: chans)
        let full = BeatMath.FlashSafety.WireFrame(x: 0.3127, y: 0.3290, brightness: 1.0)
        XCTAssertEqual(field.relativeLuminance, full.relativeLuminance / 8.0, accuracy: 1e-12)
        XCTAssertLessThan(field.relativeLuminance, full.relativeLuminance / 4.0,
                          "a max-reduction would report the single lamp as the whole field")
    }

    func testFieldLuminanceAveragesLuminanceNotDimming() {
        // `dimmingLuminance` is a cube, so averaging the DIMMING levels first
        // and cubing after understates every mixed frame (Jensen) — and
        // understating is the direction that lets a flash through.
        let mixed = [(x: 0.3127, y: 0.3290, brightness: 1.0),
                     (x: 0.3127, y: 0.3290, brightness: 0.0)]
        let field = BeatMath.FlashSafety.fieldFrame(channels: mixed)
        let meanOfLuminances =
            (BeatMath.FlashSafety.WireFrame(x: 0.3127, y: 0.3290, brightness: 1.0).relativeLuminance
             + BeatMath.FlashSafety.WireFrame(x: 0.3127, y: 0.3290, brightness: 0.0).relativeLuminance) / 2
        let cubeOfMeanDimming =
            BeatMath.FlashSafety.WireFrame(x: 0.3127, y: 0.3290, brightness: 0.5).relativeLuminance
        XCTAssertEqual(field.relativeLuminance, meanOfLuminances, accuracy: 1e-12)
        XCTAssertGreaterThan(meanOfLuminances, cubeOfMeanDimming + 0.05,
                             "the two must differ enough that this test can tell them apart")
    }

    func testFieldChromaticityIsWeightedByLuminance() {
        // A chase's dark tail must not dilute the hue: an unweighted mean would
        // drag a saturated-red strike off red until the red rule stopped firing.
        let red = (x: 0.675, y: 0.322, brightness: 1.0)
        let darkBlue = (x: 0.167, y: 0.04, brightness: 0.0)
        let field = BeatMath.FlashSafety.fieldFrame(channels: [red, darkBlue, darkBlue, darkBlue])
        XCTAssertEqual(field.x, red.x, accuracy: 1e-9)
        XCTAssertEqual(field.y, red.y, accuracy: 1e-9)
        XCTAssertTrue(field.isSaturatedRed,
                      "the lit channel decides the field's colour; the dark ones contribute none")
        let unweightedX = (red.x + 3 * darkBlue.x) / 4
        XCTAssertGreaterThan(abs(unweightedX - field.x), 0.2,
                             "an unweighted mean must be visibly different, or this proves nothing")
    }

    func testFieldFrameLuminanceIsExactNotApproximate() {
        // The inverse round-trip is what makes the reserved frame's own
        // luminance BE the field luminance rather than near it.
        let chans = [(x: 0.3127, y: 0.3290, brightness: 0.8),
                     (x: 0.675, y: 0.322, brightness: 0.35),
                     (x: 0.17, y: 0.70, brightness: 0.6)]
        let expected = chans
            .map { BeatMath.FlashSafety.WireFrame(x: $0.x, y: $0.y, brightness: $0.brightness) }
            .reduce(0.0) { $0 + $1.relativeLuminance } / 3.0
        XCTAssertEqual(BeatMath.FlashSafety.fieldFrame(channels: chans).relativeLuminance,
                       expected, accuracy: 1e-12)
    }

    func testInverseDimmingLuminanceRoundTrips() {
        for bri in stride(from: 0.0, through: 1.0, by: 0.01) {
            let round = BeatMath.FlashSafety.inverseDimmingLuminance(
                BeatMath.FlashSafety.dimmingLuminance(bri))
            XCTAssertEqual(round, bri, accuracy: 1e-9, "round trip failed at \(bri)")
        }
        // Totality: nothing traps, nothing escapes 0…1.
        for bad in [Double.nan, -.infinity, .infinity, -1, 2] {
            let v = BeatMath.FlashSafety.inverseDimmingLuminance(bad)
            XCTAssertTrue(v >= 0 && v <= 1, "inverse must stay in 0…1 for \(bad)")
        }
    }

    func testFieldFrameIsTotal() {
        XCTAssertEqual(BeatMath.FlashSafety.fieldFrame(channels: []).brightness, 0,
                       "a room with no channels puts no light in the field")
        let poisoned = [(x: Double.nan, y: 0.3, brightness: 0.5),
                        (x: 0.3, y: 0.3, brightness: .nan),
                        (x: .infinity, y: -.infinity, brightness: .infinity)]
        let field = BeatMath.FlashSafety.fieldFrame(channels: poisoned)
        XCTAssertTrue(field.x.isFinite && field.y.isFinite && field.brightness.isFinite,
                      "one corrupt channel may not poison the field frame")
        XCTAssertTrue(field.relativeLuminance.isFinite)
    }

    // ── The realized rate on the wire ──

    func testPulseAtTwoFortyBpmRealizesAboveThreeHzUngated() {
        // The defect, on the code this slice replaces. Without this the gated
        // test below could pass on a look that never flashed in the first place.
        let onsets = realizedOnsets(
            compositionWire(envelope: EnvelopeConfig(shape: .pulse, bpm: 240, depth: 100,
                                                     minBrightness: 0, maxBrightness: 100),
                            gated: false).wire)
        XCTAssertGreaterThan(onsets.count, 6, "a 4 Hz square wave must realize onsets to grade")
        XCTAssertLessThan(minimumGap(onsets) ?? .infinity,
                          BeatMath.FlashSafety.minOnsetLedgerPeriod,
                          "the ungated composition loop must breach the ceiling, or the fix is untested")
    }

    func testPulseAtTwoFortyBpmIsGatedToThreeHz() {
        let onsets = realizedOnsets(
            compositionWire(envelope: EnvelopeConfig(shape: .pulse, bpm: 240, depth: 100,
                                                     minBrightness: 0, maxBrightness: 100)).wire)
        assertOnsetsRespectTheFloor(onsets, label: "composition .pulse @ 240 bpm", atLeast: 3)
    }

    func testFlickerIsGatedToThreeHz() {
        // `.flicker`'s fastest component is independent of bpm, so the slowest
        // authored tempo does not make it safe.
        let onsets = realizedOnsets(
            compositionWire(envelope: EnvelopeConfig(shape: .flicker, bpm: 20, depth: 100,
                                                     minBrightness: 0, maxBrightness: 100),
                            seconds: 10).wire)
        assertOnsetsRespectTheFloor(onsets, label: "composition .flicker", atLeast: 1)
    }

    /// A wire that never moved satisfies any floor vacuously (review round,
    /// C-11): every shape here must actually MODULATE the wire.
    private func luminanceSpan(_ wire: [Emission]) -> Double {
        let lums = wire.map { $0.frame.relativeLuminance }
        guard let lo = lums.min(), let hi = lums.max() else { return 0 }
        return hi - lo
    }

    func testEveryAuthoredEnvelopeShapeAtEveryTempoRespectsTheFloor() {
        for shape in EnvelopeConfig.Shape.allCases {
            for bpm in [20.0, 60, 137, 180, 240] {
                let wire = compositionWire(envelope: EnvelopeConfig(shape: shape, bpm: bpm, depth: 100,
                                                                    minBrightness: 0, maxBrightness: 100),
                                           seconds: 8).wire
                if shape != .steady {
                    XCTAssertGreaterThan(luminanceSpan(wire), 0.1,
                        "\(shape) @ \(bpm): the gated wire never moved — a floor over a dark wire proves nothing")
                }
                assertOnsetsRespectTheFloor(realizedOnsets(wire), label: "\(shape) @ \(bpm) bpm", atLeast: 0)
            }
        }
    }

    func testAChasingPaletteAcrossManyChannelsRespectsTheFloor() {
        // Per-channel motion is the case the uniform gate could not have
        // expressed at all: eight lights chasing a spectrum at speed.
        for count in [1, 2, 8, 20] {
            let onsets = realizedOnsets(
                compositionWire(envelope: EnvelopeConfig(shape: .pulse, bpm: 240, depth: 100,
                                                         minBrightness: 0, maxBrightness: 100),
                                palette: PaletteConfig(mode: .spectrum),
                                motion: MotionConfig(pattern: .chase, speed: 100),
                                channels: count, seconds: 8).wire)
            assertOnsetsRespectTheFloor(onsets, label: "chase over \(count) channel(s)", atLeast: 0)
        }
    }

    func testADroppedSendDoesNotAdvanceTheCompositionOnset() {
        // A frame the transport refused changed no light, so it must not hold
        // the ledger's onset — the same wire-truth rule the uniform loops keep.
        let onsets = realizedOnsets(
            compositionWire(envelope: EnvelopeConfig(shape: .pulse, bpm: 240, depth: 100,
                                                     minBrightness: 0, maxBrightness: 100),
                            seconds: 8, dropWindow: 30..<45).wire)
        assertOnsetsRespectTheFloor(onsets, label: "composition across a dropped window", atLeast: 1)
    }

    func testARestartCannotFlashAcrossTheRunBoundary() {
        // Cross-run is the path with no frame plan behind it: stop, restart, and
        // the very first frame of the new run wants to be bright. One shared
        // model = one bridge whose ledger both runs reserve against.
        let shared = WireModel()
        _ = compositionWire(envelope: EnvelopeConfig(shape: .pulse, bpm: 240, depth: 100,
                                                     minBrightness: 0, maxBrightness: 100),
                            seconds: 3, model: shared)
        _ = compositionWire(envelope: EnvelopeConfig(shape: .pulse, bpm: 240, depth: 100,
                                                     minBrightness: 0, maxBrightness: 100),
                            seconds: 3, model: shared)
        assertOnsetsRespectTheFloor(realizedOnsets(shared.wire),
                                    label: "composition stop → restart", atLeast: 2)
    }

    func testACompositionAndAUniformLoopShareOneBridgeLedger() {
        // A composition failing over, or a Strobe starting on the same bridge,
        // must not get a fresh 0.34 s budget: one wire, one record of it.
        let shared = WireModel()
        shared.fd = 0.04
        let box = CompositionParamBox(
            palette: PaletteConfig(), motion: MotionConfig(pattern: .static),
            envelope: EnvelopeConfig(shape: .pulse, bpm: 240, depth: 100,
                                     minBrightness: 0, maxBrightness: 100),
            reaction: ReactionConfig())
        for i in 0..<75 {
            shared.emitComposition(
                compositionChannels(box: box, time: Double(i) * 0.04, channels: 4))
            // A uniform loop interleaving on the same bridge, asking to flash
            // white at full on every one of its own frames.
            shared.emitComposition([(x: 0.3127, y: 0.3290, brightness: 1.0)])
        }
        assertOnsetsRespectTheFloor(realizedOnsets(shared.wire),
                                    label: "composition + uniform on one bridge", atLeast: 2)
    }
}
