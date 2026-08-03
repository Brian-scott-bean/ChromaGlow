// PresetCatalogTests.swift
// ChromaGlow — built-in composition catalog
//
// The shipped presets are the app's first impression, and nobody hand-checks
// forty of them before a release. This is the quality bar, written down:
//
//   • every colour a real bulb can actually show
//   • every field inside the range its slider allows
//   • renders cleanly at 1 light and at 20
//   • no preset that strobes when the user asked for slow
//   • multi-light rooms shimmer rather than blink in unison
//
// A preset that fails one of these is a bug the user would feel but not be
// able to name.

import XCTest
@testable import HueHome

@MainActor
final class PresetCatalogTests: XCTestCase {

    private var catalog: [CompositionPreset] { CompositionStore.builtInPresets }

    /// Every shipped bulb gamut. A preset must look right on the narrowest.
    private let gamuts: [HueColorUtils.Gamut] = [.a, .b, .c]

    // MARK: - Identity

    func testEveryPresetHasAUniqueIDAndName() {
        let ids = catalog.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate preset UUID")

        let names = catalog.map { $0.name.lowercased() }
        XCTAssertEqual(Set(names).count, names.count, "duplicate preset name")
    }

    func testEveryPresetIsMarkedBuiltInAndNamed() {
        for preset in catalog {
            XCTAssertTrue(preset.isBuiltIn, preset.name)
            XCTAssertFalse(preset.name.trimmingCharacters(in: .whitespaces).isEmpty)
            XCTAssertFalse(preset.icon.isEmpty, preset.name)
            XCTAssertTrue(preset.accentColorHex.hasPrefix("#"), "\(preset.name): \(preset.accentColorHex)")
        }
    }

    /// BuiltInSeedMigrator matches shipped presets to stored ones by id, so a
    /// built-in written with `UUID()` would get a fresh id on every launch: it
    /// would be re-added forever and never refreshed. Ids must be hand-assigned
    /// from the `0000000C-0001-0001-0001-...` scheme.
    func testEveryPresetIDIsDeterministicNotRandom() {
        let scheme = /^0000000[0-9A-F]-0001-0001-0001-[0-9A-F]{12}$/
        for preset in catalog {
            XCTAssertNotNil(
                try? scheme.wholeMatch(in: preset.id.uuidString.uppercased()),
                "\(preset.name) has id \(preset.id) — a random UUID breaks seed migration")
        }
    }

    /// Every filter chip on the Composer deck must lead somewhere.
    func testEveryCategoryChipHasPresetsBehindIt() {
        for category in PresetCategory.allCases where category != .all && category != .myCreations {
            let count = catalog.filter { $0.category == category }.count
            XCTAssertGreaterThan(count, 0, "the '\(category.rawValue)' chip shows an empty deck")
        }
    }

    func testSeasonalPresetsDeclareRealMonths() {
        for preset in catalog {
            guard let months = preset.seasonMonths else { continue }
            XCTAssertFalse(months.isEmpty, preset.name)
            for month in months {
                XCTAssertTrue((1...12).contains(month), "\(preset.name): month \(month)")
            }
        }
    }

    // MARK: - Colour

    /// Stops must sit inside gamut C — the modern colour bulb, and the gamut the
    /// Composer previews with (`activeCompositionGamut` defaults to `.c`). The
    /// engine clamps at render time, so an outside stop is not a crash; it is a
    /// quieter bug: the author picks one colour and the bulb shows another.
    ///
    /// Note gamut C is *not* a superset of A and B — A's green (0.2151, 0.7106)
    /// is more saturated than C's (0.170, 0.700). C is the target, not the union.
    ///
    /// `clampXYToGamut` returns the point untouched when it is inside, so exact
    /// equality is the membership test — no tolerance to hide a near-miss behind.
    func testEveryPaletteStopIsInsideGamutC() {
        for preset in catalog {
            let stops = [preset.palette.color1, preset.palette.color2, preset.palette.color3].compactMap { $0 }
            for (index, stop) in stops.enumerated() {
                XCTAssertTrue((0...1).contains(stop.x), "\(preset.name) stop \(index): x=\(stop.x)")
                XCTAssertTrue((0...1).contains(stop.y), "\(preset.name) stop \(index): y=\(stop.y)")

                let clamped = HueColorUtils.clampXYToGamut(x: stop.x, y: stop.y, gamut: .c)
                let drift = max(abs(clamped.x - stop.x), abs(clamped.y - stop.y))
                XCTAssertLessThan(drift, 1e-9,
                    "\(preset.name) stop \(index) (\(stop.x), \(stop.y)) sits outside gamut C — "
                    + "the bulb would show (\(clamped.x), \(clamped.y))")
            }
        }
    }

