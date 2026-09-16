// Composer2LabPerformanceTests.swift
// ChromaGlow — Composer 2 lab (experimental), v2.1.
//
// Measured, not assumed: six layers over ~100 render slots with events,
// masks and audio, evaluated at the streaming cadence. The numbers are
// attached to the result bundle; the assertions are loose ceilings so a
// slow CI box does not fail the suite while a real regression still does.

import XCTest
@testable import HueHome

@MainActor
final class Composer2LabPerformanceTests: XCTestCase {

    private static let slotCount = 100
    private static let frameCount = 250   // 10 s at 25 fps

    /// Six layers: Haunted House's four, Thunderstorm's lightning, and an
    /// audio-driven chase over a region mask.
    static func heavyComposition() -> Composer2Composition {
        var c = Composer2PresetLibrary.hauntedHouse
        c.layers.append(Composer2PresetLibrary.thunderstorm.layers[1])
        var chase = Composer2PresetLibrary.christmasChase.layers[0]
        chase.name = "Reactive chase"
        chase.mask.kind = .region
        chase.mask.regionX0 = 0.1; chase.mask.regionX1 = 0.9
        chase.mask.regionZ0 = 0.0; chase.mask.regionZ1 = 0.6
        chase.mask.feather = 0.2
        chase.audio.source = .bass
        chase.audio.targets = [.brightness, .motionSpeed]
        chase.variation = .organic
        c.layers.append(chase)
        c.layers[1].mask.kind = .randomSubset
        c.layers[1].mask.fraction = 0.4
        c.name = "Heavy"
        return c
    }

    static func geometry(_ n: Int) -> Composer2SlotGeometry {
        var points: [(x: Double, z: Double)] = []
        var ids: [String] = []
        for i in 0..<n {
            let t = Double(i) / Double(max(1, n - 1))
            points.append((x: t * 2 - 1, z: (Double(i % 7) / 6) * 2 - 1))
            ids.append("L\(i / 3)")
        }
        return Composer2SlotGeometry(points: points, lightIDs: ids)
    }

    static func slots(_ n: Int) -> [CompositionRenderSlot] {
        (0..<n).map { i in
            CompositionRenderSlot(index: i, bridgeID: "b1", lightID: "L\(i / 3)", channelID: i,
                                  segmentIndex: i % 3, segmentCount: 3,
                                  position: CompositionSlotPosition(x: Double(i) / Double(n) * 2 - 1, y: 0,
                                                                    z: (Double(i % 7) / 6) * 2 - 1),
                                  capability: i % 11 == 0 ? .tunableWhite : .color, mirekRange: 153...500)
        }
    }

    private func loudAudio(_ i: Int) -> AudioFeatures {
        var f = AudioFeatures.silent
        let beat = i % 12 == 0
        f.level = beat ? 0.9 : 0.35
        f.bass = beat ? 0.95 : 0.3
        f.mid = 0.4
        f.treble = 0.25
        return f
    }

    private func record(_ label: String, msPerFrame: Double, extra: String = "") {
        let text = String(format: "%@: %.3f ms/frame (%d slots, %d frames)%@", label, msPerFrame,
                          Self.slotCount, Self.frameCount, extra)
        let attachment = XCTAttachment(string: text)
        attachment.name = "composer2-performance-\(label)"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("[Composer2 perf] \(text)")
    }

    // MARK: Engine under load

    func testSixLayersOverHundredSlotsWithAudioAtStreamingCadence() {
        let composition = Self.heavyComposition()
        XCTAssertEqual(composition.layers.count, 6)
        let g = Self.geometry(Self.slotCount)
        var state = Composer2EngineState()
        // Warm-up: plans compile on first evaluation.
        _ = Composer2Engine.evaluate(composition, time: 0, geometry: g, state: &state, audio: loudAudio(0))
        let clock = ContinuousClock()
        var maxFrame: Duration = .zero
        let start = clock.now
        for i in 1...Self.frameCount {
            let t0 = clock.now
            let frames = Composer2Engine.evaluate(composition, time: Double(i) * 0.04, geometry: g, state: &state, audio: loudAudio(i))
            let dt = clock.now - t0
            if dt > maxFrame { maxFrame = dt }
            XCTAssertEqual(frames.count, Self.slotCount)
        }
        let total = clock.now - start
        let ms = Double(total.components.attoseconds) / 1e15 + Double(total.components.seconds) * 1000
        let msPerFrame = ms / Double(Self.frameCount)
        let maxMs = Double(maxFrame.components.attoseconds) / 1e15 + Double(maxFrame.components.seconds) * 1000
        record("engine-6-layers-audio", msPerFrame: msPerFrame, extra: String(format: ", worst %.3f ms", maxMs))
        XCTAssertLessThan(msPerFrame, 40, "a 25 fps frame budget is 40 ms; the engine must stay far below it")
        XCTAssertLessThan(maxMs, 120, "no single frame may stall the streaming loop")
    }

