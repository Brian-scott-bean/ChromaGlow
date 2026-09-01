//
//  StudioLifecycleSerializationTests.swift
//  HueHomeTests
//
//  Unified Customization Engine — R4B (apply reentrancy).
//
//  THE DEFECT
//  ──────────
//  `apply()` suspends about ten times: bridge reads, the takeover preflight,
//  the Entertainment acquisition, the 400 ms bridge-native swap, the 200 ms
//  engine teardown. Two taps in flight together each reached their install
//  site with no epoch check of any kind. Because `RunningLookTargetKey`
//  carries the CARD and the EXECUTION, the loser's scope was not overwritten
//  by the winner's — it stayed registered and `isCurrent`, an orphan whose
//  debounced sends still passed the fence and still reached the bridge.
//
//  THE FIX, and what these tests hold it to: one global FIFO lifecycle chain.
//  Every mutating entry point chains onto the previous one, so exactly one
//  lifecycle body runs at a time. The belt beside it is
//  `installRunningIdentity`, which retires every scope at a PLACE before
//  registering the new one — so even an install that skipped a stop cannot
//  leave two live scopes on one room.
//
//  DETERMINISM (Guard 12): no `Task.sleep`, no `XCTWaiter`, no
//  `wait(for:timeout:)`. Concurrency is expressed with `async let` and with a
//  continuation handshake (`RestGate`) parked inside a production bridge read,
//  so "the first operation is genuinely mid-flight" is an observed fact rather
//  than an elapsed interval.
//

import XCTest
import SwiftUI
@testable import HueHome

// MARK: - Spy

/// A bridge client that records nothing but answers everything offline, plus
/// one parkable read so a test can hold `apply` open at a known point.
private final class LifecycleSpyClient: BridgeAPIClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _fetchLightsGate: RestGate?
    private var _groupedWrites: [String] = []

    var groupedWrites: [String] {
        lock.lock(); defer { lock.unlock() }
        return _groupedWrites
    }

    /// Park `fetchLights()` — the read `apply` performs for any room with a
    /// non-light child ref, and therefore a point every apply passes through
    /// while it is INSIDE the serialized body.
    func stageFetchLightsGate(_ gate: RestGate) {
        lock.lock(); _fetchLightsGate = gate; lock.unlock()
    }

    override func fetchLights() async throws -> [HueLight] {
        lock.lock(); let gate = _fetchLightsGate; lock.unlock()
        if let gate {
            gate.signalStarted()
            await gate.waitForRelease()
        }
        return []
    }

    override func fetchRooms() async throws -> [HueRoom] { [] }
    override func fetchZones() async throws -> [HueZone] { [] }
    override func fetchGroupedLights() async throws -> [HueGroupedLight] { [] }
    override func fetchScenes() async throws -> [HueScene] { [] }
    override func fetchLightIDsForGroup(groupedLightID: String) async throws -> [String] { [] }

    override func setGroupedLightState(id: String, on: Bool, brightness: Double) async throws {
        lock.lock(); _groupedWrites.append(id); lock.unlock()
    }
    override func setGroupedLightBrightness(id: String, brightness: Double) async throws {
        lock.lock(); _groupedWrites.append(id); lock.unlock()
    }
    override func setGroupedLight(id: String, on: Bool) async throws {
        lock.lock(); _groupedWrites.append(id); lock.unlock()
    }
    override func setGroupedLightEffect(
        id: String, on: Bool?, brightness: Double?,
        xy: (Double, Double)?, mirek: Int?, duration: Int
    ) async throws {
        lock.lock(); _groupedWrites.append(id); lock.unlock()
    }
    override func setLightNativeEffect(id: String, effect: String) async throws {}
    override func setLightColor(id: String, x: Double, y: Double) async throws {}

    override func get(path: String, ip: String, token: String) async throws -> Data {
        Data(#"{"data": []}"#.utf8)
    }
    override func put(path: String, body: [String: Any], ip: String, token: String) async throws -> Data {
        Data("{}".utf8)
    }
}

