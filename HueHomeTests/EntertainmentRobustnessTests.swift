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

    /// Runs once, AFTER a GET has captured its answer — the deterministic way
    /// to model "the world moved on between the read and what the reader does
    /// with it", with no timing at all.
    private var _onGetOnce: (() -> Void)?
    func onGetOnce(_ block: @escaping () -> Void) {
        lock.lock(); _onGetOnce = block; lock.unlock()
    }

    override func get(path: String, ip: String, token: String) async throws -> Data {
        lock.lock()
        _getPaths.append(path)
        let after = _onGetOnce
        _onGetOnce = nil
        lock.unlock()
        defer { after?() }
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

    // Packet 7 ownership seams. Ownership decisions turn on whether a PUT
    // actually SUCCEEDED, so a test needs to fail one precisely — all PUTs, a
    // typed transport error rather than an HTTP one, or the stop for one exact
    // configuration while its neighbour's still succeeds.
    var putShouldFail = false
    /// When set, thrown instead of `HueAPIError.httpError` — an unknown
    /// outcome rather than a definitive refusal.
    var putError: Error?
    /// `action=stop` fails for exactly these configuration ids.
    var failStopsFor: Set<String> = []
    /// Observed at the network boundary, before the action is recorded, so a
    /// test can ask what ownership looked like at that exact instant.
    var onPut: ((_ configID: String, _ action: String) -> Void)?
    /// Fires once, INSIDE the PUT — i.e. while cleanup still holds its claim
    /// and the stop is in flight. That is the only window in which the race
    /// this guards against can actually happen.
    private var _onPutOnce: ((String, String) -> Void)?
    func onPutOnce(_ block: @escaping (String, String) -> Void) {
        lock.lock(); _onPutOnce = block; lock.unlock()
    }

    override func put(path: String, body: [String: Any], ip: String, token: String) async throws -> Data {
        if path.contains("entertainment_configuration/"),
           let action = body["action"] as? String,
           let configID = path.split(separator: "/").last.map(String.init) {
            onPut?(configID, action)
            lock.lock(); let once = _onPutOnce; _onPutOnce = nil; lock.unlock()
            once?(configID, action)
            lock.lock()
            _actions.append((configID, action))
            let failThisStop = action == "stop" && failStopsFor.contains(configID)
            lock.unlock()
            if putShouldFail || failThisStop {
                throw putError ?? HueAPIError.httpError(500)
            }
        }
        if putShouldFail { throw putError ?? HueAPIError.httpError(500) }
        return Data("{}".utf8)
    }

    // Packet 4 prime seams: the Composer startup prime is exactly this PUT.
    // A test can HOLD it at the network boundary (the gated-network stale-prime
    // guard) or FAIL it (the thrown-prime guard).
    private var _groupedEffectHold: RestGate?
    func stageGroupedEffectHold(_ gate: RestGate?) {
        lock.lock(); _groupedEffectHold = gate; lock.unlock()
    }
    var groupedEffectShouldFail = false
    override func setGroupedLightEffect(
        id: String, on: Bool?, brightness: Double?,
        xy: (Double, Double)?, mirek: Int?, duration: Int
    ) async throws {
        lock.lock()
        let hold = _groupedEffectHold
        let fail = groupedEffectShouldFail
        lock.unlock()
        if let hold {
            hold.signalStarted()
            await hold.waitForRelease()
        }
        if fail { throw HueAPIError.httpError(500) }
    }
}

// MARK: - Tests

final class EntertainmentRobustnessTests: XCTestCase {

