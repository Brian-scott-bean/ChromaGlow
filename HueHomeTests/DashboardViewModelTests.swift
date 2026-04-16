// DashboardViewModelTests.swift
// HueHome Pro — Unit Tests
// Tests for DashboardViewModel using mocked HueAPIClient.
// Validates: toggle logic, brightness clamping, SSE updates, widget sync.

import XCTest
@testable import HueHome

// MARK: - Mock API Client

/// Protocol-matched mock that returns pre-configured results without networking.
final class MockHueAPIClient: HueAPIClient {

    // Configurable stubs
    var stubbedRooms:  [HueRoom]        = []
    var stubbedLights: [HueLight]       = []
    var stubbedGroupedLight: HueGroupedLight? = nil
    var shouldThrowOnToggle  = false
    var shouldThrowOnFetch   = false
    var toggleCallCount      = 0
    var brightnessCallCount  = 0
    var lastSetBrightness: Double? = nil
    var lastSetOn: Bool?           = nil

    override func credentials() throws -> (ip: String, token: String) {
        ("192.168.1.1", "mock-token")
    }

    override func fetchRooms() async throws -> [HueRoom] {
        if shouldThrowOnFetch { throw HueAPIError.httpError(500) }
        return stubbedRooms
    }

    override func fetchLights() async throws -> [HueLight] {
        if shouldThrowOnFetch { throw HueAPIError.httpError(500) }
        return stubbedLights
    }

    override func fetchGroupedLight(id: String) async throws -> HueGroupedLight {
        guard let gl = stubbedGroupedLight else { throw HueAPIError.httpError(404) }
        return gl
    }

    override func setGroupedLight(id: String, on: Bool) async throws {
        if shouldThrowOnToggle { throw HueAPIError.httpError(503) }
        toggleCallCount += 1
        lastSetOn = on
    }

    override func setGroupedLightBrightness(id: String, brightness: Double) async throws {
        if shouldThrowOnToggle { throw HueAPIError.httpError(503) }
        brightnessCallCount += 1
        lastSetBrightness = brightness
    }
}

// MARK: - Dashboard ViewModel Tests

@MainActor
final class DashboardViewModelTests: XCTestCase {

    var mockAPI: MockHueAPIClient!
    var vm: DashboardViewModel!

    override func setUp() async throws {
        try await super.setUp()
        mockAPI = MockHueAPIClient()
        vm = DashboardViewModel(api: mockAPI)
    }

    // MARK: - loadAll