// MARK: - Tests

@MainActor
final class StudioLifecycleSerializationTests: XCTestCase {

    private var vm: StudioViewModel!
    private var orchestrator: UnifiedOrchestrator!
    private var bridge: LifecycleSpyClient!

    override func setUp() async throws {
        try await super.setUp()
        bridge = LifecycleSpyClient(bridgeID: "bridge-a", bridgeName: "Bridge A",
                                    ip: "192.0.2.1", token: "spy-token")
        orchestrator = UnifiedOrchestrator()
        orchestrator.injectForTesting(clients: ["bridge-a": bridge])
        vm = StudioViewModel()
        vm.configure(orchestrator: orchestrator)
    }

    override func tearDown() async throws {
        await orchestrator.stopStudioMode()
        vm = nil
        orchestrator = nil
        bridge = nil
        try await super.tearDown()
    }

    // ── Fixtures ────────────────────────────────────────────────

    /// A room whose child refs include a DEVICE, which is what makes `apply`
    /// run the `fetchLights()` inventory the gate is parked on.
    private func gatedRoom(_ id: String = "room-a") -> RoomDisplayItem {
        RoomDisplayItem(
            kind: .room, id: id, name: id, archetype: nil, isOn: true, brightness: 60,
            groupedLightID: "gl-\(id)", lightCount: 2, bridgeID: "bridge-a",
            childResourceRefs: [(rid: "D1", rtype: "device")])
    }

    private func plainRoom(_ id: String = "room-a") -> RoomDisplayItem {
        RoomDisplayItem(
            kind: .room, id: id, name: id, archetype: nil, isOn: true, brightness: 60,
            groupedLightID: "gl-\(id)", lightCount: 2, bridgeID: "bridge-a",
            childResourceRefs: [])
    }

    private func card(_ id: String) throws -> StudioCard {
        try XCTUnwrap((vm.liveModeCards + vm.effectCards).first { $0.id == id })
    }

    // ── The race the chain closes ───────────────────────────────

    /// Two applies of the same card on the same target, genuinely concurrent.
    ///
    /// Before the chain, both reached their install site and BOTH registered a
    /// scope: same target key, two generations, and the loser's entry left
    /// behind as `isCurrent` for its own generation. Afterwards there is one
    /// row, one scope, and every earlier generation on that target is fenced.
    func testTwoConcurrentAppliesOnOneTargetLeaveExactlyOneRowAndOneScope() async throws {
        let room = plainRoom()
        let ambient = try card("ambient")
        vm.selectedRoom = room

        async let first: Void = vm.apply(ambient, roomOverride: room,
                                         preferEntertainmentOverride: nil)
        async let second: Void = vm.apply(ambient, roomOverride: room,
                                          preferEntertainmentOverride: nil)
        _ = await (first, second)

        XCTAssertEqual(vm.runningEffects.count, 1, "one target, one row")
        XCTAssertEqual(vm.valueScopes.runningTargetCount, 1,
                       "the loser left no orphan scope behind")

        let survivor = try XCTUnwrap(vm.runningEffect(for: room)).identity
        XCTAssertTrue(vm.valueScopes.isCurrent(survivor),
                      "the row that exists is the run the scopes describe")
        let earlier = RunningLookIdentity(
            bridgeID: survivor.bridgeID, groupID: survivor.groupID, kind: survivor.kind,
            cardID: survivor.cardID, execution: survivor.execution,
            generation: CustomizationGeneration(survivor.generation.value - 1))
        XCTAssertFalse(vm.valueScopes.isCurrent(earlier),
                       "the first apply's identity is fenced out, so its sends drop")
    }

