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
    private var _effectWrites: [RecordedEffectWrite] = []

    struct RecordedEffectWrite: Equatable {
        let id: String
        let on: Bool?
        let brightness: Double?
        let mirek: Int?
        let hasXY: Bool
        let duration: Int
    }

    /// Every grouped_light effect write, in call order.
    var effectWrites: [RecordedEffectWrite] {
        lock.lock(); defer { lock.unlock() }
        return _effectWrites
    }

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
        lock.lock()
        _groupedEffectCount += 1
        _effectWrites.append(RecordedEffectWrite(id: id, on: on, brightness: brightness,
                                                 mirek: mirek, hasXY: xy != nil, duration: duration))
        lock.unlock()
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

    /// A Composer sweep books its whole room at once: it goes immediately,
    /// and the bridge's NEXT command waits for every slot it booked.
    func testReserveBooksItsWholeCostBeforeTheNextCommand() async {
        let gate = BridgeCommandGate()
        let clock = ContinuousClock()
        let start = clock.now
        await gate.reserve(cost: 5)
        XCTAssertLessThan(start.duration(to: clock.now), .milliseconds(50),
            "the first booking on an idle bridge must not wait")
        await gate.send { }
        XCTAssertGreaterThanOrEqual(start.duration(to: clock.now), .milliseconds(480),
            "a 5-command booking holds the bridge for 5 × 100 ms")
    }

    /// Sweep after sweep of an 8-light room averages the bridge budget, not
    /// the bridge's reply speed (device round: ~14 cmd/sec, replies ~270 ms).
    func testBackToBackReservationsAverageTheBridgeBudget() async {
        let gate = BridgeCommandGate()
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<3 { await gate.reserve(cost: 8) }
        // Three 8-command sweeps = 24 commands; the third starts after 16.
        XCTAssertGreaterThanOrEqual(start.duration(to: clock.now), .milliseconds(1550))
    }

    /// A zero or negative cost still books one slot — a sweep is at least a
    /// command, and a free booking would let a loop spin.
    func testReserveNeverBooksLessThanOneSlot() async {
        let gate = BridgeCommandGate()
        let clock = ContinuousClock()
        let start = clock.now
        await gate.reserve(cost: 0)
        await gate.reserve(cost: -3)
        XCTAssertGreaterThanOrEqual(start.duration(to: clock.now), .milliseconds(90))
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

    /// More/Settings enter demo from a PAIRED session: the real client stays
    /// registered, so the bulk fan-out itself must refuse — and the real
    /// rooms must not survive into the demo snapshot (All Off walked them).
    func testDemoEnteredFromPairedSessionNeverWritesToTheRealBridge() async {
        let (orchestrator, client) = makeBulkSUT(roomCount: 3)
        orchestrator.enterDemoMode()

        await orchestrator.turnAllOff()
        await orchestrator.applyAutomationPreset(id: "relax")
        await orchestrator.applyAutomationEffect(id: "movie")

        XCTAssertTrue(client.attemptsByID.isEmpty,
            "a demo All Off / automation must never reach the real bridge")
        XCTAssertNil(orchestrator.testRoomsByBridge()["bridge-1"],
            "real rooms must not survive into the demo snapshot")
        XCTAssertFalse(orchestrator.allRooms.contains { $0.bridgeID == "bridge-1" })
        XCTAssertFalse(orchestrator.globalScenes.contains { $0.bridgeID == "bridge-1" })
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

    /// Forget-all: once Settings suspends publishing, a rebuild landing in
    /// the async teardown window must not schedule a widget/watch publish —
    /// its `wc_unpaired = false` push superseded the watch's unpair.
    func testForgetAllSuspendsWidgetPublishingThroughTeardown() async {
        let (orchestrator, _) = makeBulkSUT(roomCount: 2)
        orchestrator.testSetGuestGrants([:])   // any rebuild schedules a publish
        XCTAssertTrue(orchestrator.testHasPendingWidgetWrite, "sanity: rebuilds publish normally")

        orchestrator.suspendWidgetPublishingForTeardown()
        XCTAssertFalse(orchestrator.testHasPendingWidgetWrite, "the pending publish is cancelled")

        orchestrator.testSetGuestGrants([:])
        await orchestrator.applyAutomationPreset(id: "relax")
        XCTAssertFalse(orchestrator.testHasPendingWidgetWrite,
            "no publish may be scheduled while a forget-all teardown is in progress")

        await orchestrator.forgetAllBridges()
        orchestrator.testSetGuestGrants([:])
        XCTAssertFalse(orchestrator.testHasPendingWidgetWrite,
            "still suspended after teardown — only the next configure lifts it")
    }

    /// Family Sharing: presets/effects set level + CT, so a power-only guest
    /// grant must exclude them — only All Off (power) may reach that bridge.
    func testPowerOnlyGuestGrantBlocksPresetsAndEffectsButNotAllOff() async {
        let (orchestrator, client) = makeBulkSUT(roomCount: 2)
        orchestrator.testSetGuestGrants(["bridge-1": GuestGrantSnapshot(
            allowedGroupIDs: ["room-1", "room-2"], features: [GuestFeature.onOff],
            profileName: "Alex")])

        await orchestrator.applyAutomationPreset(id: "relax")
        await orchestrator.applyAutomationEffect(id: "winddown")
        await orchestrator.applyAutomationEffect(id: "candle")
        XCTAssertTrue(client.attemptsByID.isEmpty,
            "a power-only grant must not receive preset/effect writes")

        await orchestrator.turnAllOff()
        XCTAssertEqual(Set(client.attemptsByID.keys), ["gl-1", "gl-2"],
            "All Off only needs power — it still reaches the granted rooms")
    }

    // ──────────────────────────────────────────────
    // MARK: - Effect automations apply the effect's OWN look
    // ──────────────────────────────────────────────

    private func effect(_ id: String) throws -> HueEffect {
        try XCTUnwrap(EffectLibrary.all.first { $0.id == id }, "catalog effect '\(id)' expected")
    }

    /// Wind Down is a slow dim to 3% at the warmest white — it used to set
    /// the house to 70% / 300 mirek in 400 ms.
    func testWindDownPlanIsASlowDimToNearDark() throws {
        let plan = AutomationEffectPlan.plan(for: try effect("winddown"))
        XCTAssertEqual(plan, .writes([
            AutomationGroupWrite(on: true, brightness: 3, mirek: 500, xy: nil,
                                 durationMs: 1_200_000),
        ]))
    }

    /// Sunset fades to darkness over its full 30 minutes, warming as it
    /// goes — one bridge-side transition, so the off survives the app.
    func testSunsetPlanFadesToOffOverItsDuration() throws {
        let plan = AutomationEffectPlan.plan(for: try effect("sunset"))
        XCTAssertEqual(plan, .writes([
            AutomationGroupWrite(on: false, brightness: nil, mirek: 490, xy: nil,
                                 durationMs: 1_800_000),
        ]))
    }

    /// Sunrise snaps to its dim warm start, then ramps to bright daylight.
    func testSunrisePlanSnapsToStartThenRamps() throws {
        let plan = AutomationEffectPlan.plan(for: try effect("sunrise"))
        XCTAssertEqual(plan, .writes([
            AutomationGroupWrite(on: true, brightness: 1, mirek: 490, xy: nil, durationMs: 0),
            AutomationGroupWrite(on: true, brightness: 90, mirek: 230, xy: nil,
                                 durationMs: 1_800_000),
        ]))
    }

    func testOneShotPlansUseTheirOwnLook() throws {
        XCTAssertEqual(AutomationEffectPlan.plan(for: try effect("movie")), .writes([
            AutomationGroupWrite(on: true, brightness: 30, mirek: 380, xy: nil, durationMs: 2000),
        ]))
        // Romance has a colour swatch, no warmth slider → a gamut-C xy write.
        guard case .writes(let steps) = AutomationEffectPlan.plan(for: try effect("romance")),
              let only = steps.first, steps.count == 1 else {
            return XCTFail("romance must be one colour write")
        }
        XCTAssertEqual(only.brightness, 20)
        XCTAssertNil(only.mirek)
        let xy = try XCTUnwrap(only.xy, "romance is a colour, not a white")
        XCTAssertGreaterThan(xy.x, 0.35, "a pink/red xy, not the white point")
        XCTAssertEqual(only.durationMs, 3000)
    }

    func testEveryPickableEffectPlanStaysInsideHueLimits() {
        for effect in EffectLibrary.all where !effect.requiresForeground {
            guard case .writes(let steps) = AutomationEffectPlan.plan(for: effect) else { continue }
            for step in steps {
                XCTAssertLessThanOrEqual(step.durationMs, AutomationEffectPlan.maxTransitionMs, effect.id)
                XCTAssertGreaterThanOrEqual(step.durationMs, 0, effect.id)
                if let m = step.mirek { XCTAssertTrue((153...500).contains(m), effect.id) }
                if let b = step.brightness { XCTAssertTrue((0...100).contains(b), effect.id) }
            }
        }
    }

    /// End to end through the gated fan-out: the bridge receives Wind Down's
    /// look, not the old shared 70 % / 300 mirek / 400 ms.
    func testApplyAutomationEffectSendsTheEffectsOwnLook() async {
        let (orchestrator, client) = makeBulkSUT(roomCount: 2)

        await orchestrator.applyAutomationEffect(id: "winddown")

        let writes = client.effectWrites
        XCTAssertEqual(writes.count, 2, "one ramp write per room")
        for write in writes {
            XCTAssertEqual(write.on, true)
            XCTAssertEqual(write.brightness, 3)
            XCTAssertEqual(write.mirek, 500)
            XCTAssertEqual(write.duration, 1_200_000)
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Automation notifications and housekeeping
    // ──────────────────────────────────────────────

    /// A delivered notification changes nothing until it is tapped — the copy
    /// used to claim the automation "is now active".
    func testAutomationNotificationCopyAsksForTheTap() {
        XCTAssertEqual(AutomationScheduler.notificationBody(for: .effect("winddown")),
                       "Tap to apply Wind Down.")
        XCTAssertEqual(AutomationScheduler.notificationBody(for: .preset("relax")),
                       "Tap to apply Relax.")
    }

    /// iOS silently keeps only 64 pending requests; over the cap the soonest
    /// slots win (and the caller logs the rest) instead of an arbitrary drop.
    func testSchedulingOverTheIOSCapKeepsTheSoonestFiringSlots() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-22T12:00:00Z"))
        let today = calendar.component(.weekday, from: now)
        let tomorrow = today % 7 + 1
        let id = UUID()
        let inOneHour = AutomationScheduler.Slot(automationID: id, weekday: today, hour: 13, minute: 0)
        let tomorrowSlot = AutomationScheduler.Slot(automationID: id, weekday: tomorrow, hour: 9, minute: 0)
        let almostAWeek = AutomationScheduler.Slot(automationID: id, weekday: today, hour: 11, minute: 0)
        let slots = [almostAWeek, tomorrowSlot, inOneHour]

        XCTAssertEqual(AutomationScheduler.slotsWithinCap(slots, now: now, calendar: calendar, cap: 2),
                       [inOneHour, tomorrowSlot])
        XCTAssertEqual(AutomationScheduler.slotsWithinCap(slots, now: now, calendar: calendar),
                       slots, "under the 64 cap every slot is kept as-is")
    }

    /// A tapped automation is buffered for the cold-start drain; an entry
    /// that sat undrained (e.g. while the drain was gated off) must expire,
    /// not replay "Sleep" at 7 am on some later launch.
    func testPendingAutomationTapExpiresInsteadOfReplayingLater() throws {
        let suite = "test.pendingAutomation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = PendingAutomation.presetKey
        let tappedAt = Date(timeIntervalSince1970: 1_000_000)

        PendingAutomation.store("sleep", forKey: key, now: tappedAt, defaults: defaults)
        XCTAssertEqual(PendingAutomation.take(forKey: key, now: tappedAt.addingTimeInterval(30),
                                              defaults: defaults), "sleep")
        XCTAssertNil(PendingAutomation.take(forKey: key, now: tappedAt.addingTimeInterval(31),
                                            defaults: defaults), "taken exactly once")

        PendingAutomation.store("sleep", forKey: key, now: tappedAt, defaults: defaults)
        XCTAssertNil(PendingAutomation.take(forKey: key, now: tappedAt.addingTimeInterval(9 * 3600),
                                            defaults: defaults), "a stale tap is discarded")
        XCTAssertNil(defaults.string(forKey: key), "…and removed, so it can never replay")

        defaults.set("relax", forKey: key)   // unstamped entry from an older build
        XCTAssertNil(PendingAutomation.take(forKey: key, now: tappedAt, defaults: defaults))
    }

    /// The optimistic card update must survive the rebuild that follows it
    /// (it used to write allRooms only, which rebuildAllRooms() rebuilt from
    /// the untouched per-bridge dictionary — discarding it immediately).
    func testAutomationPresetOptimisticUpdateSticks() async throws {
        let (orchestrator, _) = makeBulkSUT(roomCount: 2)
        let preset = try XCTUnwrap(AutomationPreset.find("relax"))

        await orchestrator.applyAutomationPreset(id: "relax")

        XCTAssertEqual(orchestrator.allRooms.count, 2)
        XCTAssertTrue(orchestrator.allRooms.allSatisfy { $0.brightness == preset.brightness },
                      "cards must show the preset, not the pre-preset cache")
        XCTAssertTrue(orchestrator.allRooms.allSatisfy { $0.dominantMirek == preset.mirek })
    }

    // ──────────────────────────────────────────────
    // MARK: - Family Sharing: presets/washes are adjust-level access
    // ──────────────────────────────────────────────

    private func powerOnlyGrant() -> [String: GuestGrantSnapshot] {
        ["bridge-1": GuestGrantSnapshot(allowedGroupIDs: ["room-1", "room-2"],
                                        features: [GuestFeature.onOff],
                                        profileName: "Alex")]
    }

    func testAutomationPresetSkipsPowerOnlyGrantedBridge() async {
        let (orchestrator, client) = makeBulkSUT(roomCount: 2)
        orchestrator.testSetGuestGrants(powerOnlyGrant())

        await orchestrator.applyAutomationPreset(id: "relax")

        XCTAssertTrue(client.attemptsByID.isEmpty,
                      "a power-only guest's rooms must not be re-dimmed or recolored")
        XCTAssertNil(orchestrator.lastBulkFailure, "a skip is not a failure")
        XCTAssertTrue(orchestrator.allRooms.allSatisfy { $0.brightness == 80 },
                      "skipped rooms keep their cards — no optimistic lie")
    }

    func testColorWashRefusesGrantWithoutAdjust() async throws {
        let (orchestrator, client) = makeBulkSUT(roomCount: 1)
        orchestrator.testSetGuestGrants(powerOnlyGrant())
        let room = try XCTUnwrap(orchestrator.allRooms.first)

        await orchestrator.applyColorWash(to: room, rule: .none, rootHue: 0.5,
                                          saturation: 1, brightness: 80)

        XCTAssertEqual(client.groupedEffectCount, 0)
        XCTAssertEqual(orchestrator.toastMessage, "Not available with guest access")
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

    // ──────────────────────────────────────────────
    // MARK: - Packet 4: return-value observability
    // ──────────────────────────────────────────────
    //
    // `enqueue`/`clear`/`clearAll` now report what they DID to the pending slot.
    // Behaviour is untouched — these report on the same branches packet 3 already
    // took. A caller cannot derive any of it: `flush()` removes an entry from
    // `pending` BEFORE awaiting its closure, so "enqueued but not yet started"
    // covers both a replaceable pending item and an unreplaceable executing one.

    // 8. A first enqueue drops nothing.
    func testFirstEnqueueReportsNoReplacement() async {
        let sender = RestSender()
        let scope = RestScope(roomID: "room-a", owner: .composer)

        let result = await sender.enqueue(scope: scope) { _ in }

        XCTAssertFalse(result.replacedPending,
            "an empty slot cannot have replaced anything")
    }

    // 9. Overwriting an occupied slot drops a closure that will never run.
    func testEnqueueOverAPendingSlotReportsReplacement() async {
        let sender = RestSender()
        let events = RestEventLog()
        let scope = RestScope(roomID: "room-a", owner: .composer)

        // Park an unrelated scope so nothing for `scope` can start.
        let gate = await parkBlockingWork(
            on: sender, scope: RestScope(roomID: "__park__", owner: .composer),
            events: events)

        let first = await sender.enqueue(scope: scope) { _ in events.record("FIRST") }
        let second = await sender.enqueue(scope: scope) { _ in events.record("SECOND") }

        gate.release()
        await drain(sender)

        XCTAssertFalse(first.replacedPending, "first enqueue into an empty slot")
        XCTAssertTrue(second.replacedPending, "second enqueue overwrote a pending closure")
        XCTAssertEqual(events.entries, ["gate", "SECOND"],
            "the reported replacement is real — FIRST never ran")
    }

    // 10. THE DISTINCTION THAT CANNOT BE INFERRED: once flush has dequeued an
    //     item, the slot is empty again, so enqueueing over an EXECUTING item
    //     replaces nothing. A caller guessing from its own "not yet started"
    //     bookkeeping would wrongly call this a replacement.
    func testEnqueueWhilePriorWorkIsExecutingReportsNoReplacement() async {
        let sender = RestSender()
        let events = RestEventLog()
        let scope = RestScope(roomID: "room-a", owner: .composer)

        // Park THIS scope: its closure is dequeued and running, slot now empty.
        let gate = await parkBlockingWork(
            on: sender, scope: scope, events: events, label: "EXEC")

        let result = await sender.enqueue(scope: scope) { _ in events.record("NEXT") }

        gate.release()
        await drain(sender)

        XCTAssertFalse(result.replacedPending, """
            the executing closure had already left the pending slot, so nothing \
            was dropped — reporting true here would count a send that did happen \
            as superseded
            """)
        XCTAssertEqual(events.entries, ["EXEC", "NEXT"],
            "both closures ran; neither was dropped")
    }

    // 11. clear reports removal only when it actually removed pending work.
    func testClearReportsRemovalOnlyForActualPendingWork() async {
        let sender = RestSender()
        let events = RestEventLog()
        let scope = RestScope(roomID: "room-a", owner: .composer)

        let gate = await parkBlockingWork(
            on: sender, scope: RestScope(roomID: "__park__", owner: .composer),
            events: events)
        await enqueueRecording(on: sender, scope: scope, events: events, "A")

        let removedReal = await sender.clear(scope: scope)
        let removedAgain = await sender.clear(scope: scope)
        let removedUnknown = await sender.clear(
            scope: RestScope(roomID: "never-seen", owner: .composer))

        gate.release()
        await drain(sender)

        XCTAssertTrue(removedReal, "pending work was dropped")
        XCTAssertFalse(removedAgain, "the slot was already empty")
        XCTAssertFalse(removedUnknown, "this sender has never seen that scope")
        XCTAssertEqual(events.entries, ["gate"], "A never ran")
    }

    // 12. An EXECUTING-only scope reports false — nothing was dropped — but is
    //     still invalidated. Both halves matter: the count must not include it,
    //     and packet 3's cancellation must still fire.
    func testClearOfAnExecutingOnlyScopeReportsFalseButStillInvalidates() async {
        let sender = RestSender()
        let events = RestEventLog()
        let probeBox = RestProbeBox()
        let scope = RestScope(roomID: "room-a", owner: .composer)

        let gate = await parkBlockingWork(
            on: sender, scope: scope, events: events, probeBox: probeBox)

        let removed = await sender.clear(scope: scope)

        XCTAssertFalse(removed,
            "no pending closure was dropped — the work had already started")
        let stillCurrent = await probeBox.probe?()
        XCTAssertEqual(stillCurrent, false,
            "the executing closure is still invalidated: its probe flips to false")

        gate.release()
        await drain(sender)
    }

    // 13. clearAll returns exactly its PENDING scopes, excluding executing-only
    //     ones, while still invalidating everything it knows about.
    func testClearAllReturnsOnlyPendingScopesButInvalidatesExecutingOnes() async {
        let sender = RestSender()
        let events = RestEventLog()
        let probeBox = RestProbeBox()
        let executing = RestScope(roomID: "room-exec", owner: .composer)
        let pendingA = RestScope(roomID: "room-a", owner: .composer)
        let pendingB = RestScope(roomID: "room-b", owner: .studio)

        let gate = await parkBlockingWork(
            on: sender, scope: executing, events: events, probeBox: probeBox)
        await enqueueRecording(on: sender, scope: pendingA, events: events, "A")
        await enqueueRecording(on: sender, scope: pendingB, events: events, "B")

        let removed = await sender.clearAll()

        XCTAssertEqual(removed, [pendingA, pendingB], """
            only scopes whose pending work was actually dropped — the executing \
            scope lost nothing and must not be counted as cancelled-before-start
            """)
        XCTAssertFalse(removed.contains(executing), "executing-only scope excluded")

        let stillCurrent = await probeBox.probe?()
        XCTAssertEqual(stillCurrent, false,
            "the executing closure is invalidated even though it is not returned")

        gate.release()
        await drain(sender)

        XCTAssertEqual(events.entries, ["gate"], "neither A nor B ran")
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