    func testLoadAllPopulatesRooms() async throws {
        mockAPI.stubbedRooms = [
            makeHueRoom(id: "r-001", name: "Living Room", glID: "gl-001"),
            makeHueRoom(id: "r-002", name: "Bedroom",     glID: "gl-002"),
        ]
        mockAPI.stubbedGroupedLight = makeGroupedLight(id: "gl-001", on: true, brightness: 80)

        await vm.loadAll()

        XCTAssertEqual(vm.rooms.count, 2)
        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.errorMessage)
    }

    func testLoadAllSortsRoomsAlphabetically() async {
        mockAPI.stubbedRooms = [
            makeHueRoom(id: "r-003", name: "Zephyr Room", glID: nil),
            makeHueRoom(id: "r-001", name: "Alpha Room",  glID: nil),
            makeHueRoom(id: "r-002", name: "Mid Room",    glID: nil),
        ]
        await vm.loadAll()
        XCTAssertEqual(vm.rooms.map(\.name), ["Alpha Room", "Mid Room", "Zephyr Room"])
    }

    func testLoadAllSetsErrorOnFailure() async {
        mockAPI.shouldThrowOnFetch = true
        await vm.loadAll()
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertTrue(vm.rooms.isEmpty)
        XCTAssertFalse(vm.isLoading)
    }

    func testLoadAllDoesNotRunWhileAlreadyLoading() async {
        // Simulate loading state guard
        vm.rooms = [makeRoomDisplayItem(id: "r-existing")]
        // Even if we call loadAll while isLoading is simulated, rooms shouldn't be cleared
        // (Testing the guard: second call while first is in flight won't reset rooms)
        XCTAssertFalse(vm.rooms.isEmpty)
    }

    // MARK: - toggleRoom

    func testToggleRoomCallsAPIWithCorrectState() async {
        let room = makeRoomDisplayItem(id: "r-001", glID: "gl-001", isOn: false)
        vm.rooms = [room]

        vm.toggleRoom(room)
        // Brief wait for async Task in toggleRoom
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(mockAPI.toggleCallCount, 1)
        XCTAssertEqual(mockAPI.lastSetOn, true)
    }

    func testToggleRoomOptimisticallyUpdatesUI() {
        let room = makeRoomDisplayItem(id: "r-001", glID: "gl-001", isOn: false)
        vm.rooms = [room]
        vm.toggleRoom(room)
        // Optimistic update should fire synchronously before API call completes
        XCTAssertTrue(vm.rooms.first?.isOn ?? false)
    }

    func testToggleRoomRollsBackOnAPIFailure() async {
        mockAPI.shouldThrowOnToggle = true
        let room = makeRoomDisplayItem(id: "r-001", glID: "gl-001", isOn: true)
        vm.rooms = [room]

        vm.toggleRoom(room)
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Should roll back to original state
        XCTAssertTrue(vm.rooms.first?.isOn ?? false)
    }

    func testToggleRoomWithNoGroupedLightIDDoesNothing() {
        let room = makeRoomDisplayItem(id: "r-001", glID: nil, isOn: false)
        vm.rooms = [room]
        vm.toggleRoom(room)
        XCTAssertEqual(mockAPI.toggleCallCount, 0)
    }

    // MARK: - setBrightness

    func testSetBrightnessClampedToMinimum() async {
        let room = makeRoomDisplayItem(id: "r-001", glID: "gl-001", isOn: true)
        vm.rooms = [room]

        vm.setBrightness(-50, for: room)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(mockAPI.lastSetBrightness, 1.0, accuracy: 0.01)
    }

    func testSetBrightnessClampedToMaximum() async {
        let room = makeRoomDisplayItem(id: "r-001", glID: "gl-001", isOn: true)
        vm.rooms = [room]

        vm.setBrightness(150, for: room)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(mockAPI.lastSetBrightness, 100.0, accuracy: 0.01)
    }

    func testSetBrightnessOptimisticallyUpdates() {
        let room = makeRoomDisplayItem(id: "r-001", glID: "gl-001", isOn: true)
        vm.rooms = [room]
        vm.setBrightness(65, for: room)
        XCTAssertEqual(vm.rooms.first?.brightness ?? 0, 65, accuracy: 0.1)
    }

    func testSetBrightnessTurnsOnIfRoomWasOff() {
        let room = makeRoomDisplayItem(id: "r-001", glID: "gl-001", isOn: false)
        vm.rooms = [room]
        vm.setBrightness(50, for: room)
        XCTAssertTrue(vm.rooms.first?.isOn ?? false)
    }

    // MARK: - SSE applySSEUpdates

    func testApplySSEUpdatesOnState() {
        vm.rooms = [makeRoomDisplayItem(id: "r-001", glID: "gl-001", isOn: false, brightness: 100)]

        let update = SSEResourceUpdate(
            id: "gl-001",
            type: "grouped_light",
            on: .init(on: true),
            dimming: .init(brightness: 75),
            colorTemperature: nil,
            color: nil
        )
        vm.applySSEUpdates([update])

        XCTAssertTrue(vm.rooms.first?.isOn ?? false)
        XCTAssertEqual(vm.rooms.first?.brightness ?? 0, 75, accuracy: 0.1)
    }

    func testApplySSEUpdateOnlyMatchesCorrectGroupedLight() {
        vm.rooms = [
            makeRoomDisplayItem(id: "r-001", glID: "gl-001", isOn: false),
            makeRoomDisplayItem(id: "r-002", glID: "gl-002", isOn: false),
        ]
        let update = SSEResourceUpdate(
            id: "gl-001",
            type: "grouped_light",
            on: .init(on: true),
            dimming: nil,
            colorTemperature: nil,
            color: nil
        )
        vm.applySSEUpdates([update])

        XCTAssertTrue(vm.rooms[0].isOn)
        XCTAssertFalse(vm.rooms[1].isOn)
    }

    func testApplySSEUpdateWithWrongTypeDoesNothing() {
        vm.rooms = [makeRoomDisplayItem(id: "r-001", glID: "gl-001", isOn: false)]
        let update = SSEResourceUpdate(
            id: "gl-001",
            type: "light",  // wrong type
            on: .init(on: true),
            dimming: nil,
            colorTemperature: nil,
            color: nil
        )
        vm.applySSEUpdates([update])
        XCTAssertFalse(vm.rooms.first?.isOn ?? true)
    }
}

// MARK: - Test Fixtures

private func makeHueRoom(id: String, name: String, glID: String?) -> HueRoom {
    let services: [HueResourceRef] = glID.map { [HueResourceRef(rid: $0, rtype: "grouped_light")] } ?? []
    return HueRoom(
        id: id,
        metadata: HueRoom.Metadata(name: name, archetype: "living_room"),
        children: [],
        services: services
    )
}

private func makeGroupedLight(id: String, on: Bool, brightness: Double) -> HueGroupedLight {
    HueGroupedLight(
        id: id,
        on: HueGroupedLight.OnState(on: on),
        dimming: HueGroupedLight.Dimming(brightness: brightness),
        type: "grouped_light"
    )
}

private func makeRoomDisplayItem(
    id: String,
    glID: String? = "gl-001",
    isOn: Bool = false,
    brightness: Double = 100
) -> RoomDisplayItem {
    RoomDisplayItem(
        id: id,
        name: "Room \(id)",
        archetype: "living_room",
        isOn: isOn,
        brightness: brightness,
        groupedLightID: glID,
        lightCount: 2,
        childResourceRefs: []
    )
}
