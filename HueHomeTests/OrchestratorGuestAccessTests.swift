// OrchestratorGuestAccessTests.swift
// ChromaGlow — Family Sharing Phase 3 (the enforcement choke point)
//
// Proves the orchestrator-level guarantees the UI relies on:
//  - after loadAll, a granted bridge's rooms/zones are filtered while an
//    un-granted bridge is untouched — and the per-bridge DICTIONARIES are
//    pruned, not just the merged arrays (SSE lookups, updateRoom, and
//    removeBridge read the dictionaries directly);
//  - an SSE event for a pruned room mutates nothing;
//  - the SwiftData preload window is filtered (no flash before loadAll);
//  - demo mode is immune;
//  - scenes refilter when a grant arrives mid-session;
//  - guestFeatures / guestAccessInfo per-bridge semantics.

import XCTest
@testable import HueHome

// MARK: - Offline spy client

private final class GuestAccessSpyBridgeClient: BridgeAPIClient, @unchecked Sendable {
    private let stubRooms: [HueRoom]
    private let stubZones: [HueZone]
    private let stubLights: [HueLight]
    private let stubGroupedLights: [HueGroupedLight]

    init(bridgeID: String, rooms: [HueRoom], zones: [HueZone],
         lights: [HueLight], groupedLights: [HueGroupedLight]) {
        self.stubRooms = rooms
        self.stubZones = zones
        self.stubLights = lights
        self.stubGroupedLights = groupedLights
        super.init(bridgeID: bridgeID, bridgeName: "Bridge \(bridgeID)",
                   ip: "192.0.2.\(abs(bridgeID.hashValue % 250) + 1)", token: "test-token")
    }

    override func fetchRooms() async throws -> [HueRoom] { stubRooms }
    override func fetchZones() async throws -> [HueZone] { stubZones }
    override func fetchLights() async throws -> [HueLight] { stubLights }
    override func fetchGroupedLights() async throws -> [HueGroupedLight] { stubGroupedLights }

    override func get(path: String, ip: String, token: String) async throws -> Data {
        Data(#"{"errors":[],"data":[]}"#.utf8)   // entertainment cleanup no-op
    }
}

// MARK: - Fixtures

private enum GuestAccessFixtures {

