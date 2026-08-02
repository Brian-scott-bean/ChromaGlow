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

    // ──────────────────────────────────────────────
    // MARK: - Composer 2 packet 3: scoped REST mailbox semantics
    // ──────────────────────────────────────────────
    //
    // Pure `RestSender` behavior only — orchestrator/multi-bridge integration
    // lives in MultiBridgeRoutingTests. Every test here is driven by
    // continuations and recorded event arrays; NOTHING is proven by Task.sleep.
    //
    // The shared shape: park one closure inside the flush loop (it blocks on a
    // continuation), mutate the mailbox while it is parked, then release it and
    // assert on the recorded order. That is the only way to observe "pending"
    // and "executing" as distinct states without racing the scheduler.

    /// Enqueue a closure that signals when it starts and blocks until released.
    /// Returns the handle used to await the start and to release it.
    @discardableResult
    private func parkBlockingWork(
        on sender: RestSender,
        scope: RestScope,
        events: RestEventLog,
        label: String = "gate",
        probeBox: RestProbeBox? = nil
    ) async -> RestGate {
        let gate = RestGate()
        await sender.enqueue(scope: scope) { stillCurrent in
            probeBox?.probe = stillCurrent
            events.record(label)
            gate.signalStarted()
            await gate.waitForRelease()
        }
        await gate.waitUntilStarted()
        return gate
    }

    /// Enqueue a closure that records `label` and never blocks.
    private func enqueueRecording(
        on sender: RestSender,
        scope: RestScope,
        events: RestEventLog,
        _ label: String
    ) async {
        await sender.enqueue(scope: scope) { _ in
            events.record(label)
        }
    }

    /// Park a no-op behind everything already queued, then wait for it. Once it
    /// runs, the flush loop has drained every scope enqueued before it — a
    /// deterministic barrier that replaces "sleep and hope".
    private func drain(_ sender: RestSender) async {
        let done = RestGate()
        await sender.enqueue(scope: RestScope(roomID: "__drain__", owner: .composer)) { _ in
            done.signalStarted()
        }
        await done.waitUntilStarted()
    }

    // 1. Latest-wins applies WITHIN a scope, and scopes are independent slots.
    func testLatestWinsIsPerScopeAndScopesAreIndependent() async {
        let sender = RestSender()
        let events = RestEventLog()
        let roomB = RestScope(roomID: "room-b", owner: .composer)
        let roomC = RestScope(roomID: "room-c", owner: .composer)

        let gate = await parkBlockingWork(
            on: sender, scope: RestScope(roomID: "room-a", owner: .composer),
            events: events)

        // Queued behind the parked closure, so nothing can start early.
        await enqueueRecording(on: sender, scope: roomB, events: events, "B1")
        await enqueueRecording(on: sender, scope: roomC, events: events, "C1")
        await enqueueRecording(on: sender, scope: roomB, events: events, "B2")

        gate.release()
        await drain(sender)

        XCTAssertEqual(events.entries, ["gate", "B2", "C1"], """
            B2 must REPLACE B1 in room B's slot (latest-wins within a scope), \
            while room C's independent slot is untouched — the pre-packet-3 \
            single slot would have dropped C1 as well
            """)
    }

    // 2. clear(scope:) drops that scope's pending work and nothing else.
    func testClearScopeDropsOnlyThatScopesPendingWork() async {
        let sender = RestSender()
        let events = RestEventLog()
        let roomB = RestScope(roomID: "room-b", owner: .composer)
        let roomC = RestScope(roomID: "room-c", owner: .composer)

        let gate = await parkBlockingWork(
            on: sender, scope: RestScope(roomID: "room-a", owner: .composer),
            events: events)
        await enqueueRecording(on: sender, scope: roomB, events: events, "B")
        await enqueueRecording(on: sender, scope: roomC, events: events, "C")

        await sender.clear(scope: roomB)
        gate.release()
        await drain(sender)

        XCTAssertEqual(events.entries, ["gate", "C"],
            "clearing room B must not touch room C's queued work")
    }

    // 3. The epoch is invalidated BEFORE clear(scope:) returns — an already
    //    executing closure observes it through its own probe.
    func testEpochInvalidationIsVisibleBeforeClearReturns() async {
        let sender = RestSender()
        let events = RestEventLog()
        let scope = RestScope(roomID: "room-a", owner: .composer)
        let probeBox = RestProbeBox()

        let gate = await parkBlockingWork(
            on: sender, scope: scope, events: events, probeBox: probeBox)

        let probe = try? XCTUnwrap(probeBox.probe)
        let currentBeforeClear = await probe?()
        XCTAssertEqual(currentBeforeClear, true, "the running closure starts valid")

        await sender.clear(scope: scope)

        let currentAfterClear = await probe?()
        XCTAssertEqual(currentAfterClear, false, """
            invalidation must be complete when clear returns — the caller \
            immediately primes the replacement look, and a probe that still \
            reported "current" would let the old batch loop keep going
            """)

        gate.release()
        await drain(sender)
    }

    // 4. clearAll() invalidates EVERY epoch before clearing pending.
    func testClearAllInvalidatesEveryEpochBeforeClearingPending() async {
        let sender = RestSender()
        let events = RestEventLog()
        let running = RestScope(roomID: "room-a", owner: .composer)
        let queued  = RestScope(roomID: "room-b", owner: .studio)
        let probeBox = RestProbeBox()

        let gate = await parkBlockingWork(
            on: sender, scope: running, events: events, probeBox: probeBox)
        await enqueueRecording(on: sender, scope: queued, events: events, "B")

        await sender.clearAll()

        let probe = try? XCTUnwrap(probeBox.probe)
        let stillCurrent = await probe?()
        XCTAssertEqual(stillCurrent, false,
            "the EXECUTING closure must see invalidation — epochs are bumped first")
        let queuedStillCurrent = await sender.isCurrent(scope: queued, epoch: 0)
        XCTAssertFalse(queuedStillCurrent, """
            a scope that only ever held PENDING work must be invalidated too, \
            not merely dropped
            """)

        gate.release()
        await drain(sender)
        XCTAssertEqual(events.entries, ["gate"], "clearAll drops queued work as well")
    }

    // 5. One-flush invariant: two enqueues arriving before the first flush is
    //    scheduled must not produce two concurrently executing closures.
    //    (Pre-packet-3, `isInflight` was set inside the spawned flush task, so
    //    the second enqueue saw it false and spawned a second flush.)
    func testBurstEnqueuesNeverRunTwoClosuresConcurrently() async {
        let sender = RestSender()
        let events = RestEventLog()
        let first  = RestScope(roomID: "room-a", owner: .composer)
        let second = RestScope(roomID: "room-b", owner: .composer)

        let gate = RestGate()
        // Back-to-back, with no suspension that would let a flush task run in
        // between — this is the exact burst that used to double-flush.
        await sender.enqueue(scope: first) { _ in
            events.record("first-start")
            gate.signalStarted()
            await gate.waitForRelease()
            events.record("first-end")
        }
        await sender.enqueue(scope: second) { _ in
            events.record("second-start")
        }

        await gate.waitUntilStarted()
        XCTAssertEqual(events.entries, ["first-start"], """
            the second closure must not have begun while the first is still \
            executing — one request in flight is the whole point of the mailbox
            """)

        gate.release()
        await drain(sender)
        XCTAssertEqual(events.entries, ["first-start", "first-end", "second-start"],
            "the second closure runs only after the first completes")
    }

    // 6. Re-entrant enqueue/clear from inside a running closure must not
    //    deadlock (the actor suspends across `await work(...)`, and `isFlushing`
    //    is already true so no second flush spawns).
    func testReentrantEnqueueAndClearFromInsideAClosureDoesNotDeadlock() async {
        let sender = RestSender()
        let events = RestEventLog()
        let outer   = RestScope(roomID: "room-a", owner: .composer)
        let spawned = RestScope(roomID: "room-b", owner: .composer)
        let doomed  = RestScope(roomID: "room-c", owner: .composer)

        let gate = await parkBlockingWork(
            on: sender, scope: RestScope(roomID: "room-gate", owner: .composer),
            events: events)

        // `outer` is queued AHEAD of `doomed`, so its re-entrant clear reaches
        // work that has genuinely not started yet.
        let spawnedRan = RestGate()
        await sender.enqueue(scope: outer) { _ in
            events.record("outer")
            await sender.clear(scope: doomed)
            await sender.enqueue(scope: spawned) { _ in
                events.record("spawned-from-inside")
                spawnedRan.signalStarted()
            }
        }
        await enqueueRecording(on: sender, scope: doomed, events: events, "doomed")

        gate.release()
        // Wait on the spawned work itself: it is enqueued LATER than any
        // barrier this test could have placed up front, so `drain` would
        // return before it ran.
        await spawnedRan.waitUntilStarted()
        XCTAssertEqual(events.entries, ["gate", "outer", "spawned-from-inside"], """
            work enqueued from inside a running closure must still run, the \
            re-entrant clear must drop the not-yet-started work, and neither \
            may wedge the flush loop
            """)
    }

    // 7. Scope selection is FIFO by first-enqueue, not dictionary order — a busy
    //    scope must not be able to starve a quiet one.
    func testScopeSelectionIsFIFO() async {
        let sender = RestSender()
        let events = RestEventLog()

        let gate = await parkBlockingWork(
            on: sender, scope: RestScope(roomID: "room-a", owner: .composer),
            events: events)

        for label in ["C", "B", "D", "E"] {
            await enqueueRecording(
                on: sender,
                scope: RestScope(roomID: "room-\(label)", owner: .composer),
                events: events, label)
        }
        // Replacing C's payload must NOT move it to the back of the queue.
        await enqueueRecording(
            on: sender, scope: RestScope(roomID: "room-C", owner: .composer),
            events: events, "C2")

        gate.release()
        await drain(sender)

        XCTAssertEqual(events.entries, ["gate", "C2", "B", "D", "E"],
            "scopes are served in the order they first joined the queue")
    }
}

