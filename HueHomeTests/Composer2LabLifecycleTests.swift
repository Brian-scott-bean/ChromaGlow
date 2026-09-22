// Composer2LabLifecycleTests.swift
// ChromaGlow — Composer 2 lab. The document, the room layouts, and the
// playback center's lifecycle against a fake gateway: gated starts, honest
// refusals, audition-vs-applied, heartbeat verdicts, and edits flowing to
// the runtime. Hermetic — injected clock, no orchestrator, no waiting.

import XCTest
@testable import HueHome

// MARK: - Fake gateway

@MainActor
final class Composer2FakeGateway: Composer2LiveGateway {
    var gateResult: Composer2LiveGate = .ready
    var availability = Composer2StreamAvailability(prefer: true, severalAreas: false)
    var startOutcome: Composer2StartOutcome = .started(.streaming)
    var claimed = true
    /// Whether the orchestrator still renders the box it was given.
    var driving = true
    var transportMode: Composer2PlayMode? = nil
    var demo = false
    var startCalls: [(roomID: String, preferStreaming: Bool)] = []
    var stopCalls: [String] = []
    var boxes: [CompositionParamBox] = []
    var lights: [LightDisplayItem] = Composer2LabFixtures.lights
    /// When set, `start` asks the takeover question and honours the answer.
    var foreignControllerPresent = false
    var takeoverAsked = 0
    /// Exact slots the orchestrator would publish on the box at start.
    var renderSlots: [CompositionRenderSlot] = []
    var publishCalls: [(roomID: String, name: String)] = []
    var retireCalls: [String] = []
    var stopHandler: (@MainActor (String?, String) async -> Bool)?
    var stopHandlerInstalls = 0

    func gate(for room: RoomDisplayItem?) -> Composer2LiveGate { gateResult }
    func streamAvailability(for room: RoomDisplayItem) -> Composer2StreamAvailability { availability }
    func warm(room: RoomDisplayItem) async {}
    func streamingLayout(room: RoomDisplayItem, lights: [LightDisplayItem]) -> Composer2SlotLayout? {
        Composer2SlotLayout.streaming(config: Composer2LabFixtures.config, membership: Composer2LabFixtures.membership, lights: lights)
    }
    func roomLayout(room: RoomDisplayItem, lights: [LightDisplayItem]) -> Composer2SlotLayout {
        Composer2SlotLayout.estimated(lights: lights)
    }
    func lightItems(room: RoomDisplayItem) -> [LightDisplayItem] { lights }
    func rooms() -> [RoomDisplayItem] { [Composer2LabFixtures.room("r1"), Composer2LabFixtures.room("r2")] }
    func isDemo() -> Bool { demo }
    func start(room: RoomDisplayItem, box: CompositionParamBox, preferStreaming: Bool,
               askTakeover: @escaping @MainActor () async -> Bool) async -> Composer2StartOutcome {
        startCalls.append((room.id, preferStreaming))
        boxes.append(box)
        if foreignControllerPresent {
            takeoverAsked += 1
            let approved = await askTakeover()
            if !approved { return .declined }
        }
        if case .started = startOutcome { box.renderSlots = renderSlots }
        return startOutcome
    }
    func stop(roomID: String, bridgeID: String?) async { stopCalls.append(roomID) }
    func isRoomClaimed(roomID: String, bridgeID: String?) -> Bool { claimed }
    func isDriving(box: CompositionParamBox) -> Bool { driving }
    func transport(roomID: String, bridgeID: String?) -> Composer2PlayMode? { transportMode }
    func publishNowPlaying(roomID: String, bridgeID: String?, roomName: String,
                           groupedLightID: String?, compositionName: String) {
        publishCalls.append((roomID, compositionName))
    }
    func retireNowPlaying(roomID: String, bridgeID: String?) { retireCalls.append(roomID) }
    func installStopHandler(_ handler: (@MainActor (String?, String) async -> Bool)?) {
        stopHandler = handler
        stopHandlerInstalls += 1
    }
}

enum Composer2LabFixtures {
    static func room(_ id: String, refs: [(rid: String, rtype: String)] = []) -> RoomDisplayItem {
        RoomDisplayItem(id: id, name: "Room \(id)", archetype: "living_room", isOn: true, brightness: 70,
                        groupedLightID: "g-\(id)", lightCount: 3, bridgeID: "b1", childResourceRefs: refs)
    }

