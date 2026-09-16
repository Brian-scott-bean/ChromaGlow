// Composer2LabPrimitiveTests.swift
// ChromaGlow — Composer 2 lab. Seeded randomness, noise, colour math, geometry.
// Deterministic and hermetic: no bridge, no timing, no storage.

import XCTest
@testable import HueHome

final class Composer2LabPrimitiveTests: XCTestCase {

    // MARK: RNG

    func testSameSeedSameStream() {
        var a = Composer2Rng(seed: 12345), b = Composer2Rng(seed: 12345)
        for _ in 0..<1000 { XCTAssertEqual(a.next(), b.next()) }
    }

    func testDifferentSeedsDiffer() {
        var a = Composer2Rng(seed: 1), b = Composer2Rng(seed: 2)
        var same = 0
        for _ in 0..<100 where a.next() == b.next() { same += 1 }
        XCTAssertLessThan(same, 3)
    }

    func testSeedZeroAndMaxProduceNonDegenerateStreams() {
        for seed in [UInt64(0), UInt64.max] {
            var rng = Composer2Rng(seed: seed)
            var deciles = Set<Int>()
            var previous = rng.nextUnit()
            var repeats = 0
            for _ in 0..<1000 {
                let u = rng.nextUnit()
                if u == previous { repeats += 1 }
                deciles.insert(Int(u * 10))
                previous = u
            }
            XCTAssertEqual(repeats, 0, "seed \(seed) repeats values")
            XCTAssertGreaterThanOrEqual(deciles.count, 9, "seed \(seed) does not spread")
        }
    }

    func testUnitIsInHalfOpenRange() {
        var rng = Composer2Rng(seed: 99)
        for _ in 0..<5000 {
            let u = rng.nextUnit()
            XCTAssertGreaterThanOrEqual(u, 0)
            XCTAssertLessThan(u, 1)
        }
    }

    func testNextIntStaysInRangeIncludingSingletons() {
        var rng = Composer2Rng(seed: 7)
        for _ in 0..<200 { XCTAssertEqual(rng.nextInt(in: 3...3), 3) }
        var seen = Set<Int>()
        for _ in 0..<500 {
            let v = rng.nextInt(in: -2...4)
            XCTAssert((-2...4).contains(v))
            seen.insert(v)
        }
        XCTAssertEqual(seen.count, 7)
    }

    func testHashIsStableAndSaltSeparates() {
        XCTAssertEqual(Composer2Hash.unit(5, 3, 4, salt: 1), Composer2Hash.unit(5, 3, 4, salt: 1))
        var different = 0
        for i in 0..<100 where Composer2Hash.unit(5, i, 0, salt: 1) != Composer2Hash.unit(5, i, 0, salt: 2) {
            different += 1
        }
        XCTAssertGreaterThan(different, 95)
    }

    func testSeedFromUUIDIsStableAndDistinct() {
        let a = UUID(uuidString: "0000000C-0002-0002-0002-000000000001")!
        let b = UUID(uuidString: "0000000C-0002-0002-0002-000000000002")!
        XCTAssertEqual(Composer2Hash.seed(from: a), Composer2Hash.seed(from: UUID(uuidString: a.uuidString)!))
        XCTAssertNotEqual(Composer2Hash.seed(from: a), Composer2Hash.seed(from: b))
    }

    // MARK: Noise

    func testNoiseStaysInUnitIntervalForAnyInput() {
        let inputs: [Double] = [-1e12, -3.7, 0, 0.5, 1e12, .nan, .infinity, -.infinity]
        for x in inputs {
            for y in inputs {
                let v1 = Composer2Noise.value1D(x, seed: 3)
                let v2 = Composer2Noise.value2D(x, y, seed: 3)
                let f = Composer2Noise.fbm2D(x, y, seed: 3)
                for v in [v1, v2, f] {
                    XCTAssert(v.isFinite && v >= 0 && v <= 1, "noise out of range for \(x),\(y): \(v)")
                }
            }
        }
    }

    func testNoiseIsContinuous() {
        var x = -20.0
        while x < 20 {
            let a = Composer2Noise.value1D(x, seed: 11), b = Composer2Noise.value1D(x + 0.005, seed: 11)
            XCTAssertLessThanOrEqual(abs(a - b), 0.03)
            let c = Composer2Noise.fbm2D(x, 0.3, seed: 11), d = Composer2Noise.fbm2D(x + 0.005, 0.3, seed: 11)
            XCTAssertLessThanOrEqual(abs(c - d), 0.04)
            x += 0.37
        }
    }

