// Composer2LabThemeTests.swift
// ChromaGlow — Composer 2 lab, v2.2. The theme library and the new
// primitives it is built from: completeness, gamut, legal frames, the
// photosensitivity gate measured with the REAL wire gate, and the behaviour
// of lightning, fireworks, marches, candles and the event macros.

import XCTest
import UIKit
@testable import HueHome

@MainActor
final class Composer2LabThemeTests: XCTestCase {

    private let entries = Composer2ThemeCatalog.entries

    private func geometry(_ n: Int) -> Composer2SlotGeometry {
        guard n > 1 else { return .linear(count: n) }
        var points: [(x: Double, z: Double)] = []
        for i in 0..<n {
            let angle = Double(i) / Double(n) * 2 * .pi
            points.append((x: 0.5 + 0.45 * cos(angle), z: 0.5 + 0.3 * sin(angle)))
        }
        return Composer2SlotGeometry(points: points)
    }

    private func inGamut(_ xy: Composer2XY, _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        let c = HueColorUtils.clampXYToGamut(x: xy.x, y: xy.y, gamut: .c)
        XCTAssertEqual(c.x, xy.x, accuracy: 1e-12, "\(context) outside gamut C", file: file, line: line)
        XCTAssertEqual(c.y, xy.y, accuracy: 1e-12, "\(context) outside gamut C", file: file, line: line)
    }

    // MARK: Catalog