// MARK: - Packet 3 test support

/// Thread-safe ordered event recorder. Every packet 3 assertion is about
/// ORDER and PRESENCE, never elapsed time.
final class RestEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _entries: [String] = []

    var entries: [String] {
        lock.lock(); defer { lock.unlock() }
        return _entries
    }

    func record(_ entry: String) {
        lock.lock(); defer { lock.unlock() }
        _entries.append(entry)
    }
}

/// A closure can hand its `ValidityProbe` out to the test so the test can ask,
/// from outside, what the RUNNING closure would see.
final class RestProbeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _probe: RestSender.ValidityProbe?

    var probe: RestSender.ValidityProbe? {
        get { lock.lock(); defer { lock.unlock() }; return _probe }
        set { lock.lock(); defer { lock.unlock() }; _probe = newValue }
    }
}

/// A two-way handshake: the test waits for the closure to start, the closure
/// waits for the test to release it. Both directions are continuation-based so
/// nothing depends on timing.
final class RestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func signalStarted() {
        lock.lock()
        started = true
        let waiters = startWaiters
        startWaiters = []
        lock.unlock()
        waiters.forEach { $0.resume() }
    }

    func release() {
        lock.lock()
        released = true
        let waiters = releaseWaiters
        releaseWaiters = []
        lock.unlock()
        waiters.forEach { $0.resume() }
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if started { lock.unlock(); cont.resume(); return }
            startWaiters.append(cont)
            lock.unlock()
        }
    }

    func waitForRelease() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if released { lock.unlock(); cont.resume(); return }
            releaseWaiters.append(cont)
            lock.unlock()
        }
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
