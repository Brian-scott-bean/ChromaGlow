// Composer2LabEventTests.swift
// ChromaGlow — Composer 2 lab. The seeded event generator.

import XCTest
@testable import HueHome

final class Composer2LabEventTests: XCTestCase {

    private var geometry: Composer2SlotGeometry {
        Composer2SlotGeometry(points: (0..<6).map { (x: Double($0) / 5, z: 0.5) })
    }

    /// A spec whose events are over almost instantly, so scheduling is the only thing measured.
    private func quick(_ mutate: (inout Composer2EventSpec) -> Void = { _ in }) -> Composer2EventSpec {
        var s = Composer2EventSpec(timing: .random, minDelay: 4, maxDelay: 14, probability: 1,
                                   burstMin: 1, burstMax: 1, spacingMin: 0.02, spacingMax: 0.02,
                                   durationMin: 0.01, durationMax: 0.01, decaySeconds: 0.01)
        mutate(&s)
        return s
    }

    /// Steps the generator and records each fired event's scheduled start.
    private func run(_ spec: Composer2EventSpec, seed: UInt64 = 1, duration: Double, dt: Double = 0.04,
                     timing: Double = 1, boost: Double = 0, geometry g: Composer2SlotGeometry? = nil)
        -> (starts: [Double], state: Composer2EventState) {
        let geo = g ?? geometry
        var state = Composer2EventState.initial(spec: spec, eventSeed: seed, startTime: 0, timingVariation: timing)
        var starts: [Double] = []
        var lastIndex = -1
        var t = 0.0
        while t <= duration {
            state.advance(to: t, spec: spec, eventSeed: seed, geometry: geo, timingVariation: timing, probabilityBoost: boost)
            if let e = state.current, e.index != lastIndex {
                lastIndex = e.index
                starts.append(e.start)
            }
            t += dt
        }
        return (starts, state)
    }

    func testRandomIntervalStaysInConfiguredRange() {
        let spec = quick()
        let starts = run(spec, duration: 3000).starts
        XCTAssertGreaterThan(starts.count, 150)
        for (a, b) in zip(starts, starts.dropFirst()) {
            let d = b - a
            XCTAssertGreaterThanOrEqual(d, 4 - 1e-9)
            XCTAssertLessThanOrEqual(d, 14 + 1e-9)
        }
    }

    func testFixedIntervalIsExact() {
        let spec = quick { $0.timing = .fixed; $0.interval = 2.5 }
        let starts = run(spec, duration: 200).starts
        for (a, b) in zip(starts, starts.dropFirst()) { XCTAssertEqual(b - a, 2.5, accuracy: 1e-9) }
    }

    func testTimingVariationZeroGivesMidpoint() {
        let starts = run(quick(), duration: 300, timing: 0).starts
        for (a, b) in zip(starts, starts.dropFirst()) { XCTAssertEqual(b - a, 9, accuracy: 1e-9) }
    }

    func testProbabilityBounds() {
        let never = run(quick { $0.probability = 0 }, duration: 600).state
        XCTAssertEqual(never.firedCount, 0)
        XCTAssertGreaterThan(never.opportunityIndex, 40)
        let always = run(quick { $0.probability = 1 }, duration: 600).state
        XCTAssertEqual(always.firedCount, always.opportunityIndex)
    }

    func testProbabilityHalfIsStatisticallySane() {
        let spec = quick { $0.probability = 0.5; $0.minDelay = 1; $0.maxDelay = 1.5 }
        let state = run(spec, duration: 2600, dt: 0.1).state
        XCTAssertGreaterThan(state.opportunityIndex, 1900)
        let ratio = Double(state.firedCount) / Double(state.opportunityIndex)
        XCTAssertGreaterThan(ratio, 0.42)
        XCTAssertLessThan(ratio, 0.58)
    }

