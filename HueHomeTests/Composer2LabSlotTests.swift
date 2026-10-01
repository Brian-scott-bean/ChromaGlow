// Composer2LabSlotTests.swift
// ChromaGlow — Composer 2 lab (experimental), v2.1.
//
// Exact render-slot identity: the orchestrator publishes what it will drive
// (bridge, light, segment, channel, real position, capability) and Composer 2
// consumes that order instead of reconstructing it.

import XCTest
@testable import HueHome

@MainActor
final class Composer2LabSlotTests: XCTestCase {

    // MARK: Fixtures

    /// Raw lights with honest capabilities: a colour lamp, a colour gradient
    /// strip and a tunable-white ceiling light.
    static func rawLights() throws -> [HueLight] {
        let json = """
        [{"id":"L0","metadata":{"name":"Floor Lamp","archetype":"floor_shade"},"on":{"on":true},"owner":{"rid":"d0","rtype":"device"},
          "color":{"xy":{"x":0.45,"y":0.41},"gamut_type":"C"}},
         {"id":"L1","metadata":{"name":"TV Strip","archetype":"hue_lightstrip"},"on":{"on":true},"owner":{"rid":"d1","rtype":"device"},
          "color":{"xy":{"x":0.2,"y":0.3},"gamut_type":"C"},"gradient":{"points_capable":3}},
         {"id":"L2","metadata":{"name":"Ceiling","archetype":"ceiling_round"},"on":{"on":true},"owner":{"rid":"d2","rtype":"device"},
          "color_temperature":{"mirek":366,"mirek_schema":{"mirek_minimum":153,"mirek_maximum":454}}},
         {"id":"L3","metadata":{"name":"Hall","archetype":"pendant_round"},"on":{"on":true},"owner":{"rid":"d3","rtype":"device"},
          "dimming":{"brightness":50}}]
        """
        return try JSONDecoder().decode([HueLight].self, from: Data(json.utf8))
    }

    private func streamingSlots() throws -> [CompositionRenderSlot] {
        CompositionRenderSlot.streaming(channels: Composer2LabFixtures.config.channels,
                                        membership: Composer2LabFixtures.membership,
                                        bridgeID: "b1", lights: try Self.rawLights())
    }

    // MARK: Builders

    func testStreamingSlotsCarryExactIdentityInChannelOrder() throws {
        let slots = try streamingSlots()
        XCTAssertEqual(slots.count, 4)
        XCTAssertEqual(slots.map(\.index), [0, 1, 2, 3])
        XCTAssertEqual(slots.map(\.channelID), [0, 1, 2, 3])
        XCTAssertEqual(slots.map(\.lightID), ["L0", "L1", "L1", "L2"])
        XCTAssertEqual(slots.map(\.bridgeID), ["b1", "b1", "b1", "b1"])
        // The strip's two channels are segments 1/2 and 2/2 of ONE light.
        XCTAssertEqual(slots[1].segmentIndex, 0); XCTAssertEqual(slots[1].segmentCount, 2)
        XCTAssertEqual(slots[2].segmentIndex, 1); XCTAssertEqual(slots[2].segmentCount, 2)
        XCTAssertTrue(slots[1].isSegment); XCTAssertFalse(slots[0].isSegment)
        // Real positions, never invented.
        XCTAssertEqual(slots[0].position, CompositionSlotPosition(x: -1, y: 0, z: 0.5))
        XCTAssertEqual(slots[2].position, CompositionSlotPosition(x: 1, y: 0, z: -1))
        // Capabilities come from the light, not the archetype.
        XCTAssertEqual(slots.map(\.capability), [.color, .color, .color, .tunableWhite])
        XCTAssertEqual(slots[3].mirekRange, 153...454)
        XCTAssertNil(slots[0].mirekRange)
    }

