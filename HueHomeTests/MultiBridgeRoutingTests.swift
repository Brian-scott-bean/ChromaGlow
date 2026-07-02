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
    // MARK: - H-05: Effects tab targets the selected room's bridge
    // ──────────────────────────────────────────────

    func testEffectsActivateTargetsTheSelectedRoomsBridge() async throws {
        let roomOnB = RoomDisplayItem(
            id: "room-b", name: "Bedroom B", archetype: nil,
            isOn: true, brightness: 50,
            groupedLightID: "gl-room-b", lightCount: 2,
            bridgeID: "bridge-b", childResourceRefs: []
        )
        let movie = try XCTUnwrap(
            EffectLibrary.all.first { $0.id == "movie" },
            "catalog 'movie' effect (oneShot) expected"
        )

        let vm = EffectsViewModel()
        vm.configure(orchestrator: orchestrator)
        vm.selectedRoom   = roomOnB
        vm.selectedEffect = movie

        await vm.activate()

        XCTAssertEqual(bridgeB.groupedEffectIDs, ["gl-room-b"],
                       "the effect PUT must land on the room's own bridge (H-05)")
        XCTAssertTrue(bridgeA.groupedEffectIDs.isEmpty,
                      "the other bridge must see zero effect traffic (H-05)")
    }
}