    func testCatalogIsCompleteUniqueAndStable() throws {
        XCTAssertGreaterThanOrEqual(entries.count, 45)
        let ids = entries.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "ids are unique")
        XCTAssertEqual(Set(entries.map(\.composition.name)).count, entries.count, "names are unique")
        let pattern = try NSRegularExpression(pattern: "^0000000C-0002-0002-0002-[0-9]{12}$")
        var layerIDs = Set<UUID>()
        for e in entries {
            let raw = e.id.uuidString
            XCTAssertNotNil(pattern.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)), raw)
            XCTAssertTrue(e.composition.isBuiltIn, e.composition.name)
            XCTAssertFalse(e.composition.subtitle.isEmpty, e.composition.name)
            XCTAssertTrue(e.composition.hasVisibleOutput, e.composition.name)
            for l in e.composition.layers {
                XCTAssertTrue(layerIDs.insert(l.id).inserted, "\(e.composition.name): layer id reused")
            }
        }
        for category in Composer2LookCategory.allCases {
            XCTAssertGreaterThanOrEqual(Composer2ThemeCatalog.entries(in: category).count, 4, category.title)
        }
        // The v2.0 looks keep their identities (saved copies point at them).
        XCTAssertEqual(Composer2PresetLibrary.originals.map { String($0.id.uuidString.suffix(1)) }, ["1", "2", "3", "4", "5"])
        for original in Composer2PresetLibrary.originals {
            XCTAssertNotNil(Composer2ThemeCatalog.entry(id: original.id), original.name)
        }
        XCTAssertEqual(Composer2PresetLibrary.all.count, entries.count)
        XCTAssertEqual(Composer2ThemeCatalog.featured.count, Composer2ThemeCatalog.featuredIDs.count)
        XCTAssertTrue(entries.contains { $0.category == .halloween && $0.composition.name == "Jack-o'-Lantern" })
        XCTAssertTrue(entries.contains { $0.composition.layers.contains { $0.motion.kind == .march } },
                      "a real chasing string exists")
        XCTAssertTrue(entries.contains { $0.composition.layers.contains { $0.events?.shape == .lightning } },
                      "real lightning exists")
    }

    func testEverySymbolExists() {
        for e in entries { XCTAssertNotNil(UIImage(systemName: e.symbol), "\(e.composition.name): \(e.symbol)") }
        for c in Composer2LookCategory.allCases { XCTAssertNotNil(UIImage(systemName: c.symbol), c.symbol) }
    }

    func testEveryColourIsInsideGamutC() {
        for e in entries {
            for layer in e.composition.layers {
                let context = "\(e.composition.name)/\(layer.name)"
                for stop in layer.color.stops { inGamut(stop.xy, context) }
                if let c = layer.events?.color { inGamut(c, context + " event") }
                for c in layer.events?.colors ?? [] { inGamut(c, context + " event colours") }
            }
        }
    }

    func testEveryLookRendersLegalDeterministicFramesAtEveryRoomSize() {
        for e in entries {
            for n in [1, 5, 20] {
                var a = Composer2EngineState(), b = Composer2EngineState()
                let g = geometry(n)
                for step in 0..<250 {
                    let t = Double(step) * 0.08
                    let frames = Composer2Engine.evaluate(e.composition, time: t, geometry: g, state: &a)
                    XCTAssertEqual(frames, Composer2Engine.evaluate(e.composition, time: t, geometry: g, state: &b),
                                   "\(e.composition.name) is not deterministic")
                    XCTAssertEqual(frames.count, n)
                    for f in frames {
                        XCTAssertTrue(f.isValid, "\(e.composition.name) n=\(n): \(f)")
                        inGamut(Composer2XY(x: f.x, y: f.y), "\(e.composition.name) output")
                    }
                }
            }
        }
    }

    /// The wire gate is the authority, and a refused onset HOLDS the frame —
    /// a stutter. Every look is played through the real output path (engine +
    /// flash shaper) on the 20 ms Entertainment grid at three room sizes and
    /// then through an independent copy of the wire gate: the gate may hold
    /// (practically) never. The shaper's own work is measured too, so a look
    /// that only stays smooth because the shaper keeps slowing it is caught.
    func testNoLookLeansOnTheFlashGate() {
        let fps = 50.0
        let seconds = 40.0
        var report: [String] = []
        for e in entries {
            for n in [1, 6] {
                let output = Composer2LiveOutput(composition: e.composition)
                output.eventCap = 1
                output.setPreviewGeometry(geometry(n))
                var gate = BeatMath.FlashSafety.OnsetGate()
                var holds = 0
                let total = Int(seconds * fps)
                for step in 0..<total {
                    let t = Double(step) / fps
                    let frames = output.evaluate(time: t)
                    let field = BeatMath.FlashSafety.fieldFrame(channels: frames.map { (x: $0.x, y: $0.y, brightness: $0.brightness) })
                    let reservation = gate.admit(frame: field, source: "wire", at: t,
                                                 minPeriod: BeatMath.FlashSafety.minOnsetLedgerPeriod)
                    if !reservation.wasAdmitted { holds += 1 }
                    gate.commit(reservation, delivered: true, at: t)
                }
                let shaped = Double(output.shaper.shapedFrames) / Double(max(1, output.shaper.totalFrames))
                report.append(String(format: "%@ n=%d shaped=%.3f holds=%d", e.composition.name, n, shaped, holds))
                XCTAssertLessThanOrEqual(holds, 3, "\(e.composition.name) at \(n) lights: the wire gate held \(holds) frames")
                // In a one-light room every sparkle, twinkle and chase step IS
                // a whole-room flash, so the shaper legitimately slows more of
                // them; a room of several lights must barely need it.
                XCTAssertLessThanOrEqual(shaped, n == 1 ? 0.3 : 0.06,
                                         "\(e.composition.name) at \(n) lights leans on the shaper (\(shaped))")
            }
        }
        print("Composer2LabThemeTests gate report:\n" + report.joined(separator: "\n"))
    }

    // MARK: Lightning

    private func strike(distance: Double, seed: UInt64 = 3, n: Int = 8, index: Int = 0) -> Composer2ActiveEvent {
        var spec = Composer2EventSpec(timing: .fixed, interval: 1, probability: 1, burstMin: 3, burstMax: 3,
                                      spacingMin: 0.36, spacingMax: 0.5, durationMin: 0.04, durationMax: 0.06,
                                      decaySeconds: 0.45, targeting: .spatialBiased, spatialBias: 0.6,
                                      modulates: [.brightness, .color], color: Composer2XY(x: 0.27, y: 0.28),
                                      shape: .lightning, distance: distance, propagation: 0.4)
        spec = spec.sanitized
        var state = Composer2EventState.initial(spec: spec, eventSeed: seed, startTime: 0)
        state.advance(to: 1.0001, spec: spec, eventSeed: seed, geometry: geometry(n))
        return state.current!
    }

    func testCloseStrikeHasALeaderStrokesSpacedABudgetApartAndAnAfterglow() {
        let e = strike(distance: 0)
        XCTAssertEqual(e.shape, .lightning)
        XCTAssertGreaterThan(e.leader, 0, "a close strike has a stepped leader")
        XCTAssertGreaterThanOrEqual(e.flashes.count, 1)
        for (a, b) in zip(e.flashes, e.flashes.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b.start - a.start, BeatMath.FlashSafety.minOnsetLedgerPeriod,
                                        "restrokes are a flash budget apart")
        }
        XCTAssertLessThanOrEqual(e.attack, 0.021, "a close stroke rises in one frame (the gate would hold a slow one)")
        XCTAssertEqual(e.peak, 1, accuracy: 0.26)
        // The focus blazes; far lights get the sky's share.
        let focus = e.targets.firstIndex(of: e.targets.max()!)!
        let peakTime = e.flashes[0].start + e.attack + 0.01
        let hot = e.levels(slot: focus, time: peakTime)
        XCTAssertGreaterThan(hot.level, 0.6)
        XCTAssertGreaterThan(hot.core, 0.5, "the bolt's colour at the bolt")
        // It lingers, then it is gone.
        let lastHold = e.flashes.last!.holdEnd
        XCTAssertGreaterThan(e.levels(slot: focus, time: lastHold + 0.3).level, 0.05, "afterglow")
        XCTAssertEqual(e.levels(slot: focus, time: e.end + 0.01).level, 0)
    }

    func testDistantStrikesAreDimmerSofterWiderAndRoll() {
        let near = strike(distance: 0, seed: 11)
        let far = strike(distance: 1, seed: 11)
        XCTAssertLessThan(far.peak, near.peak * 0.6, "distant lightning is dimmer")
        XCTAssertGreaterThan(far.attack, near.attack, "…softer")
        XCTAssertGreaterThan(far.skyShare, near.skyShare, "…a sheet across the sky, not a bolt")
        XCTAssertLessThanOrEqual(far.flashes.count, 2)
        XCTAssertGreaterThan(far.delays.max() ?? 0, 0.05, "…and it rolls across the room")
        XCTAssertEqual(near.delays.max() ?? 0, 0, accuracy: 1e-12, "a close strike lands everywhere in the same frame")
    }

    func testStormCycleStartsQuietAndPeaksMidCycle() {
        let spec = Composer2EventSpec(activityPeriod: 240, activityDepth: 0.8).sanitized
        XCTAssertEqual(spec.activity(at: 0), 0.2, accuracy: 1e-9)
        XCTAssertEqual(spec.activity(at: 120), 1, accuracy: 1e-9)
        XCTAssertEqual(spec.activity(at: 240), 0.2, accuracy: 1e-9)
        XCTAssertEqual(Composer2EventSpec().activity(at: 77), 1, "no cycle, full activity")
    }

    // MARK: Fireworks, twinkles

    func testFireworkPicksAColourFromItsSetAndBloomsOutward() {
        let colours = [Composer2XY(x: 0.64, y: 0.32), Composer2XY(x: 0.21, y: 0.62), Composer2XY(x: 0.16, y: 0.08)]
        let spec = Composer2PresetLibrary.fireworks(colours, every: 1...1, bloom: 0.5).sanitized
        var picked = Set<String>()
        for seed in UInt64(1)...40 {
            var state = Composer2EventState.initial(spec: spec, eventSeed: seed, startTime: 0)
            state.advance(to: 1.5, spec: spec, eventSeed: seed, geometry: geometry(10))
            guard let e = state.current else { continue }
            XCTAssertEqual(e.shape, .firework)
            if let c = e.color { picked.insert("\(c.x),\(c.y)") }
            let order = e.delays.enumerated().sorted { $0.element < $1.element }
            XCTAssertEqual(order.first?.element ?? 1, 0, accuracy: 1e-12, "the burst starts where it lands")
            XCTAssertGreaterThan(order.last?.element ?? 0, 0.2, "and reaches the far side later")
        }
        XCTAssertEqual(picked.count, 3, "every burst colour is used")
    }

    // MARK: March

    func testMarchStepsOneLightPerStepInRoomOrder() {
        let march = Composer2Motion(kind: .march, periodSeconds: 4, smoothness: 0, steps: 4)
        XCTAssertEqual(march.stepSeconds, 1, accuracy: 1e-9)
        func cell(_ rank: Int, _ t: Double) -> Int {
            Int((march.sample(slot: rank, position: 0, cross: 0.5, time: t, seed: 1, rank: rank).phase * 4).rounded(.down))
        }
        for rank in 0..<8 {
            XCTAssertEqual(cell(rank, 0.5), rank % 4)
            XCTAssertEqual(cell(rank, 1.5), (rank + 3) % 4, "one step later the pattern has moved one light forward")
        }
        // Theater chase: one cell in three lit.
        let theater = Composer2Motion(kind: .march, periodSeconds: 1.5, smoothness: 0, travelWidth: 0.34, steps: 3)
        let lit = (0..<9).map { theater.sample(slot: $0, position: 0, cross: 0.5, time: 0.1, seed: 1, rank: $0).weight }
        XCTAssertEqual(lit.filter { $0 > 0.5 }.count, 3)
    }

    func testMarchIsNeverFasterThanOneFlashBudgetPerStep() {
        let fast = Composer2Motion(kind: .march, periodSeconds: 0.1, steps: 5)
        XCTAssertGreaterThanOrEqual(fast.stepSeconds, BeatMath.FlashSafety.minOnsetLedgerPeriod - 1e-12)
    }

    // MARK: Candle and colour-follows-brightness

    func testCandleFlickersSmoothlyAndItsColourFollowsItsBrightness() {
        let look = Composer2PresetLibrary.candlelight
        var state = Composer2EngineState()
        let g = geometry(1)
        var samples: [(bri: Double, x: Double)] = []
        for step in 0..<2000 {
            let f = Composer2Engine.evaluate(look, time: Double(step) * 0.04, geometry: g, state: &state)[0]
            samples.append((f.brightness, f.x))
        }
        let bright = samples.sorted { $0.bri > $1.bri }
        let top = bright.prefix(200).map(\.x).reduce(0, +) / 200
        let bottom = bright.suffix(200).map(\.x).reduce(0, +) / 200
        XCTAssertLessThan(top, bottom, "brighter = whiter (the flame's last stop), dimmer = deeper amber")
        let steps = zip(samples, samples.dropFirst()).map { abs($1.bri - $0.bri) }
        XCTAssertLessThan(steps.max() ?? 1, 0.2, "a flame sways and flickers; it never jumps")
    }

    // MARK: Macros

    func testEventRateAndStrengthMacros() {
        var look = Composer2PresetLibrary.thunderstorm
        func strikes(_ c: Composer2Composition) -> Int {
            var state = Composer2EngineState()
            let g = geometry(6)
            for step in 0..<Int(600 / 0.1) {
                _ = Composer2Engine.evaluate(c, time: Double(step) * 0.1, geometry: g, state: &state)
            }
            return state.layers.compactMap(\.events).map(\.firedCount).reduce(0, +)
        }
        let authored = strikes(look)
        look.master.eventRate = 3
        let frequent = strikes(look)
        // Strikes cannot overlap (one in flight per layer, afterglow included),
        // so ×3 frequency lands well above ×1.5 rather than a clean ×3.
        XCTAssertGreaterThan(Double(frequent), Double(authored) * 1.5, "Frequency ×3: many more strikes (\(authored) → \(frequent))")

        var silent = Composer2PresetLibrary.thunderstorm
        silent.master.eventStrength = 0
        var quiet = Composer2EngineState(), loud = Composer2EngineState()
        let g = geometry(6)
        var maxDifference = 0.0
        var strongMax = 0.0, silentMax = 0.0
        for step in 0..<3000 {
            let t = Double(step) * 0.1
            let s = Composer2Engine.evaluate(silent, time: t, geometry: g, state: &quiet)
            let l = Composer2Engine.evaluate(Composer2PresetLibrary.thunderstorm, time: t, geometry: g, state: &loud)
            silentMax = max(silentMax, s.map(\.brightness).max() ?? 0)
            strongMax = max(strongMax, l.map(\.brightness).max() ?? 0)
            maxDifference = max(maxDifference, zip(s, l).map { abs($0.brightness - $1.brightness) }.max() ?? 0)
        }
        XCTAssertLessThan(silentMax, 0.3, "Strength 0: the storm keeps its sky, loses its lightning")
        XCTAssertGreaterThan(strongMax, 0.6)
    }

    // MARK: Persistence of the new fields

    func testNewFieldsRoundTripAndOldFilesDecodeWithDefaults() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for e in entries {
            let decoded = try decoder.decode(Composer2Composition.self, from: try encoder.encode(e.composition))
            XCTAssertEqual(decoded, e.composition, e.composition.name)
        }
        // A v2.1 event and master decode with the v2.2 defaults.
        let oldEvent = try decoder.decode(Composer2EventSpec.self, from: Data(#"{"timing":"random","minDelay":4}"#.utf8))
        XCTAssertEqual(oldEvent.shape, .flash)
        XCTAssertTrue(oldEvent.colors.isEmpty)
        XCTAssertEqual(oldEvent.activityPeriod, 0)
        let oldMaster = try decoder.decode(Composer2MasterControls.self, from: Data(#"{"intensity":0.5,"seed":"7"}"#.utf8))
        XCTAssertEqual(oldMaster.eventRate, 1)
        XCTAssertEqual(oldMaster.eventStrength, 1)
        // An unknown future shape falls back rather than failing the layer.
        let future = try decoder.decode(Composer2EventSpec.self, from: Data(#"{"shape":"meteor_shower"}"#.utf8))
        XCTAssertEqual(future.shape, .flash)
    }
}
