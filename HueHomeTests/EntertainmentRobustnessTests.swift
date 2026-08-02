// EntertainmentRobustnessTests.swift
// HueHome Pro — Unit Tests
//
// Regression guards for audit findings M-06 / M-09 / L-11 (entertainment/DTLS):
//  - M-09: ContinuationGate resumes exactly once under a concurrent
//    handshake-complete + timeout race (no CONTINUATION MISUSE trap).
//  - L-11: a failed DTLS open issues a compensating action=stop so the
//    entertainment configuration is not left activated on the bridge.
//  - M-06: deactivateStuckEntertainmentSessions excludes the app's own
//    active (registered) session and still stops a genuinely stale one.
//
// M-10 (send-failure reconnect) requires a live DTLS socket and is covered
// by the on-device checkpoint; the reconnect scheduling is bounded by code
// inspection (max 3 attempts, cancelled in stopSession).
//
// Audit: docs/audit/hardening-audit-2026-07-01.md §6 "Entertainment / DTLS".

import XCTest
@testable import HueHome

// MARK: - Spy REST client (records entertainment_configuration PUTs)

private final class EntertainmentSpyClient: BridgeAPIClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _actions: [(configID: String, action: String)] = []
    var actions: [(configID: String, action: String)] {
        lock.lock(); defer { lock.unlock() }
        return _actions
    }

    /// entertainment_configuration list returned by GET.
    var stubConfigsJSON: String = #"{"data": []}"#
    /// `/resource/entertainment` list — the service→owner-device half of the join.
    var stubEntertainmentJSON: String = #"{"data": []}"#
    /// Lights returned by `fetchLights()` — the device→light half of the join.
    var stubLights: [HueLight] = []

    /// Per-endpoint failure switches, so a test can fail exactly one component.
    var configsShouldFail = false
    var entertainmentShouldFail = false
    var lightsShouldFail = false

    private var _getPaths: [String] = []
    /// Every GET this client was asked for — proves synchronous paths stay offline.
    var getPaths: [String] {
        lock.lock(); defer { lock.unlock() }
        return _getPaths
    }
    private var _fetchLightsCallCount = 0
    var fetchLightsCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _fetchLightsCallCount
    }

    func resetRecordings() {
        lock.lock(); defer { lock.unlock() }
        _getPaths = []
        _fetchLightsCallCount = 0
        _actions = []
    }

    override func get(path: String, ip: String, token: String) async throws -> Data {
        lock.lock(); _getPaths.append(path); lock.unlock()
        if path.contains("entertainment_configuration") {
            if configsShouldFail { throw HueAPIError.httpError(500) }
            return Data(stubConfigsJSON.utf8)
        }
        if path.contains("resource/entertainment") {
            if entertainmentShouldFail { throw HueAPIError.httpError(500) }
            return Data(stubEntertainmentJSON.utf8)
        }
        return Data("{}".utf8)
    }

    // Not overriding this would route through `get`, receive `{}`, and throw in
    // decode — so every warm would silently see zero lights.
    override func fetchLights() async throws -> [HueLight] {
        lock.lock(); _fetchLightsCallCount += 1; lock.unlock()
        if lightsShouldFail { throw HueAPIError.httpError(500) }
        return stubLights
    }

    override func put(path: String, body: [String: Any], ip: String, token: String) async throws -> Data {
        if path.contains("entertainment_configuration/"),
           let action = body["action"] as? String,
           let configID = path.split(separator: "/").last.map(String.init) {
            lock.lock()
            _actions.append((configID, action))
            lock.unlock()
        }
        return Data("{}".utf8)
    }
}

// MARK: - Tests

final class EntertainmentRobustnessTests: XCTestCase {

    // ──────────────────────────────────────────────
    // MARK: - M-09: continuation resumes exactly once
    // ──────────────────────────────────────────────

