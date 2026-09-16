// Composer2LabLayerTests.swift
// ChromaGlow — Composer 2 lab. Motion, rhythm, masks and blending.

import XCTest
@testable import HueHome

final class Composer2LabLayerTests: XCTestCase {

    private let times: [Double] = [-1e6, -3.7, 0, 0.04, 1.5, 1e6]
    private let positions: [Double] = [0, 0.5, 1]

    // MARK: Motion

    func testPhaseAndWeightAreBoundedForEveryKindAndEdge() {
        for kind in Composer2Motion.Kind.allCases {
            for edge in Composer2Motion.Edge.allCases {
                for width in [0.05, 0.35, 1.0] {
                    var motion = Composer2Motion(kind: kind, periodSeconds: 5, travelWidth: width, steps: 3, edge: edge)
                    motion.mirror = edge == .bounce
                    for t in times {
                        for p in positions {
                            for slot in [0, 1, 6] {
                                let s = motion.sample(slot: slot, position: p, cross: 0.3, time: t, seed: 9)
                                XCTAssert(s.phase.isFinite && s.phase >= 0 && s.phase <= 1,
                                          "\(kind)/\(edge) phase \(s.phase) at t=\(t) p=\(p)")
                                XCTAssert(s.weight.isFinite && s.weight >= 0 && s.weight <= 1,
                                          "\(kind)/\(edge) weight \(s.weight) at t=\(t) p=\(p)")
                            }
                        }
                    }
                }
            }
        }
    }

    func testReverseMirrorsDirection() {
        var forward = Composer2Motion(kind: .flow, periodSeconds: 10)
        forward.spread = 1
        var reverse = forward
        reverse.reverse = true
        let f0 = forward.sample(slot: 0, position: 0.5, cross: 0.5, time: 0, seed: 1).phase
        let f1 = forward.sample(slot: 0, position: 0.5, cross: 0.5, time: 0.5, seed: 1).phase
        let r1 = reverse.sample(slot: 0, position: 0.5, cross: 0.5, time: 0.5, seed: 1).phase
        XCTAssertGreaterThan(f1, f0)
        XCTAssertLessThan(r1, f0)
    }

    func testMirrorIsSymmetric() {
        var motion = Composer2Motion(kind: .static)
        motion.mirror = true
        let a = motion.sample(slot: 0, position: 0.2, cross: 0.5, time: 3, seed: 1)
        let b = motion.sample(slot: 0, position: 0.8, cross: 0.5, time: 3, seed: 1)
        XCTAssertEqual(a.phase, b.phase, accuracy: 1e-12)
    }

    func testChaseStepsQuantizePhase() {
        let motion = Composer2Motion(kind: .chase, periodSeconds: 4, spread: 1, smoothness: 0, travelWidth: 1, steps: 3)
        var seen = Set<Int>()
        for t in stride(from: 0.0, to: 8.0, by: 0.05) {
            for p in stride(from: 0.0, through: 1.0, by: 0.125) {
                let phase = motion.sample(slot: 0, position: p, cross: 0.5, time: t, seed: 1).phase
                seen.insert(Int((phase * 1e6).rounded()))
            }
        }
        XCTAssertLessThanOrEqual(seen.count, 3, "chase with 3 steps produced \(seen.count) phases")
    }

    func testOrganicIsContinuousInTime() {
        let motion = Composer2Motion(kind: .organic, periodSeconds: 20, scale: 1)
        for t in stride(from: 0.0, to: 40.0, by: 0.9) {
            let a = motion.sample(slot: 2, position: 0.4, cross: 0.6, time: t, seed: 5).phase
            let b = motion.sample(slot: 2, position: 0.4, cross: 0.6, time: t + 0.02, seed: 5).phase
            let d = abs(a - b)
            XCTAssertLessThanOrEqual(min(d, 1 - d), 0.05)
        }
    }

    func testStaticIgnoresTime() {
        let motion = Composer2Motion(kind: .static, spread: 0.7)
        let a = motion.sample(slot: 0, position: 0.3, cross: 0.5, time: 0, seed: 1)
        let b = motion.sample(slot: 0, position: 0.3, cross: 0.5, time: 999, seed: 1)
        XCTAssertEqual(a.phase, b.phase)
        XCTAssertEqual(a.weight, 1)
    }

    func testMotionPeriodIsFlooredByTheFlashBudget() {
        let motion = Composer2Motion(kind: .flow, periodSeconds: 0.01)
        XCTAssertEqual(motion.sanitizedPeriod, BeatMath.FlashSafety.minOnsetLedgerPeriod, accuracy: 1e-12)
    }

    // MARK: Rhythm

    func testRhythmValueIsBoundedForEveryShape() {
        let extremes: [Double] = [-1, 0, 0.5, 1, 2]
        for shape in Composer2Rhythm.Shape.allCases {
            for attack in extremes {
                for depth in extremes {
                    let r = Composer2Rhythm(shape: shape, periodSeconds: 2, attack: attack, decay: 1 - attack,
                                            depth: depth, duty: attack, minBrightness: 0.9, maxBrightness: 0.2)
                    for t in times {
                        let v = r.value(cyclePhase: t / 2, time: t, slot: 3, seed: 4)
                        XCTAssert(v.isFinite && v >= 0 && v <= 1, "\(shape) value \(v)")
                    }
                }
            }
        }
    }