    func testNoiseIsDeterministic() {
        XCTAssertEqual(Composer2Noise.value2D(3.25, -7.5, seed: 42), Composer2Noise.value2D(3.25, -7.5, seed: 42))
        XCTAssertNotEqual(Composer2Noise.value2D(3.25, -7.5, seed: 42), Composer2Noise.value2D(3.25, -7.5, seed: 43))
    }

    // MARK: Colour

    private func assertInsideGamutC(_ xy: Composer2XY, _ message: String = "", tolerance: Double = 1e-9,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let c = HueColorUtils.clampXYToGamut(x: xy.x, y: xy.y, gamut: .c)
        XCTAssertEqual(c.x, xy.x, accuracy: tolerance, "x outside gamut C \(message)", file: file, line: line)
        XCTAssertEqual(c.y, xy.y, accuracy: tolerance, "y outside gamut C \(message)", file: file, line: line)
    }

    private let eightStops: [Composer2XY] = [
        Composer2XY(x: 0.64, y: 0.32), Composer2XY(x: 0.56, y: 0.40), Composer2XY(x: 0.45, y: 0.47),
        Composer2XY(x: 0.30, y: 0.55), Composer2XY(x: 0.21, y: 0.42), Composer2XY(x: 0.18, y: 0.20),
        Composer2XY(x: 0.25, y: 0.13), Composer2XY(x: 0.40, y: 0.18)
    ]

    func testPaletteEndpointsMatchStops() {
        for style in Composer2ColorSource.Interpolation.allCases {
            var source = Composer2ColorSource.stops(eightStops, interpolation: style)
            source.cycle = false
            let palette = Composer2CompiledPalette(source)
            for (i, pos) in palette.positions.enumerated() {
                let sample = palette.sampleXY(pos)
                XCTAssertEqual(sample.x, eightStops[i].x, accuracy: 2e-3, "\(style) stop \(i)")
                XCTAssertEqual(sample.y, eightStops[i].y, accuracy: 2e-3, "\(style) stop \(i)")
            }
        }
    }

    func testLinearMidpointIsChromaticityMidpoint() {
        let a = Composer2XY(x: 0.64, y: 0.32), b = Composer2XY(x: 0.21, y: 0.42)
        var source = Composer2ColorSource.stops([a, b], interpolation: .linear)
        source.cycle = false
        let mid = Composer2CompiledPalette(source).sampleXY(0.5)
        XCTAssertEqual(mid.x, (a.x + b.x) / 2, accuracy: 2e-3)
        XCTAssertEqual(mid.y, (a.y + b.y) / 2, accuracy: 2e-3)
    }

    func testHueArcMidpointKeepsChroma() {
        let red = Composer2XY(x: 0.64, y: 0.32), yellow = Composer2XY(x: 0.45, y: 0.47)
        var source = Composer2ColorSource.stops([red, yellow], interpolation: .hueArc)
        source.cycle = false
        let palette = Composer2CompiledPalette(source)
        let mid = palette.sample(0.5)
        let minChroma = min(Composer2ColorMath.lab(fromXY: red).chroma, Composer2ColorMath.lab(fromXY: yellow).chroma)
        XCTAssertGreaterThanOrEqual(mid.chroma, minChroma * 0.8, "midpoint went grey")
    }

    func testHueArcThroughWhiteDoesNotSpinHue() {
        let red = Composer2ColorMath.lab(fromXY: Composer2XY(x: 0.64, y: 0.32))
        let white = Composer2ColorMath.lab(fromXY: .d65)
        let mid = Composer2ColorMath.mixHueArc(red, white, t: 0.5)
        // Same hue direction as red: the a/b vector points the same way.
        XCTAssertGreaterThan(mid.a * red.a + mid.b * red.b, 0)
    }

    func testEveryStyleStaysInsideGamutC() {
        for style in Composer2ColorSource.Interpolation.allCases {
            var source = Composer2ColorSource.stops(eightStops, interpolation: style)
            source.saturation = 1.4
            source.warmth = -0.5
            let palette = Composer2CompiledPalette(source)
            for i in 0..<512 {
                assertInsideGamutC(palette.sampleXY(Double(i) / 511), "\(style) t=\(i)")
            }
        }
    }