    func testTemperaturePresetsUseALegalMirek() {
        for preset in catalog where preset.palette.mode == .temperature {
            XCTAssertTrue((153...500).contains(preset.palette.temperature),
                          "\(preset.name): mirek \(preset.palette.temperature)")
        }
    }

    // MARK: - Field ranges (each slider's own bounds)

    func testEveryFieldIsInsideItsSliderRange() {
        for preset in catalog {
            let name = preset.name

            XCTAssertTrue((0...100).contains(preset.palette.saturation), "\(name) saturation")
            XCTAssertTrue((-180...180).contains(preset.palette.hueShift), "\(name) hueShift")

            XCTAssertTrue((0...100).contains(preset.motion.speed), "\(name) speed")
            XCTAssertTrue((0...100).contains(preset.motion.spread), "\(name) spread")
            XCTAssertTrue((0...100).contains(preset.motion.offset), "\(name) offset")

            XCTAssertTrue((20...240).contains(preset.envelope.bpm), "\(name) bpm")
            XCTAssertTrue((0...100).contains(preset.envelope.depth), "\(name) depth")
            XCTAssertTrue((0...50).contains(preset.envelope.minBrightness), "\(name) minBrightness")
            XCTAssertTrue((50...100).contains(preset.envelope.maxBrightness), "\(name) maxBrightness")

            XCTAssertTrue((0...100).contains(preset.reaction.sensitivity), "\(name) sensitivity")
            XCTAssertTrue((0...100).contains(preset.reaction.intensity), "\(name) intensity")
        }
    }

    func testBrightnessFloorSitsBelowItsCeiling() {
        for preset in catalog {
            XCTAssertLessThan(preset.envelope.minBrightness, preset.envelope.maxBrightness,
                              "\(preset.name): floor is not below ceiling")
        }
    }

    // MARK: - Render

    /// A room may have one bulb or sixty. None of them may produce NaN, a
    /// colour outside CIE space, or a light that is simply off.
    ///
    /// Packet 5 widened this past 20. The old list stopped exactly at the
    /// phantom cap, and the loop itself could not have gone further: it built
    /// `(0..<UInt8(lightCount))`, which traps above 255 — the same `UInt8`
    /// assumption that produced the cap in production.
    func testEveryPresetRendersLegalFramesAtEveryRoomSize() {
        for preset in catalog {
            for lightCount in [1, 5, 20, 21, 64, 300] {
                let box = CompositionParamBox(preset: preset)
                let channels = Array(0..<lightCount)

                for step in 0..<25 {
                    let frames = CompositionEngine.render(
                        time: Double(step) * 0.04, channelIDs: channels, params: box)

                    XCTAssertEqual(frames.count, lightCount, "\(preset.name) @\(lightCount)")
                    for frame in frames {
                        XCTAssertTrue(frame.x.isFinite && frame.y.isFinite,
                                      "\(preset.name) @\(lightCount): NaN colour")
                        XCTAssertTrue((0...1).contains(frame.x), "\(preset.name): x=\(frame.x)")
                        XCTAssertTrue((0...1).contains(frame.y), "\(preset.name): y=\(frame.y)")
                        XCTAssertTrue(frame.brightness.isFinite, "\(preset.name): NaN brightness")
                        XCTAssertTrue((0...1).contains(frame.brightness),
                                      "\(preset.name): brightness=\(frame.brightness)")
                    }
                }
            }
        }
    }

    /// Patterns whose whole point is to step. A marquee chase that faded
    /// smoothly would not be a chase, and twinkle is stochastic per-light
    /// sparkle by definition — judging either for smoothness tests the wrong
    /// thing. They are still bound by the flash-rate limit below.
    private let steppedPatterns: Set<MotionConfig.Pattern> = [.chase, .twinkle]

    /// Envelopes that are meant to snap rather than glide.
    private let steppedEnvelopes: Set<EnvelopeConfig.Shape> = [.flicker, .pulse]

    /// "Slow" must not look like a strobe. For a smooth pattern at a low speed,
    /// brightness between adjacent 25fps frames should move gradually.
    func testSlowSmoothPresetsDoNotJump() {
        for preset in catalog {
            guard preset.motion.speed <= 25,
                  !steppedPatterns.contains(preset.motion.pattern),
                  !steppedEnvelopes.contains(preset.envelope.shape),
                  preset.reaction.source == .none
            else { continue }

            let box = CompositionParamBox(preset: preset)
            let channels: [Int] = [0, 1, 2, 3, 4]
            var previous: [Double] = []

            for step in 0..<50 {
                let frames = CompositionEngine.render(
                    time: Double(step) * 0.04, channelIDs: channels, params: box)
                let brightness = frames.map(\.brightness)

                if !previous.isEmpty {
                    for (i, value) in brightness.enumerated() {
                        let jump = abs(value - previous[i])
                        XCTAssertLessThan(jump, 0.34,
                            "\(preset.name) jumps \(String(format: "%.2f", jump)) in one frame "
                            + "at speed \(preset.motion.speed) — that reads as a flicker, not a glide")
                    }
                }
                previous = brightness
            }
        }
    }

