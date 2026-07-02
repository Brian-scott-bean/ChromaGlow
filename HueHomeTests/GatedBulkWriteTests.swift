// GatedBulkWriteTests.swift
// HueHome Pro — Unit Tests
//
// Regression guards for audit findings M-08 / M-14 / M-15 (unbounded bulk +
// effect writes with `try?`-swallowed failures):
//  - BridgeCommandGate paces command starts (~10 cmd/sec), retries once, and
//    reports persistent failures instead of hiding them.
//  - turnAllOff / applyAutomationPreset attempt EVERY room through the gate,
//    retry failed rooms, and surface partial failures via lastBulkFailure —
//    no silent partial application.
//  - EffectLoops.setAll collapses a same-color frame into a single
//    grouped_light PUT when the room's groupedLightID is available (M-14).
//
// Audit: docs/audit/hardening-audit-2026-07-01.md §6 "Throughput / multi-bridge".

import XCTest
@testable import HueHome

// MARK: - Spy client

private final class BulkSpyClient: BridgeAPIClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _attemptsByID: [String: Int] = [:]
    private var _groupedEffectCount = 0
    private var _perLightEffectCount = 0

    /// grouped_light ids that fail on EVERY attempt.
    var persistentlyFailingIDs: Set<String> = []

    var attemptsByID: [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return _attemptsByID
    }
    var groupedEffectCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _groupedEffectCount
    }
    var perLightEffectCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _perLightEffectCount
    }

    private func recordAttempt(id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        _attemptsByID[id, default: 0] += 1
        return !persistentlyFailingIDs.contains(id)
    }

    override func setGroupedLight(id: String, on: Bool) async throws {
        guard recordAttempt(id: id) else { throw HueAPIError.httpError(429) }
    }

    override func setGroupedLightEffect(
        id: String, on: Bool?, brightness: Double?,
        xy: (Double, Double)?, mirek: Int?, duration: Int
    ) async throws {
        lock.lock(); _groupedEffectCount += 1; lock.unlock()
        guard recordAttempt(id: id) else { throw HueAPIError.httpError(429) }
    }

    override func setLightEffect(
        id: String, on: Bool?, brightness: Double?,
        xy: (Double, Double)?, mirek: Int?, duration: Int
    ) async throws {
        lock.lock(); _perLightEffectCount += 1; lock.unlock()
        _ = recordAttempt(id: id)
    }
}

// MARK: - Helpers

@MainActor
private func makeBulkSUT(roomCount: Int) -> (orchestrator: UnifiedOrchestrator, client: BulkSpyClient) {
    let client = BulkSpyClient(bridgeID: "bridge-1", bridgeName: "Test Bridge",
                               ip: "192.0.2.1", token: "test-token")
    let cachedRooms = (1...roomCount).map { i -> HueLocalRoom in
        let room = HueLocalRoom(roomID: "room-\(i)", bridgeID: "bridge-1")
        room.cachedName = "Room \(i)"
        room.cachedGroupedLightID = "gl-\(i)"
        room.lastIsOn = true
        room.lastBrightness = 80
        return room
    }
    let orchestrator = UnifiedOrchestrator()
    orchestrator.preloadCached(from: cachedRooms)
    orchestrator.injectForTesting(clients: ["bridge-1": client])
    return (orchestrator, client)
}

// MARK: - Tests

@MainActor
final class GatedBulkWriteTests: XCTestCase {

    /// applyAutomationPreset triggers the orchestrator's debounced (500ms)
    /// widget snapshot write. Drain it before the suite ends so the delayed
    /// write cannot land in the middle of another suite's App Group
    /// assertions (KeychainSharingTests).
    override func tearDown() async throws {
        try await Task.sleep(for: .milliseconds(650))
        try await super.tearDown()
    }

    // ──────────────────────────────────────────────
    // MARK: - BridgeCommandGate semantics
    // ──────────────────────────────────────────────