    func testBurstSpacingHoldAndIntensityStayInRange() {
        let spec = Composer2EventSpec(timing: .fixed, interval: 6, probability: 1, burstMin: 2, burstMax: 4,
                                      spacingMin: 0.3, spacingMax: 0.5, durationMin: 0.05, durationMax: 0.1,
                                      decaySeconds: 0.2, intensityMin: 0.6, intensityMax: 0.9)
        var state = Composer2EventState.initial(spec: spec, eventSeed: 3, startTime: 0)
        var inspected = 0
        var lastIndex = -1
        for i in 0..<5000 {
            let t = Double(i) * 0.04
            state.advance(to: t, spec: spec, eventSeed: 3, geometry: geometry)
            guard let e = state.current, e.index != lastIndex else { continue }
            lastIndex = e.index
            inspected += 1
            XCTAssert((2...4).contains(e.flashes.count))
            for f in e.flashes {
                XCTAssertGreaterThanOrEqual(f.holdEnd - f.start, 0.05 - 1e-9)
                XCTAssertLessThanOrEqual(f.holdEnd - f.start, 0.1 + 1e-9)
                XCTAssertGreaterThanOrEqual(f.intensity, 0.6)
                XCTAssertLessThanOrEqual(f.intensity, 0.9)
            }
            for (a, b) in zip(e.flashes, e.flashes.dropFirst()) {
                XCTAssertGreaterThanOrEqual(b.start - a.holdEnd, 0.3 - 1e-9)
                XCTAssertLessThanOrEqual(b.start - a.holdEnd, 0.5 + 1e-9)
            }
        }
        XCTAssertGreaterThan(inspected, 20)
    }

    func testCooldownPushesNextOpportunity() {
        let spec = quick { $0.minDelay = 1; $0.maxDelay = 2; $0.cooldown = 5 }
        let starts = run(spec, duration: 400).starts
        XCTAssertGreaterThan(starts.count, 20)
        for (a, b) in zip(starts, starts.dropFirst()) { XCTAssertGreaterThanOrEqual(b - a, 5 - 1e-9) }
    }