    func testContinuationGateResumesExactlyOnceUnderConcurrency() async {
        for _ in 0..<50 {
            let gate = ContinuationGate()
            let winners = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
                for _ in 0..<16 {
                    group.addTask { gate.tryResume() }
                }
                var count = 0
                for await won in group where won { count += 1 }
                return count
            }
            XCTAssertEqual(winners, 1,
                "exactly ONE racer may resume the continuation (M-09 double-resume trap)")
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - L-11: failed open sends a compensating action=stop
    // ──────────────────────────────────────────────

    func testFailedDTLSOpenIssuesCompensatingStop() async {
        let spy = EntertainmentSpyClient(bridgeID: "bridge-1", bridgeName: "Test",
                                         ip: "192.0.2.1", token: "t")
        // Invalid (non-hex) client key → openDTLSConnection throws before any
        // network I/O, exercising the failed-open path deterministically.
        let client = HueEntertainmentClient(bridgeIP: "192.0.2.1",
                                            username: "user",
                                            clientKeyHex: "ZZ-not-hex",
                                            restClient: spy)

        do {
            try await client.startSession(configID: "cfg-fail")
            XCTFail("startSession must throw when the DTLS open fails")
        } catch {
            // expected
        }

        let actions = spy.actions
        XCTAssertEqual(actions.map(\.action), ["start", "stop"],
            "a failed open must roll back with action=stop (L-11)")
        XCTAssertEqual(Set(actions.map(\.configID)), ["cfg-fail"])
        XCTAssertFalse(HueEntertainmentClient.isAppOwnedSession(configID: "cfg-fail"),
            "a failed session must not stay registered as app-owned")
    }

    // ──────────────────────────────────────────────
    // MARK: - M-06: app-owned sessions excluded from stuck cleanup
    // ──────────────────────────────────────────────

    @MainActor
    func testStuckCleanupSkipsAppOwnedSessionAndStopsStaleOne() async {
        let spy = EntertainmentSpyClient(bridgeID: "bridge-1", bridgeName: "Test",
                                         ip: "192.0.2.1", token: "t")
        spy.stubConfigsJSON = """
        {"data": [
            {"id": "cfg-ours",  "status": "active"},
            {"id": "cfg-stale", "status": "active"},
            {"id": "cfg-idle",  "status": "inactive"}
        ]}
        """
        let orchestrator = UnifiedOrchestrator()
        orchestrator.injectForTesting(clients: ["bridge-1": spy])

        HueEntertainmentClient.registerActiveSession(configID: "cfg-ours")
        defer { HueEntertainmentClient.unregisterActiveSession(configID: "cfg-ours") }

        await orchestrator.deactivateStuckEntertainmentSessions()

        let stopped = spy.actions.filter { $0.action == "stop" }.map(\.configID)
        XCTAssertEqual(stopped, ["cfg-stale"],
            "cleanup must stop the stale session and NEVER the app's own active one (M-06)")
    }

    func testSessionRegistryRegisterUnregister() {
        XCTAssertFalse(HueEntertainmentClient.isAppOwnedSession(configID: "cfg-x"))
        HueEntertainmentClient.registerActiveSession(configID: "cfg-x")
        XCTAssertTrue(HueEntertainmentClient.isAppOwnedSession(configID: "cfg-x"))
        HueEntertainmentClient.unregisterActiveSession(configID: "cfg-x")
        XCTAssertFalse(HueEntertainmentClient.isAppOwnedSession(configID: "cfg-x"))
    }

    func testSessionRegistryIsRefCounted() {
        // Two client instances can stream the same configuration (Sync +
        // Studio) — one stopping must not expose the other to the cleanup.
        HueEntertainmentClient.registerActiveSession(configID: "cfg-rc")
        HueEntertainmentClient.registerActiveSession(configID: "cfg-rc")
        HueEntertainmentClient.unregisterActiveSession(configID: "cfg-rc")
        XCTAssertTrue(HueEntertainmentClient.isAppOwnedSession(configID: "cfg-rc"),
            "one remaining owner must keep the session protected")
        HueEntertainmentClient.unregisterActiveSession(configID: "cfg-rc")
        XCTAssertFalse(HueEntertainmentClient.isAppOwnedSession(configID: "cfg-rc"))
        // Extra unregister must not underflow into protecting ghosts.
        HueEntertainmentClient.unregisterActiveSession(configID: "cfg-rc")
        XCTAssertFalse(HueEntertainmentClient.isAppOwnedSession(configID: "cfg-rc"))
    }

    // ──────────────────────────────────────────────
    // MARK: - M-10 follow-through: terminal failure drives REST failover
    // ──────────────────────────────────────────────

    func testTerminalFailureTearsDownFlagsAndResetsOnRestart() async {
        let spy = EntertainmentSpyClient(bridgeID: "bridge-1", bridgeName: "Test",
                                         ip: "192.0.2.1", token: "t")
        let client = HueEntertainmentClient(bridgeIP: "192.0.2.1",
                                            username: "user",
                                            clientKeyHex: "ZZ-not-hex",
                                            restClient: spy)
        await client.seedSessionForTesting(configID: "cfg-term")

        await client.noteTerminalFailure()

        let failed = await client.isTerminallyFailed
        XCTAssertTrue(failed,
            "terminal failure must be observable so owning render loops can fail over to REST")
        XCTAssertEqual(spy.actions.map(\.action), ["stop"],
            "abandonment must best-effort stop the configuration on the bridge")
        XCTAssertFalse(HueEntertainmentClient.isAppOwnedSession(configID: "cfg-term"),
            "a terminally failed session must leave the registry — the stuck-session cleanup would skip an 'owned' dead config forever")

        // The next startSession clears the flag before opening (this one
        // throws on the invalid key, but the reset precedes the open).
        _ = try? await client.startSession(configID: "cfg-term-2")
        let resetFlag = await client.isTerminallyFailed
        XCTAssertFalse(resetFlag, "startSession must reset the terminal-failure flag")
    }

    func testStartSessionRegistersBeforeRESTActivate() async {
        // The cleanup race (loadAll during the DTLS handshake) is closed by
        // registering BEFORE action=start. The failed-open path must still
        // end unregistered.
        let spy = EntertainmentSpyClient(bridgeID: "bridge-1", bridgeName: "Test",
                                         ip: "192.0.2.1", token: "t")
        let client = HueEntertainmentClient(bridgeIP: "192.0.2.1",
                                            username: "user",
                                            clientKeyHex: "ZZ-not-hex",
                                            restClient: spy)
        _ = try? await client.startSession(configID: "cfg-race")
        XCTAssertFalse(HueEntertainmentClient.isAppOwnedSession(configID: "cfg-race"),
            "a failed startSession must leave the registry balanced")
    }

    // MARK: - L-12: PSK length validation

    func testDecodePSKAcceptsExactly32HexChars() {
        let key = String(repeating: "AB", count: 16)   // 32 hex chars
        XCTAssertEqual(HueEntertainmentClient.decodePSK(key)?.count, 16)
        // Data(hexString:) trims edge whitespace — still a valid 16-byte key.
        XCTAssertEqual(HueEntertainmentClient.decodePSK(" \(key) ")?.count, 16)
    }

    func testDecodePSKRefusesWrongLengthAndNonHex() {
        // A truncated key used to sail into the DTLS handshake and die as a
        // 10-second timeout; now it's refused before the connection opens.
        XCTAssertNil(HueEntertainmentClient.decodePSK(""))
        XCTAssertNil(HueEntertainmentClient.decodePSK(String(repeating: "AB", count: 15)))  // 30 chars
        XCTAssertNil(HueEntertainmentClient.decodePSK(String(repeating: "AB", count: 17)))  // 34 chars
        XCTAssertNil(HueEntertainmentClient.decodePSK(String(repeating: "A", count: 31)))   // odd length
        XCTAssertNil(HueEntertainmentClient.decodePSK(String(repeating: "ZZ", count: 16)))  // non-hex
    }
}

// ═══════════════════════════════════════════════════════════════════════
// MARK: - Composer 2 packet 1b: caches, honesty, and one selection per start
// ═══════════════════════════════════════════════════════════════════════
//
// `EntertainmentAreaSelectorTests` covers the selection contract itself. These
// cover what the orchestrator does around it: which components it warms, what
// it is willing to CLAIM about a room, and the guarantee that the config a
// session is opened with is the one whose channels drive the render loop.
//
// The DTLS handshake is never reached: every client key here is non-hex, so
// `decodePSK` refuses before any socket exists. That still exercises the real
// REST activation, which is what the ordering assertions read.

@MainActor
final class EntertainmentRoomSelectionTests: XCTestCase {