    /// A stop requested while an apply is genuinely mid-flight is QUEUED, not
    /// lost: it runs against the replacement the apply installs, and the room
    /// ends up stopped.
    ///
    /// Deterministic by handshake, not by timing: the stop is only issued once
    /// the apply has signalled from inside its own bridge read, which is inside
    /// the serialized body.
    func testStopQueuedBehindAnApplyStopsTheReplacement() async throws {
        let room = gatedRoom()
        let ambient = try card("ambient")
        vm.selectedRoom = room

        let gate = RestGate()
        bridge.stageFetchLightsGate(gate)

        let applying = Task { @MainActor in
            await self.vm.apply(ambient, roomOverride: room, preferEntertainmentOverride: nil)
        }
        await gate.waitUntilStarted()   // the apply is INSIDE the lifecycle body

        let stopping = Task { @MainActor in await self.vm.stopAll() }
        gate.release()
        await applying.value
        await stopping.value

        XCTAssertTrue(vm.runningEffects.isEmpty,
                      "the stop was queued behind the apply and stopped what it started")
        XCTAssertEqual(vm.valueScopes.runningTargetCount, 0,
                       "…including its scope")
        XCTAssertTrue(vm.paramSendTasks.isEmpty, "…and its pending send slot")
    }

    // ── The re-entrancy detector ────────────────────────────────

    #if DEBUG
    /// The detector fires on a nested entry, and the inner body runs INLINE
    /// rather than deadlocking on a chain link that cannot finish until it
    /// returns. Both halves matter: the flag is how a future ordering slip is
    /// found, and the inline fallback is why finding it is not a hang.
    func testNestedSerializedEntryIsDetectedAndRunsInlineInsteadOfDeadlocking() async {
        XCTAssertFalse(vm.lifecycleReentrancyDetected, "clean to start")
        var innerRan = false
        await vm.serialized { [weak vm] in
            await vm?.serialized { innerRan = true }
        }
        XCTAssertTrue(innerRan, "the inner body ran rather than deadlocking")
        XCTAssertTrue(vm.lifecycleReentrancyDetected, "…and the slip was recorded")
    }

    /// The invariant: no PRODUCTION path re-enters the chain. Drives the paths
    /// that compose others — apply, reset (which re-applies for a bridge-native
    /// card), a preview audition and its cancel, and Stop All.
    func testNoProductionLifecyclePathReEntersTheChain() async throws {
        let room = plainRoom()
        let ambient = try card("ambient")
        vm.selectedRoom = room

        await vm.apply(ambient, roomOverride: room, preferEntertainmentOverride: nil)
        await vm.resetParams(for: ambient)
        await vm.beginPreviewLive(card: ambient)
        await vm.cancelPreviewLive()
        await vm.stopActiveTarget(StudioSelectionKey(room: room))
        await vm.stopAll()

        XCTAssertFalse(vm.lifecycleReentrancyDetected,
                       "every production entry point reaches the chain from outside it")
    }

    /// The task-local LEAKS into unstructured tasks.
    ///
    /// `isInside` is a `@TaskLocal`, and task-locals are COPIED into every
    /// `Task {}` spawned while they are set. The engine and frame loops
    /// `startStudioMode` / `startCompositionMode` spawn therefore inherited
    /// "we are inside a lifecycle body" for the whole life of the look — so a
    /// later call from one of those loops into a serialized entry point would
    /// run INLINE, silently bypassing the FIFO. `applyCore` resets the value
    /// across those two start calls; this is that reset, proven.
    func testATaskSpawnedAcrossTheStartResetSeesItselfOutsideTheChain() async {
        var insideAtSpawn: Bool?
        var insideUnderReset: Bool?
        await vm.serialized {
            await StudioLifecycleContext.$isInside.withValue(false) {
                await Task { insideUnderReset = StudioLifecycleContext.isInside }.value
            }
            await Task { insideAtSpawn = StudioLifecycleContext.isInside }.value
        }
        XCTAssertEqual(insideUnderReset, false, """
            a task spawned across the reset must not inherit the flag: it \
            outlives this body, and re-entering the chain from it would run \
            inline instead of queueing
            """)
        XCTAssertEqual(insideAtSpawn, true,
                       "…while an ordinary spawn inside the body still inherits it, "
                       + "which is exactly why the reset has to be explicit")
    }
    #endif

