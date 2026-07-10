// RoomAggregateTests.swift
// HueHome Pro — Unit Tests
//
// Master-bar live-update fix: the room/zone bar derives from the complete
// member-light list. Locks the pure aggregate math AND the two live paths
// that used to leave the bar stale — optimistic per-light taps and the SSE
// stream (which previously filtered out grouped_light events entirely and
// never recomputed the aggregate).

import XCTest
@testable import HueHome

@MainActor
final class RoomAggregateTests: XCTestCase {

    // ── Fixtures ──────────────────────────────────────────────

    private func light(_ id: String, on: Bool, brightness: Double) -> LightDisplayItem {
        LightDisplayItem(
            id: id, name: "Light \(id)", archetype: nil,
            isOn: on, brightness: brightness,
            colorX: nil, colorY: nil,
            colorTempMirek: nil, mirekMin: 153, mirekMax: 500
        )
    }

    private func demoRoom() -> RoomDisplayItem {
        RoomDisplayItem(
            kind: .room,
            id: "room-a",
            name: "Test Room",
            archetype: nil,
            isOn: true,
            brightness: 70,
            groupedLightID: "gl-a",
            lightCount: 2,
            bridgeID: "bridge-a",
            childResourceRefs: [(rid: "l1", rtype: "light"), (rid: "l2", rtype: "light")]
        )
    }

    private func makeVM(lights: [LightDisplayItem]) -> RoomDetailViewModel {
        RoomDetailViewModel(room: demoRoom(), api: nil, isDemoMode: true, initialLights: lights)
    }

    private func sseUpdates(_ json: String) throws -> [SSEResourceUpdate] {
        try JSONDecoder().decode([SSEResourceUpdate].self, from: Data(json.utf8))
    }

    // ── Pure helper ───────────────────────────────────────────

    func testDeriveAllOffIsOffAndHoldsFallbackBrightness() {
        let state = RoomAggregate.derive(
            from: [light("a", on: false, brightness: 40), light("b", on: false, brightness: 90)],
            fallbackBrightness: 63)
        XCTAssertFalse(state.isOn)
        XCTAssertEqual(state.brightness, 63)
    }

    func testDeriveAnyOnIsOnWithAverageOfOnLightsOnly() {
        let state = RoomAggregate.derive(
            from: [light("a", on: true, brightness: 20),
                   light("b", on: true, brightness: 80),
                   light("c", on: false, brightness: 100)],
            fallbackBrightness: 50)
        XCTAssertTrue(state.isOn)
        XCTAssertEqual(state.brightness, 50)   // (20+80)/2 — off light excluded
    }

    func testDeriveClampsAndHandlesEmpty() {
        XCTAssertEqual(RoomAggregate.derive(from: [], fallbackBrightness: 77),
                       RoomAggregate.State(isOn: false, brightness: 77))
        let state = RoomAggregate.derive(from: [light("a", on: true, brightness: 0.2)],
                                         fallbackBrightness: 50)
        XCTAssertEqual(state.brightness, 1)    // clamped to UI range
    }

    // ── Optimistic per-light path (the reported bug) ──────────

    /// Turning every light off one by one must flip the master bar with the
    /// last light — no leave-and-return needed.
    func testTurningLightsOffIndividuallyFlipsMasterBar() {
        let vm = makeVM(lights: [light("l1", on: true, brightness: 60),
                                 light("l2", on: true, brightness: 80)])
        XCTAssertTrue(vm.roomIsOn)

        vm.setLight(vm.lights[0], isOn: false)
        XCTAssertTrue(vm.roomIsOn, "one light still on — bar stays on")

        vm.setLight(vm.lights[1], isOn: false)
        XCTAssertFalse(vm.roomIsOn, "all lights off — bar must flip off immediately")
    }

    func testIndividualBrightnessChangesMoveTheMasterAverage() {
        let vm = makeVM(lights: [light("l1", on: true, brightness: 60),
                                 light("l2", on: true, brightness: 80)])
        vm.setBrightness(20, for: vm.lights[0])
        XCTAssertEqual(vm.roomBrightness, 50, accuracy: 0.5)   // (20+80)/2
    }

    // ── SSE path ──────────────────────────────────────────────

    /// Per-light OFF events for every member must flip the bar without any
    /// grouped_light event (the bridge's grouped OFF can lag or be missed).
    func testSSEAllLightsOffFlipsMasterBarWithoutGroupedEvent() throws {
        let vm = makeVM(lights: [light("l1", on: true, brightness: 60),
                                 light("l2", on: true, brightness: 80)])
        let updates = try sseUpdates("""
        [
          {"id": "l1", "type": "light", "on": {"on": false}},
          {"id": "l2", "type": "light", "on": {"on": false}}
        ]
        """)
        vm.applySSEUpdates(updates)
        XCTAssertFalse(vm.roomIsOn)
    }

    /// grouped_light events for this room's group are consumed (they used to
    /// be filtered out) — OFF wins when no member light disagrees.
    func testSSEGroupedLightEventUpdatesBar() throws {
        let vm = makeVM(lights: [light("l1", on: false, brightness: 60)])
        vm.applySSEUpdates(try sseUpdates("""
        [{"id": "gl-a", "type": "grouped_light", "on": {"on": true}, "dimming": {"brightness": 42}}]
        """))
        XCTAssertTrue(vm.roomIsOn)
        XCTAssertEqual(vm.roomBrightness, 42)

        vm.applySSEUpdates(try sseUpdates("""
        [{"id": "gl-a", "type": "grouped_light", "on": {"on": false}}]
        """))
        XCTAssertFalse(vm.roomIsOn)
    }

    /// grouped_light OFF must NOT beat member lights that are demonstrably on
    /// (grouped_light lags after scene recalls — trust the lights for ON).
    func testSSEGroupedOffLosesToOnMemberLights() throws {
        let vm = makeVM(lights: [light("l1", on: true, brightness: 60)])
        vm.applySSEUpdates(try sseUpdates("""
        [{"id": "gl-a", "type": "grouped_light", "on": {"on": false}}]
        """))
        XCTAssertTrue(vm.roomIsOn)
    }

    /// Events for OTHER groups are ignored.
    func testSSEOtherGroupedLightIsIgnored() throws {
        let vm = makeVM(lights: [light("l1", on: true, brightness: 60)])
        vm.applySSEUpdates(try sseUpdates("""
        [{"id": "gl-other", "type": "grouped_light", "on": {"on": false}, "dimming": {"brightness": 5}}]
        """))
        XCTAssertTrue(vm.roomIsOn)
        XCTAssertEqual(vm.roomBrightness, 70)   // seeded from the room item
    }

    // ── Optimistic-write echo guard ───────────────────────────

    /// Right after a master toggle, SSE echoes must not bounce the bar back.
    func testMasterWriteWindowSuppressesSSEEcho() throws {
        let vm = makeVM(lights: [light("l1", on: false, brightness: 60)])
        vm.toggleRoom(on: true)
        XCTAssertTrue(vm.roomIsOn)
        // A stale grouped OFF echo arrives inside the 1.5s window…
        vm.applySSEUpdates(try sseUpdates("""
        [{"id": "gl-a", "type": "grouped_light", "on": {"on": false}}]
        """))
        XCTAssertTrue(vm.roomIsOn, "optimistic master write must hold through the echo window")
    }
}
