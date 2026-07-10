// BridgeDynamicSceneExporterTests.swift
// ChromaGlow — Composer → native Hue dynamic scene
//
// The export is a one-way door: it POSTs a scene to the bridge that then runs
// without the app. If the palette is wrong, the user finds out when their living
// room is the wrong colour and the phone is in another room.
//
// The bug these lock out: the export used to read `palette.color1`/`color2`
// straight off the config. In spectrum mode those fields are not the colours
// being displayed (the hue wheel is), and in temperature mode the colour is
// derived from mirek. Both exported the wrong scene.

import XCTest
@testable import HueHome

final class BridgeDynamicSceneExporterTests: XCTestCase {

    private typealias Exporter = BridgeDynamicSceneExporter
    private let gamut = HueColorUtils.Gamut.c

    // MARK: - Palette shape per mode

    func testSolidPaletteIsOnePointAndSaysItWontAnimate() {
        var palette = PaletteConfig()
        palette.mode = .solid

        let points = Exporter.palettePoints(for: palette, gamut: gamut)
        XCTAssertEqual(points.count, 1)

        let recipe = Exporter.recipe(palette: palette, motion: MotionConfig(),
                                     envelope: EnvelopeConfig(), gamut: gamut)
        XCTAssertFalse(recipe.willAnimate, "one colour cannot cycle — don't promise a loop")
    }

    /// The anchors are the authored stops, after gamut clamping — that clamp is
    /// part of the contract, so the expectation goes through it too rather than
    /// hard-coding coordinates that may sit just outside a bulb's triangle.
    private func clamped(_ x: Double, _ y: Double) -> Exporter.PaletteXY {
        let p = HueColorUtils.clampXYToGamut(x: x, y: y, gamut: gamut)
        return .init(x: p.x, y: p.y)
    }

    func testTwoStopGradientExportsBothStops() {
        var palette = PaletteConfig()
        palette.mode = .gradient
        palette.color1 = CodableColor(x: 0.60, y: 0.32)   // red-ish
        palette.color2 = CodableColor(x: 0.17, y: 0.05)   // blue-ish, just outside gamut C
        palette.color3 = nil

        let points = Exporter.palettePoints(for: palette, gamut: gamut)
        XCTAssertEqual(points.count, 2)
        XCTAssertTrue(Exporter.isSameColor(points[0], clamped(0.60, 0.32)))
        XCTAssertTrue(Exporter.isSameColor(points[1], clamped(0.17, 0.05)))
    }

    func testThreeStopGradientExportsAllThreeInOrder() {
        var palette = PaletteConfig()
        palette.mode = .gradient
        palette.color1 = CodableColor(x: 0.60, y: 0.32)
        palette.color2 = CodableColor(x: 0.40, y: 0.45)
        palette.color3 = CodableColor(x: 0.20, y: 0.10)

        let points = Exporter.palettePoints(for: palette, gamut: gamut)
        XCTAssertEqual(points.count, 3)
        XCTAssertTrue(Exporter.isSameColor(points[0], clamped(0.60, 0.32)))
        // Middle stop sits at phase 0.5 — it must be color2, not a blend.
        XCTAssertTrue(Exporter.isSameColor(points[1], clamped(0.40, 0.45)),
                      "phase 0.5 of a 3-stop gradient is the middle stop")
        XCTAssertTrue(Exporter.isSameColor(points[2], clamped(0.20, 0.10)))
    }

    /// A stop outside the bulb's triangle must land on it, not be sent raw to
    /// the bridge — CLIP accepts the value and the light shows a different colour.
    func testOutOfGamutStopsAreProjectedOntoTheTriangle() {
        var palette = PaletteConfig()
        palette.mode = .gradient
        palette.color1 = CodableColor(x: 0.99, y: 0.99)   // nowhere near a real bulb
        palette.color2 = CodableColor(x: 0.0, y: 0.0)

        let points = Exporter.palettePoints(for: palette, gamut: gamut)
        for point in points {
            XCTAssertTrue((0...1).contains(point.x))
            XCTAssertTrue((0...1).contains(point.y))
        }
        XCTAssertFalse(Exporter.isSameColor(points[0], .init(x: 0.99, y: 0.99)),
                       "an out-of-gamut stop was passed through unclamped")
    }

    /// The headline fix. Spectrum's colours come from the hue wheel; color1 and
    /// color2 are ignored entirely by `color(at:)`.
    func testSpectrumSamplesTheHueWheelAndIgnoresColor1And2() {
        var palette = PaletteConfig()
        palette.mode = .spectrum
        palette.saturation = 100
        // Deliberately absurd stops — if they leak into the export, we'd see them.
        palette.color1 = CodableColor(x: 0.9, y: 0.05)
        palette.color2 = CodableColor(x: 0.9, y: 0.05)

        let points = Exporter.palettePoints(for: palette, gamut: gamut)
        XCTAssertGreaterThan(points.count, 2, "a rainbow needs more than two anchors")
        XCTAssertLessThanOrEqual(points.count, Exporter.maxPalettePoints)

        let leaked = points.filter { Exporter.isSameColor($0, .init(x: 0.9, y: 0.05)) }
        XCTAssertTrue(leaked.isEmpty, "color1/color2 leaked into a spectrum export")

        // Distinct anchors, i.e. an actual sweep rather than one colour repeated.
        for i in points.indices.dropLast() {
            XCTAssertFalse(Exporter.isSameColor(points[i], points[i + 1]),
                           "adjacent spectrum anchors \(i) and \(i+1) are the same colour")
        }
    }