    static func rooms(bridge suffix: String, ids: [String]) throws -> [HueRoom] {
        let items = ids.map { id in
            """
            {"id":"\(id)","type":"room",
             "metadata":{"name":"Room \(id)","archetype":"bedroom"},
             "children":[{"rid":"light-\(id)","rtype":"light"}],
             "services":[{"rid":"gl-\(id)","rtype":"grouped_light"}]}
            """
        }.joined(separator: ",")
        return try decodeEnvelope(from: #"{"errors":[],"data":[\#(items)]}"#)
    }

    static func zones(ids: [String]) throws -> [HueZone] {
        let items = ids.map { id in
            """
            {"id":"\(id)","type":"zone",
             "metadata":{"name":"Zone \(id)","archetype":"recreation"},
             "children":[{"rid":"light-\(id)","rtype":"light"}],
             "services":[{"rid":"gl-\(id)","rtype":"grouped_light"}]}
            """
        }.joined(separator: ",")
        return try decodeEnvelope(from: #"{"errors":[],"data":[\#(items)]}"#)
    }

    static func groupedLights(ids: [String]) throws -> [HueGroupedLight] {
        let items = ids.map { id in
            #"{"id":"gl-\#(id)","type":"grouped_light","on":{"on":true},"dimming":{"brightness":50}}"#
        }.joined(separator: ",")
        return try decodeEnvelope(from: #"{"errors":[],"data":[\#(items)]}"#)
    }

    private static func decodeEnvelope<T: Decodable>(from json: String) throws -> [T] {
        try JSONDecoder().decode(HueV2Response<T>.self, from: Data(json.utf8)).data
    }

    static func grant(groups: [String], features: [String] = GuestFeature.all) -> GuestGrantSnapshot {
        GuestGrantSnapshot(allowedGroupIDs: Set(groups), features: Set(features), profileName: "Alex")
    }
}

// MARK: - Tests

@MainActor
final class OrchestratorGuestAccessTests: XCTestCase {

    /// bridge-1: rooms a,b + zone z1 — GRANTED (allow room-a + zone-z1).
    /// bridge-2: rooms c,d — un-granted (owner's own bridge).
    private func makeTwoBridgeSUT() throws -> UnifiedOrchestrator {
        let orchestrator = UnifiedOrchestrator()
        let b1 = GuestAccessSpyBridgeClient(
            bridgeID: "bridge-1",
            rooms: try GuestAccessFixtures.rooms(bridge: "1", ids: ["room-a", "room-b"]),
            zones: try GuestAccessFixtures.zones(ids: ["zone-z1", "zone-z2"]),
            lights: [],
            groupedLights: try GuestAccessFixtures.groupedLights(
                ids: ["room-a", "room-b", "zone-z1", "zone-z2"])
        )
        let b2 = GuestAccessSpyBridgeClient(
            bridgeID: "bridge-2",
            rooms: try GuestAccessFixtures.rooms(bridge: "2", ids: ["room-c", "room-d"]),
            zones: [],
            lights: [],
            groupedLights: try GuestAccessFixtures.groupedLights(ids: ["room-c", "room-d"])
        )
        orchestrator.injectForTesting(clients: ["bridge-1": b1, "bridge-2": b2])
        return orchestrator
    }

    // ── loadAll filtering ─────────────────────────────────

    func testLoadAllFiltersGrantedBridgeAndKeepsOwnedBridge() async throws {
        let orchestrator = try makeTwoBridgeSUT()
        orchestrator.testSetGuestGrants(
            ["bridge-1": GuestAccessFixtures.grant(groups: ["room-a", "zone-z1"])]
        )

        await orchestrator.loadAll()

        XCTAssertEqual(Set(orchestrator.allRooms.map(\.id)), ["room-a", "room-c", "room-d"],
                       "granted bridge filtered to its allowlist; owned bridge untouched")
        XCTAssertEqual(orchestrator.allZones.map(\.id), ["zone-z1"])

        // The DICTIONARY must be pruned, not just the merged arrays — SSE
        // lookups, updateRoom, and removeBridge's doomed list read it.
        XCTAssertEqual(orchestrator.testRoomsByBridge()["bridge-1"]?.map(\.id), ["room-a"])
        XCTAssertEqual(orchestrator.testZonesByBridge()["bridge-1"]?.map(\.id), ["zone-z1"])
        XCTAssertEqual(orchestrator.testRoomsByBridge()["bridge-2"]?.count, 2)
    }

    func testEmptyAllowlistFailsClosedToZeroRooms() async throws {
        let orchestrator = try makeTwoBridgeSUT()
        orchestrator.testSetGuestGrants(["bridge-1": GuestAccessFixtures.grant(groups: [])])

        await orchestrator.loadAll()

        XCTAssertEqual(Set(orchestrator.allRooms.map(\.id)), ["room-c", "room-d"])
        XCTAssertEqual(orchestrator.testRoomsByBridge()["bridge-1"]?.count, 0)
        XCTAssertTrue(orchestrator.allZones.isEmpty)
    }

    // ── SSE cannot resurrect a pruned room ────────────────

    func testSSEEventForPrunedRoomMutatesNothing() async throws {
        let orchestrator = try makeTwoBridgeSUT()
        orchestrator.testSetGuestGrants(
            ["bridge-1": GuestAccessFixtures.grant(groups: ["room-a"])]
        )
        await orchestrator.loadAll()

        // gl-room-b belongs to the pruned room-b.
        let hidden = try decodeSSEEvents("""
        [{"creationtime":"2024-01-01T00:00:00Z","data":[{
          "id":"gl-room-b","id_v1":null,"type":"grouped_light",
          "on":{"on":false},"dimming":{"brightness":1},"owner":null
        }],"id":"evt-h","type":"update"}]
        """)
        let hiddenResult = orchestrator.testApplySSEEventsAndRebuild(hidden, bridgeID: "bridge-1")
        XCTAssertFalse(hiddenResult.rooms, "an event for a pruned room must find no target")
        XCTAssertFalse(orchestrator.allRooms.map(\.id).contains("room-b"))

        // …while the allowed room still updates live.
        let allowed = try decodeSSEEvents("""
        [{"creationtime":"2024-01-01T00:00:00Z","data":[{
          "id":"gl-room-a","id_v1":null,"type":"grouped_light",
          "on":{"on":false},"dimming":{"brightness":1},"owner":null
        }],"id":"evt-a","type":"update"}]
        """)
        let allowedResult = orchestrator.testApplySSEEventsAndRebuild(allowed, bridgeID: "bridge-1")
        XCTAssertTrue(allowedResult.rooms)
        XCTAssertFalse(orchestrator.allRooms.first { $0.id == "room-a" }!.isOn)
    }

    // ── Preload window ────────────────────────────────────

    func testPreloadCachedFiltersAgainstGrants() {
        let orchestrator = UnifiedOrchestrator()
        orchestrator.testSetGuestGrants(
            ["bridge-1": GuestAccessFixtures.grant(groups: ["room-a"])]
        )

        let allowed = HueLocalRoom(roomID: "room-a", bridgeID: "bridge-1")
        allowed.cachedName = "Allowed"
        let forbidden = HueLocalRoom(roomID: "room-b", bridgeID: "bridge-1")
        forbidden.cachedName = "Forbidden"

        orchestrator.preloadCached(from: [allowed, forbidden])

        XCTAssertEqual(orchestrator.allRooms.map(\.id), ["room-a"],
                       "the cache preload must never flash forbidden rooms")
        XCTAssertEqual(orchestrator.testRoomsByBridge()["bridge-1"]?.map(\.id), ["room-a"])
    }

    // ── Demo immunity ─────────────────────────────────────

    func testDemoModeIsImmuneToGrants() {
        let orchestrator = UnifiedOrchestrator()
        orchestrator.testSetGuestGrants(
            ["some-real-bridge": GuestAccessFixtures.grant(groups: [])]
        )

        orchestrator.enterDemoMode()

        XCTAssertFalse(orchestrator.allRooms.isEmpty, "demo rooms must all be present")
        XCTAssertFalse(orchestrator.guestAccessInfo.hasAnyGrant)
        XCTAssertEqual(orchestrator.guestFeatures(for: "some-real-bridge"), .unrestricted)
    }

    // ── Scenes ────────────────────────────────────────────

    func testGrantArrivalRefiltersScenes() {
        let orchestrator = UnifiedOrchestrator()
        orchestrator.globalScenes = [
            GlobalSceneItem(id: "b1:s1", bridgeSceneID: "s1", name: "Allowed",
                            roomID: "room-a", bridgeID: "bridge-1",
                            isActive: false, isDynamic: false, speed: 0.5),
            GlobalSceneItem(id: "b1:s2", bridgeSceneID: "s2", name: "HiddenRoom",
                            roomID: "room-b", bridgeID: "bridge-1",
                            isActive: false, isDynamic: false, speed: 0.5),
            GlobalSceneItem(id: "b2:s3", bridgeSceneID: "s3", name: "OwnedBridge",
                            roomID: "room-c", bridgeID: "bridge-2",
                            isActive: false, isDynamic: false, speed: 0.5),
        ]

        orchestrator.testSetGuestGrants(
            ["bridge-1": GuestAccessFixtures.grant(groups: ["room-a"])]
        )

        XCTAssertEqual(orchestrator.globalScenes.map(\.bridgeSceneID), ["s1", "s3"])
    }

    func testScenesFeatureMissingDropsGrantedBridgeScenes() {
        let orchestrator = UnifiedOrchestrator()
        orchestrator.globalScenes = [
            GlobalSceneItem(id: "b1:s1", bridgeSceneID: "s1", name: "S",
                            roomID: "room-a", bridgeID: "bridge-1",
                            isActive: false, isDynamic: false, speed: 0.5),
        ]
        orchestrator.testSetGuestGrants(
            ["bridge-1": GuestAccessFixtures.grant(groups: ["room-a"],
                                                   features: [GuestFeature.onOff])]
        )
        XCTAssertTrue(orchestrator.globalScenes.isEmpty)
    }

    // ── Feature + shell info semantics ────────────────────

    func testGuestFeaturesPerBridge() {
        let orchestrator = UnifiedOrchestrator()
        orchestrator.testSetGuestGrants(
            ["bridge-1": GuestAccessFixtures.grant(groups: ["room-a"],
                                                   features: [GuestFeature.onOff])]
        )

        let granted = orchestrator.guestFeatures(for: "bridge-1")
        XCTAssertTrue(granted.canPower)
        XCTAssertFalse(granted.canAdjust)
        XCTAssertFalse(granted.canRecallScenes)
        XCTAssertEqual(orchestrator.guestFeatures(for: "bridge-2"), .unrestricted)
        XCTAssertEqual(orchestrator.guestFeatures(for: nil), .unrestricted)
    }

    func testGuestAccessInfoMixedRoleVersusGuestOnly() throws {
        let orchestrator = try makeTwoBridgeSUT()

        orchestrator.testSetGuestGrants(
            ["bridge-1": GuestAccessFixtures.grant(groups: ["room-a"])]
        )
        XCTAssertTrue(orchestrator.guestAccessInfo.hasAnyGrant)
        XCTAssertFalse(orchestrator.guestAccessInfo.isGuestOnly,
                       "owning bridge-2 keeps the full shell")

        orchestrator.testSetGuestGrants([
            "bridge-1": GuestAccessFixtures.grant(groups: ["room-a"]),
            "bridge-2": GuestAccessFixtures.grant(groups: ["room-c"]),
        ])
        XCTAssertTrue(orchestrator.guestAccessInfo.isGuestOnly)
        XCTAssertEqual(orchestrator.guestAccessInfo.profileNames, ["Alex"])
    }

    // ── Helpers ───────────────────────────────────────────

    private func decodeSSEEvents(_ json: String) throws -> [SSEEvent] {
        try UnifiedOrchestrator.sseDecoder.decode([SSEEvent].self, from: Data(json.utf8))
    }
}
