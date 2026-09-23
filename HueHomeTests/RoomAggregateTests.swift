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

// MARK: - Offline RoomDetailViewModel client

/// Offline HueAPIClient for RoomDetailViewModel's write paths: records each
/// call by name and throws (HTTP 503) for any name in `failing`. Internal so
/// other RoomDetail-facing suites (ColorClipboardTests, …) share it.
final class RoomDetailSpyAPIClient: HueAPIClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    private var _failing: Set<String> = []

    var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
    var failing: Set<String> {
        get { lock.lock(); defer { lock.unlock() }; return _failing }
        set { lock.lock(); _failing = newValue; lock.unlock() }
    }

    override init() { super.init(ip: "192.0.2.50", token: "spy-token") }

    private func record(_ name: String) throws {
        lock.lock()
        _calls.append(name)
        let fail = _failing.contains(name)
        lock.unlock()
        if fail { throw HueAPIError.httpError(503) }
    }

    override func setLight(id: String, on: Bool) async throws { try record("setLight") }
    override func setLightState(id: String, on: Bool, brightness: Double) async throws {
        try record("setLightState")
    }
    override func setLightColor(id: String, x: Double, y: Double) async throws {
        try record("setLightColor")
    }
    override func setLightColorTemp(id: String, mirek: Int) async throws {
        try record("setLightColorTemp")
    }
    override func setGroupedLight(id: String, on: Bool) async throws {
        try record("setGroupedLight")
    }
    override func setGroupedLightState(id: String, on: Bool, brightness: Double) async throws {
        try record("setGroupedLightState")
    }
    override func setGroupedLightEffect(
        id: String, on: Bool?, brightness: Double?,
        xy: (Double, Double)?, mirek: Int?, duration: Int
    ) async throws {
        try record("setGroupedLightEffect")
    }
    /// What fetchGroupedLight returns (nil = HTTP 404).
    var groupedLight: HueGroupedLight?
    override func fetchGroupedLight(id: String) async throws -> HueGroupedLight {
        try record("fetchGroupedLight")
        guard let groupedLight else { throw HueAPIError.httpError(404) }
        return groupedLight
    }
    override func deleteScene(id: String) async throws { try record("deleteScene") }
    override func renameScene(id: String, name: String) async throws {
        try record("renameScene")
    }
}