    func testRoomModeSlotsExpandGradientSegmentsAndShareTheLightPosition() throws {
        let map = GradientChannelMap(entries: [
            GradientChannelMap.Entry(lightID: "L2", channelStart: 0, channelCount: 1),
            GradientChannelMap.Entry(lightID: "L1", channelStart: 1, channelCount: 3),
            GradientChannelMap.Entry(lightID: "L0", channelStart: 4, channelCount: 1)
        ])
        let slots = CompositionRenderSlot.roomMode(
            lightIDs: ["L2", "L1", "L0", "L3"], gradientMap: map,
            lightPositions: ["L1": (x: 0.5, z: -1), "L0": (x: -1, z: 0.5)],
            bridgeID: "b1", lights: try Self.rawLights())
        XCTAssertEqual(slots.count, 6, "1 + 3 gradient segments + 1 + 1")
        XCTAssertEqual(slots.map(\.lightID), ["L2", "L1", "L1", "L1", "L0", "L3"])
        XCTAssertEqual(slots.map(\.index), Array(0..<6))
        XCTAssertTrue(slots.allSatisfy { $0.channelID == nil }, "no DTLS channel in Room mode")
        XCTAssertEqual(slots[1...3].map(\.segmentIndex), [0, 1, 2])
        XCTAssertTrue(slots[1...3].allSatisfy { $0.segmentCount == 3 })
        XCTAssertTrue(slots[1...3].allSatisfy { $0.position == slots[1].position }, "segments share the light's position")
        XCTAssertEqual(slots[1].position, CompositionSlotPosition(x: 0.5, y: 0, z: -1))
        XCTAssertNil(slots[0].position, "no map entry, no position — never invented")
        XCTAssertEqual(slots[4].position, CompositionSlotPosition(x: -1, y: 0, z: 0.5))
        XCTAssertEqual(slots.map(\.capability), [.tunableWhite, .color, .color, .color, .color, .dimmable])
    }

    func testCapabilityMappingIsHonest() throws {
        let lights = try Self.rawLights()
        XCTAssertEqual(CompositionRenderSlot.capability(of: lights[0]), .color)
        XCTAssertEqual(CompositionRenderSlot.capability(of: lights[2]), .tunableWhite)
        XCTAssertEqual(CompositionRenderSlot.capability(of: lights[3]), .dimmable)
        XCTAssertEqual(CompositionRenderSlot.capability(of: nil), .color, "an unknown light is driven as colour, as before")
        XCTAssertEqual(CompositionRenderSlot.mirekRange(of: lights[2]), 153...454)
        XCTAssertNil(CompositionRenderSlot.mirekRange(of: lights[3]))
    }

    // MARK: Runtime consumption

    func testLiveOutputUsesExactSlotsForGeometryAndIdentity() throws {
        let slots = try streamingSlots()
        let out = Composer2LiveOutput(composition: Composer2PresetLibrary.auroraDrift)
        let box = CompositionParamBox(palette: PaletteConfig(), motion: MotionConfig(),
                                      envelope: EnvelopeConfig(), reaction: ReactionConfig())
        box.frameSource = out
        box.renderSlots = slots
        let frames = CompositionEngine.render(time: 1, channelIDs: [0, 1, 2, 3], params: box, hostNow: 1)
        XCTAssertEqual(frames.count, 4)
        XCTAssertEqual(out.liveSlots, slots, "the runtime adopted the orchestrator's slots")
        XCTAssertEqual(out.geometry.count, 4)
        XCTAssertTrue(out.geometry.hasSpatialData, "positions came from the channels")
        XCTAssertEqual(out.geometry.lightIDs, ["L0", "L1", "L1", "L2"])
        out.releaseLiveGeometry()
        XCTAssertTrue(out.liveSlots.isEmpty)
    }

    func testLightIDMasksResolveThroughSlotIdentity() throws {
        let slots = try streamingSlots()
        var composition = Composer2PresetLibrary.auroraDrift
        composition.layers[0].mask.kind = .lightIDs
        composition.layers[0].mask.lightIDs = ["L1"]
        composition.layers[0].rhythm.minBrightness = 0.5
        let out = Composer2LiveOutput(composition: composition)
        let box = CompositionParamBox(palette: PaletteConfig(), motion: MotionConfig(),
                                      envelope: EnvelopeConfig(), reaction: ReactionConfig())
        box.frameSource = out
        box.renderSlots = slots
        let frames = CompositionEngine.render(time: 2, channelIDs: [0, 1, 2, 3], params: box, hostNow: 2)
        XCTAssertEqual(frames.count, 4)
        XCTAssertEqual(frames[0].brightness, 0, accuracy: 1e-9, "the lamp is outside the mask")
        XCTAssertEqual(frames[3].brightness, 0, accuracy: 1e-9, "the ceiling is outside the mask")
        XCTAssertGreaterThan(frames[1].brightness, 0.1, "both strip segments are inside the mask")
        XCTAssertGreaterThan(frames[2].brightness, 0.1)
    }