    func testSeamPathWithExactSlotsAndLegacyBoxCosts() {
        let composition = Self.heavyComposition()
        let out = Composer2LiveOutput(composition: composition)
        let box = CompositionParamBox(palette: PaletteConfig(), motion: MotionConfig(),
                                      envelope: EnvelopeConfig(), reaction: ReactionConfig())
        box.frameSource = out
        box.renderSlots = Self.slots(Self.slotCount)
        let ids = Array(0..<Self.slotCount)
        _ = CompositionEngine.render(time: 0, channelIDs: ids, params: box, hostNow: 0)
        let clock = ContinuousClock()
        let start = clock.now
        for i in 1...Self.frameCount {
            let frames = CompositionEngine.render(time: Double(i) * 0.04, channelIDs: ids, params: box,
                                                  hostNow: Double(i) * 0.04)
            XCTAssertEqual(frames.count, Self.slotCount)
        }
        let total = clock.now - start
        let msPerFrame = (Double(total.components.attoseconds) / 1e15 + Double(total.components.seconds) * 1000) / Double(Self.frameCount)
        record("seam-render-100-slots", msPerFrame: msPerFrame)
        XCTAssertEqual(out.liveSlots.count, Self.slotCount, "slots adopted once, not per frame")
        XCTAssertLessThan(msPerFrame, 40)
    }

    func testPreviewFeedAndLayoutResolutionStayCheap() {
        let composition = Self.heavyComposition()
        let out = Composer2LiveOutput(composition: composition)
        out.setPreviewGeometry(Self.geometry(Self.slotCount))
        let feed = Composer2PreviewFeed(output: out)
        let clock = ContinuousClock()
        let start = clock.now
        var produced = 0
        for i in 0..<Self.frameCount {
            produced += feed.displayFrames(hostNow: 1000 + Double(i) / 20, features: loudAudio(i)).count
        }
        let total = clock.now - start
        let msPerFrame = (Double(total.components.attoseconds) / 1e15 + Double(total.components.seconds) * 1000) / Double(Self.frameCount)
        record("preview-feed-100-slots", msPerFrame: msPerFrame)
        XCTAssertEqual(produced, Self.slotCount * Self.frameCount)
        XCTAssertLessThan(msPerFrame, 50, "the preview runs at 20 fps on the main thread")

        let lights = (0..<34).map {
            LightDisplayItem(id: "L\($0)", name: "Light \($0)", archetype: "hue_lightstrip", isOn: true, brightness: 50,
                             colorX: 0.3, colorY: 0.3, colorTempMirek: nil, mirekMin: 153, mirekMax: 500)
        }
        let layoutStart = clock.now
        var layout = Composer2SlotLayout.empty
        for _ in 0..<20 {
            layout = Composer2SlotLayout.resolved(slots: Self.slots(Self.slotCount), lights: lights, areaName: "Big Area")
        }
        let layoutTotal = clock.now - layoutStart
        let layoutMs = (Double(layoutTotal.components.attoseconds) / 1e15 + Double(layoutTotal.components.seconds) * 1000) / 20
        record("layout-resolve-100-slots", msPerFrame: layoutMs)
        XCTAssertEqual(layout.count, Self.slotCount)
        XCTAssertEqual(layout.lightCount, 34)
        XCTAssertLessThan(layoutMs, 20)
    }

    func testEventHeavyMinuteDoesNotAccumulateWork() {
        // Thunderstorm lightning + haunted flashes for 60 s: per-frame cost at
        // the end must not exceed the start (no unbounded event ledgers).
        let composition = Self.heavyComposition()
        let g = Self.geometry(Self.slotCount)
        var state = Composer2EngineState()
        let clock = ContinuousClock()
        func window(_ from: Int) -> Double {
            let start = clock.now
            for i in from..<(from + 100) {
                _ = Composer2Engine.evaluate(composition, time: Double(i) * 0.04, geometry: g, state: &state, audio: loudAudio(i))
            }
            let d = clock.now - start
            return (Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000) / 100
        }
        _ = window(0)
        let early = window(100)
        for i in 200..<1400 {
            _ = Composer2Engine.evaluate(composition, time: Double(i) * 0.04, geometry: g, state: &state, audio: loudAudio(i))
        }
        let late = window(1400)
        record("event-minute-early", msPerFrame: early)
        record("event-minute-late", msPerFrame: late)
        XCTAssertLessThan(late, max(early * 3, early + 2), "late frames cost about what early frames cost")
    }
}