/// Polls (yielding the main actor) until `condition` holds or `timeout`
/// passes — RoomDetailViewModel's writes run in unstructured Tasks.
@MainActor
func awaitRoomDetail(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

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

    // ── Per-light failure rollback (LightControl path) ────────

    private func liveVM(_ lights: [LightDisplayItem], api: RoomDetailSpyAPIClient) -> RoomDetailViewModel {
        RoomDetailViewModel(room: demoRoom(), api: api, initialLights: lights)
    }

    /// LightControlView's binding used to write the new value into the model
    /// BEFORE the callback, so the item the VM received was already new and
    /// the failure "rollback" restored the new value. The VM now rolls back
    /// to its own pre-write state, whatever the caller passes, and says so.
    func testFailedBrightnessRollsBackToTheModelsPreviousValueAndToasts() async {
        let spy = RoomDetailSpyAPIClient()
        spy.failing = ["setLightState"]
        let vm = liveVM([light("l1", on: true, brightness: 40)], api: spy)
        var alreadyNew = vm.lights[0]
        alreadyNew.brightness = 90            // what the old binding pre-write handed over

        vm.setBrightness(90, for: alreadyNew)
        await awaitRoomDetail { vm.toastMessage != nil }

        XCTAssertEqual(vm.lights[0].brightness, 40, "rollback must restore the value before the write")
        XCTAssertNotNil(vm.toastMessage, "a failed write is never silent")
    }

    func testFailedColorAndColorTempRollBackToThePreviousState() async {
        let spy = RoomDetailSpyAPIClient()
        spy.failing = ["setLightColor", "setLightColorTemp"]
        var start = light("l1", on: true, brightness: 60)
        start.colorX = 0.3; start.colorY = 0.3
        let vm = liveVM([start], api: spy)

        var paintedAlready = vm.lights[0]
        paintedAlready.colorX = 0.6; paintedAlready.colorY = 0.35
        vm.setColor(x: 0.6, y: 0.35, for: paintedAlready)
        await awaitRoomDetail { vm.toastMessage != nil }
        XCTAssertEqual(vm.lights[0].colorX, 0.3)
        XCTAssertEqual(vm.lights[0].colorY, 0.3)

        vm.toastMessage = nil
        vm.setColorTemp(mirek: 250, for: vm.lights[0])
        await awaitRoomDetail { vm.toastMessage != nil }
        XCTAssertNil(vm.lights[0].colorTempMirek, "CT rollback restores the pre-write (nil) mirek")
    }

    // ── Room-level undo ───────────────────────────────────────

    /// A failed room OFF used to set EVERY light to !on — turning on lights
    /// that were off before the tap. Each card must get its own state back.
    func testFailedRoomToggleRestoresEachLightsOwnState() async {
        let spy = RoomDetailSpyAPIClient()
        spy.failing = ["setGroupedLight"]
        let vm = liveVM([light("l1", on: true, brightness: 60),
                         light("l2", on: false, brightness: 30)], api: spy)

        vm.toggleRoom(on: false)
        XCTAssertEqual(vm.lights.map(\.isOn), [false, false], "optimistic")
        await awaitRoomDetail { vm.toastMessage != nil }

        XCTAssertEqual(vm.lights.map(\.isOn), [true, false], "l2 was off and must stay off")
        XCTAssertTrue(vm.roomIsOn)
    }

    func testFailedRoomBrightnessRestoresTheCardsToo() async {
        let spy = RoomDetailSpyAPIClient()
        spy.failing = ["setGroupedLightState"]
        let vm = liveVM([light("l1", on: true, brightness: 60),
                         light("l2", on: false, brightness: 30)], api: spy)

        vm.setRoomBrightness(95)
        await awaitRoomDetail { vm.toastMessage != nil }

        XCTAssertEqual(vm.lights.map(\.brightness), [60, 30])
        XCTAssertEqual(vm.lights.map(\.isOn), [true, false])
        XCTAssertEqual(vm.roomBrightness, 70, "back to the pre-write bar value")
    }

    func testFailedRoomPresetRestoresTheCards() async throws {
        let spy = RoomDetailSpyAPIClient()
        spy.failing = ["setGroupedLightEffect"]
        let vm = liveVM([light("l1", on: false, brightness: 20)], api: spy)
        let preset = try XCTUnwrap(LightingPreset.all.first)

        vm.applyPreset(preset)
        vm.toastMessage = nil   // the preset's own "applied" toast
        await awaitRoomDetail { vm.toastMessage != nil }

        XCTAssertFalse(vm.lights[0].isOn)
        XCTAssertEqual(vm.lights[0].brightness, 20)
    }

    // ── Bulk (multi-select) writes ───────────────────────────

    /// Bulk On goes through the pacing gate — one command per light, starts
    /// spaced to the bridge budget — and a light that still fails after the
    /// gate's retry is restored with one toast.
    func testBulkOnIsPacedAndFailedLightsRollBack() async {
        let spy = RoomDetailSpyAPIClient()
        spy.failing = ["setLight"]
        let vm = liveVM([light("l1", on: false, brightness: 40),
                         light("l2", on: false, brightness: 50)], api: spy)
        vm.enterSelectMode()
        vm.selectAll()
        let started = ContinuousClock.now

        vm.setSelectedLightsOn(true)
        XCTAssertEqual(vm.lights.map(\.isOn), [true, true], "optimistic")
        await awaitRoomDetail(timeout: 5) { vm.toastMessage != nil }

        XCTAssertEqual(vm.lights.map(\.isOn), [false, false], "failed lights restored")
        XCTAssertEqual(spy.calls.filter { $0 == "setLight" }.count, 4,
                       "one command per light, retried once by the gate")
        XCTAssertGreaterThanOrEqual(started.duration(to: .now), .milliseconds(300),
                                    "four gated starts are paced ~100ms apart")
    }

    /// A grouped_light can report brightness 0; the bar's range is 1…100.
    func testLoadRoomStateClampsGroupedBrightnessZero() async throws {
        let spy = RoomDetailSpyAPIClient()
        spy.groupedLight = try JSONDecoder().decode(HueGroupedLight.self, from: Data("""
        {"id": "gl-a", "type": "grouped_light", "on": {"on": false}, "dimming": {"brightness": 0}}
        """.utf8))
        let vm = liveVM([light("l1", on: false, brightness: 40)], api: spy)

        await vm.loadRoomState()

        XCTAssertFalse(vm.roomIsOn)
        XCTAssertEqual(vm.roomBrightness, 1)
    }
}