    /// Ownership lives in an isolated suite: these tests must never read or
    /// write the real user's persisted records, and each test must start from
    /// a known-empty registry rather than whatever the previous one left.
    private var ownership: EntertainmentSessionOwnership!
    private let suiteName = "EntertainmentRobustnessTests"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        ownership = EntertainmentSessionOwnership(defaults: defaults)
        ownership.resetForTesting()
    }

    override func tearDown() {
        ownership.resetForTesting()
        ownership = nil
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// A client wired to this test's isolated ownership store. The client key
    /// is deliberately non-hex, so `decodePSK` refuses before any socket
    /// exists — the DTLS handshake is never reached, while the REST activation
    /// the ordering assertions read still runs for real.
    private func makeClient(bridgeID: String = "bridge-1",
                            spy: EntertainmentSpyClient) -> HueEntertainmentClient {
        HueEntertainmentClient(bridgeID: bridgeID,
                               bridgeIP: "192.0.2.1",
                               username: "user",
                               clientKeyHex: "ZZ-not-hex",
                               restClient: spy,
                               ownership: ownership)
    }

    private func spyClient(bridgeID: String = "bridge-1",
                           ip: String = "192.0.2.1") -> EntertainmentSpyClient {
        EntertainmentSpyClient(bridgeID: bridgeID, bridgeName: "Test", ip: ip, token: "t")
    }

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
        let spy = spyClient()
        // Invalid (non-hex) client key → openDTLSConnection throws before any
        // network I/O, exercising the failed-open path deterministically.
        let client = makeClient(spy: spy)

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
        XCTAssertFalse(ownership.isProcessOwned(bridgeID: "bridge-1", configID: "cfg-fail"),
            "a failed session must not stay registered as app-owned")
    }

    // ──────────────────────────────────────────────
    // MARK: - M-06: app-owned sessions excluded from stuck cleanup
    // ──────────────────────────────────────────────

    @MainActor
    func testStuckCleanupSkipsAppOwnedSessionAndStopsStaleOne() async {
        let spy = spyClient()
        spy.stubConfigsJSON = """
        {"data": [
            {"id": "cfg-ours",  "status": "active"},
            {"id": "cfg-stale", "status": "active"},
            {"id": "cfg-idle",  "status": "inactive"}
        ]}
        """
        let orchestrator = UnifiedOrchestrator()
        orchestrator.injectForTesting(clients: ["bridge-1": spy])
        orchestrator.injectForTesting(ownership: ownership)

        ownership.registerProcess(bridgeID: "bridge-1", configID: "cfg-ours")
        // "Stale" now means something specific: recorded by ChromaGlow, not
        // owned by this process. An unrecorded active config is FOREIGN and is
        // covered by the packet 7 tests below.
        ownership.recordPersisted(bridgeID: "bridge-1", configID: "cfg-stale")

        await orchestrator.deactivateStuckEntertainmentSessions()

        let stopped = spy.actions.filter { $0.action == "stop" }.map(\.configID)
        XCTAssertEqual(stopped, ["cfg-stale"],
            "cleanup must stop the stale session and NEVER the app's own active one (M-06)")
    }

    func testSessionRegistryRegisterUnregister() {
        XCTAssertFalse(ownership.isProcessOwned(bridgeID: "b1", configID: "cfg-x"))
        ownership.registerProcess(bridgeID: "b1", configID: "cfg-x")
        XCTAssertTrue(ownership.isProcessOwned(bridgeID: "b1", configID: "cfg-x"))
        ownership.releaseProcess(bridgeID: "b1", configID: "cfg-x")
        XCTAssertFalse(ownership.isProcessOwned(bridgeID: "b1", configID: "cfg-x"))
    }

    func testSessionRegistryIsRefCounted() {
        // Two client instances can stream the same configuration (Sync +
        // Studio) — one stopping must not expose the other to the cleanup.
        ownership.registerProcess(bridgeID: "b1", configID: "cfg-rc")
        ownership.registerProcess(bridgeID: "b1", configID: "cfg-rc")

        let first = ownership.releaseProcess(bridgeID: "b1", configID: "cfg-rc")
        XCTAssertFalse(first.wasFinalOwner,
            "the first of two owners is not the final owner and may not stop the session")
        XCTAssertEqual(first.remaining, 1)
        XCTAssertTrue(ownership.isProcessOwned(bridgeID: "b1", configID: "cfg-rc"),
            "one remaining owner must keep the session protected")

        let second = ownership.releaseProcess(bridgeID: "b1", configID: "cfg-rc")
        XCTAssertTrue(second.wasFinalOwner, "the last owner out may stop the session")
        XCTAssertEqual(second.remaining, 0)
        XCTAssertFalse(ownership.isProcessOwned(bridgeID: "b1", configID: "cfg-rc"))

        // Extra release must not underflow into protecting ghosts — nor claim
        // final ownership, which would authorize stopping someone else's work.
        let extra = ownership.releaseProcess(bridgeID: "b1", configID: "cfg-rc")
        XCTAssertFalse(extra.wasFinalOwner,
            "an unbalanced release must never authorize a stop")
        XCTAssertFalse(ownership.isProcessOwned(bridgeID: "b1", configID: "cfg-rc"))
    }

    // ──────────────────────────────────────────────
    // MARK: - M-10 follow-through: terminal failure drives REST failover
    // ──────────────────────────────────────────────

    func testTerminalFailureTearsDownFlagsAndResetsOnRestart() async {
        let spy = spyClient()
        let client = makeClient(spy: spy)
        await client.seedSessionForTesting(configID: "cfg-term")

        await client.noteTerminalFailure()

        let failed = await client.isTerminallyFailed
        XCTAssertTrue(failed,
            "terminal failure must be observable so owning render loops can fail over to REST")
        XCTAssertEqual(spy.actions.map(\.action), ["stop"],
            "abandonment must best-effort stop the configuration on the bridge")
        XCTAssertFalse(ownership.isProcessOwned(bridgeID: "bridge-1", configID: "cfg-term"),
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
        let spy = spyClient()
        let client = makeClient(spy: spy)
        _ = try? await client.startSession(configID: "cfg-race")
        XCTAssertFalse(ownership.isProcessOwned(bridgeID: "bridge-1", configID: "cfg-race"),
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
// MARK: - Composer 2 packet 7: ChromaGlow yields to third-party sessions
// ═══════════════════════════════════════════════════════════════════════
//
// The defect: automatic cleanup treated EVERY active entertainment
// configuration this process had not registered as "stuck" and sent
// action=stop. It runs from loadAll on launch, foreground, and every state
// refresh — so a Hue Sync Box or another Hue app streaming on the bridge was
// silently evicted although the ChromaGlow user never asked for playback.
//
// Two things were missing, and a process-only refcount could supply neither:
//   1. bridge identity — a configuration UUID recorded on bridge A said
//      nothing about the same UUID on bridge B, yet authorized stopping it;
//   2. survival — a refcount dies with the process, so a session ChromaGlow
//      left active after an unclean termination was indistinguishable from a
//      stranger's.
//
// Everything here is proved by observing recorded PUTs and registry state, in
// an isolated UserDefaults suite. No sleeps, no waiters, no elapsed time.
//
// Review: docs/ios/composer2-architecture-review-2026-08-01.md (K1 / N4).

final class EntertainmentOwnershipTests: XCTestCase {

    private var ownership: EntertainmentSessionOwnership!
    private let suiteName = "EntertainmentOwnershipTests"

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        ownership = EntertainmentSessionOwnership(defaults: defaults)
        ownership.resetForTesting()
    }

    override func tearDown() {
        ownership.resetForTesting()
        ownership = nil
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: Fixtures

    private func spy(bridgeID: String = "bridge-1",
                     ip: String = "192.0.2.1") -> EntertainmentSpyClient {
        EntertainmentSpyClient(bridgeID: bridgeID, bridgeName: "Test", ip: ip, token: "t")
    }

    private func client(bridgeID: String = "bridge-1",
                        spy: EntertainmentSpyClient) -> HueEntertainmentClient {
        HueEntertainmentClient(bridgeID: bridgeID,
                               bridgeIP: "192.0.2.1",
                               username: "user",
                               clientKeyHex: "ZZ-not-hex",
                               restClient: spy,
                               ownership: ownership)
    }

    private func activeJSON(_ ids: [String], inactive: [String] = []) -> String {
        let active = ids.map { #"{"id": "\#($0)", "status": "active"}"# }
        let idle = inactive.map { #"{"id": "\#($0)", "status": "inactive"}"# }
        return #"{"data": [\#((active + idle).joined(separator: ", "))]}"#
    }

    @MainActor
    private func orchestrator(_ clients: [String: EntertainmentSpyClient]) -> UnifiedOrchestrator {
        let o = UnifiedOrchestrator()
        o.injectForTesting(clients: clients)
        o.injectForTesting(ownership: ownership)
        return o
    }

    private func stops(_ spy: EntertainmentSpyClient) -> [String] {
        spy.actions.filter { $0.action == "stop" }.map(\.configID)
    }

    // ──────────────────────────────────────────────
    // MARK: - Automatic cleanup never disturbs a foreign session
    // ──────────────────────────────────────────────

    /// P7-01
    @MainActor
    func testAutomaticCleanupLeavesAForeignActiveConfigurationUntouched() async {
        let bridge = spy()
        bridge.stubConfigsJSON = activeJSON(["cfg-someone-else"])
        let orchestrator = orchestrator(["bridge-1": bridge])

        await orchestrator.deactivateStuckEntertainmentSessions()

        XCTAssertTrue(stops(bridge).isEmpty,
            "an active configuration ChromaGlow never recorded belongs to another controller — cleanup must not stop it")
    }

    /// P7-02 — a background pass must be entirely read-only over a foreign
    /// session: no stop, and equally no start. (That it also raises no consent
    /// prompt is locked once the prompt exists — see P7-25.)
    @MainActor
    func testAutomaticCleanupWritesNothingAtAllForAForeignSession() async {
        let bridge = spy()
        bridge.stubConfigsJSON = activeJSON(["cfg-someone-else"])
        let orchestrator = orchestrator(["bridge-1": bridge])

        await orchestrator.deactivateStuckEntertainmentSessions()

        XCTAssertTrue(bridge.actions.isEmpty,
            "cleanup may only READ a bridge whose active session belongs to someone else")
    }

    /// P7-03
    @MainActor
    func testAutomaticCleanupStopsAPersistedChromaGlowOwnedStaleConfiguration() async {
        let bridge = spy()
        bridge.stubConfigsJSON = activeJSON(["cfg-ours-stale", "cfg-foreign"])
        ownership.recordPersisted(bridgeID: "bridge-1", configID: "cfg-ours-stale")
        let orchestrator = orchestrator(["bridge-1": bridge])

        await orchestrator.deactivateStuckEntertainmentSessions()

        XCTAssertEqual(stops(bridge), ["cfg-ours-stale"],
            "only the session ChromaGlow recorded as its own may be cleaned up")
    }

    /// P7-04 — the whole reason ownership is keyed by bridge AND configuration.
    @MainActor
    func testAPersistedRecordOnBridgeACannotAuthorizeStoppingTheSameIDOnBridgeB() async {
        let a = spy(bridgeID: "bridge-a", ip: "192.0.2.1")
        let b = spy(bridgeID: "bridge-b", ip: "192.0.2.2")
        // The SAME configuration id is active on both bridges; only bridge A's
        // is ours.
        a.stubConfigsJSON = activeJSON(["cfg-shared"])
        b.stubConfigsJSON = activeJSON(["cfg-shared"])
        ownership.recordPersisted(bridgeID: "bridge-a", configID: "cfg-shared")
        let orchestrator = orchestrator(["bridge-a": a, "bridge-b": b])

        await orchestrator.deactivateStuckEntertainmentSessions()

        XCTAssertEqual(stops(a), ["cfg-shared"], "bridge A's session is ours")
        XCTAssertTrue(stops(b).isEmpty,
            "the same configuration id on another bridge is a different session, and this one is a stranger's")
    }

    /// P7-05
    @MainActor
    func testACurrentlyProcessOwnedConfigurationIsSkipped() async {
        let bridge = spy()
        bridge.stubConfigsJSON = activeJSON(["cfg-live"])
        ownership.registerProcess(bridgeID: "bridge-1", configID: "cfg-live")
        ownership.recordPersisted(bridgeID: "bridge-1", configID: "cfg-live")
        let orchestrator = orchestrator(["bridge-1": bridge])

        await orchestrator.deactivateStuckEntertainmentSessions()

        XCTAssertTrue(stops(bridge).isEmpty,
            "cleanup used to kill the app's own running show mid-stream")
        XCTAssertTrue(ownership.isPersisted(bridgeID: "bridge-1", configID: "cfg-live"),
            "a live session keeps its record")
    }

    /// P7-06
    @MainActor
    func testAnInactivePersistedRecordIsPrunedWithoutSendingStop() async {
        let bridge = spy()
        bridge.stubConfigsJSON = activeJSON([], inactive: ["cfg-done"])
        ownership.recordPersisted(bridgeID: "bridge-1", configID: "cfg-done")
        let orchestrator = orchestrator(["bridge-1": bridge])

        await orchestrator.deactivateStuckEntertainmentSessions()

        XCTAssertTrue(stops(bridge).isEmpty,
            "the bridge already reports it inactive — stopping it again is a pointless write")
        XCTAssertFalse(ownership.isPersisted(bridgeID: "bridge-1", configID: "cfg-done"),
            "proved inactive means the evidence has done its job")
    }

    /// P7-06b — a record whose configuration the bridge no longer lists at all.
    @MainActor
    func testAPersistedRecordForAnAbsentConfigurationIsPruned() async {
        let bridge = spy()
        bridge.stubConfigsJSON = activeJSON([])
        ownership.recordPersisted(bridgeID: "bridge-1", configID: "cfg-deleted")
        let orchestrator = orchestrator(["bridge-1": bridge])

        await orchestrator.deactivateStuckEntertainmentSessions()

        XCTAssertTrue(stops(bridge).isEmpty)
        XCTAssertFalse(ownership.isPersisted(bridgeID: "bridge-1", configID: "cfg-deleted"))
    }

    /// P7-07
    @MainActor
    func testABridgeFetchFailureRetainsThePersistedRecordForRetry() async {
        let bridge = spy()
        bridge.configsShouldFail = true
        ownership.recordPersisted(bridgeID: "bridge-1", configID: "cfg-ours")
        let orchestrator = orchestrator(["bridge-1": bridge])

        await orchestrator.deactivateStuckEntertainmentSessions()

        XCTAssertTrue(stops(bridge).isEmpty, "an unreadable bridge authorizes nothing")
        XCTAssertTrue(ownership.isPersisted(bridgeID: "bridge-1", configID: "cfg-ours"),
            "unknown is not 'gone' — the record must survive for a later launch to retry")
    }

    /// P7-07b — one bridge failing must not blind the others.
    @MainActor
    func testOneBridgesFailureDoesNotPreventClassificationOfOtherBridges() async {
        let a = spy(bridgeID: "bridge-a", ip: "192.0.2.1")
        let b = spy(bridgeID: "bridge-b", ip: "192.0.2.2")
        a.configsShouldFail = true
        b.stubConfigsJSON = activeJSON(["cfg-b-stale"])
        ownership.recordPersisted(bridgeID: "bridge-a", configID: "cfg-a-ours")
        ownership.recordPersisted(bridgeID: "bridge-b", configID: "cfg-b-stale")
        let orchestrator = orchestrator(["bridge-a": a, "bridge-b": b])

        await orchestrator.deactivateStuckEntertainmentSessions()

        XCTAssertEqual(stops(b), ["cfg-b-stale"],
            "bridge B is readable and its stale session must still be cleaned up")
        XCTAssertTrue(ownership.isPersisted(bridgeID: "bridge-a", configID: "cfg-a-ours"))
    }

    /// P7-08
    @MainActor
    func testASuccessfulStopRemovesPersistedOwnership() async {
        let bridge = spy()
        bridge.stubConfigsJSON = activeJSON(["cfg-ours-stale"])
        ownership.recordPersisted(bridgeID: "bridge-1", configID: "cfg-ours-stale")
        let orchestrator = orchestrator(["bridge-1": bridge])

        await orchestrator.deactivateStuckEntertainmentSessions()

        XCTAssertEqual(stops(bridge), ["cfg-ours-stale"])
        XCTAssertFalse(ownership.isPersisted(bridgeID: "bridge-1", configID: "cfg-ours-stale"),
            "a confirmed stop retires the record")
    }

    /// P7-09
    @MainActor
    func testAFailedStopRetainsPersistedOwnership() async {
        let bridge = spy()
        bridge.stubConfigsJSON = activeJSON(["cfg-ours-stale"])
        bridge.putShouldFail = true
        ownership.recordPersisted(bridgeID: "bridge-1", configID: "cfg-ours-stale")
        let orchestrator = orchestrator(["bridge-1": bridge])

        await orchestrator.deactivateStuckEntertainmentSessions()

        XCTAssertTrue(ownership.isPersisted(bridgeID: "bridge-1", configID: "cfg-ours-stale"),
            "the configuration may still be active — dropping the record would strand it forever")
    }

    /// P7-38 — one failing stop must not skip the rest of the stale set.
    @MainActor
    func testEveryPersistedStaleIDIsHandledIndependently() async {
        let bridge = spy()
        bridge.stubConfigsJSON = activeJSON(["cfg-a", "cfg-b", "cfg-foreign"])
        bridge.failStopsFor = ["cfg-a"]
        ownership.recordPersisted(bridgeID: "bridge-1", configID: "cfg-a")
        ownership.recordPersisted(bridgeID: "bridge-1", configID: "cfg-b")
        let orchestrator = orchestrator(["bridge-1": bridge])

        await orchestrator.deactivateStuckEntertainmentSessions()

        XCTAssertEqual(Set(stops(bridge)), ["cfg-a", "cfg-b"],
            "cfg-a's failure must not abort the pass before cfg-b")
        XCTAssertTrue(ownership.isPersisted(bridgeID: "bridge-1", configID: "cfg-a"))
        XCTAssertFalse(ownership.isPersisted(bridgeID: "bridge-1", configID: "cfg-b"))
    }

    /// P7-39 — the real race is not "after the initial GET", it is "after
    /// cleanup has taken the right to destroy". The gate therefore opens on
    /// the PUT: cleanup has claimed the session and is about to stop it, and a
    /// brand-new client tries to start that exact session right then.
    @MainActor
    func testAClientCannotStartASessionCleanupHasClaimed() async {
        let bridge = spy()
        bridge.stubConfigsJSON = activeJSON(["cfg-ours"])
        ownership.recordPersisted(bridgeID: "bridge-1", configID: "cfg-ours")
        let orchestrator = orchestrator(["bridge-1": bridge])

        let attempt = StartAttemptProbe()
        // Fires while the claim is held and the stop is in flight.
        bridge.onPutOnce { [ownership] configID, action in
            guard action == "stop", configID == "cfg-ours" else { return }
            attempt.record(
                claimHeld: ownership!.hasCleanupClaim(bridgeID: "bridge-1", configID: "cfg-ours"),
                registration: ownership!.registerProcess(bridgeID: "bridge-1", configID: "cfg-ours"))
        }

        await orchestrator.deactivateStuckEntertainmentSessions()

        XCTAssertEqual(attempt.claimHeld, true,
            "cleanup must hold an exclusive claim while its stop is in flight")
        XCTAssertEqual(attempt.registration, .blockedByCleanup,
            "a start may not register underneath a claim — that is the owner cleanup is about to black out")
        XCTAssertFalse(ownership.isProcessOwned(bridgeID: "bridge-1", configID: "cfg-ours"),
            "and so no owner exists for cleanup to have destroyed")
        XCTAssertEqual(stops(bridge), ["cfg-ours"], "the claimed stale session is stopped exactly once")
        XCTAssertFalse(ownership.isPersisted(bridgeID: "bridge-1", configID: "cfg-ours"))
    }

    /// P7-39b — a blocked registration must not reach action=start. The client
    /// refuses rather than racing the stop.
    func testAStartRefusesWhileCleanupHoldsTheClaim() async {
        let bridge = spy()
        ownership.recordPersisted(bridgeID: "bridge-1", configID: "cfg-claimed")
        XCTAssertNotNil(ownership.beginStaleCleanup(bridgeID: "bridge-1", configID: "cfg-claimed"),
            "cleanup takes the exclusive right to stop this session")

        let client = client(spy: bridge)
        do {
            try await client.startSession(configID: "cfg-claimed")
            XCTFail("a start must refuse while cleanup holds the claim")
        } catch {
            // expected
        }

        XCTAssertTrue(bridge.actions.isEmpty,
            "no action=start may be sent — refusing means touching nothing")
        XCTAssertFalse(ownership.isProcessOwned(bridgeID: "bridge-1", configID: "cfg-claimed"))
    }

    /// P7-39c — the claim is exclusive and released afterwards, so ordinary
    /// starts resume immediately.
    @MainActor
    func testAfterTheClaimIsReleasedANewStartProceedsNormally() async {
        ownership.recordPersisted(bridgeID: "bridge-1", configID: "cfg-x")
        let first = ownership.beginStaleCleanup(bridgeID: "bridge-1", configID: "cfg-x")
        XCTAssertNotNil(first, "the first claimant wins")
        XCTAssertNil(ownership.beginStaleCleanup(bridgeID: "bridge-1", configID: "cfg-x"),
            "a second cleanup may not claim the same session concurrently")
        XCTAssertEqual(ownership.registerProcess(bridgeID: "bridge-1", configID: "cfg-x"),
                       .blockedByCleanup)

        ownership.endStaleCleanup(first!)

        XCTAssertFalse(ownership.hasCleanupClaim(bridgeID: "bridge-1", configID: "cfg-x"))
        XCTAssertEqual(ownership.registerProcess(bridgeID: "bridge-1", configID: "cfg-x"),
                       .registered, "with the claim gone, a start proceeds normally")
    }

    /// P7-39d — a claim on one key leaves every other key alone.
    func testACleanupClaimIsScopedToItsExactBridgeAndConfiguration() {
        ownership.recordPersisted(bridgeID: "bridge-a", configID: "cfg-shared")
        let claim = ownership.beginStaleCleanup(bridgeID: "bridge-a", configID: "cfg-shared")
        XCTAssertNotNil(claim)

        XCTAssertEqual(ownership.registerProcess(bridgeID: "bridge-b", configID: "cfg-shared"),
                       .registered, "same configuration id, different bridge — independent")
        XCTAssertEqual(ownership.registerProcess(bridgeID: "bridge-a", configID: "cfg-other"),
                       .registered, "same bridge, different configuration — independent")
    }

    /// P7-40 — a live owner and a missing record are both refusals of the
    /// claim itself, so authorization is one operation rather than two facts
    /// with a gap between them.
    func testTheClaimRefusesAnOwnedOrUnrecordedSession() {
        // Owned: not stale, whatever the snapshot said.
        ownership.recordPersisted(bridgeID: "bridge-1", configID: "cfg-live")
        ownership.registerProcess(bridgeID: "bridge-1", configID: "cfg-live")
        XCTAssertNil(ownership.beginStaleCleanup(bridgeID: "bridge-1", configID: "cfg-live"),
            "a session with a live owner is not stale state")

        // Unrecorded: an active configuration ChromaGlow never recorded is
        // foreign, and foreign is never ours to stop.
        XCTAssertNil(ownership.beginStaleCleanup(bridgeID: "bridge-1", configID: "cfg-stranger"),
            "without evidence there is no authorization to destroy anything")
    }

    /// P7-40b — cleanup cannot stop a session that registered before the claim.
    @MainActor
    func testCleanupCannotStopAnOwnerThatRegisteredFirst() async {
        let bridge = spy()
        bridge.stubConfigsJSON = activeJSON(["cfg-ours"])
        ownership.recordPersisted(bridgeID: "bridge-1", configID: "cfg-ours")
        // The owner wins the race by registering before cleanup runs at all.
        XCTAssertEqual(ownership.registerProcess(bridgeID: "bridge-1", configID: "cfg-ours"),
                       .registered)
        let orchestrator = orchestrator(["bridge-1": bridge])

        await orchestrator.deactivateStuckEntertainmentSessions()

        XCTAssertTrue(stops(bridge).isEmpty, "a registered owner is never stale")
        XCTAssertTrue(ownership.isProcessOwned(bridgeID: "bridge-1", configID: "cfg-ours"))
        XCTAssertTrue(ownership.isPersisted(bridgeID: "bridge-1", configID: "cfg-ours"))
    }

    // ──────────────────────────────────────────────
    // MARK: - Registration lifecycle
    // ──────────────────────────────────────────────

    /// P7-10 — the bridge reports a configuration active the moment
    /// action=start lands, so ownership must already be installed by then or a
    /// concurrent cleanup can stop our own session during the handshake.
    func testRegistrationIsInstalledBeforeActionStartIsObservable() async {
        let bridge = spy()
        let recorded = ActionOwnershipProbe()
        bridge.onPut = { [ownership] configID, action in
            guard action == "start" else { return }
            recorded.record(
                process: ownership!.isProcessOwned(bridgeID: "bridge-1", configID: configID),
                persisted: ownership!.isPersisted(bridgeID: "bridge-1", configID: configID))
        }
        let client = client(spy: bridge)

        _ = try? await client.startSession(configID: "cfg-order")

        XCTAssertEqual(recorded.snapshot?.process, true,
            "process ownership must be visible to a concurrent cleanup before action=start")
        XCTAssertEqual(recorded.snapshot?.persisted, true,
            "persisted ownership must land before activation too — a crash one instruction later still leaves OUR session active")
    }

    /// P7-11 — the bridge answered and refused: nothing was activated, so both
    /// layers must balance.
    func testADefinitiveActivationFailureBalancesOwnership() async {
        let bridge = spy()
        bridge.putShouldFail = true          // HueAPIError.httpError — typed, definitive
        let client = client(spy: bridge)

        _ = try? await client.startSession(configID: "cfg-refused")

        XCTAssertFalse(ownership.isProcessOwned(bridgeID: "bridge-1", configID: "cfg-refused"))
        XCTAssertFalse(ownership.isPersisted(bridgeID: "bridge-1", configID: "cfg-refused"),
            "a definitive refusal leaves nothing on the bridge to clean up later")
    }

    /// P7-11b — an unknown outcome is NOT a refusal. Keep the evidence.
    func testAnIndefiniteActivationFailureRetainsPersistedOwnership() async {
        let bridge = spy()
        bridge.putShouldFail = true
        bridge.putError = URLError(.timedOut)   // transport — outcome unknown
        let client = client(spy: bridge)

        _ = try? await client.startSession(configID: "cfg-maybe")

        XCTAssertFalse(ownership.isProcessOwned(bridgeID: "bridge-1", configID: "cfg-maybe"),
            "this client is not streaming, so it holds no process reference")
        XCTAssertTrue(ownership.isPersisted(bridgeID: "bridge-1", configID: "cfg-maybe"),
            "the activation may have landed — a later launch must be able to find and stop it")
    }

    /// P7-12 — a failed DTLS open runs the compensating stop; the record's fate
    /// follows whether that stop succeeded.
    func testAFailedDTLSOpenCompensatingStopSucceeded() async {
        let bridge = spy()
        let client = client(spy: bridge)

        _ = try? await client.startSession(configID: "cfg-dtls")

        XCTAssertEqual(bridge.actions.map(\.action), ["start", "stop"])
        XCTAssertFalse(ownership.isProcessOwned(bridgeID: "bridge-1", configID: "cfg-dtls"))
        XCTAssertFalse(ownership.isPersisted(bridgeID: "bridge-1", configID: "cfg-dtls"),
            "the compensating stop was confirmed, so nothing is left to remember")
    }

    /// P7-12b
    func testAFailedDTLSOpenWhoseCompensatingStopFailedKeepsTheRecord() async {
        let bridge = spy()
        bridge.failStopsFor = ["cfg-dtls"]
        let client = client(spy: bridge)

        _ = try? await client.startSession(configID: "cfg-dtls")

        XCTAssertFalse(ownership.isProcessOwned(bridgeID: "bridge-1", configID: "cfg-dtls"))
        XCTAssertTrue(ownership.isPersisted(bridgeID: "bridge-1", configID: "cfg-dtls"),
            "the configuration was activated and the stop failed — it is still ours to clean up")
    }

    /// P7-13
    func testReferenceCountingIsExactForTwoClientsOnOneBridgeAndConfiguration() {
        ownership.registerProcess(bridgeID: "b", configID: "cfg")
        ownership.registerProcess(bridgeID: "b", configID: "cfg")

        XCTAssertEqual(ownership.releaseProcess(bridgeID: "b", configID: "cfg"),
                       EntertainmentProcessRelease(wasFinalOwner: false, remaining: 1))
        XCTAssertTrue(ownership.isProcessOwned(bridgeID: "b", configID: "cfg"))
        XCTAssertEqual(ownership.releaseProcess(bridgeID: "b", configID: "cfg"),
                       EntertainmentProcessRelease(wasFinalOwner: true, remaining: 0))
        XCTAssertFalse(ownership.isProcessOwned(bridgeID: "b", configID: "cfg"))
    }

    /// P7-14
    func testSameConfigurationIDOnTwoBridgesIsIndependent() {
        ownership.registerProcess(bridgeID: "bridge-a", configID: "cfg-shared")
        ownership.recordPersisted(bridgeID: "bridge-a", configID: "cfg-shared")

        XCTAssertFalse(ownership.isProcessOwned(bridgeID: "bridge-b", configID: "cfg-shared"),
            "ownership on one bridge says nothing about another")
        XCTAssertFalse(ownership.isPersisted(bridgeID: "bridge-b", configID: "cfg-shared"))
        XCTAssertEqual(ownership.persistedConfigIDs(onBridge: "bridge-a"), ["cfg-shared"])
        XCTAssertTrue(ownership.persistedConfigIDs(onBridge: "bridge-b").isEmpty)

        // Releasing bridge A's reference must leave bridge B's untouched.
        ownership.registerProcess(bridgeID: "bridge-b", configID: "cfg-shared")
        ownership.releaseProcess(bridgeID: "bridge-a", configID: "cfg-shared")
        XCTAssertTrue(ownership.isProcessOwned(bridgeID: "bridge-b", configID: "cfg-shared"))
    }

    // ──────────────────────────────────────────────
    // MARK: - Final-owner stop semantics
    // ──────────────────────────────────────────────

    /// P7-29 — two live ChromaGlow clients, same bridge + configuration. The
    /// first one out must not black out the second one's stream.
    func testTheFirstOfTwoOwnersStoppingSendsNoActionStop() async {
        let bridge = spy()
        let first = client(spy: bridge)
        let second = client(spy: bridge)
        await first.seedSessionForTesting(configID: "cfg-shared")
        await second.seedSessionForTesting(configID: "cfg-shared")

        await first.stopSession()

        XCTAssertTrue(bridge.actions.filter { $0.action == "stop" }.isEmpty,
            "the other client is still streaming this exact configuration")
        XCTAssertTrue(ownership.isProcessOwned(bridgeID: "bridge-1", configID: "cfg-shared"),
            "the surviving owner keeps the session protected from cleanup")
        XCTAssertTrue(ownership.isPersisted(bridgeID: "bridge-1", configID: "cfg-shared"),
            "persisted ownership must remain while any process owner exists")
    }

    /// P7-30
    func testTheFinalOwnerSendsExactlyOneActionStop() async {
        let bridge = spy()
        let first = client(spy: bridge)
        let second = client(spy: bridge)
        await first.seedSessionForTesting(configID: "cfg-shared")
        await second.seedSessionForTesting(configID: "cfg-shared")

        await first.stopSession()
        await second.stopSession()

        XCTAssertEqual(bridge.actions.filter { $0.action == "stop" }.map(\.configID),
                       ["cfg-shared"],
            "exactly one stop, sent by the last owner out")
        XCTAssertFalse(ownership.isProcessOwned(bridgeID: "bridge-1", configID: "cfg-shared"))
        XCTAssertFalse(ownership.isPersisted(bridgeID: "bridge-1", configID: "cfg-shared"))
    }

    /// P7-31
    func testASecondOwnersActivationFailurePreservesTheFirstOwner() async {
        let bridge = spy()
        let live = client(spy: bridge)
        await live.seedSessionForTesting(configID: "cfg-shared")

        let failing = client(spy: bridge)
        bridge.putShouldFail = true
        _ = try? await failing.startSession(configID: "cfg-shared")

        XCTAssertTrue(ownership.isProcessOwned(bridgeID: "bridge-1", configID: "cfg-shared"),
            "the live client's reference must survive the other client's failure")
        XCTAssertTrue(ownership.isPersisted(bridgeID: "bridge-1", configID: "cfg-shared"),
            "a second owner's failure may not strip the evidence protecting a live session")
        XCTAssertTrue(bridge.actions.filter { $0.action == "stop" }.isEmpty,
            "and it certainly may not stop the live session")
    }

    /// P7-32
    func testASecondOwnersDTLSFailureDoesNotStopTheSharedLiveConfiguration() async {
        let bridge = spy()
        let live = client(spy: bridge)
        await live.seedSessionForTesting(configID: "cfg-shared")

        // Non-hex key: activation succeeds, the DTLS open fails, and the
        // compensating stop runs — as a NON-final release, so it must not fire.
        let failing = client(spy: bridge)
        _ = try? await failing.startSession(configID: "cfg-shared")

        XCTAssertEqual(bridge.actions.map(\.action), ["start"],
            "the compensating rollback must never terminate another live ChromaGlow client's stream")
        XCTAssertTrue(ownership.isProcessOwned(bridgeID: "bridge-1", configID: "cfg-shared"))
        XCTAssertTrue(ownership.isPersisted(bridgeID: "bridge-1", configID: "cfg-shared"))
    }

    // ──────────────────────────────────────────────
    // MARK: - The old rule must not come back
    // ──────────────────────────────────────────────

    /// P7-26 — behavioural tests above would all still pass if someone
    /// reintroduced a configID-only ownership question alongside the scoped
    /// one, so pin the absence of the old rule directly.
    func testNoProductionPathRetainsActiveAndNotProcessOwnedMeansStop() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // HueHomeTests/
            .deletingLastPathComponent()   // repo root

        func code(_ relativePath: String) throws -> String {
            try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
        }

        let orchestrator = try code("HueHome/Core/Network/UnifiedOrchestrator.swift")
        let client = try code("HueHome/Core/Network/HueEntertainmentClient.swift")

        for symbol in ["isAppOwnedSession", "registerActiveSession", "unregisterActiveSession"] {
            XCTAssertFalse(orchestrator.contains(symbol),
                "\(symbol) keyed ownership by configuration alone — bridge-scoped ownership replaced it")
            XCTAssertFalse(client.contains(symbol),
                "\(symbol) keyed ownership by configuration alone — bridge-scoped ownership replaced it")
        }

        XCTAssertTrue(orchestrator.contains("entertainmentOwnership.isProcessOwned(bridgeID:"),
            "cleanup must ask the bridge-scoped question")
        XCTAssertTrue(orchestrator.contains("entertainmentOwnership.isPersisted(bridgeID:"),
            "and must be able to recognise its own orphaned sessions")
    }
}

/// Actor-safe recorder for a start attempted while a cleanup claim is held.
private final class StartAttemptProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _claimHeld: Bool?
    private var _registration: EntertainmentSessionOwnership.ProcessRegistration?

    func record(claimHeld: Bool,
                registration: EntertainmentSessionOwnership.ProcessRegistration) {
        lock.lock(); defer { lock.unlock() }
        if _claimHeld == nil { _claimHeld = claimHeld; _registration = registration }
    }
    var claimHeld: Bool? { lock.lock(); defer { lock.unlock() }; return _claimHeld }
    var registration: EntertainmentSessionOwnership.ProcessRegistration? {
        lock.lock(); defer { lock.unlock() }; return _registration
    }
}

/// Actor-safe one-shot recorder for "what did ownership look like at the exact
/// moment the bridge saw action=start?".
private final class ActionOwnershipProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (process: Bool, persisted: Bool)?

    func record(process: Bool, persisted: Bool) {
        lock.lock(); defer { lock.unlock() }
        if value == nil { value = (process, persisted) }
    }

    var snapshot: (process: Bool, persisted: Bool)? {
        lock.lock(); defer { lock.unlock() }
        return value
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

        await orchestrator.stopCompositionMode(roomID: bedroom.id, bridgeID: bridgeAID)
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

        await orchestrator.stopCompositionMode(roomID: bedroom.id, bridgeID: bridgeAID)
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

        await orchestrator.stopCompositionMode(roomID: bedroom.id, bridgeID: bridgeAID)
    }

    // ──────────────────────────────────────────────
    // MARK: - Composer 2 packet 4: the startup prime's generation gate
    // ──────────────────────────────────────────────

    /// Gated-network stale-prime guard: a generation-1 prime is held at the
    /// network boundary while the room restarts into generation 2. When the
    /// old prime is finally released — and completes SUCCESSFULLY — it must
    /// not mutate the newer runtime's send bookkeeping.
    func testStalePrimeCannotMutateANewerRuntime() async {
        let bedroom = room("bedroom", bridge: bridgeAID, lightIDs: [])
        // The room has already restarted: its live runtime is generation 2.
        orchestrator.testStageRESTComposition(
            roomID: "bedroom", bridgeID: bridgeAID, api: bridgeA, generation: 2)

        let hold = RestGate()
        bridgeA.stageGroupedEffectHold(hold)
        let stalePrime = Task { [orchestrator] in
            await orchestrator!.testPerformCompositionPrime(room: bedroom, generation: 1)
        }
        await hold.waitUntilStarted()   // the generation-1 prime is on the wire
        bridgeA.stageGroupedEffectHold(nil)
        hold.release()                  // …and now completes successfully
        await stalePrime.value

        let state = orchestrator.testCompositionRuntimeSendState(roomID: "bedroom")
        XCTAssertEqual(state?.sendCount, 0, """
            a generation-1 prime completion must not record a send against the \
            generation-2 runtime
            """)
        XCTAssertNil(state?.lastSentX)
        XCTAssertNil(state?.lastSentAt)
    }

    /// A thrown prime records no send; the same prime re-issued by the LIVE
    /// generation records exactly one.
    func testThrownPrimeRecordsNoSendAndAMatchingPrimeRecordsOne() async {
        let bedroom = room("bedroom", bridge: bridgeAID, lightIDs: [])
        orchestrator.testStageRESTComposition(
            roomID: "bedroom", bridgeID: bridgeAID, api: bridgeA, generation: 1)

        bridgeA.groupedEffectShouldFail = true
        await orchestrator.testPerformCompositionPrime(room: bedroom, generation: 1)

        var state = orchestrator.testCompositionRuntimeSendState(roomID: "bedroom")
        XCTAssertEqual(state?.sendCount, 0, "a thrown prime records no send")
        XCTAssertNil(state?.lastSentX)

        bridgeA.groupedEffectShouldFail = false
        await orchestrator.testPerformCompositionPrime(room: bedroom, generation: 1)

        state = orchestrator.testCompositionRuntimeSendState(roomID: "bedroom")
        XCTAssertEqual(state?.sendCount, 1,
            "the live generation's successful prime records exactly one send")
        XCTAssertNotNil(state?.lastSentX)
    }
}
