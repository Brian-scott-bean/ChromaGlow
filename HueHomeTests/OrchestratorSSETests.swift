import XCTest
@testable import HueHome

@MainActor
final class OrchestratorSSETests: XCTestCase {

    // MARK: - SSE-01 grouped_light visible state

    func testGroupedLightSSE_updatesVisibleRoomState() throws {
        let orchestrator = makeOrchestratorSSESUT(isOn: true, brightness: 80)

        let json = """
        [{"creationtime":"2024-01-01T00:00:00Z","data":[{
          "id":"gl-001","id_v1":null,"type":"grouped_light",
          "on":{"on":false},"dimming":{"brightness":1},"owner":null
        }],"id":"evt-1","type":"update"}]
        """
        let events = try decodeSSEEvents(json)

        let result = orchestrator.testApplySSEEventsAndRebuild(events, bridgeID: "bridge-1")

        XCTAssertTrue(result.rooms)
        XCTAssertFalse(result.zones)
        XCTAssertEqual(orchestrator.allRooms.count, 1)
        XCTAssertEqual(orchestrator.allRooms[0].id, "room-001")
        XCTAssertFalse(orchestrator.allRooms[0].isOn)
        XCTAssertEqual(orchestrator.allRooms[0].brightness, 1, accuracy: 0.1)
    }

    // MARK: - SSE-02 shared decoder rejection (decoder-only boundary)

    func testSSEDecoder_rejectsMalformedJSON_withoutMutatingState() {
        let orchestrator = makeOrchestratorSSESUT(isOn: true, brightness: 80)
        let malformed = Data("{not valid json".utf8)

        XCTAssertThrowsError(
            try UnifiedOrchestrator.sseDecoder.decode(
                [SSEEvent].self,
                from: malformed
            )
        )

        XCTAssertEqual(orchestrator.allRooms.count, 1)
        XCTAssertTrue(orchestrator.allRooms[0].isOn)
        XCTAssertEqual(orchestrator.allRooms[0].brightness, 80, accuracy: 0.1)
    }

    // MARK: - SSE-03 unknown resource type

    func testUnknownSSEType_doesNotMutateVisibleRoomState() throws {
        let orchestrator = makeOrchestratorSSESUT(isOn: true, brightness: 80)

        let json = """
        [{"creationtime":"2024-01-01T00:00:00Z","data":[{
          "id":"gizmo-001","id_v1":null,"type":"unknown_resource",
          "on":{"on":false}
        }],"id":"evt-9","type":"update"}]
        """
        let events = try decodeSSEEvents(json)

        var roomsMutated = false
        var zonesMutated = false
        for event in events {
            let result = orchestrator.applySSEEvent(event, bridgeID: "bridge-1")
            if result.rooms { roomsMutated = true }
            if result.zones { zonesMutated = true }
        }

        XCTAssertFalse(roomsMutated)
        XCTAssertFalse(zonesMutated)
        XCTAssertEqual(orchestrator.allRooms.count, 1)
        XCTAssertTrue(orchestrator.allRooms[0].isOn)
        XCTAssertEqual(orchestrator.allRooms[0].brightness, 80, accuracy: 0.1)
    }

    // MARK: - Fixtures

    private func makeOrchestratorSSECachedRoom(
        isOn: Bool = true,
        brightness: Double = 80
    ) -> HueLocalRoom {
        let room = HueLocalRoom(roomID: "room-001", bridgeID: "bridge-1")
        room.cachedName = "Bedroom"
        room.cachedGroupedLightID = "gl-001"
        room.lastIsOn = isOn
        room.lastBrightness = brightness
        return room
    }

    @MainActor
    private func makeOrchestratorSSESUT(
        isOn: Bool = true,
        brightness: Double = 80
    ) -> UnifiedOrchestrator {
        let orchestrator = UnifiedOrchestrator()
        orchestrator.preloadCached(
            from: [
                makeOrchestratorSSECachedRoom(
                    isOn: isOn,
                    brightness: brightness
                )
            ]
        )
        return orchestrator
    }

    private func decodeSSEEvents(_ json: String) throws -> [SSEEvent] {
        let data = try XCTUnwrap(json.data(using: .utf8))
        return try UnifiedOrchestrator.sseDecoder.decode(
            [SSEEvent].self,
            from: data
        )
    }
}