    static let lights: [LightDisplayItem] = [
        LightDisplayItem(id: "L0", name: "Floor Lamp", archetype: "floor_shade", isOn: true, brightness: 80,
                         colorX: 0.45, colorY: 0.41, colorTempMirek: nil, mirekMin: 153, mirekMax: 500),
        LightDisplayItem(id: "L1", name: "TV Strip", archetype: "hue_lightstrip", isOn: true, brightness: 60,
                         colorX: 0.2, colorY: 0.3, colorTempMirek: nil, mirekMin: 153, mirekMax: 500),
        LightDisplayItem(id: "L2", name: "Ceiling", archetype: "ceiling_round", isOn: true, brightness: 90,
                         colorX: nil, colorY: nil, colorTempMirek: 366, mirekMin: 153, mirekMax: 500)
    ]

    static let config = EntertainmentConfig(id: "cfg", name: "Living Area", channels: [
        EntertainmentChannel(id: 0, lightServiceIDs: ["e0"], position: (x: -1, y: 0, z: 0.5)),
        EntertainmentChannel(id: 1, lightServiceIDs: ["e1"], position: (x: 0, y: 0, z: -1)),
        EntertainmentChannel(id: 2, lightServiceIDs: ["e1"], position: (x: 1, y: 0, z: -1)),
        EntertainmentChannel(id: 3, lightServiceIDs: ["e2"], position: (x: 0.5, y: 0, z: 1))
    ])
    static let membership = ["e0": "L0", "e1": "L1", "e2": "L2"]

    static func rawLights() throws -> [HueLight] {
        let json = """
        [{"id":"L2","metadata":{"name":"Ceiling","archetype":"ceiling_round"},"on":{"on":true},"owner":{"rid":"d2","rtype":"device"}},
         {"id":"L0","metadata":{"name":"Floor Lamp","archetype":"floor_shade"},"on":{"on":true},"owner":{"rid":"d0","rtype":"device"}},
         {"id":"L1","metadata":{"name":"TV Strip","archetype":"hue_lightstrip"},"on":{"on":true},"owner":{"rid":"d1","rtype":"device"},
          "gradient":{"points_capable":3}}]
        """
        return try JSONDecoder().decode([HueLight].self, from: Data(json.utf8))
    }
}

// MARK: - Tests

@MainActor
final class Composer2LabLifecycleTests: XCTestCase {

    private func document(_ composition: Composer2Composition = Composer2PresetLibrary.auroraDrift,
                          room: RoomDisplayItem? = Composer2LabFixtures.room("r1")) -> Composer2Document {
        var context = Composer2RoomContext(room: room)
        context.lights = Composer2LabFixtures.lights
        context.layout = Composer2SlotLayout.estimated(lights: Composer2LabFixtures.lights)
        return Composer2Document(composition: composition, roomContext: context)
    }

    /// A center with the Composer 2 screen showing (auditions need a viewer).
    private func center(now: Double = 100) -> Composer2PlaybackCenter {
        let c = Composer2PlaybackCenter(observeApplication: false)
        c.now = { now }
        c.attachScreen()
        return c
    }

    // MARK: Document

    func testDocumentDefaultsAndSynchronousEdits() {
        let doc = document()
        XCTAssertEqual(doc.mode, .customize)
        XCTAssertFalse(doc.isDirty)
        var fired = 0
        doc.onEdit = { fired += 1 }
        doc.edit { $0.master.intensity = 0.4 }
        XCTAssertEqual(fired, 1)
        XCTAssertTrue(doc.isDirty)
        XCTAssertEqual(doc.composition.master.intensity, 0.4)
        XCTAssertFalse(doc.usesAudio)
        doc.editSelectedLayer { $0.audio.source = .bass }
        XCTAssertTrue(doc.usesAudio)
        doc.rename("  Northern Sky ", subtitle: "Cold and slow")
        XCTAssertEqual(doc.composition.name, "Northern Sky")
        XCTAssertEqual(doc.composition.subtitle, "Cold and slow")
        doc.rename("   ")
        XCTAssertEqual(doc.composition.name, "Northern Sky")
        doc.toggleSlot(2)
        XCTAssertEqual(doc.selectedLayer.mask.kind, .slots)
        XCTAssertEqual(doc.selectedLayer.mask.slots, [2])
        doc.toggleSlot(2)
        XCTAssertEqual(doc.selectedLayer.mask.kind, .wholeRoom)
    }