    private typealias Availability = UnifiedOrchestrator.EntertainmentAvailability

    private var orchestrator: UnifiedOrchestrator!
    private var bridgeA: EntertainmentSpyClient!
    private var bridgeB: EntertainmentSpyClient!

    private let bridgeAID = "bridge-a"
    private let bridgeBID = "bridge-b"

    override func setUp() async throws {
        try await super.setUp()
        bridgeA = EntertainmentSpyClient(bridgeID: bridgeAID, bridgeName: "Bridge A",
                                         ip: "192.0.2.1", token: "t")
        bridgeB = EntertainmentSpyClient(bridgeID: bridgeBID, bridgeName: "Bridge B",
                                         ip: "192.0.2.2", token: "t")
        orchestrator = UnifiedOrchestrator()
        orchestrator.injectForTesting(clients: [bridgeAID: bridgeA, bridgeBID: bridgeB])
        // Availability gates on a client key before it looks at any cache.
        // Non-hex on purpose: DTLS must refuse before opening a socket.
        try KeychainManager.shared.saveCredentials(
            ip: "192.0.2.1", token: "t", clientKey: "ZZ-not-hex", for: bridgeAID)
        try KeychainManager.shared.saveCredentials(
            ip: "192.0.2.2", token: "t", clientKey: "ZZ-not-hex", for: bridgeBID)
    }