    func testFrameCountMismatchStillFallsBackToLegacyMath() throws {
        let out = Composer2LiveOutput(composition: Composer2PresetLibrary.auroraDrift)
        let box = CompositionParamBox(palette: PaletteConfig(), motion: MotionConfig(),
                                      envelope: EnvelopeConfig(), reaction: ReactionConfig())
        box.frameSource = out
        box.renderSlots = try streamingSlots()   // 4 slots …
        let frames = CompositionEngine.render(time: 1, channelIDs: [0, 1, 2], params: box, hostNow: 1)   // … 3 channels
        XCTAssertEqual(frames.count, 3, "the loop always gets exactly one frame per channel")
        XCTAssertEqual(out.geometry.count, 3, "slot list ignored on mismatch; index geometry instead")
        XCTAssertTrue(out.liveSlots.isEmpty)
    }

    func testSlotsWithoutPositionsFallBackToBoxGeometryThenIndex() throws {
        let slots = CompositionRenderSlot.roomMode(lightIDs: ["L0", "L1", "L2"], gradientMap: nil,
                                                   lightPositions: [:], bridgeID: "b1", lights: try Self.rawLights())
        let out = Composer2LiveOutput(composition: Composer2PresetLibrary.auroraDrift)
        let box = CompositionParamBox(palette: PaletteConfig(), motion: MotionConfig(),
                                      envelope: EnvelopeConfig(), reaction: ReactionConfig())
        box.frameSource = out
        box.renderSlots = slots
        box.radialPositions = [0.2, 0.6, 1.0]
        box.angularPositions = [0.1, 0.5, 0.9]
        _ = CompositionEngine.render(time: 1, channelIDs: [0, 1, 2], params: box, hostNow: 1)
        XCTAssertEqual(out.geometry.lightIDs, ["L0", "L1", "L2"], "identity kept even without positions")
        XCTAssertTrue(out.geometry.hasSpatialData, "the box's radial/angular pairs still give geometry")
        box.radialPositions = []
        box.angularPositions = []
        box.renderSlots = CompositionRenderSlot.roomMode(lightIDs: ["L2", "L1", "L0"], gradientMap: nil,
                                                         lightPositions: [:], bridgeID: "b1", lights: try Self.rawLights())
        _ = CompositionEngine.render(time: 2, channelIDs: [0, 1, 2], params: box, hostNow: 2)
        XCTAssertEqual(out.geometry.lightIDs, ["L2", "L1", "L0"], "a new slot order is adopted")
        XCTAssertEqual(out.geometry.count, 3)
    }

    // MARK: Screen layout from slots

    func testResolvedLayoutLabelsSegmentsAndCapabilities() throws {
        let layout = Composer2SlotLayout.resolved(slots: try streamingSlots(), lights: Composer2LabFixtures.lights,
                                                  areaName: "Living Area")
        XCTAssertEqual(layout.count, 4)
        XCTAssertEqual(layout.source, .streaming(areaName: "Living Area"))
        XCTAssertFalse(layout.positionsAreEstimated)
        XCTAssertEqual(layout.slots[0].name, "Floor Lamp")
        XCTAssertTrue(layout.slots[1].name.contains("TV Strip") && layout.slots[1].name.contains("1/2"), layout.slots[1].name)
        XCTAssertTrue(layout.slots[2].name.contains("2/2"), layout.slots[2].name)
        XCTAssertEqual(layout.slots[1].segment?.index, 1, "segments are 1-based on screen")
        XCTAssertEqual(layout.slots[2].segment?.index, 2)
        XCTAssertEqual(layout.slots[2].segment?.count, 2)
        XCTAssertNil(layout.slots[0].segment)
        XCTAssertEqual(layout.slots.map(\.capability), [.color, .color, .color, .tunableWhite])
        XCTAssertEqual(layout.whiteOnlyCount, 1)
        XCTAssertFalse(layout.slots[3].isColour)
        XCTAssertEqual(layout.lightCount, 3)
        XCTAssertEqual(layout.lightIDs, ["L0", "L1", "L1", "L2"])
        // Real Entertainment coordinates map into the unit square, order kept.
        XCTAssertLessThan(layout.slots[0].x ?? 1, layout.slots[2].x ?? 0)
    }