    func testExpertStackOperations() {
        let doc = document(Composer2PresetLibrary.thunderstorm)
        XCTAssertEqual(doc.composition.layers.count, 2)
        let added = doc.addLayer(.blank(name: "Sparkle"))
        XCTAssertEqual(doc.composition.layers.count, 3)
        XCTAssertEqual(doc.selectedLayerID, added.id)
        doc.duplicateLayer(id: added.id)
        XCTAssertEqual(doc.composition.layers.count, 4)
        XCTAssertEqual(doc.composition.layers[3].name, "Sparkle copy")
        doc.moveLayer(id: added.id, up: true)
        XCTAssertEqual(doc.composition.layers[1].id, added.id)
        doc.setLayer(id: added.id, enabled: false)
        XCTAssertFalse(doc.composition.layers[1].enabled)
        XCTAssertTrue(doc.removeLayer(id: added.id))
        XCTAssertEqual(doc.composition.layers.count, 3)
        for layer in doc.composition.layers.dropFirst() { _ = doc.removeLayer(id: layer.id) }
        XCTAssertEqual(doc.composition.layers.count, 1)
        XCTAssertFalse(doc.removeLayer(id: doc.composition.layers[0].id), "the last behavior stays")
        doc.setDimension(.motion, on: false)
        XCTAssertEqual(doc.selectedLayer.motion.kind, .static)
        doc.setDimension(.motion, on: true)
        XCTAssertNotEqual(doc.selectedLayer.motion.kind, .static)
    }

    /// The light selection belongs to the selected behavior. It used to be
    /// one document-wide set, so choosing lights for one behavior and then
    /// tapping a light on another rewrote the second behavior's mask with
    /// the first behavior's lights.
    func testLightSelectionFollowsTheSelectedBehavior() throws {
        let doc = document(Composer2PresetLibrary.thunderstorm)
        let sky = doc.composition.layers[0].id
        let lightning = doc.composition.layers[1].id

        doc.select(layerID: lightning)
        doc.toggleSlot(0)
        doc.toggleSlot(2)
        XCTAssertEqual(doc.selectedSlots, [0, 2])
        XCTAssertEqual(doc.composition.layers[1].mask.slots, [0, 2])

        doc.select(layerID: sky)
        XCTAssertEqual(doc.selectedSlots, [], "the sky layer lights the whole room; nothing is picked")
        doc.toggleSlot(1)
        XCTAssertEqual(doc.composition.layers[0].mask.slots, [1], "only the light tapped for THIS behavior")
        XCTAssertEqual(doc.composition.layers[1].mask.slots, [0, 2], "the other behavior is untouched")

        doc.select(layerID: lightning)
        XCTAssertEqual(doc.selectedSlots, [0, 2], "coming back shows that behavior's own lights")

        // Reopening a saved composition shows its first behavior's selection.
        var saved = doc.composition
        saved.layers.swapAt(0, 1)
        doc.load(saved)
        XCTAssertEqual(doc.selectedSlots, [0, 2])
        let fresh = Composer2Document(composition: saved)
        XCTAssertEqual(fresh.selectedSlots, [0, 2])
    }

    // MARK: Layouts

    func testStreamingLayoutUsesRealPositionsAndMembership() {
        let layout = Composer2SlotLayout.streaming(config: Composer2LabFixtures.config,
                                                   membership: Composer2LabFixtures.membership,
                                                   lights: Composer2LabFixtures.lights)
        XCTAssertFalse(layout.positionsAreEstimated)
        XCTAssertEqual(layout.count, 4)
        XCTAssertEqual(layout.lightCount, 3)
        XCTAssertEqual(layout.slots.map(\.name), ["Floor Lamp", "TV Strip · 1/2", "TV Strip · 2/2", "Ceiling"])
        XCTAssertEqual(layout.slots[0].x!, 0, accuracy: 1e-9)
        XCTAssertEqual(layout.slots[0].z!, 0.25, accuracy: 1e-9)
        XCTAssertEqual(layout.slots[3].x!, 0.75, accuracy: 1e-9)
        XCTAssertEqual(layout.lightIDs, ["L0", "L1", "L1", "L2"])
        XCTAssertTrue(layout.geometry.hasSpatialData)
        if case .streaming(let area) = layout.source { XCTAssertEqual(area, "Living Area") } else { XCTFail("source") }
    }