    func testSameSeedSameScheduleAndFrameRateIndependence() {
        let spec = quick()
        let a = run(spec, seed: 9, duration: 500, dt: 0.04).starts
        let b = run(spec, seed: 9, duration: 500, dt: 0.04).starts
        let c = run(spec, seed: 9, duration: 500, dt: 0.125).starts
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, c)
        XCTAssertNotEqual(a, run(spec, seed: 10, duration: 500).starts)
    }

    func testAudioBoostDoesNotChangeDrawCount() {
        let spec = quick { $0.probability = 0.3 }
        let plain = run(spec, seed: 4, duration: 800).state
        let boosted = run(spec, seed: 4, duration: 800, boost: 0.5).state
        XCTAssertEqual(plain.opportunityIndex, boosted.opportunityIndex)
        XCTAssertEqual(plain.schedule, boosted.schedule)
        XCTAssertGreaterThan(boosted.firedCount, plain.firedCount)
    }

    func testMajorStrikeTargetsEveryLight() {
        let spec = quick { $0.majorProbability = 1; $0.targeting = .randomCount; $0.targetCount = 1; $0.burstMax = 3 }
        var state = Composer2EventState.initial(spec: spec, eventSeed: 1, startTime: 0)
        state.advance(to: 20, spec: spec, eventSeed: 1, geometry: geometry)
        let e = try! XCTUnwrap(state.current)
        XCTAssertTrue(e.isMajor)
        XCTAssertEqual(e.targets, Array(repeating: 1, count: 6))
        XCTAssertEqual(e.flashes.count, 3)
    }

    func testRandomCountSelectsExactlyN() {
        let spec = quick { $0.targeting = .randomCount; $0.targetCount = 2 }
        var state = Composer2EventState.initial(spec: spec, eventSeed: 2, startTime: 0)
        state.advance(to: 20, spec: spec, eventSeed: 2, geometry: geometry)
        let e = try! XCTUnwrap(state.current)
        XCTAssertEqual(e.targets.filter { $0 == 1 }.count, 2)
        XCTAssertEqual(e.targets.filter { $0 == 0 }.count, 4)
    }

    func testSpatialBiasFavoursNeighbours() {
        let spec = quick { $0.targeting = .spatialBiased; $0.spatialBias = 0.8 }
        var state = Composer2EventState.initial(spec: spec, eventSeed: 5, startTime: 0)
        state.advance(to: 20, spec: spec, eventSeed: 5, geometry: geometry)
        let e = try! XCTUnwrap(state.current)
        let focus = try! XCTUnwrap(e.targets.firstIndex(of: 1))
        for near in [focus - 1, focus + 1] where near >= 0 && near < 6 {
            for far in [focus - 3, focus + 3] where far >= 0 && far < 6 {
                XCTAssertGreaterThan(e.targets[near], e.targets[far])
            }
        }
    }

    func testOneLightRoomAndZeroSlots() {
        let one = Composer2SlotGeometry.linear(count: 1)
        for targeting in Composer2EventSpec.Targeting.allCases {
            let spec = quick { $0.targeting = targeting; $0.targetCount = 3 }
            var state = Composer2EventState.initial(spec: spec, eventSeed: 1, startTime: 0)
            state.advance(to: 20, spec: spec, eventSeed: 1, geometry: one)
            XCTAssertEqual(state.current?.targets, [1])
        }
        let none = Composer2SlotGeometry.linear(count: 0)
        var state = Composer2EventState.initial(spec: quick(), eventSeed: 1, startTime: 0)
        state.advance(to: 20, spec: quick(), eventSeed: 1, geometry: none)
        XCTAssertEqual(state.sample(slot: 0, time: 20), 0)
    }

    func testTargetsRebuildOnSlotCountChange() {
        let spec = quick { $0.targeting = .randomCount; $0.targetCount = 2; $0.durationMax = 5; $0.decaySeconds = 2 }
        var state = Composer2EventState.initial(spec: spec, eventSeed: 2, startTime: 0)
        state.advance(to: 20, spec: spec, eventSeed: 2, geometry: geometry)
        XCTAssertEqual(state.current?.targets.count, 6)
        state.rebuildTargets(geometry: .linear(count: 9), eventSeed: 2, spec: spec)
        XCTAssertEqual(state.current?.targets.count, 9)
    }

    func testEnvelopeDecaysMonotonicallyAfterHold() {
        let spec = Composer2EventSpec(timing: .fixed, interval: 10, probability: 1, burstMin: 1, burstMax: 1,
                                      durationMin: 0.1, durationMax: 0.1, decaySeconds: 0.5)
        var state = Composer2EventState.initial(spec: spec, eventSeed: 1, startTime: 0)
        state.advance(to: 10.05, spec: spec, eventSeed: 1, geometry: geometry)
        let e = try! XCTUnwrap(state.current)
        let hold = e.flashes[0].holdEnd
        var previous = e.envelope(at: hold)
        XCTAssertGreaterThan(previous, 0.5)
        var t = hold
        while t < e.end {
            let v = e.envelope(at: t)
            XCTAssertLessThanOrEqual(v, previous + 1e-12)
            previous = v
            t += 0.02
        }
    }

    func testMinGreaterThanMaxRangesAreSanitized() {
        let spec = Composer2EventSpec(minDelay: 14, maxDelay: 4, burstMin: 5, burstMax: 2,
                                      spacingMin: 1, spacingMax: 0.5, intensityMin: 0.9, intensityMax: 0.1).sanitized
        XCTAssertEqual(spec.minDelay, 4)
        XCTAssertEqual(spec.maxDelay, 14)
        XCTAssertEqual(spec.burstMin, 2)
        XCTAssertEqual(spec.burstMax, 5)
        XCTAssertEqual(spec.spacingMin, 0.5)
        XCTAssertEqual(spec.intensityMin, 0.1)
    }

    func testResumeAfterLongGapReanchorsWithoutReplaying() {
        let spec = quick { $0.minDelay = 1; $0.maxDelay = 1.5 }
        var state = Composer2EventState.initial(spec: spec, eventSeed: 1, startTime: 0)
        state.advance(to: 5, spec: spec, eventSeed: 1, geometry: geometry)
        let before = state.firedCount
        state.advance(to: 605, spec: spec, eventSeed: 1, geometry: geometry)
        XCTAssertLessThanOrEqual(state.firedCount - before, 2)
        XCTAssertGreaterThanOrEqual(state.nextOpportunity, 605)
    }
}