    override func tearDown() async throws {
        await orchestrator.stopStudioMode()
        KeychainManager.shared.deleteCredentials(for: bridgeAID)
        KeychainManager.shared.deleteCredentials(for: bridgeBID)
        orchestrator = nil
        bridgeA = nil
        bridgeB = nil
        try await super.tearDown()
    }

    // ── Fixtures ──────────────────────────────────────────────

    private func room(_ id: String, bridge: String, lightIDs: [String]) -> RoomDisplayItem {
        RoomDisplayItem(
            kind: .room,
            id: id,
            name: id,
            archetype: nil,
            isOn: true,
            brightness: 100,
            groupedLightID: "grouped-\(id)",
            lightCount: lightIDs.count,
            bridgeID: bridge,
            childResourceRefs: lightIDs.map { (rid: $0, rtype: "light") }
        )
    }

    private func light(_ id: String, device: String) -> HueLight {
        HueLight(
            id: id,
            metadata: LightMetadata(name: id, archetype: nil),
            on: OnState(on: true),
            dimming: DimmingState(brightness: 100),
            color: nil,
            color_temperature: nil,
            owner: ResourceRef(rid: device, rtype: "device")
        )
    }

    /// `L1…Ln`, each owned by its own device `D1…Dn`.
    private func lights(_ count: Int) -> [HueLight] {
        (1...count).map { light("L\($0)", device: "D\($0)") }
    }

    /// `/resource/entertainment` payload wiring E1→D1, E2→D2, …
    private func entertainmentJSON(_ count: Int) -> String {
        let items = (1...count).map {
            #"{"id":"E\#($0)","owner":{"rid":"D\#($0)","rtype":"device"}}"#
        }
        return #"{"data":[\#(items.joined(separator: ","))]}"#
    }

    /// One entertainment_configuration, one channel per entertainment service.
    private func configJSON(id: String, name: String, ent entIDs: [String]) -> String {
        let channels = entIDs.enumerated().map { index, entID in
            #"{"channel_id":\#(index),"position":{"x":0,"y":0,"z":0},"members":[{"service":{"rid":"\#(entID)","rtype":"entertainment"}}]}"#
        }
        return #"{"id":"\#(id)","metadata":{"name":"\#(name)"},"channels":[\#(channels.joined(separator: ","))]}"#
    }

    private func configsJSON(_ configs: [String]) -> String {
        #"{"data":[\#(configs.joined(separator: ","))]}"#
    }

    /// Two rooms, two areas, one bridge — the wrong-room scenario.
    private func stageTwoAreaBridge(_ spy: EntertainmentSpyClient) {
        spy.stubLights = lights(4)
        spy.stubEntertainmentJSON = entertainmentJSON(4)
        spy.stubConfigsJSON = configsJSON([
            configJSON(id: "area-living", name: "Living Room TV", ent: ["E3", "E4"]),
            configJSON(id: "area-bedroom", name: "Bedroom", ent: ["E1", "E2"]),
        ])
    }

    // ── Honest availability ───────────────────────────────────

    func testNeverAskedReportsUnknownAndStillOffersStreaming() {
        let bedroom = room("bedroom", bridge: bridgeAID, lightIDs: ["L1", "L2"])
        XCTAssertEqual(orchestrator.entertainmentAvailability(for: bedroom), .unknown)
        XCTAssertTrue(Availability.unknown.canStream)
    }

    func testABridgeWithNoAreasReportsNoArea() async {
        bridgeA.stubLights = lights(2)
        bridgeA.stubEntertainmentJSON = entertainmentJSON(2)
        bridgeA.stubConfigsJSON = #"{"data":[]}"#
        let bedroom = room("bedroom", bridge: bridgeAID, lightIDs: ["L1", "L2"])

        await orchestrator.warmEntertainmentCaches(for: bedroom)
        XCTAssertEqual(orchestrator.entertainmentAvailability(for: bedroom), .noArea)
    }

    func testAMatchingAreaReportsAvailableUnderItsOwnName() async {
        stageTwoAreaBridge(bridgeA)
        let bedroom = room("bedroom", bridge: bridgeAID, lightIDs: ["L1", "L2"])

        await orchestrator.warmEntertainmentCaches(for: bedroom)
        XCTAssertEqual(orchestrator.entertainmentAvailability(for: bedroom),
                       .available(areaName: "Bedroom"),
                       "the name reported must be the area actually selected")
    }