    func testRoomModeLayoutFollowsResolverOrderAndExpandsStrips() throws {
        let raw = try Composer2LabFixtures.rawLights()
        let room = Composer2LabFixtures.room("r1", refs: [(rid: "L2", rtype: "light"), (rid: "L1", rtype: "light"), (rid: "L0", rtype: "light")])
        let layout = Composer2SlotLayout.roomMode(room: room, rawLights: raw, lights: Composer2LabFixtures.lights)
        XCTAssertTrue(layout.positionsAreEstimated)
        XCTAssertEqual(layout.source, .roomMode)
        XCTAssertEqual(layout.slots.map(\.lightID), ["L2", "L1", "L1", "L1", "L0"], "ref order, strip expanded to 3 slots")
        XCTAssertEqual(layout.lightCount, 3)
        XCTAssertEqual(layout.slots[2].name, "TV Strip · 2/3")
    }

    func testEstimatedAndEmptyLayouts() {
        let estimated = Composer2SlotLayout.estimated(lights: Composer2LabFixtures.lights)
        XCTAssertTrue(estimated.positionsAreEstimated)
        XCTAssertEqual(estimated.source, .estimated)
        XCTAssertEqual(estimated.count, 3)
        XCTAssertTrue(estimated.geometry.hasSpatialData, "estimated positions still lay out the preview")
        XCTAssertEqual(Composer2SlotLayout.empty.geometry.count, 0)
        XCTAssertEqual(Composer2SlotLayout.estimated(lights: []).count, 0)
        // Deterministic: the same lights lay out the same way twice.
        XCTAssertEqual(estimated, Composer2SlotLayout.estimated(lights: Composer2LabFixtures.lights))
    }

    // MARK: Playback center — gates

    func testGatesNeverCallStart() async {
        for (gate, copy) in [(Composer2LiveGate.demo, Composer2Copy.liveDemoUnavailable),
                             (.noBridge, Composer2Copy.liveNoBridge),
                             (.noRoom, Composer2Copy.liveNoRoom)] {
            let gw = Composer2FakeGateway()
            gw.gateResult = gate
            let c = center()
            let doc = document()
            let out = Composer2LiveOutput(composition: doc.composition)
            let status = await c.start(document: doc, output: out, gateway: gw, audition: true)
            XCTAssertEqual(status, .failed(copy))
            XCTAssertTrue(gw.startCalls.isEmpty)
            XCTAssertNil(c.session)
            XCTAssertFalse(c.isLive)
        }
    }

    func testStreamingStartBindsTheRuntimeToACoherentBox() async {
        let gw = Composer2FakeGateway()
        let c = center()
        let doc = document(Composer2PresetLibrary.christmasChase)
        let out = Composer2LiveOutput(composition: doc.composition)
        let status = await c.start(document: doc, output: out, gateway: gw, audition: true)
        XCTAssertEqual(status, .live)
        XCTAssertTrue(c.isLive)
        XCTAssertEqual(c.session?.playMode, .streaming)
        XCTAssertEqual(c.session?.isAudition, true)
        XCTAssertEqual(c.session?.roomID, "r1")
        XCTAssertEqual(c.statusText, Composer2Copy.liveStreaming)
        XCTAssertTrue(c.output === out)
        let box = gw.boxes[0]
        XCTAssertTrue(box.frameSource === out)
        let stops = doc.composition.primaryStops
        XCTAssertEqual(box.palette.color1.x, stops[0].x, accuracy: 1e-12)
        XCTAssertEqual(box.palette.color2.y, stops[1].y, accuracy: 1e-12)
        XCTAssertEqual(box.motion.pattern, .static)
        XCTAssertEqual(box.envelope.shape, .steady)
        XCTAssertEqual(box.reaction.source, .none)
        XCTAssertTrue(gw.startCalls[0].preferStreaming)
        XCTAssertFalse(doc.roomContext.layout.positionsAreEstimated, "streaming layout with real positions")
    }

    func testForeignControllerIsRefusedHonestly() async {
        let gw = Composer2FakeGateway()
        gw.startOutcome = .foreignController
        let c = center()
        let doc = document()
        let out = Composer2LiveOutput(composition: doc.composition)
        let status = await c.start(document: doc, output: out, gateway: gw, audition: true)
        XCTAssertEqual(status, .failed(Composer2Copy.liveForeignController))
        XCTAssertNil(c.session)
        XCTAssertNil(c.output)
        XCTAssertNil(gw.boxes[0].frameSource, "the box is unbound so nothing keeps rendering")
        XCTAssertTrue(gw.stopCalls.isEmpty)
    }

