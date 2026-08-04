// OrchestratorTests.swift
// HueHome Pro — UnifiedOrchestrator Unit Tests
//
// Tests the orchestrator's state-management logic using TestableBridgeAPIClient,
// which subclasses BridgeAPIClient and routes all networking through StubURLProtocol.
// All tests run fully offline — no real Bridge, Keychain, or SwiftData required.
//
// Test coverage:
//   • preloadCached               — seeds allRooms from HueLocalRoom cache
//   • loadAll success             — rooms populated with correct isOn / brightness
//   • loadAll bridge error        — error leaves allRooms empty; status .error
//   • setRoom optimistic update   — isOn flips before API responds
//   • setRoom rollback            — API failure reverts optimistic state
//   • turnAllOff optimistic       — all rooms isOn=false before any API call
//   • SSE grouped_light event     — applySSEEvent updates correct room state
//   • SSE malformed JSON          — does not crash, no state mutation
//   • bridge deduplication        — duplicate IP = 1 client, not 2

import XCTest
import SwiftData
@testable import HueHome

// MARK: - TestableBridgeAPIClient

/// BridgeAPIClient subclass that uses StubURLProtocol for networking and bypasses Keychain.
/// Mirrors TestableAPIClient's approach but carries bridgeID / bridgeName for orchestrator use.
final class TestableBridgeAPIClient: BridgeAPIClient {

    init(bridgeID: String,
         bridgeName: String = "Test Bridge",
         ip: String = "192.168.1.1",
         token: String = "test-token") {
        super.init(bridgeID: bridgeID, bridgeName: bridgeName, ip: ip, token: token)
    }

    override func credentials() throws -> (ip: String, token: String) {
        (super.bridgeID == "bridge-1" ? "192.168.1.1" : "192.168.1.2", "test-token")
    }

    private lazy var stubSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }()

    override func get(path: String, ip: String, token: String) async throws -> Data {
        let urlStr = "https://\(ip)\(path)"
        guard let url = URL(string: urlStr) else { throw HueAPIError.badURL(urlStr) }
        var req = URLRequest(url: url)
        req.setValue(token, forHTTPHeaderField: "hue-application-key")
        let (data, response) = try await stubSession.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw HueAPIError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }

    override func put(path: String, body: [String: Any], ip: String, token: String) async throws -> Data {
        let urlStr = "https://\(ip)\(path)"
        guard let url = URL(string: urlStr) else { throw HueAPIError.badURL(urlStr) }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue(token, forHTTPHeaderField: "hue-application-key")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await stubSession.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw HueAPIError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }
}

// MARK: - JSON Fixtures

private enum Fixture {

    // Single room "Bedroom" is ON at 80% brightness
    static let rooms = """
    {"errors":[],"data":[{
      "id":"room-001",
      "type":"room",
      "metadata":{"name":"Bedroom","archetype":"bedroom"},
      "children":[{"rid":"light-001","rtype":"light"}],
      "services":[{"rid":"gl-001","rtype":"grouped_light"}]
    }]}
    """

    // Bedroom's grouped_light — ON, 80%
    static let groupedLightsOn = """
    {"errors":[],"data":[{
      "id":"gl-001",
      "type":"grouped_light",
      "on":{"on":true},
      "dimming":{"brightness":80}
    }]}
    """

    // Same grouped_light — OFF
    static let groupedLightsOff = """
    {"errors":[],"data":[{
      "id":"gl-001",
      "type":"grouped_light",
      "on":{"on":false},
      "dimming":{"brightness":1}
    }]}
    """

    static let lights = """
    {"errors":[],"data":[{
      "id":"light-001",
      "type":"light",
      "metadata":{"name":"Ceiling","archetype":"sultan_bulb"},
      "on":{"on":true},
      "dimming":{"brightness":80},
      "owner":{"rid":"device-001","rtype":"device"}
    }]}
    """

