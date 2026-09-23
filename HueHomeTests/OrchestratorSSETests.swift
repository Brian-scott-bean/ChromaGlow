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

    // MARK: - SSE-06 light-event bus survives a rapid room A→B resubscribe

    func testSubscribeToLightEvents_rapidResubscribe_newSubscriberStillReceives() async throws {
        let orchestrator = makeOrchestratorSSESUT(isOn: true, brightness: 80)

        // Room A subscribes, then its consumer tears down (view pop)…
        let streamA = try XCTUnwrap(orchestrator.subscribeToLightEvents())
        let consumerA = Task { for await _ in streamA {} }
        consumerA.cancel()

        // …and room B subscribes immediately after, before A's deferred
        // onTermination hop has run.
        let streamB = try XCTUnwrap(orchestrator.subscribeToLightEvents())

        // Let A's deferred MainActor termination task land — pre-fix, this is
        // the moment it clobbered B's continuation to nil.
        try await Task.sleep(nanoseconds: 100_000_000)

        let json = """
        [{"creationtime":"2024-01-01T00:00:00Z","data":[{
          "id":"light-001","id_v1":null,"type":"light",
          "on":{"on":true},"owner":null
        }],"id":"evt-10","type":"update"}]
        """
        let events = try decodeSSEEvents(json)

        let received = expectation(description: "room B receives light events")
        let consumerB = Task {
            for await updates in streamB where !updates.isEmpty {
                received.fulfill()
                break
            }
        }
        orchestrator.testYieldLightEvents(events[0].data)

        await fulfillment(of: [received], timeout: 2)
        consumerB.cancel()
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

    // MARK: - SSE-04 scene recall status (R5 live-update fix)

    /// Scene events flip ACTIVE badges live — recalls from the official Hue
    /// app or a wall switch used to leave stale badges until a manual reload.
    func testSceneSSE_updatesActiveStateAndDeactivatesRoomMates() throws {
        let orchestrator = makeOrchestratorSSESUT()
        orchestrator.globalScenes = [
            GlobalSceneItem(id: "b1#s1", bridgeSceneID: "s1", name: "Relax",
                            roomID: "room-001", bridgeID: "bridge-1",
                            isActive: true, isDynamic: false, speed: 0.5),
            GlobalSceneItem(id: "b1#s2", bridgeSceneID: "s2", name: "Energize",
                            roomID: "room-001", bridgeID: "bridge-1",
                            isActive: false, isDynamic: false, speed: 0.5),
        ]

        let json = """
        [{"creationtime":"2024-01-01T00:00:00Z","data":[{
          "id":"s2","id_v1":null,"type":"scene",
          "status":{"active":"static"},"owner":null
        }],"id":"evt-9","type":"update"}]
        """
        _ = orchestrator.testApplySSEEventsAndRebuild(try decodeSSEEvents(json), bridgeID: "bridge-1")

        XCTAssertTrue(orchestrator.globalScenes.first { $0.bridgeSceneID == "s2" }!.isActive)
        XCTAssertFalse(orchestrator.globalScenes.first { $0.bridgeSceneID == "s1" }!.isActive,
                       "room-mate must deactivate — one active scene per group")
    }

    /// Foreign "status" shapes (zigbee_connectivity sends a plain string)
    /// must not break batch decoding.
    func testSSEDecoder_toleratesStringStatusFromOtherResourceTypes() throws {
        let json = """
        [{"creationtime":"2024-01-01T00:00:00Z","data":[
          {"id":"conn-1","id_v1":null,"type":"zigbee_connectivity","status":"connected","owner":null},
          {"id":"gl-001","id_v1":null,"type":"grouped_light","on":{"on":false},"owner":null}
        ],"id":"evt-10","type":"update"}]
        """
        let events = try decodeSSEEvents(json)
        XCTAssertEqual(events.first?.data.count, 2)
        XCTAssertNil(events.first?.data.first?.status?.active)
    }

    // MARK: - SSE-08 unmapped Tap-Dial button must not fire a guessed action

    func testButtonSSE_unmappedButtonUUID_leavesBeatClockUntouched() throws {
        let orchestrator = makeOrchestratorSSESUT(isOn: true, brightness: 80)
        orchestrator.djModeEnabled = true
        defer { orchestrator.djModeEnabled = false }

        // Known state: unpinned. A guessed control_id 1 would tap() → pin.
        BeatClock.shared.unpin()

        let json = """
        [{"creationtime":"2024-01-01T00:00:00Z","data":[{
          "id":"button-unmapped-001","id_v1":null,"type":"button",
          "button":{"button_report":{"event":"initial_press"}}
        }],"id":"evt-b1","type":"update"}]
        """
        let events = try decodeSSEEvents(json)
        for event in events {
            _ = orchestrator.applySSEEvent(event, bridgeID: "bridge-1")
        }

        XCTAssertFalse(BeatClock.shared.isPinned)
        XCTAssertNotEqual(BeatClock.shared.source, .tap)
    }

    // MARK: - SSE-09 CRUD edits survive the next rebuild; delete events remove

    /// Deleting a room changed only the merged list; the next rebuild (any SSE
    /// event) re-derived it from the stale per-bridge snapshot and the room
    /// came back.
    func testDeletedRoomStaysDeletedAcrossTheNextSSERebuild() async throws {
        let (orchestrator, spy) = makeCRUDSUT()

        await orchestrator.deleteRoom(try room("room-001", in: orchestrator))
        XCTAssertEqual(spy.calls, ["deleteRoom:room-001"])
        orchestrator.testApplySSEEventsAndRebuild(
            try decodeSSEEvents(groupedLightJSON(id: "gl-002", on: false)), bridgeID: "bridge-1")

        XCTAssertEqual(orchestrator.allRooms.map(\.id), ["room-002"],
            "the deleted room must not be resurrected by a rebuild")
        XCTAssertEqual(orchestrator.testRoomsByBridge()["bridge-1"]?.map(\.id), ["room-002"])
    }

    func testRenamedRoomKeepsItsNameAcrossTheNextSSERebuild() async throws {
        let (orchestrator, _) = makeCRUDSUT()

        await orchestrator.renameRoom(try room("room-001", in: orchestrator),
                                      name: "Den", archetype: "office")
        orchestrator.testApplySSEEventsAndRebuild(
            try decodeSSEEvents(groupedLightJSON(id: "gl-002", on: false)), bridgeID: "bridge-1")

        let renamed = try XCTUnwrap(orchestrator.allRooms.first { $0.id == "room-001" })
        XCTAssertEqual(renamed.name, "Den", "a rebuild must not revert the rename")
        XCTAssertEqual(renamed.archetype, "office")
    }

    func testAFailedRoomDeleteRestoresItExactlyOnce() async throws {
        let (orchestrator, _) = makeCRUDSUT(failWrites: true)

        await orchestrator.deleteRoom(try room("room-001", in: orchestrator))

        XCTAssertEqual(orchestrator.allRooms.filter { $0.id == "room-001" }.count, 1)
        XCTAssertEqual(orchestrator.testRoomsByBridge()["bridge-1"]?.map(\.id).sorted(),
                       ["room-001", "room-002"], "the snapshot is restored too")
    }

    func testAFailedRoomRenameRestoresTheOriginalName() async throws {
        let (orchestrator, _) = makeCRUDSUT(failWrites: true)

        await orchestrator.renameRoom(try room("room-001", in: orchestrator),
                                      name: "Den", archetype: "office")
        orchestrator.testApplySSEEventsAndRebuild(
            try decodeSSEEvents(groupedLightJSON(id: "gl-002", on: false)), bridgeID: "bridge-1")

        XCTAssertEqual(orchestrator.allRooms.first { $0.id == "room-001" }?.name, "Bedroom")
    }

    func testDeletedAndRenamedZonesSurviveTheNextRebuild() async throws {
        let (orchestrator, spy) = makeCRUDSUT()
        let upstairs = try XCTUnwrap(orchestrator.allZones.first { $0.id == "zone-001" })
        let downstairs = try XCTUnwrap(orchestrator.allZones.first { $0.id == "zone-002" })

        await orchestrator.deleteZone(upstairs)
        await orchestrator.renameZone(downstairs, name: "Ground Floor", archetype: "home")
        XCTAssertEqual(spy.calls, ["deleteZone:zone-001", "renameZone:zone-002"])
        orchestrator.testApplySSEEventsAndRebuild(
            try decodeSSEEvents(groupedLightJSON(id: "gl-z02", on: false)), bridgeID: "bridge-1")

        XCTAssertEqual(orchestrator.allZones.map(\.id), ["zone-002"])
        XCTAssertEqual(orchestrator.allZones.first?.name, "Ground Floor")
    }

    /// A room or zone deleted elsewhere (the official Hue app) arrives as a
    /// `delete` batch naming the group and its grouped_light.
    func testSSEDeleteEventRemovesTheRoomAndZoneItNames() throws {
        let (orchestrator, _) = makeCRUDSUT()
        let json = """
        [{"creationtime":"2024-01-01T00:00:00Z","data":[
          {"id":"room-001","id_v1":"/groups/1","type":"room"},
          {"id":"gl-001","id_v1":"/groups/1","type":"grouped_light"},
          {"id":"zone-001","id_v1":"/groups/9","type":"zone"}
        ],"id":"evt-d1","type":"delete"}]
        """
        let result = orchestrator.testApplySSEEventsAndRebuild(
            try decodeSSEEvents(json), bridgeID: "bridge-1")

        XCTAssertTrue(result.rooms)
        XCTAssertTrue(result.zones)
        XCTAssertEqual(orchestrator.allRooms.map(\.id), ["room-002"])
        XCTAssertEqual(orchestrator.allZones.map(\.id), ["zone-002"])
    }

    func testSSEDeleteOfAnotherBridgesRoomIDRemovesNothingHere() throws {
        let (orchestrator, _) = makeCRUDSUT()
        let json = """
        [{"creationtime":"2024-01-01T00:00:00Z","data":[
          {"id":"room-001","type":"room"}
        ],"id":"evt-d2","type":"delete"}]
        """
        let result = orchestrator.testApplySSEEventsAndRebuild(
            try decodeSSEEvents(json), bridgeID: "bridge-2")

        XCTAssertFalse(result.rooms, "exact bridge identity — bridge-2's stream cannot delete bridge-1's room")
        XCTAssertTrue(orchestrator.allRooms.contains { $0.id == "room-001" })
    }

    /// A grouped_light delete carries no state; it used to fall through to the
    /// update handler and flag a rebuild anyway.
    func testAGroupedLightDeleteAloneRemovesAndFlagsNothing() throws {
        let (orchestrator, _) = makeCRUDSUT()
        let json = """
        [{"creationtime":"2024-01-01T00:00:00Z","data":[
          {"id":"gl-001","type":"grouped_light"}
        ],"id":"evt-d3","type":"delete"}]
        """
        let result = orchestrator.testApplySSEEventsAndRebuild(
            try decodeSSEEvents(json), bridgeID: "bridge-1")

        XCTAssertFalse(result.rooms)
        XCTAssertFalse(result.zones)
        XCTAssertTrue(orchestrator.allRooms.contains { $0.id == "room-001" })
    }

    func testAGroupedLightUpdateThatChangesNothingFlagsNoRebuild() throws {
        let orchestrator = makeOrchestratorSSESUT(isOn: true, brightness: 80)
        let json = """
        [{"creationtime":"2024-01-01T00:00:00Z","data":[{
          "id":"gl-001","type":"grouped_light","on":{"on":true},"dimming":{"brightness":80}
        }],"id":"evt-u1","type":"update"}]
        """
        let result = orchestrator.testApplySSEEventsAndRebuild(
            try decodeSSEEvents(json), bridgeID: "bridge-1")

        XCTAssertFalse(result.rooms, "values the card already shows are not a change")
    }

    // MARK: - SSE-10 only an HTTP 200 opens the stream

    /// A 401/403/503 still returns a byte stream; it used to be marked
    /// connected, close at once as a "clean" end, reset the backoff and be
    /// re-dialled every 5 s forever. Anything but 200 now takes the error
    /// backoff instead.
    func testOnlyHTTP200OpensTheEventStream() throws {
        let url = try XCTUnwrap(URL(string: "https://192.0.2.1/eventstream/clip/v2"))
        func http(_ status: Int) throws -> URLResponse {
            try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status,
                                          httpVersion: "HTTP/1.1", headerFields: nil))
        }
        XCTAssertTrue(UnifiedOrchestrator.isAcceptableSSEResponse(try http(200)))
        for status in [204, 401, 403, 404, 429, 500, 503] {
            XCTAssertFalse(UnifiedOrchestrator.isAcceptableSSEResponse(try http(status)),
                           "HTTP \(status) is not an open event stream")
        }
        XCTAssertFalse(UnifiedOrchestrator.isAcceptableSSEResponse(
            URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)),
            "a non-HTTP response is never a stream")
    }

    // MARK: - SSE-11 idle watchdog

    /// Infinite timeouts meant a half-open stream (bridge reboot, silent Wi-Fi
    /// roam) was never noticed. The request timeout is URLSession's idle timer,
    /// so a finite window is the watchdog; only a timeout on an OPEN stream is
    /// an idle expiry (re-dial at once) — a connect timeout keeps the backoff.
    func testOnlyASilentOpenStreamCountsAsAnIdleExpiry() {
        let timedOut = URLError(.timedOut)
        XCTAssertTrue(UnifiedOrchestrator.isSSEIdleTimeout(timedOut, streamWasOpen: true))
        XCTAssertFalse(UnifiedOrchestrator.isSSEIdleTimeout(timedOut, streamWasOpen: false),
            "a bridge that never answered is a connect failure — it keeps the backoff")
        XCTAssertFalse(UnifiedOrchestrator.isSSEIdleTimeout(
            URLError(.networkConnectionLost), streamWasOpen: true))
        XCTAssertFalse(UnifiedOrchestrator.isSSEIdleTimeout(
            HueAPIError.httpError(503), streamWasOpen: true))
        XCTAssertFalse(UnifiedOrchestrator.isSSEIdleTimeout(
            CancellationError(), streamWasOpen: true))
    }

    /// The bridge sends no periodic keep-alive, so the window must be finite
    /// (the old `.infinity` never fired) but generous — in a quiet home every
    /// expiry costs a reconnect.
    func testTheIdleWindowIsFiniteAndGenerous() {
        XCTAssertEqual(UnifiedOrchestrator.sseIdleTimeout, 180)
    }

    // MARK: - SSE-12 addBridge streams; removeBridge drops its scenes

    /// `addBridge` + `loadAll` never started SSE, and a re-pair reusing the
    /// record kept the stream that captured the OLD client (IP/token).
    func testAddingABridgeStartsItsStreamAndARePairRetiresTheStaleOne() throws {
        let id = "sse-add-\(UUID().uuidString)"
        try KeychainManager.shared.saveCredentials(ip: "192.0.2.61", token: "tok-old", for: id)
        defer { KeychainManager.shared.deleteCredentials(for: id) }
        let orchestrator = UnifiedOrchestrator()
        defer { orchestrator.stopSSE() }
        let record = BridgeRecord(id: id, name: "Added", host: "192.0.2.61")

        orchestrator.addBridge(record)
        let first = try XCTUnwrap(orchestrator.testSSETask(bridgeID: id),
            "a bridge added mid-session must get its live event stream")

        try KeychainManager.shared.saveCredentials(ip: "192.0.2.62", token: "tok-new", for: id)
        orchestrator.addBridge(record)   // re-pair onto the same record id
        let second = try XCTUnwrap(orchestrator.testSSETask(bridgeID: id))

        XCTAssertTrue(first.isCancelled, "the stream holding the old client is retired")
        XCTAssertFalse(second.isCancelled)
        XCTAssertNotEqual(first, second)
    }

    func testRemovingABridgeDropsOnlyItsScenes() async {
        let gone = "rm-gone-\(UUID().uuidString)", kept = "rm-kept-\(UUID().uuidString)"
        let orchestrator = UnifiedOrchestrator()
        orchestrator.injectForTesting(clients: [
            gone: BridgeAPIClient(bridgeID: gone, bridgeName: "Gone", ip: "192.0.2.71", token: "t"),
            kept: BridgeAPIClient(bridgeID: kept, bridgeName: "Kept", ip: "192.0.2.72", token: "t"),
        ])
        orchestrator.globalScenes = [
            GlobalSceneItem(id: "\(gone):s1", bridgeSceneID: "s1", name: "Relax",
                            roomID: "room-001", bridgeID: gone,
                            isActive: false, isDynamic: false, speed: 0.5),
            GlobalSceneItem(id: "\(kept):s1", bridgeSceneID: "s1", name: "Relax",
                            roomID: "room-001", bridgeID: kept,
                            isActive: false, isDynamic: false, speed: 0.5),
        ]

        await orchestrator.removeBridge(id: gone)

        XCTAssertEqual(orchestrator.globalScenes.map(\.bridgeID), [kept],
            "a removed bridge's scenes must not linger in the Scenes tab or the widgets")
    }

    // MARK: CRUD fixtures

    private final class CRUDSpyClient: BridgeAPIClient, @unchecked Sendable {
        var failWrites = false
        private let lock = NSLock()
        private var _calls: [String] = []
        var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }

        private func record(_ call: String) throws {
            lock.lock(); _calls.append(call); lock.unlock()
            if failWrites { throw HueAPIError.httpError(500) }
        }
        override func deleteRoom(id: String) async throws { try record("deleteRoom:\(id)") }
        override func deleteZone(id: String) async throws { try record("deleteZone:\(id)") }
        override func renameRoom(id: String, name: String, archetype: String) async throws {
            try record("renameRoom:\(id)")
        }
        override func renameZone(id: String, name: String, archetype: String) async throws {
            try record("renameZone:\(id)")
        }
    }

    private func makeCRUDSUT(failWrites: Bool = false) -> (UnifiedOrchestrator, CRUDSpyClient) {
        let spy = CRUDSpyClient(bridgeID: "bridge-1", bridgeName: "Home", ip: "192.0.2.1", token: "t")
        spy.failWrites = failWrites
        let orchestrator = UnifiedOrchestrator()
        orchestrator.injectForTesting(clients: ["bridge-1": spy])
        func group(_ kind: RoomDisplayItem.Kind, _ id: String, _ name: String, _ gl: String) -> RoomDisplayItem {
            RoomDisplayItem(kind: kind, id: id, name: name, archetype: nil,
                            isOn: true, brightness: 80, groupedLightID: gl, lightCount: 2,
                            bridgeID: "bridge-1", childResourceRefs: [])
        }
        orchestrator.testSeedBridgeGroups(
            bridgeID: "bridge-1",
            rooms: [group(.room, "room-001", "Bedroom", "gl-001"),
                    group(.room, "room-002", "Kitchen", "gl-002")],
            zones: [group(.zone, "zone-001", "Upstairs", "gl-z01"),
                    group(.zone, "zone-002", "Downstairs", "gl-z02")])
        orchestrator.testSetGuestGrants([:])   // no grants — just rebuilds both merged lists
        return (orchestrator, spy)
    }

    private func room(_ id: String, in orchestrator: UnifiedOrchestrator) throws -> RoomDisplayItem {
        try XCTUnwrap(orchestrator.allRooms.first { $0.id == id })
    }

    private func groupedLightJSON(id: String, on: Bool) -> String {
        """
        [{"creationtime":"2024-01-01T00:00:00Z","data":[{
          "id":"\(id)","type":"grouped_light","on":{"on":\(on)}
        }],"id":"evt-gl","type":"update"}]
        """
    }

    private func decodeSSEEvents(_ json: String) throws -> [SSEEvent] {
        let data = try XCTUnwrap(json.data(using: .utf8))
        return try UnifiedOrchestrator.sseDecoder.decode(
            [SSEEvent].self,
            from: data
        )
    }
}
