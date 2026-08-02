// MultiBridgeRoutingTests.swift
// HueHome Pro — Unit Tests
//
// Regression guards for audit findings M-07 / H-05 / M-18 (the wrong-bridge
// class): room-targeted writes must resolve their client from the TARGET's
// bridge — never from `primaryAPIClient` (= clients.values.first, an
// arbitrary dictionary order).
//
//  - hueClient(forBridgeIP:) resolves the client whose credentials carry the
//    requested LAN host (used by composition teardown, whose manifest records
//    only the bridge IP).
//  - stopCompositionMode tears down a bridge-stored animation against the
//    manifest's own bridge (M-07) and never issues v1 deletes on the other.
//  - EffectsViewModel.activate() targets the selected room's bridge (H-05):
//    the grouped_light PUT lands on the room's bridge and the other bridge
//    sees zero traffic.
//
// Audit: docs/audit/hardening-audit-2026-07-01.md §6 "Throughput / multi-bridge".

import XCTest
@testable import HueHome

// MARK: - Spies

/// v1 spy recording resource deletes without touching the network.
private final class RoutingSpyV1Client: HueV1Client, @unchecked Sendable {
    private let lock = NSLock()
    private var _deletedResources: [String] = []
    var deletedResources: [String] {
        lock.lock(); defer { lock.unlock() }
        return _deletedResources
    }
    private func record(_ entry: String) {
        lock.lock(); defer { lock.unlock() }
        _deletedResources.append(entry)
    }

    override func deleteSchedule(id: String) async throws { record("schedule:\(id)") }
    override func deleteRule(id: String) async throws { record("rule:\(id)") }
    override func deleteSensor(id: String) async throws { record("sensor:\(id)") }
    override func deleteScene(id: String) async throws { record("scene:\(id)") }
    override func deleteResourcelink(id: String) async throws { record("resourcelink:\(id)") }
}

/// v2 spy recording grouped_light effect PUTs and vending a paired v1 spy.
private final class RoutingSpyClient: BridgeAPIClient, @unchecked Sendable {
    let v1Spy: RoutingSpyV1Client

    private let lock = NSLock()
    private var _groupedEffectIDs: [String] = []
    var groupedEffectIDs: [String] {
        lock.lock(); defer { lock.unlock() }
        return _groupedEffectIDs
    }

    init(bridgeID: String, bridgeName: String, ip: String) {
        self.v1Spy = RoutingSpyV1Client(ip: ip, token: "spy-token")
        super.init(bridgeID: bridgeID, bridgeName: bridgeName, ip: ip, token: "spy-token")
    }

    override func makeV1Client() throws -> HueV1Client { v1Spy }

    override func setGroupedLightEffect(
        id: String, on: Bool?, brightness: Double?,
        xy: (Double, Double)?, mirek: Int?, duration: Int
    ) async throws {
        lock.lock(); defer { lock.unlock() }
        _groupedEffectIDs.append(id)
    }

    override func fetchLightIDsForGroup(groupedLightID: String) async throws -> [String] { [] }
    override func setLightColor(id: String, x: Double, y: Double) async throws {}

    // R4 Effects-port heirs: Studio's bridge-native path.
    private var _groupedStateIDs: [String] = []
    var groupedStateIDs: [String] {
        lock.lock(); defer { lock.unlock() }
        return _groupedStateIDs
    }
    private var _v1EffectPuts: [String] = []   // "lightID:effect"
    var v1EffectPuts: [String] {
        lock.lock(); defer { lock.unlock() }
        return _v1EffectPuts
    }

    override func setGroupedLightState(id: String, on: Bool, brightness: Double) async throws {
        lock.lock(); defer { lock.unlock() }
        _groupedStateIDs.append(id)
    }

    override func setLightNativeEffect(id: String, effect: String) async throws {
        lock.lock(); defer { lock.unlock() }
        _v1EffectPuts.append("\(id):\(effect)")
    }

    override func fetchLights() async throws -> [HueLight] { [] }
}

// MARK: - Tests

@MainActor
final class MultiBridgeRoutingTests: XCTestCase {

    private var bridgeA: RoutingSpyClient!
    private var bridgeB: RoutingSpyClient!
    private var orchestrator: UnifiedOrchestrator!

