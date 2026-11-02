// Composer2LightRolesTests.swift
// HueHome Pro — Unit Tests ("the room is the band", step 3: light roles)
//
// Which lights are low, middle and high: the user's answer, else the
// bridge's height (z) when the area has any, else the product type, else
// middle — and the role mask that puts a layer on some heights only.

import XCTest
@testable import HueHome

final class Composer2LightRolesTests: XCTestCase {

    private var store: UserDefaults!

    override func setUp() {
        super.setUp()
        store = UserDefaults(suiteName: "Composer2LightRolesTests")!
        store.removePersistentDomain(forName: "Composer2LightRolesTests")
        Composer2LightRoles.useDefaults(store)
    }

    override func tearDown() {
        Composer2LightRoles.useDefaults(nil)
        store.removePersistentDomain(forName: "Composer2LightRolesTests")
        super.tearDown()
    }

    private func slot(_ i: Int, light: String, z: Double, archetype: String? = nil, streaming: Bool = true) -> CompositionRenderSlot {
        CompositionRenderSlot(index: i, bridgeID: "b1", lightID: light, channelID: streaming ? i : nil,
                              segmentIndex: 0, segmentCount: 1,
                              position: CompositionSlotPosition(x: Double(i) / 3, y: 0, z: z),
                              capability: .color, mirekRange: nil, archetype: archetype)
    }

    func testTheBridgeHeightDecidesWhenTheAreaHasHeights() {
        let slots = [slot(0, light: "a", z: -0.8), slot(1, light: "b", z: 0), slot(2, light: "c", z: 0.9),
                     slot(3, light: "d", z: -0.2, archetype: "pendant_round")]
        let r = Composer2LightRoles.resolve(slots, answers: [:])
        XCTAssertEqual(r.map(\.role), [.low, .middle, .high, .middle], "z thirds; z beats the product type")
        XCTAssertEqual(r.map(\.source), [.bridge, .bridge, .bridge, .bridge])
    }

    func testAFlatAreaFallsBackToTheProductType() {
        // ChromaGlow's own area builder writes z = 0 for every light.
        let slots = [slot(0, light: "a", z: 0, archetype: "floor_shade"), slot(1, light: "b", z: 0, archetype: "ceiling_round"),
                     slot(2, light: "c", z: 0, archetype: "table_shade"), slot(3, light: "d", z: 0, archetype: "classic_bulb"),
                     slot(4, light: "e", z: 0, archetype: nil)]
        let r = Composer2LightRoles.resolve(slots, answers: [:])
        XCTAssertEqual(r.map(\.role), [.low, .high, .middle, .middle, .middle])
        XCTAssertEqual(r.map(\.source), [.product, .product, .product, .unknown, .unknown])
    }

    func testRoomModePositionsAreNotHeights() {
        // Room mode's z is the floor plan's depth.
        let slots = [slot(0, light: "a", z: -0.9, streaming: false), slot(1, light: "b", z: 0.9, streaming: false)]
        XCTAssertEqual(Composer2LightRoles.resolve(slots, answers: [:]).map(\.source), [.unknown, .unknown])
    }

    func testTheUsersAnswerWinsAndIsKept() {
        let slots = [slot(0, light: "a", z: -0.8), slot(1, light: "b", z: 0.9)]
        let before = Composer2LightRoles.version
        Composer2LightRoles.setAnswer(.high, lightID: "a")
        XCTAssertNotEqual(Composer2LightRoles.version, before, "renderers re-resolve")
        let r = Composer2LightRoles.resolve(slots, answers: Composer2LightRoles.answers())
        XCTAssertEqual(r[0].role, .high)
        XCTAssertEqual(r[0].source, .answer)
        XCTAssertEqual(r[1].source, .bridge)
        // Kept on the phone: a fresh read of the same store sees it.
        Composer2LightRoles.useDefaults(store)
        XCTAssertEqual(Composer2LightRoles.answers()["a"], .high)
        Composer2LightRoles.setAnswer(nil, lightID: "a")
        XCTAssertNil(Composer2LightRoles.answers()["a"], "cleared")
    }