    func testFailedStartCarriesTheMessage() async {
        let gw = Composer2FakeGateway()
        gw.startOutcome = .failed("Nope")
        let c = center()
        let doc = document()
        let status = await c.start(document: doc, output: Composer2LiveOutput(composition: doc.composition), gateway: gw, audition: true)
        XCTAssertEqual(status, .failed("Nope"))
        c.clearNotice()
        XCTAssertEqual(c.status, .idle)
    }

    func testRoomModeStartRelabelsTheLayout() async {
        let gw = Composer2FakeGateway()
        gw.startOutcome = .started(.roomMode)
        gw.availability = Composer2StreamAvailability(prefer: false, severalAreas: true)
        let c = center()
        let doc = document()
        _ = await c.start(document: doc, output: Composer2LiveOutput(composition: doc.composition), gateway: gw, audition: true)
        XCTAssertEqual(c.session?.playMode, .roomMode)
        XCTAssertTrue(c.severalAreas)
        XCTAssertTrue(doc.roomContext.layout.positionsAreEstimated)
        XCTAssertFalse(gw.startCalls[0].preferStreaming)
    }

    // MARK: Heartbeat

    func testHeartbeatVerdictTable() {
        typealias H = Composer2Heartbeat
        XCTAssertEqual(H.verdict(lastLiveRenderAt: 100, startedAt: 90, now: 100.5, roomStillClaimed: true), .alive)
        XCTAssertEqual(H.verdict(lastLiveRenderAt: 0, startedAt: 100, now: 100.9, roomStillClaimed: true), .alive)
        XCTAssertEqual(H.verdict(lastLiveRenderAt: 100, startedAt: 90, now: 103, roomStillClaimed: true), .reconnecting)
        // Our box, silent past the window: lost — claimed or not.
        XCTAssertEqual(H.verdict(lastLiveRenderAt: 100, startedAt: 90, now: 109, roomStillClaimed: true), .lost)
        // Unclaimed and not ours: a failover in flight is still "reconnecting"…
        XCTAssertEqual(H.verdict(lastLiveRenderAt: 100, startedAt: 90, now: 103, roomStillClaimed: false,
                                 drivingOurs: false), .reconnecting)
        // …until the whole window has passed.
        XCTAssertEqual(H.verdict(lastLiveRenderAt: 100, startedAt: 90, now: 109, roomStillClaimed: false,
                                 drivingOurs: false), .lost)
        // Claimed by a box that is not ours: replaced, at once.
        XCTAssertEqual(H.verdict(lastLiveRenderAt: 100, startedAt: 90, now: 101.2, roomStillClaimed: true,
                                 drivingOurs: false), .replaced)
    }

    func testHeartbeatEndedNeverCallsStopAndReleasesTheRuntime() async {
        let gw = Composer2FakeGateway()
        let c = center(now: 100)
        let doc = document()
        let out = Composer2LiveOutput(composition: doc.composition)
        _ = await c.start(document: doc, output: out, gateway: gw, audition: false)
        // Silent for 3 s but still claimed: reconnecting.
        c.now = { 103 }
        XCTAssertTrue(c.tickHeartbeat())
        XCTAssertEqual(c.status, .reconnecting)
        // The loop renders again: alive.
        let box = gw.boxes[0]
        _ = CompositionEngine.render(time: 3, channelIDs: [0, 1, 2], params: box, hostNow: 103.2)
        c.now = { 103.3 }
        XCTAssertTrue(c.tickHeartbeat())
        XCTAssertEqual(c.status, .live)
        // Another look took the room (it is claimed, but not by our box):
        // replaced, and NO stop is sent.
        gw.driving = false
        c.now = { 105 }
        XCTAssertFalse(c.tickHeartbeat())
        XCTAssertEqual(c.status, .ended(Composer2Copy.liveEndedElsewhere))
        XCTAssertNil(c.session)
        XCTAssertNil(box.frameSource, "nothing renders our box any more, so it lets go")
        XCTAssertTrue(gw.stopCalls.isEmpty, "the replacement is never stopped")
        XCTAssertEqual(gw.retireCalls, ["r1"], "retire is asked; it removes only a row that is still ours")
        XCTAssertNil(gw.stopHandler, "the Dashboard route is uninstalled with the session")
    }