    func testEmptyPaletteFallsBackToWhiteAndSingleStopIsSolid() {
        let empty = Composer2CompiledPalette(Composer2ColorSource(stops: []))
        XCTAssertEqual(empty.sampleXY(0.3).x, Composer2XY.d65.x, accuracy: 1e-3)
        let solid = Composer2CompiledPalette(Composer2ColorSource.solid(Composer2XY(x: 0.5, y: 0.4)))
        for t in stride(from: 0.0, through: 1.0, by: 0.1) {
            XCTAssertEqual(solid.sampleXY(t).x, 0.5, accuracy: 2e-3)
            XCTAssertEqual(solid.sampleXY(t).y, 0.4, accuracy: 2e-3)
        }
    }

    func testStoppedPaletteHasExactlyNColours() {
        let source = Composer2ColorSource.stops(Array(eightStops.prefix(3)), interpolation: .stepped)
        let palette = Composer2CompiledPalette(source)
        var seen = Set<String>()
        for i in 0..<300 {
            let xy = palette.sampleXY(Double(i) / 299)
            seen.insert(String(format: "%.4f,%.4f", xy.x, xy.y))
        }
        XCTAssertEqual(seen.count, 3)
    }

    func testCyclingPaletteGivesEveryStopASegment() {
        let ring = Composer2CompiledPalette(Composer2ColorSource.stops(Array(eightStops.prefix(4)), interpolation: .stepped))
        XCTAssertEqual(ring.positions, [0, 0.25, 0.5, 0.75])
        XCTAssertEqual(ring.sampleXY(0.9).x, eightStops[3].x, accuracy: 2e-3)
        XCTAssertEqual(ring.sampleXY(1.0).x, eightStops[0].x, accuracy: 2e-3, "phase 1 wraps to the first stop")
    }

    func testMoreThanEightStopsAreTruncated() {
        let many = (0..<12).map { _ in Composer2PaletteStop(x: 0.3, y: 0.3) }
        XCTAssertEqual(Composer2ColorSource(stops: many).sanitizedStops.count, 8)
    }

    func testLabRoundTripIsClose() {
        for xy in eightStops + [.d65, .warmWhite] {
            let back = Composer2ColorMath.xy(fromLab: Composer2ColorMath.lab(fromXY: xy))
            XCTAssertEqual(back.x, xy.x, accuracy: 1e-3)
            XCTAssertEqual(back.y, xy.y, accuracy: 1e-3)
        }
    }

    // MARK: Geometry

    func testReconstructionRecoversPrincipalAxisOrder() {
        let points = (0..<6).map { (x: Double($0) * 0.4 - 1, z: 0.1 * sin(Double($0))) }
        let direct = Composer2SlotGeometry(points: points)
        XCTAssertTrue(direct.hasSpatialData)
        let projection = direct.projection(kind: .principal, angleDegrees: 0)
        let ordered = projection.sorted() == projection || projection.sorted() == projection.reversed()
        XCTAssertTrue(ordered, "principal projection must preserve the line's order: \(projection)")

        // The orchestrator hands the runtime radial/angular arrays only.
        let rebuilt = Composer2SlotGeometry(radial: direct.radial, angular: direct.angular)
        XCTAssertTrue(rebuilt.hasSpatialData)
        let rebuiltProjection = rebuilt.projection(kind: .principal, angleDegrees: 0)
        for (a, b) in zip(projection, rebuiltProjection) { XCTAssertEqual(a, b, accuracy: 0.02) }
    }

    func testDegenerateGeometryFallsBackToIndex() {
        let same = Composer2SlotGeometry(points: Array(repeating: (x: 0.3, z: 0.3), count: 4))
        XCTAssertFalse(same.hasSpatialData)
        XCTAssertEqual(same.projection(kind: .angle, angleDegrees: 45), same.linearIndex)
        let centred = Composer2SlotGeometry(radial: [0.5, 0.5, 0.5], angular: [0.5, 0.5, 0.5])
        XCTAssertFalse(centred.hasSpatialData)
        XCTAssertEqual(centred.count, 3)
    }

    func testOneAndZeroSlots() {
        let one = Composer2SlotGeometry(points: [(x: 3, z: 4)])
        XCTAssertEqual(one.count, 1)
        XCTAssertEqual(one.linearIndex, [0.5])
        let zero = Composer2SlotGeometry.linear(count: 0)
        XCTAssertEqual(zero.count, 0)
        XCTAssertTrue(zero.projection(kind: .radial, angleDegrees: 0).isEmpty)
    }
}