    /// No shipped scene may flash faster than 3 times a second. That is the
    /// photosensitive-epilepsy guideline (WCAG 2.3.1), and it binds every
    /// pattern — a chase is allowed to step, not to strobe. Deliberate strobing
    /// lives on Studio's engine cards, which the user invokes by name; an
    /// ambient scene must never surprise anyone with it.
    func testNoPresetFlashesFasterThanThreeHertz() {
        let duration = 4.0
        let fps = 25.0
        /// The shallow-ripple guard below skips lights that barely move. Count
        /// what we actually measured, so this test can never pass by measuring
        /// nothing.
        var measuredLights = 0

        for preset in catalog where preset.reaction.source == .none {
            let box = CompositionParamBox(preset: preset)
            let channels: [Int] = [0, 1, 2, 3, 4]

            var series: [[Double]] = Array(repeating: [], count: channels.count)
            for step in 0..<Int(duration * fps) {
                let frames = CompositionEngine.render(
                    time: Double(step) / fps, channelIDs: channels, params: box)
                for (i, frame) in frames.enumerated() { series[i].append(frame.brightness) }
            }

            for (light, samples) in series.enumerated() {
                // Count rising crossings of the light's own midpoint — one
                // crossing per flash, ignoring shallow ripple.
                guard let low = samples.min(), let high = samples.max(), high - low > 0.25 else { continue }
                measuredLights += 1
                let mid = (low + high) / 2
                var flashes = 0
                for i in 1..<samples.count where samples[i - 1] < mid && samples[i] >= mid {
                    flashes += 1
                }
                let hz = Double(flashes) / duration
                XCTAssertLessThanOrEqual(hz, 3.0,
                    "\(preset.name) light \(light) flashes at \(String(format: "%.1f", hz))Hz — "
                    + "above the 3Hz photosensitivity limit")
            }
        }

        XCTAssertGreaterThan(measuredLights, 20,
            "the flash-rate check measured only \(measuredLights) lights — it is passing vacuously")
    }

    /// A moving pattern across many lights should not have every bulb doing the
    /// same thing — that is what `static` is for. Otherwise a 20-bulb room
    /// blinks in unison instead of shimmering.
    func testMovingPresetsSpreadAcrossLights() {
        for preset in catalog where preset.motion.pattern != .static {
            let box = CompositionParamBox(preset: preset)
            let channels = Array(0..<8)

            // Sample a full second: at some point the lights must differ.
            var everDiffered = false
            for step in 0..<25 {
                let frames = CompositionEngine.render(
                    time: Double(step) * 0.04, channelIDs: channels, params: box)
                let brightnesses = frames.map { ($0.brightness * 1000).rounded() }
                let colors = frames.map { (($0.x * 1000).rounded(), ($0.y * 1000).rounded()) }

                if Set(brightnesses).count > 1 || Set(colors.map { "\($0.0),\($0.1)" }).count > 1 {
                    everDiffered = true
                    break
                }
            }
            XCTAssertTrue(everDiffered,
                "\(preset.name) has motion '\(preset.motion.pattern.rawValue)' but every light stays identical")
        }
    }

    // MARK: - Tier & transport coherence

    /// `capabilityTier` is derived, so it cannot lie — but a preset that claims
    /// to prefer streaming while being bridge-optimizable is a contradiction the
    /// transport resolver has to break arbitrarily.
    func testBridgeOptimizedPresetsDoNotDemandStreaming() {
        for preset in catalog where preset.capabilityTier == .bridgeOptimized {
            XCTAssertNotEqual(preset.preferredTransport, .entertainmentArea,
                              "\(preset.name) is a static scene asking for a DTLS session")
        }
    }

    /// A preset that needs the microphone can never run on the bridge alone.
    func testMicReactivePresetsAreNotBridgeOptimized() {
        for preset in catalog where preset.reaction.requiresMic {
            XCTAssertNotEqual(preset.capabilityTier, .bridgeOptimized, preset.name)
            XCTAssertNotNil(BridgeDynamicSceneExporter.ineligibilityReason(for: preset), preset.name)
        }
    }
}