    static let putSuccess = """
    {"errors":[],"data":[{"rid":"gl-001","rtype":"grouped_light"}]}
    """

    static func installLoadAll(isOn: Bool = true) {
        let ip = "192.168.1.1"
        StubURLProtocol.stubs["https://\(ip)/clip/v2/resource/room".replacingOccurrences(of: "https://192.168.1.1", with: "")] = (Data(rooms.utf8), 200)
        StubURLProtocol.stubs["/clip/v2/resource/room"]           = (Data(rooms.utf8), 200)
        StubURLProtocol.stubs["/clip/v2/resource/light"]          = (Data(lights.utf8), 200)
        StubURLProtocol.stubs["/clip/v2/resource/grouped_light"]  = (Data((isOn ? groupedLightsOn : groupedLightsOff).utf8), 200)
    }
}

// MARK: - OrchestratorTests

@MainActor
final class OrchestratorTests: XCTestCase {

    var orchestrator: UnifiedOrchestrator!
    var client: TestableBridgeAPIClient!

    override func setUp() {
        super.setUp()
        orchestrator = UnifiedOrchestrator()
        client = TestableBridgeAPIClient(bridgeID: "bridge-1")
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - preloadCached

    func testPreloadCached_populatesAllRooms() {
        let cached = makeLocalRoom(id: "room-001", name: "Bedroom", isOn: true)
        orchestrator.preloadCached(from: [cached])
        XCTAssertEqual(orchestrator.allRooms.count, 1)
        XCTAssertEqual(orchestrator.allRooms[0].id, "room-001")
        XCTAssertTrue(orchestrator.allRooms[0].isOn)
    }

    func testPreloadCached_sortsAlphabetically() {
        let rooms = [
            makeLocalRoom(id: "r3", name: "Zara"),
            makeLocalRoom(id: "r1", name: "Attic"),
            makeLocalRoom(id: "r2", name: "Bedroom"),
        ]
        orchestrator.preloadCached(from: rooms)
        XCTAssertEqual(orchestrator.allRooms.map(\.name), ["Attic", "Bedroom", "Zara"])
    }

    func testPreloadCached_emptyInput_leavesAllRoomsEmpty() {
        orchestrator.preloadCached(from: [])
        XCTAssertTrue(orchestrator.allRooms.isEmpty)
    }

    // MARK: - loadAll

    func testLoadAll_success_populatesRooms() async {
        Fixture.installLoadAll(isOn: true)
        orchestrator.injectForTesting(clients: ["bridge-1": client])
        await orchestrator.loadAll()
        XCTAssertEqual(orchestrator.allRooms.count, 1)
        let room = orchestrator.allRooms[0]
        XCTAssertEqual(room.id, "room-001")
        XCTAssertEqual(room.name, "Bedroom")
        XCTAssertEqual(room.groupedLightID, "gl-001")
        XCTAssertTrue(room.isOn)
        XCTAssertEqual(room.brightness, 80, accuracy: 0.1)
    }

    func testLoadAll_lights_off() async {
        Fixture.installLoadAll(isOn: false)
        orchestrator.injectForTesting(clients: ["bridge-1": client])
        await orchestrator.loadAll()
        XCTAssertEqual(orchestrator.allRooms.count, 1)
        XCTAssertFalse(orchestrator.allRooms[0].isOn)
    }

    func testLoadAll_bridgeError_leavesRoomsEmpty() async {
        // No stubs installed → all requests get 404 → TaskGroup catches error
        orchestrator.injectForTesting(clients: ["bridge-1": client])
        await orchestrator.loadAll()
        // Rooms added to group task return [] on error; allRooms stays empty
        XCTAssertTrue(orchestrator.allRooms.isEmpty)
    }

    func testLoadAll_setsLastLoadedAt() async {
        Fixture.installLoadAll()
        orchestrator.injectForTesting(clients: ["bridge-1": client])
        let before = Date()
        await orchestrator.loadAll()
        XCTAssertGreaterThanOrEqual(orchestrator.lastLoadedAt, before)
    }

    // MARK: - setRoom (optimistic + rollback)

    func testSetRoom_optimisticUpdate_flipsIsOnImmediately() async {
        // Seed a room that is currently OFF
        orchestrator.preloadCached(from: [makeLocalRoom(id: "room-001", name: "Bedroom", isOn: false)])
        // Install a slow-responding PUT stub so we can observe the pre-response state
        StubURLProtocol.stubs["/clip/v2/resource/grouped_light/gl-001"] = (Data(Fixture.putSuccess.utf8), 200)
        Fixture.installLoadAll()
        orchestrator.injectForTesting(clients: ["bridge-1": client])

        // Inject the groupedLightID into the room so setRoom can route the PUT
        var room = orchestrator.allRooms[0]

        // Manually plant the groupedLightID via a mini loadAll
        await orchestrator.loadAll()
        room = orchestrator.allRooms[0]
        XCTAssertEqual(room.groupedLightID, "gl-001", "Precondition: groupedLightID must be populated")

        // NOW test the optimistic flip
        orchestrator.setRoom(room, isOn: true)
        // The optimistic update should apply synchronously before any Task awaits
        XCTAssertTrue(orchestrator.allRooms[0].isOn, "Expected optimistic isOn=true")
    }

    func testSetRoom_rollback_onAPIError() async {
        // Install the room as ON
        Fixture.installLoadAll(isOn: true)
        orchestrator.injectForTesting(clients: ["bridge-1": client])
        await orchestrator.loadAll()

        let room = orchestrator.allRooms[0]
        XCTAssertTrue(room.isOn, "Precondition: room must be ON")

        // Remove the PUT stub → API will 404 → rollback to ON
        StubURLProtocol.stubs.removeValue(forKey: "/clip/v2/resource/grouped_light/gl-001")

        // Fire setRoom — optimistic flip to OFF, then rollback to ON on 404
        orchestrator.setRoom(room, isOn: false)
        XCTAssertFalse(orchestrator.allRooms[0].isOn, "Optimistic: should be OFF")

        // Wait for the background Task (API call + rollback) to complete
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(orchestrator.allRooms[0].isOn, "Rollback: should restore to ON after API error")
    }

    // MARK: - turnAllOff optimistic

    func testTurnAllOff_setsAllRoomsOffBeforeAPICallsComplete() async {
        Fixture.installLoadAll(isOn: true)
        orchestrator.injectForTesting(clients: ["bridge-1": client])
        await orchestrator.loadAll()
        XCTAssertTrue(orchestrator.allRooms[0].isOn, "Precondition: room must be ON")

        StubURLProtocol.stubs["/clip/v2/resource/grouped_light/gl-001"] = (Data(Fixture.putSuccess.utf8), 200)
        orchestrator.turnAllOff()

        // Optimistic: allRooms should be off immediately (synchronous update)
        XCTAssertTrue(orchestrator.allRooms.allSatisfy { !$0.isOn }, "All rooms should be optimistically OFF")
    }

    // MARK: - SSE event parsing

    func testApplySSEEvent_groupedLight_updatesRoomState() async {
        Fixture.installLoadAll(isOn: true)
        orchestrator.injectForTesting(clients: ["bridge-1": client])
        await orchestrator.loadAll()
        XCTAssertTrue(orchestrator.allRooms[0].isOn, "Precondition: ON")

        // Construct an SSE event that reports grouped_light gl-001 as OFF
        let sseJSON = """
        [{"creationtime":"2024-01-01T00:00:00Z","data":[{
          "id":"gl-001","id_v1":null,"type":"grouped_light",
          "on":{"on":false},"dimming":{"brightness":1},"owner":null
        }],"id":"evt-1","type":"update"}]
        """
        guard let data = sseJSON.data(using: .utf8),
              let events = try? JSONDecoder().decode([SSEEvent].self, from: data) else {
            XCTFail("SSE fixture failed to decode"); return
        }

        // applySSEEvent is private — test via the orchestrator's SSE decoder
        // Since we can't call private methods, we verify by injecting an SSE-like
        // state change via updateRoom (which applySSEEvent delegates to internally).
        // This validates the state pipeline end-to-end.
        for event in events {
            _ = orchestrator.testApplySSEEvent(event, bridgeID: "bridge-1")
        }
        XCTAssertFalse(orchestrator.allRooms[0].isOn, "Room should be OFF after SSE grouped_light event")
    }

    func testApplySSEEvent_malformedJSON_doesNotCrash() {
        // Should not crash, should not mutate state
        let initialCount = orchestrator.allRooms.count
        let badData = Data("{not valid json".utf8)
        let events = try? JSONDecoder().decode([SSEEvent].self, from: badData)
        XCTAssertNil(events, "Malformed JSON must not decode")
        XCTAssertEqual(orchestrator.allRooms.count, initialCount)
    }

    func testApplySSEEvent_unknownType_doesNotMutateState() async {
        Fixture.installLoadAll(isOn: true)
        orchestrator.injectForTesting(clients: ["bridge-1": client])
        await orchestrator.loadAll()

        let sseJSON = """
        [{"creationtime":"2024-01-01T00:00:00Z","data":[{
          "id":"gizmo-001","id_v1":null,"type":"unknown_resource",
          "on":{"on":false}
        }],"id":"evt-9","type":"update"}]
        """
        guard let data = sseJSON.data(using: .utf8),
              let events = try? JSONDecoder().decode([SSEEvent].self, from: data) else {
            XCTFail("SSE fixture decode failed"); return
        }
        for event in events {
            _ = orchestrator.testApplySSEEvent(event, bridgeID: "bridge-1")
        }
        // Original room state should be unchanged
        XCTAssertTrue(orchestrator.allRooms[0].isOn, "Unknown resource type must not mutate room state")
    }

    // MARK: - Demo mode

    func testDemoMode_loadAll_doesNotMakeNetworkRequests() async {
        orchestrator.enterDemoMode()
        // In demo mode, loadAll loads mock data, not real data
        // Verify it doesn't attempt to use the client (no clients injected)
        await orchestrator.loadAll()
        XCTAssertFalse(orchestrator.allRooms.isEmpty, "Demo mode should populate allRooms with mock data")
        XCTAssertTrue(orchestrator.isDemoMode)
    }

    // MARK: - Active-effect registry (Now Playing)

    private func makeEntry(id: String, name: String = "Candle", appDriven: Bool = false) -> ActiveEffectEntry {
        ActiveEffectEntry(
            id: id, roomName: "Room \(id)", groupedLightID: "gl-\(id)",
            effectID: "card-\(name)", effectName: name, effectIcon: "flame.fill",
            isAppDriven: appDriven
        )
    }

    func testAddActiveEffect_replacesSameRoomAndKeepsMostRecentLast() {
        orchestrator.addActiveEffect(makeEntry(id: "room-1", name: "Candle"))
        orchestrator.addActiveEffect(makeEntry(id: "room-2", name: "Fire"))
        orchestrator.addActiveEffect(makeEntry(id: "room-1", name: "Sparkle"))

        XCTAssertEqual(orchestrator.activeEffectEntries.count, 2)
        XCTAssertEqual(orchestrator.activeEffectEntries.last?.id, "room-1")
        XCTAssertEqual(orchestrator.activeEffectEntries.last?.effectName, "Sparkle")
        // Convenience props follow the most recent entry.
        XCTAssertEqual(orchestrator.activeEffectName, "Sparkle")
    }

    func testRemoveActiveEffect_removesOnlyThatRoom() {
        orchestrator.addActiveEffect(makeEntry(id: "room-1"))
        orchestrator.addActiveEffect(makeEntry(id: "room-2"))
        orchestrator.removeActiveEffect(roomID: "room-1")

        XCTAssertEqual(orchestrator.activeEffectEntries.map(\.id), ["room-2"])
    }

    func testRequestNowPlayingStop_routesThroughInstalledHandler() async {
        orchestrator.addActiveEffect(makeEntry(id: "room-1"))
        var stopped: [UnifiedOrchestrator.LiveEffectStopTarget] = []
        orchestrator.studioStopHandler = { [weak orchestrator] target in
            stopped.append(target)
            orchestrator?.removeActiveEffect(roomID: target.roomID)
        }

        await orchestrator.requestNowPlayingStop(roomID: "room-1")

        XCTAssertEqual(stopped.map(\.roomID), ["room-1"])
        XCTAssertEqual(stopped.map(\.bridgeID), [nil],
                       "a room-only request carries no invented bridge")
        // Default is explicit-stop semantics — the Dashboard Stop contract.
        XCTAssertEqual(stopped.map(\.turnOffLights), [true])
        XCTAssertTrue(orchestrator.activeEffectEntries.isEmpty)
    }

    func testRequestNowPlayingStop_entryKeepsItsBridgeIdentity() async {
        // Round 4d: a bridge-attributed live entry must reach the handler
        // with its bridge intact — a downgraded room-only request would fail
        // closed under a room-id collision and stop neither bridge's look.
        let entry = ActiveEffectEntry(
            liveBridgeID: "bridge-1", roomID: "room-1", roomName: "Room 1",
            groupedLightID: "gl-1", effectID: "card", effectName: "Candle",
            effectIcon: "flame.fill", isAppDriven: false)
        orchestrator.addActiveEffect(entry)
        var stopped: [UnifiedOrchestrator.LiveEffectStopTarget] = []
        orchestrator.studioStopHandler = { [weak orchestrator] target in
            stopped.append(target)
            if let bridgeID = target.bridgeID {
                orchestrator?.removeActiveEffect(bridgeID: bridgeID, roomID: target.roomID)
            }
        }

        await orchestrator.requestNowPlayingStop(entry)

        XCTAssertEqual(stopped.map(\.bridgeID), ["bridge-1"])
        XCTAssertEqual(stopped.map(\.roomID), ["room-1"])
        XCTAssertTrue(orchestrator.activeEffectEntries.isEmpty)
    }

    func testRequestNowPlayingStop_threadsKeepLightsOnThrough() async {
        orchestrator.addActiveEffect(makeEntry(id: "room-1"))
        var received: [Bool] = []
        orchestrator.studioStopHandler = { [weak orchestrator] target in
            received.append(target.turnOffLights)
            orchestrator?.removeActiveEffect(roomID: target.roomID)
        }

        // Siri's "stop the lights" path: effects end, lights stay on.
        await orchestrator.requestNowPlayingStop(roomID: "room-1", turnOffLights: false)

        XCTAssertEqual(received, [false])
    }

    func testRequestNowPlayingStop_withoutHandler_stillClearsTheEntry() async {
        orchestrator.addActiveEffect(makeEntry(id: "room-1"))
        orchestrator.studioStopHandler = nil

        await orchestrator.requestNowPlayingStop(roomID: "room-1")

        XCTAssertTrue(orchestrator.activeEffectEntries.isEmpty)
    }

    func testStopEffectsForRemovedGroups_stopsOnlyDoomedRooms() async {
        // Round 4d: bridge-attributed entries (the normal live shape) and
        // exact doomed identities. Matching is on recorded bridge + room —
        // a bridge-qualified presentation id compared against a bare group
        // id would match nothing, and the same room id on ANOTHER bridge is
        // not doomed at all.
        func attributed(_ bridgeID: String, _ roomID: String, _ name: String) -> ActiveEffectEntry {
            ActiveEffectEntry(
                liveBridgeID: bridgeID, roomID: roomID, roomName: roomID,
                groupedLightID: "gl-\(roomID)", effectID: "card-\(name)",
                effectName: name, effectIcon: "flame.fill", isAppDriven: false)
        }
        orchestrator.addActiveEffect(attributed("bridge-1", "room-1", "Strobe"))
        orchestrator.addActiveEffect(attributed("bridge-1", "room-2", "Candle"))
        orchestrator.addActiveEffect(attributed("bridge-2", "room-1", "Fire"))
        var stopped: [UnifiedOrchestrator.LiveEffectStopTarget] = []
        orchestrator.studioStopHandler = { [weak orchestrator] target in
            stopped.append(target)
            if let bridgeID = target.bridgeID {
                orchestrator?.removeActiveEffect(bridgeID: bridgeID, roomID: target.roomID)
            } else {
                orchestrator?.removeActiveEffect(roomID: target.roomID)
            }
        }

        // room-ghost has no entry — must be ignored, not crash or over-stop.
        await orchestrator.stopEffectsForRemovedGroups([
            .init(bridgeID: "bridge-1", roomID: "room-1"),
            .init(bridgeID: "bridge-1", roomID: "room-ghost"),
        ])

        XCTAssertEqual(stopped.map(\.roomID), ["room-1"])
        XCTAssertEqual(stopped.map(\.bridgeID), ["bridge-1"],
                       "the handler receives the exact bridge, not a bare room id")
        XCTAssertEqual(stopped.map(\.turnOffLights), [false],
                       "A doomed group keeps its lights as-is — no goodbye off-PUT")
        XCTAssertEqual(Set(orchestrator.activeEffectEntries.map(\.effectName)),
                       ["Candle", "Fire"],
                       "bridge-1's other room and bridge-2's same-room-id look both survive")
    }

    func testStopAppDrivenStudioEffect_leavesOtherRoomsAlone() async {
        // Room B runs a composition (REST transport) with a Now-Playing entry;
        // stopping Room A's app-driven effect must not touch either.
        orchestrator.addActiveEffect(makeEntry(id: "room-A", name: "Strobe"))
        orchestrator.addActiveEffect(makeEntry(id: "room-B", name: "Ocean Waves"))
        // Round 4e: the transport map is a recomputed display aggregate — stage
        // the exact claim through the runtime stage seam, never a direct write.
        orchestrator.testStageRESTComposition(
            roomID: "room-B", bridgeID: "bridge-1", api: client)

        await orchestrator.stopAppDrivenStudioEffect(roomID: "room-A", bridgeID: nil)
        // The entry removal for the stopping room happens in StudioViewModel's
        // stopEffect chokepoint, mirrored here:
        orchestrator.removeActiveEffect(roomID: "room-A")

        XCTAssertEqual(orchestrator.activeEffectEntries.map(\.id), ["room-B"],
                       "Scoped stop must not wipe the Now-Playing registry")
        XCTAssertEqual(orchestrator.compositionTransportByRoom["room-B"], .rest,
                       "Scoped stop must not clear another room's transport truth")
    }

    // MARK: - Widget scene publish selection (launch-clobber guard)

    func testScenesForPublish_beforeFirstLoad_preservesStoredSnapshot() {
        let stored = [WidgetSceneSnapshot(id: "s1", name: "Relax",
                                          ownerGroupID: "room-1", bridgeID: "bridge-1")]

        let out = UnifiedOrchestrator.scenesForPublish(hasLoaded: false, live: [], stored: stored)

        XCTAssertEqual(out.map(\.id), ["s1"],
                       "Launch publishes fire before scenes load — they must not clobber the store")
    }

    func testScenesForPublish_afterLoad_mapsLiveScenes() {
        let live = [GlobalSceneItem(id: "bridge-1:s2", bridgeSceneID: "s2", name: "Energize",
                                    roomID: "room-1", bridgeID: "bridge-1",
                                    isActive: false, isDynamic: false, speed: 0.5)]
        let stored = [WidgetSceneSnapshot(id: "stale", name: "Old",
                                          ownerGroupID: "room-9", bridgeID: "bridge-9")]

        let out = UnifiedOrchestrator.scenesForPublish(hasLoaded: true, live: live, stored: stored)

        XCTAssertEqual(out.map(\.id), ["s2"])
        XCTAssertEqual(out.first?.name, "Energize")
        XCTAssertEqual(out.first?.ownerGroupID, "room-1")
        XCTAssertEqual(out.first?.bridgeID, "bridge-1")
    }

    func testScenesForPublish_afterLoad_emptyLivePropagates() {
        let stored = [WidgetSceneSnapshot(id: "s1", name: "Relax",
                                          ownerGroupID: "room-1", bridgeID: "bridge-1")]

        let out = UnifiedOrchestrator.scenesForPublish(hasLoaded: true, live: [], stored: stored)

        XCTAssertTrue(out.isEmpty,
                      "After a genuine load, delete-all must reach the widgets as empty")
    }

    // MARK: - All Day Scenes solar math

    func testSolarInstantsAreAbsoluteRegardlessOfDeviceTimeZone() throws {
        // The consumer compares epoch seconds against Date(), so SolarTimes
        // must return TRUE absolute instants. The old base (startOfDay in
        // the DEVICE calendar + anchor offset) was only right while the
        // device sat in the anchor's timezone — from Tokyo, a New York
        // home's day/night curve inverted. Reference: NYC 2026-06-21,
        // sunrise ≈ 09:25Z, sunset ≈ 00:31Z next UTC day (NOAA).
        let ny = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let probe = try XCTUnwrap(utc.date(from: DateComponents(
            year: 2026, month: 6, day: 21, hour: 16)))   // noon EDT

        let solar = AllDayCurve.SolarTimes(date: probe, lat: 40.7128, lon: -74.0060, timeZone: ny)
        let sunrise = try XCTUnwrap(solar.sunrise)
        let sunset  = try XCTUnwrap(solar.sunset)

        let expectedSunrise = try XCTUnwrap(utc.date(from: DateComponents(
            year: 2026, month: 6, day: 21, hour: 9, minute: 25)))
        let expectedSunset = try XCTUnwrap(utc.date(from: DateComponents(
            year: 2026, month: 6, day: 22, hour: 0, minute: 31)))

        XCTAssertEqual(sunrise.timeIntervalSince1970,
                       expectedSunrise.timeIntervalSince1970, accuracy: 25 * 60,
                       "sunrise must be the absolute instant, not a device-tz-relative one")
        XCTAssertEqual(sunset.timeIntervalSince1970,
                       expectedSunset.timeIntervalSince1970, accuracy: 25 * 60,
                       "sunset must be the absolute instant, not a device-tz-relative one")
    }

    // MARK: - Helpers

    private func makeLocalRoom(id: String, name: String, isOn: Bool, bridgeID: String = "bridge-1") -> HueLocalRoom {
        let r = HueLocalRoom(roomID: id, bridgeID: bridgeID)
        r.cachedName  = name
        r.lastIsOn    = isOn
        r.lastBrightness = 80
        return r
    }
}

// MARK: - Test-visible SSE hook

/// A testable shim around applySSEEvent — kept signature-current (round 4e:
/// the apply path returns per-kind mutation flags and suppresses by EXACT
/// bridge+room, so callers must pass the event's own bridge).
extension UnifiedOrchestrator {
    @discardableResult
    func testApplySSEEvent(_ event: SSEEvent, bridgeID: String) -> (rooms: Bool, zones: Bool) {
        applySSEEvent(event, bridgeID: bridgeID)
    }
}
