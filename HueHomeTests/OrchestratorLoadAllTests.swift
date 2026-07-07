import XCTest
@testable import HueHome

// MARK: - Test errors

private enum OrchestratorLoadAllTestError: Error, LocalizedError {
    case forcedResourceFetchFailure
    case unexpectedGET(path: String)
    case unexpectedPUT(path: String)

    var errorDescription: String? {
        switch self {
        case .forcedResourceFetchFailure:
            return "Forced resource fetch failure for loadAll test"
        case .unexpectedGET(let path):
            return "Unexpected GET \(path) in OrchestratorLoadAllTests"
        case .unexpectedPUT(let path):
            return "Unexpected PUT \(path) in OrchestratorLoadAllTests"
        }
    }
}

// MARK: - Concurrency-safe recorder

private actor OrchestratorLoadAllSpyRecorder {
    private(set) var fetchRoomsCount = 0
    private(set) var fetchZonesCount = 0
    private(set) var fetchLightsCount = 0
    private(set) var fetchGroupedLightsCount = 0
    private(set) var cleanupGETCount = 0
    private(set) var unexpectedPUTCount = 0

    func recordFetchRooms() { fetchRoomsCount += 1 }
    func recordFetchZones() { fetchZonesCount += 1 }
    func recordFetchLights() { fetchLightsCount += 1 }
    func recordFetchGroupedLights() { fetchGroupedLightsCount += 1 }
    func recordCleanupGET() { cleanupGETCount += 1 }
    func recordUnexpectedPUT() { unexpectedPUTCount += 1 }
}

// MARK: - Typed offline spy