    /// The lie this packet exists to stop: the bridge HAS areas, just not for
    /// this room. Saying "no area" would send the user to build a fourth one.
    func testARoomInNoAreaReportsNoMatchingAreaNotNoArea() async {
        stageTwoAreaBridge(bridgeA)
        bridgeA.stubLights = lights(6)
        bridgeA.stubEntertainmentJSON = entertainmentJSON(6)
        let study = room("study", bridge: bridgeAID, lightIDs: ["L5", "L6"])

        await orchestrator.warmEntertainmentCaches(for: study)
        XCTAssertEqual(orchestrator.entertainmentAvailability(for: study), .noMatchingArea)
        XCTAssertFalse(Availability.noMatchingArea.canStream)
    }

    /// Cold room lights are "we don't know", never a verdict — a false
    /// unavailable is worse than a fallback nobody notices.
    func testAnUnresolvableRoomAnswersUnknownRatherThanDisablingStreaming() async {
        stageTwoAreaBridge(bridgeA)
        let bedroom = room("bedroom", bridge: bridgeAID, lightIDs: ["L1", "L2"])
        await orchestrator.warmEntertainmentCaches(for: bedroom)

        // Same bridge, but this room's refs resolve to nothing we have.
        let ghost = room("ghost", bridge: bridgeAID, lightIDs: [])
        XCTAssertEqual(orchestrator.entertainmentAvailability(for: ghost), .unknown)
    }