    func testCanSplitNeedsALowAndAHighLight() {
        XCTAssertTrue(Composer2LightRoles.canSplit([.low, .middle, .high]))
        XCTAssertFalse(Composer2LightRoles.canSplit([.middle, .middle]))
        XCTAssertFalse(Composer2LightRoles.canSplit([.low, .low, .middle]))
    }

    // MARK: - The role mask

    func testARoleMaskCoversItsHeightsOnly() {
        let g = Composer2SlotGeometry.linear(count: 4).withRoles([.low, .middle, .high, .low])
        XCTAssertEqual(Composer2LayerMask.role([.low]).weights(geometry: g, seed: 1), [1, 0, 0, 1])
        XCTAssertEqual(Composer2LayerMask.role([.middle, .high]).weights(geometry: g, seed: 1), [0, 1, 1, 0])
        var inverted = Composer2LayerMask.role([.low])
        inverted.invert = true
        XCTAssertEqual(inverted.weights(geometry: g, seed: 1), [0, 1, 1, 0])
    }

    func testUnknownHeightsMeanTheWholeRoom() {
        let g = Composer2SlotGeometry.linear(count: 3)
        XCTAssertEqual(Composer2LayerMask.role([.low]).weights(geometry: g, seed: 1), [1, 1, 1], "never a silent no-op")
        XCTAssertEqual(g.withRoles([.low]).roles, [], "a role per slot or none")
        XCTAssertEqual(g.withRoles([.low, .high, .low]).withLightIDs(["a", "b", "c"]).roles, [.low, .high, .low])
    }

    func testRoleMasksSaveAndOtherMasksEncodeAsBefore() throws {
        let m = Composer2LayerMask.role([.low, .high])
        let decoded = try JSONDecoder().decode(Composer2LayerMask.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(decoded, m)
        let whole = String(data: try JSONEncoder().encode(Composer2LayerMask.wholeRoom), encoding: .utf8) ?? ""
        XCTAssertFalse(whole.contains("roles"), "masks without roles encode exactly as before")
        let future = Data(#"{"kind":"role","roles":["low","basement"]}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(Composer2LayerMask.self, from: future).roles, [.low], "unknown heights dropped")
        let older = Data(#"{"kind":"region","regionX0":0.2}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(Composer2LayerMask.self, from: older).roles, [])
    }

    // MARK: - Live

    func testTheLiveGeometryCarriesRolesAndFollowsAnAnswer() {
        var layer = Composer2Layer(name: "Low", color: .solid(Composer2XY(x: 0.3127, y: 0.329)),
                                   motion: Composer2Motion(kind: .static),
                                   rhythm: Composer2Rhythm(shape: .steady, maxBrightness: 0.8))
        layer.mask = .role([.low])
        let look = Composer2Composition(name: "Low", createdAt: Date(timeIntervalSince1970: 0), layers: [layer])
        let output = Composer2LiveOutput(composition: look)
        let slots = [slot(0, light: "a", z: -0.8), slot(1, light: "b", z: 0.9)]
        let layout = CompositionLiveLayout(radial: [0, 1], angular: [0, 0.5], slots: slots, outputLead: 0)
        func run(from t0: Double) -> [LightFrame] {
            var frames: [LightFrame] = []
            for k in 0..<40 {
                frames = output.renderLiveFrames(time: t0 + Double(k) * 0.02, channelIDs: [0, 1], layout: layout,
                                                 features: .silent, beat: .none, hostNow: 0)
            }
            return frames
        }
        var frames = run(from: 1)
        XCTAssertEqual(output.geometry.roles, [.low, .high])
        XCTAssertEqual(frames.count, 2)
        XCTAssertGreaterThan(frames.first?.brightness ?? 0, 0.5, "the low light")
        XCTAssertLessThan(frames.last?.brightness ?? 1, 0.05, "not the high one")
        Composer2LightRoles.setAnswer(.low, lightID: "b")
        frames = run(from: 2)
        XCTAssertEqual(output.geometry.roles, [.low, .low], "an answer reaches the running look")
        XCTAssertGreaterThan(frames.last?.brightness ?? 0, 0.5)
    }
}