    override func setUp() async throws {
        try await super.setUp()
        bridgeA = RoutingSpyClient(bridgeID: "bridge-a", bridgeName: "Bridge A", ip: "192.0.2.1")
        bridgeB = RoutingSpyClient(bridgeID: "bridge-b", bridgeName: "Bridge B", ip: "192.0.2.2")
        orchestrator = UnifiedOrchestrator()
        orchestrator.injectForTesting(clients: ["bridge-a": bridgeA, "bridge-b": bridgeB])
    }

    // ──────────────────────────────────────────────
    // MARK: - Client resolution
    // ──────────────────────────────────────────────

    func testHueClientForBridgeIPResolvesTheMatchingClient() {
        XCTAssertTrue(orchestrator.hueClient(forBridgeIP: "192.0.2.2") === bridgeB)
        XCTAssertTrue(orchestrator.hueClient(forBridgeIP: "192.0.2.1") === bridgeA)
        XCTAssertNil(orchestrator.hueClient(forBridgeIP: "192.0.2.99"))
    }

    func testRebuildPrunesRoomsOfForgottenBridges() async {
        // Simulate the forget-all → re-pair flow: the SwiftData preload seeds
        // rooms under the OLD (deleted) bridge id, then clients exist only
        // under the NEW ids. The merge must drop the stale snapshot — it used
        // to surface dead room cards whose controls silently no-oped.
        let staleRoom = HueLocalRoom(roomID: "room-x", bridgeID: "stale-old-bridge")
        staleRoom.cachedName = "Stale Room"
        staleRoom.cachedGroupedLightID = "gl-x"
        staleRoom.lastIsOn = true
        staleRoom.lastBrightness = 50
        orchestrator.preloadCached(from: [staleRoom])
        XCTAssertEqual(orchestrator.allRooms.count, 1)

        // Any rebuild with live clients prunes the dead bridge id.
        await orchestrator.removeBridge(id: "unrelated-id")

        XCTAssertTrue(orchestrator.allRooms.isEmpty,
            "rooms keyed by a forgotten bridge id must not survive a rebuild")
    }

    func testHueClientForNilBridgeID() {
        // Multi-bridge: nil is unresolvable — guessing would reintroduce the
        // wrong-bridge class.
        XCTAssertNil(orchestrator.hueClient(for: nil))
        // Single-bridge: legacy rooms (bridgeID nil, cached pre-multi-bridge)
        // can only belong to the sole registered bridge.
        orchestrator.injectForTesting(clients: ["bridge-a": bridgeA])
        XCTAssertTrue(orchestrator.hueClient(for: nil) === bridgeA)
    }

    // ──────────────────────────────────────────────
    // MARK: - M-07: composition teardown targets the manifest's bridge
    // ──────────────────────────────────────────────

    func testStopCompositionModeDeletesOnTheManifestsBridgeOnly() async throws {
        let presetID = UUID()
        let roomID   = "routing-test-room"
        let manifest = BridgeAnimationManifest(
            id: UUID(), presetID: presetID, presetName: "RoutingTest",
            roomID: roomID, roomName: "Routing Room",
            bridgeIP: "192.0.2.2",          // lives on bridge B — NOT the first client
            sensorID: "11", ruleIDs: ["22", "23"], scheduleID: "33",
            sceneIDs: [], resourcelinkID: nil,
            stepCount: 2, intervalSeconds: 3, cycleDurationSeconds: 6,
            createdAt: Date()
        )
        BridgeAnimationStore.shared.save(manifest)
        defer { BridgeAnimationStore.shared.remove(presetID: presetID, roomID: roomID) }

        await orchestrator.stopCompositionMode(roomID: roomID)

        XCTAssertTrue(bridgeA.v1Spy.deletedResources.isEmpty,
                      "teardown must not touch a bridge the animation does not live on (M-07)")
        let deletedOnB = Set(bridgeB.v1Spy.deletedResources)
        XCTAssertTrue(deletedOnB.contains("schedule:33"), "schedule delete must land on the manifest's bridge")
        XCTAssertTrue(deletedOnB.contains("rule:22") && deletedOnB.contains("rule:23"))
        XCTAssertTrue(deletedOnB.contains("sensor:11"))
        XCTAssertFalse(BridgeAnimationStore.shared.allManifests()
            .contains { $0.presetID == presetID && $0.roomID == roomID },
            "manifest must be removed after correct-bridge cleanup")
    }