    /// A DTLS→REST failover drops the room's claim before its awaits. The
    /// session must ride through it (and learn it is in Room mode now),
    /// not end after one silent second and orphan the re-entered look.
    func testFailoverToRoomModeIsReconnectingThenLiveInRoomMode() async {
        let gw = Composer2FakeGateway()
        let c = center(now: 100)
        let doc = document()
        let out = Composer2LiveOutput(composition: doc.composition)
        _ = await c.start(document: doc, output: out, gateway: gw, audition: false)
        XCTAssertEqual(c.session?.playMode, .streaming)
        gw.claimed = false
        gw.driving = false
        c.now = { 104 }
        XCTAssertTrue(c.tickHeartbeat())
        XCTAssertEqual(c.status, .reconnecting)
        XCTAssertNotNil(c.session)
        // Room mode picked our box up again.
        gw.claimed = true
        gw.driving = true
        gw.transportMode = .roomMode
        _ = CompositionEngine.render(time: 4, channelIDs: [0, 1, 2], params: gw.boxes[0], hostNow: 104.1)
        c.now = { 104.2 }
        XCTAssertTrue(c.tickHeartbeat())
        XCTAssertEqual(c.status, .live)
        XCTAssertEqual(c.session?.playMode, .roomMode, "the status says Room mode after a failover")
        XCTAssertTrue(gw.stopCalls.isEmpty)
    }

    /// The runtime plays what the document holds when Live is pressed — the
    /// screen's output used to keep the composition it was created with, so
    /// a mood picked before Live never reached the lights.
    func testStartPlaysTheDocumentsCurrentComposition() async {
        let gw = Composer2FakeGateway()
        let c = center()
        let doc = document(Composer2PresetLibrary.auroraDrift)
        let out = Composer2LiveOutput(composition: Composer2PresetLibrary.auroraDrift)
        doc.load(Composer2PresetLibrary.thunderstorm)
        XCTAssertNotEqual(out.composition, doc.composition)
        _ = await c.start(document: doc, output: out, gateway: gw, audition: true)
        XCTAssertEqual(out.composition, doc.composition)
        XCTAssertEqual(c.session?.compositionName, "Thunderstorm")
    }

    // MARK: Audition vs applied, room change, promotion

    func testAuditionEndsOnDismissButAppliedSurvives() async {
        let gw = Composer2FakeGateway()
        let c = center()
        let doc = document()
        let out = Composer2LiveOutput(composition: doc.composition)
        _ = await c.start(document: doc, output: out, gateway: gw, audition: true)
        let task = c.endAudition(gateway: gw)
        XCTAssertNotNil(task)
        await task?.value
        XCTAssertEqual(gw.stopCalls, ["r1"])
        XCTAssertNil(c.session)
        XCTAssertEqual(c.status, .idle)

        _ = await c.start(document: doc, output: out, gateway: gw, audition: false)
        XCTAssertNil(c.endAudition(gateway: gw))
        XCTAssertNotNil(c.session)
        XCTAssertEqual(c.session?.isAudition, false)
        XCTAssertTrue(c.retainedDocument(for: "r1") === doc)
        XCTAssertNil(c.retainedDocument(for: "r2"))
    }

    func testRoomChangeStopsTheOldRoomFirstAndSameRoomPromotes() async {
        let gw = Composer2FakeGateway()
        let c = center()
        let doc1 = document(room: Composer2LabFixtures.room("r1"))
        let out = Composer2LiveOutput(composition: doc1.composition)
        _ = await c.start(document: doc1, output: out, gateway: gw, audition: true)
        _ = await c.start(document: doc1, output: out, gateway: gw, audition: false)
        XCTAssertEqual(gw.startCalls.count, 1, "starting again on the same room promotes instead of restarting")
        XCTAssertEqual(c.session?.isAudition, false)

        let doc2 = document(room: Composer2LabFixtures.room("r2"))
        _ = await c.start(document: doc2, output: Composer2LiveOutput(composition: doc2.composition), gateway: gw, audition: true)
        XCTAssertEqual(gw.stopCalls, ["r1"])
        XCTAssertEqual(gw.startCalls.map(\.roomID), ["r1", "r2"])
        XCTAssertEqual(c.session?.roomID, "r2")

        await c.stop(gateway: gw)
        XCTAssertEqual(gw.stopCalls, ["r1", "r2"])
        XCTAssertNil(c.session)
        XCTAssertNil(c.output)
    }