    func testAnAreaWithUnusableChannelsIsNotReportedAvailable() async {
        bridgeA.stubLights = lights(2)
        bridgeA.stubEntertainmentJSON = entertainmentJSON(2)
        // channel_id 300 cannot be carried by the DTLS protocol at all.
        bridgeA.stubConfigsJSON = #"""
        {"data":[{"id":"broken","metadata":{"name":"Bedroom"},"channels":[
          {"channel_id":300,"position":{"x":0,"y":0,"z":0},"members":[{"service":{"rid":"E1","rtype":"entertainment"}}]},
          {"channel_id":1,"position":{"x":0,"y":0,"z":0},"members":[{"service":{"rid":"E2","rtype":"entertainment"}}]}
        ]}]}
        """#
        let bedroom = room("bedroom", bridge: bridgeAID, lightIDs: ["L1", "L2"])

        await orchestrator.warmEntertainmentCaches(for: bedroom)
        XCTAssertEqual(orchestrator.entertainmentAvailability(for: bedroom), .noMatchingArea,
            "promising a stream that startup must refuse is a lie with extra steps")
    }

    // ── Failure is not an answer ──────────────────────────────

    func testAFailedFirstFetchLeavesAvailabilityUnknownNotNoArea() async {
        bridgeA.stubLights = lights(2)
        bridgeA.stubEntertainmentJSON = entertainmentJSON(2)
        bridgeA.configsShouldFail = true
        let bedroom = room("bedroom", bridge: bridgeAID, lightIDs: ["L1", "L2"])

        await orchestrator.warmEntertainmentCaches(for: bedroom)
        XCTAssertEqual(orchestrator.entertainmentAvailability(for: bedroom), .unknown,
            "a bridge that timed out has not told us it has no areas")
    }

    func testATransientFailureAfterAGoodWarmKeepsTheLastKnownGoodAnswer() async {
        stageTwoAreaBridge(bridgeA)
        let bedroom = room("bedroom", bridge: bridgeAID, lightIDs: ["L1", "L2"])
        await orchestrator.warmEntertainmentCaches(for: bedroom)
        XCTAssertEqual(orchestrator.entertainmentAvailability(for: bedroom),
                       .available(areaName: "Bedroom"))

        bridgeA.configsShouldFail = true
        bridgeA.entertainmentShouldFail = true
        await orchestrator.warmEntertainmentCaches(for: bedroom, force: true)

        XCTAssertEqual(orchestrator.entertainmentAvailability(for: bedroom),
                       .available(areaName: "Bedroom"),
            "a blip must not demote a bridge we already have the answer for")
        XCTAssertNotNil(orchestrator.testEntertainmentMembership(forBridge: bridgeAID))
    }

    func testAFailureOnOneBridgeDoesNotDisturbAnother() async {
        stageTwoAreaBridge(bridgeA)
        stageTwoAreaBridge(bridgeB)
        let bedroomA = room("bedroom-a", bridge: bridgeAID, lightIDs: ["L1", "L2"])
        let bedroomB = room("bedroom-b", bridge: bridgeBID, lightIDs: ["L1", "L2"])
        await orchestrator.warmEntertainmentCaches(for: bedroomA)
        await orchestrator.warmEntertainmentCaches(for: bedroomB)

        bridgeA.configsShouldFail = true
        bridgeA.entertainmentShouldFail = true
        bridgeA.lightsShouldFail = true
        await orchestrator.warmEntertainmentCaches(for: bedroomA, force: true)

        XCTAssertEqual(orchestrator.entertainmentAvailability(for: bedroomB),
                       .available(areaName: "Bedroom"))
        XCTAssertNotNil(orchestrator.testEntertainmentMembership(forBridge: bridgeBID))
    }

    // ── Component-aware warming ───────────────────────────────

    /// A single "did we fetch this bridge" flag would strand this bridge on
    /// `.unknown` forever: the configs arrived, so nothing would ever retry the
    /// half that failed.
    func testAMissingMembershipIsRetriedByAnOrdinaryWarm() async {
        stageTwoAreaBridge(bridgeA)
        bridgeA.entertainmentShouldFail = true
        let bedroom = room("bedroom", bridge: bridgeAID, lightIDs: ["L1", "L2"])

        await orchestrator.warmEntertainmentCaches(for: bedroom)
        XCTAssertEqual(orchestrator.entertainmentAvailability(for: bedroom), .unknown)
        XCTAssertNil(orchestrator.testEntertainmentMembership(forBridge: bridgeAID))

        bridgeA.entertainmentShouldFail = false
        await orchestrator.warmEntertainmentCaches(for: bedroom)   // NOT force

        XCTAssertEqual(orchestrator.entertainmentAvailability(for: bedroom),
                       .available(areaName: "Bedroom"),
            "the missing component must be retried without needing a forced refresh")
    }

    func testMissingConfigsAreRetriedByAnOrdinaryWarm() async {
        stageTwoAreaBridge(bridgeA)
        bridgeA.configsShouldFail = true
        let bedroom = room("bedroom", bridge: bridgeAID, lightIDs: ["L1", "L2"])

        await orchestrator.warmEntertainmentCaches(for: bedroom)
        XCTAssertEqual(orchestrator.entertainmentAvailability(for: bedroom), .unknown)
        XCTAssertNotNil(orchestrator.testEntertainmentMembership(forBridge: bridgeAID),
            "the half that succeeded is kept")

        bridgeA.configsShouldFail = false
        await orchestrator.warmEntertainmentCaches(for: bedroom)   // NOT force

        XCTAssertEqual(orchestrator.entertainmentAvailability(for: bedroom),
                       .available(areaName: "Bedroom"))
    }

    func testASuccessfullyEmptyMembershipIsNotTreatedAsUnknown() async {
        bridgeA.stubLights = lights(2)
        bridgeA.stubEntertainmentJSON = #"{"data":[]}"#   // succeeded, genuinely empty
        bridgeA.stubConfigsJSON = configsJSON([
            configJSON(id: "area", name: "Somewhere", ent: ["E1"]),
        ])
        let bedroom = room("bedroom", bridge: bridgeAID, lightIDs: ["L1", "L2"])

        await orchestrator.warmEntertainmentCaches(for: bedroom)
        XCTAssertEqual(orchestrator.testEntertainmentMembership(forBridge: bridgeAID), [:])
        XCTAssertEqual(orchestrator.entertainmentAvailability(for: bedroom), .noMatchingArea,
            "we asked and nothing resolves — that is a verdict, not a shrug")
    }

    // ── Availability never touches the network ────────────────

    func testAvailabilityAndSelectionAreOfflineWhenWarm() async {
        stageTwoAreaBridge(bridgeA)
        let bedroom = room("bedroom", bridge: bridgeAID, lightIDs: ["L1", "L2"])
        await orchestrator.warmEntertainmentCaches(for: bedroom)
        bridgeA.resetRecordings()

        for _ in 0..<20 {
            _ = orchestrator.entertainmentAvailability(for: bedroom)
            _ = orchestrator.selectedEntertainmentConfig(for: bedroom)
            _ = orchestrator.activeEntertainmentConfig(for: bedroom)
        }

        XCTAssertTrue(bridgeA.getPaths.isEmpty, "a menu build must not hit the bridge")
        XCTAssertEqual(bridgeA.fetchLightsCallCount, 0)
    }

    func testAvailabilityIsOfflineOnAColdBridgeToo() {
        let bedroom = room("bedroom", bridge: bridgeAID, lightIDs: ["L1", "L2"])
        XCTAssertEqual(orchestrator.entertainmentAvailability(for: bedroom), .unknown)
        XCTAssertTrue(bridgeA.getPaths.isEmpty)
        XCTAssertEqual(bridgeA.fetchLightsCallCount, 0)
    }

    // ── Two rooms, one bridge; two bridges, same IDs ───────────

    func testEachRoomOnASharedBridgeSelectsItsOwnArea() async {
        stageTwoAreaBridge(bridgeA)
        let bedroom = room("bedroom", bridge: bridgeAID, lightIDs: ["L1", "L2"])
        let living = room("living", bridge: bridgeAID, lightIDs: ["L3", "L4"])
        await orchestrator.warmEntertainmentCaches(for: bedroom)

        XCTAssertEqual(orchestrator.selectedEntertainmentConfig(for: bedroom)?.id, "area-bedroom")
        XCTAssertEqual(orchestrator.selectedEntertainmentConfig(for: living)?.id, "area-living")
    }

    /// A bridge with exactly one correctly-mapped area keeps working — the
    /// conservative rules must not cost the common setup its streaming.
    func testASingleCorrectlyMappedAreaStillStreams() async {
        bridgeA.stubLights = lights(2)
        bridgeA.stubEntertainmentJSON = entertainmentJSON(2)
        bridgeA.stubConfigsJSON = configsJSON([
            configJSON(id: "only", name: "The Area", ent: ["E1", "E2"]),
        ])
        let bedroom = room("bedroom", bridge: bridgeAID, lightIDs: ["L1", "L2"])

        await orchestrator.warmEntertainmentCaches(for: bedroom)
        XCTAssertEqual(orchestrator.entertainmentAvailability(for: bedroom),
                       .available(areaName: "The Area"))
        XCTAssertEqual(orchestrator.testEntertainmentStartPlan(for: bedroom)?.channelIDs, [0, 1])
    }

    /// Identical room and config identifiers on two bridges must not bleed.
    func testCachesAndSelectionStayBridgeScoped() async {
        bridgeA.stubLights = lights(2)
        bridgeA.stubEntertainmentJSON = entertainmentJSON(2)
        bridgeA.stubConfigsJSON = configsJSON([
            configJSON(id: "shared-id", name: "Area On A", ent: ["E1", "E2"]),
        ])
        bridgeB.stubLights = lights(2)
        bridgeB.stubEntertainmentJSON = entertainmentJSON(2)
        bridgeB.stubConfigsJSON = configsJSON([
            configJSON(id: "shared-id", name: "Area On B", ent: ["E1", "E2"]),
        ])
        let onA = room("same-room-id", bridge: bridgeAID, lightIDs: ["L1", "L2"])
        let onB = room("same-room-id", bridge: bridgeBID, lightIDs: ["L1", "L2"])

        await orchestrator.warmEntertainmentCaches(for: onA)
        XCTAssertEqual(orchestrator.entertainmentAvailability(for: onA),
                       .available(areaName: "Area On A"))
        XCTAssertEqual(orchestrator.entertainmentAvailability(for: onB), .unknown,
            "warming bridge A must tell us nothing about bridge B")

        await orchestrator.warmEntertainmentCaches(for: onB)
        XCTAssertEqual(orchestrator.entertainmentAvailability(for: onB),
                       .available(areaName: "Area On B"))
        XCTAssertEqual(orchestrator.entertainmentAvailability(for: onA),
                       .available(areaName: "Area On A"))
    }

    // ── One selection per start ───────────────────────────────

    /// The config handed to `startSession` and the channel IDs that drive the
    /// render loop must come from the same area. They used to be two
    /// independent `configs.first` picks that agreed only by accident.
    func testCompositionStartsTheSelectedAreaAndNoOther() async {
        stageTwoAreaBridge(bridgeA)
        let bedroom = room("bedroom", bridge: bridgeAID, lightIDs: ["L1", "L2"])
        await orchestrator.warmEntertainmentCaches(for: bedroom)

        let plan = orchestrator.testEntertainmentStartPlan(for: bedroom)
        XCTAssertEqual(plan?.config.id, "area-bedroom")
        XCTAssertEqual(plan?.channelIDs, [0, 1])
        bridgeA.resetRecordings()

        await orchestrator.startCompositionMode(
            room: bedroom,
            paramBox: CompositionParamBox(palette: PaletteConfig(), motion: MotionConfig(),
                                          envelope: EnvelopeConfig(), reaction: ReactionConfig()),
            preferEntertainment: true
        )

        let activated = bridgeA.actions
        XCTAssertEqual(activated.map(\.configID), ["area-bedroom", "area-bedroom"],
            "only the room's OWN area may be activated")
        XCTAssertEqual(activated.map(\.action), ["start", "stop"],
            "the non-hex key fails the DTLS open, which must roll the activation back")
        XCTAssertFalse(activated.contains { $0.configID == "area-living" },
            "the other room's area must never be touched")

        await orchestrator.stopCompositionMode(roomID: bedroom.id)
    }

    /// The cold-cache path a seeded test cannot see: a Studio card can be tapped
    /// without Composer or the transport menu ever having warmed this bridge.
    func testStudioWarmsItsOwnCacheAndStartsTheRightAreaFromCold() async {
        stageTwoAreaBridge(bridgeA)
        let bedroom = room("bedroom", bridge: bridgeAID, lightIDs: ["L1", "L2"])

        // Nothing warmed anything — this is a cold launch straight into Studio.
        XCTAssertEqual(orchestrator.entertainmentAvailability(for: bedroom), .unknown)

        await orchestrator.startStudioMode(key: "strobe", room: bedroom, params: [:], colors: [:])

        let activated = bridgeA.actions
        XCTAssertEqual(activated.first?.configID, "area-bedroom",
            "the bridge listed the Living Room area first; that is not evidence of anything")
        XCTAssertFalse(activated.contains { $0.configID == "area-living" })
        XCTAssertEqual(orchestrator.selectedEntertainmentConfig(for: bedroom)?.id, "area-bedroom")

        await orchestrator.stopStudioMode()
    }

    /// An area with no usable channels must be refused BEFORE a session exists,
    /// or a live client is left parked and the configuration left started.
    func testAnUnstreamableAreaOpensNoSessionAtAll() async {
        bridgeA.stubLights = lights(2)
        bridgeA.stubEntertainmentJSON = entertainmentJSON(2)
        bridgeA.stubConfigsJSON = #"""
        {"data":[{"id":"no-channels","metadata":{"name":"Bedroom"},"channels":[]}]}
        """#
        let bedroom = room("bedroom", bridge: bridgeAID, lightIDs: ["L1", "L2"])

        await orchestrator.warmEntertainmentCaches(for: bedroom)
        XCTAssertNil(orchestrator.testEntertainmentStartPlan(for: bedroom))
        bridgeA.resetRecordings()

        await orchestrator.startCompositionMode(
            room: bedroom,
            paramBox: CompositionParamBox(palette: PaletteConfig(), motion: MotionConfig(),
                                          envelope: EnvelopeConfig(), reaction: ReactionConfig()),
            preferEntertainment: true
        )

        XCTAssertTrue(bridgeA.actions.isEmpty,
            "no action=start may be sent for a config the render loop cannot drive")
        XCTAssertFalse(orchestrator.testHasEntertainmentClient(forBridge: bridgeAID),
            "no client may be left parked in studioEntClients")
        XCTAssertNil(orchestrator.compositionOwningEntertainment(onBridge: bridgeAID),
            "no ownership may be claimed")
        XCTAssertNotEqual(orchestrator.compositionTransportByRoom[bedroom.id], .entertainment)

        await orchestrator.stopCompositionMode(roomID: bedroom.id)
    }

    /// Packet 1a's same-bridge block is untouched by this packet.
    func testARESTCompositionOnTheSameBridgeStillBlocksEntertainment() async {
        stageTwoAreaBridge(bridgeA)
        let bedroom = room("bedroom", bridge: bridgeAID, lightIDs: ["L1", "L2"])
        await orchestrator.warmEntertainmentCaches(for: bedroom)

        orchestrator.testStageRESTComposition(roomID: "living", bridgeID: bridgeAID, api: bridgeA)
        XCTAssertFalse(orchestrator.testCanAcquireEntertainment(onBridge: bridgeAID))
        XCTAssertTrue(orchestrator.testCanAcquireEntertainment(onBridge: bridgeBID),
            "packet 1a's per-bridge scoping still holds")

        bridgeA.resetRecordings()
        await orchestrator.startCompositionMode(
            room: bedroom,
            paramBox: CompositionParamBox(palette: PaletteConfig(), motion: MotionConfig(),
                                          envelope: EnvelopeConfig(), reaction: ReactionConfig()),
            preferEntertainment: true
        )
        XCTAssertTrue(bridgeA.actions.isEmpty,
            "a blocked bridge must not activate an entertainment configuration")

        await orchestrator.stopCompositionMode(roomID: bedroom.id)
    }
}