    // ──────────────────────────────────────────────
    // MARK: - Per-room composition transport truth
    // ──────────────────────────────────────────────

    func testCompositionTransportIsPerRoomAndStopClearsOnlyThatRoom() async throws {
        orchestrator.compositionTransportByRoom["room-a"] = .bridgeStored
        orchestrator.compositionTransportByRoom["room-b"] = .entertainment

        await orchestrator.stopCompositionMode(roomID: "room-a")

        XCTAssertNil(orchestrator.compositionTransportByRoom["room-a"],
                     "stop must clear the stopped room's transport")
        XCTAssertEqual(orchestrator.compositionTransportByRoom["room-b"], .entertainment,
                       "one room's stop must not mislabel another room's transport")
    }

    // ──────────────────────────────────────────────
    // MARK: - H-05 heir: Studio Deck 0 targets the selected room's bridge
    // ──────────────────────────────────────────────

    func testStudioApplyTargetsTheSelectedRoomsBridge() async throws {
        let roomOnB = RoomDisplayItem(
            kind: .zone,
            id: "room-b", name: "Bedroom B", archetype: nil,
            isOn: true, brightness: 50,
            groupedLightID: "gl-room-b", lightCount: 2,
            bridgeID: "bridge-b",
            childResourceRefs: [(rid: "LB1", rtype: "light"), (rid: "LB2", rtype: "light")]
        )

        let vm = StudioViewModel()
        vm.configure(orchestrator: orchestrator)
        let candle = try XCTUnwrap(vm.effectCards.first { $0.id == "candle" })

        await vm.apply(candle, roomOverride: roomOnB, preferEntertainmentOverride: nil)

        XCTAssertEqual(bridgeB.groupedStateIDs, ["gl-room-b"],
                       "the group-on PUT must land on the room's own bridge (H-05)")
        XCTAssertEqual(Set(bridgeB.v1EffectPuts), ["LB1:candle", "LB2:candle"],
                       "per-light effect PUTs must land on the room's own bridge")
        XCTAssertTrue(bridgeA.groupedStateIDs.isEmpty && bridgeA.v1EffectPuts.isEmpty,
                      "the other bridge must see zero traffic (H-05)")
    }

    // ──────────────────────────────────────────────
    // MARK: - M-17 heir: automation effects fan out per room, per bridge
    // ──────────────────────────────────────────────

    func testAutomationEffectFansOutToEveryRoomsOwnBridge() async throws {
        // The Effects surface's applyToAllRooms died with that surface (R4);
        // applyAutomationEffect is the surviving whole-home fan-out and must
        // keep the M-17 + H-05 routing guarantees.
        let roomOnA = HueLocalRoom(roomID: "room-a", bridgeID: "bridge-a")
        roomOnA.cachedName = "Living A"
        roomOnA.cachedGroupedLightID = "gl-room-a"
        let roomOnB = HueLocalRoom(roomID: "room-b", bridgeID: "bridge-b")
        roomOnB.cachedName = "Bedroom B"
        roomOnB.cachedGroupedLightID = "gl-room-b"
        orchestrator.preloadCached(from: [roomOnA, roomOnB])

        await orchestrator.applyAutomationEffect(id: "movie")

        XCTAssertEqual(bridgeA.groupedEffectIDs, ["gl-room-a"],
                       "the fan-out must reach the room on bridge A (M-17)")
        XCTAssertEqual(bridgeB.groupedEffectIDs, ["gl-room-b"],
                       "the fan-out must reach the room on bridge B on its own bridge (M-17 + H-05)")
    }

    func testAutomationAppDrivenEffectAppliesStaticFallbackNotALoop() async throws {
        // App-driven effects need a foreground engine loop — impossible from
        // an automation. The fan-out must degrade to exactly one static
        // grouped fallback per room and never start per-light traffic.
        let roomOnA = HueLocalRoom(roomID: "room-a", bridgeID: "bridge-a")
        roomOnA.cachedName = "Living A"
        roomOnA.cachedGroupedLightID = "gl-room-a"
        orchestrator.preloadCached(from: [roomOnA])

        await orchestrator.applyAutomationEffect(id: "strobe")

        XCTAssertEqual(bridgeA.groupedEffectIDs, ["gl-room-a"],
                       "app-driven automation = one static grouped fallback per room")
        XCTAssertTrue(bridgeA.v1EffectPuts.isEmpty,
                      "no per-light writes — no engine loop artifacts")
    }