    func testGateReturnsNilOnSuccessAndErrorAfterRetry() async {
        let gate = BridgeCommandGate()
        let successError = await gate.send { }
        XCTAssertNil(successError)

        let counter = ManagedAtomicCounter()
        let failure = await gate.send {
            counter.increment()
            throw HueAPIError.httpError(429)
        }
        XCTAssertNotNil(failure, "persistent failure must be reported, not swallowed")
        XCTAssertEqual(counter.value, 2, "the gate retries exactly once before reporting")
    }

    func testGatePacesConsecutiveCommands() async {
        let gate = BridgeCommandGate()
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<3 {
            await gate.send { }
        }
        let elapsed = start.duration(to: clock.now)
        // 3 commands = at least 2 full pacing intervals between starts.
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(180),
            "commands must be spaced to the ~10 cmd/sec bridge budget")
    }

    // ──────────────────────────────────────────────
    // MARK: - M-08: All Off reaches every room, failures surface
    // ──────────────────────────────────────────────

    func testTurnAllOffAttemptsEveryRoomRetriesAndSurfacesFailures() async throws {
        let (orchestrator, client) = makeBulkSUT(roomCount: 3)
        client.persistentlyFailingIDs = ["gl-2"]

        await orchestrator.turnAllOff()

        let attempts = client.attemptsByID
        XCTAssertEqual(attempts["gl-1"], 1)
        XCTAssertEqual(attempts["gl-3"], 1)
        XCTAssertEqual(attempts["gl-2"], 2, "a failed room must be retried once")

        let failure = try XCTUnwrap(orchestrator.lastBulkFailure,
            "partial application must surface — never silent (M-08)")
        XCTAssertEqual(failure.operation, "All Off")
        XCTAssertEqual(failure.roomNames, ["Room 2"])
    }

    func testTurnAllOffFullSuccessSurfacesNothing() async {
        let (orchestrator, client) = makeBulkSUT(roomCount: 3)
        await orchestrator.turnAllOff()
        XCTAssertNil(orchestrator.lastBulkFailure)
        XCTAssertEqual(client.attemptsByID.count, 3)
    }

    // ──────────────────────────────────────────────
    // MARK: - M-08: automation preset routes through the gate too
    // ──────────────────────────────────────────────

    func testAutomationPresetSurfacesFailedRooms() async throws {
        let (orchestrator, client) = makeBulkSUT(roomCount: 2)
        client.persistentlyFailingIDs = ["gl-1"]

        await orchestrator.applyAutomationPreset(id: "relax")

        XCTAssertEqual(client.attemptsByID["gl-1"], 2, "failed room retried once")
        XCTAssertEqual(client.attemptsByID["gl-2"], 1)
        let failure = try XCTUnwrap(orchestrator.lastBulkFailure)
        XCTAssertEqual(failure.operation, "Automation preset")
        XCTAssertEqual(failure.roomNames, ["Room 1"])
    }

    // ──────────────────────────────────────────────
    // MARK: - M-14: same-color frames collapse to one grouped_light PUT
    // ──────────────────────────────────────────────

    func testSetAllCollapsesToSingleGroupedLightPUT() async {
        let client = BulkSpyClient(bridgeID: "bridge-1", bridgeName: "Test Bridge",
                                   ip: "192.0.2.1", token: "test-token")
        let lights = (1...10).map { i in
            LightDisplayItem(id: "light-\(i)", name: "L\(i)", archetype: nil,
                             isOn: true, brightness: 100,
                             colorX: 0.3, colorY: 0.3,
                             colorTempMirek: 300, mirekMin: 153, mirekMax: 500)
        }

        let ok = await EffectLoops.setAll(
            lights: lights, api: client,
            groupedLightID: "gl-room", gate: BridgeCommandGate(),
            on: true, brightness: 100, xy: (0.3, 0.3), duration: 0)

        XCTAssertTrue(ok)
        XCTAssertEqual(client.groupedEffectCount, 1,
            "a same-color frame for 10 lights must be ONE grouped_light PUT (M-14)")
        XCTAssertEqual(client.perLightEffectCount, 0,
            "no per-light PUTs when the grouped collapse is available")
    }
}

// MARK: - Tiny atomic counter (test-local)

private final class ManagedAtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func increment() {
        lock.lock(); defer { lock.unlock() }
        _value += 1
    }
}
