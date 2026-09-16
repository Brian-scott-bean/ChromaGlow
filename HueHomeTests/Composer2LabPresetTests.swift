// Composer2LabPresetTests.swift
// ChromaGlow — Composer 2 lab. The five demonstration compositions: identity,
// gamut, legal output, spread across lights, and the 3 Hz photosensitivity
// limit measured the same way PresetCatalogTests measures the legacy catalog.

import XCTest
@testable import HueHome

@MainActor
final class Composer2LabPresetTests: XCTestCase {

    private let presets = Composer2PresetLibrary.all

    private func geometry(_ n: Int) -> Composer2SlotGeometry {
        var points: [(x: Double, z: Double)] = []
        let denominator = Double(max(1, n - 1))
        for i in 0..<n {
            let x: Double = Double(i) / denominator
            let z: Double = 0.4 + 0.2 * Double(i % 3)
            points.append((x: x, z: z))
        }
        return Composer2SlotGeometry(points: points)
    }

    func testFiveUniqueDeterministicIDs() throws {
        XCTAssertEqual(presets.count, 5)
        let ids = presets.map(\.id.uuidString)
        XCTAssertEqual(Set(ids).count, 5)
        let pattern = try NSRegularExpression(pattern: "^0000000C-0002-0002-0002-[0-9]{12}$")
        for id in ids {
            XCTAssertNotNil(pattern.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)), id)
        }
        var layerIDs = Set<UUID>()
        for p in presets {
            XCTAssertTrue(p.isBuiltIn)
            XCTAssertFalse(p.name.isEmpty)
            XCTAssertFalse(p.subtitle.isEmpty)
            XCTAssertTrue(p.hasVisibleOutput)
            for l in p.layers { XCTAssertTrue(layerIDs.insert(l.id).inserted, "layer id reused: \(l.name)") }
        }
        XCTAssertEqual(presets.map(\.name), ["Aurora Drift", "Lava Lamp", "Christmas Chase", "Haunted House", "Thunderstorm"])
    }

    func testBuiltInsAreStableValues() throws {
        XCTAssertEqual(Composer2PresetLibrary.auroraDrift, Composer2PresetLibrary.all[0])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for p in presets {
            let decoded = try decoder.decode(Composer2Composition.self, from: try encoder.encode(p))
            XCTAssertEqual(decoded, p, p.name)
        }
    }

    func testEveryStopAndFlashColourIsInsideGamutC() {
        for p in presets {
            for layer in p.layers {
                for stop in layer.color.stops {
                    let c = HueColorUtils.clampXYToGamut(x: stop.x, y: stop.y, gamut: .c)
                    XCTAssertEqual(c.x, stop.x, accuracy: 1e-12, "\(p.name)/\(layer.name) stop outside gamut C")
                    XCTAssertEqual(c.y, stop.y, accuracy: 1e-12, "\(p.name)/\(layer.name) stop outside gamut C")
                }
                if let flash = layer.events?.color {
                    let c = HueColorUtils.clampXYToGamut(x: flash.x, y: flash.y, gamut: .c)
                    XCTAssertEqual(c.x, flash.x, accuracy: 1e-12, "\(p.name)/\(layer.name) flash colour")
                    XCTAssertEqual(c.y, flash.y, accuracy: 1e-12, "\(p.name)/\(layer.name) flash colour")
                }
            }
        }
    }

    func testEveryPresetRendersLegalFramesAtEveryRoomSize() {
        for p in presets {
            for n in [1, 5, 20] {
                var state = Composer2EngineState()
                for i in 0..<100 {
                    let frames = Composer2Engine.evaluate(p, time: Double(i) * 0.04, geometry: geometry(n), state: &state)
                    XCTAssertEqual(frames.count, n)
                    for f in frames {
                        XCTAssertTrue(f.isValid, "\(p.name) n=\(n) frame \(i): \(f)")
                        let c = HueColorUtils.clampXYToGamut(x: f.x, y: f.y, gamut: .c)
                        XCTAssertEqual(c.x, f.x, accuracy: 1e-9, "\(p.name) outside gamut C")
                        XCTAssertEqual(c.y, f.y, accuracy: 1e-9, "\(p.name) outside gamut C")
                    }
                }
            }
        }
    }

    /// The catalog's method: rising crossings of each light's own midpoint,
    /// ignoring shallow ripple, in every one-second window — plus the same
    /// rule for the room field the flash gate measures.
    func testNoPresetFlashesFasterThanThreeHertzInAnyOneSecondWindow() {
        let duration = 60.0
        let fps = 25.0
        let window = Int(fps)
        var measuredLights = 0
        for p in presets {
            var state = Composer2EngineState()
            let g = geometry(5)
            var series: [[Double]] = Array(repeating: [], count: 5)
            var field: [Double] = []
            for step in 0..<Int(duration * fps) {
                let frames = Composer2Engine.evaluate(p, time: Double(step) / fps, geometry: g, state: &state)
                for (i, f) in frames.enumerated() { series[i].append(f.brightness) }
                field.append(frames.reduce(0.0) { $0 + $1.brightness } / Double(frames.count))
            }
            for (light, samples) in (series + [field]).enumerated() {
                guard let low = samples.min(), let high = samples.max(), high - low > 0.25 else { continue }
                if light < 5 { measuredLights += 1 }
                let mid = (low + high) / 2
                var start = 0
                while start + window <= samples.count {
                    var flashes = 0
                    for i in (start + 1)..<(start + window) where samples[i - 1] < mid && samples[i] >= mid { flashes += 1 }
                    XCTAssertLessThanOrEqual(flashes, 3,
                        "\(p.name) \(light == 5 ? "room field" : "light \(light)") flashed \(flashes)× in the second starting at \(Double(start) / fps) s")
                    start += 5
                }
            }
        }
        XCTAssertGreaterThanOrEqual(measuredLights, 5, "the flash-rate check measured only \(measuredLights) lights — vacuous")
    }

    func testLightningSpacingRespectsTheFlashLedger() throws {
        let lightning = try XCTUnwrap(Composer2PresetLibrary.thunderstorm.layers.first { $0.name == "Lightning" })
        let spec = try XCTUnwrap(lightning.events).sanitized
        XCTAssertGreaterThanOrEqual(spec.spacingMin, BeatMath.FlashSafety.minOnsetLedgerPeriod - 1e-12)
        XCTAssertEqual(spec.timing, .random)
        XCTAssertLessThan(spec.minDelay, spec.maxDelay)
        XCTAssertGreaterThan(spec.majorProbability, 0)
    }

    func testMovingPresetsSpreadAcrossLights() {
        for p in [Composer2PresetLibrary.auroraDrift, Composer2PresetLibrary.lavaLamp, Composer2PresetLibrary.christmasChase] {
            var state = Composer2EngineState()
            var spread = 0.0
            for i in 0..<100 {
                let frames = Composer2Engine.evaluate(p, time: Double(i) * 0.08, geometry: geometry(5), state: &state)
                for a in frames { for b in frames { spread = max(spread, hypot(a.x - b.x, a.y - b.y)) } }
            }
            XCTAssertGreaterThan(spread, 0.02, "\(p.name) shows the same colour on every light")
        }
    }

    func testPresetsExposeTheirHeadlineControls() throws {
        let chase = try XCTUnwrap(Composer2PresetLibrary.christmasChase.layers.first)
        XCTAssertEqual(chase.motion.kind, .chase)
        XCTAssertEqual(chase.motion.steps, 3)
        XCTAssertEqual(chase.color.stops.count, 3)
        XCTAssertEqual(chase.color.interpolation, .stepped)
        XCTAssertNotNil(Composer2PresetLibrary.christmasChase.layers.first { $0.events != nil }, "sparkle layer")

        let aurora = try XCTUnwrap(Composer2PresetLibrary.auroraDrift.layers.first)
        XCTAssertEqual(aurora.motion.kind, .organic)
        XCTAssertEqual(aurora.motion.axisKind, .principal)
        XCTAssertGreaterThan(aurora.variation.amount, 0)
        XCTAssertEqual(aurora.rhythm.shape, .breathe)

        XCTAssertEqual(Composer2PresetLibrary.hauntedHouse.layers.count, 4)
        XCTAssertTrue(Composer2PresetLibrary.hauntedHouse.layers.contains { $0.rhythm.shape == .flicker })
        XCTAssertTrue(Composer2PresetLibrary.hauntedHouse.layers.contains { $0.events != nil })
        XCTAssertEqual(Composer2PresetLibrary.lavaLamp.layers.count, 2)
    }
}
