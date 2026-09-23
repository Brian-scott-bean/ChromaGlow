import XCTest
@testable import HueHome

// MARK: - Test errors

private enum OrchestratorOptimisticUpdateTestError: Error, LocalizedError {
    case forcedGroupedLightFailure
    case timeout(description: String)

    var errorDescription: String? {
        switch self {
        case .forcedGroupedLightFailure:
            return "Forced grouped-light failure for optimistic-update test"
        case .timeout(let description):
            return "Timed out waiting for \(description)"
        }
    }
}

// MARK: - Actor-backed recorder

private actor OrchestratorOptimisticUpdateRecorder {
    struct Call: Equatable, Sendable {
        let id: String
        let on: Bool
    }

    private var calls: [Call] = []

    func record(_ call: Call) {
        calls.append(call)
    }

    func recordedCalls() -> [Call] {
        calls
    }

    func waitForCallCount(
        _ count: Int,
        timeout: Duration = .seconds(2)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while calls.count < count {
            if clock.now >= deadline {
                throw OrchestratorOptimisticUpdateTestError.timeout(
                    description: "grouped-light call count \(count)"
                )
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

// MARK: - Actor-backed gate

private actor OrchestratorGroupedLightGate {
    private enum Resolution: Sendable {
        case success
        case failure
    }

    private var resolution: Resolution?
    private var waiterContinuation: CheckedContinuation<Resolution, Never>?
    private var awaitingRelease = false

    func suspendUntilReleased() async throws {
        awaitingRelease = true
        if let pending = consumeResolution() {
            awaitingRelease = false
            try resolve(pending)
            return
        }

        let result = await withCheckedContinuation { (cont: CheckedContinuation<Resolution, Never>) in
            if let pending = consumeResolution() {
                cont.resume(returning: pending)
            } else {
                waiterContinuation = cont
            }
        }
        waiterContinuation = nil
        awaitingRelease = false
        try resolve(result)
    }

    func waitUntilSuspended(timeout: Duration = .seconds(2)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !awaitingRelease {
            if clock.now >= deadline {
                throw OrchestratorOptimisticUpdateTestError.timeout(
                    description: "grouped-light gate suspension"
                )
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func releaseSuccess() {
        applyRelease(.success)
    }

    func releaseFailure() {
        applyRelease(.failure)
    }

    private func consumeResolution() -> Resolution? {
        guard let pending = resolution else { return nil }
        resolution = nil
        return pending
    }

    private func applyRelease(_ value: Resolution) {
        if let cont = waiterContinuation {
            waiterContinuation = nil
            awaitingRelease = false
            cont.resume(returning: value)
        } else if resolution == nil {
            resolution = value
        }
    }

    private func resolve(_ value: Resolution) throws {
        switch value {
        case .success:
            return
        case .failure:
            throw OrchestratorOptimisticUpdateTestError.forcedGroupedLightFailure
        }
    }
}

// MARK: - Typed offline spy

private final class OrchestratorOptimisticUpdateSpyBridgeClient:
    BridgeAPIClient,
    @unchecked Sendable
{
    private let recorder: OrchestratorOptimisticUpdateRecorder
    private let gate: OrchestratorGroupedLightGate?

    init(
        bridgeID: String,
        bridgeName: String,
        ip: String,
        token: String,
        recorder: OrchestratorOptimisticUpdateRecorder,
        gate: OrchestratorGroupedLightGate?
    ) {
        self.recorder = recorder
        self.gate = gate
        super.init(bridgeID: bridgeID, bridgeName: bridgeName, ip: ip, token: token)
    }

    override func setGroupedLight(id: String, on: Bool) async throws {
        await recorder.record(.init(id: id, on: on))
        if let gate {
            try await gate.suspendUntilReleased()
        } else {
            throw OrchestratorOptimisticUpdateTestError.forcedGroupedLightFailure
        }
    }
}

// MARK: - Cached-room fixture

private func makeOrchestratorOptimisticUpdateCachedRoom(initialIsOn: Bool) -> HueLocalRoom {
    let room = HueLocalRoom(roomID: "room-001", bridgeID: "bridge-1")
    room.cachedName = "Bedroom"
    room.cachedGroupedLightID = "gl-001"
    room.lastIsOn = initialIsOn
    room.lastBrightness = 80
    return room
}

// MARK: - SUT

@MainActor
private struct OrchestratorOptimisticUpdateSUT {
    let orchestrator: UnifiedOrchestrator
    let client: OrchestratorOptimisticUpdateSpyBridgeClient
    let recorder: OrchestratorOptimisticUpdateRecorder
    let gate: OrchestratorGroupedLightGate?
}

@MainActor
private func makeOrchestratorOptimisticUpdateSUT(
    initialIsOn: Bool,
    gate: OrchestratorGroupedLightGate?
) -> OrchestratorOptimisticUpdateSUT {
    let recorder = OrchestratorOptimisticUpdateRecorder()
    let client = OrchestratorOptimisticUpdateSpyBridgeClient(
        bridgeID: "bridge-1",
        bridgeName: "Test Bridge",
        ip: "192.168.1.1",
        token: "test-token",
        recorder: recorder,
        gate: gate
    )
    let orchestrator = UnifiedOrchestrator()
    orchestrator.preloadCached(from: [makeOrchestratorOptimisticUpdateCachedRoom(initialIsOn: initialIsOn)])
    orchestrator.injectForTesting(clients: ["bridge-1": client])
    return OrchestratorOptimisticUpdateSUT(
        orchestrator: orchestrator,
        client: client,
        recorder: recorder,
        gate: gate
    )
}

// MARK: - Bounded eventual helper

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(2),
    condition: @MainActor () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        if clock.now >= deadline {
            throw OrchestratorOptimisticUpdateTestError.timeout(description: "condition")
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

// MARK: - OrchestratorOptimisticUpdateTests

@MainActor
final class OrchestratorOptimisticUpdateTests: XCTestCase {

    // MARK: MUT-01

    func testSetRoom_appliesOptimisticState_beforeAPICallCompletes() async throws {
        let gate = OrchestratorGroupedLightGate()
        let sut = makeOrchestratorOptimisticUpdateSUT(initialIsOn: false, gate: gate)
        let room = sut.orchestrator.allRooms[0]

        sut.orchestrator.setRoom(room, isOn: true)
        XCTAssertTrue(sut.orchestrator.allRooms[0].isOn)

        do {
            try await sut.recorder.waitForCallCount(1)
            try await gate.waitUntilSuspended()
            let calls = await sut.recorder.recordedCalls()
            XCTAssertEqual(calls, [OrchestratorOptimisticUpdateRecorder.Call(id: "gl-001", on: true)])
            await gate.releaseFailure()
            try await waitUntil { !sut.orchestrator.allRooms[0].isOn }
        } catch {
            await gate.releaseFailure()
            throw error
        }
    }

    // MARK: MUT-02

    func testSetRoom_rollsBack_afterAPIError() async throws {
        let sut = makeOrchestratorOptimisticUpdateSUT(initialIsOn: true, gate: nil)
        let room = sut.orchestrator.allRooms[0]

        sut.orchestrator.setRoom(room, isOn: false)
        XCTAssertFalse(sut.orchestrator.allRooms[0].isOn)

        try await sut.recorder.waitForCallCount(1)
        try await waitUntil { sut.orchestrator.allRooms[0].isOn }
        let calls = await sut.recorder.recordedCalls()
        XCTAssertEqual(calls, [OrchestratorOptimisticUpdateRecorder.Call(id: "gl-001", on: false)])
    }

    // MARK: MUT-03

    func testTurnAllOff_appliesOptimisticState_beforeAPICallsComplete() async throws {
        let gate = OrchestratorGroupedLightGate()
        let sut = makeOrchestratorOptimisticUpdateSUT(initialIsOn: true, gate: gate)
        let task = Task { await sut.orchestrator.turnAllOff() }

        do {
            try await sut.recorder.waitForCallCount(1)
            try await gate.waitUntilSuspended()
            XCTAssertFalse(sut.orchestrator.allRooms[0].isOn)
            let calls = await sut.recorder.recordedCalls()
            XCTAssertEqual(calls, [OrchestratorOptimisticUpdateRecorder.Call(id: "gl-001", on: false)])
            await gate.releaseSuccess()
            await task.value
        } catch {
            await gate.releaseSuccess()
            _ = await task.value
            throw error
        }
    }
}

// MARK: - Scenes-tab delete / rename (optimistic + rollback)

/// Scene CRUD spy: deleteScene/renameScene succeed or throw on demand.
private final class SceneCRUDSpyBridgeClient: BridgeAPIClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _fail = false
    private var _renamedTo: [String] = []
    var fail: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _fail }
        set { lock.lock(); _fail = newValue; lock.unlock() }
    }
    var renamedTo: [String] { lock.lock(); defer { lock.unlock() }; return _renamedTo }

    init() {
        super.init(bridgeID: "bridge-s", bridgeName: "Scenes Bridge",
                   ip: "192.0.2.60", token: "test-token")
    }

    override func deleteScene(id: String) async throws {
        if fail { throw OrchestratorOptimisticUpdateTestError.forcedGroupedLightFailure }
    }
    override func renameScene(id: String, name: String) async throws {
        lock.lock(); _renamedTo.append(name); let shouldFail = _fail; lock.unlock()
        if shouldFail { throw OrchestratorOptimisticUpdateTestError.forcedGroupedLightFailure }
    }
}

@MainActor
final class OrchestratorSceneCRUDRollbackTests: XCTestCase {

    /// Scene writes schedule the debounced widget snapshot — drain it so it
    /// can't land inside another suite's App Group assertions.
    override func tearDown() async throws {
        try await Task.sleep(for: .milliseconds(650))
        try await super.tearDown()
    }

    private func scene(_ id: String, _ name: String) -> GlobalSceneItem {
        GlobalSceneItem(id: "bridge-s:\(id)", bridgeSceneID: id, name: name,
                        roomID: "room-s", bridgeID: "bridge-s",
                        isActive: false, isDynamic: false, speed: 0.5)
    }

    private func makeSUT() -> (UnifiedOrchestrator, SceneCRUDSpyBridgeClient) {
        let orchestrator = UnifiedOrchestrator()
        let client = SceneCRUDSpyBridgeClient()
        orchestrator.injectForTesting(clients: ["bridge-s": client])
        orchestrator.globalScenes = [scene("a", "Alpha"), scene("b", "Bravo"), scene("c", "Charlie")]
        return (orchestrator, client)
    }

    func testFailedDeleteRestoresTheSceneInPlaceAndSaysSo() async {
        let (orchestrator, client) = makeSUT()
        client.fail = true

        let deleted = await orchestrator.deleteGlobalScene(orchestrator.globalScenes[1])

        XCTAssertFalse(deleted, "callers must not scrub favorites/usage for a live scene")
        XCTAssertEqual(orchestrator.globalScenes.map(\.bridgeSceneID), ["a", "b", "c"],
                       "the refused delete rolls back to its original position")
        XCTAssertNotNil(orchestrator.toastMessage)
    }

    func testConfirmedDeleteRemovesTheScene() async {
        let (orchestrator, _) = makeSUT()
        let deleted = await orchestrator.deleteGlobalScene(orchestrator.globalScenes[0])
        XCTAssertTrue(deleted)
        XCTAssertEqual(orchestrator.globalScenes.map(\.bridgeSceneID), ["b", "c"])
    }

    func testFailedRenameRestoresTheOldName() async {
        let (orchestrator, client) = makeSUT()
        client.fail = true

        let renamed = await orchestrator.renameGlobalScene(orchestrator.globalScenes[0], to: "Omega")

        XCTAssertFalse(renamed)
        XCTAssertEqual(orchestrator.globalScenes[0].name, "Alpha")
        XCTAssertNotNil(orchestrator.toastMessage)
    }

    func testRenameIsTrimmedAndCappedAtTheBridgeLimit() async {
        let (orchestrator, client) = makeSUT()
        let long = "  " + String(repeating: "x", count: 40) + "  "

        let renamed = await orchestrator.renameGlobalScene(orchestrator.globalScenes[0], to: long)

        XCTAssertTrue(renamed)
        XCTAssertEqual(client.renamedTo, [String(repeating: "x", count: 32)])
        XCTAssertEqual(orchestrator.globalScenes[0].name.count, 32)
    }
}