    // ──────────────────────────────────────────────
    // MARK: - Composer 2 packet 1a: the Entertainment gate is per bridge
    // ──────────────────────────────────────────────
    //
    // The gate used to read `compositionEntRoomByBridge[bridgeID] == nil &&
    // compositionRuntimes.isEmpty`. The second conjunct was global: one REST
    // composition anywhere demoted every later Entertainment start on EVERY
    // bridge to REST, silently and for as long as it ran. Bridge A's state may
    // not decide bridge B's transport.
    //
    // The same-bridge REST block is kept on purpose, not overlooked: a REST
    // composition on this bridge may be writing to lights inside the area we
    // would stream into, and resolving that precisely needs area membership
    // (packet 1b). Refusing beats guessing.

    func testRESTCompositionOnOneBridgeDoesNotBlockEntertainmentOnAnother() {
        orchestrator.testStageRESTComposition(
            roomID: "room-a", bridgeID: "bridge-a", api: bridgeA
        )

        XCTAssertTrue(orchestrator.testCanAcquireEntertainment(onBridge: "bridge-b"),
                      "a REST composition on bridge A must not demote bridge B (the global-lockout defect)")
    }

    func testRESTCompositionBlocksEntertainmentOnItsOwnBridge() {
        orchestrator.testStageRESTComposition(
            roomID: "room-a", bridgeID: "bridge-a", api: bridgeA
        )

        XCTAssertFalse(orchestrator.testCanAcquireEntertainment(onBridge: "bridge-a"),
                       "same-bridge REST + DTLS could fight over shared lights — refuse until 1b can prove they don't")
    }

    func testExistingEntertainmentOwnerBlocksASecondAcquisitionOnThatBridge() {
        orchestrator.testStageEntertainmentOwner(roomID: "room-b1", bridgeID: "bridge-b")

        XCTAssertFalse(orchestrator.testCanAcquireEntertainment(onBridge: "bridge-b"),
                       "one Entertainment owner per bridge — same-bridge exclusivity must not weaken")
        XCTAssertTrue(orchestrator.testCanAcquireEntertainment(onBridge: "bridge-a"),
                      "…and that exclusivity is still scoped to the owned bridge")
    }

    func testAnUnusedBridgeCanAcquireEntertainment() {
        XCTAssertTrue(orchestrator.testCanAcquireEntertainment(onBridge: "bridge-a"),
                      "an idle bridge must be acquirable — the gate must not fail closed")
    }

    func testStoppingOneBridgeLeavesTheOthersOwnershipIntact() async {
        orchestrator.testStageRESTComposition(
            roomID: "room-a", bridgeID: "bridge-a", api: bridgeA
        )
        orchestrator.testStageEntertainmentOwner(roomID: "room-b1", bridgeID: "bridge-b")

        await orchestrator.stopCompositionMode(roomID: "room-a")

        XCTAssertEqual(orchestrator.compositionOwningEntertainment(onBridge: "bridge-b"), "room-b1",
                       "bridge A's teardown must not clear bridge B's Entertainment ownership")
        XCTAssertNil(orchestrator.testCompositionRuntimeBridges()["room-a"],
                     "the stopped room's own runtime must be gone")
        XCTAssertTrue(orchestrator.testCanAcquireEntertainment(onBridge: "bridge-a"),
                      "bridge A is free again once its REST composition stops")
        XCTAssertFalse(orchestrator.testCanAcquireEntertainment(onBridge: "bridge-b"),
                       "bridge B is still owned")
    }

    func testRuntimesRecordTheirOwnBridgeNotTheFirstClient() {
        orchestrator.testStageRESTComposition(
            roomID: "room-a", bridgeID: "bridge-a", api: bridgeA
        )
        orchestrator.testStageRESTComposition(
            roomID: "room-b", bridgeID: "bridge-b", api: bridgeB
        )

        XCTAssertEqual(orchestrator.testCompositionRuntimeBridges(),
                       ["room-a": "bridge-a", "room-b": "bridge-b"],
                       "each runtime must carry its own bridge — the gate reads this, not dictionary order")
        XCTAssertFalse(orchestrator.testCanAcquireEntertainment(onBridge: "bridge-a"))
        XCTAssertFalse(orchestrator.testCanAcquireEntertainment(onBridge: "bridge-b"))
    }
}