    func testRhythmPeriodFloorIsTheFlashLedgerPeriod() {
        let fast = Composer2Rhythm(shape: .pulse, periodSeconds: 0.05)
        XCTAssertEqual(fast.sanitizedPeriod, BeatMath.FlashSafety.minOnsetLedgerPeriod, accuracy: 1e-12)
        let heartbeat = Composer2Rhythm(shape: .heartbeat, periodSeconds: 0.05)
        XCTAssertEqual(heartbeat.sanitizedPeriod, BeatMath.FlashSafety.minOnsetLedgerPeriod * 2, accuracy: 1e-12)
    }

    func testFlickerCrossingsStayUnderThreeHertz() {
        let r = Composer2Rhythm(shape: .flicker, periodSeconds: 2, depth: 1, minBrightness: 0, maxBrightness: 1, flickerRate: 2.5)
        let dt = 0.04
        var values: [Double] = []
        for i in 0..<1500 {
            let t = Double(i) * dt
            values.append(r.value(cyclePhase: t / 2, time: t, slot: 0, seed: 77))
        }
        let mid = 0.5
        for start in stride(from: 0, to: values.count - 25, by: 5) {
            var crossings = 0
            for i in (start + 1)..<(start + 25) where values[i - 1] < mid && values[i] >= mid { crossings += 1 }
            XCTAssertLessThanOrEqual(crossings, 3, "flicker crossed \(crossings) times in one second")
        }
    }

    func testSwappedMinMaxSanitizes() {
        let r = Composer2Rhythm(shape: .steady, minBrightness: 0.9, maxBrightness: 0.3)
        XCTAssertEqual(r.range.hi, 0.9, accuracy: 1e-12)
        XCTAssertLessThanOrEqual(r.range.lo, r.range.hi)
    }

    // MARK: Mask

    private var line: Composer2SlotGeometry {
        Composer2SlotGeometry(points: (0..<8).map { (x: Double($0) / 7, z: 0.5) })
    }

    func testWholeRoomAndExplicitSlots() {
        XCTAssertEqual(Composer2LayerMask.wholeRoom.weights(geometry: line, seed: 1), Array(repeating: 1, count: 8))
        let picked = Composer2LayerMask.slots([1, 3, 99, -1]).weights(geometry: line, seed: 1)
        XCTAssertEqual(picked, [0, 1, 0, 1, 0, 0, 0, 0])
    }

    func testRandomSubsetIsExactAndDeterministic() {
        let a = Composer2LayerMask.randomCount(3).weights(geometry: line, seed: 5)
        let b = Composer2LayerMask.randomCount(3).weights(geometry: line, seed: 5)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.filter { $0 == 1 }.count, 3)
        let half = Composer2LayerMask.randomSubset(fraction: 0.5).weights(geometry: line, seed: 5)
        XCTAssertEqual(half.filter { $0 == 1 }.count, 4)
        XCTAssertEqual(Composer2LayerMask.randomCount(3).selectedCount(total: 8), 3)
    }

    func testRegionSelectsInsideAndFeatherIsMonotone() {
        var region = Composer2LayerMask(kind: .region, regionX0: 0.4, regionZ0: 0, regionX1: 0.7, regionZ1: 1)
        let hard = region.weights(geometry: line, seed: 1)
        XCTAssertEqual(hard, [0, 0, 0, 1, 1, 0, 0, 0])
        region.feather = 0.6
        let soft = region.weights(geometry: line, seed: 1)
        XCTAssertGreaterThanOrEqual(soft[3], soft[2])
        XCTAssertGreaterThanOrEqual(soft[2], soft[1])
        XCTAssertGreaterThanOrEqual(soft[4], soft[5])
        region.invert = true
        let inverted = region.weights(geometry: line, seed: 1)
        for (s, i) in zip(soft, inverted) { XCTAssertEqual(s + i, 1, accuracy: 1e-12) }
    }

    func testLightIDsWithoutMapFallsBackToWholeRoom() {
        let mask = Composer2LayerMask(kind: .lightIDs, lightIDs: ["a", "b"])
        XCTAssertEqual(mask.weights(geometry: line, seed: 1), Array(repeating: 1, count: 8))
        let named = line.withLightIDs((0..<8).map { "L\($0)" })
        let picked = Composer2LayerMask(kind: .lightIDs, lightIDs: ["L2", "L5"]).weights(geometry: named, seed: 1)
        XCTAssertEqual(picked, [0, 0, 1, 0, 0, 1, 0, 0])
    }

    // MARK: Blend

    func testBlendSemantics() {
        let red = Composer2ColorMath.lab(fromXY: Composer2XY(x: 0.64, y: 0.32))
        var acc = Composer2Blend.Accum()
        Composer2Blend.composite(&acc, lab: red, brightness: 0.8, coverage: 1, mode: .replace)
        XCTAssertEqual(acc.brightness, 0.8)
        XCTAssertEqual(acc.lab, red)

        var untouched = acc
        Composer2Blend.composite(&untouched, lab: .d65, brightness: 1, coverage: 0, mode: .replace)
        XCTAssertEqual(untouched, acc)

        var added = acc
        Composer2Blend.composite(&added, lab: .d65, brightness: 0.9, coverage: 1, mode: .addLighten)
        XCTAssertEqual(added.brightness, 1)

        var kept = acc
        Composer2Blend.composite(&kept, lab: .d65, brightness: 0.2, coverage: 1, mode: .maxBrightness)
        XCTAssertEqual(kept.brightness, 0.8)
        XCTAssertEqual(kept.lab, red)

        var overBlack = Composer2Blend.Accum()
        Composer2Blend.composite(&overBlack, lab: red, brightness: 1, coverage: 0.5, mode: .replace)
        XCTAssertEqual(overBlack.brightness, 0.5, accuracy: 1e-12)
    }
}