    func testResolvedRoomModeLayoutFansSegmentsAndMarksEstimates() throws {
        let map = GradientChannelMap(entries: [GradientChannelMap.Entry(lightID: "L1", channelStart: 0, channelCount: 3)])
        let slots = CompositionRenderSlot.roomMode(lightIDs: ["L1", "L0"], gradientMap: map,
                                                   lightPositions: ["L1": (x: 0, z: 0), "L0": (x: 1, z: 1)],
                                                   bridgeID: "b1", lights: try Self.rawLights())
        let layout = Composer2SlotLayout.resolved(slots: slots, lights: Composer2LabFixtures.lights, areaName: nil)
        XCTAssertEqual(layout.source, .roomMode)
        XCTAssertEqual(layout.count, 4)
        XCTAssertTrue(layout.positionsAreEstimated, "fanned segments are display estimates, and say so")
        let xs = layout.slots[0...2].compactMap(\.x)
        XCTAssertEqual(Set(xs).count, 3, "segments are fanned apart on screen so each is tappable")
        XCTAssertEqual(layout.slots[3].name, "Floor Lamp")
        let noPositions = Composer2SlotLayout.resolved(
            slots: CompositionRenderSlot.roomMode(lightIDs: ["L0"], gradientMap: nil, lightPositions: [:],
                                                  bridgeID: "b1", lights: try Self.rawLights()),
            lights: Composer2LabFixtures.lights, areaName: nil)
        XCTAssertTrue(noPositions.positionsAreEstimated)
        XCTAssertEqual(noPositions.count, 1)
    }

    func testDisplayItemCapabilityMatchesRawCapability() {
        XCTAssertEqual(Composer2SlotLayout.capability(Composer2LabFixtures.lights[0]), .color)
        XCTAssertEqual(Composer2SlotLayout.capability(Composer2LabFixtures.lights[2]), .tunableWhite)
        // The app's display model says "no white range" as min == max.
        let dimmable = LightDisplayItem(id: "D", name: "Dim", archetype: nil, isOn: true, brightness: 10,
                                        colorX: nil, colorY: nil, colorTempMirek: nil, mirekMin: 0, mirekMax: 0)
        XCTAssertEqual(Composer2SlotLayout.capability(dimmable), .dimmable)
        XCTAssertEqual(Composer2SlotLayout.estimated(lights: Composer2LabFixtures.lights).whiteOnlyCount, 1)
    }

    /// Device round (build 58): an 8-light ceiling room laid out on the old
    /// half-width arc fused into one glow. Every pair stays a readable
    /// distance apart, positions stay on the stage, and index order still
    /// runs left to right (a chase steps down the line).
    func testManyCeilingLightsSpreadOutAndKeepTheirOrder() {
        for n in [4, 6, 8, 12] {
            let p = Composer2SlotLayout.semanticPositions(
                count: n, archetypes: Array(repeating: "sultan_bulb", count: n))
            XCTAssertEqual(p.count, n)
            for a in 0..<n {
                XCTAssertTrue((0...1).contains(p[a].x) && (0...1).contains(p[a].z))
                if a > 0 { XCTAssertGreaterThan(p[a].x, p[a - 1].x, "left to right at \(n) lights") }
                for b in (a + 1)..<n {
                    let d = ((p[a].x - p[b].x) * (p[a].x - p[b].x) + (p[a].z - p[b].z) * (p[a].z - p[b].z)).squareRoot()
                    XCTAssertGreaterThan(d, 0.1, "lights \(a) and \(b) of \(n) crowd together (\(d))")
                }
            }
        }
        // A small room keeps its familiar arc.
        let three = Composer2SlotLayout.semanticPositions(count: 3, archetypes: ["sultan_bulb", "sultan_bulb", "sultan_bulb"])
        XCTAssertEqual(three[0].x, 0.25, accuracy: 1e-9)
        XCTAssertEqual(three[2].x, 0.75, accuracy: 1e-9)
    }

}
