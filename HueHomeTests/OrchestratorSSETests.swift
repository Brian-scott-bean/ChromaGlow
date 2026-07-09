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

    // MARK: - SSE-04 light on-event proves a lagging room card on

    func testLightOnSSE_flipsOffRoomCardOn() throws {
        let orchestrator = makeOrchestratorSSESUT(isOn: false, brightness: 1)
        orchestrator.testSeedLightIndex(lightIDToRoomID: ["light-001": "room-001"])

        let json = """
        [{"creationtime":"2024-01-01T00:00:00Z","data":[{
          "id":"light-001","id_v1":null,"type":"light",
          "on":{"on":true},"owner":null
        }],"id":"evt-4","type":"update"}]
        """
        let events = try decodeSSEEvents(json)

        let result = orchestrator.testApplySSEEventsAndRebuild(events, bridgeID: "bridge-1")

        XCTAssertTrue(result.rooms)
        XCTAssertTrue(orchestrator.allRooms[0].isOn,
                      "an explicit light-on event must prove the room on even when " +
                      "the grouped_light event lags or never arrives")
    }

    func testLightOffSSE_neverFlipsRoomCardOff() throws {
        let orchestrator = makeOrchestratorSSESUT(isOn: true, brightness: 80)
        orchestrator.testSeedLightIndex(lightIDToRoomID: ["light-001": "room-001"])

        let json = """
        [{"creationtime":"2024-01-01T00:00:00Z","data":[{
          "id":"light-001","id_v1":null,"type":"light",
          "on":{"on":false},"owner":null
        }],"id":"evt-5","type":"update"}]
        """
        let events = try decodeSSEEvents(json)

        orchestrator.testApplySSEEventsAndRebuild(events, bridgeID: "bridge-1")

        XCTAssertTrue(orchestrator.allRooms[0].isOn,
                      "a single light going off never implies the room is off — " +
                      "grouped_light events own the off aggregate")
    }

    func testLightColorOnlySSE_updatesGlowWithoutFlippingOffRoomOn() throws {
        let orchestrator = makeOrchestratorSSESUT(isOn: false, brightness: 1)
        orchestrator.testSeedLightIndex(lightIDToRoomID: ["light-001": "room-001"])

        let json = """
        [{"creationtime":"2024-01-01T00:00:00Z","data":[{
          "id":"light-001","id_v1":null,"type":"light",
          "color":{"xy":{"x":0.31,"y":0.32}},"owner":null
        }],"id":"evt-6","type":"update"}]
        """
        let events = try decodeSSEEvents(json)

        orchestrator.testApplySSEEventsAndRebuild(events, bridgeID: "bridge-1")

        let room = orchestrator.allRooms[0]
        XCTAssertFalse(room.isOn,
                       "only an explicit on:true may flip a card on — a color-only " +
                       "event proves nothing about power state")
        XCTAssertEqual(room.dominantColorX ?? -1, 0.31, accuracy: 0.0001)
        XCTAssertEqual(room.dominantColorY ?? -1, 0.32, accuracy: 0.0001)
    }

    // MARK: - SSE-05 per-light cache stays live (RoomDetail seed freshness)

    func testLightSSE_keepsRawLightCacheFresh() throws {
        let orchestrator = makeOrchestratorSSESUT(isOn: true, brightness: 80)
        orchestrator.testSeedLightIndex(lightIDToRoomID: ["light-001": "room-001"])
        orchestrator.testSeedLightCache(
            bridgeID: "bridge-1",
            lights: [makeCachedLight(id: "light-001", isOn: false, brightness: 10)]
        )

        let onJSON = """
        [{"creationtime":"2024-01-01T00:00:00Z","data":[{
          "id":"light-001","id_v1":null,"type":"light",
          "on":{"on":true},"dimming":{"brightness":55},
          "color":{"xy":{"x":0.2,"y":0.21}},"owner":null
        }],"id":"evt-7","type":"update"}]
        """
        orchestrator.testApplySSEEventsAndRebuild(try decodeSSEEvents(onJSON), bridgeID: "bridge-1")

        var cached = try XCTUnwrap(orchestrator.cachedRawLights(for: "bridge-1"))
        XCTAssertTrue(cached[0].on.on, "the RoomDetail seed must reflect the SSE on event")
        XCTAssertEqual(cached[0].dimming?.brightness ?? -1, 55, accuracy: 0.1)
        XCTAssertEqual(cached[0].color?.xy.x ?? -1, 0.2, accuracy: 0.0001)
        XCTAssertEqual(cached[0].color?.gamut_type, "C",
                       "capability fields must survive an SSE apply")

        // OFF events refresh the cache too — a truthful seed is the point.
        let offJSON = """
        [{"creationtime":"2024-01-01T00:00:00Z","data":[{
          "id":"light-001","id_v1":null,"type":"light",
          "on":{"on":false},"owner":null
        }],"id":"evt-8","type":"update"}]
        """
        orchestrator.testApplySSEEventsAndRebuild(try decodeSSEEvents(offJSON), bridgeID: "bridge-1")

        cached = try XCTUnwrap(orchestrator.cachedRawLights(for: "bridge-1"))
        XCTAssertFalse(cached[0].on.on, "an external OFF must not leave a stale-on seed")
        XCTAssertEqual(cached[0].dimming?.brightness ?? -1, 55, accuracy: 0.1,
                       "fields absent from the event must carry over unchanged")
    }

    func testLightSSE_unknownLightLeavesCacheUntouched() throws {
        let orchestrator = makeOrchestratorSSESUT(isOn: true, brightness: 80)
        orchestrator.testSeedLightCache(
            bridgeID: "bridge-1",
            lights: [makeCachedLight(id: "light-001", isOn: false, brightness: 10)]
        )

        let json = """
        [{"creationtime":"2024-01-01T00:00:00Z","data":[{
          "id":"light-elsewhere","id_v1":null,"type":"light",
          "on":{"on":true},"owner":null
        }],"id":"evt-9","type":"update"}]
        """
        orchestrator.testApplySSEEventsAndRebuild(try decodeSSEEvents(json), bridgeID: "bridge-1")

        let cached = try XCTUnwrap(orchestrator.cachedRawLights(for: "bridge-1"))
        XCTAssertEqual(cached.count, 1)
        XCTAssertFalse(cached[0].on.on)
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

    private func makeCachedLight(
        id: String,
        isOn: Bool,
        brightness: Double
    ) -> HueLight {
        HueLight(
            id: id,
            metadata: LightMetadata(name: "L-\(id)", archetype: nil),
            on: OnState(on: isOn),
            dimming: DimmingState(brightness: brightness),
            color: LightColor(xy: CIExy(x: 0.5, y: 0.4), gamut_type: "C"),
            color_temperature: nil,
            owner: ResourceRef(rid: "device-\(id)", rtype: "device")
        )
    }

    private func decodeSSEEvents(_ json: String) throws -> [SSEEvent] {
        let data = try XCTUnwrap(json.data(using: .utf8))
        return try UnifiedOrchestrator.sseDecoder.decode(
            [SSEEvent].self,
            from: data
        )
    }
}