    func testEditsWhileLiveFlowToTheRuntimeAndMirrorTheMic() async {
        let gw = Composer2FakeGateway()
        let c = center()
        let doc = document()
        let out = Composer2LiveOutput(composition: doc.composition)
        _ = await c.start(document: doc, output: out, gateway: gw, audition: true)
        let box = gw.boxes[0]
        doc.rename("Sky River")
        XCTAssertEqual(out.composition.name, "Sky River")
        XCTAssertEqual(c.session?.compositionName, "Sky River")
        doc.editSelectedLayer { $0.audio.source = .bass }
        XCTAssertEqual(box.reaction.source, .micAmplitude, "the orchestrator now holds the microphone for us")
        doc.editSelectedLayer { $0.audio.source = .beat }
        XCTAssertEqual(box.reaction.source, .beat)
        doc.editSelectedLayer { $0.audio.source = .off }
        XCTAssertEqual(box.reaction.source, .none)
        doc.editSelectedLayer { $0.motion.periodSeconds = 3 }
        XCTAssertEqual(out.composition.layers[0].motion.periodSeconds, 3)
    }

    // MARK: Preview feed

    func testPreviewFeedMirrorsLiveFramesAndEvaluatesOtherwise() {
        let doc = document()
        let out = Composer2LiveOutput(composition: doc.composition)
        out.setPreviewGeometry(doc.roomContext.layout.geometry)
        let feed = Composer2PreviewFeed(output: out)
        XCTAssertFalse(feed.isMirroringLive(hostNow: 100))
        let frames = feed.displayFrames(hostNow: 100)
        XCTAssertEqual(frames.count, 3)
        let box = CompositionParamBox(preset: CompositionStore.builtInPresets[0])
        box.frameSource = out
        _ = CompositionEngine.render(time: 1, channelIDs: [0, 1, 2, 3, 4], params: box, hostNow: 200)
        XCTAssertTrue(feed.isMirroringLive(hostNow: 200.1))
        XCTAssertEqual(feed.displayFrames(hostNow: 200.1).count, 5, "the hero shows the frames the lights got")
        XCTAssertTrue(feed.isMirroringLive(hostNow: 201), "a sparse Room-mode cadence still counts as live")
        XCTAssertFalse(feed.isMirroringLive(hostNow: 203.5))
        out.releaseLiveGeometry()
        XCTAssertFalse(feed.isMirroringLive(hostNow: 200.2), "a stop hands the hero straight back to the preview")
    }

    /// Room mode renders a room every 120 ms or more, and several rooms
    /// rotate. The preview must never advance the SHARED engine state on
    /// its own clock between two live renders: the next live frame would
    /// jump the engine time backwards, reset the state, and re-arm every
    /// event schedule — so lightning never struck in Room mode.
    func testPreviewNeverRewindsTheSharedEngineBetweenSparseLiveRenders() {
        var composition = Composer2PresetLibrary.thunderstorm
        // Fire an opportunity every second, always, so a reset is visible.
        for i in composition.layers.indices where composition.layers[i].events != nil {
            composition.layers[i].events?.timing = .fixed
            composition.layers[i].events?.interval = 1
            composition.layers[i].events?.probability = 1
            composition.layers[i].events?.majorProbability = 0
        }
        let out = Composer2LiveOutput(composition: composition)
        let feed = Composer2PreviewFeed(output: out)
        let box = CompositionParamBox(preset: CompositionStore.builtInPresets[0])
        box.frameSource = out
        let channels = [0, 1, 2, 3, 4]
        var host = 500.0
        var liveTime = 0.0
        var previewRuns = 0
        // 30 s of a 0.6 s live cadence with a 20 fps hero in between.
        while liveTime < 30 {
            _ = CompositionEngine.render(time: liveTime, channelIDs: channels, params: box, hostNow: host)
            for _ in 0..<12 {
                host += 0.05
                _ = feed.displayFrames(hostNow: host)
                previewRuns += 1
            }
            liveTime += 0.6
        }
        XCTAssertGreaterThan(previewRuns, 500)
        XCTAssertEqual(out.lastRenderTime ?? -1, liveTime - 0.6, accuracy: 1e-9,
                       "only the live clock may move the shared engine")
        let fired = out.state.layers.compactMap(\.events).map(\.firedCount).max() ?? 0
        XCTAssertGreaterThanOrEqual(fired, 10, "the event schedule survived the whole run")
    }
}