private final class OrchestratorLoadAllSpyBridgeClient:
    BridgeAPIClient,
    @unchecked Sendable
{
    private let recorder: OrchestratorLoadAllSpyRecorder
    private let stubRooms: [HueRoom]
    private let stubZones: [HueZone]
    private let stubLights: [HueLight]
    private let stubGroupedLights: [HueGroupedLight]
    var forceResourceFetchError = false

    init(
        bridgeID: String,
        bridgeName: String,
        ip: String,
        token: String,
        recorder: OrchestratorLoadAllSpyRecorder,
        rooms: [HueRoom],
        zones: [HueZone],
        lights: [HueLight],
        groupedLights: [HueGroupedLight]
    ) {
        self.recorder = recorder
        self.stubRooms = rooms
        self.stubZones = zones
        self.stubLights = lights
        self.stubGroupedLights = groupedLights
        super.init(bridgeID: bridgeID, bridgeName: bridgeName, ip: ip, token: token)
    }

    override func fetchRooms() async throws -> [HueRoom] {
        await recorder.recordFetchRooms()
        if forceResourceFetchError { throw OrchestratorLoadAllTestError.forcedResourceFetchFailure }
        return stubRooms
    }

    override func fetchZones() async throws -> [HueZone] {
        await recorder.recordFetchZones()
        if forceResourceFetchError { throw OrchestratorLoadAllTestError.forcedResourceFetchFailure }
        return stubZones
    }

    override func fetchLights() async throws -> [HueLight] {
        await recorder.recordFetchLights()
        if forceResourceFetchError { throw OrchestratorLoadAllTestError.forcedResourceFetchFailure }
        return stubLights
    }

    override func fetchGroupedLights() async throws -> [HueGroupedLight] {
        await recorder.recordFetchGroupedLights()
        if forceResourceFetchError { throw OrchestratorLoadAllTestError.forcedResourceFetchFailure }
        return stubGroupedLights
    }

    override func get(path: String, ip: String, token: String) async throws -> Data {
        if path == "/clip/v2/resource/entertainment_configuration" {
            await recorder.recordCleanupGET()
            return Data(#"{"errors":[],"data":[]}"#.utf8)
        }
        throw OrchestratorLoadAllTestError.unexpectedGET(path: path)
    }

    override func put(path: String, body: [String: Any], ip: String, token: String) async throws -> Data {
        await recorder.recordUnexpectedPUT()
        throw OrchestratorLoadAllTestError.unexpectedPUT(path: path)
    }
}

// MARK: - Typed fixtures

private enum OrchestratorLoadAllFixtures {

    static let roomsJSON = """
    {"errors":[],"data":[{
      "id":"room-001",
      "type":"room",
      "metadata":{"name":"Bedroom","archetype":"bedroom"},
      "children":[{"rid":"light-001","rtype":"light"}],
      "services":[{"rid":"gl-001","rtype":"grouped_light"}]
    }]}
    """

    static let groupedLightsOnJSON = """
    {"errors":[],"data":[{
      "id":"gl-001",
      "type":"grouped_light",
      "on":{"on":true},
      "dimming":{"brightness":80}
    }]}
    """

    static let groupedLightsOffJSON = """
    {"errors":[],"data":[{
      "id":"gl-001",
      "type":"grouped_light",
      "on":{"on":false},
      "dimming":{"brightness":1}
    }]}
    """

    static func rooms() throws -> [HueRoom] {
        try decodeEnvelope(from: roomsJSON)
    }

    static func groupedLights(on: Bool) throws -> [HueGroupedLight] {
        try decodeEnvelope(from: on ? groupedLightsOnJSON : groupedLightsOffJSON)
    }

    static func light() -> HueLight {
        HueLight(
            id: "light-001",
            metadata: LightMetadata(name: "Ceiling", archetype: "sultan_bulb"),
            on: OnState(on: true),
            dimming: DimmingState(brightness: 80),
            color: nil,
            color_temperature: nil,
            owner: ResourceRef(rid: "device-001", rtype: "device")
        )
    }

    private static func decodeEnvelope<T: Decodable>(from json: String) throws -> [T] {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(HueV2Response<T>.self, from: data).data
    }
}

// MARK: - SUT

@MainActor
private struct OrchestratorLoadAllSUT {
    let orchestrator: UnifiedOrchestrator
    let client: OrchestratorLoadAllSpyBridgeClient
    let recorder: OrchestratorLoadAllSpyRecorder
}

@MainActor
private func makeOrchestratorLoadAllSUT(
    groupedLightOn: Bool = true,
    forceResourceFetchError: Bool = false
) throws -> OrchestratorLoadAllSUT {
    let recorder = OrchestratorLoadAllSpyRecorder()
    let client = OrchestratorLoadAllSpyBridgeClient(
        bridgeID: "bridge-1",
        bridgeName: "Test Bridge",
        ip: "192.168.1.1",
        token: "test-token",
        recorder: recorder,
        rooms: try OrchestratorLoadAllFixtures.rooms(),
        zones: [],
        lights: [OrchestratorLoadAllFixtures.light()],
        groupedLights: try OrchestratorLoadAllFixtures.groupedLights(on: groupedLightOn)
    )
    if forceResourceFetchError {
        client.forceResourceFetchError = true
    }
    return OrchestratorLoadAllSUT(
        orchestrator: UnifiedOrchestrator(),
        client: client,
        recorder: recorder
    )
}

// MARK: - OrchestratorLoadAllTests

@MainActor
final class OrchestratorLoadAllTests: XCTestCase {

    // MARK: LOAD-01

    func testLoadAll_success_populatesRooms() async throws {
        let sut = try makeOrchestratorLoadAllSUT(groupedLightOn: true)
        sut.orchestrator.injectForTesting(clients: ["bridge-1": sut.client])

        await sut.orchestrator.loadAll()

        XCTAssertEqual(sut.orchestrator.allRooms.count, 1)
        let room = sut.orchestrator.allRooms[0]
        XCTAssertEqual(room.id, "room-001")
        XCTAssertEqual(room.name, "Bedroom")
        XCTAssertEqual(room.groupedLightID, "gl-001")
        XCTAssertTrue(room.isOn)
        XCTAssertEqual(room.brightness, 80, accuracy: 0.1)

        guard case .connected? = sut.orchestrator.connectionStatus["bridge-1"] else {
            return XCTFail("Expected connected bridge status")
        }

        // Cleanup is now deferred off loadAll's critical path — await it before asserting.
        await sut.orchestrator.testAwaitEntertainmentCleanup()
        let cleanupGETCount = await sut.recorder.cleanupGETCount
        let unexpectedPUTCount = await sut.recorder.unexpectedPUTCount
        XCTAssertGreaterThanOrEqual(cleanupGETCount, 1)
        XCTAssertEqual(unexpectedPUTCount, 0)
    }

    // MARK: LOAD-02

    func testLoadAll_lightsOff_updatesRoomState() async throws {
        let sut = try makeOrchestratorLoadAllSUT(groupedLightOn: false)
        sut.orchestrator.injectForTesting(clients: ["bridge-1": sut.client])

        await sut.orchestrator.loadAll()

        XCTAssertEqual(sut.orchestrator.allRooms.count, 1)
        XCTAssertFalse(sut.orchestrator.allRooms[0].isOn)

        guard case .connected? = sut.orchestrator.connectionStatus["bridge-1"] else {
            return XCTFail("Expected connected bridge status")
        }
    }

    // MARK: LOAD-03

    func testLoadAll_bridgeError_leavesRoomsEmpty() async throws {
        let sut = try makeOrchestratorLoadAllSUT(
            groupedLightOn: true,
            forceResourceFetchError: true
        )
        sut.orchestrator.injectForTesting(clients: ["bridge-1": sut.client])

        await sut.orchestrator.loadAll()

        XCTAssertTrue(sut.orchestrator.allRooms.isEmpty)

        guard case .error? = sut.orchestrator.connectionStatus["bridge-1"] else {
            return XCTFail("Expected error bridge status")
        }

        XCTAssertGreaterThan(sut.orchestrator.lastLoadedAt, .distantPast)
    }

    // MARK: LOAD-04

    func testLoadAll_setsLastLoadedAt_onCompletion() async throws {
        let sut = try makeOrchestratorLoadAllSUT(groupedLightOn: true)
        sut.orchestrator.injectForTesting(clients: ["bridge-1": sut.client])

        let before = Date()
        await sut.orchestrator.loadAll()

        XCTAssertGreaterThanOrEqual(sut.orchestrator.lastLoadedAt, before)
    }
}