    /// The wheel is periodic: phase 1.0 is phase 0.0. Sampling it would waste a
    /// slot and make the bridge dwell on that colour for two beats.
    func testSpectrumDoesNotRepeatItsFirstColourAtTheEnd() {
        var palette = PaletteConfig()
        palette.mode = .spectrum

        let points = Exporter.palettePoints(for: palette, gamut: gamut)
        let first = try! XCTUnwrap(points.first)
        let last = try! XCTUnwrap(points.last)
        XCTAssertFalse(Exporter.isSameColor(first, last))
    }

    func testSpectrumHonoursHueShift() {
        var base = PaletteConfig()
        base.mode = .spectrum
        var shifted = base
        shifted.hueShift = 120

        let a = Exporter.palettePoints(for: base, gamut: gamut)
        let b = Exporter.palettePoints(for: shifted, gamut: gamut)
        XCTAssertNotEqual(a.first, b.first, "hueShift must move where the sweep starts")
    }

    /// Temperature mode's colour comes from mirek, not from color1.
    func testTemperatureExportsItsMirekDerivedColourNotColor1() {
        var warm = PaletteConfig()
        warm.mode = .temperature
        warm.temperature = 500                            // warmest
        warm.color1 = CodableColor(x: 0.17, y: 0.05)      // a blue that must not appear

        var cool = warm
        cool.temperature = 153                            // coolest

        let warmPoints = Exporter.palettePoints(for: warm, gamut: gamut)
        let coolPoints = Exporter.palettePoints(for: cool, gamut: gamut)

        XCTAssertEqual(warmPoints.count, 1)
        XCTAssertEqual(coolPoints.count, 1)
        XCTAssertFalse(Exporter.isSameColor(warmPoints[0], .init(x: 0.17, y: 0.05)),
                       "color1 leaked into a temperature export")
        XCTAssertFalse(Exporter.isSameColor(warmPoints[0], coolPoints[0]),
                       "2000K and 6500K must not export the same colour")
        XCTAssertGreaterThan(warmPoints[0].x, coolPoints[0].x, "warm should sit further into red")
    }

    // MARK: - Invariants

    func testPaletteNeverExceedsTheClipCap() {
        for mode in PaletteConfig.Mode.allCases {
            var palette = PaletteConfig()
            palette.mode = mode
            palette.color3 = CodableColor(x: 0.3, y: 0.3)
            let points = Exporter.palettePoints(for: palette, gamut: gamut)
            XCTAssertGreaterThanOrEqual(points.count, 1, "\(mode) exported an empty palette")
            XCTAssertLessThanOrEqual(points.count, Exporter.maxPalettePoints, "\(mode)")
        }
    }

    func testEveryExportedPointIsInsideTheGamut() {
        for preset in CompositionStore.builtInPresets {
            for point in Exporter.palettePoints(for: preset.palette, gamut: gamut) {
                XCTAssertTrue((0...1).contains(point.x), "\(preset.name): x=\(point.x)")
                XCTAssertTrue((0...1).contains(point.y), "\(preset.name): y=\(point.y)")
            }
        }
    }

    func testDuplicateStopsCollapseSoTheBridgeDoesNotDwell() {
        var palette = PaletteConfig()
        palette.mode = .gradient
        palette.color1 = CodableColor(x: 0.5, y: 0.4)
        palette.color2 = CodableColor(x: 0.5, y: 0.4)   // same colour twice

        XCTAssertEqual(Exporter.palettePoints(for: palette, gamut: gamut).count, 1)
    }

    // MARK: - Speed & brightness

    /// Speed 0 would stop the cycle outright, which is not what "slow" means.
    func testSpeedIsClampedAwayFromZero() {
        var motion = MotionConfig()
        motion.speed = 0
        XCTAssertEqual(Exporter.speed(for: motion), 0.1, accuracy: 0.0001)

        motion.speed = 100
        XCTAssertEqual(Exporter.speed(for: motion), 1.0, accuracy: 0.0001)

        motion.speed = 40
        XCTAssertEqual(Exporter.speed(for: motion), 0.4, accuracy: 0.0001)
    }

    func testBrightnessUsesTheEnvelopeCeilingAndStaysLegal() {
        var envelope = EnvelopeConfig()
        envelope.maxBrightness = 100
        XCTAssertEqual(Exporter.brightness(for: envelope), 100, accuracy: 0.001)

        envelope.maxBrightness = 0      // CLIP rejects brightness 0
        XCTAssertEqual(Exporter.brightness(for: envelope), 1, accuracy: 0.001)
    }

    // MARK: - Eligibility

    func testMicReactivePresetsAreRejectedWithAReason() {
        guard var preset = CompositionStore.builtInPresets.first else { return XCTFail("no presets") }
        preset.reaction.source = .micAmplitude
        let reason = Exporter.ineligibilityReason(for: preset)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains("bridge can't hear") ?? false)
    }

    func testNonReactivePresetsAreEligible() {
        guard var preset = CompositionStore.builtInPresets.first else { return XCTFail("no presets") }
        preset.reaction.source = .none
        XCTAssertNil(Exporter.ineligibilityReason(for: preset))
    }
}