    // ── The belt: one live scope per place ──────────────────────

    /// `installRunningIdentity` retires every scope at the PLACE it is
    /// installing on — any card, any execution — and cancels their pending
    /// sends with them.
    ///
    /// This is the case serialization alone cannot cover: an install that never
    /// routed through `stopEffect` (a saved-look outcome, a handoff replay, a
    /// card whose strategy changed under one id) would otherwise leave the
    /// predecessor's scope live under its own target key.
    func testInstallRunningIdentityRetiresEveryScopeAtThatPlace() throws {
        let room = plainRoom()
        let ambient = try card("ambient")
        let candle = try card("candle")

        let first = vm.installRunningIdentity(
            room: room, card: ambient, execution: .appDriven(engineKey: "ambient"))
        vm.runningEffects[StudioSelectionKey(room: room)] = RunningEffect(
            cardID: ambient.id, card: ambient, room: room, lightIDs: ["L1"],
            isEntertainment: false, requestedTransport: nil, transportFallback: false,
            identity: first)
        XCTAssertEqual(vm.valueScopes.runningTargetCount, 1)

        // Arm a pending send against the first instance, exactly as a drag does.
        vm.selectedRoom = room
        let session = try XCTUnwrap(vm.beginParamEdit(cardID: ambient.id, paramID: "speed"))
        vm.updateParamEdit(session, value: 88)
        XCTAssertNotNil(vm.paramSendTasks[first.targetKey], "a send is pending for the first run")

        // A DIFFERENT card, with a different execution, on the SAME place.
        let second = vm.installRunningIdentity(
            room: room, card: candle, execution: .bridgeNative(effect: "candle"))

        XCTAssertEqual(vm.valueScopes.runningTargetCount, 1,
                       "a place holds exactly one live scope")
        XCTAssertFalse(vm.valueScopes.isCurrent(first), "the predecessor is fenced")
        XCTAssertTrue(vm.valueScopes.isCurrent(second))
        XCTAssertNil(vm.paramSendTasks[first.targetKey],
                     "the predecessor's pending send was cancelled with its scope")
        XCTAssertNil(vm.pendingParamSends[first.targetKey],
                     "…and the fields it had accumulated were dropped, not inherited")
    }

    /// The belt is scoped to ONE place: a same-id zone on the same bridge, and
    /// the same room id on another bridge, are different places and survive.
    func testTheBeltDoesNotReachAnotherPlace() throws {
        let asRoom = plainRoom("shared-id")
        let asZone = RoomDisplayItem(
            kind: .zone, id: "shared-id", name: "shared-id", archetype: nil,
            isOn: true, brightness: 60, groupedLightID: "gl-z", lightCount: 2,
            bridgeID: "bridge-a", childResourceRefs: [])
        let onOtherBridge = RoomDisplayItem(
            kind: .room, id: "shared-id", name: "shared-id", archetype: nil,
            isOn: true, brightness: 60, groupedLightID: "gl-b", lightCount: 2,
            bridgeID: "bridge-b", childResourceRefs: [])
        let ambient = try card("ambient")

        let zoneIdentity = vm.installRunningIdentity(
            room: asZone, card: ambient, execution: .appDriven(engineKey: "ambient"))
        let otherBridgeIdentity = vm.installRunningIdentity(
            room: onOtherBridge, card: ambient, execution: .appDriven(engineKey: "ambient"))
        let roomIdentity = vm.installRunningIdentity(
            room: asRoom, card: ambient, execution: .appDriven(engineKey: "ambient"))

        XCTAssertEqual(vm.valueScopes.runningTargetCount, 3,
                       "room, same-id zone, and the same id on another bridge are three places")
        XCTAssertTrue(vm.valueScopes.isCurrent(zoneIdentity))
        XCTAssertTrue(vm.valueScopes.isCurrent(otherBridgeIdentity))
        XCTAssertTrue(vm.valueScopes.isCurrent(roomIdentity))
    }
}
