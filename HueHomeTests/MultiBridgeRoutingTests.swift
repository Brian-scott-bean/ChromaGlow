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
//
// Composer 2 packet 1a widened the remit from "writes go to the right bridge" to
// "ownership is scoped to the right bridge, and is never taken without consent":
// the per-bridge Entertainment gate and the Studio↔Composer handoff prompt.
// Review: docs/ios/composer2-architecture-review-2026-08-01.md (defects 2 and 3).

import XCTest
@testable import HueHome

// MARK: - Spies

/// v1 spy recording resource deletes without touching the network.
///
/// Packet 2 also makes it record every *enumeration* (`fetch*`) and vend stub
/// inventories. Two reasons: "normal playback never enumerates the bridge" is
/// only assertable if the fetches are observable, and an un-overridden fetch
/// would otherwise attempt a real request against the TEST-NET-1 address the
/// spies are built with.
private final class RoutingSpyV1Client: HueV1Client, @unchecked Sendable {
    private let lock = NSLock()
    private var _deletedResources: [String] = []
    private var _fetchCalls: [String] = []
    private var _inventories: [String: [String: [String: Any]]] = [:]

    /// Deletes in the order they were issued ("schedule:33", "rule:22", …).
    var deletedResources: [String] {
        lock.lock(); defer { lock.unlock() }
        return _deletedResources
    }
    /// Bridge-wide enumerations in the order they were issued.
    var fetchCalls: [String] {
        lock.lock(); defer { lock.unlock() }
        return _fetchCalls
    }
    /// Stage what `fetchSchedules`/`fetchRules`/… should report. Empty by default.
    func stageInventory(_ kind: String, _ contents: [String: [String: Any]]) {
        lock.lock(); defer { lock.unlock() }
        _inventories[kind] = contents
    }

    private func record(_ entry: String) {
        lock.lock(); defer { lock.unlock() }
        _deletedResources.append(entry)
    }

    // ── Packet 8 staging ────────────────────────────────────────────────
    //
    // Reconciliation needs three distinctions packet 2 never did, and all three
    // look identical to the packet-2 spy while taking the reconciler down
    // completely different paths: a read that FAILED (vs. one that found
    // nothing), a delete that failed (vs. one that succeeded), and a delete the
    // bridge answers "already gone".

    /// Inventory kinds whose read must FAIL. Deliberately distinct from an
    /// empty staged inventory: "I could not look" and "there is nothing there"
    /// are exactly the two answers packet 8 exists to keep apart.
    private var _failingInventoryKinds: Set<String> = []
    /// The raw v1 error envelope a bridge returns for a refused read. v1 sends
    /// it with HTTP 200, so this proves an envelope is never mistaken for an
    /// empty bridge end to end, not only at the decoder.
    private var _inventoryErrorEnvelopes: [String: String] = [:]
    /// Deletes that fail, spelled exactly as `deletedResources` records them.
    private var _failingDeletes: Set<String> = []
    /// Deletes the bridge answers with v1 `type: 3` (resource not available).
    /// A correct cleanup counts these as SUCCESS — a stale manifest whose
    /// resources a user already removed must be prunable, not stuck forever.
    private var _absentDeletes: Set<String> = []
    /// Only the deletes that did NOT throw. `deletedResources` stays ATTEMPTED,
    /// because packet 2 asserts on attempts and that meaning must not shift.
    private var _succeededDeletes: [String] = []
    private var _deleteGates: [String: RestGate] = [:]
    private var _inventoryGates: [String: RestGate] = [:]
    private var _creations: [String] = []

    func stageInventoryFailure(_ kinds: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        _failingInventoryKinds = kinds
    }
    func stageInventoryErrorEnvelope(_ kind: String, _ json: String) {
        lock.lock(); defer { lock.unlock() }
        _inventoryErrorEnvelopes[kind] = json
    }
    func stageDeleteFailures(_ entries: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        _failingDeletes = entries
    }
    func stageAlreadyAbsentDeletes(_ entries: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        _absentDeletes = entries
    }
    /// Park a specific delete mid-flight — the continuation handshake that
    /// makes "a stale stop landed after a replacement" provable with no timing.
    func stageDeleteGate(_ entry: String, _ gate: RestGate) {
        lock.lock(); defer { lock.unlock() }
        _deleteGates[entry] = gate
    }
    /// Park a specific inventory read mid-pass, so the store can be mutated
    /// while a reconciliation pass is holding a snapshot.
    func stageInventoryGate(_ kind: String, _ gate: RestGate) {
        lock.lock(); defer { lock.unlock() }
        _inventoryGates[kind] = gate
    }

    var succeededDeletes: [String] {
        lock.lock(); defer { lock.unlock() }
        return _succeededDeletes
    }
    /// Every v1 resource creation, so "zero new create requests" is directly
    /// assertable when a replacement must be refused.
    var creations: [String] {
        lock.lock(); defer { lock.unlock() }
        return _creations
    }

    private func recordCreation(_ kind: String) {
        lock.lock(); defer { lock.unlock() }
        _creations.append(kind)
    }
    private func deleteGate(_ entry: String) -> RestGate? {
        lock.lock(); defer { lock.unlock() }
        return _deleteGates[entry]
    }
    private func deletePlan(_ entry: String) -> (fails: Bool, absent: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (_failingDeletes.contains(entry), _absentDeletes.contains(entry))
    }

    /// One delete. Records the ATTEMPT first, then applies the staged outcome.
    private func performDelete(_ entry: String) async throws {
        record(entry)
        if let gate = deleteGate(entry) {
            await gate.signalStarted()
            await gate.waitForRelease()
        }
        let plan = deletePlan(entry)
        if plan.absent {
            // Through the PRODUCTION classifier, so "already absent counts as
            // removed" is proven where it actually lives.
            try HueV1Client.throwUnlessDeleted(
                Data(#"[{"error":{"type":3,"address":"/x","description":"resource, /x, not available"}}]"#.utf8))
        } else if plan.fails {
            throw HueV1ClientError.apiError(type: 1, address: "/x", description: "unauthorized user")
        }
        lock.lock(); defer { lock.unlock() }
        _succeededDeletes.append(entry)
    }

    private func inventoryGate(_ kind: String) -> RestGate? {
        lock.lock(); defer { lock.unlock() }
        return _inventoryGates[kind]
    }
    private func inventoryPlan(
        _ kind: String
    ) -> (fails: Bool, envelope: String?, contents: [String: [String: Any]]) {
        lock.lock(); defer { lock.unlock() }
        _fetchCalls.append(kind)
        return (_failingInventoryKinds.contains(kind),
                _inventoryErrorEnvelopes[kind],
                _inventories[kind] ?? [:])
    }

    private func inventory(_ kind: String) async throws -> [String: [String: Any]] {
        if let gate = inventoryGate(kind) {
            await gate.signalStarted()
            await gate.waitForRelease()
        }
        let plan = inventoryPlan(kind)
        if let envelope = plan.envelope {
            // Through the PRODUCTION decoder, so this proves the real
            // envelope-vs-empty rule and not a test-local imitation of it.
            return try HueV1Client.decodeResourceMap(Data(envelope.utf8), path: kind)
        }
        if plan.fails { throw HueAPIError.httpError(500) }
        return plan.contents
    }

    override func deleteSchedule(id: String) async throws { try await performDelete("schedule:\(id)") }
    override func deleteRule(id: String) async throws { try await performDelete("rule:\(id)") }
    override func deleteSensor(id: String) async throws { try await performDelete("sensor:\(id)") }
    override func deleteScene(id: String) async throws { try await performDelete("scene:\(id)") }
    override func deleteResourcelink(id: String) async throws { try await performDelete("resourcelink:\(id)") }

    override func fetchSchedules() async throws -> [String: [String: Any]] { try await inventory("fetchSchedules") }
    override func fetchRules() async throws -> [String: [String: Any]] { try await inventory("fetchRules") }
    override func fetchSensors() async throws -> [String: [String: Any]] { try await inventory("fetchSensors") }
    override func fetchScenes() async throws -> [String: [String: Any]] { try await inventory("fetchScenes") }
    override func fetchResourcelinks() async throws -> [String: [String: Any]] { try await inventory("fetchResourcelinks") }

    override func createCLIPSensor(name: String, initialStatus: Int) async throws -> String {
        recordCreation("sensor"); return "new-sensor"
    }
    override func createRule(
        name: String, conditions: [[String: Any]], actions: [[String: Any]]
    ) async throws -> String {
        recordCreation("rule"); return "new-rule"
    }
    override func createRecurringSchedule(
        name: String, intervalSeconds: Int, command: [String: Any], autoDelete: Bool
    ) async throws -> String {
        recordCreation("schedule"); return "new-schedule"
    }
    override func createScene(
        name: String, lightIDs: [String], lightstates: [String: [String: Any]], recycle: Bool
    ) async throws -> String {
        recordCreation("scene"); return "new-scene"
    }
    override func createResourcelink(
        name: String, description: String, links: [String]
    ) async throws -> String {
        recordCreation("resourcelink"); return "new-resourcelink"
    }
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

    /// Packet 8: the explicit-stop power-off. A SEPARATE recorder from
    /// `groupedStateIDs` so existing suites' "no state writes" assertions keep
    /// meaning exactly what they meant before.
    private var _groupedPowerIDs: [String] = []
    var groupedPowerIDs: [String] {
        lock.lock(); defer { lock.unlock() }
        return _groupedPowerIDs
    }
    override func setGroupedLight(id: String, on: Bool) async throws {
        lock.lock(); _groupedPowerIDs.append("\(id):\(on)"); lock.unlock()
    }

    /// Packet 6: All-Day's tick issues exactly this PUT, one per room. Failing
    /// a chosen grouped light proves a per-room error stays confined to its own
    /// scope instead of abandoning the rest of the tick.
    private var _failingGroupedEffectIDs: Set<String> = []
    func stageGroupedEffectFailures(_ ids: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        _failingGroupedEffectIDs = ids
    }

    override func setGroupedLightEffect(
        id: String, on: Bool?, brightness: Double?,
        xy: (Double, Double)?, mirek: Int?, duration: Int
    ) async throws {
        lock.lock()
        _groupedEffectIDs.append(id)
        let failing = _failingGroupedEffectIDs.contains(id)
        lock.unlock()
        if failing { throw HueAPIError.httpError(500) }
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

    /// Packet 6: gates on the FIRST mutating request of the bridge-native
    /// startup, so a test can inspect ownership while that startup is genuinely
    /// mid-flight rather than inferring it afterwards.
    private var _groupedStateGate: RestGate?
    func stageGroupedStateGate(_ gate: RestGate) {
        lock.lock(); defer { lock.unlock() }
        _groupedStateGate = gate
    }
    /// Same, for the per-light firmware teardown the stop path runs.
    private var _lightNativeEffectGate: RestGate?
    func stageLightNativeEffectGate(_ gate: RestGate) {
        lock.lock(); defer { lock.unlock() }
        _lightNativeEffectGate = gate
    }
    /// Lights `fetchLights()` should report — lets a test drive the capability
    /// resolver to a real `.unsupported` verdict.
    private var _stagedLights: [HueLight] = []
    func stageLights(_ lights: [HueLight]) {
        lock.lock(); defer { lock.unlock() }
        _stagedLights = lights
    }

    override func setGroupedLightState(id: String, on: Bool, brightness: Double) async throws {
        lock.lock()
        let gate = _groupedStateGate
        lock.unlock()
        // Gate BEFORE recording, so "the first mutation has begun" is observable
        // at the earliest possible moment.
        if let gate {
            gate.signalStarted()
            await gate.waitForRelease()
        }
        lock.lock(); defer { lock.unlock() }
        _groupedStateIDs.append(id)
    }

    /// Packet 3: `startStudioMode`'s default branch issues exactly this PUT.
    /// Overridden so the ownership tests never reach the (unroutable) TEST-NET-1
    /// address the spies are built with.
    override func setGroupedLightBrightness(id: String, brightness: Double) async throws {
        lock.lock(); defer { lock.unlock() }
        _groupedStateIDs.append(id)
    }

    override func setLightNativeEffect(id: String, effect: String) async throws {
        lock.lock()
        _v1EffectPuts.append("\(id):\(effect)")
        let gate = _lightNativeEffectGate
        lock.unlock()
        if let gate {
            gate.signalStarted()
            await gate.waitForRelease()
        }
    }

    /// Packet 7 follow-up: how many times the bridge's light inventory was
    /// actually re-read. A refresh that "ran" without reading anything is
    /// indistinguishable from a throttled no-op unless the reads are counted.
    private var _fetchLightsCallCount = 0
    var fetchLightsCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _fetchLightsCallCount
    }

    override func fetchLights() async throws -> [HueLight] {
        lock.lock(); defer { lock.unlock() }
        _fetchLightsCallCount += 1
        return _stagedLights
    }

    // ── Packet 7 follow-up: loadAll staging ──────────────────────────
    //
    // `loadAll` fans out four fetches per bridge. Only `fetchLights` was ever
    // overridden, so the other three reached for the (unroutable) TEST-NET-1
    // address the spies are built with. Staging them keeps the load offline
    // AND lets `allRooms` be built by the production rebuild rather than
    // assigned by hand — which is what makes "the unattended pass saw a real
    // room and still did nothing" an honest claim.
    private var _stagedRooms: [HueRoom] = []
    private var _stagedGroupedLights: [HueGroupedLight] = []
    func stageRooms(_ rooms: [HueRoom], groupedLights: [HueGroupedLight] = []) {
        lock.lock(); defer { lock.unlock() }
        _stagedRooms = rooms
        _stagedGroupedLights = groupedLights
    }
    override func fetchRooms() async throws -> [HueRoom] {
        lock.lock(); defer { lock.unlock() }
        return _stagedRooms
    }
    override func fetchZones() async throws -> [HueZone] { [] }
    override func fetchGroupedLights() async throws -> [HueGroupedLight] {
        lock.lock(); defer { lock.unlock() }
        return _stagedGroupedLights
    }
    override func fetchScenes() async throws -> [HueScene] { [] }

    // Packet 4: the Composer per-light path (and the gradient path's flat
    // entries) issue exactly this PUT. Recorded — and optionally failed per
    // light — so dispatch-count and bookkeeping tests never reach the
    // unroutable TEST-NET-1 address the spies are built with.
    private var _lightEffectIDs: [String] = []
    var lightEffectIDs: [String] {
        lock.lock(); defer { lock.unlock() }
        return _lightEffectIDs
    }
    /// Packet 5: brightness per dispatched PUT, in order. Proves a subset's
    /// lights receive THEIR OWN frames — the frame↔light alignment that
    /// absolute indices exist to guarantee.
    private var _lightEffectBrightnesses: [Double] = []
    var lightEffectBrightnesses: [Double] {
        lock.lock(); defer { lock.unlock() }
        return _lightEffectBrightnesses
    }
    private var _failingLightEffectIDs: Set<String> = []
    func stageLightEffectFailures(_ ids: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        _failingLightEffectIDs = ids
    }
    override func setLightEffect(
        id: String, on: Bool?, brightness: Double?,
        xy: (Double, Double)?, mirek: Int?, duration: Int
    ) async throws {
        lock.lock()
        _lightEffectIDs.append(id)
        if let brightness { _lightEffectBrightnesses.append(brightness) }
        let failing = _failingLightEffectIDs.contains(id)
        lock.unlock()
        if failing { throw HueAPIError.httpError(500) }
    }

    // ── Packet 7: Entertainment ownership over the raw REST surface ──
    //
    // The consent flow reads entertainment_configuration and writes
    // action=stop directly, so these tests need the raw get/put the other
    // packets never touched. Recording both is what makes "nothing was
    // mutated before the user answered" an observable claim rather than an
    // assertion about code shape.

    /// What the bridge reports for `entertainment_configuration`.
    private var _entertainmentConfigsJSON = #"{"data": []}"#
    func stageEntertainmentConfigs(_ json: String) {
        lock.lock(); _entertainmentConfigsJSON = json; lock.unlock()
    }

    /// Convenience: mark these configuration ids active.
    func stageActiveEntertainment(_ ids: [String]) {
        let items = ids.map { #"{"id": "\#($0)", "status": "active"}"# }
        stageEntertainmentConfigs(#"{"data": [\#(items.joined(separator: ", "))]}"#)
    }

    var entertainmentConfigsShouldFail = false
    /// `action=stop` fails for exactly these configuration ids.
    private var _failingStopIDs: Set<String> = []
    func stageEntertainmentStopFailures(_ ids: Set<String>) {
        lock.lock(); _failingStopIDs = ids; lock.unlock()
    }

    /// Change what the bridge reports AFTER the next read observes the
    /// current state — the deterministic way to model "the world moved on
    /// between two reads" with no timing at all.
    ///
    /// One-shot on purpose: the world changes once, at a named point, and a
    /// later read must see the result rather than trigger it again.
    private var _onEntertainmentRead: (() -> Void)?
    func onEntertainmentReadOnce(_ block: @escaping () -> Void) {
        lock.lock(); _onEntertainmentRead = block; lock.unlock()
    }

    /// Fires after EVERY entertainment_configuration read, so a test can count
    /// reads and act on a specific one. Counting beats guessing: the preflight
    /// performs its own reads, and a "next read" hook fires inside it rather
    /// than at the acquisition that actually matters.
    private var _onEntertainmentReadEach: (() -> Void)?
    func onEntertainmentReadEach(_ block: @escaping () -> Void) {
        lock.lock(); _onEntertainmentReadEach = block; lock.unlock()
    }

    private var _entertainmentActions: [(configID: String, action: String)] = []
    /// Every entertainment_configuration action this bridge was asked for.
    var entertainmentActions: [(configID: String, action: String)] {
        lock.lock(); defer { lock.unlock() }
        return _entertainmentActions
    }
    var entertainmentStops: [String] {
        entertainmentActions.filter { $0.action == "stop" }.map(\.configID)
    }
    var entertainmentStarts: [String] {
        entertainmentActions.filter { $0.action == "start" }.map(\.configID)
    }

    /// `/resource/entertainment` — the service→device half of the join the
    /// area selector needs before it can call any area streamable.
    private var _entertainmentServicesJSON = #"{"data": []}"#
    func stageEntertainmentServices(_ json: String) {
        lock.lock(); _entertainmentServicesJSON = json; lock.unlock()
    }

    /// Every raw GET path, in order (packet 7 follow-up). "A fresh read
    /// happened" is only assertable if the reads themselves are recorded —
    /// a cached verdict and a re-read verdict look identical from the outside.
    private var _getPaths: [String] = []
    var getPaths: [String] {
        lock.lock(); defer { lock.unlock() }
        return _getPaths
    }
    var entertainmentConfigGets: [String] {
        getPaths.filter { $0.contains("entertainment_configuration") }
    }

    override func get(path: String, ip: String, token: String) async throws -> Data {
        lock.lock(); _getPaths.append(path); lock.unlock()
        if path.contains("entertainment_configuration") {
            lock.lock()
            let fail = entertainmentConfigsShouldFail
            let json = _entertainmentConfigsJSON
            let onRead = _onEntertainmentRead
            _onEntertainmentRead = nil          // one-shot
            let onEach = _onEntertainmentReadEach
            lock.unlock()
            if fail { throw HueAPIError.httpError(500) }
            // Fires AFTER this read has captured its answer, so the caller
            // sees the state it asked about and the NEXT reader sees the
            // change.
            onRead?()
            onEach?()
            return Data(json.utf8)
        }
        if path.contains("resource/entertainment") {
            lock.lock(); let json = _entertainmentServicesJSON; lock.unlock()
            return Data(json.utf8)
        }
        return Data("{}".utf8)
    }

    /// Rewrites the staged configuration list once a stop lands — what a real
    /// bridge does the moment `action=stop` is accepted. Modelling it here lets
    /// the takeover tests observe the true post-stop state instead of staging
    /// it by hand at a guessed moment in the read sequence.
    private var _deactivateOnStop: ((String) -> String)?
    func stageDeactivationOnStop(_ rewrite: @escaping (String) -> String) {
        lock.lock(); _deactivateOnStop = rewrite; lock.unlock()
    }

    override func put(path: String, body: [String: Any], ip: String, token: String) async throws -> Data {
        if path.contains("entertainment_configuration/"),
           let action = body["action"] as? String,
           let configID = path.split(separator: "/").last.map(String.init) {
            lock.lock()
            _entertainmentActions.append((configID, action))
            let failing = action == "stop" && _failingStopIDs.contains(configID)
            let rewrite = _deactivateOnStop
            lock.unlock()
            if failing { throw HueAPIError.httpError(500) }
            if action == "stop", let rewrite {
                let updated = rewrite(configID)
                lock.lock(); _entertainmentConfigsJSON = updated; lock.unlock()
            }
        }
        return Data("{}".utf8)
    }
}

/// Counts reads so a test can act on the Nth one rather than on "the next
/// one", which is only well-defined if you already know the read sequence.
final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = 0
    private var fired = false
    private let threshold: Int

    init(threshold: Int) { self.threshold = threshold }

    /// True exactly once, on the first read past the threshold.
    func advancePastThreshold() -> Bool {
        lock.lock(); defer { lock.unlock() }
        seen += 1
        guard !fired, seen > threshold else { return false }
        fired = true
        return true
    }
}

/// Deterministic clock for the packet-4 telemetry seam: tests advance it
/// explicitly, so cadence expiry is provable without a single wall-clock wait.
final class TelemetryTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CFAbsoluteTime
    init(_ start: CFAbsoluteTime) { value = start }
    func advance(to newValue: CFAbsoluteTime) {
        lock.lock(); value = newValue; lock.unlock()
    }
    func now() -> CFAbsoluteTime {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

// MARK: - Tests

@MainActor
final class MultiBridgeRoutingTests: XCTestCase {

    private var bridgeA: RoutingSpyClient!
    private var bridgeB: RoutingSpyClient!
    private var orchestrator: UnifiedOrchestrator!

    override func setUp() async throws {
        try await super.setUp()
        // Every assertion in this class is about which EXACT manifests exist,
        // so each test gets its own store on its own file. Sharing
        // `BridgeAnimationStore.shared` meant a sibling test's set-up could
        // empty the store while this one was suspended inside a production
        // settle window, and it also left fixtures in the developer's real
        // `bridge_animations.json`.
        animationStoreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("p8-\(UUID().uuidString).json")
        animationStore = BridgeAnimationStore(fileURL: animationStoreURL)
        bridgeA = RoutingSpyClient(bridgeID: "bridge-a", bridgeName: "Bridge A", ip: "192.0.2.1")
        bridgeB = RoutingSpyClient(bridgeID: "bridge-b", bridgeName: "Bridge B", ip: "192.0.2.2")
        orchestrator = UnifiedOrchestrator()
        orchestrator.injectForTesting(clients: ["bridge-a": bridgeA, "bridge-b": bridgeB])
        orchestrator.injectForTesting(bridgeAnimationStore: animationStore)
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
            bridgeID: "bridge-b",
            sensorID: "11", ruleIDs: ["22", "23"], scheduleID: "33",
            sceneIDs: [], resourcelinkID: nil,
            stepCount: 2, intervalSeconds: 3, cycleDurationSeconds: 6,
            createdAt: Date()
        )
        animationStore.save(manifest)
        defer { animationStore.remove(id: manifest.id) }

        // Packet 8: the caller names the bridge. A roomID-only reach could
        // never be exact with two bridges registered, and the production
        // comment on `stopCompositionMode` has always said so — this makes it
        // structural. The claim under test is unchanged and now stronger.
        await orchestrator.stopCompositionMode(roomID: roomID, bridgeID: "bridge-b")

        XCTAssertTrue(bridgeA.v1Spy.deletedResources.isEmpty,
                      "teardown must not touch a bridge the animation does not live on (M-07)")
        let deletedOnB = Set(bridgeB.v1Spy.deletedResources)
        XCTAssertTrue(deletedOnB.contains("schedule:33"), "schedule delete must land on the manifest's bridge")
        XCTAssertTrue(deletedOnB.contains("rule:22") && deletedOnB.contains("rule:23"))
        XCTAssertTrue(deletedOnB.contains("sensor:11"))
        XCTAssertFalse(animationStore.allManifests().contains { $0.id == manifest.id },
                       "manifest must be removed after correct-bridge cleanup")
    }

    /// Packet 8: with several bridges registered and no bridge named, there is
    /// no exact identity to delete against — so nothing is deleted and every
    /// manifest is retained. Failing closed here is the point: the alternative
    /// is guessing a bridge from a room id two bridges can both hold.
    func testStopCompositionModeWithNoNamedBridgeAndSeveralBridgesDeletesNothing() async throws {
        let manifest = BridgeAnimationManifest(
            id: UUID(), presetID: UUID(), presetName: "Ambiguous",
            roomID: "ambiguous-room", roomName: "Ambiguous Room",
            bridgeIP: "192.0.2.2", bridgeID: nil,
            sensorID: "11", ruleIDs: ["22"], scheduleID: "33",
            sceneIDs: [], resourcelinkID: nil,
            stepCount: 2, intervalSeconds: 3, cycleDurationSeconds: 6,
            createdAt: Date())
        animationStore.save(manifest)
        defer { animationStore.remove(id: manifest.id) }

        await orchestrator.stopCompositionMode(roomID: "ambiguous-room", bridgeID: nil)

        XCTAssertTrue(bridgeA.v1Spy.deletedResources.isEmpty)
        XCTAssertTrue(bridgeB.v1Spy.deletedResources.isEmpty)
        XCTAssertTrue(animationStore.allManifests().contains { $0.id == manifest.id },
                      "an unresolvable identity must retain the manifest, never drop it")
    }

    // ──────────────────────────────────────────────
    // MARK: - Per-room composition transport truth
    // ──────────────────────────────────────────────

    func testCompositionTransportIsPerRoomAndStopClearsOnlyThatRoom() async throws {
        orchestrator.compositionTransportByRoom["room-a"] = .bridgeStored
        orchestrator.compositionTransportByRoom["room-b"] = .entertainment

        await orchestrator.stopCompositionMode(roomID: "room-a", bridgeID: nil)

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

        await orchestrator.stopCompositionMode(roomID: "room-a", bridgeID: "bridge-a")

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

    // ──────────────────────────────────────────────
    // MARK: - Composer 2 packet 1a: Studio cannot silently take Composer's session
    // ──────────────────────────────────────────────
    //
    // startStudioMode stops whatever entertainment client sits on the target
    // bridge without asking who owns it, and leaves composition bookkeeping
    // behind. The composition's 25 fps loop then renders into a disconnected
    // client forever: `send` no-ops, `isTerminallyFailed` never trips, so the
    // REST failover never fires either. Silent and unrecoverable in-session.
    //
    // The fix is consent, not a smarter teardown — so what these lock is that
    // NOTHING is mutated before the user answers.

    /// A room on bridge B, used as the Studio target throughout this section.
    private func roomOnBridgeB(id: String = "room-b", name: String = "Bedroom B") -> RoomDisplayItem {
        RoomDisplayItem(
            kind: .zone,
            id: id, name: name, archetype: nil,
            isOn: true, brightness: 50,
            groupedLightID: "gl-\(id)", lightCount: 2,
            bridgeID: "bridge-b",
            childResourceRefs: [(rid: "LB1", rtype: "light"), (rid: "LB2", rtype: "light")]
        )
    }

    private func makePreset(named name: String) -> CompositionPreset {
        CompositionPreset(
            id: UUID(), name: name, icon: "sparkles", accentColorHex: "#FFB84D",
            isBuiltIn: false, category: .ambient, seasonMonths: nil,
            palette: PaletteConfig(),
            motion: MotionConfig(),
            envelope: EnvelopeConfig(),
            reaction: ReactionConfig(),
            createdAt: Date(timeIntervalSince1970: 1_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_000_000)
        )
    }

    /// Studio VM wired to the two-bridge orchestrator, with a composition
    /// already owning bridge B's Entertainment session and known to Studio's
    /// Now-Playing registry (so the prompt can name it).
    private func makeVMWithComposerOwningBridgeB(
        owningRoomID: String = "room-b-composer"
    ) -> (StudioViewModel, StudioCard) {
        orchestrator.testStageEntertainmentOwner(roomID: owningRoomID, bridgeID: "bridge-b")

        let vm = StudioViewModel()
        vm.configure(orchestrator: orchestrator)
        let compositionRoom = roomOnBridgeB(id: owningRoomID, name: "Aurora Room")
        let compositionCard = vm.studioCard(for: makePreset(named: "Aurora Drift"))
        vm.runningEffects[owningRoomID] = RunningEffect(
            cardID: compositionCard.id, card: compositionCard, room: compositionRoom,
            lightIDs: [], isEntertainment: true,
            requestedTransport: .entertainmentArea, transportFallback: false
        )
        return (vm, compositionCard)
    }

    /// The app-driven engine cards (Party/Strobe/Thunderstorm/Ambient) — the
    /// only Studio surface that reaches `startStudioMode`, and so the only one
    /// that can take a bridge's Entertainment session out from under Composer.
    private func liveModeCard(_ vm: StudioViewModel, _ id: String) throws -> StudioCard {
        try XCTUnwrap(vm.liveModeCards.first { $0.id == id })
    }

    func testStudioTapOverAComposerOwnedBridgeAsksBeforeTearingAnythingDown() async throws {
        let (vm, _) = makeVMWithComposerOwningBridgeB()
        let ambient = try liveModeCard(vm, "ambient")

        await vm.apply(ambient, roomOverride: roomOnBridgeB(), preferEntertainmentOverride: nil)

        let prompt = try XCTUnwrap(vm.entertainmentHandoffPrompt,
                                   "an explicit Studio tap over a Composer-owned bridge must ask")
        XCTAssertEqual(prompt.runningLookName, "Aurora Drift", "the prompt must name what is playing")
        XCTAssertEqual(prompt.requestedLookName, "Ambient")
        XCTAssertEqual(prompt.owningRoomID, "room-b-composer",
                       "ownership is per bridge — the owner need not be the targeted room")

        // …and nothing may have moved yet.
        XCTAssertEqual(orchestrator.compositionOwningEntertainment(onBridge: "bridge-b"),
                       "room-b-composer", "the session must survive an unanswered prompt")
        XCTAssertNotNil(vm.runningEffects["room-b-composer"],
                        "the composition must still be registered as playing")
        XCTAssertNil(vm.runningEffects["room-b"], "Studio must not have started")
        XCTAssertTrue(bridgeB.groupedStateIDs.isEmpty && bridgeB.groupedEffectIDs.isEmpty,
                      "no bridge traffic may precede the user's answer")
    }

    func testCancellingTheHandoffMutatesNothing() async throws {
        let (vm, _) = makeVMWithComposerOwningBridgeB()
        let ambient = try liveModeCard(vm, "ambient")
        await vm.apply(ambient, roomOverride: roomOnBridgeB(), preferEntertainmentOverride: nil)
        XCTAssertNotNil(vm.entertainmentHandoffPrompt)

        vm.cancelEntertainmentHandoff()

        XCTAssertNil(vm.entertainmentHandoffPrompt, "the prompt is consumed")
        XCTAssertEqual(orchestrator.compositionOwningEntertainment(onBridge: "bridge-b"),
                       "room-b-composer", "cancel must not release ownership")
        XCTAssertEqual(orchestrator.compositionTransportByRoom["room-b-composer"], .entertainment,
                       "cancel must not touch transport bookkeeping")
        XCTAssertNotNil(vm.runningEffects["room-b-composer"], "the composition keeps playing")
        XCTAssertNil(vm.runningEffects["room-b"], "the Studio card must not have started")
        XCTAssertTrue(bridgeB.groupedStateIDs.isEmpty && bridgeB.groupedEffectIDs.isEmpty,
                      "cancel means no writes reached the bridge")
    }

    func testConfirmingTheHandoffStopsTheCompositionThenStartsStudio() async throws {
        let (vm, _) = makeVMWithComposerOwningBridgeB()
        let ambient = try liveModeCard(vm, "ambient")
        await vm.apply(ambient, roomOverride: roomOnBridgeB(), preferEntertainmentOverride: nil)
        XCTAssertNotNil(vm.entertainmentHandoffPrompt)

        await vm.confirmEntertainmentHandoff()
        defer { Task { await orchestrator.stopStudioMode() } }

        XCTAssertNil(vm.entertainmentHandoffPrompt)
        XCTAssertNil(orchestrator.compositionOwningEntertainment(onBridge: "bridge-b"),
                     "confirm must clear Entertainment ownership — a stopped composition cannot keep the session")
        XCTAssertNil(orchestrator.compositionTransportByRoom["room-b-composer"],
                     "the official stop path clears transport truth; a leftover entry is the orphaned-loop signature")
        XCTAssertNil(vm.runningEffects["room-b-composer"],
                     "the composition must leave the Now-Playing registry")
        XCTAssertEqual(vm.runningEffects["room-b"]?.cardID, "ambient",
                       "…and only then does the requested Studio look start")
        XCTAssertTrue(orchestrator.testCanAcquireEntertainment(onBridge: "bridge-b"),
                      "the bridge is genuinely free afterwards — ownership and live state agree")
    }

    func testRepeatedConfirmOrCancelTapsCannotDoubleStopOrDoubleStart() async throws {
        let (vm, _) = makeVMWithComposerOwningBridgeB()
        let ambient = try liveModeCard(vm, "ambient")
        await vm.apply(ambient, roomOverride: roomOnBridgeB(), preferEntertainmentOverride: nil)

        await vm.confirmEntertainmentHandoff()
        defer { Task { await orchestrator.stopStudioMode() } }
        // The prompt was consumed before the first await, so every later tap is a no-op.
        await vm.confirmEntertainmentHandoff()
        vm.cancelEntertainmentHandoff()
        await vm.confirmEntertainmentHandoff()

        XCTAssertNil(vm.entertainmentHandoffPrompt)
        XCTAssertEqual(vm.runningEffects.count, 1,
                       "exactly one effect survives — no double start, no resurrected composition")
        XCTAssertEqual(vm.runningEffects["room-b"]?.cardID, "ambient")
        XCTAssertNil(orchestrator.compositionOwningEntertainment(onBridge: "bridge-b"))
    }

    func testCancelIsIdempotentAndSafeWithoutAPendingPrompt() {
        let (vm, _) = makeVMWithComposerOwningBridgeB()

        vm.cancelEntertainmentHandoff()
        vm.cancelEntertainmentHandoff()

        XCTAssertNil(vm.entertainmentHandoffPrompt)
        XCTAssertEqual(orchestrator.compositionOwningEntertainment(onBridge: "bridge-b"),
                       "room-b-composer",
                       "a stray dismissal must never stop a composition nobody asked to replace")
    }

    func testReplacingOneCompositionWithAnotherDoesNotPrompt() async throws {
        let (vm, _) = makeVMWithComposerOwningBridgeB()
        // A composition card whose preset is not in the store: the composition
        // branch bails immediately, so this asserts the CONFLICT decision alone —
        // which is made before the strategy switch is ever reached.
        let replacement = vm.studioCard(for: makePreset(named: "Ember Slow"))

        await vm.apply(replacement, roomOverride: roomOnBridgeB(), preferEntertainmentOverride: nil)

        XCTAssertNil(vm.entertainmentHandoffPrompt,
                     "swapping looks inside the surface that already owns the session is not a takeover")
    }

    func testStudioTapOnADifferentBridgeDoesNotPrompt() async throws {
        let (vm, _) = makeVMWithComposerOwningBridgeB()
        let ambient = try liveModeCard(vm, "ambient")
        let roomOnA = RoomDisplayItem(
            kind: .zone,
            id: "room-a", name: "Living A", archetype: nil,
            isOn: true, brightness: 50,
            groupedLightID: "gl-room-a", lightCount: 1,
            bridgeID: "bridge-a",
            childResourceRefs: [(rid: "LA1", rtype: "light")]
        )

        await vm.apply(ambient, roomOverride: roomOnA, preferEntertainmentOverride: nil)
        defer { Task { await orchestrator.stopStudioMode() } }

        XCTAssertNil(vm.entertainmentHandoffPrompt,
                     "bridge B's owner may not gate playback on bridge A — that is the lockout defect wearing a prompt")
        XCTAssertEqual(vm.runningEffects["room-a"]?.cardID, "ambient", "it just starts")
        XCTAssertEqual(orchestrator.compositionOwningEntertainment(onBridge: "bridge-b"),
                       "room-b-composer", "and bridge B is untouched")
    }

    func testStudioTapOnAFreeBridgeDoesNotPrompt() async throws {
        let vm = StudioViewModel()
        vm.configure(orchestrator: orchestrator)
        let ambient = try liveModeCard(vm, "ambient")

        await vm.apply(ambient, roomOverride: roomOnBridgeB(), preferEntertainmentOverride: nil)
        defer { Task { await orchestrator.stopStudioMode() } }

        XCTAssertNil(vm.entertainmentHandoffPrompt,
                     "no owner, no conflict — the prompt must not become a tax on ordinary taps")
        XCTAssertEqual(vm.runningEffects["room-b"]?.cardID, "ambient")
    }

    // ──────────────────────────────────────────────
    // MARK: - Composer 2 packet 2: bridge-stored cleanup is scoped to the owning manifest
    // ──────────────────────────────────────────────
    //
    // Every bridge-stored start used to end its per-room cleanup loop with
    // `purgeAllChromaGlowResources`, which enumerates the bridge and deletes
    // EVERY `CG_`-prefixed schedule/rule/sensor/scene/resourcelink. Starting a
    // look in room B therefore tore down room A's live animation on the same
    // bridge and left room A's manifest persisted, pointing at resources that no
    // longer existed. The per-room loop had a second, quieter bug: it filtered
    // on `roomID` alone, so a manifest recorded against a DIFFERENT bridge was
    // "stopped" through the current room's client — deletes aimed at a bridge
    // that never held those resources, and the only record of them dropped.
    //
    // The ownership boundary is now the manifest's own recorded IDs, selected by
    // roomID AND bridgeIP. Names are not ownership: `CG_` is a prefix every
    // room's resources share.

    /// This test's isolated manifest store (see `setUp`).
    private var animationStore: BridgeAnimationStore!
    private var animationStoreURL: URL!

    /// Manifests staged into this test's store.
    private var stagedManifests: [UUID] = []

    override func tearDown() async throws {
        // Drain before sweeping: a pass `loadAll` scheduled must not still be
        // writing to the shared store while the next test sets up.
        await orchestrator.testDrainBridgeAnimationReconciliation()
        stagedManifests.removeAll()
        if let animationStoreURL { try? FileManager.default.removeItem(at: animationStoreURL) }
        // Packet 4: never leave an injected telemetry clock behind.
        orchestrator.testResetCompositionTelemetryClock()
        try await super.tearDown()
    }

    /// Persist a manifest.
    ///
    /// Packet 8: the store now keys on the MANIFEST id, so `presetID` and
    /// `bridgeID` are both explicit parameters — staging the same preset in the
    /// same room on two bridges is exactly the collision case that used to be
    /// impossible to express, and `bridgeID: nil` stages a legacy IP-only
    /// record for the migration tests.
    @discardableResult
    private func stageManifest(
        roomID: String,
        bridgeIP: String,
        bridgeID: String? = nil,
        presetID: UUID = UUID(),
        presetName: String = "Packet2",
        roomName: String? = nil,
        sensorID: String,
        ruleIDs: [String],
        scheduleID: String,
        sceneIDs: [String] = [],
        resourcelinkID: String? = nil
    ) -> BridgeAnimationManifest {
        let manifest = BridgeAnimationManifest(
            id: UUID(), presetID: presetID, presetName: presetName,
            roomID: roomID, roomName: roomName ?? roomID,
            bridgeIP: bridgeIP, bridgeID: bridgeID,
            sensorID: sensorID, ruleIDs: ruleIDs, scheduleID: scheduleID,
            sceneIDs: sceneIDs, resourcelinkID: resourcelinkID,
            stepCount: 2, intervalSeconds: 3, cycleDurationSeconds: 6,
            createdAt: Date()
        )
        animationStore.save(manifest)
        stagedManifests.append(manifest.id)
        return manifest
    }

    /// Every delete a correct teardown of this manifest must issue — as a SET.
    /// Manifests live in a dictionary, so the order two manifests are cleaned in
    /// is not a contract; only the order WITHIN one manifest is.
    private func expectedDeletes(for manifest: BridgeAnimationManifest) -> Set<String> {
        var expected: Set<String> = [
            "schedule:\(manifest.scheduleID)",
            "sensor:\(manifest.sensorID)"
        ]
        for ruleID in manifest.ruleIDs { expected.insert("rule:\(ruleID)") }
        for sceneID in manifest.sceneIDs { expected.insert("scene:\(sceneID)") }
        if let rlID = manifest.resourcelinkID { expected.insert("resourcelink:\(rlID)") }
        return expected
    }

    private func storeStillHolds(_ manifest: BridgeAnimationManifest) -> Bool {
        animationStore.manifest(id: manifest.id) != nil
    }

    func testStartingARoomPreservesASiblingRoomsBridgeAnimation() async {
        let sibling = stageManifest(
            roomID: "p2-sibling-a", bridgeIP: "192.0.2.1", presetName: "Sibling A",
            sensorID: "a-sensor", ruleIDs: ["a-rule-1", "a-rule-2"], scheduleID: "a-sched",
            sceneIDs: ["a-scene"], resourcelinkID: "a-link"
        )

        // Room B has no previous animation: this is a first start, not a replacement.
        await orchestrator.testCleanupBridgeStoredForReplacement(
            roomID: "p2-sibling-b", bridgeID: "bridge-a", v1Client: bridgeA.v1Spy)

        XCTAssertTrue(bridgeA.v1Spy.deletedResources.isEmpty,
                      "starting one room must delete nothing belonging to another room")
        XCTAssertTrue(bridgeA.v1Spy.fetchCalls.isEmpty,
                      "a first start must not enumerate the bridge — that enumeration WAS the defect")
        XCTAssertTrue(storeStillHolds(sibling),
                      "the sibling's manifest must survive intact, not be orphaned by a global purge")
    }

    func testReplacingARoomDeletesOnlyThatRoomsKnownResources() async {
        let sibling = stageManifest(
            roomID: "p2-replace-a", bridgeIP: "192.0.2.1", presetName: "Sibling A",
            sensorID: "a-sensor", ruleIDs: ["a-rule-1"], scheduleID: "a-sched",
            sceneIDs: ["a-scene"], resourcelinkID: "a-link"
        )
        let replaced = stageManifest(
            roomID: "p2-replace-b", bridgeIP: "192.0.2.1", presetName: "Old B",
            sensorID: "b-sensor", ruleIDs: ["b-rule-1", "b-rule-2"], scheduleID: "b-sched",
            sceneIDs: ["b-scene-1", "b-scene-2"], resourcelinkID: "b-link"
        )

        await orchestrator.testCleanupBridgeStoredForReplacement(
            roomID: "p2-replace-b", bridgeID: "bridge-a", v1Client: bridgeA.v1Spy)

        XCTAssertEqual(Set(bridgeA.v1Spy.deletedResources), expectedDeletes(for: replaced),
                       "replacement deletes exactly the replaced room's recorded resources — no more, no less")
        XCTAssertTrue(Set(bridgeA.v1Spy.deletedResources).isDisjoint(with: expectedDeletes(for: sibling)),
                      "and nothing belonging to the sibling room")
        XCTAssertFalse(storeStillHolds(replaced), "the replaced manifest must be removed")
        XCTAssertTrue(storeStillHolds(sibling), "the sibling manifest must remain")
    }

    func testEveryOldManifestForTheTargetRoomIsCleaned() async {
        let firstOld = stageManifest(
            roomID: "p2-multi-b", bridgeIP: "192.0.2.1", presetName: "Old B one",
            sensorID: "b1-sensor", ruleIDs: ["b1-rule"], scheduleID: "b1-sched",
            sceneIDs: ["b1-scene"], resourcelinkID: "b1-link"
        )
        let secondOld = stageManifest(
            roomID: "p2-multi-b", bridgeIP: "192.0.2.1", presetName: "Old B two",
            sensorID: "b2-sensor", ruleIDs: ["b2-rule"], scheduleID: "b2-sched",
            sceneIDs: [], resourcelinkID: nil
        )
        let sibling = stageManifest(
            roomID: "p2-multi-a", bridgeIP: "192.0.2.1", presetName: "Sibling A",
            sensorID: "a-sensor", ruleIDs: ["a-rule"], scheduleID: "a-sched"
        )

        await orchestrator.testCleanupBridgeStoredForReplacement(
            roomID: "p2-multi-b", bridgeID: "bridge-a", v1Client: bridgeA.v1Spy)

        XCTAssertEqual(Set(bridgeA.v1Spy.deletedResources),
                       expectedDeletes(for: firstOld).union(expectedDeletes(for: secondOld)),
                       "a room can accumulate more than one manifest — every known resource in all of them goes")
        XCTAssertFalse(storeStillHolds(firstOld))
        XCTAssertFalse(storeStillHolds(secondOld))
        XCTAssertTrue(storeStillHolds(sibling), "…and the other room's manifest is untouched")
    }

    func testSameRoomIDOnAnotherBridgeIsNotTreatedAsOwned() async {
        // One room id, two bridges. Filtering on roomID alone would clean both —
        // issuing bridge B's deletes through bridge A's client and dropping the
        // only record of resources still live on bridge B.
        let onBridgeA = stageManifest(
            roomID: "p2-room-shared", bridgeIP: "192.0.2.1", presetName: "Shared on A",
            sensorID: "a-sensor", ruleIDs: ["a-rule"], scheduleID: "a-sched",
            sceneIDs: ["a-scene"], resourcelinkID: "a-link"
        )
        let onBridgeB = stageManifest(
            roomID: "p2-room-shared", bridgeIP: "192.0.2.2", presetName: "Shared on B",
            sensorID: "b-sensor", ruleIDs: ["b-rule"], scheduleID: "b-sched",
            sceneIDs: ["b-scene"], resourcelinkID: "b-link"
        )

        await orchestrator.testCleanupBridgeStoredForReplacement(
            roomID: "p2-room-shared", bridgeID: "bridge-a", v1Client: bridgeA.v1Spy)

        XCTAssertEqual(Set(bridgeA.v1Spy.deletedResources), expectedDeletes(for: onBridgeA),
                       "only the manifest recorded on THIS bridge is owned by this cleanup")
        XCTAssertFalse(storeStillHolds(onBridgeA))
        XCTAssertTrue(storeStillHolds(onBridgeB),
                      "the other bridge's animation is still live — its manifest must not be dropped")
    }

    func testCleanupOnOneBridgeSendsZeroTrafficToTheOther() async {
        stageManifest(
            roomID: "p2-traffic-shared", bridgeIP: "192.0.2.1", presetName: "On A",
            sensorID: "a-sensor", ruleIDs: ["a-rule"], scheduleID: "a-sched"
        )
        stageManifest(
            roomID: "p2-traffic-shared", bridgeIP: "192.0.2.2", presetName: "On B",
            sensorID: "b-sensor", ruleIDs: ["b-rule"], scheduleID: "b-sched"
        )

        await orchestrator.testCleanupBridgeStoredForReplacement(
            roomID: "p2-traffic-shared", bridgeID: "bridge-a", v1Client: bridgeA.v1Spy)

        XCTAssertTrue(bridgeB.v1Spy.deletedResources.isEmpty,
                      "a cleanup on bridge A must issue no deletes on bridge B")
        XCTAssertTrue(bridgeB.v1Spy.fetchCalls.isEmpty,
                      "…and no reads either — bridge B sees nothing at all")
    }

    func testNormalReplacementNeverEnumeratesBridgeResources() async {
        stageManifest(
            roomID: "p2-noenum-b", bridgeIP: "192.0.2.1", presetName: "Old B",
            sensorID: "b-sensor", ruleIDs: ["b-rule"], scheduleID: "b-sched",
            sceneIDs: ["b-scene"], resourcelinkID: "b-link"
        )

        await orchestrator.testCleanupBridgeStoredForReplacement(
            roomID: "p2-noenum-b", bridgeID: "bridge-a", v1Client: bridgeA.v1Spy)

        XCTAssertTrue(bridgeA.v1Spy.fetchCalls.isEmpty,
                      """
                      normal playback must issue zero fetchSchedules/fetchRules/fetchSensors/\
                      fetchScenes/fetchResourcelinks — enumerating the bridge is the first half \
                      of the global purge that destroyed sibling rooms
                      """)
        XCTAssertFalse(bridgeA.v1Spy.deletedResources.isEmpty,
                       "…while the manifest-specific deletes still happen")
    }

    func testExplicitMaintenancePurgeDeletesOnlyChromaGlowResources() async {
        // The maintenance action is the ONE place a global CG_ sweep is correct.
        // It must stay whole — and must still leave everything else alone.
        let spy = bridgeA.v1Spy
        spy.stageInventory("fetchSchedules", [
            "1": ["name": "CG_Aurora_tmr"],
            "2": ["name": "Wake up"]
        ])
        spy.stageInventory("fetchRules", [
            "10": ["name": "CG_Aurora_s0"],
            "11": ["name": "Motion sensor rule"]
        ])
        spy.stageInventory("fetchSensors", [
            "20": ["name": "CG_Aurora_ctr"],
            "21": ["name": "Hallway motion"]
        ])
        spy.stageInventory("fetchScenes", [
            "abc": ["name": "CG_Aurora_f0"],
            "def": ["name": "Relax"]
        ])
        spy.stageInventory("fetchResourcelinks", [
            "30": ["name": "CG_Aurora"],
            "31": ["name": "Hue Labs formula"]
        ])

        await BridgeAnimationEngine().purgeAllChromaGlowResources(v1Client: spy)

        XCTAssertEqual(Set(spy.deletedResources),
                       ["schedule:1", "rule:10", "sensor:20", "scene:abc", "resourcelink:30"],
                       "the explicit purge must still remove every CG_ resource in all five inventories")
        for survivor in ["schedule:2", "rule:11", "sensor:21", "scene:def", "resourcelink:31"] {
            XCTAssertFalse(spy.deletedResources.contains(survivor),
                           "the purge must never touch a non-ChromaGlow resource (\(survivor))")
        }
    }

    func testManifestCleanupDeletesInDependencySafeOrder() async throws {
        // Within ONE manifest the order matters: kill the timer, then the chain,
        // then the counter, then the stored states, then the grouping. A rule
        // outliving its sensor is a rule that can still fire.
        stageManifest(
            roomID: "p2-order-b", bridgeIP: "192.0.2.1", presetName: "Ordered",
            sensorID: "sen", ruleIDs: ["rule-1", "rule-2"], scheduleID: "sched",
            sceneIDs: ["scene-1", "scene-2"], resourcelinkID: "link"
        )

        await orchestrator.testCleanupBridgeStoredForReplacement(
            roomID: "p2-order-b", bridgeID: "bridge-a", v1Client: bridgeA.v1Spy)

        let deletes = bridgeA.v1Spy.deletedResources
        func position(_ entry: String) throws -> Int {
            try XCTUnwrap(deletes.firstIndex(of: entry), "\(entry) was never deleted")
        }
        let schedule = try position("schedule:sched")
        let lastRule = max(try position("rule:rule-1"), try position("rule:rule-2"))
        let sensor = try position("sensor:sen")
        let firstScene = min(try position("scene:scene-1"), try position("scene:scene-2"))
        let link = try position("resourcelink:link")

        XCTAssertLessThan(schedule, try position("rule:rule-1"), "the timer dies before the chain it drives")
        XCTAssertLessThan(lastRule, sensor, "every rule goes before the sensor its condition reads")
        XCTAssertLessThan(sensor, firstScene, "the counter goes before the states it selected")
        XCTAssertLessThan(firstScene, link, "the grouping resourcelink goes last")
    }

    func testManifestWithoutAResourcelinkCleansSafely() async {
        // The resourcelink is best-effort at upload time (`resourcelinkID: nil`
        // on failure); its absence must not strand the rest of the teardown.
        let noLink = stageManifest(
            roomID: "p2-nolink-b", bridgeIP: "192.0.2.1", presetName: "No link",
            sensorID: "sen", ruleIDs: ["rule-1"], scheduleID: "sched",
            sceneIDs: ["scene-1"], resourcelinkID: nil
        )

        await orchestrator.testCleanupBridgeStoredForReplacement(
            roomID: "p2-nolink-b", bridgeID: "bridge-a", v1Client: bridgeA.v1Spy)

        XCTAssertEqual(Set(bridgeA.v1Spy.deletedResources), expectedDeletes(for: noLink))
        XCTAssertFalse(bridgeA.v1Spy.deletedResources.contains { $0.hasPrefix("resourcelink:") },
                       "no resourcelink recorded, no resourcelink delete")
        XCTAssertFalse(storeStillHolds(noLink))
    }

    func testManifestWithEmptyRuleAndSceneArraysCleansSafely() async {
        let sparse = stageManifest(
            roomID: "p2-sparse-b", bridgeIP: "192.0.2.1", presetName: "Sparse",
            sensorID: "sen", ruleIDs: [], scheduleID: "sched",
            sceneIDs: [], resourcelinkID: nil
        )

        await orchestrator.testCleanupBridgeStoredForReplacement(
            roomID: "p2-sparse-b", bridgeID: "bridge-a", v1Client: bridgeA.v1Spy)

        XCTAssertEqual(Set(bridgeA.v1Spy.deletedResources), ["schedule:sched", "sensor:sen"])
        XCTAssertEqual(expectedDeletes(for: sparse), ["schedule:sched", "sensor:sen"])
        XCTAssertFalse(storeStillHolds(sparse))
    }

    /// Architectural guard, not a behavior test.
    ///
    /// The tests above exercise the cleanup helper, and the helper genuinely
    /// enumerates nothing. But they would all still pass if a later edit called
    /// `purgeAllChromaGlowResources` from `startCompositionMode` right AFTER the
    /// helper — which is exactly the shape the defect had. So pin the wiring
    /// itself: the orchestrator has no purge call at all, and the one legitimate
    /// caller is the explicit Settings maintenance action.
    func testGlobalBridgeAnimationPurgeIsWiredOnlyToExplicitMaintenance() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // HueHomeTests/
            .deletingLastPathComponent()   // repo root

        /// Production source with comment-only lines stripped: a doc comment
        /// naming the purge (the orchestrator carries one, recording why the
        /// call left) is documentation, not a call site.
        func code(_ relativePath: String) throws -> String {
            let url = repoRoot.appendingPathComponent(relativePath)
            return try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
        }

        XCTAssertFalse(
            try code("HueHome/Core/Network/UnifiedOrchestrator.swift")
                .contains("purgeAllChromaGlowResources"),
            """
            no normal playback path may reach the global CG_ purge: start, stop, replacement, \
            launch and refresh all live in UnifiedOrchestrator, so one call anywhere in it \
            reopens the cross-room destruction defect
            """)
        XCTAssertTrue(
            try code("HueHome/UI/Settings/SettingsView.swift")
                .contains("purgeAllChromaGlowResources(v1Client:"),
            "the user-invoked Clean Bridge Resources maintenance action must keep its purge")
        XCTAssertTrue(
            try code("HueHome/Core/Network/BridgeAnimationEngine.swift")
                .contains("func purgeAllChromaGlowResources("),
            "the recovery operation itself stays available — it was unwired, not deleted")
    }

    // ──────────────────────────────────────────────
    // MARK: - Composer 2 packet 3: scoped REST mailboxes + cooperative cancellation
    // ──────────────────────────────────────────────
    //
    // Before packet 3 ONE `RestSender` served every Composer room, every Studio
    // engine loop, and every Studio live-param write across every bridge — so
    // `clear()` was global, and the multi-batch closures had no way to notice
    // they had been superseded. These are the orchestrator-level guards; the
    // pure sender semantics live in GatedBulkWriteTests.
    //
    // Everything below is proven by continuations and recorded event ORDER.
    // Nothing is proven by elapsed time.

    /// Park a closure inside a sender's flush loop so later enqueues stay
    /// pending and observable.
    private func park(
        _ sender: RestSender,
        room: String = "__park__",
        events: RestEventLog
    ) async -> RestGate {
        let gate = RestGate()
        await sender.enqueue(scope: RestScope(roomID: room, owner: .composer)) { _ in
            gate.signalStarted()
            await gate.waitForRelease()
        }
        await gate.waitUntilStarted()
        _ = events
        return gate
    }

    /// Deterministic barrier: everything enqueued before this has run.
    private func drain(_ sender: RestSender) async {
        let done = RestGate()
        await sender.enqueue(scope: RestScope(roomID: "__drain__", owner: .studio)) { _ in
            done.signalStarted()
        }
        await done.waitUntilStarted()
    }

    private func enqueueRecording(
        _ sender: RestSender,
        _ scope: RestScope,
        _ events: RestEventLog,
        _ label: String
    ) async {
        await sender.enqueue(scope: scope) { _ in events.record(label) }
    }

    private func composerScope(_ roomID: String) -> RestScope {
        RestScope(roomID: roomID, owner: .composer)
    }
    private func studioScope(_ roomID: String) -> RestScope {
        RestScope(roomID: roomID, owner: .studio)
    }

    // 8. Stopping room A must not discard room B's queued frame. This is the
    //    headline defect: the global clear() also poisoned room B's delta gate
    //    (the scheduler had already recorded lastSent* for the discarded
    //    frame), so a stopped room could FREEZE a running room's colour.
    func testStoppingOneRoomPreservesAnotherRoomsQueuedWork() async {
        orchestrator.testStageRESTComposition(roomID: "room-a", bridgeID: "bridge-a", api: bridgeA)
        orchestrator.testStageRESTComposition(roomID: "room-b", bridgeID: "bridge-a", api: bridgeA)
        let sender = orchestrator.testRestSender(for: "bridge-a")
        let events = RestEventLog()

        let gate = await park(sender, events: events)
        await enqueueRecording(sender, composerScope("room-a"), events, "A")
        await enqueueRecording(sender, composerScope("room-b"), events, "B")

        await orchestrator.stopCompositionMode(roomID: "room-a", bridgeID: "bridge-a")

        gate.release()
        await drain(sender)

        XCTAssertEqual(events.entries, ["B"], """
            room A's queued frame is dropped and room B's survives — a global \
            clear() here is what froze running rooms on a stale colour
            """)
    }

    // 9. The same isolation across bridges: bridge B's mailbox is a different
    //    object entirely, so a bridge-A stop cannot reach it.
    func testStoppingARoomOnOneBridgePreservesTheOtherBridgesQueuedWork() async {
        orchestrator.testStageRESTComposition(roomID: "room-a", bridgeID: "bridge-a", api: bridgeA)
        orchestrator.testStageRESTComposition(roomID: "room-b", bridgeID: "bridge-b", api: bridgeB)
        let senderA = orchestrator.testRestSender(for: "bridge-a")
        let senderB = orchestrator.testRestSender(for: "bridge-b")
        let events = RestEventLog()

        let gateA = await park(senderA, room: "__park-a__", events: events)
        let gateB = await park(senderB, room: "__park-b__", events: events)
        await enqueueRecording(senderA, composerScope("room-a"), events, "A")
        await enqueueRecording(senderB, composerScope("room-b"), events, "B")

        await orchestrator.stopCompositionMode(roomID: "room-a", bridgeID: "bridge-a")

        gateA.release()
        gateB.release()
        await drain(senderA)
        await drain(senderB)

        XCTAssertEqual(events.entries, ["B"],
            "bridge B's mailbox is a separate object; a bridge-A stop cannot reach it")
    }

    // 10. Stop identity is EXPLICIT (packet 4): the caller names the room's
    //     original bridge, so a stop can never guess. Two protections replace
    //     the old runtime-existence gate: a stop aimed at a bridge with no
    //     sender must not conjure one, and a stop aimed at bridge X must not
    //     reach work queued on bridge A — even for the same roomID.
    func testStoppingAgainstASenderlessBridgeClearsNothingAndConjuresNoSender() async {
        let sender = orchestrator.testRestSender(for: "bridge-a")
        let events = RestEventLog()
        let keysBefore = orchestrator.testRestSenderBridgeKeys()

        let gate = await park(sender, events: events)
        await enqueueRecording(sender, composerScope("ghost-room"), events, "ghost")

        // The caller says ghost-room lives on bridge-x — a bridge that has no
        // REST sender (an Entertainment-only bridge, say). Nothing may be
        // cleared anywhere, and no bridge-x mailbox may spring into existence
        // just to clear nothing.
        await orchestrator.stopCompositionMode(roomID: "ghost-room", bridgeID: "bridge-x")

        gate.release()
        await drain(sender)

        XCTAssertEqual(events.entries, ["ghost"],
            "bridge-a's queued work is untouched by a stop naming bridge-x")
        XCTAssertEqual(orchestrator.testRestSenderBridgeKeys(), keysBefore,
            "the stop must not lazily create a sender for the named bridge")
    }

    // 11. The bridge comes from the RUNTIME's recorded bridgeID, never from
    //     `allRooms` — that snapshot goes stale mid-composition, and a stale
    //     lookup would clear the wrong bridge's mailbox in both directions.
    func testComposerStopUsesTheRuntimesBridgeNotAStaleRoomSnapshot() async {
        // Runtime says room-a lives on bridge A…
        orchestrator.testStageRESTComposition(roomID: "room-a", bridgeID: "bridge-a", api: bridgeA)
        // …but the room snapshot has since moved it to bridge B.
        let movedRoom = HueLocalRoom(roomID: "room-a", bridgeID: "bridge-b")
        movedRoom.cachedName = "Room A"
        movedRoom.cachedGroupedLightID = "gl-a"
        orchestrator.preloadCached(from: [movedRoom])
        XCTAssertEqual(orchestrator.allRooms.first(where: { $0.id == "room-a" })?.bridgeID,
                       "bridge-b", "precondition: the snapshot disagrees with the runtime")

        let senderA = orchestrator.testRestSender(for: "bridge-a")
        let senderB = orchestrator.testRestSender(for: "bridge-b")
        let events = RestEventLog()

        let gateA = await park(senderA, room: "__park-a__", events: events)
        let gateB = await park(senderB, room: "__park-b__", events: events)
        await enqueueRecording(senderA, composerScope("room-a"), events, "on-bridge-a")
        await enqueueRecording(senderB, composerScope("room-a"), events, "on-bridge-b")

        // The caller passes the identity RECORDED at start (packet 4) — the
        // running-effect record says bridge A. The stale allRooms snapshot
        // (which now claims bridge B) must play no part in the teardown.
        await orchestrator.stopCompositionMode(roomID: "room-a", bridgeID: "bridge-a")

        gateA.release()
        gateB.release()
        await drain(senderA)
        await drain(senderB)

        XCTAssertEqual(events.entries, ["on-bridge-b"], """
            the recorded bridge (A) is cleared and the stale snapshot's bridge \
            (B) is left alone — reading allRooms here would invert this
            """)
    }

    // 12. Composer and Studio may target the same room simultaneously (a Studio
    //     slider while a composition runs). The owner is part of the key, so
    //     they are independent slots and one cannot cancel the other.
    func testStudioAndComposerScopesForTheSameRoomAreIndependent() async {
        let sender = orchestrator.testRestSender(for: "bridge-a")
        let events = RestEventLog()

        let gate = await park(sender, events: events)
        await enqueueRecording(sender, composerScope("room-a"), events, "composer")
        await enqueueRecording(sender, studioScope("room-a"), events, "studio")

        await sender.clear(scope: composerScope("room-a"))

        gate.release()
        await drain(sender)

        XCTAssertEqual(events.entries, ["studio"],
            "clearing the room's Composer slot must leave its Studio slot alone")
    }

    // 13. CROSS-ROOM STUDIO REPLACEMENT. `activeStudioTask` is one global slot,
    //     so starting Studio in room B replaces room A's loop. startStudioMode
    //     must therefore clear the PREVIOUSLY RECORDED scope, not the incoming
    //     room's — otherwise room A's epoch stays valid and it keeps writing.
    func testStartingStudioInAnotherRoomInvalidatesThePreviousRoomsScope() async {
        let roomA = RoomDisplayItem(
            id: "room-a", name: "Room A", archetype: nil,
            isOn: true, brightness: 50,
            groupedLightID: "gl-a", lightCount: 1,
            bridgeID: "bridge-a",
            childResourceRefs: [(rid: "LA1", rtype: "light")]
        )
        let roomB = RoomDisplayItem(
            id: "room-b", name: "Room B", archetype: nil,
            isOn: true, brightness: 50,
            groupedLightID: "gl-b", lightCount: 1,
            bridgeID: "bridge-a",
            childResourceRefs: [(rid: "LB1", rtype: "light")]
        )

        // A Studio card with no engine loop: `startStudioMode`'s default branch
        // does one grouped PUT, so the ownership sequence runs without spawning
        // an endless engine task.
        await orchestrator.startStudioMode(key: "static-test-card", room: roomA,
                                           params: [:], colors: [:])
        XCTAssertEqual(orchestrator.testActiveStudioRestScope()?.scope, studioScope("room-a"),
            "room A is recorded as the Studio REST owner")

        let sender = orchestrator.testRestSender(for: "bridge-a")
        let events = RestEventLog()
        let gate = await park(sender, events: events)
        // Room A's Studio work is queued, and an unrelated Composer scope too.
        await enqueueRecording(sender, studioScope("room-a"), events, "studio-a")
        await enqueueRecording(sender, composerScope("room-c"), events, "composer-c")

        await orchestrator.startStudioMode(key: "static-test-card", room: roomB,
                                           params: [:], colors: [:])

        let roomAStillCurrent = await sender.isCurrent(scope: studioScope("room-a"), epoch: 0)
        XCTAssertFalse(roomAStillCurrent,
            "room A's epoch must be invalidated even though the new card targets room B")
        XCTAssertEqual(orchestrator.testActiveStudioRestScope()?.scope, studioScope("room-b"),
            "room B is recorded before its first enqueue")

        // Room B's first work is accepted normally.
        await enqueueRecording(sender, studioScope("room-b"), events, "studio-b")

        gate.release()
        await drain(sender)

        XCTAssertEqual(events.entries, ["composer-c", "studio-b"], """
            room A's queued Studio work is gone, room B's is accepted, and the \
            unrelated Composer scope was never touched
            """)
    }

    // 14. removeBridge clears and removes ONLY that bridge's sender, and drops
    //     the Studio owner iff it lived there. (Deliberate divergence from the
    //     commandGates precedent, which leaks a gate per removed bridge.)
    func testRemovingABridgeClearsOnlyItsOwnSenderAndStudioOwnership() async {
        let senderA = orchestrator.testRestSender(for: "bridge-a")
        let senderB = orchestrator.testRestSender(for: "bridge-b")
        let events = RestEventLog()
        orchestrator.testSetActiveStudioRestScope(bridgeKey: "bridge-a", roomID: "room-a")

        let gateA = await park(senderA, room: "__park-a__", events: events)
        let gateB = await park(senderB, room: "__park-b__", events: events)
        await enqueueRecording(senderA, studioScope("room-a"), events, "A")
        await enqueueRecording(senderB, composerScope("room-b"), events, "B")

        await orchestrator.removeBridge(id: "bridge-a")

        XCTAssertFalse(orchestrator.testRestSenderBridgeKeys().contains("bridge-a"),
            "bridge A's sender is removed, not leaked")
        XCTAssertTrue(orchestrator.testRestSenderBridgeKeys().contains("bridge-b"),
            "bridge B's sender survives")
        XCTAssertNil(orchestrator.testActiveStudioRestScope(),
            "the Studio owner lived on bridge A, so it is forgotten")

        gateA.release()
        gateB.release()
        await drain(senderA)
        await drain(senderB)

        XCTAssertEqual(events.entries, ["B"],
            "only bridge A's queued work was invalidated")
    }

    // 14b. …and a removal on the OTHER bridge must leave Studio ownership alone.
    func testRemovingADifferentBridgeLeavesStudioOwnershipIntact() async {
        _ = orchestrator.testRestSender(for: "bridge-a")
        _ = orchestrator.testRestSender(for: "bridge-b")
        orchestrator.testSetActiveStudioRestScope(bridgeKey: "bridge-a", roomID: "room-a")

        await orchestrator.removeBridge(id: "bridge-b")

        XCTAssertEqual(orchestrator.testActiveStudioRestScope()?.bridgeKey, "bridge-a",
            "the Studio owner is cleared iff it belonged to the removed bridge")
    }

    // 15. An EXECUTING multi-batch closure stops before its NEXT batch. This is
    //     the cooperative-cancellation guarantee — Task.isCancelled cannot do
    //     it, because the flush task is unstructured and never cancelled.
    func testAnExecutingMultiBatchClosureStopsBeforeItsNextBatch() async {
        let sender = orchestrator.testRestSender(for: "bridge-a")
        let events = RestEventLog()
        let scope = composerScope("room-a")
        let batch1 = RestGate()
        let finished = RestGate()

        await sender.enqueue(scope: scope) { stillCurrent in
            // Mirrors the production Composer shape: probe at the TOP of every
            // batch, including the first.
            for batch in 1...3 {
                guard await stillCurrent() else { break }
                events.record("batch\(batch)")
                if batch == 1 {
                    batch1.signalStarted()
                    await batch1.waitForRelease()   // stands in for the 80 ms gap
                }
            }
            finished.signalStarted()
        }

        await batch1.waitUntilStarted()
        await sender.clear(scope: scope)
        batch1.release()
        await finished.waitUntilStarted()

        XCTAssertEqual(events.entries, ["batch1"], """
            the already-dispatched batch may complete, but no LATER batch may \
            begin — batch2 and batch3 must never appear
            """)
    }

    // 16. Superseded queued work never begins at all: the closure body is not
    //     entered even once.
    func testSupersededQueuedWorkNeverBegins() async {
        let sender = orchestrator.testRestSender(for: "bridge-a")
        let events = RestEventLog()
        let scope = composerScope("room-a")

        let gate = await park(sender, events: events)
        await sender.enqueue(scope: scope) { _ in events.record("old-look") }
        await sender.enqueue(scope: scope) { _ in events.record("new-look") }

        gate.release()
        await drain(sender)

        XCTAssertEqual(events.entries, ["new-look"],
            "the superseded closure body is never entered — not entered-and-aborted")
    }

    // 17. Repeated stop/start is idempotent: clearing three times then enqueuing
    //     once must run exactly once, with no stuck or doubled work.
    func testRepeatedClearThenEnqueueRunsExactlyOnce() async {
        let sender = orchestrator.testRestSender(for: "bridge-a")
        let events = RestEventLog()
        let scope = composerScope("room-a")

        for _ in 0..<3 { await sender.clear(scope: scope) }
        await enqueueRecording(sender, scope, events, "run")
        await drain(sender)

        XCTAssertEqual(events.entries, ["run"],
            "repeated clears leave the mailbox usable, and the work runs exactly once")
    }

    // 18. Cross-bridge independence asserted by ORDERING, not elapsed time:
    //     bridge B's mailbox makes progress while bridge A's is parked.
    func testCrossBridgeIndependenceIsProvenByOrderingNotTiming() async {
        let senderA = orchestrator.testRestSender(for: "bridge-a")
        let senderB = orchestrator.testRestSender(for: "bridge-b")
        let events = RestEventLog()

        let gateA = await park(senderA, room: "__park-a__", events: events)
        await enqueueRecording(senderA, composerScope("room-a"), events, "A")

        // Bridge B runs to completion while bridge A is still blocked.
        await enqueueRecording(senderB, composerScope("room-b"), events, "B")
        await drain(senderB)
        XCTAssertEqual(events.entries, ["B"],
            "a parked bridge-A mailbox cannot stall bridge B")

        gateA.release()
        await drain(senderA)
        XCTAssertEqual(events.entries, ["B", "A"], "bridge A resumes independently")
    }

    // 19. STUDIO PER-LIGHT COOPERATIVE CANCELLATION. Before packet 3 this loop
    //     ran ~lightCount x 100 ms with nothing able to stop it: the gate's own
    //     cancellation guards are inert inside a mailbox closure. Mirrors the
    //     production shape in StudioViewModel (see the source guard below).
    func testStudioPerLightSweepStopsAfterTheDispatchedLight() async {
        let sender = orchestrator.testRestSender(for: "bridge-a")
        let gate = orchestrator.commandGate(for: "bridge-a")
        let events = RestEventLog()
        let firstLight = RestGate()
        let finished = RestGate()
        let lights = ["light-1", "light-2", "light-3"]

        await orchestrator.enqueueStudioRestWrite(
            roomID: "room-a", bridgeID: "bridge-a"
        ) { stillCurrent in
            for id in lights {
                guard await stillCurrent() else { break }
                _ = await gate.send(retry: false) {
                    events.record(id)
                    if id == "light-1" {
                        firstLight.signalStarted()
                        await firstLight.waitForRelease()
                    }
                }
            }
            finished.signalStarted()
        }

        // An unrelated Composer scope is queued behind it.
        await enqueueRecording(sender, composerScope("room-z"), events, "composer-z")

        await firstLight.waitUntilStarted()
        await sender.clear(scope: studioScope("room-a"))
        firstLight.release()
        await finished.waitUntilStarted()
        await drain(sender)

        XCTAssertEqual(events.entries, ["light-1", "composer-z"], """
            only the already-dispatched light completes; lights 2 and 3 never \
            begin, and the unrelated Composer scope is still executable
            """)
    }

    // Hardening guard, not a behavior test.
    //
    // Test 19 proves the SHAPE works. It would still pass if a later edit moved
    // production's `stillCurrent` check to before the loop instead of before
    // every send — which is exactly the ~2 s uncancellable window packet 3
    // removed. And `Task.isCancelled` is permanently false inside an enqueued
    // closure (the mailbox flush task is unstructured and never cancelled), so
    // any staleness guard built on it in there is a silent no-op. Pin both
    // properties against the production source.
    func testEveryEnqueuedClosureIsCooperativelyCancellable() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // HueHomeTests/
            .deletingLastPathComponent()   // repo root

        /// The body of every `enqueue(scope:)` / `enqueueStudioRestWrite(...)`
        /// closure in a file, as arrays of trimmed lines. Comment-only lines are
        /// stripped first so prose about a call is never mistaken for one.
        /// The closure opener may sit several lines below the call (the scoped
        /// signature wraps), so the opener is found by scanning forward for the
        /// `{ … in` line, then the body is taken by brace depth.
        func enqueuedClosureBodies(_ relativePath: String) throws -> [[String]] {
            let raw = try String(
                contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
            let lines = raw
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .map { $0.hasPrefix("//") ? "" : $0 }

            var bodies: [[String]] = []
            var index = 0
            while index < lines.count {
                // Packet 4 moved the Composer closures into makeComposer*Work
                // factories (so the scheduler and the DEBUG seams build the
                // identical closure) — their `return { … in` bodies are the
                // same enqueued closures and stay in this guard's remit.
                let isCall = lines[index].contains(".enqueue(scope:")
                    || lines[index].contains("enqueueStudioRestWrite(")
                    || lines[index].contains("-> RestSender.Work {")
                guard isCall else { index += 1; continue }

                var opener = index
                while opener < lines.count, opener - index <= 6,
                      !(lines[opener].hasSuffix(" in") && lines[opener].contains("{")) {
                    opener += 1
                }
                guard opener < lines.count, opener - index <= 6,
                      lines[opener].hasSuffix(" in"), lines[opener].contains("{") else {
                    index += 1; continue
                }

                var depth = 0
                var body: [String] = []
                var scan = opener
                while scan < lines.count {
                    depth += lines[scan].filter { $0 == "{" }.count
                    depth -= lines[scan].filter { $0 == "}" }.count
                    body.append(lines[scan])
                    scan += 1
                    if depth == 0 { break }
                }
                bodies.append(body)
                index = scan
            }
            return bodies
        }

        let orchestratorClosures = try enqueuedClosureBodies("HueHome/Core/Network/UnifiedOrchestrator.swift")
        let studioClosures = try enqueuedClosureBodies("HueHome/UI/Studio/StudioViewModel.swift")
        XCTAssertFalse(orchestratorClosures.isEmpty, "UnifiedOrchestrator must still enqueue REST work")
        XCTAssertFalse(studioClosures.isEmpty, "StudioViewModel must still enqueue REST work")

        // (a) No enqueued closure may guard on Task.isCancelled.
        for (label, closures) in [("UnifiedOrchestrator", orchestratorClosures),
                                  ("StudioViewModel", studioClosures)] {
            for body in closures {
                XCTAssertFalse(body.contains(where: { $0.contains("Task.isCancelled") }), """
                    \(label): an enqueued closure must not guard on \
                    Task.isCancelled — it is permanently false in there, so the \
                    guard silently does nothing. Use the stillCurrent probe.
                    """)
            }
        }

        // (b) Every gate.send inside an enqueued closure is a PACED PER-LIGHT
        //     sweep, and must be guarded immediately before EVERY send —
        //     including the first light. One check before the loop leaves a
        //     full ~lightCount x 100 ms uncancellable sweep.
        //     (The unguarded gate.send in applyEffectsV2Parameters is NOT in an
        //     enqueued closure — it is the initial apply, with no probe to
        //     consult — so it is correctly out of this set.)
        let perLightClosures = studioClosures.filter { body in
            body.contains(where: { $0.contains("gate.send(") })
        }
        XCTAssertEqual(perLightClosures.count, 3, """
            the three paced per-light Studio loops (warmth, speed, base colour) \
            are the cancellable ones — a new per-light site needs a guard too
            """)
        for body in perLightClosures {
            let sendLines = body.indices.filter { body[$0].hasPrefix("_ = await gate.send(") }
            XCTAssertFalse(sendLines.isEmpty)
            for line in sendLines {
                XCTAssertEqual(body[line - 1], "guard await stillCurrent() else { return }",
                    "every gate.send in a per-light Studio loop must be immediately guarded")
            }
        }

        // (c) Both Composer batch loops probe at the TOP of each batch, before
        //     dispatching it — otherwise a stopped room keeps writing for
        //     another 300-500 ms after the replacement look primed.
        let batchClosures = orchestratorClosures.filter { body in
            body.contains(where: { $0.hasPrefix("for batchStart in stride(") })
        }
        XCTAssertEqual(batchClosures.count, 2,
            "the gradient-aware and flat per-light Composer batch loops")
        for body in batchClosures {
            let loopLines = body.indices.filter { body[$0].hasPrefix("for batchStart in stride(") }
            for line in loopLines {
                // Packet 4: the guard's else body now REPORTS the cancellation
                // (with the operations accumulated so far) before returning —
                // the probe itself must still sit immediately above every
                // batch, including the first.
                XCTAssertTrue(body[line + 1].hasPrefix("guard await stillCurrent() else"),
                    "each Composer batch must be probed before it is dispatched")
                let elseBody = body[(line + 1)...].prefix(6)
                XCTAssertTrue(elseBody.contains(where: { $0.contains("kind: .cancelled,") }), """
                    a failed probe must report an honest cancelled terminal — \
                    silently returning would leave the item dangling forever
                    """)
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Composer 2 packet 4: canonical Composer bridge identity
    // ──────────────────────────────────────────────
    //
    // `startCompositionMode` computes `room.bridgeID ?? ""` and stores it in the
    // NONOPTIONAL `CompositionRuntime.bridgeID`, while `restSender(for:)`
    // normalizes a NIL bridge to the key "legacy". "" is not nil — so routing the
    // Composer mailbox through `bridgeID` gave a bridgeless room its own ""
    // sender while All-Day and Studio used "legacy": two mailboxes for one
    // conceptual bridge. Both Composer paths now key on `restBridgeIdentity`,
    // the room's original optional.
    //
    // These must hold TOGETHER. Moving only the enqueue side would leave
    // `clear(scope:)` aimed at a different actor, and packet 3's cooperative
    // cancellation would silently stop working for bridgeless rooms.

    /// The production resolver maps a bridgeless room to the SHARED "legacy"
    /// sender and never an empty-string one. Stop reaches that same mailbox
    /// WITHOUT creating anything (packet 4 dropped the old lazy creation:
    /// stopping an Entertainment-only session must not conjure a REST sender).
    func testBridgelessComposerRoomResolvesToTheLegacySender() async {
        orchestrator.testStageRESTComposition(roomID: "room-nil", bridgeID: nil, api: bridgeA)
        // The enqueue-side resolver — the same call the scheduler makes.
        _ = orchestrator.testRestSender(for: nil)
        let keysBefore = orchestrator.testRestSenderBridgeKeys()
        XCTAssertTrue(keysBefore.contains("legacy"), """
            a bridgeless room's Composer mailbox is the SHARED "legacy" sender — \
            keying it off the nonoptional bridgeID resolved "" instead
            """)
        XCTAssertFalse(keysBefore.contains(""), """
            no empty-string sender may ever be created: it is a second mailbox for \
            the same conceptual bridge, invisible to every other bridgeless path
            """)

        await orchestrator.stopCompositionMode(roomID: "room-nil", bridgeID: nil)

        XCTAssertEqual(orchestrator.testRestSenderBridgeKeys(), keysBefore, """
            stop resolves the SAME legacy mailbox by lookup — it neither creates \
            a new sender nor an empty-string one
            """)
    }

    /// Enqueue and clear must resolve the SAME sender for a bridgeless room.
    /// Proven by ordering: the stopped room's queued frame is dropped and a
    /// sibling scope's survives. If clear still keyed off the nonoptional
    /// `bridgeID` it would target a "" sender and "NIL" would have survived.
    func testBridgelessComposerEnqueueAndStopUseTheSameSender() async {
        orchestrator.testStageRESTComposition(roomID: "room-nil", bridgeID: nil, api: bridgeA)
        let legacySender = orchestrator.testRestSender(for: nil)
        let events = RestEventLog()

        let gate = await park(legacySender, events: events)
        await enqueueRecording(legacySender, composerScope("room-nil"), events, "NIL")
        await enqueueRecording(legacySender, composerScope("room-other"), events, "OTHER")

        await orchestrator.stopCompositionMode(roomID: "room-nil", bridgeID: nil)

        gate.release()
        await drain(legacySender)

        XCTAssertEqual(events.entries, ["OTHER"], """
            the stop reached the very mailbox the scheduler enqueues on, and \
            reached ONLY the stopped room's scope
            """)
    }

    /// Stop with the explicit nil identity clears EXACTLY the named room's
    /// scope on the legacy mailbox — with or without a REST runtime — and a
    /// sibling scope always survives. (Packet 4 replaced the old
    /// runtime-existence gate: identity comes from the caller now, so an
    /// Entertainment or bridge-stored stop still drops its stale mailbox work,
    /// and there is no bridge to guess wrong.)
    func testStopClearsOnlyTheNamedScopeOnTheLegacySender() async {
        let legacySender = orchestrator.testRestSender(for: nil)

        // (a) No runtime at all — the named scope is still cleared, the
        // sibling scope is untouched.
        let events = RestEventLog()
        let gateA = await park(legacySender, room: "__park-a__", events: events)
        await enqueueRecording(legacySender, composerScope("ghost"), events, "GHOST")
        await enqueueRecording(legacySender, composerScope("bystander"), events, "BYSTANDER")
        await orchestrator.stopCompositionMode(roomID: "ghost", bridgeID: nil)
        gateA.release()
        await drain(legacySender)
        XCTAssertEqual(events.entries, ["BYSTANDER"], """
            the named room's stale frame is dropped even without a runtime, and \
            only that room's — the sibling scope survives
            """)

        // (b) A staged bridgeless runtime — same outcome.
        orchestrator.testStageRESTComposition(roomID: "ghost", bridgeID: nil, api: bridgeA)
        let events2 = RestEventLog()
        let gateB = await park(legacySender, room: "__park-b__", events: events2)
        await enqueueRecording(legacySender, composerScope("ghost"), events2, "GHOST2")
        await orchestrator.stopCompositionMode(roomID: "ghost", bridgeID: nil)
        gateB.release()
        await drain(legacySender)
        XCTAssertTrue(events2.entries.isEmpty, """
            a bridgeless room DOES have a mailbox to clear — its scope on the \
            legacy sender is dropped
            """)
    }

    // ──────────────────────────────────────────────
    // MARK: - Composer 2 packet 4: honest completion-based telemetry
    // ──────────────────────────────────────────────
    //
    // The ledger's pure semantics live in CompositionRoomPriorityScorerTests.
    // Everything here is the ORCHESTRATOR's half: sender-evidence handling,
    // exact (bridgeKey, scope) session identity, publication refresh/expiry,
    // and completion-gated runtime bookkeeping — driven through the same
    // production helpers and closure factories the scheduler uses, under an
    // injected telemetry clock. No wall-clock waits anywhere.

    /// Packet-4 shorthand: begin a session and install a deterministic clock.
    private func stageTelemetrySession(
        room: String, bridge: String?, generation: Int = 1,
        restActive: Bool = true, clock: TelemetryTestClock,
        eligibleOperations: Int = 0
    ) {
        orchestrator.testSetCompositionTelemetryClock(clock.now)
        orchestrator.testBeginComposerTelemetrySession(
            roomID: room, bridgeID: bridge, generation: generation,
            isRESTActive: restActive, eligibleOperations: eligibleOperations)
    }

    /// One fully successful single-operation item, terminal at `finishAt`.
    @discardableResult
    private func completeComposerItem(
        room: String, bridge: String?, generation: Int = 1,
        clock: TelemetryTestClock, finishAt: CFAbsoluteTime,
        sentX: Double? = nil, sentY: Double? = nil, sentBri: Double? = nil
    ) async -> CompositionSendLedger.Token {
        let token = await orchestrator.testEnqueueComposerWork(
            roomID: room, bridgeID: bridge, generation: generation
        ) { _ in { _ in } }
        clock.advance(to: finishAt - 0.001)
        orchestrator.testReportComposerStarted(token)
        clock.advance(to: finishAt)
        orchestrator.testReportComposerCompleted(
            token: token, attemptedOperations: 1, failures: 0,
            sentX: sentX, sentY: sentY, sentBri: sentBri)
        return token
    }

    private func telemetrySnap(_ room: String, _ bridge: String?) -> CompositionSendLedger.Snapshot {
        orchestrator.testComposerLedgerSnapshot(roomID: room, bridgeID: bridge)
    }

    // 13. superseded comes from the SENDER's replacedPending — a pending slot
    //     that was actually overwritten — never from inference.
    func testSupersededIsRecordedOnlyOnSenderReportedReplacement() async {
        let clock = TelemetryTestClock(100)
        stageTelemetrySession(room: "room-a", bridge: "bridge-a", clock: clock)
        let sender = orchestrator.testRestSender(for: "bridge-a")
        let events = RestEventLog()

        // Park the sender on ANOTHER scope so room-a's slot stays pending.
        let gate = await park(sender, events: events)
        _ = await orchestrator.testEnqueueComposerWork(
            roomID: "room-a", bridgeID: "bridge-a", generation: 1
        ) { _ in { _ in events.record("FIRST") } }
        _ = await orchestrator.testEnqueueComposerWork(
            roomID: "room-a", bridgeID: "bridge-a", generation: 1
        ) { _ in { _ in events.record("SECOND") } }

        gate.release()
        await drain(sender)

        let snapshot = telemetrySnap("room-a", "bridge-a")
        XCTAssertEqual(snapshot.enqueuedItems, 2)
        XCTAssertEqual(snapshot.supersededItems, 1,
            "the sender reported one real replacement — FIRST never ran")
        XCTAssertEqual(snapshot.cancelledItems, 0,
            "superseded and cancelled are distinct counters")
        XCTAssertEqual(events.entries, ["SECOND"])
    }

    // 14. THE INFERENCE ERROR THE SENDER EVIDENCE PREVENTS: an enqueue over an
    //     item that has already been dequeued for execution replaces nothing,
    //     so nothing may be marked superseded.
    func testEnqueueOverAnExecutingItemDoesNotSupersedeIt() async {
        let clock = TelemetryTestClock(100)
        stageTelemetrySession(room: "room-a", bridge: "bridge-a", clock: clock)
        let sender = orchestrator.testRestSender(for: "bridge-a")

        // The FIRST item is dispatched immediately and parks INSIDE execution —
        // its pending slot is empty while it runs.
        let gate = RestGate()
        _ = await orchestrator.testEnqueueComposerWork(
            roomID: "room-a", bridgeID: "bridge-a", generation: 1
        ) { _ in
            { _ in
                gate.signalStarted()
                await gate.waitForRelease()
            }
        }
        await gate.waitUntilStarted()

        _ = await orchestrator.testEnqueueComposerWork(
            roomID: "room-a", bridgeID: "bridge-a", generation: 1
        ) { _ in { _ in } }

        gate.release()
        await drain(sender)

        XCTAssertEqual(telemetrySnap("room-a", "bridge-a").supersededItems, 0, """
            the sender reported replacedPending == false — the first item was \
            executing, not pending, and wrongly superseding it would erase a \
            send that actually happened
            """)
    }

    // 15. Stop consumes the sender's pending-removal evidence: the pending
    //     frame never runs, the tracker is cleaned, and the session ends
    //     deactivated.
    func testStopWithPendingWorkConsumesSenderEvidenceAndCleansTracker() async {
        let clock = TelemetryTestClock(100)
        orchestrator.testSetCompositionTelemetryClock(clock.now)
        orchestrator.testStageRESTComposition(roomID: "room-a", bridgeID: "bridge-a", api: bridgeA)
        let sender = orchestrator.testRestSender(for: "bridge-a")
        let events = RestEventLog()

        let gate = await park(sender, events: events)
        _ = await orchestrator.testEnqueueComposerWork(
            roomID: "room-a", bridgeID: "bridge-a", generation: 1
        ) { _ in { _ in events.record("RAN") } }
        XCTAssertNotNil(orchestrator.testComposerPendingToken(roomID: "room-a", bridgeID: "bridge-a"))

        await orchestrator.stopCompositionMode(roomID: "room-a", bridgeID: "bridge-a")

        gate.release()
        await drain(sender)

        XCTAssertTrue(events.entries.isEmpty, "the pending frame was dropped before it could run")
        XCTAssertNil(orchestrator.testComposerPendingToken(roomID: "room-a", bridgeID: "bridge-a"))
        XCTAssertEqual(telemetrySnap("room-a", "bridge-a"), .empty,
            "stop DEACTIVATES the session — nothing may linger")
        XCTAssertFalse(orchestrator.testComposerTelemetrySessions()
            .contains { $0.bridgeKey == "bridge-a" && $0.roomID == "room-a" })
    }

    // 16. An EXECUTING item is never terminalized by clear — it reports
    //     cancelled at its own next probe, with the operations it accumulated,
    //     and that report is ACCEPTED while its session is still active.
    func testExecutingWorkIsNotTerminalizedByClearAndReportsAtItsProbe() async {
        let clock = TelemetryTestClock(100)
        stageTelemetrySession(room: "room-a", bridge: "bridge-a", clock: clock)
        let sender = orchestrator.testRestSender(for: "bridge-a")

        let gate = RestGate()
        let orch = orchestrator!
        _ = await orchestrator.testEnqueueComposerWork(
            roomID: "room-a", bridgeID: "bridge-a", generation: 1
        ) { token in
            { stillCurrent in
                orch.testReportComposerStarted(token)
                gate.signalStarted()
                await gate.waitForRelease()
                if await stillCurrent() {
                    orch.testReportComposerCompleted(
                        token: token, attemptedOperations: 2, failures: 0)
                } else {
                    orch.testReportComposerCancelled(
                        token: token, attemptedOperations: 2, failures: 0)
                }
            }
        }
        await gate.waitUntilStarted()

        // Clear while it executes: RestSender reports NO pending removal, so
        // no 0/0 pending cancellation may be recorded for it.
        let removed = await sender.clear(scope: composerScope("room-a"))
        XCTAssertFalse(removed, "the work had started — nothing was pending")

        gate.release()
        await drain(sender)

        let snapshot = telemetrySnap("room-a", "bridge-a")
        XCTAssertEqual(snapshot.cancelledItems, 1,
            "the closure reported its OWN cancellation at the failed probe")
        XCTAssertEqual(snapshot.attemptedOperations, 2,
            "the operations dispatched before invalidation are preserved")
        XCTAssertEqual(snapshot.successfulItems, 1,
            "a partially successful cancelled item counts — not mutually exclusive")
    }

    // 17. Brian correction (round 3): a fast dispatch consumes the pending
    //     tracker via its started report — after enqueue returns there is no
    //     stale token, and a later clear of the empty scope records nothing.
    func testFastDispatchLeavesNoStalePendingTokenAndClearRecordsNothing() async {
        let clock = TelemetryTestClock(100)
        stageTelemetrySession(room: "room-a", bridge: "bridge-a", clock: clock)
        let sender = orchestrator.testRestSender(for: "bridge-a")

        let orch = orchestrator!
        _ = await orchestrator.testEnqueueComposerWork(
            roomID: "room-a", bridgeID: "bridge-a", generation: 1
        ) { token in
            { _ in
                orch.testReportComposerStarted(token)
                orch.testReportComposerCompleted(
                    token: token, attemptedOperations: 1, failures: 0)
            }
        }
        await drain(sender)

        XCTAssertNil(orchestrator.testComposerPendingToken(roomID: "room-a", bridgeID: "bridge-a"),
            "the started report consumed the tracker — no stale token survives")
        let removed = await sender.clear(scope: composerScope("room-a"))
        XCTAssertFalse(removed, "the scope is empty — the sender has nothing to remove")

        let snapshot = telemetrySnap("room-a", "bridge-a")
        XCTAssertEqual(snapshot.successfulItems, 1)
        XCTAssertEqual(snapshot.cancelledItems, 0,
            "no pending cancellation may be recorded without sender evidence")
    }

    // 18. Cadence EXPIRES with no new completion: only the injected clock
    //     advances, one refresh pass runs, and the number leaves the screen.
    func testCadenceExpiresWithoutANewCompletion() async {
        let clock = TelemetryTestClock(100)
        stageTelemetrySession(room: "room-a", bridge: "bridge-a", clock: clock)

        await completeComposerItem(room: "room-a", bridge: "bridge-a", clock: clock, finishAt: 100.5)
        await completeComposerItem(room: "room-a", bridge: "bridge-a", clock: clock, finishAt: 101.0)

        XCTAssertEqual(orchestrator.activeRESTCadence(roomID: "room-a", bridgeID: "bridge-a") ?? -1,
                       0.5, accuracy: 0.000001,
            "two completions 0.5 s apart publish a 0.5 s cadence")

        // Requests hang: no further events. Only the clock moves.
        clock.advance(to: 107.0)
        orchestrator.testRefreshComposerCadencePublications()

        XCTAssertNil(orchestrator.activeRESTCadence(roomID: "room-a", bridgeID: "bridge-a"), """
            the newest completion is 6 s old — past the 5 s horizon the number \
            must disappear rather than freeze at the last good value
            """)
    }

    // 19. Brian clarification 5: the per-pass refresh covers EVERY REST-active
    //     session, so room B expires even while room A keeps completing.
    func testTwoActiveRESTRoomsRefreshAndExpireIndependentlyPerSchedulerPass() async {
        let clock = TelemetryTestClock(100)
        stageTelemetrySession(room: "room-a", bridge: "bridge-a", clock: clock)
        stageTelemetrySession(room: "room-b", bridge: "bridge-a", clock: clock)

        await completeComposerItem(room: "room-b", bridge: "bridge-a", clock: clock, finishAt: 100.0)
        await completeComposerItem(room: "room-b", bridge: "bridge-a", clock: clock, finishAt: 101.0)
        await completeComposerItem(room: "room-a", bridge: "bridge-a", clock: clock, finishAt: 104.0)
        await completeComposerItem(room: "room-a", bridge: "bridge-a", clock: clock, finishAt: 105.0)

        XCTAssertNotNil(orchestrator.activeRESTCadence(roomID: "room-a", bridgeID: "bridge-a"))
        XCTAssertNotNil(orchestrator.activeRESTCadence(roomID: "room-b", bridgeID: "bridge-a"))

        // One pass at t=107.5: room A's newest completion is 2.5 s old (keeps
        // its number); room B's is 6.5 s old (expires) — with NO room selected
        // and NO new completion for either.
        clock.advance(to: 107.5)
        orchestrator.testRefreshComposerCadencePublications()

        XCTAssertEqual(orchestrator.activeRESTCadence(roomID: "room-a", bridgeID: "bridge-a") ?? -1,
                       1.0, accuracy: 0.000001, "room A keeps its valid value")
        XCTAssertNil(orchestrator.activeRESTCadence(roomID: "room-b", bridgeID: "bridge-a"),
            "room B expires without receiving another completion")
    }

    // 20. Brian correction (round 5): refresh eligibility is the EXACT retained
    //     session's isRESTActive — never the roomID-keyed transport map, which
    //     cannot tell identical room IDs on different bridges apart.
    func testSchedulerRefreshUsesExactSessionRESTStatusNotRoomTransport() async {
        let clock = TelemetryTestClock(100)
        // The SAME roomID on two bridges: A's session is REST-active, B's is an
        // Entertainment session (not REST-active).
        stageTelemetrySession(room: "shared-room", bridge: "bridge-a", restActive: true, clock: clock)
        stageTelemetrySession(room: "shared-room", bridge: "bridge-b", restActive: false, clock: clock)

        await completeComposerItem(room: "shared-room", bridge: "bridge-a", clock: clock, finishAt: 100.0)
        await completeComposerItem(room: "shared-room", bridge: "bridge-a", clock: clock, finishAt: 101.0)
        XCTAssertNotNil(orchestrator.activeRESTCadence(roomID: "shared-room", bridgeID: "bridge-a"))

        clock.advance(to: 108.0)
        orchestrator.testRefreshComposerCadencePublications()

        XCTAssertNil(orchestrator.activeRESTCadence(roomID: "shared-room", bridgeID: "bridge-a"),
            "the REST-active session was swept and expired")
        let sessions = orchestrator.testComposerTelemetrySessions()
        XCTAssertTrue(sessions.contains {
            $0.bridgeKey == "bridge-a" && $0.roomID == "shared-room" && $0.isRESTActive
        })
        XCTAssertTrue(sessions.contains {
            $0.bridgeKey == "bridge-b" && $0.roomID == "shared-room" && !$0.isRESTActive
        }, """
            bridge B's exact session coexists and stays NOT REST-active — \
            bridge A's roomID entry must not promote it
            """)
    }

    // 21. Stop deactivates: publication gone immediately, late reports from the
    //     stopped generation ignored, no session left behind.
    func testStopDeactivatesTelemetryAndRemovesPublication() async {
        let clock = TelemetryTestClock(100)
        orchestrator.testSetCompositionTelemetryClock(clock.now)
        orchestrator.testStageRESTComposition(roomID: "room-a", bridgeID: "bridge-a", api: bridgeA)

        await completeComposerItem(room: "room-a", bridge: "bridge-a", clock: clock, finishAt: 100.5)
        await completeComposerItem(room: "room-a", bridge: "bridge-a", clock: clock, finishAt: 101.0)
        XCTAssertNotNil(orchestrator.activeRESTCadence(roomID: "room-a", bridgeID: "bridge-a"))

        // An executing straggler from this generation…
        let straggler = await orchestrator.testEnqueueComposerWork(
            roomID: "room-a", bridgeID: "bridge-a", generation: 1
        ) { _ in { _ in } }
        orchestrator.testReportComposerStarted(straggler)

        await orchestrator.stopCompositionMode(roomID: "room-a", bridgeID: "bridge-a")

        XCTAssertNil(orchestrator.activeRESTCadence(roomID: "room-a", bridgeID: "bridge-a"),
            "publication is removed IMMEDIATELY at stop, not at the next horizon")
        XCTAssertFalse(orchestrator.testComposerTelemetrySessions()
            .contains { $0.bridgeKey == "bridge-a" && $0.roomID == "room-a" })

        // …whose late report is ignored after deactivation.
        orchestrator.testReportComposerCompleted(
            token: straggler, attemptedOperations: 3, failures: 0)
        XCTAssertEqual(telemetrySnap("room-a", "bridge-a"), .empty,
            "reports from a stopped generation die in the deactivated ledger")
    }

    // 22. An Entertainment-selected composition has NO REST runtime and maybe
    //     no REST sender — stop must still find and deactivate its telemetry
    //     session, and must not conjure a sender to do it.
    func testStoppingEntertainmentSelectedCompositionDeactivatesTelemetryAndCreatesNoSender() async {
        let clock = TelemetryTestClock(100)
        orchestrator.testStageEntertainmentOwner(roomID: "ent-room", bridgeID: "bridge-ent")
        stageTelemetrySession(room: "ent-room", bridge: "bridge-ent", restActive: false, clock: clock)
        let keysBefore = orchestrator.testRestSenderBridgeKeys()
        XCTAssertFalse(keysBefore.contains("bridge-ent"), "precondition: no REST sender exists")

        await orchestrator.stopCompositionMode(roomID: "ent-room", bridgeID: "bridge-ent")

        XCTAssertFalse(orchestrator.testComposerTelemetrySessions()
            .contains { $0.bridgeKey == "bridge-ent" && $0.roomID == "ent-room" },
            "the retained identity is how stop finds a session with no runtime")
        XCTAssertEqual(orchestrator.testRestSenderBridgeKeys(), keysBefore,
            "stopping an Entertainment-only session must not create a REST sender")
    }

    // 23. Brian correction (round 4): the SAME roomID on two bridges — stop
    //     with the explicit identity deactivates ONLY that bridge's session.
    func testStopWithExplicitIdentityDeactivatesOnlyThatBridgesSession() async {
        let clock = TelemetryTestClock(100)
        stageTelemetrySession(room: "shared", bridge: "bridge-a", clock: clock)
        stageTelemetrySession(room: "shared", bridge: "bridge-b", clock: clock)

        await completeComposerItem(room: "shared", bridge: "bridge-a", clock: clock, finishAt: 100.4)
        await completeComposerItem(room: "shared", bridge: "bridge-a", clock: clock, finishAt: 100.8)
        await completeComposerItem(room: "shared", bridge: "bridge-b", clock: clock, finishAt: 100.5)
        await completeComposerItem(room: "shared", bridge: "bridge-b", clock: clock, finishAt: 101.0)

        // A pending token on EACH bridge's mailbox for the same roomID.
        let senderA = orchestrator.testRestSender(for: "bridge-a")
        let senderB = orchestrator.testRestSender(for: "bridge-b")
        let eventsA = RestEventLog()
        let eventsB = RestEventLog()
        let gateA = await park(senderA, room: "__park-a__", events: eventsA)
        let gateB = await park(senderB, room: "__park-b__", events: eventsB)
        _ = await orchestrator.testEnqueueComposerWork(
            roomID: "shared", bridgeID: "bridge-a", generation: 1) { _ in { _ in } }
        _ = await orchestrator.testEnqueueComposerWork(
            roomID: "shared", bridgeID: "bridge-b", generation: 1) { _ in { _ in } }

        await orchestrator.stopCompositionMode(roomID: "shared", bridgeID: "bridge-a")

        gateA.release()
        gateB.release()
        await drain(senderA)
        await drain(senderB)

        XCTAssertFalse(orchestrator.testComposerTelemetrySessions()
            .contains { $0.bridgeKey == "bridge-a" && $0.roomID == "shared" })
        XCTAssertTrue(orchestrator.testComposerTelemetrySessions()
            .contains { $0.bridgeKey == "bridge-b" && $0.roomID == "shared" },
            "bridge B's session for the SAME roomID must survive untouched")
        XCTAssertNil(orchestrator.testComposerPendingToken(roomID: "shared", bridgeID: "bridge-a"))
        XCTAssertNotNil(orchestrator.testComposerPendingToken(roomID: "shared", bridgeID: "bridge-b"),
            "bridge B's pending tracker survives")
        XCTAssertNil(orchestrator.activeRESTCadence(roomID: "shared", bridgeID: "bridge-a"))
        XCTAssertNotNil(orchestrator.activeRESTCadence(roomID: "shared", bridgeID: "bridge-b"),
            "bridge B's publication survives")
        XCTAssertNotEqual(telemetrySnap("shared", "bridge-b"), .empty,
            "bridge B's counters survive")
    }

    // 24. Bridge removal clears that bridge's sessions, tokens, and publication
    //     — and no other bridge's.
    func testBridgeRemovalClearsOnlyThatBridgesTelemetry() async {
        let clock = TelemetryTestClock(100)
        stageTelemetrySession(room: "room-a", bridge: "bridge-a", clock: clock)
        stageTelemetrySession(room: "room-b", bridge: "bridge-b", clock: clock)
        await completeComposerItem(room: "room-a", bridge: "bridge-a", clock: clock, finishAt: 100.4)
        await completeComposerItem(room: "room-a", bridge: "bridge-a", clock: clock, finishAt: 100.8)
        await completeComposerItem(room: "room-b", bridge: "bridge-b", clock: clock, finishAt: 100.5)
        await completeComposerItem(room: "room-b", bridge: "bridge-b", clock: clock, finishAt: 101.0)

        await orchestrator.removeBridge(id: "bridge-a")

        XCTAssertFalse(orchestrator.testComposerTelemetrySessions()
            .contains { $0.bridgeKey == "bridge-a" })
        XCTAssertNil(orchestrator.activeRESTCadence(roomID: "room-a", bridgeID: "bridge-a"))
        XCTAssertTrue(orchestrator.testComposerTelemetrySessions()
            .contains { $0.bridgeKey == "bridge-b" && $0.roomID == "room-b" })
        XCTAssertNotNil(orchestrator.activeRESTCadence(roomID: "room-b", bridgeID: "bridge-b"),
            "another bridge's telemetry must survive a removal")
    }

    // 25. Forget-all leaves NOTHING: no sessions, no tokens, no publication —
    //     including sessions on bridges that never had a REST sender.
    func testForgetAllLeavesNoTelemetrySessionsTokensOrPublication() async {
        let clock = TelemetryTestClock(100)
        stageTelemetrySession(room: "room-a", bridge: "bridge-a", clock: clock)
        stageTelemetrySession(room: "ent-room", bridge: "bridge-ent", restActive: false, clock: clock)
        await completeComposerItem(room: "room-a", bridge: "bridge-a", clock: clock, finishAt: 100.4)
        await completeComposerItem(room: "room-a", bridge: "bridge-a", clock: clock, finishAt: 100.8)
        let sender = orchestrator.testRestSender(for: "bridge-a")
        let events = RestEventLog()
        let gate = await park(sender, events: events)
        _ = await orchestrator.testEnqueueComposerWork(
            roomID: "room-a", bridgeID: "bridge-a", generation: 1) { _ in { _ in } }
        gate.release()

        await orchestrator.forgetAllBridges()

        XCTAssertTrue(orchestrator.testComposerTelemetrySessions().isEmpty,
            "no active telemetry session may survive forget-all")
        XCTAssertNil(orchestrator.testComposerPendingToken(roomID: "room-a", bridgeID: "bridge-a"))
        XCTAssertNil(orchestrator.activeRESTCadence(roomID: "room-a", bridgeID: "bridge-a"))
        XCTAssertEqual(telemetrySnap("room-a", "bridge-a"), .empty)
        XCTAssertEqual(telemetrySnap("ent-room", "bridge-ent"), .empty,
            "even a session whose bridge never had a sender is deactivated")
    }

    // 26. Runtime bookkeeping: a fully successful ACCEPTED completion advances
    //     the delta gate, with lastSentAt from the SAME terminal clock sample.
    func testFullySuccessfulCompletionAdvancesRuntimeBookkeeping() async {
        let clock = TelemetryTestClock(200)
        orchestrator.testSetCompositionTelemetryClock(clock.now)
        orchestrator.testStageRESTComposition(roomID: "room-a", bridgeID: "bridge-a", api: bridgeA)

        await completeComposerItem(
            room: "room-a", bridge: "bridge-a", clock: clock, finishAt: 200.7,
            sentX: 0.41, sentY: 0.36, sentBri: 55)

        let state = orchestrator.testCompositionRuntimeSendState(roomID: "room-a")
        XCTAssertEqual(state?.sendCount, 1)
        XCTAssertEqual(state?.lastSentX ?? -1, 0.41, accuracy: 0.000001)
        XCTAssertEqual(state?.lastSentY ?? -1, 0.36, accuracy: 0.000001)
        XCTAssertEqual(state?.lastSentBri ?? -1, 55, accuracy: 0.000001)
        XCTAssertEqual(state?.lastSentAt ?? -1, 200.7, accuracy: 0.000001,
            "lastSentAt is the SAME terminalAt the ledger recorded — one clock sample")
    }

    // 27. Partial and all-failed completions leave the delta gate untouched, so
    //     the frame stays eligible for re-send.
    func testPartialOrAllFailedCompletionLeavesRuntimeDeltaStateUnchanged() async {
        let clock = TelemetryTestClock(200)
        orchestrator.testSetCompositionTelemetryClock(clock.now)
        orchestrator.testStageRESTComposition(roomID: "room-a", bridgeID: "bridge-a", api: bridgeA)

        let partial = await orchestrator.testEnqueueComposerWork(
            roomID: "room-a", bridgeID: "bridge-a", generation: 1) { _ in { _ in } }
        orchestrator.testReportComposerStarted(partial)
        orchestrator.testReportComposerCompleted(
            token: partial, attemptedOperations: 5, failures: 2,
            sentX: 0.5, sentY: 0.5, sentBri: 50)

        let allFailed = await orchestrator.testEnqueueComposerWork(
            roomID: "room-a", bridgeID: "bridge-a", generation: 1) { _ in { _ in } }
        orchestrator.testReportComposerStarted(allFailed)
        orchestrator.testReportComposerCompleted(
            token: allFailed, attemptedOperations: 5, failures: 5,
            sentX: 0.5, sentY: 0.5, sentBri: 50)

        let state = orchestrator.testCompositionRuntimeSendState(roomID: "room-a")
        XCTAssertEqual(state?.sendCount, 0, "no fully successful completion happened")
        XCTAssertNil(state?.lastSentX)
        XCTAssertNil(state?.lastSentAt)
    }

    // 28. SUCCESSFUL-BUT-CANCELLED: telemetry records the contributing item,
    //     but the runtime delta gate must NOT advance.
    func testSuccessfulButCancelledDoesNotAdvanceRuntime() async {
        let clock = TelemetryTestClock(200)
        orchestrator.testSetCompositionTelemetryClock(clock.now)
        orchestrator.testStageRESTComposition(roomID: "room-a", bridgeID: "bridge-a", api: bridgeA)

        let token = await orchestrator.testEnqueueComposerWork(
            roomID: "room-a", bridgeID: "bridge-a", generation: 1) { _ in { _ in } }
        orchestrator.testReportComposerStarted(token)
        // One 5-op batch succeeded, then the probe failed.
        orchestrator.testReportComposerCancelled(
            token: token, attemptedOperations: 5, failures: 0)

        let snapshot = telemetrySnap("room-a", "bridge-a")
        XCTAssertEqual(snapshot.successfulItems, 1)
        XCTAssertEqual(snapshot.cancelledItems, 1)
        let state = orchestrator.testCompositionRuntimeSendState(roomID: "room-a")
        XCTAssertEqual(state?.sendCount, 0, """
            cancelled work left lights mid-sweep — claiming the frame was sent \
            would freeze the delta gate on a half-applied state
            """)
        XCTAssertNil(state?.lastSentAt)
    }

    // 29. Brian correction (round 5): ledger ACCEPTANCE gates bookkeeping — a
    //     duplicate completed report increments sendCount exactly once.
    func testDuplicateCompletedReportsIncrementRuntimeSendCountOnlyOnce() async {
        let clock = TelemetryTestClock(200)
        orchestrator.testSetCompositionTelemetryClock(clock.now)
        orchestrator.testStageRESTComposition(roomID: "room-a", bridgeID: "bridge-a", api: bridgeA)

        let token = await orchestrator.testEnqueueComposerWork(
            roomID: "room-a", bridgeID: "bridge-a", generation: 1) { _ in { _ in } }
        orchestrator.testReportComposerStarted(token)
        orchestrator.testReportComposerCompleted(
            token: token, attemptedOperations: 1, failures: 0, sentX: 0.4, sentY: 0.3, sentBri: 40)
        orchestrator.testReportComposerCompleted(
            token: token, attemptedOperations: 1, failures: 0, sentX: 0.9, sentY: 0.9, sentBri: 90)

        let state = orchestrator.testCompositionRuntimeSendState(roomID: "room-a")
        XCTAssertEqual(state?.sendCount, 1, "the duplicate was rejected by the ledger")
        XCTAssertEqual(state?.lastSentX ?? -1, 0.4, accuracy: 0.000001,
            "the duplicate's values must not overwrite the accepted ones")
    }

    // 30. Brian correction (round 5): a same-generation token wiped by a
    //     session reset cannot update the newer runtime when its late
    //     completion finally arrives.
    func testSameGenerationTokenRemovedByBeginSessionCannotUpdateNewerRuntime() async {
        let clock = TelemetryTestClock(200)
        orchestrator.testSetCompositionTelemetryClock(clock.now)
        orchestrator.testStageRESTComposition(roomID: "room-a", bridgeID: "bridge-a", api: bridgeA)

        let old = await orchestrator.testEnqueueComposerWork(
            roomID: "room-a", bridgeID: "bridge-a", generation: 1) { _ in { _ in } }
        orchestrator.testReportComposerStarted(old)

        // The transport window resets — SAME numeric generation.
        orchestrator.testBeginComposerTelemetrySession(
            roomID: "room-a", bridgeID: "bridge-a", generation: 1, isRESTActive: true)

        orchestrator.testReportComposerCompleted(
            token: old, attemptedOperations: 3, failures: 0,
            sentX: 0.7, sentY: 0.7, sentBri: 70)

        let state = orchestrator.testCompositionRuntimeSendState(roomID: "room-a")
        XCTAssertEqual(state?.sendCount, 0, """
            generation equality alone passes; token STATE does not — the wiped \
            token's completion is rejected and the runtime stays untouched
            """)
        XCTAssertEqual(telemetrySnap("room-a", "bridge-a"), .empty)
    }

    // 31. Brian correction (round 5): completed-before-started is rejected and
    //     cannot move the runtime either.
    func testCompletedBeforeStartedCannotUpdateRuntimeBookkeeping() async {
        let clock = TelemetryTestClock(200)
        orchestrator.testSetCompositionTelemetryClock(clock.now)
        orchestrator.testStageRESTComposition(roomID: "room-a", bridgeID: "bridge-a", api: bridgeA)

        let token = await orchestrator.testEnqueueComposerWork(
            roomID: "room-a", bridgeID: "bridge-a", generation: 1) { _ in { _ in } }
        // No started report — straight to completed.
        orchestrator.testReportComposerCompleted(
            token: token, attemptedOperations: 3, failures: 0,
            sentX: 0.7, sentY: 0.7, sentBri: 70)

        XCTAssertEqual(orchestrator.testCompositionRuntimeSendState(roomID: "room-a")?.sendCount, 0)
        XCTAssertEqual(telemetrySnap("room-a", "bridge-a").successfulItems, 0)
    }

    // 32. Brian correction (round 4): a session reset leaves no prior pending
    //     tracker that could later be misreported as a cancellation.
    func testSessionBeginLeavesNoPriorPendingTokenToMisreportAsCancellation() async {
        let clock = TelemetryTestClock(100)
        orchestrator.testSetCompositionTelemetryClock(clock.now)
        orchestrator.testStageRESTComposition(roomID: "room-a", bridgeID: "bridge-a", api: bridgeA)
        let sender = orchestrator.testRestSender(for: "bridge-a")
        let events = RestEventLog()

        let gate = await park(sender, events: events)
        _ = await orchestrator.testEnqueueComposerWork(
            roomID: "room-a", bridgeID: "bridge-a", generation: 1) { _ in { _ in } }
        XCTAssertNotNil(orchestrator.testComposerPendingToken(roomID: "room-a", bridgeID: "bridge-a"))

        // New session at the same key: the orchestrator's own stale tracking is
        // cleared BEFORE install.
        orchestrator.testBeginComposerTelemetrySession(
            roomID: "room-a", bridgeID: "bridge-a", generation: 2, isRESTActive: true)
        XCTAssertNil(orchestrator.testComposerPendingToken(roomID: "room-a", bridgeID: "bridge-a"),
            "no prior pending tracker survives the reset")

        // Stop now consumes REAL sender evidence (the old closure IS still
        // pending in the mailbox) — but with no tracked token there is nothing
        // to misreport, and the fresh session simply deactivates.
        await orchestrator.stopCompositionMode(roomID: "room-a", bridgeID: "bridge-a")
        gate.release()
        await drain(sender)
        XCTAssertEqual(telemetrySnap("room-a", "bridge-a"), .empty)
    }

    // 33. Brian correction (round 3): attemptedOperations counts only requests
    //     the task groups actually dispatched — never the room's size.
    //
    //     Packet 5 rewrote the SCENARIO while keeping the invariant. This used
    //     to prove the point with frameless entries (the closures skipped an
    //     entry whose channel range fell past a truncated frame array). That
    //     path is now unreachable by construction — the whole room is always
    //     rendered — and is an assertionFailure if it ever happens again,
    //     because a batch dispatching fewer operations than its slice would
    //     pin the rotation cursor and stall the room forever. The honest
    //     modern scenario is the one the scheduler actually produces: a room
    //     larger than one sweep hands the closure a SUBSET.
    func testAttemptedOperationsCountOnlyDispatchedRequests() async {
        let clock = TelemetryTestClock(100)
        stageTelemetrySession(room: "room-g", bridge: "bridge-a", clock: clock)
        stageTelemetrySession(room: "room-p", bridge: "bridge-a", clock: clock)
        let sender = orchestrator.testRestSender(for: "bridge-a")

        // A four-light room rendered in full…
        let frames = (0..<4).map {
            LightFrame(channelID: $0, x: 0.4, y: 0.35, brightness: 0.5)
        }
        let orch = orchestrator!

        // …of which this sweep dispatches only the first two entries.
        let allEntries: [GradientChannelMap.Entry] = [
            .init(lightID: "L1", channelStart: 0, channelCount: 1),
            .init(lightID: "L2", channelStart: 1, channelCount: 1),
            .init(lightID: "L3", channelStart: 2, channelCount: 2),
        ]
        _ = await orchestrator.testEnqueueComposerWork(
            roomID: "room-g", bridgeID: "bridge-a", generation: 1
        ) { token in
            orch.testMakeComposerGradientWork(
                token: token, entries: Array(allEntries.prefix(2)), frames: frames,
                api: self.bridgeA, gamut: .c, sentX: 0.4, sentY: 0.35, sentBri: 50)
        }
        await drain(sender)

        let gradientSnap = telemetrySnap("room-g", "bridge-a")
        XCTAssertEqual(gradientSnap.attemptedOperations, 2, """
            the room has 3 entries but this sweep was handed 2 — \
            attemptedOperations reports what the task group actually ran
            """)

        // PER-LIGHT: a four-light room, two of them in this sweep's subset.
        _ = await orchestrator.testEnqueueComposerWork(
            roomID: "room-p", bridgeID: "bridge-a", generation: 1
        ) { token in
            orch.testMakeComposerPerLightWork(
                token: token,
                targets: [(frameIndex: 0, lightID: "P1"), (frameIndex: 1, lightID: "P2")],
                frames: frames,
                api: self.bridgeA, gamut: .c, sentX: 0.4, sentY: 0.35, sentBri: 50)
        }
        await drain(sender)

        let perLightSnap = telemetrySnap("room-p", "bridge-a")
        XCTAssertEqual(perLightSnap.attemptedOperations, 2, """
            the room has 4 lights but this sweep was handed 2 — never the \
            room's size
            """)
        XCTAssertEqual(Set(bridgeA.lightEffectIDs), ["L1", "L2", "P1", "P2"],
            "exactly the dispatched requests reached the API")
    }

    // 33b. Packet 5: a subset's ABSOLUTE frame indices are what pair a light
    //      with its colour. Dispatching the tail of a room must send the
    //      tail's frames — not frames 0…n re-read from the top.
    func testSubsetDispatchUsesAbsoluteFrameIndices() async {
        let clock = TelemetryTestClock(100)
        stageTelemetrySession(room: "room-t", bridge: "bridge-a", clock: clock)
        let sender = orchestrator.testRestSender(for: "bridge-a")

        // Six lights, each with a distinguishable brightness.
        let frames = (0..<6).map {
            LightFrame(channelID: $0, x: 0.4, y: 0.35, brightness: Double($0) / 10.0)
        }
        let orch = orchestrator!
        // The second sweep of a rotation: lights 4 and 5.
        _ = await orchestrator.testEnqueueComposerWork(
            roomID: "room-t", bridgeID: "bridge-a", generation: 1
        ) { token in
            orch.testMakeComposerPerLightWork(
                token: token,
                targets: [(frameIndex: 4, lightID: "L4"), (frameIndex: 5, lightID: "L5")],
                frames: frames,
                api: self.bridgeA, gamut: .c, sentX: 0.4, sentY: 0.35, sentBri: 50)
        }
        await drain(sender)

        XCTAssertEqual(bridgeA.lightEffectIDs, ["L4", "L5"])
        // brightness is sent as a percentage with a 1% floor: frame 4 → 40, 5 → 50.
        XCTAssertEqual(bridgeA.lightEffectBrightnesses, [40, 50],
            "each light must receive ITS OWN frame, addressed absolutely")
    }

    // 34. The REAL closures still probe before the FIRST batch (packet 3), and
    //     the cancellation they report is honest: started, zero operations.
    func testRealComposerClosuresProbeBeforeTheFirstBatch() async {
        let clock = TelemetryTestClock(100)
        stageTelemetrySession(room: "room-a", bridge: "bridge-a", clock: clock)
        let sender = orchestrator.testRestSender(for: "bridge-a")

        // Mint + track a token through the production enqueue path (no-op
        // mailbox work), then run the REAL per-light closure with a probe that
        // is already false — as after a clear that bumped the epoch.
        let token = await orchestrator.testEnqueueComposerWork(
            roomID: "room-a", bridgeID: "bridge-a", generation: 1
        ) { _ in { _ in } }
        await drain(sender)

        let work = orchestrator.testMakeComposerPerLightWork(
            token: token,
            targets: [(frameIndex: 0, lightID: "P1"), (frameIndex: 1, lightID: "P2")],
            frames: [LightFrame(channelID: 0, x: 0.4, y: 0.35, brightness: 0.5),
                     LightFrame(channelID: 1, x: 0.45, y: 0.30, brightness: 0.6)],
            api: bridgeA, gamut: .c, sentX: 0.4, sentY: 0.35, sentBri: 50)
        let dispatchedBefore = bridgeA.lightEffectIDs.count
        await work({ false })

        XCTAssertEqual(bridgeA.lightEffectIDs.count, dispatchedBefore,
            "a failed FIRST probe dispatches nothing — batch 1 is guarded too")
        let snapshot = telemetrySnap("room-a", "bridge-a")
        XCTAssertEqual(snapshot.startedItems, 1, "the sweep still STARTED")
        XCTAssertEqual(snapshot.cancelledItems, 1)
        XCTAssertEqual(snapshot.attemptedOperations, 0,
            "zero operations were dispatched before the probe failed")
    }

    // 35. Isolation: rooms, bridges, and owners do not leak into each other's
    //     ledgers or publications.
    func testTelemetryIsolationAcrossRoomsBridgesAndOwners() async {
        let clock = TelemetryTestClock(100)
        stageTelemetrySession(room: "room-a", bridge: "bridge-a", clock: clock)
        stageTelemetrySession(room: "room-b", bridge: "bridge-a", clock: clock)
        stageTelemetrySession(room: "room-a", bridge: "bridge-b", clock: clock)
        let sender = orchestrator.testRestSender(for: "bridge-a")

        await completeComposerItem(room: "room-a", bridge: "bridge-a", clock: clock, finishAt: 100.4)
        await completeComposerItem(room: "room-a", bridge: "bridge-a", clock: clock, finishAt: 100.8)

        // A Studio enqueue on the SAME room and bridge (packet 3 scope model).
        await sender.enqueue(scope: studioScope("room-a")) { _ in }
        await drain(sender)

        XCTAssertNotNil(orchestrator.activeRESTCadence(roomID: "room-a", bridgeID: "bridge-a"))
        XCTAssertNil(orchestrator.activeRESTCadence(roomID: "room-b", bridgeID: "bridge-a"),
            "room B never completed anything — its cadence is nil")
        XCTAssertNil(orchestrator.activeRESTCadence(roomID: "room-a", bridgeID: "bridge-b"),
            "the same roomID on another bridge publishes independently")
        let snapshot = telemetrySnap("room-a", "bridge-a")
        XCTAssertEqual(snapshot.enqueuedItems, 2,
            "the .studio enqueue left the .composer ledger untouched")
    }

    // 36. Re-staging a composition (a transport switch, a restart) begins a
    //     FRESH telemetry session — nothing carries over.
    func testRestagingACompositionBeginsAFreshTelemetrySession() async {
        let clock = TelemetryTestClock(100)
        orchestrator.testSetCompositionTelemetryClock(clock.now)
        orchestrator.testStageRESTComposition(roomID: "room-a", bridgeID: "bridge-a", api: bridgeA)

        let old = await orchestrator.testEnqueueComposerWork(
            roomID: "room-a", bridgeID: "bridge-a", generation: 1) { _ in { _ in } }
        orchestrator.testReportComposerStarted(old)
        await completeComposerItem(room: "room-a", bridge: "bridge-a", clock: clock, finishAt: 100.5)
        XCTAssertNotEqual(telemetrySnap("room-a", "bridge-a"), .empty)

        // Restart the composition (stage runs the same session-begin the
        // production start runs).
        orchestrator.testStageRESTComposition(roomID: "room-a", bridgeID: "bridge-a", api: bridgeA)

        XCTAssertEqual(telemetrySnap("room-a", "bridge-a"), .empty,
            "the new transport window starts from a blank ledger")
        orchestrator.testReportComposerCompleted(
            token: old, attemptedOperations: 4, failures: 0)
        XCTAssertEqual(telemetrySnap("room-a", "bridge-a"), .empty,
            "the pre-restart token's late completion is ignored")
    }

    // 37. Amendment (round 6): a REJECTED terminal must not consume the pending
    //     tracker — only ledger acceptance, or the sender's own clear/clearAll
    //     evidence, may. Otherwise a bad report would erase the teardown's map
    //     of what the mailbox still holds.
    func testRejectedTerminalBeforeStartPreservesPendingTrackerUntilSenderClear() async {
        let clock = TelemetryTestClock(100)
        orchestrator.testSetCompositionTelemetryClock(clock.now)
        orchestrator.testStageRESTComposition(roomID: "room-a", bridgeID: "bridge-a", api: bridgeA)
        let sender = orchestrator.testRestSender(for: "bridge-a")
        let events = RestEventLog()

        // A genuinely pending token: the sender is parked on another scope.
        let gate = await park(sender, events: events)
        let pending = await orchestrator.testEnqueueComposerWork(
            roomID: "room-a", bridgeID: "bridge-a", generation: 1
        ) { _ in { _ in events.record("PENDING-RAN") } }

        // Completed-before-started: the ledger rejects it…
        orchestrator.testReportComposerCompleted(
            token: pending, attemptedOperations: 3, failures: 0)
        XCTAssertEqual(telemetrySnap("room-a", "bridge-a").successfulItems, 0,
            "the invalid terminal was rejected")
        // …and the tracker still holds the exact token.
        XCTAssertEqual(
            orchestrator.testComposerPendingToken(roomID: "room-a", bridgeID: "bridge-a"),
            pending,
            "a rejected terminal must not mutate the pending tracker")

        // The sender's own evidence then consumes it: stop clears the scope,
        // the clear reports an actual pending removal, and the teardown helper
        // cancels the CORRECT tracked token before deactivating.
        await orchestrator.stopCompositionMode(roomID: "room-a", bridgeID: "bridge-a")
        gate.release()
        await drain(sender)

        XCTAssertTrue(events.entries.isEmpty,
            "the pending closure was really removed — it never ran")
        XCTAssertNil(orchestrator.testComposerPendingToken(roomID: "room-a", bridgeID: "bridge-a"))
        XCTAssertEqual(telemetrySnap("room-a", "bridge-a"), .empty)
    }

    // 38. Amendment (round 6): stopStudioMode is stop-EVERYTHING — it sweeps
    //     every retained session by exact key, including sessions whose bridge
    //     never created a REST sender, and conjures nothing to do it.
    func testStopStudioModeDeactivatesSenderlessEntertainmentTelemetry() async {
        let clock = TelemetryTestClock(100)
        orchestrator.testSetCompositionTelemetryClock(clock.now)
        // Entertainment-only session: no RestSender exists for its bridge.
        orchestrator.testBeginComposerTelemetrySession(
            roomID: "ent-room", bridgeID: "bridge-ent", generation: 1, isRESTActive: false)
        // Plus a live REST session with a pending token and a published cadence.
        orchestrator.testStageRESTComposition(roomID: "room-a", bridgeID: "bridge-a", api: bridgeA)
        await completeComposerItem(room: "room-a", bridge: "bridge-a", clock: clock, finishAt: 100.4)
        await completeComposerItem(room: "room-a", bridge: "bridge-a", clock: clock, finishAt: 100.8)
        let sender = orchestrator.testRestSender(for: "bridge-a")
        let events = RestEventLog()
        let gate = await park(sender, events: events)
        _ = await orchestrator.testEnqueueComposerWork(
            roomID: "room-a", bridgeID: "bridge-a", generation: 1) { _ in { _ in } }
        let keysBefore = orchestrator.testRestSenderBridgeKeys()

        await orchestrator.stopStudioMode()
        gate.release()

        XCTAssertTrue(orchestrator.testComposerTelemetrySessions().isEmpty,
            "no retained session may survive the global stop — senderless ones included")
        XCTAssertNil(orchestrator.testComposerPendingToken(roomID: "room-a", bridgeID: "bridge-a"))
        XCTAssertNil(orchestrator.activeRESTCadence(roomID: "room-a", bridgeID: "bridge-a"))
        XCTAssertEqual(telemetrySnap("ent-room", "bridge-ent"), .empty)
        XCTAssertEqual(orchestrator.testRestSenderBridgeKeys(), keysBefore,
            "the sweep must not create a sender for bridge-ent")
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - Composer 2 packet 5 — rolling subsets, honest degradation
    // ──────────────────────────────────────────────────────────
    //
    // Everything below is proven by recorded state and event ORDER. Nothing is
    // proven by elapsed time: no Task.sleep as evidence, no waiter, no
    // timeout, no clock arithmetic standing in for a guarantee.

    /// Run one sweep's worth of per-light work through the PRODUCTION factory,
    /// so what these tests exercise is exactly what the scheduler builds.
    @discardableResult
    private func runSweep(
        room: String, bridge: String?, generation: Int = 1,
        cursor: Int, count: Int, totalLights: Int,
        failing: Set<String> = []
    ) async -> CompositionSendLedger.Token {
        let frames = (0..<totalLights).map {
            LightFrame(channelID: $0, x: 0.4, y: 0.35, brightness: Double($0 % 10) / 10.0)
        }
        let targets = (cursor..<(cursor + count)).map {
            (frameIndex: $0, lightID: "L\($0)")
        }
        bridgeA.stageLightEffectFailures(failing)
        let orch = orchestrator!
        let api = bridge == "bridge-b" ? bridgeB! : bridgeA!
        let token = await orchestrator.testEnqueueComposerWork(
            roomID: room, bridgeID: bridge, generation: generation
        ) { token in
            orch.testMakeComposerPerLightWork(
                token: token, targets: targets, frames: frames,
                api: api, gamut: .c, sentX: 0.4, sentY: 0.35, sentBri: 50)
        }
        await drain(orchestrator.testRestSender(for: bridge))
        return token
    }

    private func rotation(
        _ room: String, _ bridge: String?
    ) -> (cursor: Int, eligibleOperationCount: Int,
          hadFailure: Bool, completedSuccessfulRotation: Bool)? {
        orchestrator.testCompositionRotationState(roomID: room, bridgeID: bridge)
    }

    // P5-1. A room at or under the sweep budget completes its rotation in one
    //       sweep and becomes eligible to quiesce.
    func testSmallRoomCompletesItsRotationInASingleSweep() async {
        let clock = TelemetryTestClock(100)
        stageTelemetrySession(room: "small", bridge: "bridge-a", clock: clock,
                              eligibleOperations: 20)
        await runSweep(room: "small", bridge: "bridge-a",
                       cursor: 0, count: 20, totalLights: 20)

        let r = rotation("small", "bridge-a")
        XCTAssertEqual(r?.cursor, 0, "a 20-light room is back at the boundary")
        XCTAssertEqual(r?.completedSuccessfulRotation, true)
        XCTAssertEqual(bridgeA.lightEffectIDs.count, 20)
    }

    // P5-2. 21 lights: sweep 1 dispatches 0…19, sweep 2 dispatches ONLY 20.
    //       No wraparound — that is what makes "exactly once per rotation"
    //       true and lets a static look go quiet.
    func testTwentyOneLightsRotateTwentyThenOneWithoutWrapping() async {
        let clock = TelemetryTestClock(100)
        stageTelemetrySession(room: "big", bridge: "bridge-a", clock: clock,
                              eligibleOperations: 21)

        await runSweep(room: "big", bridge: "bridge-a",
                       cursor: 0, count: 20, totalLights: 21)
        XCTAssertEqual(rotation("big", "bridge-a")?.cursor, 20)
        XCTAssertEqual(rotation("big", "bridge-a")?.completedSuccessfulRotation, false,
            "mid-rotation: the room has not been fully delivered yet")

        await runSweep(room: "big", bridge: "bridge-a",
                       cursor: 20, count: 1, totalLights: 21)
        XCTAssertEqual(rotation("big", "bridge-a")?.cursor, 0)
        XCTAssertEqual(rotation("big", "bridge-a")?.completedSuccessfulRotation, true)

        // Operations WITHIN a batch run concurrently, so their completion
        // order is not defined — the guarantees are coverage and partitioning,
        // not intra-batch sequence.
        let served = bridgeA.lightEffectIDs
        XCTAssertEqual(served.count, 21, "no light served twice in one rotation")
        XCTAssertEqual(Set(served), Set((0..<21).map { "L\($0)" }),
            "every light served exactly once per rotation")
        XCTAssertEqual(served.last, "L20",
            "the second sweep carried ONLY light 20 — the partition did not wrap")
        XCTAssertEqual(Set(served.prefix(20)), Set((0..<20).map { "L\($0)" }),
            "the first sweep carried exactly lights 0…19")
    }

    // P5-3. Failed attempts still advance the cursor — they were attempted —
    //       and attemptedOperations agrees, because both read the same
    //       outcomes array.
    func testFailedAttemptsAdvanceTheCursorAndAreCountedAsAttempted() async {
        let clock = TelemetryTestClock(100)
        stageTelemetrySession(room: "f", bridge: "bridge-a", clock: clock,
                              eligibleOperations: 21)

        await runSweep(room: "f", bridge: "bridge-a",
                       cursor: 0, count: 5, totalLights: 21,
                       failing: ["L1", "L3"])

        XCTAssertEqual(rotation("f", "bridge-a")?.cursor, 5,
            "5 attempted → cursor 5, whatever the outcomes were")
        let snap = telemetrySnap("f", "bridge-a")
        XCTAssertEqual(snap.attemptedOperations, 5)
        XCTAssertEqual(snap.failures, 2)
        XCTAssertEqual(snap.successfulOperations, 3)
        XCTAssertEqual(rotation("f", "bridge-a")?.hadFailure, true,
            "the rotation is tainted even though the cursor moved")
    }

    // P5-4. A failure ANYWHERE in a rotation withholds quiescence, so the room
    //       re-rotates and retries. This is the defect the amendment closed:
    //       completion-only bookkeeping already refuses to record a partially
    //       failed sweep, and the gate must not overrule it.
    func testAFailureEarlyInARotationPreventsQuiescence() async {
        let clock = TelemetryTestClock(100)
        stageTelemetrySession(room: "e", bridge: "bridge-a", clock: clock,
                              eligibleOperations: 21)

        await runSweep(room: "e", bridge: "bridge-a",
                       cursor: 0, count: 20, totalLights: 21, failing: ["L7"])
        await runSweep(room: "e", bridge: "bridge-a",
                       cursor: 20, count: 1, totalLights: 21)

        let r = rotation("e", "bridge-a")
        XCTAssertEqual(r?.cursor, 0, "the rotation still closed")
        XCTAssertEqual(r?.completedSuccessfulRotation, false,
            "but it did not DELIVER, so the room may not go quiet")
        XCTAssertEqual(r?.hadFailure, false, "the taint resets for the next rotation")
    }

    func testAFailureInTheFinalBatchPreventsQuiescence() async {
        let clock = TelemetryTestClock(100)
        stageTelemetrySession(room: "l", bridge: "bridge-a", clock: clock,
                              eligibleOperations: 21)

        await runSweep(room: "l", bridge: "bridge-a",
                       cursor: 0, count: 20, totalLights: 21)
        await runSweep(room: "l", bridge: "bridge-a",
                       cursor: 20, count: 1, totalLights: 21, failing: ["L20"])

        XCTAssertEqual(rotation("l", "bridge-a")?.completedSuccessfulRotation, false)
    }

    // P5-5. The retry actually happens, and a clean rotation then earns
    //       quiescence.
    func testTheNextRotationRetriesAndACleanRotationEarnsQuiescence() async {
        let clock = TelemetryTestClock(100)
        stageTelemetrySession(room: "r", bridge: "bridge-a", clock: clock,
                              eligibleOperations: 21)

        await runSweep(room: "r", bridge: "bridge-a",
                       cursor: 0, count: 20, totalLights: 21, failing: ["L7"])
        await runSweep(room: "r", bridge: "bridge-a",
                       cursor: 20, count: 1, totalLights: 21)
        XCTAssertEqual(rotation("r", "bridge-a")?.completedSuccessfulRotation, false)

        // Second rotation, nothing failing: L7 is dispatched again…
        bridgeA.stageLightEffectFailures([])
        let before = bridgeA.lightEffectIDs.filter { $0 == "L7" }.count
        await runSweep(room: "r", bridge: "bridge-a",
                       cursor: 0, count: 20, totalLights: 21)
        await runSweep(room: "r", bridge: "bridge-a",
                       cursor: 20, count: 1, totalLights: 21)

        XCTAssertEqual(bridgeA.lightEffectIDs.filter { $0 == "L7" }.count, before + 1,
            "the previously failed light gets another turn")
        XCTAssertEqual(rotation("r", "bridge-a")?.completedSuccessfulRotation, true,
            "…and once a rotation delivers cleanly, quiescence becomes eligible")
    }

    // P5-6. Superseded work never starts, so it advances nothing — the same
    //       slice is simply re-selected next pass with a fresh frame.
    func testSupersededWorkAdvancesTheCursorByZero() async {
        let clock = TelemetryTestClock(100)
        stageTelemetrySession(room: "s", bridge: "bridge-a", clock: clock,
                              eligibleOperations: 40)
        let sender = orchestrator.testRestSender(for: "bridge-a")
        let events = RestEventLog()

        // Park the sender elsewhere so this room's slot stays pending.
        let gate = await park(sender, events: events)
        let frames = (0..<40).map {
            LightFrame(channelID: $0, x: 0.4, y: 0.35, brightness: 0.5)
        }
        let orch = orchestrator!
        for _ in 0..<2 {
            _ = await orchestrator.testEnqueueComposerWork(
                roomID: "s", bridgeID: "bridge-a", generation: 1
            ) { token in
                orch.testMakeComposerPerLightWork(
                    token: token,
                    targets: [(frameIndex: 0, lightID: "L0")],
                    frames: frames, api: self.bridgeA, gamut: .c,
                    sentX: 0.4, sentY: 0.35, sentBri: 50)
            }
        }
        XCTAssertEqual(rotation("s", "bridge-a")?.cursor, 0,
            "nothing has STARTED yet, so nothing has advanced")

        gate.release()
        await drain(sender)

        let snap = telemetrySnap("s", "bridge-a")
        XCTAssertEqual(snap.supersededItems, 1, "the first enqueue was replaced")
        XCTAssertEqual(rotation("s", "bridge-a")?.cursor, 1,
            "only the surviving sweep's single operation moved the cursor")
    }

    // P5-7. A probe-cancelled batch dispatches nothing and advances nothing,
    //       so cancellation can never skip an operation.
    func testAProbeCancelledSweepAdvancesTheCursorByZero() async {
        let clock = TelemetryTestClock(100)
        stageTelemetrySession(room: "c", bridge: "bridge-a", clock: clock,
                              eligibleOperations: 40)
        let token = await orchestrator.testEnqueueComposerWork(
            roomID: "c", bridgeID: "bridge-a", generation: 1
        ) { _ in { _ in } }
        await drain(orchestrator.testRestSender(for: "bridge-a"))

        let work = orchestrator.testMakeComposerPerLightWork(
            token: token,
            targets: [(frameIndex: 0, lightID: "L0"), (frameIndex: 1, lightID: "L1")],
            frames: [LightFrame(channelID: 0, x: 0.4, y: 0.35, brightness: 0.5),
                     LightFrame(channelID: 1, x: 0.4, y: 0.35, brightness: 0.5)],
            api: bridgeA, gamut: .c, sentX: 0.4, sentY: 0.35, sentBri: 50)
        await work({ false })

        XCTAssertEqual(rotation("c", "bridge-a")?.cursor, 0)
    }

    // P5-8. Two rooms sharing an ID on different bridges hold two INDEPENDENT
    //       rotation states at the same time — the exact-key requirement that
    //       a roomID-keyed dictionary could not have satisfied.
    func testSameRoomIDOnTwoBridgesKeepsIndependentRotations() async {
        let clock = TelemetryTestClock(100)
        stageTelemetrySession(room: "shared", bridge: "bridge-a", clock: clock,
                              eligibleOperations: 40)
        stageTelemetrySession(room: "shared", bridge: "bridge-b", clock: clock,
                              eligibleOperations: 40)

        await runSweep(room: "shared", bridge: "bridge-a",
                       cursor: 0, count: 20, totalLights: 40)

        XCTAssertEqual(rotation("shared", "bridge-a")?.cursor, 20)
        XCTAssertEqual(rotation("shared", "bridge-b")?.cursor, 0,
            "bridge B's identically-named room is untouched")

        await runSweep(room: "shared", bridge: "bridge-b",
                       cursor: 0, count: 5, totalLights: 40)
        XCTAssertEqual(rotation("shared", "bridge-a")?.cursor, 20)
        XCTAssertEqual(rotation("shared", "bridge-b")?.cursor, 5)
    }

    // P5-9. A replacement start resets the rotation and rejects the old
    //       generation's in-flight advances.
    func testReplacementResetsRotationAndRejectsTheOldGeneration() async {
        let clock = TelemetryTestClock(100)
        stageTelemetrySession(room: "rep", bridge: "bridge-a", generation: 1,
                              clock: clock, eligibleOperations: 40)
        let staleToken = await runSweep(room: "rep", bridge: "bridge-a",
                                        generation: 1, cursor: 0, count: 20,
                                        totalLights: 40)
        XCTAssertEqual(rotation("rep", "bridge-a")?.cursor, 20)

        // Replacement: new generation, blank slate.
        stageTelemetrySession(room: "rep", bridge: "bridge-a", generation: 2,
                              clock: clock, eligibleOperations: 40)
        XCTAssertEqual(rotation("rep", "bridge-a")?.cursor, 0,
            "the new session starts at the boundary")

        // The old closure reports a batch in late — it must move nothing.
        orchestrator.testReportComposerRotationAdvanced(
            token: staleToken, attemptedOperations: 5, failures: 0)
        XCTAssertEqual(rotation("rep", "bridge-a")?.cursor, 0,
            "a generation-1 advance cannot move generation 2's cursor")
    }

    // P5-10. Stop clears rotation AND degradation together, for that key only.
    func testStopClearsRotationAndDegradationForThatSessionOnly() async {
        let clock = TelemetryTestClock(100)
        stageTelemetrySession(room: "x", bridge: "bridge-a", clock: clock,
                              eligibleOperations: 40)
        stageTelemetrySession(room: "y", bridge: "bridge-a", clock: clock,
                              eligibleOperations: 40)
        orchestrator.testRecordCompositionFallback(
            roomID: "x", bridgeID: "bridge-a", generation: 1,
            reason: .bridgeCapacityInsufficient)
        XCTAssertNotNil(rotation("x", "bridge-a"))
        XCTAssertNotNil(orchestrator.testCompositionDegradation(roomID: "x", bridgeID: "bridge-a"))

        await orchestrator.stopCompositionMode(roomID: "x", bridgeID: "bridge-a")

        XCTAssertNil(rotation("x", "bridge-a"))
        XCTAssertNil(orchestrator.testCompositionDegradation(roomID: "x", bridgeID: "bridge-a"))
        XCTAssertNotNil(rotation("y", "bridge-a"), "the sibling room is untouched")
    }

    // ── Degradation: two independent facts ──────────────────────

    // P5-11. A capacity refusal into a large room is BOTH true. Neither write
    //        may erase the other, in either order.
    func testCapacityFallbackAndLargeRoomBothSurvive() {
        let clock = TelemetryTestClock(100)
        // markRESTActive records the large-room fact first…
        stageTelemetrySession(room: "combo", bridge: "bridge-a", clock: clock,
                              eligibleOperations: 60)
        // …then the bridge-stored catch records why we are here at all.
        orchestrator.testRecordCompositionFallback(
            roomID: "combo", bridgeID: "bridge-a", generation: 1,
            reason: .bridgeCapacityInsufficient)

        let snap = orchestrator.testCompositionDegradation(
            roomID: "combo", bridgeID: "bridge-a")
        XCTAssertEqual(snap?.fallbackReason, .bridgeCapacityInsufficient)
        XCTAssertEqual(snap?.largeRoomEligibleOperations, 60)
        XCTAssertEqual(snap?.isLargeRoom, true)

        XCTAssertEqual(
            TransportVocabulary.roomModeStatus(
                fallback: snap?.fallbackReason, largeRoom: true, liveSeconds: nil),
            "This bridge couldn't store this look, so Room mode is playing; lights take turns updating",
            "the sentence must name BOTH facts")
    }

    func testEntertainmentFallbackAndLargeRoomBothSurvive() {
        let clock = TelemetryTestClock(100)
        stageTelemetrySession(room: "ent", bridge: "bridge-a", clock: clock,
                              eligibleOperations: 45)
        orchestrator.testRecordCompositionFallback(
            roomID: "ent", bridgeID: "bridge-a", generation: 1,
            reason: .entertainmentUnavailable)

        let snap = orchestrator.testCompositionDegradation(roomID: "ent", bridgeID: "bridge-a")
        XCTAssertEqual(snap?.fallbackReason, .entertainmentUnavailable)
        XCTAssertEqual(snap?.largeRoomEligibleOperations, 45)
    }

    // P5-12. Unknown capacity is NOT "the bridge is full" — the app knows
    //        nothing, and must not claim otherwise.
    func testUnknownCapacityNeverClaimsTheBridgeIsFull() {
        let insufficient = TransportVocabulary.roomModeStatus(
            fallback: .bridgeCapacityInsufficient, largeRoom: false, liveSeconds: nil)
        let unknown = TransportVocabulary.roomModeStatus(
            fallback: .bridgeCapacityUnknown, largeRoom: false, liveSeconds: nil)

        XCTAssertNotEqual(insufficient, unknown)
        XCTAssertTrue(insufficient.contains("doesn't have room"))
        XCTAssertFalse(unknown.contains("doesn't have room"),
            "unknown capacity must never assert the bridge is out of space")
        XCTAssertTrue(unknown.contains("Couldn't check"))
    }

    // P5-13. A room at or under the budget shows no rotation warning; a larger
    //        one does.
    func testRotationWarningAppearsOnlyForRoomsAboveTheSweepBudget() {
        let clock = TelemetryTestClock(100)
        stageTelemetrySession(room: "atBudget", bridge: "bridge-a", clock: clock,
                              eligibleOperations: CompositionRotationPlan.maxOperationsPerSweep)
        XCTAssertNil(
            orchestrator.testCompositionDegradation(roomID: "atBudget", bridgeID: "bridge-a"),
            "a 20-operation room is not degraded and says nothing new")

        stageTelemetrySession(room: "overBudget", bridge: "bridge-a", clock: clock,
                              eligibleOperations: CompositionRotationPlan.maxOperationsPerSweep + 1)
        XCTAssertEqual(
            orchestrator.testCompositionDegradation(
                roomID: "overBudget", bridgeID: "bridge-a")?.largeRoomEligibleOperations,
            21)
    }

    // P5-14. Degradation is exact-keyed: same room ID, two bridges, two
    //        independent reasons.
    func testDegradationIsIndependentPerBridgeForTheSameRoomID() {
        let clock = TelemetryTestClock(100)
        stageTelemetrySession(room: "dual", bridge: "bridge-a", clock: clock,
                              eligibleOperations: 5)
        stageTelemetrySession(room: "dual", bridge: "bridge-b", clock: clock,
                              eligibleOperations: 5)
        orchestrator.testRecordCompositionFallback(
            roomID: "dual", bridgeID: "bridge-a", generation: 1,
            reason: .bridgeCapacityUnknown)

        XCTAssertEqual(
            orchestrator.testCompositionDegradation(roomID: "dual", bridgeID: "bridge-a")?
                .fallbackReason, .bridgeCapacityUnknown)
        XCTAssertNil(
            orchestrator.testCompositionDegradation(roomID: "dual", bridgeID: "bridge-b"),
            "bridge B's identically-named room carries no reason of its own")
    }

    // P5-15. A restart inherits nothing, and a stale generation cannot
    //        republish an old reason.
    func testRestartCarriesNoOldReasonAndStaleGenerationsCannotRepublish() {
        let clock = TelemetryTestClock(100)
        stageTelemetrySession(room: "z", bridge: "bridge-a", generation: 1,
                              clock: clock, eligibleOperations: 5)
        orchestrator.testRecordCompositionFallback(
            roomID: "z", bridgeID: "bridge-a", generation: 1,
            reason: .entertainmentUnavailable)
        XCTAssertNotNil(orchestrator.testCompositionDegradation(roomID: "z", bridgeID: "bridge-a"))

        stageTelemetrySession(room: "z", bridge: "bridge-a", generation: 2,
                              clock: clock, eligibleOperations: 5)
        XCTAssertNil(orchestrator.testCompositionDegradation(roomID: "z", bridgeID: "bridge-a"),
            "the new session starts clean")

        // A late event from the superseded run must not resurrect it.
        orchestrator.testRecordCompositionFallback(
            roomID: "z", bridgeID: "bridge-a", generation: 1,
            reason: .entertainmentUnavailable)
        XCTAssertNil(orchestrator.testCompositionDegradation(roomID: "z", bridgeID: "bridge-a"))
    }

    // P5-16. `roomModeStatus` is total and jargon-free for every combination.
    func testRoomModeStatusIsTotalAndJargonFree() {
        let reasons: [CompositionFallbackReason?] = [
            nil, .entertainmentUnavailable, .bridgeCapacityInsufficient,
            .bridgeCapacityUnknown, .bridgeStoredUploadFailed,
        ]
        let banned = ["REST", "Transport", "transport", "DTLS", "SSE",
                      "ENT AREA", "grouped light", "rate-capped"]
        var seen = Set<String>()

        for reason in reasons {
            for largeRoom in [false, true] {
                for seconds in [nil, 1.2] as [Double?] {
                    let text = TransportVocabulary.roomModeStatus(
                        fallback: reason, largeRoom: largeRoom, liveSeconds: seconds)
                    XCTAssertFalse(text.isEmpty)
                    for word in banned {
                        XCTAssertFalse(text.contains(word),
                            "'\(word)' leaked into: \(text)")
                    }
                    XCTAssertNil(try? /\d+ lights?\b/.firstMatch(in: text),
                        "no sentence may state a light count: \(text)")
                    seen.insert(text)
                }
            }
        }
        XCTAssertGreaterThanOrEqual(seen.count, 10,
            "each (reason, largeRoom) pair needs its own sentence")
    }

    // P5-17. The grouped fallback (no per-light IDs) arms rotation state with
    //        an eligible count of ZERO, and the grouped closure never reports
    //        a rotation advance — so `hasCompletedInitialSuccessfulRotation`
    //        can never rise for it. That exact state must read as trivially
    //        complete at the delta gate, or a static grouped room would
    //        re-send an identical PUT every tick forever instead of going
    //        quiet.
    func testAGroupedSessionNeverHoldsTheDeltaGateOpen() {
        orchestrator.testStageRESTComposition(
            roomID: "grouped", bridgeID: "bridge-a", api: bridgeA)
        // The default stage is the grouped shape: lightIDs empty.

        let r = rotation("grouped", "bridge-a")
        XCTAssertEqual(r?.eligibleOperationCount, 0)
        XCTAssertEqual(r?.completedSuccessfulRotation, false,
            "nothing ever advances a zero-count rotation, so the flag stays down…")

        // …and the gate consults this exact state through the predicate.
        XCTAssertFalse(CompositionRotationPlan.deliveryIncomplete(
            eligibleOperationCount: r?.eligibleOperationCount ?? -1,
            hasCompletedInitialSuccessfulRotation: r?.completedSuccessfulRotation ?? true,
            cursor: r?.cursor ?? -1),
            "an empty eligible set is trivially complete — the delta gate may quiesce")

        // A real per-light session with the same flags down IS incomplete:
        // the exemption is about emptiness, not a general loosening.
        orchestrator.testStageRESTComposition(
            roomID: "perlight", bridgeID: "bridge-a", api: bridgeA,
            lightIDs: (0..<3).map { "L\($0)" })
        let p = rotation("perlight", "bridge-a")
        XCTAssertEqual(p?.eligibleOperationCount, 3)
        XCTAssertTrue(CompositionRotationPlan.deliveryIncomplete(
            eligibleOperationCount: p?.eligibleOperationCount ?? 0,
            hasCompletedInitialSuccessfulRotation: p?.completedSuccessfulRotation ?? true,
            cursor: p?.cursor ?? 0))
    }

    // ──────────────────────────────────────────────
    // MARK: - Composer 2 packet 6: All-Day per-room delivery and lifecycle
    //
    // Before packet 6, All-Day owned ONE RestSender and ONE sentinel scope
    // (`RestScope(roomID: "__allDay__", owner: .allDay)`), so every room in a
    // tick overwrote the previous room's pending slot: with N rooms, N-2 were
    // typically dropped without a trace. It also discarded the ValidityProbe,
    // so a stop could not halt an executing closure, and NO teardown path —
    // removeBridge, forgetAllBridges, stopStudioMode — could reach its mailbox.
    //
    // Everything below is proven by continuations, recorded event ORDER, and
    // source shape. Nothing is proven by elapsed time — Guard 8 in
    // hardening_guards.sh forbids timing waiters anywhere in this file.
    // ──────────────────────────────────────────────

    private func allDayScope(_ roomID: String) -> RestScope {
        RestScope(roomID: roomID, owner: .allDay)
    }

    private func allDayAnchor() -> UnifiedOrchestrator.AllDayAnchor {
        // Fixed instant + timezone: the curve is pure, so the tick's OUTPUT is
        // irrelevant here — what matters is which rooms it reaches.
        UnifiedOrchestrator.AllDayAnchor(
            lat: 40.7128, lon: -74.0060, timeZoneID: "America/New_York",
            updatedAt: Date(timeIntervalSince1970: 1_000_000))
    }

    private func allDayRoom(
        _ id: String, bridge: String?, glID: String? = nil
    ) -> RoomDisplayItem {
        RoomDisplayItem(
            id: id, name: "Room \(id)", archetype: nil,
            isOn: true, brightness: 50,
            groupedLightID: glID ?? "gl-\(id)", lightCount: 2,
            bridgeID: bridge,
            childResourceRefs: [])
    }

    /// Run one production tick at the orchestrator's current generation, then
    /// drain every All-Day mailbox it used so the assertions see settled state.
    private func runAllDayTick(bridgeKeys: [String?] = ["bridge-a", "bridge-b"]) async {
        let gen = orchestrator.testAllDayGeneration()
        await orchestrator.testTickAllDayScenes(anchor: allDayAnchor(), generation: gen)
        for key in bridgeKeys {
            if let sender = orchestrator.testAllDayRestSender(for: key) {
                await drainAllDay(sender)
            }
        }
    }

    /// Deterministic barrier on an All-Day sender — everything enqueued before
    /// this has run. Mirrors `drain(_:)` but in the `.allDay` owner space so it
    /// cannot collide with a Composer/Studio scope.
    private func drainAllDay(_ sender: RestSender) async {
        let done = RestGate()
        await sender.enqueue(scope: allDayScope("__drain-allday__")) { _ in
            done.signalStarted()
        }
        await done.waitUntilStarted()
    }

    /// Production source with comment-only lines stripped — a doc comment that
    /// names a symbol is documentation, not a call site.
    private func productionCode(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // HueHomeTests/
            .deletingLastPathComponent()   // repo root
        return try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The body of a top-level func in a Swift source, by brace depth.
    private func functionBody(_ source: String, startingWith signature: String) -> [String]? {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: { $0.contains(signature) }) else { return nil }
        var depth = 0
        var started = false
        var body: [String] = []
        for line in lines[start...] {
            for ch in line {
                if ch == "{" { depth += 1; started = true }
                if ch == "}" { depth -= 1 }
            }
            if started { body.append(line) }
            if started && depth == 0 { return body }
        }
        return nil
    }

    // ── Delivery: every eligible room, every tick ────────────────────

    // P6-1. Two eligible rooms on ONE bridge both dispatch in one tick.
    func testOneTickDispatchesEveryEligibleRoomOnABridge() async {
        orchestrator.allRooms = [
            allDayRoom("room-1", bridge: "bridge-a"),
            allDayRoom("room-2", bridge: "bridge-a"),
        ]
        await runAllDayTick()

        XCTAssertEqual(Set(bridgeA.groupedEffectIDs), ["gl-room-1", "gl-room-2"], """
            both rooms must receive their All-Day write — the sentinel scope \
            used to let room-2's enqueue erase room-1's pending slot
            """)
    }

    // P6-2. More rooms than the OLD single pending slot could hold are not
    //       dropped. Five rooms, one bridge: five writes, no silent losses.
    func testFiveRoomsInOneTickAreAllDelivered() async {
        orchestrator.allRooms = (1...5).map { allDayRoom("r\($0)", bridge: "bridge-a") }
        await runAllDayTick()

        XCTAssertEqual(Set(bridgeA.groupedEffectIDs),
            Set((1...5).map { "gl-r\($0)" }),
            "every room gets exactly one attempt per tick, regardless of count")
        XCTAssertEqual(bridgeA.groupedEffectIDs.count, 5,
            "and exactly one — no duplicates from re-enqueue")
    }

    // P6-3. The SAME room id on two bridges dispatches independently: two
    //       different sender instances, two scopes that never meet.
    func testSameRoomIDOnTwoBridgesDispatchesIndependently() async {
        orchestrator.allRooms = [
            allDayRoom("shared", bridge: "bridge-a", glID: "gl-a"),
            allDayRoom("shared", bridge: "bridge-b", glID: "gl-b"),
        ]
        await runAllDayTick()

        XCTAssertEqual(bridgeA.groupedEffectIDs, ["gl-a"],
            "bridge A writes its own room")
        XCTAssertEqual(bridgeB.groupedEffectIDs, ["gl-b"], """
            and bridge B writes its identically-named room — a roomID-only \
            design would have collapsed these into one mailbox slot
            """)
        XCTAssertEqual(orchestrator.testAllDayRestSenderBridgeKeys(),
            ["bridge-a", "bridge-b"],
            "one All-Day mailbox per bridge")
    }

    // P6-18. A failing room does not prevent LATER rooms from being attempted —
    //        separate scopes mean a thrown error is confined to its own closure.
    func testAFailingRoomDoesNotPreventLaterRooms() async {
        bridgeA.stageGroupedEffectFailures(["gl-r1"])
        orchestrator.allRooms = (1...3).map { allDayRoom("r\($0)", bridge: "bridge-a") }
        await runAllDayTick()

        XCTAssertEqual(Set(bridgeA.groupedEffectIDs), ["gl-r1", "gl-r2", "gl-r3"], """
            r1 threw, and r2/r3 were still attempted — All-Day swallows per-room \
            failures (try?) and must not abandon the rest of the tick
            """)
    }

    // P6-17. A newer tick replaces only the SAME exact bridge+room pending item.
    func testANewerTickReplacesOnlyTheSameBridgeAndRoom() async {
        let senderA = orchestrator.testAllDayRestSender(for: "bridge-a")!
        let events = RestEventLog()

        // Park the mailbox so later enqueues stay pending and observable.
        let gate = RestGate()
        await senderA.enqueue(scope: allDayScope("__park__")) { _ in
            gate.signalStarted()
            await gate.waitForRelease()
        }
        await gate.waitUntilStarted()

        await senderA.enqueue(scope: allDayScope("room-1")) { _ in events.record("room-1 old") }
        await senderA.enqueue(scope: allDayScope("room-2")) { _ in events.record("room-2") }
        // Newer work for room-1 ONLY.
        await senderA.enqueue(scope: allDayScope("room-1")) { _ in events.record("room-1 new") }

        gate.release()
        await drainAllDay(senderA)

        XCTAssertFalse(events.entries.contains("room-1 old"),
            "the superseded room-1 closure never runs")
        XCTAssertTrue(events.entries.contains("room-1 new"),
            "the newer room-1 value wins for its own scope")
        XCTAssertTrue(events.entries.contains("room-2"), """
            and room-2 is untouched — replacement is per scope, which is the \
            whole reason rooms stopped erasing each other
            """)
    }

    // ── Stop, generation, and retirement (A1) ────────────────────────

    // P6-13. Stop invalidates PENDING work: nothing queued before the stop may
    //        reach the bridge afterwards.
    //
    //        NOTE the barrier. `stopAllDayScenes` spawns its own cleanup over
    //        the retired senders, so a drain SENTINEL enqueued after the stop
    //        can be dropped by that cleanup — which hangs the test instead of
    //        failing it. The barrier here is a `clearAll()` the test itself
    //        awaits: idempotent, and impossible to swallow.
    func testStopDropsPendingAllDayWork() async {
        orchestrator.allRooms = [
            allDayRoom("room-1", bridge: "bridge-a"),
            allDayRoom("room-2", bridge: "bridge-a"),
        ]
        let sender = orchestrator.testAllDayRestSender(for: "bridge-a")!

        // Park the mailbox so the tick's writes are still pending at stop time.
        let parked = RestGate()
        let parkFinished = RestGate()
        await sender.enqueue(scope: allDayScope("__park__")) { _ in
            parked.signalStarted()
            await parked.waitForRelease()
            parkFinished.signalStarted()
        }
        await parked.waitUntilStarted()

        await orchestrator.testTickAllDayScenes(
            anchor: allDayAnchor(), generation: orchestrator.testAllDayGeneration())

        orchestrator.stopAllDayScenes()

        XCTAssertTrue(orchestrator.testAllDayRestSenderBridgeKeys().isEmpty,
            "the sender map is detached SYNCHRONOUSLY, not merely cleared")
        XCTAssertFalse(orchestrator.testAllDayTaskIsRunning(),
            "the 5-minute loop is cancelled and forgotten")

        parked.release()
        await parkFinished.waitUntilStarted()
        _ = await sender.clearAll()

        XCTAssertEqual(bridgeA.groupedEffectIDs, [], """
            no write queued before the stop may land afterwards — either the \
            retirement dropped it, or its generation guard rejected it
            """)
    }

    // P6-14. Stop invalidates EXECUTING work at the next validity boundary.
    //        All-Day used to discard the probe entirely, so this was impossible.
    func testExecutingAllDayWorkStopsAtItsNextValidityBoundary() async {
        let senderA = orchestrator.testAllDayRestSender(for: "bridge-a")!
        let events = RestEventLog()
        let batch1 = RestGate()
        let finished = RestGate()

        await senderA.enqueue(scope: allDayScope("room-1")) { stillCurrent in
            for batch in 1...3 {
                guard await stillCurrent() else { break }
                events.record("batch\(batch)")
                if batch == 1 {
                    batch1.signalStarted()
                    await batch1.waitForRelease()
                }
            }
            finished.signalStarted()
        }

        await batch1.waitUntilStarted()
        orchestrator.stopAllDayScenes()
        batch1.release()
        await finished.waitUntilStarted()

        XCTAssertEqual(events.entries, ["batch1"], """
            the already-dispatched batch may finish, but no LATER batch may \
            begin — the probe All-Day now consumes is what makes this possible
            """)
    }

    // P6-15. Generation replacement rejects old work: a tick staged under an
    //        old generation performs no write once the generation moves on.
    func testStaleGenerationAllDayWorkNeverWrites() async {
        orchestrator.allRooms = [allDayRoom("room-1", bridge: "bridge-a")]
        let staleGeneration = orchestrator.testAllDayGeneration()
        orchestrator.testSetAllDayGeneration(staleGeneration + 1)

        await orchestrator.testTickAllDayScenes(
            anchor: allDayAnchor(), generation: staleGeneration)

        XCTAssertEqual(bridgeA.groupedEffectIDs, [],
            "a tick whose generation has been superseded writes nothing at all")
    }

    // A1-b. A restart swaps sender INSTANCES. This is what makes a retired
    //       cleanup task harmless: it can only reach detached objects.
    func testRestartingAllDayCreatesFreshSenderInstances() async {
        let before = orchestrator.testAllDayRestSender(for: "bridge-a")!
        orchestrator.stopAllDayScenes()
        let after = orchestrator.testAllDayRestSender(for: "bridge-a")!

        XCTAssertFalse(before === after, """
            stop detaches the map, so the next resolution builds a NEW sender — \
            if it reused the old instance, the retired clearAll below could \
            erase work belonging to the new generation
            """)
    }

    // A1-a. THE retirement race. Park a retired sender's cleanup, restart
    //       All-Day, enqueue on the new generation, then release the cleanup:
    //       the new generation's work must survive.
    func testRetiredAllDaySenderCleanupCannotClearANewGeneration() async {
        let events = RestEventLog()
        let retired = orchestrator.testAllDayRestSender(for: "bridge-a")!

        // Occupy the retired sender so its clearAll has something to race with.
        let parked = RestGate()
        await retired.enqueue(scope: allDayScope("__park__")) { _ in
            parked.signalStarted()
            await parked.waitForRelease()
        }
        await parked.waitUntilStarted()

        // Stop detaches the map and spawns cleanup over the retired snapshot.
        orchestrator.stopAllDayScenes()

        // The new generation resolves a FRESH sender and queues real work.
        let fresh = orchestrator.testAllDayRestSender(for: "bridge-a")!
        XCTAssertFalse(retired === fresh, "precondition: the instance was swapped")
        await fresh.enqueue(scope: allDayScope("room-1")) { _ in
            events.record("new-generation write")
        }

        // Now let the retired cleanup run. Awaiting clearAll on the RETIRED
        // sender is the deterministic form of "the retirement cleanup has
        // happened" — a drain sentinel there could be swallowed by that very
        // cleanup. `fresh` is not in the retired snapshot, so draining it is safe.
        parked.release()
        _ = await retired.clearAll()
        await drainAllDay(fresh)

        XCTAssertEqual(events.entries, ["new-generation write"], """
            the retired sender's asynchronous clearAll must not reach the new \
            generation's mailbox — clearAll bumps epochs on whatever sender it \
            holds, so ONLY detachment (not a generation guard) can prevent this
            """)
    }

    // ── Bridge removal, tombstones, and the forget-all gate (A3) ─────

    // P6-16. Bridge removal clears only THAT bridge's All-Day work.
    func testBridgeRemovalClearsOnlyThatBridgesAllDaySender() async {
        let senderA = orchestrator.testAllDayRestSender(for: "bridge-a")!
        let senderB = orchestrator.testAllDayRestSender(for: "bridge-b")!
        let events = RestEventLog()

        let gateA = RestGate(), gateB = RestGate()
        await senderA.enqueue(scope: allDayScope("__park-a__")) { _ in
            gateA.signalStarted(); await gateA.waitForRelease()
        }
        await senderB.enqueue(scope: allDayScope("__park-b__")) { _ in
            gateB.signalStarted(); await gateB.waitForRelease()
        }
        await gateA.waitUntilStarted()
        await gateB.waitUntilStarted()
        await senderA.enqueue(scope: allDayScope("room-a")) { _ in events.record("A") }
        await senderB.enqueue(scope: allDayScope("room-b")) { _ in events.record("B") }

        await orchestrator.removeBridge(id: "bridge-a")

        gateA.release(); gateB.release()
        await drainAllDay(senderA)
        await drainAllDay(senderB)

        XCTAssertEqual(events.entries, ["B"],
            "only bridge A's queued All-Day work was invalidated")
        XCTAssertFalse(orchestrator.testAllDayRestSenderBridgeKeys().contains("bridge-a"),
            "bridge A's All-Day mailbox is detached")
        XCTAssertTrue(orchestrator.testAllDayRestSenderBridgeKeys().contains("bridge-b"),
            "bridge B's survives untouched")
    }

    // A3-a. A tombstoned bridge cannot have a sender RECREATED for it. This is
    //       the protection that detachment alone does not provide: while
    //       removeBridge is suspended, clients[id] and allRooms still exist, so
    //       a concurrent tick would otherwise lazily rebuild the mailbox.
    func testATickCannotRecreateAnAllDaySenderForARemovedBridge() async {
        _ = orchestrator.testAllDayRestSender(for: "bridge-a")
        await orchestrator.removeBridge(id: "bridge-a")

        XCTAssertTrue(orchestrator.testAllDayBlockedBridgeKeys().contains("bridge-a"),
            "removal leaves a persistent tombstone, not just a detached sender")
        XCTAssertNil(orchestrator.testAllDayRestSender(for: "bridge-a"), """
            the accessor REFUSES structurally — a non-optional lazily-creating \
            accessor could not express this, and every caller would have to \
            remember the check
            """)

        // A tick still holding the removed bridge's rooms creates nothing.
        orchestrator.allRooms = [allDayRoom("room-1", bridge: "bridge-a")]
        await runAllDayTick(bridgeKeys: ["bridge-b"])

        XCTAssertEqual(bridgeA.groupedEffectIDs, [],
            "no write reaches the removed bridge")
        XCTAssertFalse(orchestrator.testAllDayRestSenderBridgeKeys().contains("bridge-a"),
            "and no mailbox was resurrected for it")
    }

    // A3-c. Bridge B stays fully operational while bridge A is blocked.
    func testBridgeBKeepsDeliveringWhileBridgeAIsBlocked() async {
        orchestrator.testBlockAllDayBridge("bridge-a")
        orchestrator.allRooms = [
            allDayRoom("room-a", bridge: "bridge-a"),
            allDayRoom("room-b", bridge: "bridge-b"),
        ]
        await runAllDayTick()

        XCTAssertEqual(bridgeA.groupedEffectIDs, [], "the blocked bridge is skipped")
        XCTAssertEqual(bridgeB.groupedEffectIDs, ["gl-room-b"], """
            and an unrelated bridge is unaffected — one bridge's teardown may \
            never suppress another's delivery
            """)
    }

    // A3-d. Re-adding a bridge clears ONLY that bridge's tombstone, through the
    //       same production helper both registration paths call.
    func testReAddingABridgeClearsOnlyThatBridgesTombstone() async {
        orchestrator.testBlockAllDayBridge("bridge-a")
        orchestrator.testBlockAllDayBridge("bridge-b")

        orchestrator.testClearAllDayBridgeTombstone("bridge-a")

        XCTAssertEqual(orchestrator.testAllDayBlockedBridgeKeys(), ["bridge-b"],
            "only the re-registered bridge is unblocked")
        XCTAssertNotNil(orchestrator.testAllDayRestSender(for: "bridge-a"),
            "bridge A can hold an All-Day mailbox again")
        XCTAssertNil(orchestrator.testAllDayRestSender(for: "bridge-b"),
            "bridge B stays blocked")
    }

    // A3-b. A start attempted while forget-all is in flight leaves NOTHING
    //       behind: no task, no sender, and no later write.
    func testAStartDuringForgetAllCreatesNoTaskOrSenderAndWritesNothing() async {
        orchestrator.testSetAllDayTeardownInProgress(true)
        orchestrator.allRooms = [allDayRoom("room-1", bridge: "bridge-a")]

        orchestrator.startAllDayScenes(anchor: allDayAnchor())
        orchestrator.startAllDayScenesIfNeeded()

        XCTAssertFalse(orchestrator.testAllDayTaskIsRunning(),
            "no 5-minute loop may survive a start made during forget-all")
        XCTAssertTrue(orchestrator.testAllDayRestSenderBridgeKeys().isEmpty,
            "and no sender may be built outside the retired snapshot")

        // Even a tick forced at the current generation writes nothing.
        await runAllDayTick()
        XCTAssertEqual(bridgeA.groupedEffectIDs, [],
            "the gate refuses at target selection AND at dispatch")
    }

    // A3-b (cont). Forget-all itself leaves All-Day fully retired, gate down,
    //              and deliberately does NOT restart it.
    func testForgetAllRetiresAllDayAndDoesNotRestartIt() async {
        _ = orchestrator.testAllDayRestSender(for: "bridge-a")
        let generationBefore = orchestrator.testAllDayGeneration()

        await orchestrator.forgetAllBridges()

        XCTAssertFalse(orchestrator.testAllDayTeardownInProgress(),
            "the gate is dropped once teardown completes")
        XCTAssertGreaterThan(orchestrator.testAllDayGeneration(), generationBefore,
            "the generation moved, so any in-flight tick is stale")
        XCTAssertFalse(orchestrator.testAllDayTaskIsRunning(),
            "the loop is gone")
        XCTAssertTrue(orchestrator.testAllDayRestSenderBridgeKeys().isEmpty,
            "every All-Day mailbox is detached")
        XCTAssertFalse(orchestrator.allDayScenesEnabled,
            "and All-Day is NOT auto-restarted — the user re-enables it")
    }

    // ── Source guards ────────────────────────────────────────────────

    // P6-22. The global sentinel scope must never come back. Behavior tests
    //        above would all still pass if someone reintroduced it alongside
    //        the per-room scopes, so pin its absence directly.
    func testAllDayUsesNoGlobalSentinelScope() throws {
        let code = try productionCode("HueHome/Core/Network/UnifiedOrchestrator.swift")

        XCTAssertFalse(code.contains("__allDay__"), """
            the sentinel room id is gone: one scope for the whole feature is \
            exactly what made later rooms erase earlier ones
            """)
        XCTAssertFalse(code.contains("allDayRestScope"), """
            and so is the single shared scope property — All-Day scopes are \
            built per room at the enqueue site now
            """)
    }

    // A3 guard. The sender accessor must stay refusal-capable, and no call site
    //           may force-unwrap its way past a tombstone.
    func testAllDaySenderAccessorRemainsOptionalAndIsNeverForceUnwrapped() throws {
        let code = try productionCode("HueHome/Core/Network/UnifiedOrchestrator.swift")

        XCTAssertTrue(
            code.contains("private func allDayRestSender(for bridgeID: String?) -> RestSender?"),
            """
            refusal is structural: a non-optional lazily-creating accessor \
            cannot say "this bridge is being removed", and every caller would \
            have to remember to check the tombstone first
            """)
        XCTAssertFalse(code.contains("allDayRestSender(for: target.bridgeID)!"),
            "the tick must not force-unwrap past a refusal")
        XCTAssertFalse(code.contains("allDayRestSender(for: bridgeID)!"),
            "nor may any other production caller")
    }

    // A1-c / A1-d / A3 guard. The invalidating steps must run BEFORE each
    // teardown function's first suspension. A behavior test cannot see this
    // window — the whole defect is that state is reachable while suspended.
    func testAllDayTeardownStepsPrecedeTheFirstAwait() throws {
        let code = try productionCode("HueHome/Core/Network/UnifiedOrchestrator.swift")

        func indexOfFirst(_ needle: String, in body: [String]) -> Int? {
            body.firstIndex { $0.contains(needle) }
        }

        // removeBridge: tombstone + detach before `await stopEffectsForRemovedGroups`.
        let remove = try XCTUnwrap(
            functionBody(code, startingWith: "func removeBridge(id: String) async"),
            "removeBridge must be findable")
        let removeFirstAwait = try XCTUnwrap(indexOfFirst("await ", in: remove),
            "removeBridge must contain an await")
        let tombstone = try XCTUnwrap(indexOfFirst("allDayBlockedBridgeKeys.insert(id)", in: remove),
            "removeBridge must tombstone the bridge for All-Day")
        let detach = try XCTUnwrap(
            indexOfFirst("allDayRestSendersByBridge.removeValue(forKey: id)", in: remove),
            "removeBridge must detach the bridge's All-Day sender")
        XCTAssertLessThan(tombstone, removeFirstAwait, """
            the tombstone must be set before removeBridge suspends: while it is \
            parked, clients[id] and allRooms still exist, so a concurrent tick \
            would recreate the sender it just detached
            """)
        XCTAssertLessThan(detach, removeFirstAwait,
            "and the detach must precede the suspension for the same reason")

        // forgetAllBridges: gate + generation + detach before `await stopStudioMode()`.
        let forget = try XCTUnwrap(
            functionBody(code, startingWith: "func forgetAllBridges() async"),
            "forgetAllBridges must be findable")
        let forgetFirstAwait = try XCTUnwrap(indexOfFirst("await ", in: forget),
            "forgetAllBridges must contain an await")
        for needle in [
            "allDayTeardownInProgress = true",
            "allDayGeneration &+= 1",
            "allDayTask?.cancel()",
            "allDayRestSendersByBridge.removeAll()",
        ] {
            let idx = try XCTUnwrap(indexOfFirst(needle, in: forget),
                "forgetAllBridges must perform `\(needle)`")
            XCTAssertLessThan(idx, forgetFirstAwait, """
                `\(needle)` must run before forget-all suspends — a start \
                arriving during the suspension would otherwise build a task and \
                senders outside the retired snapshot
                """)
        }
    }

    // A3-d guard. BOTH legitimate registration paths must lift the tombstone.
    // configure() is the LAUNCH path, so clearing only in addBridge would leave
    // a re-paired bridge permanently blocked after the next relaunch.
    func testBothBridgeRegistrationPathsClearTheAllDayTombstone() throws {
        let code = try productionCode("HueHome/Core/Network/UnifiedOrchestrator.swift")

        let configure = try XCTUnwrap(
            functionBody(code, startingWith: "func configure(bridges: [BridgeRecord]"),
            "configure must be findable")
        XCTAssertTrue(configure.contains { $0.contains("clearAllDayBridgeTombstone(bridge.id)") }, """
            configure() is the launch registration path — HueHomeApp calls it \
            immediately before startAllDayScenesIfNeeded, so a bridge re-paired \
            before a relaunch would stay blocked forever without this
            """)

        let add = try XCTUnwrap(
            functionBody(code, startingWith: "func addBridge(_ record: BridgeRecord)"),
            "addBridge must be findable")
        XCTAssertTrue(add.contains { $0.contains("clearAllDayBridgeTombstone(record.id)") },
            "addBridge is the in-session registration path and must lift it too")
    }

    // ──────────────────────────────────────────────
    // MARK: - Composer 2 packet 6: All-Day yields to active playback
    //
    // `tickAllDayScenes` wrote CT + brightness to EVERY room every 5 minutes
    // with no check against any playback registry — and because SSE echo is
    // suppressed for app-driven rooms, the overwrite was invisible in the UI.
    //
    // Suppression is per exact bridge + room, read from the strongest runtime
    // state available for each owner — never from the view-model mirrors
    // (`activeEffectEntries`, `runningEffects`), which carry no bridge identity
    // and cannot tell a one-shot from a continuing owner.
    // ──────────────────────────────────────────────

    private func makeStudioVM() -> StudioViewModel {
        let vm = StudioViewModel()
        vm.configure(orchestrator: orchestrator)
        return vm
    }

    private func bridgeNativeCard(
        id: String = "candle-card", effect: String = "candle"
    ) -> StudioCard {
        StudioCard(
            id: id, name: "Candle", tagline: "Soft flicker", icon: "flame",
            accentColor: .orange, requiresForeground: false, params: [],
            strategy: .bridgeNative(effect: effect),
            compositionLayerActivity: nil)
    }

    private func firmwareRoom(
        _ id: String = "room-1", bridge: String? = "bridge-a",
        glID: String? = "gl-room-1", lights: [String] = ["L1"]
    ) -> RoomDisplayItem {
        RoomDisplayItem(
            id: id, name: "Room \(id)", archetype: nil,
            isOn: true, brightness: 50,
            groupedLightID: glID, lightCount: lights.count,
            bridgeID: bridge,
            childResourceRefs: lights.map { (rid: $0, rtype: "light") })
    }

    private func capabilityLight(id: String, v1Effects: [String]) -> HueLight {
        HueLight(
            id: id,
            metadata: LightMetadata(name: id, archetype: nil),
            on: OnState(on: true),
            dimming: nil, color: nil, color_temperature: nil, owner: nil,
            effects: LightEffectsV1(effect_values: v1Effects, status: nil),
            effects_v2: nil, timed_effects: nil, gradient: nil)
    }

    private func ownershipKey(
        _ roomID: String, _ bridgeKey: String
    ) -> UnifiedOrchestrator.BridgeNativeOwnershipKey {
        .init(bridgeKey: bridgeKey, roomID: roomID)
    }

    // ── Suppression, per exact bridge + room ─────────────────────────

    // P6-4. An owned room is skipped while its neighbour still writes.
    func testAnOwnedRoomIsSkippedWhileItsNeighbourStillWrites() async {
        orchestrator.testBeginComposerTelemetrySession(
            roomID: "owned", bridgeID: "bridge-a", generation: 1, isRESTActive: true)
        orchestrator.allRooms = [
            allDayRoom("owned", bridge: "bridge-a", glID: "gl-owned"),
            allDayRoom("free", bridge: "bridge-a", glID: "gl-free"),
        ]
        await runAllDayTick()

        XCTAssertEqual(bridgeA.groupedEffectIDs, ["gl-free"], """
            one owned room must not suppress unrelated rooms — that is the whole \
            point of skipping per exact bridge+room rather than per tick
            """)
    }

    // P6-5. Composer REST suppresses only its exact room.
    func testComposerRESTSuppressesOnlyItsExactRoom() {
        orchestrator.testStageRESTComposition(
            roomID: "room-1", bridgeID: "bridge-a", api: bridgeA)

        XCTAssertFalse(orchestrator.testIsAllDayWriteAllowed(
            bridgeID: "bridge-a", roomID: "room-1"))
        XCTAssertTrue(orchestrator.testIsAllDayWriteAllowed(
            bridgeID: "bridge-a", roomID: "room-2"),
            "a sibling room on the same bridge stays eligible")
        XCTAssertTrue(orchestrator.testIsAllDayWriteAllowed(
            bridgeID: "bridge-b", roomID: "room-1"),
            "and the same room id on another bridge stays eligible")
    }

    // P6-6. Composer ENTERTAINMENT suppresses only its exact room — this holds
    //       even though a streaming composition has no REST runtime.
    func testComposerEntertainmentSuppressesOnlyItsExactRoom() {
        orchestrator.testStageEntertainmentOwner(roomID: "room-1", bridgeID: "bridge-a")

        XCTAssertFalse(orchestrator.testIsAllDayWriteAllowed(
            bridgeID: "bridge-a", roomID: "room-1"))
        XCTAssertTrue(orchestrator.testIsAllDayWriteAllowed(
            bridgeID: "bridge-a", roomID: "room-2"))
        XCTAssertTrue(orchestrator.testIsAllDayWriteAllowed(
            bridgeID: "bridge-b", roomID: "room-1"))
    }

    // P6-7. A Studio app-driven effect suppresses only its exact room.
    func testStudioScopeSuppressesOnlyItsExactRoom() {
        orchestrator.testSetActiveStudioRestScope(bridgeKey: "bridge-a", roomID: "room-1")

        XCTAssertFalse(orchestrator.testIsAllDayWriteAllowed(
            bridgeID: "bridge-a", roomID: "room-1"))
        XCTAssertTrue(orchestrator.testIsAllDayWriteAllowed(
            bridgeID: "bridge-a", roomID: "room-2"))
        XCTAssertTrue(orchestrator.testIsAllDayWriteAllowed(
            bridgeID: "bridge-b", roomID: "room-1"),
            "the Studio slot carries a bridge key, so it cannot suppress bridge B")
    }

    // P6-8. Bridge-stored playback suppresses where its manifest says it runs.
    //       Manifests persist, so a look uploaded in an earlier session really
    //       is still running on that bridge.
    func testBridgeStoredManifestSuppressesItsOwnBridgeAndRoom() {
        _ = stageManifest(
            roomID: "room-1", bridgeIP: "192.0.2.1",
            sensorID: "S1", ruleIDs: ["R1"], scheduleID: "SC1")

        XCTAssertFalse(orchestrator.testIsAllDayWriteAllowed(
            bridgeID: "bridge-a", roomID: "room-1"),
            "bridge A hosts the manifest (192.0.2.1)")
        XCTAssertTrue(orchestrator.testIsAllDayWriteAllowed(
            bridgeID: "bridge-b", roomID: "room-1"), """
            the SAME room id on bridge B is untouched — manifests are matched on \
            roomID AND bridge IP, never roomID alone
            """)
        XCTAssertTrue(orchestrator.testIsAllDayWriteAllowed(
            bridgeID: "bridge-a", roomID: "room-2"))
    }

    // P6-9. A one-shot leaves the room eligible: nothing about a completed
    //       command may create permanent suppression.
    func testAOneShotLeavesTheRoomEligible() async {
        // A Now-Playing row is exactly what a one-shot leaves behind.
        orchestrator.addActiveEffect(ActiveEffectEntry(
            id: "room-1", roomName: "Room 1", groupedLightID: "gl-room-1",
            effectID: "one-shot", effectName: "One Shot", effectIcon: "sparkles",
            isAppDriven: false))

        XCTAssertTrue(orchestrator.testIsAllDayWriteAllowed(
            bridgeID: "bridge-a", roomID: "room-1"), """
            that row is a display mirror with no bridge identity, and its \
            isAppDriven flag is false for BOTH firmware effects and one-shots — \
            it cannot be evidence of a continuing writer
            """)

        orchestrator.allRooms = [allDayRoom("room-1", bridge: "bridge-a")]
        await runAllDayTick()
        XCTAssertEqual(bridgeA.groupedEffectIDs, ["gl-room-1"],
            "so the room still receives its All-Day update")
    }

    // P6-11. Ownership on bridge A does not suppress bridge B.
    func testOwnershipOnBridgeADoesNotSuppressBridgeB() async {
        orchestrator.testBeginComposerTelemetrySession(
            roomID: "shared", bridgeID: "bridge-a", generation: 1, isRESTActive: true)
        orchestrator.allRooms = [
            allDayRoom("shared", bridge: "bridge-a", glID: "gl-a"),
            allDayRoom("shared", bridge: "bridge-b", glID: "gl-b"),
        ]
        await runAllDayTick()

        XCTAssertEqual(bridgeA.groupedEffectIDs, [], "the owned bridge+room is skipped")
        XCTAssertEqual(bridgeB.groupedEffectIDs, ["gl-b"], """
            the identically-named room on bridge B still updates — identical \
            room ids on different bridges must remain independent
            """)
    }

    // P6-12. When ownership ends the room is eligible on the NEXT normal tick.
    //        There is deliberately no immediate catch-up write.
    func testOwnershipEndingMakesTheRoomEligibleOnTheNextTick() async {
        let token = orchestrator.beginBridgeNativeOwnership(
            roomID: "room-1", bridgeID: "bridge-a")
        orchestrator.allRooms = [allDayRoom("room-1", bridge: "bridge-a")]

        await runAllDayTick()
        XCTAssertEqual(bridgeA.groupedEffectIDs, [], "owned: skipped")

        orchestrator.endBridgeNativeOwnership(token)
        await runAllDayTick()
        XCTAssertEqual(bridgeA.groupedEffectIDs, ["gl-room-1"],
            "freed: delivered on the next tick, with no catch-up burst")
    }

    // P6-10. Ownership that begins AFTER the enqueue still prevents the write.
    //        An enqueue-time check alone cannot do this.
    func testOwnershipBeginningAfterEnqueuePreventsTheWrite() async {
        orchestrator.allRooms = [allDayRoom("room-1", bridge: "bridge-a")]
        let sender = orchestrator.testAllDayRestSender(for: "bridge-a")!

        let parked = RestGate()
        await sender.enqueue(scope: allDayScope("__park__")) { _ in
            parked.signalStarted()
            await parked.waitForRelease()
        }
        await parked.waitUntilStarted()

        await orchestrator.testTickAllDayScenes(
            anchor: allDayAnchor(), generation: orchestrator.testAllDayGeneration())

        // Playback claims the room while All-Day's write sits pending.
        orchestrator.beginBridgeNativeOwnership(roomID: "room-1", bridgeID: "bridge-a")

        parked.release()
        await drainAllDay(sender)

        XCTAssertEqual(bridgeA.groupedEffectIDs, [], """
            the dispatch-time recheck must reject it — ownership can begin \
            between enqueue and dispatch, and that write must not land
            """)
    }

    // ── Bridge-native ownership registry ─────────────────────────────

    func testBridgeNativeOwnershipSuppressesItsExactBridgeAndRoom() {
        orchestrator.beginBridgeNativeOwnership(roomID: "room-1", bridgeID: "bridge-a")

        XCTAssertFalse(orchestrator.testIsAllDayWriteAllowed(
            bridgeID: "bridge-a", roomID: "room-1"))
        XCTAssertTrue(orchestrator.testIsAllDayWriteAllowed(
            bridgeID: "bridge-a", roomID: "room-2"))
    }

    func testBridgeNativeOwnershipOnOneBridgeLeavesTheOtherEligible() {
        orchestrator.beginBridgeNativeOwnership(roomID: "shared", bridgeID: "bridge-a")

        XCTAssertFalse(orchestrator.testIsAllDayWriteAllowed(
            bridgeID: "bridge-a", roomID: "shared"))
        XCTAssertTrue(orchestrator.testIsAllDayWriteAllowed(
            bridgeID: "bridge-b", roomID: "shared"),
            "ownership is keyed by bridge AND room, never by room alone")
    }

    func testAStaleBridgeNativeTokenCannotClearItsReplacement() {
        let old = orchestrator.beginBridgeNativeOwnership(roomID: "room-1", bridgeID: "bridge-a")
        let new = orchestrator.beginBridgeNativeOwnership(roomID: "room-1", bridgeID: "bridge-a")

        orchestrator.endBridgeNativeOwnership(old)

        XCTAssertFalse(orchestrator.testIsAllDayWriteAllowed(
            bridgeID: "bridge-a", roomID: "room-1"), """
            the replacement still owns the room — a stop that completes late \
            must not hand the room back to All-Day
            """)

        orchestrator.endBridgeNativeOwnership(new)
        XCTAssertTrue(orchestrator.testIsAllDayWriteAllowed(
            bridgeID: "bridge-a", roomID: "room-1"),
            "and the CURRENT token does release it")
    }

    func testBridgeNativeSuppressionNeedsNoMountedStudioView() {
        orchestrator.studioStopHandler = nil
        orchestrator.beginBridgeNativeOwnership(roomID: "room-1", bridgeID: "bridge-a")

        XCTAssertFalse(orchestrator.testIsAllDayWriteAllowed(
            bridgeID: "bridge-a", roomID: "room-1"), """
            correctness may not rest on an optional view-installed probe whose \
            nil value would read as "not owned"
            """)
    }

    func testBridgeRemovalClearsOnlyThatBridgesBridgeNativeOwnership() async {
        orchestrator.beginBridgeNativeOwnership(roomID: "room-1", bridgeID: "bridge-a")
        orchestrator.beginBridgeNativeOwnership(roomID: "room-1", bridgeID: "bridge-b")

        await orchestrator.removeBridge(id: "bridge-a")

        XCTAssertEqual(orchestrator.testBridgeNativeOwners(),
            [ownershipKey("room-1", "bridge-b")], """
            only the removed bridge's claims are dropped — another bridge's \
            firmware effect is still running and still owns its room
            """)
    }

    // ── A4: ownership begins before the first mutating write ─────────

    // A4-a. The claim is visible while the FIRST mutating request is in flight.
    func testBridgeNativeOwnershipIsRegisteredBeforeTheFirstNetworkMutation() async {
        let vm = makeStudioVM()
        let gate = RestGate()
        bridgeA.stageGroupedStateGate(gate)

        let finished = RestGate()
        Task {
            await vm.apply(bridgeNativeCard(), roomOverride: firmwareRoom(),
                           preferEntertainmentOverride: nil)
            finished.signalStarted()
        }
        await gate.waitUntilStarted()

        XCTAssertTrue(orchestrator.testBridgeNativeOwners().contains(
            ownershipKey("room-1", "bridge-a")), """
            the group-on PUT is already in flight — claiming the room only at \
            RunningEffect time would leave this whole startup window open to an \
            All-Day overwrite
            """)
        XCTAssertFalse(orchestrator.testIsAllDayWriteAllowed(
            bridgeID: "bridge-a", roomID: "room-1"))

        gate.release()
        await finished.waitUntilStarted()
    }

    // A4-b. An All-Day write parked before the startup is REJECTED when it is
    //       released during that startup.
    func testAnAllDayClosureParkedBeforeBridgeNativeStartupIsRejectedOnRelease() async {
        orchestrator.allRooms = [allDayRoom("room-1", bridge: "bridge-a")]
        let sender = orchestrator.testAllDayRestSender(for: "bridge-a")!

        let parked = RestGate()
        await sender.enqueue(scope: allDayScope("__park__")) { _ in
            parked.signalStarted()
            await parked.waitForRelease()
        }
        await parked.waitUntilStarted()
        await orchestrator.testTickAllDayScenes(
            anchor: allDayAnchor(), generation: orchestrator.testAllDayGeneration())

        let vm = makeStudioVM()
        let startGate = RestGate()
        bridgeA.stageGroupedStateGate(startGate)
        let finished = RestGate()
        Task {
            await vm.apply(bridgeNativeCard(), roomOverride: firmwareRoom(),
                           preferEntertainmentOverride: nil)
            finished.signalStarted()
        }
        await startGate.waitUntilStarted()

        parked.release()
        await drainAllDay(sender)

        XCTAssertEqual(bridgeA.groupedEffectIDs, [], """
            All-Day's grouped_light effect PUT must never land on a room whose \
            firmware effect is mid-startup
            """)

        startGate.release()
        await finished.waitUntilStarted()
    }

    // A4-c. A startup that exits because no lights resolved releases the claim.
    func testNoLightBridgeNativeExitReleasesTheProvisionalToken() async {
        let vm = makeStudioVM()

        await vm.apply(bridgeNativeCard(), roomOverride: firmwareRoom(lights: []),
                       preferEntertainmentOverride: nil)

        XCTAssertTrue(orchestrator.testBridgeNativeOwners().isEmpty,
            "the provisional claim is released on the no-light exit")
        XCTAssertTrue(orchestrator.testIsAllDayWriteAllowed(
            bridgeID: "bridge-a", roomID: "room-1"),
            "so All-Day may resume for that room")
        XCTAssertNil(vm.runningEffects["room-1"],
            "and nothing was registered as running")
    }

    // A4-d. Same for the unsupported-routing exit.
    func testUnsupportedRoutingExitReleasesTheProvisionalToken() async {
        // A light that reports a capability list, but not the effect we ask for.
        bridgeA.stageLights([capabilityLight(id: "L1", v1Effects: ["candle"])])
        let vm = makeStudioVM()
        var room = firmwareRoom()
        room.isOn = false   // exercise the roomWasOff undo

        await vm.apply(bridgeNativeCard(id: "fire-card", effect: "fire"),
                       roomOverride: room, preferEntertainmentOverride: nil)

        XCTAssertTrue(orchestrator.testBridgeNativeOwners().isEmpty, """
            nothing is running after an unsupported verdict, so the room must \
            not stay suppressed from All-Day
            """)
        XCTAssertNil(vm.runningEffects["room-1"])
        XCTAssertTrue(bridgeA.groupedStateIDs.contains("gl-room-1"),
            "the group-on that preceded the verdict still happened")
    }

    // A4-e. A successful startup transfers EXACTLY one token — the provisional
    //       defer must not also release it.
    func testSuccessfulBridgeNativeStartupTransfersExactlyOneToken() async {
        let vm = makeStudioVM()

        await vm.apply(bridgeNativeCard(), roomOverride: firmwareRoom(),
                       preferEntertainmentOverride: nil)

        XCTAssertEqual(orchestrator.testBridgeNativeOwners(),
            [ownershipKey("room-1", "bridge-a")],
            "exactly one claim survives a successful start")
        XCTAssertEqual(
            vm.runningEffects["room-1"]?.bridgeNativeOwnership?.key,
            ownershipKey("room-1", "bridge-a"),
            "and the token the effect holds IS the one the registry holds")
    }

    // ── A2: release survives missing network state ───────────────────

    /// Inject a running bridge-native effect plus its orchestrator claim,
    /// exactly as a successful startup leaves them.
    @discardableResult
    private func injectRunningFirmwareEffect(
        into vm: StudioViewModel, room: RoomDisplayItem,
        card: StudioCard, lightIDs: [String] = ["L1"]
    ) -> UnifiedOrchestrator.BridgeNativeOwnershipToken {
        let token = orchestrator.beginBridgeNativeOwnership(
            roomID: room.id, bridgeID: room.bridgeID)
        vm.runningEffects[room.id] = RunningEffect(
            cardID: card.id, card: card, room: room,
            lightIDs: lightIDs, isEntertainment: false,
            requestedTransport: nil, transportFallback: false,
            v2CapableLightIDs: [], bridgeNativeOwnership: token)
        return token
    }

    // A2-a. No bridge client at stop time. The old combined guard returned
    //       before the switch AND before the cleanup, stranding the claim.
    func testStopWithNoBridgeClientStillReleasesBridgeNativeOwnership() async {
        let vm = makeStudioVM()
        let room = firmwareRoom("room-1", bridge: "bridge-gone")
        injectRunningFirmwareEffect(into: vm, room: room, card: bridgeNativeCard())

        await vm.stopFromNowPlaying(roomID: "room-1")

        XCTAssertTrue(orchestrator.testBridgeNativeOwners().isEmpty, """
            an unreachable bridge must not strand the claim — the room would be \
            skipped by All-Day forever
            """)
        XCTAssertNil(vm.runningEffects["room-1"],
            "and the running-effect entry is cleaned up too")
    }

    // A2-b. No groupedLightID — the same class of early return.
    func testStopWithNoGroupedLightIDStillReleasesBridgeNativeOwnership() async {
        let vm = makeStudioVM()
        let room = firmwareRoom("room-1", bridge: "bridge-a", glID: nil)
        injectRunningFirmwareEffect(into: vm, room: room, card: bridgeNativeCard())

        await vm.stopFromNowPlaying(roomID: "room-1")

        XCTAssertTrue(orchestrator.testBridgeNativeOwners().isEmpty)
        XCTAssertNil(vm.runningEffects["room-1"])
    }

    // A2-c. A failing firmware cleanup request still releases the claim.
    func testFailedFirmwareCleanupStillReleasesBridgeNativeOwnership() async {
        let vm = makeStudioVM()
        bridgeA.stageLightEffectFailures(["L1"])
        injectRunningFirmwareEffect(
            into: vm, room: firmwareRoom(), card: bridgeNativeCard())

        await vm.stopFromNowPlaying(roomID: "room-1")

        XCTAssertTrue(orchestrator.testBridgeNativeOwners().isEmpty,
            "teardown is best-effort; ownership release is not")
    }

    // A2-d. A stale stop completing AFTER a replacement must clear neither the
    //       replacement's claim nor its Now-Playing row.
    func testAStaleStopAfterReplacementPreservesTheReplacementOwnershipAndNowPlaying() async {
        let vm = makeStudioVM()
        let room = firmwareRoom()
        injectRunningFirmwareEffect(
            into: vm, room: room, card: bridgeNativeCard(id: "old-card"))
        orchestrator.addActiveEffect(ActiveEffectEntry(
            id: "room-1", roomName: "Room 1", groupedLightID: "gl-room-1",
            effectID: "old-card", effectName: "Old", effectIcon: "flame",
            isAppDriven: false))

        // Park the stop inside its per-light firmware teardown.
        let teardownGate = RestGate()
        bridgeA.stageLightNativeEffectGate(teardownGate)
        let stopFinished = RestGate()
        Task {
            await vm.stopFromNowPlaying(roomID: "room-1")
            stopFinished.signalStarted()
        }
        await teardownGate.waitUntilStarted()

        // A replacement takes the room while the old stop is still suspended.
        injectRunningFirmwareEffect(
            into: vm, room: room, card: bridgeNativeCard(id: "new-card"))
        orchestrator.addActiveEffect(ActiveEffectEntry(
            id: "room-1", roomName: "Room 1", groupedLightID: "gl-room-1",
            effectID: "new-card", effectName: "New", effectIcon: "flame",
            isAppDriven: false))

        teardownGate.release()
        await stopFinished.waitUntilStarted()

        XCTAssertTrue(orchestrator.testBridgeNativeOwners().contains(
            ownershipKey("room-1", "bridge-a")), """
            the stale stop's token no longer holds the room, so its release is a \
            no-op — the replacement keeps its claim
            """)
        XCTAssertEqual(vm.runningEffects["room-1"]?.cardID, "new-card",
            "and the replacement's RunningEffect survives")
        XCTAssertEqual(orchestrator.activeEffectEntries.filter { $0.id == "room-1" }.count, 1,
            "its Now-Playing row survives too")
        XCTAssertFalse(orchestrator.testIsAllDayWriteAllowed(
            bridgeID: "bridge-a", roomID: "room-1"),
            "so All-Day still yields to the replacement")
    }

    // ── Packets 4 and 5 remain untouched ─────────────────────────────

    // P6-19. No All-Day action alters Composer telemetry.
    func testAllDayTicksAlterNoComposerTelemetry() async {
        let clock = TelemetryTestClock(1_000)
        stageTelemetrySession(room: "room-1", bridge: "bridge-a", clock: clock)
        await completeComposerItem(
            room: "room-1", bridge: "bridge-a", clock: clock, finishAt: 1_001)
        let before = telemetrySnap("room-1", "bridge-a")

        orchestrator.allRooms = [allDayRoom("room-2", bridge: "bridge-a")]
        await runAllDayTick()

        let after = telemetrySnap("room-1", "bridge-a")
        XCTAssertEqual(after.successfulItems, before.successfulItems,
            "All-Day writes are not Composer sends and must not be counted as any")
        XCTAssertEqual(after.cadenceSeconds, before.cadenceSeconds,
            "nor may they move the published cadence")
    }

    // P6-20. No All-Day action alters packet-5 rotation or degradation state.
    func testAllDayTicksAlterNoRotationOrDegradationState() async {
        orchestrator.testStageRESTComposition(
            roomID: "room-1", bridgeID: "bridge-a", api: bridgeA,
            lightIDs: (0..<3).map { "L\($0)" })
        let before = rotation("room-1", "bridge-a")

        orchestrator.allRooms = [allDayRoom("room-2", bridge: "bridge-a")]
        await runAllDayTick()

        let after = rotation("room-1", "bridge-a")
        XCTAssertEqual(after?.cursor, before?.cursor)
        XCTAssertEqual(after?.eligibleOperationCount, before?.eligibleOperationCount)
        XCTAssertNil(orchestrator.testCompositionDegradation(
            roomID: "room-1", bridgeID: "bridge-a"),
            "All-Day cannot invent a degradation reason for a Composer room")
    }

    // ── Source guard ─────────────────────────────────────────────────

    // P6-23. The dispatch-time recheck must not be optimised away, and the
    //        firmware claim must precede the first mutating write.
    func testAllDayRechecksOwnershipAtDispatchNotOnlyAtEnqueue() throws {
        let code = try productionCode("HueHome/Core/Network/UnifiedOrchestrator.swift")
        let tick = try XCTUnwrap(
            functionBody(code, startingWith: "private func tickAllDayScenes(anchor:"),
            "tickAllDayScenes must be findable")

        let enqueueIndex = try XCTUnwrap(
            tick.firstIndex { $0.contains(".enqueue(") },
            "the tick must enqueue its work")
        let ownershipChecks = tick.indices.filter {
            tick[$0].contains("isAllDayWriteAllowed(")
        }

        XCTAssertTrue(ownershipChecks.contains { $0 < enqueueIndex }, """
            an ownership check must run at target selection, so an already-owned \
            room is never queued
            """)
        XCTAssertTrue(ownershipChecks.contains { $0 > enqueueIndex }, """
            and AGAIN inside the enqueued closure: ownership can begin after the \
            enqueue but before the dispatch, and an enqueue-only check would let \
            that write land
            """)

        let studio = try productionCode("HueHome/UI/Studio/StudioViewModel.swift")
        let beginIndex = try XCTUnwrap(
            studio.range(of: "beginBridgeNativeOwnership(")?.lowerBound,
            "the firmware startup must claim the room")
        let firstMutation = try XCTUnwrap(
            studio.range(of: "api.setGroupedLightState(")?.lowerBound,
            "…and setGroupedLightState is that startup's first mutating request")
        XCTAssertLessThan(beginIndex, firstMutation, """
            ownership must be claimed BEFORE the group-on PUT — claiming it at \
            RunningEffect time leaves the whole startup window unowned
            """)
        XCTAssertTrue(studio.contains("if !ownershipTransferred"), """
            and a defer must release the provisional claim on every exit that \
            never reached registration — enumerating today's early returns would \
            not protect the next one added
            """)
    }

    // ──────────────────────────────────────────────
    // MARK: - Composer 2 packet 7: consent before replacing another controller
    // ──────────────────────────────────────────────
    //
    // ChromaGlow yields to third-party Entertainment sessions. Automatic
    // cleanup never touches one (EntertainmentOwnershipTests covers that); the
    // question is only ever asked when an EXPLICIT user playback action needs
    // the bridge a stranger is already using.
    //
    // What these lock is that nothing is mutated before the user answers, that
    // "Take Over" stops exactly the one session they agreed to replace, and
    // that a start blocked by a foreign owner never quietly becomes room mode
    // — which would play over the other app's show instead of asking.
    //
    // Ordering and presence only. No sleeps, no waiters.

    /// A room on bridge B whose lights are L1/L2 — the members of `area-b`.
    private func streamRoomOnB(id: String = "room-b") -> RoomDisplayItem {
        RoomDisplayItem(
            kind: .room,
            id: id, name: "Bedroom B", archetype: nil,
            isOn: true, brightness: 50,
            groupedLightID: "gl-\(id)", lightCount: 2,
            bridgeID: "bridge-b",
            childResourceRefs: [(rid: "L1", rtype: "light"), (rid: "L2", rtype: "light")]
        )
    }

    private func streamRoomOnA(id: String = "room-a") -> RoomDisplayItem {
        RoomDisplayItem(
            kind: .room,
            id: id, name: "Bedroom A", archetype: nil,
            isOn: true, brightness: 50,
            groupedLightID: "gl-\(id)", lightCount: 2,
            bridgeID: "bridge-a",
            childResourceRefs: [(rid: "L1", rtype: "light"), (rid: "L2", rtype: "light")]
        )
    }

    private func p7Light(_ id: String, device: String) -> HueLight {
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

    /// One streamable area (`area-b`, channels over L1/L2) plus whatever else
    /// is active on the bridge. `active` lists the configuration ids the
    /// bridge reports streaming right now.
    private func stageStreamableBridge(_ spy: RoutingSpyClient,
                                       areaID: String = "area-b",
                                       active: [String] = []) {
        spy.stageLights([p7Light("L1", device: "D1"), p7Light("L2", device: "D2")])
        spy.stageEntertainmentServices(
            #"{"data":[{"id":"E1","owner":{"rid":"D1","rtype":"device"}},"# +
            #"{"id":"E2","owner":{"rid":"D2","rtype":"device"}}]}"#)
        spy.stageEntertainmentConfigs(Self.configsJSON(areaID: areaID, active: active))
    }

    /// `area-b` always present (so the room HAS somewhere to stream), with the
    /// listed ids marked active.
    private static func configsJSON(areaID: String, active: [String]) -> String {
        let channels = #"{"channel_id":0,"position":{"x":0,"y":0,"z":0},"members":[{"service":{"rid":"E1","rtype":"entertainment"}}]},"# +
                       #"{"channel_id":1,"position":{"x":0,"y":0,"z":0},"members":[{"service":{"rid":"E2","rtype":"entertainment"}}]}"#
        var items = [
            #"{"id":"\#(areaID)","metadata":{"name":"Bedroom"},"status":"\#(active.contains(areaID) ? "active" : "inactive")","channels":[\#(channels)]}"#
        ]
        for id in active where id != areaID {
            items.append(#"{"id":"\#(id)","metadata":{"name":"Other"},"status":"active","channels":[]}"#)
        }
        return #"{"data":[\#(items.joined(separator: ","))]}"#
    }

    /// A Studio VM on the shared orchestrator, with an isolated ownership
    /// store so nothing here reads or writes the real user's records.
    ///
    /// Credentials are real Keychain writes because the entertainment cache
    /// warm refuses to run for a bridge with no client key — and the takeover
    /// preflight resolves its target area through that same production warm,
    /// deliberately, so the area it names is the area that gets streamed. The
    /// key is non-hex, so `decodePSK` refuses before any socket exists.
    private func makeP7VM() -> StudioViewModel {
        for (id, ip) in [("bridge-a", "192.0.2.1"), ("bridge-b", "192.0.2.2")] {
            try? KeychainManager.shared.saveCredentials(
                ip: ip, token: "t", clientKey: "ZZ-not-hex", for: id)
            addTeardownBlock { KeychainManager.shared.deleteCredentials(for: id) }
        }
        let suite = "MultiBridgeRoutingTests.p7"
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        let store = EntertainmentSessionOwnership(defaults: UserDefaults(suiteName: suite)!)
        store.resetForTesting()
        orchestrator.injectForTesting(ownership: store)
        ownershipStore = store
        addTeardownBlock {
            store.resetForTesting()
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        let vm = StudioViewModel()
        vm.configure(orchestrator: orchestrator)
        return vm
    }

    /// The isolated ownership store `makeP7VM` installed, so a test can assert
    /// on what a start actually recorded.
    private var ownershipStore: EntertainmentSessionOwnership!

    /// Stops of the third-party session specifically. A ChromaGlow start whose
    /// DTLS open fails sends its OWN compensating stop for its OWN area
    /// (L-11) — correct, and unrelated to the takeover.
    private func foreignStops(_ spy: RoutingSpyClient, _ configID: String) -> [String] {
        spy.entertainmentStops.filter { $0 == configID }
    }

    /// The Party card streams, so it is the surface that can collide with
    /// another controller.
    private func streamingCard(_ vm: StudioViewModel) throws -> StudioCard {
        try XCTUnwrap(vm.liveModeCards.first { $0.id == "party" })
    }

    // ── The prompt appears only for an explicit start ─────────

    /// P7-15
    func testAnExplicitStartOverAForeignOwnerAsksBeforeAnyMutation() async throws {
        stageStreamableBridge(bridgeB, active: ["cfg-someone-else"])
        let vm = makeP7VM()
        let party = try streamingCard(vm)

        await vm.apply(party, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)

        let request = try XCTUnwrap(vm.foreignTakeoverRequest,
            "an explicit start over another app's session must ask first")
        XCTAssertEqual(request.bridgeID, "bridge-b")
        XCTAssertEqual(request.foreignConfigID, "cfg-someone-else")
        XCTAssertEqual(request.targetConfigID, "area-b",
            "the request must name the area this room would actually stream")
        XCTAssertTrue(bridgeB.entertainmentActions.isEmpty,
            "no stop, no start, and no DTLS may precede the user's answer")
        XCTAssertTrue(bridgeB.groupedStateIDs.isEmpty && bridgeB.groupedEffectIDs.isEmpty,
            "and no playback bookkeeping may be partially mutated either")
        XCTAssertNil(vm.runningEffects[streamRoomOnB().id],
            "the requested look must not be running")
    }

    /// P7-16
    func testCancelPerformsZeroNetworkWritesAndDoesNotStart() async throws {
        stageStreamableBridge(bridgeB, active: ["cfg-someone-else"])
        let vm = makeP7VM()
        let party = try streamingCard(vm)
        await vm.apply(party, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)
        XCTAssertNotNil(vm.foreignTakeoverRequest)

        vm.cancelForeignTakeover()

        XCTAssertNil(vm.foreignTakeoverRequest, "the request is consumed")
        XCTAssertTrue(bridgeB.entertainmentActions.isEmpty,
            "Keep Existing means the other app's show is never touched")
        XCTAssertTrue(bridgeB.groupedStateIDs.isEmpty && bridgeB.groupedEffectIDs.isEmpty)
        XCTAssertNil(vm.runningEffects[streamRoomOnB().id],
            "and the requested look does not start")
    }

    /// P7-17
    func testConfirmStopsTheExactConsentedSessionThenStartsTheOriginalRequest() async throws {
        stageStreamableBridge(bridgeB, active: ["cfg-someone-else"])
        let vm = makeP7VM()
        let party = try streamingCard(vm)
        await vm.apply(party, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)

        // Taking over clears the bridge, exactly as the real one would.
        // Stopping the foreign session deactivates it, as a real bridge would.
        bridgeB.stageDeactivationOnStop { _ in
            Self.configsJSON(areaID: "area-b", active: [])
        }
        await vm.confirmForeignTakeover()

        XCTAssertEqual(foreignStops(bridgeB, "cfg-someone-else"), ["cfg-someone-else"],
            "exactly the one session the user agreed to replace, stopped exactly once")
        XCTAssertEqual(bridgeB.entertainmentActions.first.map { [$0.configID, $0.action] },
                       ["cfg-someone-else", "stop"],
            "and the stop comes FIRST — the takeover is resolved before we ask for the bridge")
        XCTAssertTrue(bridgeB.entertainmentStarts.contains("area-b"),
            "then the original request starts, on the area the request named")
        XCTAssertNil(vm.foreignTakeoverRequest, "no second prompt")
        XCTAssertNotNil(vm.runningEffects[streamRoomOnB().id],
            "the original request must actually play after a successful takeover")
    }

    /// P7-18
    func testDoubleConfirmCannotStopOrStartTwice() async throws {
        stageStreamableBridge(bridgeB, active: ["cfg-someone-else"])
        let vm = makeP7VM()
        let party = try streamingCard(vm)
        await vm.apply(party, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)
        // Stopping the foreign session deactivates it, as a real bridge would.
        bridgeB.stageDeactivationOnStop { _ in
            Self.configsJSON(areaID: "area-b", active: [])
        }

        await vm.confirmForeignTakeover()
        await vm.confirmForeignTakeover()
        await vm.confirmForeignTakeover()

        XCTAssertEqual(foreignStops(bridgeB, "cfg-someone-else"), ["cfg-someone-else"],
            "the request is consumed before the first await — a replayed confirm finds nothing")
        XCTAssertEqual(vm.runningEffects.count, 1)
    }

    /// P7-19
    func testAForeignSessionThatEndedBeforeConfirmationNeedsNoStop() async throws {
        stageStreamableBridge(bridgeB, active: ["cfg-someone-else"])
        let vm = makeP7VM()
        let party = try streamingCard(vm)
        await vm.apply(party, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)

        // The other app stopped on its own while the prompt was up.
        bridgeB.stageEntertainmentConfigs(Self.configsJSON(areaID: "area-b", active: []))
        await vm.confirmForeignTakeover()

        XCTAssertTrue(foreignStops(bridgeB, "cfg-someone-else").isEmpty,
            "there is nothing to stop — a redundant stop is a write nobody asked for")
        XCTAssertNotNil(vm.runningEffects[streamRoomOnB().id],
            "and the requested look still starts")
    }

    /// P7-20
    func testStaleConsentCannotStopADifferentForeignSession() async throws {
        stageStreamableBridge(bridgeB, active: ["cfg-first"])
        let vm = makeP7VM()
        let party = try streamingCard(vm)
        await vm.apply(party, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)
        XCTAssertEqual(vm.foreignTakeoverRequest?.foreignConfigID, "cfg-first")

        // A DIFFERENT controller took the bridge while the prompt was open.
        bridgeB.stageEntertainmentConfigs(Self.configsJSON(areaID: "area-b", active: ["cfg-second"]))
        await vm.confirmForeignTakeover()

        XCTAssertTrue(bridgeB.entertainmentStops.isEmpty,
            "consent named one session; it may not be spread onto its replacement")
        XCTAssertNil(vm.runningEffects[streamRoomOnB().id],
            "and playback must not begin over a session nobody consented to replace")
        XCTAssertEqual(vm.foreignTakeoverRequest?.foreignConfigID, "cfg-second",
            "a fresh decision is required, with its own identity")
        XCTAssertNotEqual(vm.foreignTakeoverRequest?.foreignConfigID, "cfg-first")
    }

    /// P7-37 — several controllers at once is ambiguous; fail closed.
    func testMultipleForeignSessionsFailClosedAndStopNone() async throws {
        stageStreamableBridge(bridgeB, active: ["cfg-one", "cfg-two"])
        let vm = makeP7VM()
        let party = try streamingCard(vm)

        await vm.apply(party, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)

        XCTAssertNil(vm.foreignTakeoverRequest,
            "there is no single session to name, so there is no honest question to ask")
        XCTAssertTrue(bridgeB.entertainmentStops.isEmpty, "and nothing may be stopped")
        XCTAssertNil(vm.runningEffects[streamRoomOnB().id])
    }

    /// P7-21
    func testATakeoverStopFailureDoesNotStartPlayback() async throws {
        stageStreamableBridge(bridgeB, active: ["cfg-someone-else"])
        bridgeB.stageEntertainmentStopFailures(["cfg-someone-else"])
        let vm = makeP7VM()
        let party = try streamingCard(vm)
        await vm.apply(party, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)

        await vm.confirmForeignTakeover()

        XCTAssertEqual(foreignStops(bridgeB, "cfg-someone-else"), ["cfg-someone-else"],
            "it was attempted")
        XCTAssertTrue(bridgeB.entertainmentStarts.isEmpty,
            "never claim a takeover that did not happen — no session may be opened")
        XCTAssertNil(vm.runningEffects[streamRoomOnB().id])
        XCTAssertTrue(vm.statusMessage.contains("take over"),
            "the failure must be said out loud, not swallowed")
    }

    /// P7-24 — an unreadable bridge is "unknown", which authorizes nothing.
    func testAnUnreadableBridgeRefusesHonestlyWithoutMutation() async throws {
        stageStreamableBridge(bridgeB, active: ["cfg-someone-else"])
        let vm = makeP7VM()
        let party = try streamingCard(vm)
        await vm.apply(party, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)
        XCTAssertNotNil(vm.foreignTakeoverRequest)

        bridgeB.entertainmentConfigsShouldFail = true
        await vm.confirmForeignTakeover()

        XCTAssertTrue(bridgeB.entertainmentStops.isEmpty,
            "we cannot see what is running, so we may not evict anything")
        XCTAssertNil(vm.runningEffects[streamRoomOnB().id])
        XCTAssertFalse(vm.statusMessage.isEmpty, "and it must say so")
    }

    /// P7-24b — a start that carries no consent refuses rather than treating
    /// its own invocation as agreement. This is what a non-interactive caller
    /// gets, and it must not silently fall back to room mode.
    func testANonInteractiveStartRefusesForeignTakeoverWithoutMutation() async {
        stageStreamableBridge(bridgeB, active: ["cfg-someone-else"])
        _ = makeP7VM()

        let outcome = await orchestrator.startStudioMode(
            key: "party", room: streamRoomOnB(), params: [:], colors: [:])

        guard case .needsForeignConsent = outcome else {
            return XCTFail("a start with no consent must refuse, not proceed: \(outcome)")
        }
        XCTAssertTrue(bridgeB.entertainmentActions.isEmpty,
            "refusing means touching nothing at all")
        XCTAssertTrue(bridgeB.groupedStateIDs.isEmpty && bridgeB.groupedEffectIDs.isEmpty,
            "and REST fallback is NOT the answer to a foreign conflict — that plays over their show quietly")
    }

    /// P7-22
    func testAConflictOnBridgeADoesNotBlockOrStopPlaybackOnBridgeB() async throws {
        stageStreamableBridge(bridgeA, active: ["cfg-a-foreign"])
        stageStreamableBridge(bridgeB, active: [])
        let vm = makeP7VM()
        let party = try streamingCard(vm)

        await vm.apply(party, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)

        XCTAssertNil(vm.foreignTakeoverRequest,
            "bridge A's owner may not gate playback on bridge B")
        XCTAssertNotNil(vm.runningEffects[streamRoomOnB().id], "bridge B starts normally")
        XCTAssertTrue(bridgeA.entertainmentActions.isEmpty,
            "and bridge A is left completely untouched")
        _ = streamRoomOnA()
    }

    /// P7-33 — a room with nowhere to stream was heading for room mode anyway,
    /// so another app's session is irrelevant to it.
    func testARoomWithNoStreamableAreaNeverPromptsAndFallsBackHonestly() async throws {
        // Lights that belong to no entertainment area on this bridge.
        bridgeB.stageLights([p7Light("L9", device: "D9")])
        bridgeB.stageEntertainmentServices(#"{"data":[]}"#)
        bridgeB.stageEntertainmentConfigs(
            #"{"data":[{"id":"cfg-someone-else","metadata":{"name":"Other"},"status":"active","channels":[]}]}"#)
        let vm = makeP7VM()
        let party = try streamingCard(vm)

        await vm.apply(party, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)

        XCTAssertNil(vm.foreignTakeoverRequest,
            "asking to take over a bridge this room could never stream on is a lie")
        XCTAssertTrue(bridgeB.entertainmentStops.isEmpty)
        XCTAssertNotNil(vm.runningEffects[streamRoomOnB().id],
            "the room still plays, in room mode")
    }

    /// P7-23 — the ChromaGlow-to-ChromaGlow handoff is untouched by all this.
    func testAnAppOwnedConflictStillFollowsTheExistingHandoffBehavior() async throws {
        let (vm, _) = makeVMWithComposerOwningBridgeB()
        let ambient = try liveModeCard(vm, "ambient")

        await vm.apply(ambient, roomOverride: roomOnBridgeB(), preferEntertainmentOverride: nil)

        XCTAssertNotNil(vm.entertainmentHandoffPrompt,
            "an app-owned conflict still raises the app-owned prompt")
        XCTAssertNil(vm.foreignTakeoverRequest,
            "and must NOT be mistaken for a third-party takeover — the two stay distinct")
    }

    /// P7-25 — the prompt answers a user action, never a background pass.
    func testLoadAllSchedulingDoesNotCreateTheConsentPrompt() async throws {
        stageStreamableBridge(bridgeB, active: ["cfg-someone-else"])
        stageStreamableBridge(bridgeA, active: ["cfg-also-foreign"])
        let vm = makeP7VM()

        await orchestrator.deactivateStuckEntertainmentSessions()

        XCTAssertNil(vm.foreignTakeoverRequest,
            "launch, foreground, and refresh must never ask about somebody else's show")
        XCTAssertTrue(bridgeA.entertainmentActions.isEmpty && bridgeB.entertainmentActions.isEmpty,
            "and must never touch it")
    }

    /// P7-34 — one selection, start to finish.
    func testTheCapturedTargetAreaIsTheOneThatGetsStreamed() async throws {
        stageStreamableBridge(bridgeB, active: ["cfg-someone-else"])
        let vm = makeP7VM()
        let party = try streamingCard(vm)
        await vm.apply(party, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)
        let captured = try XCTUnwrap(vm.foreignTakeoverRequest?.targetConfigID)

        // Stopping the foreign session deactivates it, as a real bridge would.
        bridgeB.stageDeactivationOnStop { _ in
            Self.configsJSON(areaID: "area-b", active: [])
        }
        await vm.confirmForeignTakeover()

        XCTAssertEqual(captured, "area-b")
        XCTAssertEqual(Set(bridgeB.entertainmentStarts), [captured],
            "the area named in the request is the only area ever started — one selection, no drift")
    }

    /// P7-36 — a consent token is bound and single-use.
    func testAConsentTokenCannotBeReused() async throws {
        stageStreamableBridge(bridgeB, active: ["cfg-someone-else"])
        let vm = makeP7VM()
        let party = try streamingCard(vm)
        await vm.apply(party, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)
        let request = try XCTUnwrap(vm.foreignTakeoverRequest)
        // Stopping the foreign session deactivates it, as a real bridge would.
        bridgeB.stageDeactivationOnStop { _ in
            Self.configsJSON(areaID: "area-b", active: [])
        }
        await vm.confirmForeignTakeover()
        let startsAfterFirst = bridgeB.entertainmentStarts.count

        // Replay the very same token by hand.
        let spent = EntertainmentConsent(requestID: request.id,
                                         bridgeID: request.bridgeID,
                                         targetConfigID: request.targetConfigID,
                                         foreignConfigID: request.foreignConfigID)
        bridgeB.stageEntertainmentConfigs(Self.configsJSON(areaID: "area-b", active: ["cfg-someone-else"]))
        let outcome = await orchestrator.startStudioMode(
            key: "party", room: streamRoomOnB(), params: [:], colors: [:],
            capturedPlan: request.plan, consent: spent)

        if case .started = outcome {
            XCTFail("a spent consent token must not authorize a second start")
        }
        XCTAssertEqual(bridgeB.entertainmentStarts.count, startsAfterFirst,
            "no second start")
        XCTAssertEqual(foreignStops(bridgeB, "cfg-someone-else"), ["cfg-someone-else"],
            "and no second stop")
    }

    /// P7-36b — a token issued for one bridge may not act on another.
    func testAConsentTokenIsBoundToItsBridgeAndTargetArea() async {
        stageStreamableBridge(bridgeB, active: ["cfg-someone-else"])
        _ = makeP7VM()

        let wrongBridge = EntertainmentConsent(requestID: UUID(),
                                               bridgeID: "bridge-a",
                                               targetConfigID: "area-b",
                                               foreignConfigID: "cfg-someone-else")
        let outcome = await orchestrator.startStudioMode(
            key: "party", room: streamRoomOnB(), params: [:], colors: [:],
            capturedPlan: nil, consent: wrongBridge)

        if case .started = outcome {
            XCTFail("a token bound to another bridge must not authorize this start")
        }
        XCTAssertTrue(bridgeB.entertainmentStops.isEmpty)
    }

    // ── Copy honesty ──────────────────────────────────────────

    /// P7-27
    func testNoUserFacingStringLeaksProtocolVocabulary() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        func code(_ relativePath: String) throws -> String {
            try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
        }

        // The copy itself, checked as values rather than by grepping for the
        // words — this is what the user actually reads.
        //
        // P7F-37 — the follow-up added three more copy homes, and every one of
        // them is rendered in an alert the user reads. A banned-word list that
        // covers only the packet-7 vocabulary would let the newest strings say
        // "DTLS" on day one.
        let strings = [
            EntertainmentConsentCopy.takeoverTitle,
            EntertainmentConsentCopy.keepExisting,
            EntertainmentConsentCopy.takeOver,
            EntertainmentConsentCopy.takeoverFailed,
            EntertainmentConsentCopy.bridgeUnreadable,
            EntertainmentHandoffCopy.switchTitle,
            EntertainmentHandoffCopy.keepPlaying,
            EntertainmentHandoffCopy.switchLooks,
            EntertainmentHandoffCopy.alreadyStreaming,
            EntertainmentHandoffCopy.stopFailed,
            EntertainmentHandoffCopy.handoffFailed,
            EntertainmentAvailabilityCopy.noCompatibleArea,
            EntertainmentAvailabilityCopy.noCompatibleAreaNothingChanged,
            EntertainmentAvailabilityCopy.couldNotCheck,
            EntertainmentAvailabilityCopy.couldNotStart,
            StudioSafetyCopy.strobeReduceMotion,
        ]
        for banned in ["REST", "DTLS", "API", "configuration ID", "session registry",
                       "entertainment_configuration", "refcount"] {
            for string in strings {
                XCTAssertFalse(string.contains(banned),
                    "user-facing copy must not say “\(banned)”: \(string)")
            }
        }

        XCTAssertEqual(EntertainmentConsentCopy.takeoverTitle,
                       "Another app was controlling these lights — take over?")
        XCTAssertEqual(EntertainmentConsentCopy.keepExisting, "Keep Existing")
        XCTAssertEqual(EntertainmentConsentCopy.takeOver, "Take Over")

        // P7F-37 — the follow-up's copy, by value. The ChromaGlow-owned switch
        // deliberately does NOT borrow the third-party vocabulary: "Take Over"
        // is about a stranger's show, "Switch" is about two of the user's own
        // looks, and one shared wording would make the graver question read
        // like the routine one.
        XCTAssertEqual(EntertainmentHandoffCopy.switchTitle, "Switch lighting modes?")
        XCTAssertEqual(EntertainmentHandoffCopy.keepPlaying, "Keep Playing")
        XCTAssertEqual(EntertainmentHandoffCopy.switchLooks, "Switch")
        XCTAssertNotEqual(EntertainmentHandoffCopy.switchLooks, EntertainmentConsentCopy.takeOver,
            "the two consents must never present the same word to the user")
        XCTAssertNotEqual(EntertainmentHandoffCopy.keepPlaying, EntertainmentConsentCopy.keepExisting)
        XCTAssertEqual(EntertainmentAvailabilityCopy.noCompatibleArea,
            "There's no compatible Entertainment Area for that room. Playing in Room mode instead.")
        // The refusal twin. Same missing area, but on the handoff gate — which
        // starts NOTHING — so it must not promise the Room-mode fallback the
        // sentence above names.
        XCTAssertEqual(EntertainmentAvailabilityCopy.noCompatibleAreaNothingChanged,
            "There's no compatible Entertainment Area for that room, so nothing was changed.")
        XCTAssertFalse(EntertainmentAvailabilityCopy.noCompatibleAreaNothingChanged.contains("Room mode"),
            "a sentence on a path where nothing starts may not promise Room mode")
        XCTAssertEqual(EntertainmentAvailabilityCopy.couldNotCheck,
            "Streaming availability could not be checked right now.")
        XCTAssertEqual(EntertainmentAvailabilityCopy.couldNotStart,
            "Streaming couldn't start for that room, so nothing was changed.")
        XCTAssertEqual(StudioSafetyCopy.strobeReduceMotion,
            "Strobe is unavailable while Reduce Motion is on.")

        // And the prompt must not name the other app or its configuration —
        // the bridge never told us who it is, so any name would be a guess.
        let view = try code("HueHome/UI/Studio/StudioView.swift")
        XCTAssertTrue(view.contains("EntertainmentConsentCopy.takeoverTitle"),
            "the alert must use the reviewed copy, not an inline duplicate")
        XCTAssertFalse(view.contains("foreignConfigID)"),
            "the configuration id is diagnostic, never something the user reads")
    }

    /// P7-26 heir — the consent gate must stay at the choke point, not be
    /// re-implemented per card. Behaviour tests would still pass if someone
    /// added a second, subtly different copy, so pin the shape.
    func testTheConsentGateLivesAtTheSharedChokePoint() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let orchestratorSource = try String(
            contentsOf: repoRoot.appendingPathComponent("HueHome/Core/Network/UnifiedOrchestrator.swift"),
            encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        XCTAssertTrue(orchestratorSource.contains("func acquireEntertainment("),
            "every session still opens through one function")
        XCTAssertTrue(orchestratorSource.contains("foreignConflictCheck("),
            "and that function asks the consent question")
        XCTAssertFalse(orchestratorSource.contains("-> HueEntertainmentClient? {"),
            "the optional-client return could not distinguish a foreign conflict from a technical failure — that is how a conflict became a silent REST fallback")

        // Acquisition must stay separate from installation. Installing inside
        // the acquire would put a live candidate into studioEntClients before
        // the caller had decided the start was going ahead — and a conflict
        // discovered afterwards would then be reported with the previous look
        // already replaced.
        let acquireBody = try XCTUnwrap(
            functionBody(orchestratorSource, startingWith: "func acquireEntertainment("))
        XCTAssertFalse(acquireBody.joined(separator: "\n").contains("studioEntClients["),
            "the candidate may not be installed until the transaction commits")
        XCTAssertTrue(orchestratorSource.contains("func commitEntertainment("),
            "installation is its own, explicitly named step")
    }

    // ── Fail closed, and never at the cost of what is already playing ──
    //
    // The first version answered the preflight with an optional, so "several
    // controllers at once" and "could not read the bridge" both arrived as
    // nil — indistinguishable from "all clear". `apply` then carried on into
    // the teardown below it and destroyed the running look on the strength of
    // an answer that was really a shrug.

    /// Stage a room on bridge B that is ALREADY playing, so every fail-closed
    /// path can be checked against something it could destroy.
    private func stageRunningEffectOnB(_ vm: StudioViewModel) throws -> StudioCard {
        stageStreamableBridge(bridgeB, active: [])
        let party = try streamingCard(vm)
        return party
    }

    /// P7-41
    func testMultipleForeignSessionsPreserveAnAlreadyRunningEffect() async throws {
        stageStreamableBridge(bridgeB, active: [])
        let vm = makeP7VM()
        let party = try streamingCard(vm)

        // Something is already playing in this room.
        await vm.apply(party, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)
        let running = try XCTUnwrap(vm.runningEffects[streamRoomOnB().id])
        let actionsBefore = bridgeB.entertainmentActions.count

        // Now two other controllers appear, and the user taps again.
        bridgeB.stageEntertainmentConfigs(
            Self.configsJSON(areaID: "area-b", active: ["cfg-one", "cfg-two"]))
        await vm.apply(party, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)

        XCTAssertNil(vm.foreignTakeoverRequest,
            "there is no single session to name, so there is no honest question")
        XCTAssertTrue(bridgeB.entertainmentStops.filter { $0 == "cfg-one" || $0 == "cfg-two" }.isEmpty,
            "and no licence to guess which one to evict")
        XCTAssertEqual(vm.runningEffects[streamRoomOnB().id]?.cardID, running.cardID,
            "failing closed must not cost the user the look that was already playing")
        XCTAssertEqual(bridgeB.entertainmentActions.count, actionsBefore,
            "nothing was written at all")
        XCTAssertFalse(vm.statusMessage.isEmpty, "and it says so")
    }

    /// P7-42
    func testAnUnreadableBridgeAtPreflightPreservesAnAlreadyRunningEffect() async throws {
        stageStreamableBridge(bridgeB, active: [])
        let vm = makeP7VM()
        let party = try streamingCard(vm)
        await vm.apply(party, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)
        let running = try XCTUnwrap(vm.runningEffects[streamRoomOnB().id])

        bridgeB.entertainmentConfigsShouldFail = true
        await vm.apply(party, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)

        XCTAssertNil(vm.foreignTakeoverRequest)
        XCTAssertEqual(vm.runningEffects[streamRoomOnB().id]?.cardID, running.cardID,
            "unknown is not a reason to tear down what is playing")
        XCTAssertFalse(vm.statusMessage.isEmpty)
    }

    /// P7-35 — a foreign owner appearing between the first preflight and the
    /// final pre-teardown check. The decision must be taken while the previous
    /// look is still intact, and must NOT become a quiet room-mode fallback.
    func testAForeignOwnerAppearingAfterThePreflightDestroysNothingAndDoesNotFallBack() async throws {
        stageStreamableBridge(bridgeB, active: [])
        let vm = makeP7VM()
        let party = try streamingCard(vm)
        await vm.apply(party, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)
        let running = try XCTUnwrap(vm.runningEffects[streamRoomOnB().id])
        let startsBefore = bridgeB.entertainmentStarts.count

        // The first read of this attempt sees a clear bridge; a controller
        // claims it straight afterwards, before the start can tear anything
        // down. (Counts of grouped/per-light writes are deliberately NOT
        // asserted here: the already-running REST look keeps writing on its
        // own task, so any such count is a race rather than a fact.)
        bridgeB.onEntertainmentReadOnce { [weak bridgeB] in
            bridgeB?.stageEntertainmentConfigs(
                Self.configsJSON(areaID: "area-b", active: ["cfg-late"]))
        }
        await vm.apply(party, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)

        XCTAssertTrue(bridgeB.entertainmentStops.filter { $0 == "cfg-late" }.isEmpty,
            "the late arrival must not be stopped without consent")
        XCTAssertEqual(vm.runningEffects[streamRoomOnB().id]?.cardID, running.cardID,
            "and the previous look must survive — the conflict is decided before teardown")
        XCTAssertEqual(bridgeB.entertainmentStarts.count, startsBefore,
            "no session may be opened over the late arrival, and no REST fallback may stand in for one")
        XCTAssertNotNil(vm.foreignTakeoverRequest,
            "the conflict is surfaced as a question, not silently absorbed")
    }

    /// P7-43 — and cancelling that prompt is still zero mutation.
    func testCancelAfterALateConflictPromptIsZeroMutation() async throws {
        stageStreamableBridge(bridgeB, active: ["cfg-someone-else"])
        let vm = makeP7VM()
        let party = try streamingCard(vm)
        await vm.apply(party, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)
        XCTAssertNotNil(vm.foreignTakeoverRequest)
        let actionsBefore = bridgeB.entertainmentActions.count

        vm.cancelForeignTakeover()

        XCTAssertNil(vm.foreignTakeoverRequest)
        XCTAssertEqual(bridgeB.entertainmentActions.count, actionsBefore,
            "declining touches nothing")
        XCTAssertNil(vm.runningEffects[streamRoomOnB().id])
    }

    // ── The frozen start plan ─────────────────────────────────
    //
    // A configuration id alone is not a plan. Between the prompt and the answer
    // the area can be deleted, re-scoped to other lights, or lose the channels
    // the render loop needs — and replaying on the id alone would stop someone
    // else's show and then have nowhere to put ours.

    /// P7-44 — target area deleted while the prompt is open.
    func testATargetAreaRemovedWhileThePromptIsOpenStopsNothing() async throws {
        stageStreamableBridge(bridgeB, active: ["cfg-someone-else"])
        let vm = makeP7VM()
        let party = try streamingCard(vm)
        await vm.apply(party, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)
        XCTAssertNotNil(vm.foreignTakeoverRequest)

        // area-b is gone; only the stranger's session remains.
        bridgeB.stageEntertainmentConfigs(
            #"{"data":[{"id":"cfg-someone-else","metadata":{"name":"Other"},"status":"active","channels":[]}]}"#)
        await vm.confirmForeignTakeover()

        XCTAssertTrue(bridgeB.entertainmentStops.isEmpty,
            "stopping their show with nowhere to put ours is the worst possible trade")
        XCTAssertTrue(bridgeB.entertainmentStarts.isEmpty, "and nothing is started")
        XCTAssertNil(vm.runningEffects[streamRoomOnB().id])
        XCTAssertFalse(vm.statusMessage.isEmpty, "the refusal is stated")
    }

    /// P7-45 — the area survives but no longer serves this room's lights.
    func testATargetAreaThatNoLongerMatchesTheRoomStopsNothing() async throws {
        stageStreamableBridge(bridgeB, active: ["cfg-someone-else"])
        let vm = makeP7VM()
        let party = try streamingCard(vm)
        await vm.apply(party, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)
        XCTAssertNotNil(vm.foreignTakeoverRequest)

        // area-b now covers a completely different device, so it no longer
        // safely serves this room.
        bridgeB.stageLights([p7Light("L9", device: "D9")])
        bridgeB.stageEntertainmentServices(
            #"{"data":[{"id":"E9","owner":{"rid":"D9","rtype":"device"}}]}"#)
        bridgeB.stageEntertainmentConfigs(
            #"{"data":[{"id":"area-b","metadata":{"name":"Bedroom"},"status":"inactive","channels":[{"channel_id":0,"position":{"x":0,"y":0,"z":0},"members":[{"service":{"rid":"E9","rtype":"entertainment"}}]}]},"# +
            #"{"id":"cfg-someone-else","metadata":{"name":"Other"},"status":"active","channels":[]}]}"#)
        await vm.confirmForeignTakeover()

        XCTAssertTrue(bridgeB.entertainmentStops.isEmpty,
            "the captured area no longer describes this room's stream")
        XCTAssertNil(vm.runningEffects[streamRoomOnB().id])
    }

    /// P7-46 — the area still matches, but its channels are no longer usable.
    func testAnUnusableChannelPlanStopsNothing() async throws {
        stageStreamableBridge(bridgeB, active: ["cfg-someone-else"])
        let vm = makeP7VM()
        let party = try streamingCard(vm)
        await vm.apply(party, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)
        let captured = try XCTUnwrap(vm.foreignTakeoverRequest?.plan)
        XCTAssertEqual(captured.channelIDs, [0, 1], "two channels were validated at capture time")

        // area-b keeps one channel: same area, different stream.
        bridgeB.stageEntertainmentConfigs(
            #"{"data":[{"id":"area-b","metadata":{"name":"Bedroom"},"status":"inactive","channels":[{"channel_id":0,"position":{"x":0,"y":0,"z":0},"members":[{"service":{"rid":"E1","rtype":"entertainment"}}]}]},"# +
            #"{"id":"cfg-someone-else","metadata":{"name":"Other"},"status":"active","channels":[]}]}"#)
        await vm.confirmForeignTakeover()

        XCTAssertTrue(bridgeB.entertainmentStops.isEmpty,
            "the render loop would drive a channel map the user never consented to")
        XCTAssertNil(vm.runningEffects[streamRoomOnB().id])
    }

    /// P7-47 — the happy path uses the exact captured plan.
    func testASuccessfulConfirmationUsesTheExactCapturedPlan() async throws {
        stageStreamableBridge(bridgeB, active: ["cfg-someone-else"])
        let vm = makeP7VM()
        let party = try streamingCard(vm)
        await vm.apply(party, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)
        let captured = try XCTUnwrap(vm.foreignTakeoverRequest?.plan)

        // Stopping the foreign session deactivates it, as a real bridge would.
        bridgeB.stageDeactivationOnStop { _ in
            Self.configsJSON(areaID: "area-b", active: [])
        }
        await vm.confirmForeignTakeover()

        XCTAssertEqual(captured.targetConfigID, "area-b")
        XCTAssertEqual(captured.channelIDs, [0, 1])
        XCTAssertEqual(captured.roomID, streamRoomOnB().id)
        XCTAssertEqual(captured.bridgeID, "bridge-b")
        XCTAssertEqual(Set(bridgeB.entertainmentStarts), [captured.targetConfigID],
            "the replay streams the captured area and only that one")
        XCTAssertNotNil(vm.runningEffects[streamRoomOnB().id])
    }

    // ── The late-conflict transaction ─────────────────────────
    //
    // The gate below opens on the ACQUISITION read — the one that happens
    // after the ViewModel's preflight has fully completed. A "next
    // entertainment read" hook was not good enough: it can fire during
    // warmEntertainmentCaches inside the preflight itself, which tests an
    // earlier and easier moment than the one that actually matters.

    /// Arms a controller to appear on the read that follows a completed
    /// preflight, by counting reads rather than guessing at one.
    private func armForeignOwnerAfterPreflight(_ spy: RoutingSpyClient,
                                               skipping reads: Int,
                                               configID: String = "cfg-late") {
        let counter = ReadCounter(threshold: reads)
        spy.onEntertainmentReadEach { [weak spy] in
            guard counter.advancePastThreshold() else { return }
            spy?.stageEntertainmentConfigs(
                Self.configsJSON(areaID: "area-b", active: [configID]))
        }
    }

    /// P7-48 (app-driven Studio) — a controller claims the bridge after the
    /// preflight has completed and before the acquisition commits.
    func testALateForeignOwnerLeavesAppDrivenStudioBookkeepingUntouched() async throws {
        stageStreamableBridge(bridgeB, active: [])
        let vm = makeP7VM()
        let party = try streamingCard(vm)
        await vm.apply(party, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)
        let running = try XCTUnwrap(vm.runningEffects[streamRoomOnB().id])
        let startsBefore = bridgeB.entertainmentStarts.count
        let effectsBefore = vm.runningEffects.count

        // The preflight makes two configuration reads (its cache warm, then
        // its activity check). Arming after the second means the ACQUISITION
        // read — the one that follows a fully completed preflight — is the
        // first to see the stranger.
        armForeignOwnerAfterPreflight(bridgeB, skipping: 1)
        await vm.apply(party, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)

        XCTAssertNotNil(vm.foreignTakeoverRequest, "the prompt is raised, exactly once")
        XCTAssertEqual(vm.foreignTakeoverRequest?.foreignConfigID, "cfg-late")
        XCTAssertTrue(bridgeB.entertainmentStops.filter { $0 == "cfg-late" }.isEmpty,
            "the late arrival is not stopped without consent")
        XCTAssertEqual(bridgeB.entertainmentStarts.count, startsBefore,
            "no session opened, and no REST fallback stood in for one")
        XCTAssertEqual(vm.runningEffects.count, effectsBefore,
            "Now-Playing bookkeeping is untouched")
        XCTAssertEqual(vm.runningEffects[streamRoomOnB().id]?.cardID, running.cardID,
            "and the previous look is still the one running")

        // Declining still costs the user nothing.
        vm.cancelForeignTakeover()
        XCTAssertNil(vm.foreignTakeoverRequest)
        XCTAssertEqual(vm.runningEffects[streamRoomOnB().id]?.cardID, running.cardID,
            "cancel leaves the prior effect running")
    }

    /// P7-49 (composition) — the same, for the path that advances generations,
    /// opens telemetry, moves microphone demand, and rewrites spatial data.
    func testALateForeignOwnerLeavesCompositionBookkeepingUntouched() async throws {
        stageStreamableBridge(bridgeB, active: [])
        let vm = makeP7VM()
        let preset = makePreset(named: "Aurora Drift")
        vm.compositionStore.save(preset)
        addTeardownBlock { @MainActor in vm.compositionStore.delete(preset) }
        let card = vm.studioCard(for: preset)
        let room = streamRoomOnB()

        // Primed in ROOM mode on purpose (packet 7 follow-up, correction A).
        // An EXPLICIT "stream this" that cannot open a session no longer
        // demotes to REST — it refuses and says so — and every client key in
        // this suite is deliberately non-hex, so the DTLS open always fails
        // here. Asking for room mode is therefore the only way to have a
        // composition genuinely PLAYING before the late conflict arrives,
        // which is what this test needs to be able to destroy.
        await vm.apply(card, roomOverride: room, preferEntertainmentOverride: false)
        let running = try XCTUnwrap(vm.runningEffects[room.id],
            "the composition must actually be playing before the late conflict")
        let generationBefore = orchestrator.testCompositionGeneration(roomID: room.id)
        let transportBefore = orchestrator.testCompositionTransport(roomID: room.id)
        let ownerBefore = orchestrator.compositionOwningEntertainment(onBridge: "bridge-b")
        let telemetryBefore = orchestrator.testHasComposerTelemetrySession(
            roomID: room.id, bridgeID: "bridge-b")
        let startsBefore = bridgeB.entertainmentStarts.count

        armForeignOwnerAfterPreflight(bridgeB, skipping: 1)
        await vm.apply(card, roomOverride: room, preferEntertainmentOverride: true)

        XCTAssertNotNil(vm.foreignTakeoverRequest, "the prompt is raised, exactly once")
        XCTAssertTrue(bridgeB.entertainmentStops.filter { $0 == "cfg-late" }.isEmpty)
        XCTAssertEqual(bridgeB.entertainmentStarts.count, startsBefore,
            "no session opened and no REST fallback started")
        XCTAssertEqual(orchestrator.testCompositionGeneration(roomID: room.id), generationBefore,
            "the generation must not advance for a start that never happened")
        XCTAssertEqual(orchestrator.testCompositionTransport(roomID: room.id), transportBefore,
            "nor may the room's transport be rewritten")
        XCTAssertEqual(orchestrator.compositionOwningEntertainment(onBridge: "bridge-b"), ownerBefore,
            "nor Entertainment ownership")
        XCTAssertEqual(orchestrator.testHasComposerTelemetrySession(
            roomID: room.id, bridgeID: "bridge-b"), telemetryBefore,
            "nor may a telemetry session be opened")
        XCTAssertEqual(vm.runningEffects[room.id]?.cardID, running.cardID,
            "and the previous composition keeps playing")

        vm.cancelForeignTakeover()
        XCTAssertEqual(vm.runningEffects[room.id]?.cardID, running.cardID,
            "cancel leaves the prior effect running")
    }

    // ── The frozen plan reaches the render loop ───────────────

    /// P7-50 — positions moved, ids unchanged. Invisible to an id comparison,
    /// very visible on the wall.
    func testChangedChannelPositionsRefuseTheTakeover() async throws {
        stageStreamableBridge(bridgeB, active: ["cfg-someone-else"])
        let vm = makeP7VM()
        let party = try streamingCard(vm)
        await vm.apply(party, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)
        XCTAssertNotNil(vm.foreignTakeoverRequest)

        bridgeB.stageEntertainmentConfigs(
            #"{"data":[{"id":"area-b","metadata":{"name":"Bedroom"},"status":"inactive","channels":["# +
            #"{"channel_id":0,"position":{"x":0.9,"y":0.9,"z":0},"members":[{"service":{"rid":"E1","rtype":"entertainment"}}]},"# +
            #"{"channel_id":1,"position":{"x":0,"y":0,"z":0},"members":[{"service":{"rid":"E2","rtype":"entertainment"}}]}]},"# +
            #"{"id":"cfg-someone-else","metadata":{"name":"Other"},"status":"active","channels":[]}]}"#)
        await vm.confirmForeignTakeover()

        XCTAssertTrue(bridgeB.entertainmentStops.isEmpty,
            "the room would be lit in a different shape than the one consented to")
        XCTAssertNil(vm.runningEffects[streamRoomOnB().id])
    }

    /// P7-51 — members swapped, ids unchanged: the same area would drive
    /// different lights.
    func testChangedChannelMembersRefuseTheTakeover() async throws {
        stageStreamableBridge(bridgeB, active: ["cfg-someone-else"])
        let vm = makeP7VM()
        let party = try streamingCard(vm)
        await vm.apply(party, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)
        XCTAssertNotNil(vm.foreignTakeoverRequest)

        // E1/E2 both still resolve to this room's lights, so selection still
        // matches — but channel 0 now drives the other one.
        bridgeB.stageEntertainmentConfigs(
            #"{"data":[{"id":"area-b","metadata":{"name":"Bedroom"},"status":"inactive","channels":["# +
            #"{"channel_id":0,"position":{"x":0,"y":0,"z":0},"members":[{"service":{"rid":"E2","rtype":"entertainment"}}]},"# +
            #"{"channel_id":1,"position":{"x":0,"y":0,"z":0},"members":[{"service":{"rid":"E1","rtype":"entertainment"}}]}]},"# +
            #"{"id":"cfg-someone-else","metadata":{"name":"Other"},"status":"active","channels":[]}]}"#)
        await vm.confirmForeignTakeover()

        XCTAssertTrue(bridgeB.entertainmentStops.isEmpty,
            "same ids, different lights — the consented mapping no longer holds")
        XCTAssertNil(vm.runningEffects[streamRoomOnB().id])
    }

    /// P7-52 — after a successful stop, a cache refresh that reorders or
    /// re-points the configuration cannot change what the replay streams.
    func testARefreshAfterTheStopCannotRedirectTheReplay() async throws {
        stageStreamableBridge(bridgeB, active: ["cfg-someone-else"])
        let vm = makeP7VM()
        let party = try streamingCard(vm)
        await vm.apply(party, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)
        let captured = try XCTUnwrap(vm.foreignTakeoverRequest?.plan)

        // The stop clears the stranger AND introduces a rival area that a
        // fresh selection might prefer.
        bridgeB.stageDeactivationOnStop { _ in
            #"{"data":[{"id":"area-b","metadata":{"name":"Bedroom"},"status":"inactive","channels":["# +
            #"{"channel_id":0,"position":{"x":0,"y":0,"z":0},"members":[{"service":{"rid":"E1","rtype":"entertainment"}}]},"# +
            #"{"channel_id":1,"position":{"x":0,"y":0,"z":0},"members":[{"service":{"rid":"E2","rtype":"entertainment"}}]}]},"# +
            #"{"id":"area-rival","metadata":{"name":"Rival"},"status":"inactive","channels":["# +
            #"{"channel_id":0,"position":{"x":0,"y":0,"z":0},"members":[{"service":{"rid":"E1","rtype":"entertainment"}}]}]}]}"#
        }
        await vm.confirmForeignTakeover()

        XCTAssertEqual(Set(bridgeB.entertainmentStarts), [captured.targetConfigID],
            "the replay streams the captured area — a rival that appeared later cannot claim it")
        XCTAssertFalse(bridgeB.entertainmentStarts.contains("area-rival"))
        XCTAssertNotNil(vm.runningEffects[streamRoomOnB().id],
            "and the replay must not silently drop to room mode because selection moved")
    }

    /// P7-53 — the captured configuration, channel order, positions, and
    /// members are exactly what a takeover carries forward.
    func testTheCapturedPlanCarriesOrderPositionsAndMembers() async throws {
        stageStreamableBridge(bridgeB, active: ["cfg-someone-else"])
        let vm = makeP7VM()
        let party = try streamingCard(vm)
        await vm.apply(party, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)
        let plan = try XCTUnwrap(vm.foreignTakeoverRequest?.plan)

        XCTAssertEqual(plan.channelIDs, [0, 1], "ordered, not just present")
        XCTAssertEqual(plan.channels.map(\.id), [0, 1])
        XCTAssertEqual(plan.channels.map(\.members), [["E1"], ["E2"]],
            "which services each channel drives is part of the plan")
        XCTAssertEqual(plan.channels.map(\.x), [0, 0])
        XCTAssertEqual(plan.capturedConfig.id, "area-b")
        XCTAssertEqual(plan.capturedConfig.channels.map(\.id), [0, 1],
            "and the render loop is handed exactly that, rebuilt from the capture")
    }

    // ── A prepared candidate never survives an aborted start ──
    //
    // Preparing opens a REAL session: live on the bridge, process-owned, and
    // persisted. A refusal that happens after preparing therefore leaves a
    // session nothing points at — and because it looks owned, the app's own
    // cleanup skips it forever. Refusals must come first, and anything
    // prepared but not committed must be stopped.

    /// P7-54 — Strobe under Reduce Motion refuses before it prepares anything.
    func testAStrobeRefusedForReduceMotionPreparesAndDestroysNothing() async throws {
        stageStreamableBridge(bridgeB, active: [])
        let vm = makeP7VM()
        let room = streamRoomOnB()

        // Something is already playing, so a premature teardown would show.
        let party = try streamingCard(vm)
        await vm.apply(party, roomOverride: room, preferEntertainmentOverride: true)
        let running = try XCTUnwrap(vm.runningEffects[room.id])
        let nowPlayingBefore = orchestrator.activeEffectEntries
        let actionsBefore = bridgeB.entertainmentActions
        let clientBefore = orchestrator.testHasEntertainmentClient(forBridge: "bridge-b")

        vm.forcedReduceMotionForTesting = true
        let strobe = try XCTUnwrap(vm.liveModeCards.first { $0.id == "strobe" })
        await vm.apply(strobe, roomOverride: room, preferEntertainmentOverride: true)
        await orchestrator.testAwaitEntertainmentRollback()

        XCTAssertEqual(bridgeB.entertainmentActions.count, actionsBefore.count,
            "a refused card must send no action=start and no action=stop at all")
        XCTAssertFalse(orchestrator.testHasPendingEntertainmentCandidate(),
            "nothing may be left prepared and uncommitted")
        XCTAssertEqual(orchestrator.testHasEntertainmentClient(forBridge: "bridge-b"),
                       clientBefore,
            "and no prepared client may be installed")

        // Ownership: the refusal must not have created any.
        XCTAssertFalse(ownershipStore.isProcessOwned(bridgeID: "bridge-b", configID: "area-b"),
            "a refused start owns nothing")
        XCTAssertFalse(ownershipStore.isPersisted(bridgeID: "bridge-b", configID: "area-b"),
            "and records nothing — a persisted entry here would outlive the app")

        // The previous look is untouched.
        XCTAssertEqual(vm.runningEffects[room.id]?.cardID, running.cardID,
            "the running effect must survive a card that was never going to start")
        XCTAssertEqual(orchestrator.activeEffectEntries.count, nowPlayingBefore.count,
            "and Now Playing with it")
        XCTAssertTrue(vm.statusMessage.contains("Reduce Motion"),
            "the refusal is stated plainly")
    }

    /// P7-55 — an explicitly abandoned candidate is stopped and balances both
    /// ownership layers.
    ///
    /// The candidate is staged rather than produced by a real prepare: every
    /// client key in this suite is non-hex, so the DTLS open refuses before a
    /// socket exists and `.prepared` is unreachable here. What is under test
    /// is the rollback contract, and this is exactly the state a successful
    /// prepare leaves behind.
    func testAnAbandonedPreparedCandidateIsStoppedAndOwnsNothing() async throws {
        stageStreamableBridge(bridgeB, active: [])
        _ = makeP7VM()

        let client = HueEntertainmentClient(
            bridgeID: "bridge-b", bridgeIP: "192.0.2.2",
            username: "t", clientKeyHex: "ZZ-not-hex",
            restClient: bridgeB, ownership: ownershipStore)
        // Exactly what a real prepare installs: live session, both ownership
        // layers recorded.
        await client.seedSessionForTesting(configID: "area-b")
        XCTAssertTrue(ownershipStore.isProcessOwned(bridgeID: "bridge-b", configID: "area-b"))
        XCTAssertTrue(ownershipStore.isPersisted(bridgeID: "bridge-b", configID: "area-b"))

        let plan = EntertainmentTakeoverPlan(
            bridgeID: "bridge-b", roomID: streamRoomOnB().id,
            config: EntertainmentConfig(id: "area-b", name: "Bedroom", channels: []),
            channelIDs: [0, 1])
        let candidate = orchestrator.testStagePendingEntertainmentCandidate(
            client: client, plan: plan)
        XCTAssertTrue(orchestrator.testHasPendingEntertainmentCandidate(),
            "it is outstanding until committed or rolled back")

        // Abandon it without committing.
        orchestrator.rollbackUncommittedEntertainment(candidateID: candidate.id)
        await orchestrator.testAwaitEntertainmentRollback()

        XCTAssertEqual(bridgeB.entertainmentStops, ["area-b"],
            "an uncommitted candidate is stopped, not left live with nothing pointing at it")
        XCTAssertFalse(orchestrator.testHasPendingEntertainmentCandidate())
        XCTAssertFalse(orchestrator.testHasEntertainmentClient(forBridge: "bridge-b"),
            "and it was never installed")
        XCTAssertFalse(ownershipStore.isProcessOwned(bridgeID: "bridge-b", configID: "area-b"),
            "process ownership is balanced")
        XCTAssertFalse(ownershipStore.isPersisted(bridgeID: "bridge-b", configID: "area-b"),
            "and the confirmed stop retires the persisted record")
    }

    /// P7-56 — a committed candidate is never stopped by the rollback net.
    func testACommittedCandidateIsNotStoppedByRollback() async throws {
        stageStreamableBridge(bridgeB, active: [])
        let vm = makeP7VM()
        let room = streamRoomOnB()
        let party = try streamingCard(vm)

        await vm.apply(party, roomOverride: room, preferEntertainmentOverride: true)
        await orchestrator.testAwaitEntertainmentRollback()

        XCTAssertFalse(orchestrator.testHasPendingEntertainmentCandidate(),
            "committing clears the outstanding candidate")
        // The DTLS open fails on the non-hex key, so this look legitimately
        // falls back to room mode — what matters is that the rollback net did
        // not fire a SECOND stop at whatever the start left behind.
        XCTAssertLessThanOrEqual(bridgeB.entertainmentStops.count, 1,
            "the rollback must not stop anything a successful commit owns")
        XCTAssertNotNil(vm.runningEffects[room.id])
    }

    // ── Two transactions in flight at once ────────────────────
    //
    // `apply` and both start paths are @MainActor async, and every one of them
    // suspends on a bridge read. That makes them REENTRANT: a second tap runs
    // its prepare while the first is still parked. With one "currently
    // pending" slot the second candidate overwrote the first, and then the
    // first transaction's commit cleared the second's entry — leaving a live
    // session with nothing tracking it, which the app's own cleanup then
    // skipped forever because it looked owned.
    //
    // The interleaving here is expressed by call ORDER, which is exact: the
    // staging seam is synchronous, so there is no timing involved at all.
    // (`.prepared` is unreachable through a real prepare in this suite —
    // every client key is non-hex, so the DTLS open refuses before a socket
    // exists — and this stages precisely the registry state a real prepare
    // leaves behind.)

    /// A candidate wired to `bridge`, seeded so both ownership layers are
    /// recorded exactly as a real prepare would leave them.
    private func stageCandidate(on spy: RoutingSpyClient,
                                bridgeID: String,
                                configID: String,
                                roomID: String) async -> UnifiedOrchestrator.PreparedEntertainment {
        let client = HueEntertainmentClient(
            bridgeID: bridgeID, bridgeIP: "192.0.2.9",
            username: "t", clientKeyHex: "ZZ-not-hex",
            restClient: spy, ownership: ownershipStore)
        await client.seedSessionForTesting(configID: configID)
        let plan = EntertainmentTakeoverPlan(
            bridgeID: bridgeID, roomID: roomID,
            config: EntertainmentConfig(id: configID, name: "Area", channels: []),
            channelIDs: [0])
        return orchestrator.testStagePendingEntertainmentCandidate(client: client, plan: plan)
    }

    /// P7-57 — commit A while B is still outstanding.
    func testCommittingOneTransactionLeavesAnotherCandidateOutstanding() async throws {
        _ = makeP7VM()

        // Transaction A prepares, then suspends before committing.
        let a = await stageCandidate(on: bridgeA, bridgeID: "bridge-a",
                                     configID: "area-a", roomID: "room-a")
        // Transaction B prepares while A is parked.
        let b = await stageCandidate(on: bridgeB, bridgeID: "bridge-b",
                                     configID: "area-b", roomID: "room-b")
        XCTAssertEqual(orchestrator.testOutstandingCandidateIDs(), [a.id, b.id],
            "both transactions are in flight")

        // A resumes and commits.
        orchestrator.commitEntertainment(a)

        XCTAssertEqual(orchestrator.testOutstandingCandidateIDs(), [b.id],
            "committing A must remove ONLY A — B is another transaction's candidate")
        XCTAssertTrue(bridgeB.entertainmentStops.isEmpty,
            "and must not stop it either")
        XCTAssertTrue(orchestrator.testHasEntertainmentClient(forBridge: "bridge-a"),
            "A is installed")
        XCTAssertFalse(orchestrator.testHasEntertainmentClient(forBridge: "bridge-b"),
            "B is not — it was never committed")

        // B is abandoned.
        orchestrator.rollbackUncommittedEntertainment(candidateID: b.id)
        await orchestrator.testAwaitEntertainmentRollback()

        XCTAssertEqual(bridgeB.entertainmentStops, ["area-b"],
            "B stops exactly once")
        XCTAssertTrue(bridgeA.entertainmentStops.isEmpty,
            "and A, which committed, is never stopped")
        XCTAssertTrue(orchestrator.testOutstandingCandidateIDs().isEmpty)

        // Ownership balances per candidate, independently.
        XCTAssertTrue(ownershipStore.isProcessOwned(bridgeID: "bridge-a", configID: "area-a"),
            "A is still streaming, so it still owns its session")
        XCTAssertTrue(ownershipStore.isPersisted(bridgeID: "bridge-a", configID: "area-a"))
        XCTAssertFalse(ownershipStore.isProcessOwned(bridgeID: "bridge-b", configID: "area-b"),
            "B released both layers on rollback")
        XCTAssertFalse(ownershipStore.isPersisted(bridgeID: "bridge-b", configID: "area-b"))
    }

    /// P7-58 — the inverse ordering: roll back A, then commit B.
    func testRollingBackOneTransactionLeavesAnotherFreeToCommit() async throws {
        _ = makeP7VM()

        let a = await stageCandidate(on: bridgeA, bridgeID: "bridge-a",
                                     configID: "area-a", roomID: "room-a")
        let b = await stageCandidate(on: bridgeB, bridgeID: "bridge-b",
                                     configID: "area-b", roomID: "room-b")

        orchestrator.rollbackUncommittedEntertainment(candidateID: a.id)
        await orchestrator.testAwaitEntertainmentRollback()

        XCTAssertEqual(orchestrator.testOutstandingCandidateIDs(), [b.id],
            "rolling back A must not claim B")
        XCTAssertEqual(bridgeA.entertainmentStops, ["area-a"], "A alone stops")
        XCTAssertTrue(bridgeB.entertainmentStops.isEmpty)

        orchestrator.commitEntertainment(b)

        XCTAssertTrue(orchestrator.testOutstandingCandidateIDs().isEmpty)
        XCTAssertTrue(orchestrator.testHasEntertainmentClient(forBridge: "bridge-b"),
            "B alone installs")
        XCTAssertFalse(orchestrator.testHasEntertainmentClient(forBridge: "bridge-a"),
            "A was rolled back, so it is not installed")
        XCTAssertEqual(bridgeB.entertainmentStops, [],
            "and committing never stops the thing it installs")

        XCTAssertFalse(ownershipStore.isProcessOwned(bridgeID: "bridge-a", configID: "area-a"))
        XCTAssertFalse(ownershipStore.isPersisted(bridgeID: "bridge-a", configID: "area-a"))
        XCTAssertTrue(ownershipStore.isProcessOwned(bridgeID: "bridge-b", configID: "area-b"))
        XCTAssertTrue(ownershipStore.isPersisted(bridgeID: "bridge-b", configID: "area-b"))
    }

    /// P7-59 — rollback is exactly-once and inert against a committed or
    /// already-rolled-back candidate.
    func testRollbackIsExactlyOnceAndInertAfterCommit() async throws {
        _ = makeP7VM()

        let a = await stageCandidate(on: bridgeA, bridgeID: "bridge-a",
                                     configID: "area-a", roomID: "room-a")
        orchestrator.rollbackUncommittedEntertainment(candidateID: a.id)
        orchestrator.rollbackUncommittedEntertainment(candidateID: a.id)
        orchestrator.rollbackUncommittedEntertainment(candidateID: a.id)
        await orchestrator.testAwaitEntertainmentRollback()

        XCTAssertEqual(bridgeA.entertainmentStops, ["area-a"],
            "claiming by removal means a repeated rollback finds nothing to do")

        let b = await stageCandidate(on: bridgeB, bridgeID: "bridge-b",
                                     configID: "area-b", roomID: "room-b")
        orchestrator.commitEntertainment(b)
        orchestrator.rollbackUncommittedEntertainment(candidateID: b.id)
        await orchestrator.testAwaitEntertainmentRollback()

        XCTAssertTrue(bridgeB.entertainmentStops.isEmpty,
            "a rollback arriving after commit must never stop the installed session")
        XCTAssertTrue(orchestrator.testHasEntertainmentClient(forBridge: "bridge-b"))
    }

    // ──────────────────────────────────────────────
    // MARK: - Composer 2 packet 8: bridge-stored animations survive a relaunch
    // ──────────────────────────────────────────────
    //
    // A bridge-stored look runs on the bridge's own firmware, so it keeps
    // running after a force-quit. Nothing used to read the persisted manifests
    // back at launch, so the animation cycled on while the app showed nothing
    // running and offered no way to stop it.
    //
    // Every test here is about ORDER, PRESENCE and RESOURCE IDENTITY, never
    // elapsed time: no sleeps, no waiters, no timeouts. `RestGate`
    // continuations do all the sequencing. (Guards 8 and 10 enforce this.)

    /// Stage a bridge's inventory so a manifest reads back as LIVE.
    private func stageLive(_ spy: RoutingSpyV1Client, _ manifests: [BridgeAnimationManifest]) {
        var schedules: [String: [String: Any]] = [:]
        var rules: [String: [String: Any]] = [:]
        var sensors: [String: [String: Any]] = [:]
        var links: [String: [String: Any]] = [:]
        for m in manifests {
            schedules[m.scheduleID] = ["status": "enabled"]
            for r in m.ruleIDs { rules[r] = [:] }
            sensors[m.sensorID] = [:]
            if let rl = m.resourcelinkID { links[rl] = [:] }
        }
        spy.stageInventory("fetchSchedules", schedules)
        spy.stageInventory("fetchRules", rules)
        spy.stageInventory("fetchSensors", sensors)
        spy.stageInventory("fetchResourcelinks", links)
    }

    private func recoveredEntries() -> [ActiveEffectEntry] {
        orchestrator.activeEffectEntries.filter { $0.recovered != nil }
    }

    private func recoveredKey(_ m: BridgeAnimationManifest, _ bridgeID: String)
        -> UnifiedOrchestrator.RecoveredBridgeAnimationKey {
        .init(bridgeID: bridgeID, manifestID: m.id)
    }

    // ── 1-4: restore, read-only, idempotence, ordering ──────────────────

    func testP8AVerifiedLiveManifestRestoresTransportNowPlayingAndStudio() async {
        orchestrator.allRooms = [allDayRoom("room-1", bridge: "bridge-a")]
        let m = stageManifest(roomID: "room-1", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                              presetName: "Sunset Drift",
                              sensorID: "S1", ruleIDs: ["R1"], scheduleID: "SC1", resourcelinkID: "L1")
        stageLive(bridgeA.v1Spy, [m])
        let vm = makeStudioVM()

        await orchestrator.testReconcileBridgeStoredAnimations()

        XCTAssertEqual(orchestrator.testCompositionTransport(roomID: "room-1"), .bridgeStored)
        XCTAssertEqual(recoveredEntries().count, 1)
        let entry = recoveredEntries()[0]
        XCTAssertEqual(entry.effectName, "Sunset Drift")
        XCTAssertEqual(entry.roomID, "room-1")
        XCTAssertFalse(entry.isAppDriven, "no app task exists behind a bridge-stored animation")
        XCTAssertEqual(orchestrator.testRecoveredBridgeAnimations()[recoveredKey(m, "bridge-a")]?.bridgeID,
                       "bridge-a")
        XCTAssertEqual(vm.runningEffects["room-1"]?.recovered, recoveredKey(m, "bridge-a"))
        XCTAssertTrue(storeStillHolds(m))
    }

    func testP8ReconcilingAVerifiedAnimationSendsZeroMutatingRequests() async {
        orchestrator.allRooms = [allDayRoom("room-1", bridge: "bridge-a")]
        let m = stageManifest(roomID: "room-1", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                              sensorID: "S1", ruleIDs: ["R1"], scheduleID: "SC1", resourcelinkID: "L1")
        stageLive(bridgeA.v1Spy, [m])

        await orchestrator.testReconcileBridgeStoredAnimations()

        XCTAssertTrue(bridgeA.v1Spy.deletedResources.isEmpty, "a live animation is never mutated")
        XCTAssertTrue(bridgeA.v1Spy.creations.isEmpty)
        XCTAssertTrue(bridgeA.groupedEffectIDs.isEmpty)
        XCTAssertTrue(bridgeA.groupedPowerIDs.isEmpty)
        XCTAssertTrue(bridgeA.v1EffectPuts.isEmpty)
        XCTAssertTrue(bridgeA.entertainmentActions.isEmpty)
        XCTAssertTrue(bridgeB.v1Spy.deletedResources.isEmpty)
    }

    func testP8RepeatedReconciliationIsIdempotent() async {
        orchestrator.allRooms = [allDayRoom("room-1", bridge: "bridge-a")]
        let m = stageManifest(roomID: "room-1", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                              sensorID: "S1", ruleIDs: ["R1"], scheduleID: "SC1", resourcelinkID: "L1")
        stageLive(bridgeA.v1Spy, [m])

        await orchestrator.testReconcileBridgeStoredAnimations()
        let first = orchestrator.testRecoveredBridgeAnimations()
        await orchestrator.testReconcileBridgeStoredAnimations()
        await orchestrator.testReconcileBridgeStoredAnimations()

        XCTAssertEqual(orchestrator.testRecoveredBridgeAnimations(), first)
        XCTAssertEqual(recoveredEntries().count, 1, "no duplicate Now Playing row")
        XCTAssertEqual(Set(orchestrator.activeEffectEntries.map(\.id)).count,
                       orchestrator.activeEffectEntries.count)
        XCTAssertTrue(storeStillHolds(m))
        XCTAssertTrue(bridgeA.v1Spy.deletedResources.isEmpty, "no repeated cleanup")
        // ONE batched read per bridge per pass — four categories, three passes.
        XCTAssertEqual(bridgeA.v1Spy.fetchCalls.count, 12,
                       "reads are batched per bridge, never issued per manifest")
    }

    func testP8StudioConfiguredBeforeAndAfterReconciliationSeeTheSameState() async {
        orchestrator.allRooms = [allDayRoom("room-1", bridge: "bridge-a")]
        let m = stageManifest(roomID: "room-1", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                              sensorID: "S1", ruleIDs: ["R1"], scheduleID: "SC1", resourcelinkID: "L1")
        stageLive(bridgeA.v1Spy, [m])

        let early = StudioViewModel()          // configure BEFORE load
        early.configure(orchestrator: orchestrator)
        await orchestrator.testReconcileBridgeStoredAnimations()
        let late = StudioViewModel()           // configure AFTER load
        late.configure(orchestrator: orchestrator)

        let key = recoveredKey(m, "bridge-a")
        XCTAssertEqual(early.runningEffects["room-1"]?.recovered, key,
                       "the push path restores a view model that was already alive")
        XCTAssertEqual(late.runningEffects["room-1"]?.recovered, key,
                       "the pull path restores a view model created afterwards")
        XCTAssertEqual(early.runningEffects.mapValues(\.cardID), late.runningEffects.mapValues(\.cardID))
        XCTAssertEqual(early.runningEffects["room-1"]?.room.bridgeID, "bridge-a")
        XCTAssertEqual(recoveredEntries().count, 1, "a second configure must not double-publish")

        // StudioView.onAppear re-runs configure on every appearance.
        late.configure(orchestrator: orchestrator)
        late.configure(orchestrator: orchestrator)
        XCTAssertEqual(recoveredEntries().count, 1)
        XCTAssertEqual(late.runningEffects.count, 1)
    }

    /// A recovered row must not imply an in-memory render loop.
    func testP8ReconciliationCreatesNoRuntimeState() async {
        orchestrator.allRooms = [allDayRoom("room-1", bridge: "bridge-a")]
        let m = stageManifest(roomID: "room-1", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                              sensorID: "S1", ruleIDs: ["R1"], scheduleID: "SC1", resourcelinkID: "L1")
        stageLive(bridgeA.v1Spy, [m])
        let vm = makeStudioVM()

        await orchestrator.testReconcileBridgeStoredAnimations()

        XCTAssertTrue(orchestrator.testAllDayRestSenderBridgeKeys().isEmpty)
        XCTAssertFalse(orchestrator.testHasComposerTelemetrySession(roomID: "room-1", bridgeID: "bridge-a"))
        XCTAssertNil(orchestrator.studioEntClients["bridge-a"])
        let effect = vm.runningEffects["room-1"]
        XCTAssertEqual(effect?.card.params.count, 0, "no sliders: there is nothing to drive")
        XCTAssertNil(effect?.card.compositionLayerActivity, "no layer chips")
        XCTAssertEqual(effect?.card.requiresForeground, false, "no keep-app-open chrome")
        XCTAssertEqual(effect?.isEntertainment, false)
        XCTAssertTrue(effect?.lightIDs.isEmpty ?? false)
        XCTAssertNotEqual(effect?.cardID, "comp_\(m.presetID.uuidString)",
                          "the preset's own grid card must not read as running")
    }

    // ── 5-8: stop semantics ─────────────────────────────────────────────

    func testP8DashboardStopRemovesExactResourcesAndClearsStateOnlyAfterSuccess() async {
        orchestrator.allRooms = [allDayRoom("room-1", bridge: "bridge-a")]
        let m = stageManifest(roomID: "room-1", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                              sensorID: "S1", ruleIDs: ["R1"], scheduleID: "SC1", resourcelinkID: "L1")
        stageLive(bridgeA.v1Spy, [m])
        let vm = makeStudioVM()
        await orchestrator.testReconcileBridgeStoredAnimations()

        await orchestrator.requestNowPlayingStop(recoveredEntries()[0])

        XCTAssertEqual(Set(bridgeA.v1Spy.succeededDeletes), expectedDeletes(for: m))
        XCTAssertTrue(bridgeB.v1Spy.deletedResources.isEmpty)
        XCTAssertFalse(storeStillHolds(m))
        XCTAssertNil(orchestrator.testRecoveredBridgeAnimations()[recoveredKey(m, "bridge-a")])
        XCTAssertNil(orchestrator.testCompositionTransport(roomID: "room-1"))
        XCTAssertTrue(recoveredEntries().isEmpty)
        XCTAssertNil(vm.runningEffects["room-1"])
        // Mirrors a live .composition stop: the resolved room goes off.
        XCTAssertEqual(bridgeA.groupedPowerIDs, ["gl-room-1:false"])
    }

    func testP8StudioStopRemovesExactResourcesAndClearsTheSameState() async {
        orchestrator.allRooms = [allDayRoom("room-1", bridge: "bridge-a")]
        let m = stageManifest(roomID: "room-1", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                              sensorID: "S1", ruleIDs: ["R1"], scheduleID: "SC1", resourcelinkID: "L1")
        stageLive(bridgeA.v1Spy, [m])
        let vm = makeStudioVM()
        await orchestrator.testReconcileBridgeStoredAnimations()

        await vm.stopFromNowPlaying(roomID: "room-1")

        XCTAssertEqual(Set(bridgeA.v1Spy.succeededDeletes), expectedDeletes(for: m),
                       "both surfaces converge on one exact teardown")
        XCTAssertFalse(storeStillHolds(m))
        XCTAssertTrue(recoveredEntries().isEmpty)
        XCTAssertNil(vm.runningEffects["room-1"])
        XCTAssertNil(orchestrator.testCompositionTransport(roomID: "room-1"))
    }

    func testP8StopAllStopsEveryRestoredAnimationWithNoCrossBridgeBleed() async {
        orchestrator.allRooms = [
            allDayRoom("room-1", bridge: "bridge-a"),
            allDayRoom("room-2", bridge: "bridge-a"),
            allDayRoom("room-3", bridge: "bridge-b"),
        ]
        let m1 = stageManifest(roomID: "room-1", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                               sensorID: "S1", ruleIDs: ["R1"], scheduleID: "SC1")
        let m2 = stageManifest(roomID: "room-2", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                               sensorID: "S2", ruleIDs: ["R2"], scheduleID: "SC2")
        let m3 = stageManifest(roomID: "room-3", bridgeIP: "192.0.2.2", bridgeID: "bridge-b",
                               sensorID: "S3", ruleIDs: ["R3"], scheduleID: "SC3")
        stageLive(bridgeA.v1Spy, [m1, m2])
        stageLive(bridgeB.v1Spy, [m3])
        let vm = makeStudioVM()
        await orchestrator.testReconcileBridgeStoredAnimations()
        XCTAssertEqual(recoveredEntries().count, 3)

        for entry in orchestrator.activeEffectEntries {
            await orchestrator.requestNowPlayingStop(entry)
        }

        let onA = Set(bridgeA.v1Spy.succeededDeletes)
        let onB = Set(bridgeB.v1Spy.succeededDeletes)
        XCTAssertEqual(onA, expectedDeletes(for: m1).union(expectedDeletes(for: m2)))
        XCTAssertEqual(onB, expectedDeletes(for: m3))
        XCTAssertTrue(onA.isDisjoint(with: onB))
        XCTAssertFalse(storeStillHolds(m1))
        XCTAssertFalse(storeStillHolds(m2))
        XCTAssertFalse(storeStillHolds(m3))
        XCTAssertTrue(recoveredEntries().isEmpty)
        XCTAssertTrue(vm.runningEffects.isEmpty)
    }

    func testP8AFailedStopRetainsTheManifestOwnershipAndTheVisibleEntry() async {
        orchestrator.allRooms = [allDayRoom("room-1", bridge: "bridge-a")]
        let m = stageManifest(roomID: "room-1", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                              sensorID: "S1", ruleIDs: ["R1"], scheduleID: "SC1")
        stageLive(bridgeA.v1Spy, [m])
        await orchestrator.testReconcileBridgeStoredAnimations()
        bridgeA.v1Spy.stageDeleteFailures(["rule:R1"])

        await orchestrator.requestNowPlayingStop(recoveredEntries()[0])

        XCTAssertTrue(Set(bridgeA.v1Spy.deletedResources).isSuperset(of: expectedDeletes(for: m)),
                      "every step is attempted; teardown does not abort at the first failure")
        XCTAssertFalse(bridgeA.v1Spy.succeededDeletes.contains("rule:R1"))
        XCTAssertTrue(storeStillHolds(m), "evidence is retained for retry")
        XCTAssertNotNil(orchestrator.testRecoveredBridgeAnimations()[recoveredKey(m, "bridge-a")])
        XCTAssertEqual(recoveredEntries().count, 1,
                       "a stop that did not happen must not look like one that did")
        XCTAssertEqual(orchestrator.testCompositionTransport(roomID: "room-1"), .bridgeStored)
        XCTAssertNotNil(orchestrator.toastMessage)
        XCTAssertTrue(bridgeA.groupedPowerIDs.isEmpty, "a failed stop never powers the room off")
        XCTAssertFalse(orchestrator.testIsAllDayWriteAllowed(bridgeID: "bridge-a", roomID: "room-1"),
                       "ownership that suppresses All-Day must survive a failed stop")
    }

    /// The manifest's bridge is not registered right now. That is the normal
    /// transient state at launch, and it is not evidence about anything.
    func testP8AStopWithNoRegisteredBridgeRetainsEverything() async {
        orchestrator.allRooms = [allDayRoom("room-1", bridge: "bridge-a")]
        let m = stageManifest(roomID: "room-1", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                              sensorID: "S1", ruleIDs: ["R1"], scheduleID: "SC1")
        stageLive(bridgeA.v1Spy, [m])
        await orchestrator.testReconcileBridgeStoredAnimations()
        orchestrator.injectForTesting(clients: ["bridge-b": bridgeB])

        let stopped = await orchestrator.stopRecoveredBridgeAnimation(recoveredKey(m, "bridge-a"))

        XCTAssertFalse(stopped)
        XCTAssertTrue(storeStillHolds(m))
        XCTAssertEqual(recoveredEntries().count, 1)
        XCTAssertTrue(bridgeB.v1Spy.deletedResources.isEmpty)
        XCTAssertNotNil(orchestrator.toastMessage)
    }

    // ── 9-11: read failure, pruning, partial presence ───────────────────

    /// The headline pair. Same manifest, same code path — the ONLY difference
    /// is whether the bridge answered, and that difference decides everything.
    func testP8AnUnreadableInventoryRetainsWhileAnEmptyOneProves() async {
        orchestrator.allRooms = [allDayRoom("room-1", bridge: "bridge-a")]
        let m = stageManifest(roomID: "room-1", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                              sensorID: "S1", ruleIDs: ["R1"], scheduleID: "SC1")
        bridgeA.v1Spy.stageInventoryFailure(["fetchRules"])

        await orchestrator.testReconcileBridgeStoredAnimations()

        XCTAssertTrue(storeStillHolds(m), "a read failure is UNKNOWN, never absence")
        XCTAssertTrue(bridgeA.v1Spy.deletedResources.isEmpty, "zero destructive writes")
        XCTAssertTrue(recoveredEntries().isEmpty, "and no claim that it is running either")

        // Now let the bridge actually answer, reporting nothing.
        bridgeA.v1Spy.stageInventoryFailure([])
        await orchestrator.testReconcileBridgeStoredAnimations()
        XCTAssertFalse(storeStillHolds(m), "a successful empty read DOES prove absence")
        XCTAssertTrue(bridgeA.v1Spy.deletedResources.isEmpty,
                      "nothing remained, so nothing needed deleting")
    }

    /// v1 answers a refusal with HTTP 200 and an error envelope. Before packet
    /// 8 that decoded to `[:]` and read as "this bridge has nothing".
    func testP8AnErrorEnvelopeIsNotAnEmptyInventory() async {
        let m = stageManifest(roomID: "room-1", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                              sensorID: "S1", ruleIDs: ["R1"], scheduleID: "SC1")
        bridgeA.v1Spy.stageInventoryErrorEnvelope(
            "fetchRules", #"[{"error":{"type":1,"address":"/rules","description":"unauthorized user"}}]"#)

        await orchestrator.testReconcileBridgeStoredAnimations()

        XCTAssertTrue(storeStillHolds(m))
        XCTAssertTrue(bridgeA.v1Spy.deletedResources.isEmpty)
    }

    func testP8AStaleManifestIsPrunedWithoutTouchingUnrelatedResources() async {
        orchestrator.allRooms = [
            allDayRoom("room-1", bridge: "bridge-a"), allDayRoom("room-2", bridge: "bridge-a"),
        ]
        let stale = stageManifest(roomID: "room-1", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                                  sensorID: "S1", ruleIDs: ["R1"], scheduleID: "SC1")
        let live = stageManifest(roomID: "room-2", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                                 sensorID: "S2", ruleIDs: ["R2"], scheduleID: "SC2")
        // Only the live manifest's ids, plus foreign CG_-named resources.
        bridgeA.v1Spy.stageInventory("fetchSchedules", ["SC2": ["status": "enabled"],
                                                        "SC9": ["status": "enabled", "name": "CG_other"]])
        bridgeA.v1Spy.stageInventory("fetchRules", ["R2": [:], "R9": ["name": "CG_other"]])
        bridgeA.v1Spy.stageInventory("fetchSensors", ["S2": [:], "S9": ["name": "CG_other"]])

        await orchestrator.testReconcileBridgeStoredAnimations()

        XCTAssertFalse(storeStillHolds(stale))
        XCTAssertTrue(storeStillHolds(live))
        let deleted = Set(bridgeA.v1Spy.deletedResources)
        XCTAssertTrue(deleted.isDisjoint(with: ["schedule:SC9", "rule:R9", "sensor:S9"]),
                      "a CG_ name is not an ownership claim")
        XCTAssertTrue(deleted.isDisjoint(with: expectedDeletes(for: live)))
        XCTAssertEqual(recoveredEntries().map(\.roomID), ["room-2"])
    }

    func testP8APartiallyPresentManifestCleansOnlyItsOwnListedResources() async {
        let m = stageManifest(roomID: "room-1", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                              sensorID: "S1", ruleIDs: ["R1", "R2"], scheduleID: "SC1")
        // Structurally incomplete: R2 is gone, so the chain cannot run.
        bridgeA.v1Spy.stageInventory("fetchSchedules", ["SC1": ["status": "enabled"]])
        bridgeA.v1Spy.stageInventory("fetchRules", ["R1": [:], "R9": ["name": "CG_other"]])
        bridgeA.v1Spy.stageInventory("fetchSensors", ["S1": [:]])

        await orchestrator.testReconcileBridgeStoredAnimations()

        let deleted = Set(bridgeA.v1Spy.deletedResources)
        XCTAssertEqual(deleted, ["schedule:SC1", "rule:R1", "sensor:S1"],
                       "only this manifest's still-present ids — never R2, never R9")
        XCTAssertFalse(storeStillHolds(m))
        XCTAssertTrue(recoveredEntries().isEmpty)
    }

    func testP8APartialCleanupFailureRetainsTheEvidence() async {
        let m = stageManifest(roomID: "room-1", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                              sensorID: "S1", ruleIDs: ["R1", "R2"], scheduleID: "SC1")
        bridgeA.v1Spy.stageInventory("fetchSchedules", ["SC1": ["status": "enabled"]])
        bridgeA.v1Spy.stageInventory("fetchRules", ["R1": [:]])
        bridgeA.v1Spy.stageInventory("fetchSensors", ["S1": [:]])
        bridgeA.v1Spy.stageDeleteFailures(["sensor:S1"])

        await orchestrator.testReconcileBridgeStoredAnimations()

        XCTAssertTrue(storeStillHolds(m), "a partial cleanup keeps the record for a later retry")
        XCTAssertTrue(recoveredEntries().isEmpty)
    }

    // ── 12-15: independence and identity ────────────────────────────────

    func testP8TwoRoomsOnOneBridgeRestoreIndependently() async {
        orchestrator.allRooms = [
            allDayRoom("room-1", bridge: "bridge-a"), allDayRoom("room-2", bridge: "bridge-a"),
        ]
        let m1 = stageManifest(roomID: "room-1", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                               sensorID: "S1", ruleIDs: ["R1"], scheduleID: "SC1")
        let m2 = stageManifest(roomID: "room-2", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                               sensorID: "S2", ruleIDs: ["R2"], scheduleID: "SC2")
        stageLive(bridgeA.v1Spy, [m1, m2])
        await orchestrator.testReconcileBridgeStoredAnimations()
        XCTAssertEqual(Set(recoveredEntries().map(\.roomID)), ["room-1", "room-2"])

        await orchestrator.stopRecoveredBridgeAnimation(recoveredKey(m1, "bridge-a"))

        XCTAssertEqual(Set(bridgeA.v1Spy.succeededDeletes), expectedDeletes(for: m1))
        XCTAssertTrue(Set(bridgeA.v1Spy.succeededDeletes).isDisjoint(with: expectedDeletes(for: m2)))
        XCTAssertTrue(storeStillHolds(m2))
        XCTAssertEqual(recoveredEntries().map(\.roomID), ["room-2"])
        XCTAssertEqual(orchestrator.testCompositionTransport(roomID: "room-2"), .bridgeStored)
    }

    func testP8OneBridgesReadFailureNeitherBlocksNorMutatesTheOther() async {
        orchestrator.allRooms = [
            allDayRoom("room-1", bridge: "bridge-a"), allDayRoom("room-2", bridge: "bridge-b"),
        ]
        let onA = stageManifest(roomID: "room-1", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                                sensorID: "S1", ruleIDs: ["R1"], scheduleID: "SC1")
        let onB = stageManifest(roomID: "room-2", bridgeIP: "192.0.2.2", bridgeID: "bridge-b",
                                sensorID: "S2", ruleIDs: ["R2"], scheduleID: "SC2")
        bridgeA.v1Spy.stageInventoryFailure(["fetchSensors"])
        stageLive(bridgeB.v1Spy, [onB])

        await orchestrator.testReconcileBridgeStoredAnimations()

        XCTAssertTrue(storeStillHolds(onA))
        XCTAssertTrue(bridgeA.v1Spy.deletedResources.isEmpty)
        XCTAssertNotNil(orchestrator.testRecoveredBridgeAnimations()[recoveredKey(onB, "bridge-b")],
                        "bridge B completes despite bridge A failing")

        await orchestrator.stopRecoveredBridgeAnimation(recoveredKey(onB, "bridge-b"))
        XCTAssertEqual(Set(bridgeB.v1Spy.succeededDeletes), expectedDeletes(for: onB))
        XCTAssertTrue(bridgeA.v1Spy.deletedResources.isEmpty)
        XCTAssertTrue(storeStillHolds(onA))
    }

    /// The test the old `presetID_roomID` store key made impossible to write:
    /// saving the second manifest silently destroyed the first.
    func testP8SamePresetAndRoomOnTwoBridgesDoNotCollide() async {
        orchestrator.allRooms = [
            allDayRoom("shared-room", bridge: "bridge-a"),
            allDayRoom("shared-room", bridge: "bridge-b"),
        ]
        let sharedPreset = UUID()
        let onA = stageManifest(roomID: "shared-room", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                                presetID: sharedPreset, sensorID: "S1", ruleIDs: ["R1"], scheduleID: "SC1")
        let onB = stageManifest(roomID: "shared-room", bridgeIP: "192.0.2.2", bridgeID: "bridge-b",
                                presetID: sharedPreset, sensorID: "S2", ruleIDs: ["R2"], scheduleID: "SC2")
        XCTAssertEqual(animationStore.allManifests()
            .filter { $0.presetID == sharedPreset && $0.roomID == "shared-room" }.count, 2)
        stageLive(bridgeA.v1Spy, [onA])
        stageLive(bridgeB.v1Spy, [onB])

        await orchestrator.testReconcileBridgeStoredAnimations()
        XCTAssertEqual(recoveredEntries().count, 2, "two bridges, two independently stoppable rows")

        await orchestrator.stopRecoveredBridgeAnimation(recoveredKey(onA, "bridge-a"))

        XCTAssertEqual(Set(bridgeA.v1Spy.succeededDeletes), expectedDeletes(for: onA))
        XCTAssertTrue(bridgeB.v1Spy.deletedResources.isEmpty)
        XCTAssertTrue(storeStillHolds(onB))
        XCTAssertEqual(recoveredEntries().count, 1)
        XCTAssertEqual(orchestrator.testCompositionTransport(roomID: "shared-room"), .bridgeStored,
                       "bridge B's live animation keeps the label")
    }

    /// The exact-selection rule, at the normal stop path.
    func testP8StopCompositionModeTouchesOnlyTheNamedBridgesManifest() async {
        let onA = stageManifest(roomID: "shared-room", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                                sensorID: "S1", ruleIDs: ["R1"], scheduleID: "SC1")
        let onB = stageManifest(roomID: "shared-room", bridgeIP: "192.0.2.2", bridgeID: "bridge-b",
                                sensorID: "S2", ruleIDs: ["R2"], scheduleID: "SC2")
        orchestrator.allRooms = [allDayRoom("shared-room", bridge: "bridge-b")]
        stageLive(bridgeA.v1Spy, [onA])
        stageLive(bridgeB.v1Spy, [onB])
        await orchestrator.testReconcileBridgeStoredAnimations()

        XCTAssertEqual(orchestrator.testExactManifestIDs(bridgeID: "bridge-a", roomID: "shared-room"),
                       [onA.id])
        await orchestrator.stopCompositionMode(roomID: "shared-room", bridgeID: "bridge-a")

        XCTAssertEqual(Set(bridgeA.v1Spy.succeededDeletes), expectedDeletes(for: onA))
        XCTAssertTrue(bridgeB.v1Spy.deletedResources.isEmpty)
        XCTAssertFalse(storeStillHolds(onA))
        XCTAssertTrue(storeStillHolds(onB), "the other bridge's manifest survives")
        XCTAssertNotNil(orchestrator.testRecoveredBridgeAnimations()[recoveredKey(onB, "bridge-b")])
        XCTAssertEqual(recoveredEntries().count, 1)
        XCTAssertEqual(orchestrator.testCompositionTransport(roomID: "shared-room"), .bridgeStored)
    }

    /// A legacy IP-only manifest whose IP matches two registered bridges names
    /// no bridge at all, so nothing may be stopped on its behalf.
    ///
    /// The twins sit on their own TEST-NET-2 host so the ambiguity under test
    /// is the only reason selection comes back empty — bridge A's host is
    /// registered exactly once and would resolve cleanly.
    func testP8AnAmbiguousLegacyIdentityStopsNothing() async {
        let twinX = RoutingSpyClient(bridgeID: "bridge-x", bridgeName: "X", ip: "198.51.100.1")
        let twinY = RoutingSpyClient(bridgeID: "bridge-y", bridgeName: "Y", ip: "198.51.100.1")
        orchestrator.injectForTesting(clients: [
            "bridge-a": bridgeA, "bridge-x": twinX, "bridge-y": twinY,
        ])
        let legacy = stageManifest(roomID: "ambiguous-room", bridgeIP: "198.51.100.1", bridgeID: nil,
                                   sensorID: "S1", ruleIDs: ["R1"], scheduleID: "SC1")

        // The caller's own bridge DOES carry that host — the ambiguity is that
        // a second registered bridge carries it too.
        XCTAssertTrue(
            orchestrator.testExactManifestIDs(bridgeID: "bridge-x", roomID: "ambiguous-room").isEmpty,
            "an IP that resolves to two bridges names neither of them")
        await orchestrator.stopCompositionMode(roomID: "ambiguous-room", bridgeID: "bridge-x")

        XCTAssertTrue(twinX.v1Spy.deletedResources.isEmpty)
        XCTAssertTrue(twinY.v1Spy.deletedResources.isEmpty)
        XCTAssertTrue(bridgeA.v1Spy.deletedResources.isEmpty)
        XCTAssertTrue(storeStillHolds(legacy))
        XCTAssertNil(animationStore.manifest(id: legacy.id)?.bridgeID,
                     "no bridge id is guessed")
    }

    func testP8ANewManifestStaysResolvableAfterItsBridgeChangesIP() async {
        let m = stageManifest(roomID: "room-1", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                              sensorID: "S1", ruleIDs: ["R1"], scheduleID: "SC1")
        // Same bridge, new DHCP lease.
        let moved = RoutingSpyClient(bridgeID: "bridge-a", bridgeName: "A", ip: "192.0.2.77")
        orchestrator.injectForTesting(clients: ["bridge-a": moved, "bridge-b": bridgeB])
        orchestrator.allRooms = [allDayRoom("room-1", bridge: "bridge-a")]
        stageLive(moved.v1Spy, [m])

        await orchestrator.testReconcileBridgeStoredAnimations()

        XCTAssertNotNil(orchestrator.testRecoveredBridgeAnimations()[recoveredKey(m, "bridge-a")],
                        "bridgeID is authoritative, so a dead IP cannot strand the manifest")
        XCTAssertFalse(orchestrator.testIsAllDayWriteAllowed(bridgeID: "bridge-a", roomID: "room-1"),
                       "All-Day suppression must survive the IP change too")

        await orchestrator.stopRecoveredBridgeAnimation(recoveredKey(m, "bridge-a"))
        XCTAssertEqual(Set(moved.v1Spy.succeededDeletes), expectedDeletes(for: m))
        XCTAssertTrue(bridgeB.v1Spy.deletedResources.isEmpty)
    }

    // ── 16-17: legacy migration ─────────────────────────────────────────

    func testP8ALegacyManifestUpgradesOnlyOnAUniqueIPMatch() async {
        orchestrator.allRooms = [allDayRoom("room-1", bridge: "bridge-a")]
        let legacy = stageManifest(roomID: "room-1", bridgeIP: "192.0.2.1", bridgeID: nil,
                                   sensorID: "S1", ruleIDs: ["R1"], scheduleID: "SC1")
        stageLive(bridgeA.v1Spy, [legacy])

        await orchestrator.testReconcileBridgeStoredAnimations()

        XCTAssertEqual(animationStore.manifest(id: legacy.id)?.bridgeID, "bridge-a",
                       "the upgrade is persisted, not just held in memory")
        XCTAssertEqual(animationStore.manifest(id: legacy.id)?.id, legacy.id,
                       "the identity teardown depends on is unchanged")
        XCTAssertNotNil(orchestrator.testRecoveredBridgeAnimations()[recoveredKey(legacy, "bridge-a")])
        XCTAssertTrue(bridgeA.v1Spy.deletedResources.isEmpty)
    }

    func testP8AnAmbiguousLegacyManifestIsRetainedWithoutMutation() async {
        let twin = RoutingSpyClient(bridgeID: "bridge-a2", bridgeName: "A2", ip: "192.0.2.1")
        orchestrator.injectForTesting(clients: ["bridge-a": bridgeA, "bridge-a2": twin])
        let legacy = stageManifest(roomID: "room-1", bridgeIP: "192.0.2.1", bridgeID: nil,
                                   sensorID: "S1", ruleIDs: ["R1"], scheduleID: "SC1")

        await orchestrator.testReconcileBridgeStoredAnimations()

        XCTAssertNil(animationStore.manifest(id: legacy.id)?.bridgeID)
        XCTAssertTrue(storeStillHolds(legacy))
        XCTAssertTrue(bridgeA.v1Spy.deletedResources.isEmpty)
        XCTAssertTrue(twin.v1Spy.deletedResources.isEmpty)
        XCTAssertTrue(recoveredEntries().isEmpty)
    }

    /// An unmapped manifest is not a licence to poll every registered bridge
    /// looking for a home for it.
    func testP8AnUnmappedLegacyManifestIsRetainedAndReadsNothing() async {
        let legacy = stageManifest(roomID: "room-1", bridgeIP: "192.0.2.99", bridgeID: nil,
                                   sensorID: "S1", ruleIDs: ["R1"], scheduleID: "SC1")

        await orchestrator.testReconcileBridgeStoredAnimations()

        XCTAssertTrue(storeStillHolds(legacy))
        XCTAssertNil(animationStore.manifest(id: legacy.id)?.bridgeID)
        XCTAssertTrue(bridgeA.v1Spy.fetchCalls.isEmpty)
        XCTAssertTrue(bridgeB.v1Spy.fetchCalls.isEmpty)
        XCTAssertTrue(bridgeA.v1Spy.deletedResources.isEmpty)
    }

    // ── 18-19: missing preset, missing room ─────────────────────────────

    func testP8AMissingPresetStillShowsItsPersistedNameAndStopsCleanly() async {
        orchestrator.allRooms = [allDayRoom("room-1", bridge: "bridge-a")]
        // presetID belongs to no CompositionStore preset.
        let m = stageManifest(roomID: "room-1", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                              presetID: UUID(), presetName: "Sunset Drift",
                              sensorID: "S1", ruleIDs: ["R1"], scheduleID: "SC1")
        stageLive(bridgeA.v1Spy, [m])
        _ = makeStudioVM()

        await orchestrator.testReconcileBridgeStoredAnimations()

        XCTAssertEqual(recoveredEntries().first?.effectName, "Sunset Drift",
                       "the manifest's own persisted name, never a lookup that fails to nil")
        XCTAssertFalse(recoveredEntries().first?.effectIcon.isEmpty ?? true)

        await orchestrator.requestNowPlayingStop(recoveredEntries()[0])
        XCTAssertEqual(Set(bridgeA.v1Spy.succeededDeletes), expectedDeletes(for: m))
        XCTAssertFalse(storeStillHolds(m))
    }

    func testP8AMissingRoomKeepsAVisibleEntryAndStopsByExactManifest() async {
        // Only a DECOY room resolves — nothing may be guessed onto it.
        orchestrator.allRooms = [allDayRoom("room-other", bridge: "bridge-a")]
        let gone = stageManifest(roomID: "room-gone", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                                 presetName: "Ghost Look", roomName: "Old Study",
                                 sensorID: "S1", ruleIDs: ["R1"], scheduleID: "SC1")
        let other = stageManifest(roomID: "room-other", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                                  sensorID: "S2", ruleIDs: ["R2"], scheduleID: "SC2")
        stageLive(bridgeA.v1Spy, [gone, other])
        let vm = makeStudioVM()

        await orchestrator.testReconcileBridgeStoredAnimations()

        let ghost = recoveredEntries().first { $0.roomID == "room-gone" }
        XCTAssertEqual(ghost?.roomName, "Old Study", "the persisted room name keeps it identifiable")
        XCTAssertEqual(ghost?.effectName, "Ghost Look")
        XCTAssertNil(ghost?.groupedLightID, "there is no trustworthy grouped light to name")
        XCTAssertNil(vm.runningEffects["room-gone"], "no room ⇒ no Studio row, and no room guessing")
        XCTAssertNotNil(vm.runningEffects["room-other"])

        await orchestrator.stopRecoveredBridgeAnimation(recoveredKey(gone, "bridge-a"))

        XCTAssertEqual(Set(bridgeA.v1Spy.succeededDeletes), expectedDeletes(for: gone))
        XCTAssertTrue(Set(bridgeA.v1Spy.succeededDeletes).isDisjoint(with: expectedDeletes(for: other)))
        XCTAssertTrue(storeStillHolds(other))
        XCTAssertTrue(bridgeA.groupedPowerIDs.isEmpty,
                      "an unresolved room is never powered off — there is nothing safe to address")
        XCTAssertEqual(recoveredEntries().map(\.roomID), ["room-other"])
    }

    // ── 20 + amendment 4: stale stop, generation-safe power-off ─────────

    /// A stop parked mid-cleanup while a replacement takes the same room. The
    /// old stop may retire its OWN manifest and nothing else — and it must not
    /// darken a room that is now legitimately playing.
    func testP8AStaleStopCannotEraseAReplacementOrPowerOffItsRoom() async {
        orchestrator.allRooms = [allDayRoom("room-1", bridge: "bridge-a")]
        let old = stageManifest(roomID: "room-1", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                                presetName: "Old Look", sensorID: "S1", ruleIDs: ["R1"], scheduleID: "SC1")
        stageLive(bridgeA.v1Spy, [old])
        await orchestrator.testReconcileBridgeStoredAnimations()

        let gate = RestGate()
        bridgeA.v1Spy.stageDeleteGate("schedule:SC1", gate)
        let stopTask = Task { await orchestrator.stopRecoveredBridgeAnimation(recoveredKey(old, "bridge-a")) }
        await gate.waitUntilStarted()

        // A replacement lands on the same bridge + room while the stop is parked.
        let replacement = stageManifest(roomID: "room-1", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                                        presetName: "New Look", sensorID: "S9", ruleIDs: ["R9"],
                                        scheduleID: "SC9")
        orchestrator.testPublishRecovered(manifest: replacement, bridgeID: "bridge-a")

        await gate.release()
        _ = await stopTask.value

        XCTAssertFalse(storeStillHolds(old), "the old stop retires its own manifest")
        XCTAssertTrue(storeStillHolds(replacement), "and cannot touch the replacement's")
        XCTAssertTrue(Set(bridgeA.v1Spy.deletedResources)
            .isDisjoint(with: expectedDeletes(for: replacement)))
        XCTAssertNotNil(orchestrator.testRecoveredBridgeAnimations()[recoveredKey(replacement, "bridge-a")])
        XCTAssertEqual(recoveredEntries().count, 1)
        XCTAssertEqual(recoveredEntries().first?.effectName, "New Look")
        XCTAssertEqual(orchestrator.testCompositionTransport(roomID: "room-1"), .bridgeStored)
        XCTAssertTrue(bridgeA.groupedPowerIDs.isEmpty,
                      "the room is playing again — a stale stop must not turn it off")
    }

    /// The inverse control for the power-off guard: with no replacement, a
    /// successful recovered stop sends exactly one room-off request.
    func testP8ASuccessfulRecoveredStopSendsExactlyOneRoomOff() async {
        orchestrator.allRooms = [allDayRoom("room-1", bridge: "bridge-a")]
        let m = stageManifest(roomID: "room-1", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                              sensorID: "S1", ruleIDs: ["R1"], scheduleID: "SC1")
        stageLive(bridgeA.v1Spy, [m])
        await orchestrator.testReconcileBridgeStoredAnimations()

        await orchestrator.stopRecoveredBridgeAnimation(recoveredKey(m, "bridge-a"))

        XCTAssertEqual(bridgeA.groupedPowerIDs, ["gl-room-1:false"])
    }

    /// Siri's promise is "the lights stay as they are".
    func testP8ASiriStyleStopNeverPowersTheRoomOff() async {
        orchestrator.allRooms = [allDayRoom("room-1", bridge: "bridge-a")]
        let m = stageManifest(roomID: "room-1", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                              sensorID: "S1", ruleIDs: ["R1"], scheduleID: "SC1")
        stageLive(bridgeA.v1Spy, [m])
        await orchestrator.testReconcileBridgeStoredAnimations()

        await orchestrator.requestNowPlayingStop(recoveredEntries()[0], turnOffLights: false)

        XCTAssertFalse(storeStillHolds(m))
        XCTAssertTrue(bridgeA.groupedPowerIDs.isEmpty)
    }

    // ── Amendment 3: freshness ──────────────────────────────────────────

    /// The user stops and removes a manifest while a pass holds its snapshot.
    /// Publishing the stale decision would resurrect a row for an animation
    /// that is genuinely gone.
    func testP8APassCannotRepublishAManifestRemovedDuringIt() async {
        orchestrator.allRooms = [allDayRoom("room-1", bridge: "bridge-a")]
        let m = stageManifest(roomID: "room-1", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                              sensorID: "S1", ruleIDs: ["R1"], scheduleID: "SC1")
        stageLive(bridgeA.v1Spy, [m])

        let gate = RestGate()
        bridgeA.v1Spy.stageInventoryGate("fetchSchedules", gate)
        let pass = Task { await orchestrator.testReconcileBridgeStoredAnimations() }
        await gate.waitUntilStarted()
        animationStore.remove(id: m.id)   // the user stopped it
        await gate.release()
        await pass.value

        XCTAssertTrue(recoveredEntries().isEmpty, "a stale snapshot must not be published")
        XCTAssertFalse(storeStillHolds(m))
    }

    /// A manifest saved AFTER the pass began is absent from its input through
    /// no fault of its own. Sweeping "everything this answering bridge did not
    /// report" would destroy it.
    func testP8AManifestSavedDuringAPassSurvivesAndIsNotSwept() async {
        orchestrator.allRooms = [
            allDayRoom("room-1", bridge: "bridge-a"), allDayRoom("room-2", bridge: "bridge-a"),
        ]
        let existing = stageManifest(roomID: "room-1", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                                     sensorID: "S1", ruleIDs: ["R1"], scheduleID: "SC1")
        stageLive(bridgeA.v1Spy, [existing])

        let gate = RestGate()
        bridgeA.v1Spy.stageInventoryGate("fetchSchedules", gate)
        let pass = Task { await orchestrator.testReconcileBridgeStoredAnimations() }
        await gate.waitUntilStarted()
        let newcomer = stageManifest(roomID: "room-2", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                                     presetName: "Newcomer", sensorID: "S2", ruleIDs: ["R2"],
                                     scheduleID: "SC2")
        orchestrator.testPublishRecovered(manifest: newcomer, bridgeID: "bridge-a")
        await gate.release()
        await pass.value

        XCTAssertTrue(storeStillHolds(newcomer))
        XCTAssertNotNil(orchestrator.testRecoveredBridgeAnimations()[recoveredKey(newcomer, "bridge-a")],
                        "a manifest created after the pass began must survive it")
        XCTAssertEqual(Set(recoveredEntries().map(\.roomID)), ["room-1", "room-2"])
        XCTAssertTrue(bridgeA.v1Spy.deletedResources.isEmpty)
    }

    /// A legacy upgrade that lands during the await must not be reverted by the
    /// pass's pre-upgrade snapshot.
    func testP8ALegacyUpgradeDuringAPassIsNotOverwrittenByTheStaleValue() async {
        orchestrator.allRooms = [allDayRoom("room-1", bridge: "bridge-a")]
        let legacy = stageManifest(roomID: "room-1", bridgeIP: "192.0.2.99", bridgeID: nil,
                                   sensorID: "S1", ruleIDs: ["R1"], scheduleID: "SC1")
        let live = stageManifest(roomID: "room-2", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                                 sensorID: "S2", ruleIDs: ["R2"], scheduleID: "SC2")
        stageLive(bridgeA.v1Spy, [live])

        let gate = RestGate()
        bridgeA.v1Spy.stageInventoryGate("fetchSchedules", gate)
        let pass = Task { await orchestrator.testReconcileBridgeStoredAnimations() }
        await gate.waitUntilStarted()
        animationStore.adoptBridgeID("bridge-b", forManifestID: legacy.id)
        await gate.release()
        await pass.value

        XCTAssertEqual(animationStore.manifest(id: legacy.id)?.bridgeID, "bridge-b",
                       "the concurrent upgrade stands; the stale pre-upgrade value never wins")
        XCTAssertTrue(storeStillHolds(legacy))
    }

    // ── Amendment 2: replacement is blocked until cleanup is complete ───

    func testP8AReplacementIsRefusedWhenTheOldScheduleDeleteFails() async {
        let old = stageManifest(roomID: "room-1", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                                sensorID: "S1", ruleIDs: ["R1"], scheduleID: "SC1")
        bridgeA.v1Spy.stageDeleteFailures(["schedule:SC1"])

        let readiness = await orchestrator.testCleanupBridgeStoredForReplacement(
            roomID: "room-1", bridgeID: "bridge-a", v1Client: bridgeA.v1Spy)

        guard case .blocked(_, let retained) = readiness else {
            return XCTFail("a refused delete must block the replacement")
        }
        XCTAssertEqual(retained, [old.id])
        XCTAssertTrue(storeStillHolds(old))
        XCTAssertTrue(bridgeA.v1Spy.creations.isEmpty, "zero new create requests")
        XCTAssertTrue(bridgeA.v1Spy.fetchCalls.isEmpty, "and still no enumeration (packet 2)")
    }

    func testP8AReplacementIsRefusedWhenOneOldRuleDeleteFails() async {
        let old = stageManifest(roomID: "room-1", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                                sensorID: "S1", ruleIDs: ["R1", "R2"], scheduleID: "SC1")
        bridgeA.v1Spy.stageDeleteFailures(["rule:R2"])

        let readiness = await orchestrator.testCleanupBridgeStoredForReplacement(
            roomID: "room-1", bridgeID: "bridge-a", v1Client: bridgeA.v1Spy)

        guard case .blocked = readiness else { return XCTFail("expected blocked") }
        XCTAssertTrue(storeStillHolds(old))
        XCTAssertTrue(bridgeA.v1Spy.creations.isEmpty)
    }

    func testP8AReplacementIsRefusedWhenTheBridgeIsUnreadable() async {
        let old = stageManifest(roomID: "room-1", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                                sensorID: "S1", ruleIDs: ["R1"], scheduleID: "SC1")
        bridgeA.v1Spy.stageInventoryFailure([])   // reads are irrelevant here
        bridgeA.v1Spy.stageDeleteFailures([])
        // Every delete fails at transport level.
        bridgeA.v1Spy.stageDeleteFailures([])
        bridgeA.v1Spy.stageAlreadyAbsentDeletes([])
        bridgeA.v1Spy.stageDeleteFailures(["schedule:SC1", "rule:R1", "sensor:S1"])

        let readiness = await orchestrator.testCleanupBridgeStoredForReplacement(
            roomID: "room-1", bridgeID: "bridge-a", v1Client: bridgeA.v1Spy)

        guard case .blocked = readiness else { return XCTFail("expected blocked") }
        XCTAssertTrue(storeStillHolds(old))
        XCTAssertTrue(bridgeA.v1Spy.creations.isEmpty)
    }

    func testP8EveryExactOldManifestIsRemovedBeforeAReplacementIsAllowed() async {
        let first = stageManifest(roomID: "room-1", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                                  sensorID: "S1", ruleIDs: ["R1"], scheduleID: "SC1")
        let second = stageManifest(roomID: "room-1", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                                   sensorID: "S2", ruleIDs: ["R2"], scheduleID: "SC2")
        let sibling = stageManifest(roomID: "room-2", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                                    sensorID: "S3", ruleIDs: ["R3"], scheduleID: "SC3")

        let readiness = await orchestrator.testCleanupBridgeStoredForReplacement(
            roomID: "room-1", bridgeID: "bridge-a", v1Client: bridgeA.v1Spy)

        XCTAssertEqual(readiness, .clear)
        XCTAssertEqual(Set(bridgeA.v1Spy.succeededDeletes),
                       expectedDeletes(for: first).union(expectedDeletes(for: second)))
        XCTAssertFalse(storeStillHolds(first))
        XCTAssertFalse(storeStillHolds(second))
        XCTAssertTrue(storeStillHolds(sibling), "another room is never touched")
    }

    func testP8ABlockedReplacementOnOneBridgeDoesNotBlockTheOther() async {
        let onA = stageManifest(roomID: "room-1", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                                sensorID: "S1", ruleIDs: ["R1"], scheduleID: "SC1")
        let onB = stageManifest(roomID: "room-1", bridgeIP: "192.0.2.2", bridgeID: "bridge-b",
                                sensorID: "S2", ruleIDs: ["R2"], scheduleID: "SC2")
        bridgeA.v1Spy.stageDeleteFailures(["sensor:S1"])

        let blocked = await orchestrator.testCleanupBridgeStoredForReplacement(
            roomID: "room-1", bridgeID: "bridge-a", v1Client: bridgeA.v1Spy)
        let clear = await orchestrator.testCleanupBridgeStoredForReplacement(
            roomID: "room-1", bridgeID: "bridge-b", v1Client: bridgeB.v1Spy)

        guard case .blocked = blocked else { return XCTFail("bridge A must be blocked") }
        XCTAssertEqual(clear, .clear, "bridge B proceeds independently")
        XCTAssertTrue(storeStillHolds(onA))
        XCTAssertFalse(storeStillHolds(onB))
    }

    /// An already-absent resource is not a reason to refuse forever.
    func testP8AnAlreadyAbsentOldManifestClearsTheReplacement() async {
        let old = stageManifest(roomID: "room-1", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                                sensorID: "S1", ruleIDs: ["R1"], scheduleID: "SC1")
        bridgeA.v1Spy.stageAlreadyAbsentDeletes(["schedule:SC1", "rule:R1", "sensor:S1"])

        let readiness = await orchestrator.testCleanupBridgeStoredForReplacement(
            roomID: "room-1", bridgeID: "bridge-a", v1Client: bridgeA.v1Spy)

        XCTAssertEqual(readiness, .clear)
        XCTAssertFalse(storeStillHolds(old))
    }

    // ── Amendment/packet interop: 6 and 2 stay intact ───────────────────

    func testP8ALiveManifestStillSuppressesAllDayAndAPrunedOneStops() async {
        orchestrator.allRooms = [allDayRoom("room-1", bridge: "bridge-a")]
        let m = stageManifest(roomID: "room-1", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                              sensorID: "S1", ruleIDs: ["R1"], scheduleID: "SC1")
        stageLive(bridgeA.v1Spy, [m])
        await orchestrator.testReconcileBridgeStoredAnimations()

        XCTAssertFalse(orchestrator.testIsAllDayWriteAllowed(bridgeID: "bridge-a", roomID: "room-1"))
        XCTAssertTrue(orchestrator.testIsAllDayWriteAllowed(bridgeID: "bridge-b", roomID: "room-1"),
                      "suppression is per exact bridge")
        XCTAssertTrue(orchestrator.testIsAllDayWriteAllowed(bridgeID: "bridge-a", roomID: "room-2"))

        // Prove it absent, and the room becomes eligible again — otherwise
        // All-Day would be dead in that room forever.
        bridgeA.v1Spy.stageInventory("fetchSchedules", [:])
        bridgeA.v1Spy.stageInventory("fetchRules", [:])
        bridgeA.v1Spy.stageInventory("fetchSensors", [:])
        await orchestrator.testReconcileBridgeStoredAnimations()
        XCTAssertFalse(storeStillHolds(m))
        XCTAssertTrue(orchestrator.testIsAllDayWriteAllowed(bridgeID: "bridge-a", roomID: "room-1"))
    }

    /// `stopStudioMode` sends no v1 delete, so it may not claim to have stopped
    /// what is still running on a bridge.
    func testP8StopStudioModeLeavesRecoveredRowsAndTheirResourcesAlone() async {
        orchestrator.allRooms = [allDayRoom("room-1", bridge: "bridge-a")]
        let m = stageManifest(roomID: "room-1", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                              sensorID: "S1", ruleIDs: ["R1"], scheduleID: "SC1")
        stageLive(bridgeA.v1Spy, [m])
        await orchestrator.testReconcileBridgeStoredAnimations()

        await orchestrator.stopStudioMode()

        XCTAssertEqual(recoveredEntries().count, 1)
        XCTAssertTrue(storeStillHolds(m))
        XCTAssertTrue(bridgeA.v1Spy.deletedResources.isEmpty)
    }

    // ── Source-shape guards (packet-2 pattern) ──────────────────────────

    /// A shell grep cannot express ordering WITHIN a function body.
    func testP8ReconciliationRunsInsideLoadAllAfterTheBridgeFetchAndRoomRebuild() throws {
        let code = try productionCode("HueHome/Core/Network/UnifiedOrchestrator.swift")
        let body = try XCTUnwrap(functionBody(code, startingWith: "func loadAll(cacheContext:"))
        let fetch = try XCTUnwrap(body.firstIndex { $0.contains("await fetchAndMergeAllBridges()") })
        let rebuild = try XCTUnwrap(body.firstIndex { $0.contains("rebuildAllRooms()") })
        let reconcile = try XCTUnwrap(
            body.firstIndex { $0.contains("scheduleBridgeAnimationReconciliation()") })
        XCTAssertLessThan(fetch, reconcile,
                          "a manifest cannot be judged before its bridge is registered")
        XCTAssertLessThan(rebuild, reconcile,
                          "rooms must be authoritative before a recovered room is resolved")
    }

    /// Reconciliation restores presentation, never runtime.
    func testP8TheReconcilerBodyStartsNoRuntime() throws {
        let code = try productionCode("HueHome/Core/Network/UnifiedOrchestrator.swift")
        let body = try XCTUnwrap(
            functionBody(code, startingWith: "func reconcileBridgeStoredAnimations()")).joined(separator: "\n")
        XCTAssertFalse(body.isEmpty)
        for banned in [".enqueue(", "startCompositionScheduler", "refreshCompositionMicDemand",
                       "HueEntertainmentClient", "setGroupedLight", "AVAudio",
                       "purgeAllChromaGlowResources"] {
            XCTAssertFalse(body.contains(banned), "reconciliation must not reach \(banned)")
        }
    }

    /// Destructive selection goes through ONE exact-identity funnel.
    func testP8DestructiveManifestSelectionIsAlwaysBridgeExact() throws {
        let code = try productionCode("HueHome/Core/Network/UnifiedOrchestrator.swift")
        for name in ["func stopCompositionMode(roomID:",
                     "private func cleanupBridgeStoredAnimationForReplacement("] {
            let body = try XCTUnwrap(functionBody(code, startingWith: name)).joined(separator: "\n")
            XCTAssertFalse(body.isEmpty, "\(name) not found")
            XCTAssertTrue(body.contains("exactManifests("),
                          "\(name) must select through the exact-identity funnel")
            XCTAssertFalse(body.contains("allManifests()"),
                           "\(name) must not enumerate every manifest")
            XCTAssertFalse(body.contains(".roomID == roomID"),
                           "\(name) must not select destructively on a room id alone")
        }
    }

    /// The replacement must be gated on the cleanup RESULT, before any create.
    func testP8TheBridgeStoredStartIsGatedOnCleanupCompletion() throws {
        let code = try productionCode("HueHome/Core/Network/UnifiedOrchestrator.swift")
        let body = try XCTUnwrap(functionBody(code, startingWith: "func startCompositionMode("))
        let gate = try XCTUnwrap(body.firstIndex { $0.contains("case .blocked") })
        let upload = try XCTUnwrap(body.firstIndex { $0.contains("bridgeAnimationEngine.upload(") })
        XCTAssertLessThan(gate, upload,
                          "nothing may be created until the old chain is provably gone")
    }


    // ── Follow-up corrections to packet 8 ───────────────────────────────

    /// `runningEffects` is keyed by room id alone, so it cannot represent one
    /// room id running on two bridges. Letting dictionary order pick a winner
    /// would mean selecting bridge A and pressing Stop could tear down bridge
    /// B's animation. Studio mirrors NEITHER; both stay exactly stoppable from
    /// the Dashboard.
    func testP8ADuplicateRoomIDAcrossBridgesIsMirroredForNeitherStudioRoom() async {
        let roomOnA = allDayRoom("shared-room", bridge: "bridge-a")
        let roomOnB = allDayRoom("shared-room", bridge: "bridge-b")
        orchestrator.allRooms = [roomOnA, roomOnB]
        let onA = stageManifest(roomID: "shared-room", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                                presetName: "Look A", sensorID: "S1", ruleIDs: ["R1"], scheduleID: "SC1")
        let onB = stageManifest(roomID: "shared-room", bridgeIP: "192.0.2.2", bridgeID: "bridge-b",
                                presetName: "Look B", sensorID: "S2", ruleIDs: ["R2"], scheduleID: "SC2")
        stageLive(bridgeA.v1Spy, [onA])
        stageLive(bridgeB.v1Spy, [onB])
        let vm = makeStudioVM()

        await orchestrator.testReconcileBridgeStoredAnimations()

        XCTAssertNil(vm.runningEffects["shared-room"],
                     "an ambiguous room id must not be mirrored — dictionary order may not pick an owner")
        XCTAssertEqual(recoveredEntries().count, 2, "both stay visible and exactly stoppable")

        // Selecting either bridge's room can neither display nor stop the
        // other's animation: there is nothing for Studio's roomID-keyed stop
        // to act on at all.
        for room in [roomOnA, roomOnB] {
            vm.selectedRoom = room
            XCTAssertNil(vm.currentRoomEffect)
            await vm.stopFromNowPlaying(roomID: "shared-room")
        }
        XCTAssertTrue(bridgeA.v1Spy.deletedResources.isEmpty)
        XCTAssertTrue(bridgeB.v1Spy.deletedResources.isEmpty)
        XCTAssertTrue(storeStillHolds(onA))
        XCTAssertTrue(storeStillHolds(onB))
        XCTAssertEqual(recoveredEntries().count, 2)

        // Each Dashboard row still stops exactly its own animation.
        let rowForA = recoveredEntries().first { $0.recovered?.bridgeID == "bridge-a" }
        await orchestrator.requestNowPlayingStop(try! XCTUnwrap(rowForA))

        XCTAssertEqual(Set(bridgeA.v1Spy.succeededDeletes), expectedDeletes(for: onA))
        XCTAssertTrue(bridgeB.v1Spy.deletedResources.isEmpty, "the other bridge is untouched")
        XCTAssertFalse(storeStillHolds(onA))
        XCTAssertTrue(storeStillHolds(onB))
        XCTAssertEqual(recoveredEntries().map { $0.recovered?.bridgeID }, ["bridge-b"])
        XCTAssertEqual(orchestrator.testCompositionTransport(roomID: "shared-room"), .bridgeStored,
                       "bridge B's animation still owns the transport label")

        // And with the ambiguity resolved, the survivor becomes mirrorable.
        await orchestrator.testReconcileBridgeStoredAnimations()
        XCTAssertEqual(vm.runningEffects["shared-room"]?.recovered, recoveredKey(onB, "bridge-b"))
    }

    /// An idempotent republish re-confirms the SAME owner. Treating it as an
    /// ownership change would make every routine reconciliation look like a
    /// replacement and silently swallow the room-off of a stop in flight.
    func testP8AnUnchangedRepublishDoesNotSuppressAParkedStopsRoomOff() async {
        orchestrator.allRooms = [allDayRoom("room-1", bridge: "bridge-a")]
        let m = stageManifest(roomID: "room-1", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                              sensorID: "S1", ruleIDs: ["R1"], scheduleID: "SC1")
        stageLive(bridgeA.v1Spy, [m])
        await orchestrator.testReconcileBridgeStoredAnimations()

        let gate = RestGate()
        bridgeA.v1Spy.stageDeleteGate("schedule:SC1", gate)
        let stopTask = Task { await orchestrator.stopRecoveredBridgeAnimation(recoveredKey(m, "bridge-a")) }
        await gate.waitUntilStarted()

        // A routine refresh lands mid-stop and re-publishes the same manifest.
        await orchestrator.testReconcileBridgeStoredAnimations()

        await gate.release()
        _ = await stopTask.value

        XCTAssertFalse(storeStillHolds(m))
        XCTAssertEqual(bridgeA.groupedPowerIDs, ["gl-room-1:false"],
                       "exactly one room-off — an unchanged refresh is not a new owner")
        XCTAssertTrue(recoveredEntries().isEmpty)
    }

    /// A display-name refresh is not an ownership change either.
    func testP8ADisplayNameRefreshDoesNotMoveTheOwnershipGeneration() async {
        orchestrator.allRooms = [allDayRoom("room-1", bridge: "bridge-a")]
        let m = stageManifest(roomID: "room-1", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                              sensorID: "S1", ruleIDs: ["R1"], scheduleID: "SC1")
        stageLive(bridgeA.v1Spy, [m])
        await orchestrator.testReconcileBridgeStoredAnimations()
        let generation = orchestrator.testRoomOwnershipGeneration(bridgeID: "bridge-a", roomID: "room-1")

        orchestrator.refreshRecoveredDisplayName(key: recoveredKey(m, "bridge-a"), name: "Renamed")
        XCTAssertEqual(orchestrator.testRoomOwnershipGeneration(bridgeID: "bridge-a", roomID: "room-1"),
                       generation)

        await orchestrator.testReconcileBridgeStoredAnimations()
        XCTAssertEqual(orchestrator.testRoomOwnershipGeneration(bridgeID: "bridge-a", roomID: "room-1"),
                       generation, "re-confirming the same owner is not an acquisition")
    }

    /// The replacement control for the guard above: a genuinely new owner DOES
    /// move the generation, and the parked stop must then send no room-off.
    func testP8AGenuineReplacementStillSuppressesTheParkedStopsRoomOff() async {
        orchestrator.allRooms = [allDayRoom("room-1", bridge: "bridge-a")]
        let old = stageManifest(roomID: "room-1", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                                presetName: "Old Look", sensorID: "S1", ruleIDs: ["R1"], scheduleID: "SC1")
        stageLive(bridgeA.v1Spy, [old])
        await orchestrator.testReconcileBridgeStoredAnimations()

        let gate = RestGate()
        bridgeA.v1Spy.stageDeleteGate("schedule:SC1", gate)
        let stopTask = Task { await orchestrator.stopRecoveredBridgeAnimation(recoveredKey(old, "bridge-a")) }
        await gate.waitUntilStarted()

        let replacement = stageManifest(roomID: "room-1", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                                        presetName: "New Look", sensorID: "S9", ruleIDs: ["R9"],
                                        scheduleID: "SC9")
        orchestrator.testPublishRecovered(manifest: replacement, bridgeID: "bridge-a")

        await gate.release()
        _ = await stopTask.value

        XCTAssertFalse(storeStillHolds(old))
        XCTAssertTrue(storeStillHolds(replacement))
        XCTAssertTrue(bridgeA.groupedPowerIDs.isEmpty,
                      "the room is playing again — no room-off may be sent")
        XCTAssertEqual(recoveredEntries().first?.effectName, "New Look")
    }

    // ── Display name on both surfaces ───────────────────────────────────

    /// A store on its own file, so a rename assertion never reads or writes the
    /// developer's real `compositions.json`.
    private func makeStudioVM(presets: [CompositionPreset]) -> StudioViewModel {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("p8-presets-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = CompositionStore(fileURL: url, loadsSynchronously: true)
        for preset in presets { store.save(preset) }
        let vm = StudioViewModel()
        vm.injectForTesting(compositionStore: store)
        vm.configure(orchestrator: orchestrator)
        return vm
    }

    private func renamedPreset(_ name: String) -> CompositionPreset {
        var preset = CompositionStore.builtInPresets.first { !$0.reaction.requiresMic }!
        preset.name = name
        return preset
    }

    func testP8ARenamedPresetShowsItsCurrentNameOnBothSurfaces() async {
        orchestrator.allRooms = [allDayRoom("room-1", bridge: "bridge-a")]
        let preset = renamedPreset("Renamed Look")
        // The manifest still carries the name recorded at upload time.
        let m = stageManifest(roomID: "room-1", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                              presetID: preset.id, presetName: "Name At Upload",
                              sensorID: "S1", ruleIDs: ["R1"], scheduleID: "SC1")
        stageLive(bridgeA.v1Spy, [m])
        let vm = makeStudioVM(presets: [preset])

        await orchestrator.testReconcileBridgeStoredAnimations()

        XCTAssertEqual(vm.runningEffects["room-1"]?.card.name, "Renamed Look",
                       "Studio builds its card from the CURRENT preset name")
        XCTAssertEqual(recoveredEntries().first?.effectName, "Renamed Look",
                       "and the Dashboard row matches it")
        XCTAssertEqual(recoveredEntries().count, 1, "no duplicate row from the refresh")

        // Idempotent: a second pass changes neither surface nor the row count.
        await orchestrator.testReconcileBridgeStoredAnimations()
        XCTAssertEqual(vm.runningEffects["room-1"]?.card.name, "Renamed Look")
        XCTAssertEqual(recoveredEntries().count, 1)
    }

    func testP8ADeletedPresetKeepsThePersistedNameOnBothSurfaces() async {
        orchestrator.allRooms = [allDayRoom("room-1", bridge: "bridge-a")]
        // presetID matches nothing in the store — the preset was deleted.
        let m = stageManifest(roomID: "room-1", bridgeIP: "192.0.2.1", bridgeID: "bridge-a",
                              presetID: UUID(), presetName: "Name At Upload",
                              sensorID: "S1", ruleIDs: ["R1"], scheduleID: "SC1")
        stageLive(bridgeA.v1Spy, [m])
        let vm = makeStudioVM(presets: [renamedPreset("Some Other Look")])

        await orchestrator.testReconcileBridgeStoredAnimations()

        XCTAssertEqual(vm.runningEffects["room-1"]?.card.name, "Name At Upload")
        XCTAssertEqual(recoveredEntries().first?.effectName, "Name At Upload")

        // And it is still stoppable, which is the point of keeping the name.
        await vm.stopFromNowPlaying(roomID: "room-1")
        XCTAssertEqual(Set(bridgeA.v1Spy.succeededDeletes), expectedDeletes(for: m))
        XCTAssertFalse(storeStillHolds(m))
    }

    // ──────────────────────────────────────────────
    // MARK: - Packet 7 follow-up: the three device-discovered defects
    // ──────────────────────────────────────────────
    //
    // Merged packets 7 and 8 shipped to a real bridge and three things went
    // wrong that no unit test could have seen, because all three are about
    // state the app had already decided it knew:
    //
    //  A. The Streaming transport row was `.disabled(!availability.canStream)`
    //     against a CACHED verdict, and tapping that row was the only thing
    //     that ever refreshed the cache. An Entertainment Area created in the
    //     Hue app stayed undiscoverable until a force-quit — so packet 7's
    //     takeover prompt was unreachable on hardware. A cached no may explain
    //     itself; it may not disable its own remedy.
    //
    //  B. A ChromaGlow Strobe session is `processOwned`, so packet 7's foreign
    //     set is empty against it and its consent flow is a deliberate no-op.
    //     A streaming composition therefore opened a SECOND session on a bridge
    //     we were already streaming, and reported the failure as an ordinary
    //     technical inability — which every caller reads as licence to play
    //     REST underneath a live 25 fps stream.
    //
    //  C. The Reduce Motion refusal wrote `statusMessage`, which nothing
    //     renders. The tap simply did nothing.
    //
    // Same discipline as the packets above: presence, identity and ORDER only.
    // No sleeps, no waiters, no elapsed-time claims. The load-bearing tests
    // drive the REAL `StudioViewModel.apply` → `foreignTakeoverPreflight` →
    // `acquireEntertainment` path, so removing the forced preflight while the
    // row stays tappable fails them.

    // ── Shared fixtures ───────────────────────────────────────

    /// `makeP7VM` plus an ISOLATED composition store, so the composition tests
    /// never read or write the developer's real `compositions.json`.
    private func makeP7FVM(presets: [CompositionPreset] = []) -> StudioViewModel {
        let vm = makeP7VM()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("p7f-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = CompositionStore(fileURL: url, loadsSynchronously: true)
        for preset in presets { store.save(preset) }
        vm.injectForTesting(compositionStore: store)
        return vm
    }

    /// A saved composition and its Studio card, in one step.
    private func p7fComposition(_ vm: StudioViewModel,
                                named name: String = "Aurora Drift")
        -> (preset: CompositionPreset, card: StudioCard) {
        let preset = makePreset(named: name)
        vm.compositionStore.save(preset)
        return (preset, vm.studioCard(for: preset))
    }

    /// Stage "one of OUR OWN app-driven looks is streaming this bridge" without
    /// a DTLS handshake.
    ///
    /// Both halves are installed through the production seam, because
    /// `studioOwningEntertainment` deliberately answers nil unless the live
    /// client and the record agree — a fixture that wrote only one of them
    /// would be testing a state production reports as "no owner".
    @discardableResult
    private func installStudioOwner(
        spy: RoutingSpyClient,
        bridgeID: String,
        roomID: String,
        engineKey: String,
        configID: String
    ) async -> UnifiedOrchestrator.StudioEntertainmentOwner {
        let client = HueEntertainmentClient(
            bridgeID: bridgeID, bridgeIP: "192.0.2.9",
            username: "t", clientKeyHex: "ZZ-not-hex",
            restClient: spy, ownership: ownershipStore)
        await client.seedSessionForTesting(configID: configID)
        let owner = UnifiedOrchestrator.StudioEntertainmentOwner(
            bridgeID: bridgeID, roomID: roomID,
            engineKey: engineKey, configID: configID)
        orchestrator.testInstallStudioEntertainmentOwner(owner, client: client)
        return owner
    }

    /// The bridge-side room `streamRoomOnB()` mirrors, so `loadAll` can build
    /// `allRooms` through the production rebuild instead of a hand assignment.
    private func hueRoomB() -> HueRoom {
        HueRoom(
            id: "room-b",
            metadata: RoomMetadata(name: "Bedroom B", archetype: nil),
            children: [ResourceRef(rid: "L1", rtype: "light"),
                       ResourceRef(rid: "L2", rtype: "light")],
            services: [ResourceRef(rid: "gl-room-b", rtype: "grouped_light")]
        )
    }

    /// A bridge with TWO areas: `area-b` covers this room's lights, `area-far`
    /// covers a light that is not in it at all.
    private func stageTwoAreaBridge(_ spy: RoutingSpyClient) {
        spy.stageLights([p7Light("L1", device: "D1"),
                         p7Light("L2", device: "D2"),
                         p7Light("L9", device: "D9")])
        spy.stageEntertainmentServices(
            #"{"data":[{"id":"E1","owner":{"rid":"D1","rtype":"device"}},"# +
            #"{"id":"E2","owner":{"rid":"D2","rtype":"device"}},"# +
            #"{"id":"E9","owner":{"rid":"D9","rtype":"device"}}]}"#)
        spy.stageEntertainmentConfigs(
            #"{"data":[{"id":"area-b","metadata":{"name":"Bedroom"},"status":"inactive","channels":["# +
            #"{"channel_id":0,"position":{"x":0,"y":0,"z":0},"members":[{"service":{"rid":"E1","rtype":"entertainment"}}]},"# +
            #"{"channel_id":1,"position":{"x":0,"y":0,"z":0},"members":[{"service":{"rid":"E2","rtype":"entertainment"}}]}]},"# +
            #"{"id":"area-far","metadata":{"name":"Hallway"},"status":"inactive","channels":["# +
            #"{"channel_id":0,"position":{"x":0,"y":0,"z":0},"members":[{"service":{"rid":"E9","rtype":"entertainment"}}]}]}]}"#)
    }

    /// A bridge whose only area covers a device this room does not contain —
    /// the real cause of a `.noMatchingArea` verdict.
    private func stageMismatchedMembership(_ spy: RoutingSpyClient) {
        spy.stageLights([p7Light("L1", device: "D1"), p7Light("L2", device: "D2")])
        spy.stageEntertainmentServices(
            #"{"data":[{"id":"E9","owner":{"rid":"D9","rtype":"device"}}]}"#)
        spy.stageEntertainmentConfigs(
            #"{"data":[{"id":"area-b","metadata":{"name":"Bedroom"},"status":"inactive","channels":["# +
            #"{"channel_id":0,"position":{"x":0,"y":0,"z":0},"members":[{"service":{"rid":"E9","rtype":"entertainment"}}]}]}]}"#)
    }

    /// Seed the caches with the exact verdict the device had cached when the
    /// Streaming row was disabled: "asked, answered, this bridge has nothing".
    private func seedStaleNoArea(bridgeID: String = "bridge-b") {
        orchestrator.testSeedEntertainmentCaches(
            bridgeID: bridgeID, configs: [], membership: [:], fetched: true)
    }

    /// Every mutating recorder on a bridge, as one comparable snapshot. Used
    /// where the claim is "nothing at all was written", which is only honest if
    /// every write surface is named.
    private func writeSnapshot(_ spy: RoutingSpyClient) -> [Int] {
        [spy.entertainmentActions.count,
         spy.groupedStateIDs.count,
         spy.groupedEffectIDs.count,
         spy.groupedPowerIDs.count,
         spy.lightEffectIDs.count,
         spy.v1EffectPuts.count,
         spy.v1Spy.creations.count,
         spy.v1Spy.deletedResources.count]
    }

    // ──────────────────────────────────────────────
    // Correction A — a cached verdict may not disable its own remedy
    // ──────────────────────────────────────────────

    /// P7F-01 — the exact device report: an Entertainment Area created in the
    /// Hue app while ChromaGlow was running. The cached answer was "no area",
    /// the row that would have refreshed it was disabled, and only a force-quit
    /// fixed it. The tap must re-read and stream the area that now exists.
    func testAStaleNoAreaVerdictIsRefreshedByTheTapAndStreamsTheNewArea() async throws {
        let vm = makeP7VM()
        seedStaleNoArea()
        XCTAssertEqual(orchestrator.entertainmentAvailability(for: streamRoomOnB()),
                       .noArea,
                       "the fixture must start from the verdict that disabled the row")

        // The user creates the area in the Hue app. Nothing tells us.
        stageStreamableBridge(bridgeB, active: [])
        let getsBefore = bridgeB.entertainmentConfigGets.count
        let lightsBefore = bridgeB.fetchLightsCallCount

        let party = try streamingCard(vm)
        await vm.apply(party, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)

        XCTAssertGreaterThan(bridgeB.entertainmentConfigGets.count, getsBefore,
            "the start must re-ask the bridge — answering from the cache is the defect")
        XCTAssertGreaterThan(bridgeB.fetchLightsCallCount, lightsBefore,
            "and re-read the lights the membership join needs")
        XCTAssertEqual(bridgeB.entertainmentStarts, ["area-b"],
            "the area that now exists is the area that streams, and the only one")

        let plan = try XCTUnwrap(orchestrator.testEntertainmentStartPlan(for: streamRoomOnB()),
            "the refreshed cache must resolve a plan")
        XCTAssertEqual(plan.config.id, "area-b", "the exact area, by id")
        XCTAssertEqual(plan.channelIDs, [0, 1], "with its channels ordered, not merely present")
    }

    /// P7F-02 — the other half of the same defect. The bridge always had an
    /// area; the user fixed its MEMBERSHIP in the Hue app. `.noMatchingArea` is
    /// just as cached, and just as stale.
    func testAStaleNoMatchingAreaVerdictIsRefreshedByTheTapAndUsesTheCorrectedArea() async throws {
        stageMismatchedMembership(bridgeB)
        let vm = makeP7VM()
        await orchestrator.warmEntertainmentCaches(for: streamRoomOnB(), force: true)
        XCTAssertEqual(orchestrator.entertainmentAvailability(for: streamRoomOnB()),
                       .noMatchingArea,
                       "an area exists, but it covers nothing in this room")

        // The user adds this room's lights to the area.
        stageStreamableBridge(bridgeB, active: [])
        let getsBefore = bridgeB.entertainmentConfigGets.count
        let lightsBefore = bridgeB.fetchLightsCallCount

        let party = try streamingCard(vm)
        await vm.apply(party, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)

        XCTAssertGreaterThan(bridgeB.entertainmentConfigGets.count, getsBefore,
            "the corrected membership can only be discovered by asking again")
        XCTAssertGreaterThan(bridgeB.fetchLightsCallCount, lightsBefore)
        XCTAssertEqual(bridgeB.entertainmentStarts, ["area-b"],
            "the corrected area streams — by id, not by luck of ordering")
        XCTAssertEqual(orchestrator.entertainmentAvailability(for: streamRoomOnB()),
                       .available(areaName: "Bedroom"),
                       "and the verdict the UI reads has moved with it")
    }

    /// P7F-03 — a stale "unavailable" plus another app's live session. The
    /// honest outcome is a QUESTION, not a refusal: the bridge can stream, it
    /// is simply busy. Reporting unavailability here is what made the takeover
    /// prompt unreachable on hardware.
    func testAStaleUnavailableVerdictOverAForeignSessionAsksInsteadOfRefusing() async throws {
        let vm = makeP7VM()
        seedStaleNoArea()
        stageStreamableBridge(bridgeB, active: ["cfg-someone-else"])

        let party = try streamingCard(vm)
        await vm.apply(party, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)

        let request = try XCTUnwrap(vm.foreignTakeoverRequest,
            "a foreign session means ASK — a cached “no area” must not swallow the question")
        XCTAssertEqual(request.foreignConfigID, "cfg-someone-else")
        XCTAssertEqual(request.targetConfigID, "area-b",
            "and the question names the area the fresh read found")
        XCTAssertNil(vm.studioNotice,
            "a question is not a refusal — no explanatory sentence may pre-empt it")
        XCTAssertTrue(foreignStops(bridgeB, "cfg-someone-else").isEmpty,
            "and the other app's show is untouched until the user answers")
        XCTAssertTrue(bridgeB.entertainmentStarts.isEmpty)
    }

    /// P7F-04 — the preflight is not a property of one card. Party and
    /// Thunderstorm reach it by the same route, so neither can be the hole
    /// through which a stale cache survives a tap.
    func testEveryStreamingEngineCardRefreshesTheCacheItCouldHaveTrusted() async throws {
        let vm = makeP7VM()
        seedStaleNoArea()
        stageStreamableBridge(bridgeB, active: [])

        let party = try streamingCard(vm)
        let partyGets = bridgeB.entertainmentConfigGets.count
        await vm.apply(party, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)
        XCTAssertGreaterThan(bridgeB.entertainmentConfigGets.count, partyGets,
            "Party re-read the bridge")
        XCTAssertEqual(bridgeB.entertainmentStarts, ["area-b"])

        // Stale again — exactly as it would be after any cache-invalidating edit.
        seedStaleNoArea()
        let thunderstorm = try XCTUnwrap(vm.liveModeCards.first { $0.id == "thunderstorm" },
            "the Thunderstorm card must exist for this claim to mean anything")
        let stormGets = bridgeB.entertainmentConfigGets.count
        let stormStarts = bridgeB.entertainmentStarts.count

        await vm.apply(thunderstorm, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)

        XCTAssertGreaterThan(bridgeB.entertainmentConfigGets.count, stormGets,
            "Thunderstorm re-read it too — the preflight cannot be bypassed per card")
        XCTAssertGreaterThan(bridgeB.entertainmentStarts.count, stormStarts,
            "and reached the same area through the same choke point")
        XCTAssertEqual(Set(bridgeB.entertainmentStarts), ["area-b"])
    }

    /// P7F-05 — with two areas on the bridge, the one the ROOM resolves to is
    /// the one that streams, and the other is never touched. A refresh that
    /// widened the inventory must not widen what we act on.
    func testWithTwoAreasOnlyTheRoomsOwnAreaIsEverStartedOrStopped() async throws {
        let vm = makeP7VM()
        seedStaleNoArea()
        stageTwoAreaBridge(bridgeB)

        let party = try streamingCard(vm)
        await vm.apply(party, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)

        XCTAssertEqual(bridgeB.entertainmentStarts, ["area-b"],
            "the room's own area, exactly once")
        XCTAssertFalse(bridgeB.entertainmentStarts.contains("area-far"),
            "the unrelated area is never started")
        XCTAssertFalse(bridgeB.entertainmentStops.contains("area-far"),
            "and never stopped either — it is none of this room's business")
        let plan = try XCTUnwrap(orchestrator.testEntertainmentStartPlan(for: streamRoomOnB()))
        XCTAssertEqual(plan.config.id, "area-b")
        XCTAssertEqual(plan.channelIDs, [0, 1])
    }

    // ── The refresh gesture bypasses the background throttle ──

    /// P7F-06 — pull-to-refresh. `loadAll`'s own availability pass is throttled
    /// to once a minute; a load seconds earlier must not turn a deliberate
    /// gesture into a no-op, or the stale verdict survives the very gesture
    /// that exists to clear it.
    func testPullToRefreshReReadsAvailabilityDespiteAJustCompletedPeriodicPass() async throws {
        stageStreamableBridge(bridgeB, areaID: "area-first", active: [])
        bridgeB.stageRooms([hueRoomB()])
        let vm = makeP7FVM()
        orchestrator.allRooms = [streamRoomOnB()]

        // Prime the throttle with a COMPLETED periodic pass.
        orchestrator.refreshEntertainmentAvailability(reason: .periodic)
        await orchestrator.testAwaitEntertainmentAvailabilityRefresh()
        XCTAssertEqual(orchestrator.testEntertainmentStartPlan(for: streamRoomOnB())?.config.id,
                       "area-first",
                       "the periodic pass really did fill the cache")

        // The user edits the area in the Hue app, then pulls to refresh.
        stageStreamableBridge(bridgeB, areaID: "area-second", active: [])
        let getsBefore = bridgeB.entertainmentConfigGets.count
        let lightsBefore = bridgeB.fetchLightsCallCount
        let effectsBefore = vm.runningEffects.count

        // Exactly the Dashboard `.refreshable` sequence, in its order.
        orchestrator.refreshEntertainmentAvailability(reason: .userInitiated)
        await orchestrator.testAwaitEntertainmentAvailabilityRefresh()

        XCTAssertGreaterThan(bridgeB.entertainmentConfigGets.count, getsBefore,
            "the gesture must re-ask even though a periodic pass just ran")
        XCTAssertGreaterThan(bridgeB.fetchLightsCallCount, lightsBefore,
            "including the lights the membership join depends on")
        XCTAssertEqual(orchestrator.testEntertainmentStartPlan(for: streamRoomOnB())?.config.id,
                       "area-second",
                       "and the cache now names the area that actually exists")

        await orchestrator.loadAll()
        await orchestrator.testAwaitEntertainmentAvailabilityRefresh()
        await orchestrator.testAwaitEntertainmentCleanup()

        XCTAssertTrue(bridgeB.entertainmentActions.isEmpty,
            "a refresh is GETs only — it may never start, stop, or take over anything")
        XCTAssertTrue(bridgeA.entertainmentActions.isEmpty)
        XCTAssertNil(vm.foreignTakeoverRequest, "and it may never ask the user a question")
        XCTAssertNil(vm.studioHandoffRequest)
        XCTAssertEqual(vm.runningEffects.count, effectsBefore,
            "nor move a single Now-Playing row")
    }

    /// P7F-07 — returning to the app. The most likely moment for the
    /// inventory to have changed behind our back is the moment the user comes
    /// back from the Hue app, and nothing used to re-ask then either.
    func testForegroundingReReadsAvailabilityDespiteAJustCompletedPeriodicPass() async throws {
        stageStreamableBridge(bridgeB, areaID: "area-first", active: [])
        let vm = makeP7FVM()
        orchestrator.allRooms = [streamRoomOnB()]

        orchestrator.refreshEntertainmentAvailability(reason: .periodic)
        await orchestrator.testAwaitEntertainmentAvailabilityRefresh()

        stageStreamableBridge(bridgeB, areaID: "area-second", active: [])

        // A second periodic pass IS throttled — which is what makes the
        // user-initiated bypass below a claim about the reason, not about time.
        let throttledGets = bridgeB.entertainmentConfigGets.count
        orchestrator.refreshEntertainmentAvailability(reason: .periodic)
        await orchestrator.testAwaitEntertainmentAvailabilityRefresh()
        XCTAssertEqual(bridgeB.entertainmentConfigGets.count, throttledGets,
            "the background throttle is real, so the bypass below is meaningful")

        let getsBefore = bridgeB.entertainmentConfigGets.count
        let lightsBefore = bridgeB.fetchLightsCallCount
        let effectsBefore = vm.runningEffects.count

        // Exactly the AppRootView scenePhase == .active sequence.
        orchestrator.refreshEntertainmentAvailability(reason: .userInitiated)
        await orchestrator.testAwaitEntertainmentAvailabilityRefresh()

        XCTAssertGreaterThan(bridgeB.entertainmentConfigGets.count, getsBefore,
            "the same throttle that suppressed the periodic pass must not eat this one")
        XCTAssertGreaterThan(bridgeB.fetchLightsCallCount, lightsBefore)
        XCTAssertEqual(orchestrator.testEntertainmentStartPlan(for: streamRoomOnB())?.config.id,
                       "area-second")
        XCTAssertTrue(bridgeB.entertainmentActions.isEmpty,
            "and it still wrote nothing at all")
        XCTAssertNil(vm.foreignTakeoverRequest)
        XCTAssertNil(vm.studioHandoffRequest)
        XCTAssertEqual(vm.runningEffects.count, effectsBefore)
    }

    /// P7F-08 — the unattended pass, end to end. `loadAll` schedules it on every
    /// load; if it can ask a question or move a session, the user is
    /// interrupted by something they never did.
    func testAnUnattendedLoadRefreshesAvailabilityAndChangesNothingElse() async throws {
        stageStreamableBridge(bridgeB, active: [])
        bridgeB.stageRooms([hueRoomB()])
        let vm = makeP7FVM()
        let ownedBefore = ownershipStore.isProcessOwned(bridgeID: "bridge-b", configID: "area-b")
        let persistedBefore = ownershipStore.isPersisted(bridgeID: "bridge-b", configID: "area-b")
        let writesBefore = writeSnapshot(bridgeB)

        await orchestrator.loadAll()
        await orchestrator.testAwaitEntertainmentAvailabilityRefresh()
        await orchestrator.testAwaitEntertainmentCleanup()

        XCTAssertEqual(orchestrator.allRooms.map(\.id), ["room-b"],
            "the pass had a real, streamable room in front of it")
        XCTAssertGreaterThan(bridgeB.entertainmentConfigGets.count, 0,
            "and it did look — silence here must mean restraint, not inaction")
        XCTAssertEqual(writeSnapshot(bridgeB), writesBefore,
            "yet not one byte was written to the bridge")
        XCTAssertTrue(bridgeA.entertainmentActions.isEmpty)
        XCTAssertNil(vm.foreignTakeoverRequest, "no prompt may come from a background pass")
        XCTAssertNil(vm.studioHandoffRequest)
        XCTAssertNil(vm.studioNotice, "nor an interrupting sentence")
        XCTAssertTrue(vm.runningEffects.isEmpty, "nor any playback")
        XCTAssertEqual(ownershipStore.isProcessOwned(bridgeID: "bridge-b", configID: "area-b"),
                       ownedBefore, "and ownership records are exactly as they were")
        XCTAssertEqual(ownershipStore.isPersisted(bridgeID: "bridge-b", configID: "area-b"),
                       persistedBefore)
    }

    // ── What each preflight verdict actually says and does ────

    /// P7F-09 — nowhere to stream. Room mode is the honest answer and still
    /// starts; what was missing was the sentence. An explicit "stream this"
    /// that silently became room mode looked exactly like a misfired tap.
    func testNoStreamableAreaNamesRoomModeAndStillStartsRoomMode() async throws {
        bridgeB.stageLights([p7Light("L1", device: "D1"), p7Light("L2", device: "D2")])
        bridgeB.stageEntertainmentServices(#"{"data":[]}"#)
        bridgeB.stageEntertainmentConfigs(#"{"data":[]}"#)
        let vm = makeP7FVM()
        let composition = p7fComposition(vm)

        await vm.apply(composition.card, roomOverride: streamRoomOnB(),
                       preferEntertainmentOverride: true)

        XCTAssertEqual(vm.studioNotice?.message, EntertainmentAvailabilityCopy.noCompatibleArea,
            "the fallback is stated, and the sentence names Room mode")
        XCTAssertTrue(vm.studioNotice?.message.contains("Room mode") == true,
            "an explanation that omits the transport change explains nothing")
        XCTAssertNotNil(vm.runningEffects[streamRoomOnB().id],
            "…and Room mode really does start — an explained fallback is still a fallback")
        XCTAssertEqual(orchestrator.testCompositionTransport(roomID: streamRoomOnB().id), .rest,
            "on the REST transport, which is what Room mode means")
        XCTAssertTrue(bridgeB.entertainmentActions.isEmpty,
            "and no session was ever attempted")
    }

    /// P7F-10 — unreadable. Unknown is not "free" and it is not "broken
    /// either": it authorizes nothing, so the look already playing survives
    /// untouched and no new runtime appears.
    func testAnUnreadableVerdictExplainsItselfAndPreservesTheRunningLook() async throws {
        stageStreamableBridge(bridgeB, active: [])
        let vm = makeP7FVM()
        let composition = p7fComposition(vm)

        // Something is already playing, so a premature teardown would show.
        let party = try streamingCard(vm)
        await vm.apply(party, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)
        let running = try XCTUnwrap(vm.runningEffects[streamRoomOnB().id])
        let transportBefore = orchestrator.testCompositionTransport(roomID: streamRoomOnB().id)

        bridgeB.entertainmentConfigsShouldFail = true
        await vm.apply(composition.card, roomOverride: streamRoomOnB(),
                       preferEntertainmentOverride: true)

        XCTAssertEqual(vm.studioNotice?.message, EntertainmentAvailabilityCopy.couldNotCheck,
            "the refusal is rendered, not written to a field nothing reads")
        XCTAssertEqual(vm.runningEffects[streamRoomOnB().id]?.cardID, running.cardID,
            "the look that was playing is still the one playing")
        XCTAssertEqual(orchestrator.testCompositionTransport(roomID: streamRoomOnB().id),
                       transportBefore,
            "and no new runtime was opened under it")
        XCTAssertFalse(orchestrator.testHasPendingEntertainmentCandidate(),
            "nothing was left prepared and uncommitted")
    }

    /// P7F-11 — several controllers at once. There is no single session to
    /// name, so there is no honest question; failing closed must cost exactly
    /// zero writes.
    func testAnAmbiguousVerdictExplainsItselfAndWritesNothingAtAll() async throws {
        stageStreamableBridge(bridgeB, active: ["cfg-one", "cfg-two"])
        let vm = makeP7FVM()
        let composition = p7fComposition(vm)
        let writesBefore = writeSnapshot(bridgeB)

        await vm.apply(composition.card, roomOverride: streamRoomOnB(),
                       preferEntertainmentOverride: true)

        XCTAssertEqual(vm.studioNotice?.message, EntertainmentConsentCopy.takeoverFailed,
            "failing closed is still an answer the user is owed")
        XCTAssertNil(vm.foreignTakeoverRequest,
            "and there is no single session to ask about")
        XCTAssertEqual(writeSnapshot(bridgeB), writesBefore,
            "zero PUTs of any kind — no start, no stop, no room-mode write")
        XCTAssertNil(vm.runningEffects[streamRoomOnB().id])
        XCTAssertNil(orchestrator.testCompositionTransport(roomID: streamRoomOnB().id),
            "and no runtime was created")
    }

    /// P7F-12 — the bridge was free, the plan was valid, and the session still
    /// would not open. Carrying on would start REST under a look the user
    /// explicitly asked to STREAM. That silent demotion is the report this
    /// packet exists to answer.
    func testAnUnavailableVerdictUnderAnExplicitRequestRefusesInsteadOfDemoting() async throws {
        stageStreamableBridge(bridgeB, active: [])
        let vm = makeP7FVM()
        let composition = p7fComposition(vm)

        await vm.apply(composition.card, roomOverride: streamRoomOnB(),
                       preferEntertainmentOverride: true)
        await orchestrator.testAwaitEntertainmentRollback()

        XCTAssertEqual(vm.studioNotice?.message, EntertainmentAvailabilityCopy.couldNotStart,
            "the refusal is stated")
        XCTAssertNil(vm.runningEffects[streamRoomOnB().id],
            "and nothing plays — an explicit stream request is not satisfied by room mode")
        XCTAssertNil(orchestrator.testCompositionTransport(roomID: streamRoomOnB().id),
            "no REST composition runtime stands in for the stream that failed")
        XCTAssertTrue(bridgeB.groupedEffectIDs.isEmpty && bridgeB.lightEffectIDs.isEmpty,
            "and no REST frames were sent")
        XCTAssertFalse(orchestrator.testHasPendingEntertainmentCandidate(),
            "the attempt left nothing outstanding")
    }

    // ──────────────────────────────────────────────
    // Correction B — a ChromaGlow look already owns this bridge
    // ──────────────────────────────────────────────

    /// P7F-13 (B1) — the collision is detected BEFORE acquisition. The defect
    /// was a second session opened on a bridge we were already streaming.
    func testACompositionOverOurOwnStreamingLookAsksBeforeOpeningASecondSession() async throws {
        stageStreamableBridge(bridgeB, active: [])
        let vm = makeP7FVM()
        let composition = p7fComposition(vm)
        let owner = await installStudioOwner(
            spy: bridgeB, bridgeID: "bridge-b", roomID: "room-b-strobe",
            engineKey: "strobe", configID: "area-owner")
        let startsBefore = bridgeB.entertainmentStarts.count

        await vm.apply(composition.card, roomOverride: streamRoomOnB(),
                       preferEntertainmentOverride: true)

        let request = try XCTUnwrap(vm.studioHandoffRequest,
            "our own streaming look must raise the ChromaGlow-owned question")
        XCTAssertEqual(request.owner, owner, "named by whole value, not by bridge alone")
        XCTAssertEqual(request.runningLookName, "Strobe")
        XCTAssertEqual(request.requestedLookName, "Aurora Drift")
        XCTAssertEqual(bridgeB.entertainmentStarts.count, startsBefore,
            "and NO second session was opened — that is the whole defect")
        XCTAssertNil(vm.foreignTakeoverRequest,
            "our own look is not a third party; the two questions stay distinct")
        XCTAssertNil(vm.runningEffects[streamRoomOnB().id])
        XCTAssertNotNil(orchestrator.testStudioEntertainmentOwner(onBridge: "bridge-b"),
            "the owner still holds the bridge while the prompt is open")
    }

    /// P7F-14 (B2) — the two consents are two concepts with two ledgers. One
    /// authorizes replacing ANOTHER app's session; the other authorizes
    /// stopping our own look. Sharing a set would let either answer spend the
    /// other's token.
    func testTheStudioHandoffAndForeignConsentLedgersStayDisjoint() async throws {
        stageStreamableBridge(bridgeB, active: [])
        let vm = makeP7FVM()
        let composition = p7fComposition(vm)
        await installStudioOwner(spy: bridgeB, bridgeID: "bridge-b",
                                 roomID: "room-b-strobe", engineKey: "strobe",
                                 configID: "area-owner")

        await vm.apply(composition.card, roomOverride: streamRoomOnB(),
                       preferEntertainmentOverride: true)
        let requestID = try XCTUnwrap(vm.studioHandoffRequest?.id)
        await vm.confirmStudioHandoff()

        XCTAssertTrue(orchestrator.consumedStudioHandoffRequests.contains(requestID),
            "the Switch answer is spent in its own ledger")
        XCTAssertTrue(orchestrator.consumedEntertainmentConsents.isEmpty,
            "and no third-party consent was minted or spent — nobody asked for one")
        XCTAssertTrue(orchestrator.consumedStudioHandoffRequests
            .isDisjoint(with: orchestrator.consumedEntertainmentConsents),
            "the two ledgers may never intersect")

        // Shape, because behaviour alone would still pass if one call site
        // reached across into the other concept.
        let orchestratorSource = try productionCode("HueHome/Core/Network/UnifiedOrchestrator.swift")
        let resolveBody = try XCTUnwrap(
            functionBody(orchestratorSource, startingWith: "func resolveStudioHandoff("))
            .joined(separator: "\n")
        XCTAssertFalse(resolveBody.contains("EntertainmentConsent("),
            "the ChromaGlow-owned handoff must never mint a third-party consent")
        XCTAssertFalse(resolveBody.contains("consumedEntertainmentConsents"),
            "nor read or write the third-party ledger")
        XCTAssertTrue(resolveBody.contains("consumedStudioHandoffRequests"),
            "it spends its OWN token, before the first await")

        let vmSource = try productionCode("HueHome/UI/Studio/StudioViewModel.swift")
        let confirmBody = try XCTUnwrap(
            functionBody(vmSource, startingWith: "func confirmStudioHandoff("))
            .joined(separator: "\n")
        XCTAssertFalse(confirmBody.contains("foreignTakeoverRequest"),
            "and confirming a Switch must not touch the Take Over slot")
    }

    /// P7F-15 (B3) — the requested composition's plan is frozen BEFORE the user
    /// is asked. A bare configuration id would let the area be deleted or
    /// re-scoped under the open prompt and still be replayed on the way out.
    func testTheRequestedCompositionsPlanIsFrozenBeforeTheUserIsAsked() async throws {
        stageStreamableBridge(bridgeB, active: [])
        let vm = makeP7FVM()
        let composition = p7fComposition(vm)
        await installStudioOwner(spy: bridgeB, bridgeID: "bridge-b",
                                 roomID: "room-b-strobe", engineKey: "strobe",
                                 configID: "area-owner")

        await vm.apply(composition.card, roomOverride: streamRoomOnB(),
                       preferEntertainmentOverride: true)

        let plan = try XCTUnwrap(vm.studioHandoffRequest?.plan)
        XCTAssertEqual(plan.bridgeID, "bridge-b")
        XCTAssertEqual(plan.roomID, streamRoomOnB().id)
        XCTAssertEqual(plan.targetConfigID, "area-b",
            "the REQUESTED composition's area, not the owner's")
        XCTAssertEqual(plan.channelIDs, [0, 1], "ordered, not just present")
        XCTAssertEqual(plan.channels.map(\.id), [0, 1])
        XCTAssertEqual(plan.channels.map(\.members), [["E1"], ["E2"]],
            "which services each channel drives is part of the frozen plan")
        XCTAssertEqual(plan.channels.map(\.x), [0, 0])
        XCTAssertEqual(plan.channels.map(\.y), [0, 0])
        XCTAssertEqual(plan.channels.map(\.z), [0, 0])
        XCTAssertEqual(plan.capturedConfig.id, "area-b")
        XCTAssertEqual(plan.capturedConfig.channels.map(\.id), [0, 1],
            "and the render loop is handed exactly that, rebuilt from the capture")
    }

    /// P7F-16 (B4) — an open prompt is a question, not a commitment. Nothing
    /// may be stopped, prepared, published, or recorded while it waits.
    func testNothingIsStoppedPreparedOrPublishedWhileTheStudioPromptIsOpen() async throws {
        stageStreamableBridge(bridgeB, active: [])
        let vm = makeP7FVM()
        let composition = p7fComposition(vm)
        let owner = await installStudioOwner(
            spy: bridgeB, bridgeID: "bridge-b", roomID: "room-b-strobe",
            engineKey: "strobe", configID: "area-owner")

        let actionsBefore = bridgeB.entertainmentActions.count
        let nowPlayingBefore = orchestrator.activeEffectEntries
        let ownerRowBefore = vm.runningEffects[owner.roomID]?.cardID
        let candidateBefore = orchestrator.testHasPendingEntertainmentCandidate()
        let processOwnedBefore = ownershipStore.isProcessOwned(
            bridgeID: "bridge-b", configID: "area-owner")
        let persistedBefore = ownershipStore.isPersisted(
            bridgeID: "bridge-b", configID: "area-owner")

        await vm.apply(composition.card, roomOverride: streamRoomOnB(),
                       preferEntertainmentOverride: true)
        XCTAssertNotNil(vm.studioHandoffRequest, "the prompt is open")

        XCTAssertEqual(bridgeB.entertainmentActions.count, actionsBefore,
            "no stop and no start may precede the answer")
        XCTAssertEqual(orchestrator.activeEffectEntries, nowPlayingBefore,
            "Now Playing is unchanged, row for row")
        XCTAssertEqual(vm.runningEffects[owner.roomID]?.cardID, ownerRowBefore,
            "the owning look's registry row is untouched")
        XCTAssertEqual(orchestrator.testHasPendingEntertainmentCandidate(), candidateBefore,
            "nothing was prepared")
        XCTAssertEqual(ownershipStore.isProcessOwned(bridgeID: "bridge-b", configID: "area-owner"),
                       processOwnedBefore, "and ownership did not move")
        XCTAssertEqual(ownershipStore.isPersisted(bridgeID: "bridge-b", configID: "area-owner"),
                       persistedBefore)
        XCTAssertNotNil(orchestrator.testStudioEntertainmentOwner(onBridge: "bridge-b"))
    }

    /// P7F-17 (B5) — Keep Playing. The request was raised before anything was
    /// touched, so forgetting it IS the whole undo.
    func testCancellingTheStudioHandoffWritesNothingAndKeepsTheLookPlaying() async throws {
        stageStreamableBridge(bridgeB, active: [])
        let vm = makeP7FVM()
        let composition = p7fComposition(vm)
        await installStudioOwner(spy: bridgeB, bridgeID: "bridge-b",
                                 roomID: "room-b-strobe", engineKey: "strobe",
                                 configID: "area-owner")
        await vm.apply(composition.card, roomOverride: streamRoomOnB(),
                       preferEntertainmentOverride: true)
        XCTAssertNotNil(vm.studioHandoffRequest)
        let writesBefore = writeSnapshot(bridgeB)

        vm.cancelStudioHandoff()

        XCTAssertNil(vm.studioHandoffRequest, "the request is consumed")
        XCTAssertEqual(writeSnapshot(bridgeB), writesBefore,
            "Keep Playing means the running look is never touched")
        XCTAssertNotNil(orchestrator.testStudioEntertainmentOwner(onBridge: "bridge-b"),
            "it still owns the bridge")
        XCTAssertNil(vm.runningEffects[streamRoomOnB().id],
            "and the requested composition does not start")
        XCTAssertTrue(orchestrator.consumedStudioHandoffRequests.isEmpty,
            "a declined question spends no token — the user may ask again")
    }

    /// P7F-18 (B5b) — a stray dismissal with no prompt pending must be inert.
    func testCancellingTheStudioHandoffIsIdempotentWithNoPromptPending() async {
        stageStreamableBridge(bridgeB, active: [])
        _ = makeP7FVM()
        await installStudioOwner(spy: bridgeB, bridgeID: "bridge-b",
                                 roomID: "room-b-strobe", engineKey: "strobe",
                                 configID: "area-owner")
        let vm = StudioViewModel()
        vm.configure(orchestrator: orchestrator)

        vm.cancelStudioHandoff()
        vm.cancelStudioHandoff()

        XCTAssertNil(vm.studioHandoffRequest)
        XCTAssertTrue(bridgeB.entertainmentActions.isEmpty,
            "a dismissal nobody asked for must never stop a look nobody named")
        XCTAssertNotNil(orchestrator.testStudioEntertainmentOwner(onBridge: "bridge-b"))
    }

    /// P7F-19 (B6) — Switch: stop exactly the named look, exactly once, and
    /// only then ask the bridge for the composition's own session.
    func testConfirmingTheStudioHandoffStopsTheOwningLookOnceThenStartsTheComposition() async throws {
        stageStreamableBridge(bridgeB, active: [])
        stageStreamableBridge(bridgeA, active: [])
        let vm = makeP7FVM()
        let composition = p7fComposition(vm)
        await installStudioOwner(spy: bridgeB, bridgeID: "bridge-b",
                                 roomID: "room-b-strobe", engineKey: "strobe",
                                 configID: "area-owner")
        await vm.apply(composition.card, roomOverride: streamRoomOnB(),
                       preferEntertainmentOverride: true)
        XCTAssertTrue(bridgeB.entertainmentActions.isEmpty, "nothing yet")

        await vm.confirmStudioHandoff()
        await orchestrator.testAwaitEntertainmentRollback()

        XCTAssertNil(vm.studioHandoffRequest, "no second prompt")
        XCTAssertEqual(bridgeB.entertainmentStops.filter { $0 == "area-owner" }, ["area-owner"],
            "exactly the look the user named, stopped exactly once")
        XCTAssertEqual(bridgeB.entertainmentActions.first.map { [$0.configID, $0.action] },
                       ["area-owner", "stop"],
            "and the stop comes FIRST — the bridge is released before it is re-asked")
        // The composition's own `action=start` is the +1. (Its DTLS open then
        // fails on this suite's deliberately non-hex client key, which sends
        // the L-11 compensating stop for area-b — our own, and unrelated to
        // the look the user replaced.)
        XCTAssertEqual(bridgeB.entertainmentStarts, ["area-b"],
            "exactly one start, on the frozen plan's area")
        XCTAssertNil(orchestrator.testStudioEntertainmentOwner(onBridge: "bridge-b"),
            "the stopped look no longer claims the bridge")
        XCTAssertTrue(bridgeA.entertainmentActions.isEmpty,
            "and the other bridge was never addressed")
    }

    /// P7F-20 (B6b) — the token is spent before the first await, so a
    /// double-tap while the teardown is in flight finds nothing to do.
    func testDoubleConfirmingTheStudioHandoffCannotDoubleStopOrDoubleStart() async throws {
        stageStreamableBridge(bridgeB, active: [])
        let vm = makeP7FVM()
        let composition = p7fComposition(vm)
        await installStudioOwner(spy: bridgeB, bridgeID: "bridge-b",
                                 roomID: "room-b-strobe", engineKey: "strobe",
                                 configID: "area-owner")
        await vm.apply(composition.card, roomOverride: streamRoomOnB(),
                       preferEntertainmentOverride: true)

        await vm.confirmStudioHandoff()
        await vm.confirmStudioHandoff()
        await vm.confirmStudioHandoff()
        await orchestrator.testAwaitEntertainmentRollback()

        XCTAssertEqual(bridgeB.entertainmentStops.filter { $0 == "area-owner" }, ["area-owner"],
            "one stop, however many taps")
        XCTAssertEqual(bridgeB.entertainmentStarts, ["area-b"], "and one start")
        XCTAssertEqual(orchestrator.consumedStudioHandoffRequests.count, 1,
            "one answer, one spent token")
    }

    /// P7F-21 (B7) — a DIFFERENT one of our looks owns the bridge by the time
    /// the answer arrives. The user agreed to stop one specific look, not
    /// whatever came next: stop nothing and ask again, with a fresh identity.
    func testAnOwnerThatChangedWhileThePromptWasOpenStopsNothingAndAsksAgain() async throws {
        stageStreamableBridge(bridgeB, active: [])
        let vm = makeP7FVM()
        let composition = p7fComposition(vm)
        await installStudioOwner(spy: bridgeB, bridgeID: "bridge-b",
                                 roomID: "room-b-strobe", engineKey: "strobe",
                                 configID: "area-owner")
        await vm.apply(composition.card, roomOverride: streamRoomOnB(),
                       preferEntertainmentOverride: true)
        let firstRequestID = try XCTUnwrap(vm.studioHandoffRequest?.id)

        // Swapped synchronously on the main actor between prompt and answer —
        // no timing, just call order.
        let replacement = await installStudioOwner(
            spy: bridgeB, bridgeID: "bridge-b", roomID: "room-b-party",
            engineKey: "party", configID: "area-owner-2")

        await vm.confirmStudioHandoff()

        XCTAssertTrue(bridgeB.entertainmentStops.isEmpty,
            "a consent that named one look may not be spread onto its successor")
        XCTAssertTrue(bridgeB.entertainmentStarts.isEmpty,
            "and nothing may start over a look nobody agreed to replace")
        let fresh = try XCTUnwrap(vm.studioHandoffRequest,
            "a fresh decision is required")
        XCTAssertNotEqual(fresh.id, firstRequestID,
            "with its own id, and therefore its own token")
        XCTAssertEqual(fresh.owner, replacement, "naming the look that is actually running")
        XCTAssertEqual(fresh.owner.engineKey, "party")
        XCTAssertEqual(fresh.requestedLookName, "Aurora Drift",
            "the request the user made is preserved across the re-ask")
    }

    /// P7F-22 (B8) — the stop was issued and the session did NOT release. The
    /// only honest response is to start nothing: opening the composition here
    /// would put a second stream on the bridge, which is the exact defect this
    /// correction exists to prevent.
    ///
    /// The non-release is staged the way production actually produces it: a
    /// composition claims the bridge's session while the prompt is open, and
    /// the app-driven teardown then deliberately leaves that session alone.
    func testAStopThatDidNotReleaseStartsNothingAndKeepsTheOwnershipEvidence() async throws {
        stageStreamableBridge(bridgeB, active: [])
        let vm = makeP7FVM()
        let composition = p7fComposition(vm)
        await installStudioOwner(spy: bridgeB, bridgeID: "bridge-b",
                                 roomID: "room-b-strobe", engineKey: "strobe",
                                 configID: "area-owner")
        await vm.apply(composition.card, roomOverride: streamRoomOnB(),
                       preferEntertainmentOverride: true)
        XCTAssertNotNil(vm.studioHandoffRequest)

        // A composition takes the bridge's session while the prompt waits, so
        // the room-scoped app-driven stop must not release it.
        orchestrator.testStageEntertainmentOwner(roomID: "room-b-composition",
                                                 bridgeID: "bridge-b")
        let startsBefore = bridgeB.entertainmentStarts.count

        await vm.confirmStudioHandoff()

        XCTAssertEqual(vm.studioNotice?.message, EntertainmentHandoffCopy.stopFailed,
            "never claim a switch that did not happen")
        XCTAssertEqual(bridgeB.entertainmentStarts.count, startsBefore,
            "and start nothing on top of a session that is still live")
        XCTAssertNotNil(orchestrator.testStudioEntertainmentOwner(onBridge: "bridge-b"),
            "the ownership evidence is kept — a still-running owner must stay visible")
        XCTAssertNil(vm.runningEffects[streamRoomOnB().id],
            "and the requested composition did not start")
        XCTAssertNil(vm.studioHandoffRequest, "the answer was consumed, not replayed")
    }

    /// P7F-23 (B9) — the stop succeeded, the bridge is free, and the
    /// composition still cannot stream. That is reported, never silently
    /// demoted to REST underneath whatever else is on the bridge.
    func testACompositionThatCannotStreamAfterTheSwitchIsReportedNotDemoted() async throws {
        stageStreamableBridge(bridgeB, active: [])
        let vm = makeP7FVM()
        let composition = p7fComposition(vm)
        await installStudioOwner(spy: bridgeB, bridgeID: "bridge-b",
                                 roomID: "room-b-strobe", engineKey: "strobe",
                                 configID: "area-owner")
        await vm.apply(composition.card, roomOverride: streamRoomOnB(),
                       preferEntertainmentOverride: true)

        await vm.confirmStudioHandoff()
        await orchestrator.testAwaitEntertainmentRollback()

        XCTAssertEqual(vm.studioNotice?.message, EntertainmentAvailabilityCopy.couldNotStart,
            "the user asked to stream; they are told it did not")
        XCTAssertNil(vm.runningEffects[streamRoomOnB().id],
            "no Now-Playing row for a look that is not playing")
        XCTAssertNil(orchestrator.testCompositionTransport(roomID: streamRoomOnB().id),
            "and no REST composition runtime stood in for the stream")
        XCTAssertTrue(bridgeB.groupedEffectIDs.isEmpty && bridgeB.lightEffectIDs.isEmpty,
            "no REST frames were sent at all")
        XCTAssertFalse(orchestrator.testHasPendingEntertainmentCandidate())
    }

    /// P7F-24 (B10) — an owner on bridge A is not a fact about bridge B. The
    /// lockout defect wears a prompt just as easily as a refusal.
    func testAnOwnerOnOneBridgeNeitherBlocksNorPromptsForACompositionOnAnother() async throws {
        stageStreamableBridge(bridgeA, active: [])
        stageStreamableBridge(bridgeB, active: [])
        let vm = makeP7FVM()
        let composition = p7fComposition(vm)
        await installStudioOwner(spy: bridgeA, bridgeID: "bridge-a",
                                 roomID: "room-a-strobe", engineKey: "strobe",
                                 configID: "area-owner-a")

        await vm.apply(composition.card, roomOverride: streamRoomOnB(),
                       preferEntertainmentOverride: true)
        await orchestrator.testAwaitEntertainmentRollback()

        XCTAssertNil(vm.studioHandoffRequest,
            "bridge A's owner may not gate a composition on bridge B")
        XCTAssertEqual(bridgeB.entertainmentStarts, ["area-b"],
            "the composition reached the choke point and asked bridge B for its own session")
        XCTAssertTrue(bridgeA.entertainmentActions.isEmpty,
            "and bridge A was never addressed")
        XCTAssertNotNil(orchestrator.testStudioEntertainmentOwner(onBridge: "bridge-a"),
            "its owner is exactly as it was")
    }

    /// P7F-25 (B10, the other direction) — a confirmation for bridge A may not
    /// reach bridge B, however similar their rooms look.
    func testConfirmingAHandoffOnOneBridgeStopsNothingOnTheOther() async throws {
        stageStreamableBridge(bridgeA, active: [])
        stageStreamableBridge(bridgeB, active: [])
        let vm = makeP7FVM()
        let composition = p7fComposition(vm)
        await installStudioOwner(spy: bridgeA, bridgeID: "bridge-a",
                                 roomID: "room-a-strobe", engineKey: "strobe",
                                 configID: "area-owner-a")
        await installStudioOwner(spy: bridgeB, bridgeID: "bridge-b",
                                 roomID: "room-b-strobe", engineKey: "strobe",
                                 configID: "area-owner-b")
        await vm.apply(composition.card, roomOverride: streamRoomOnA(),
                       preferEntertainmentOverride: true)
        XCTAssertEqual(vm.studioHandoffRequest?.owner.bridgeID, "bridge-a")
        let bridgeBWritesBefore = writeSnapshot(bridgeB)

        await vm.confirmStudioHandoff()
        await orchestrator.testAwaitEntertainmentRollback()

        XCTAssertEqual(bridgeA.entertainmentStops.filter { $0 == "area-owner-a" },
                       ["area-owner-a"], "bridge A's look stopped")
        XCTAssertEqual(writeSnapshot(bridgeB), bridgeBWritesBefore,
            "and bridge B saw nothing at all")
        XCTAssertNotNil(orchestrator.testStudioEntertainmentOwner(onBridge: "bridge-b"),
            "its owner still holds it")
    }

    /// P7F-26 (B11) — the pre-existing composition → Studio handoff is a
    /// different question with a different answer, and this correction must
    /// leave it exactly as it was.
    func testTheExistingCompositionToStudioHandoffIsUnchangedByThisCorrection() async throws {
        let (vm, _) = makeVMWithComposerOwningBridgeB()
        let ambient = try liveModeCard(vm, "ambient")

        await vm.apply(ambient, roomOverride: roomOnBridgeB(), preferEntertainmentOverride: nil)
        XCTAssertNotNil(vm.entertainmentHandoffPrompt,
            "the composition-owned prompt still appears")
        XCTAssertNil(vm.studioHandoffRequest,
            "and the new ChromaGlow-owned slot stays empty — a composition is not an app-driven look")

        await vm.confirmEntertainmentHandoff()
        defer { Task { await orchestrator.stopStudioMode() } }

        XCTAssertNil(vm.entertainmentHandoffPrompt)
        XCTAssertNil(orchestrator.compositionOwningEntertainment(onBridge: "bridge-b"),
            "confirm still clears Entertainment ownership")
        XCTAssertNil(orchestrator.compositionTransportByRoom["room-b-composer"],
            "and still clears transport truth")
        XCTAssertNil(vm.runningEffects["room-b-composer"],
            "the composition still leaves the Now-Playing registry")
        XCTAssertEqual(vm.runningEffects["room-b"]?.cardID, "ambient",
            "…and only then does the requested Studio look start")
        XCTAssertTrue(orchestrator.testCanAcquireEntertainment(onBridge: "bridge-b"))
        XCTAssertNil(vm.studioHandoffRequest,
            "the new slot was never touched at any point in the flow")
        XCTAssertTrue(orchestrator.consumedStudioHandoffRequests.isEmpty,
            "and the new ledger recorded nothing")
    }

    /// P7F-27 (B12) — a packet 8 recovered bridge-stored animation runs on the
    /// bridge's own firmware. It installs no `studioEntClients` entry, so it
    /// can never be mistaken for a live DTLS owner — which would ask the user
    /// to "stop Strobe" about a rule chain.
    func testARecoveredBridgeStoredAnimationIsNotAnAppDrivenEntertainmentOwner() async throws {
        orchestrator.allRooms = [streamRoomOnB(), streamRoomOnB(id: "room-b2")]
        stageStreamableBridge(bridgeB, active: [])
        let manifest = stageManifest(
            roomID: "room-b2", bridgeIP: "192.0.2.2", bridgeID: "bridge-b",
            presetName: "Sunset Drift",
            sensorID: "S1", ruleIDs: ["R1"], scheduleID: "SC1", resourcelinkID: "L1")
        stageLive(bridgeB.v1Spy, [manifest])
        let vm = makeP7FVM()
        let composition = p7fComposition(vm)

        await orchestrator.testReconcileBridgeStoredAnimations()
        XCTAssertEqual(recoveredEntries().count, 1, "the animation was recovered")
        XCTAssertNil(orchestrator.testStudioEntertainmentOwner(onBridge: "bridge-b"),
            "…and it owns no Entertainment session, by construction")

        let recoveredBefore = recoveredEntries().count
        let generationBefore = orchestrator.testRoomOwnershipGeneration(
            bridgeID: "bridge-b", roomID: "room-b2")

        await vm.apply(composition.card, roomOverride: streamRoomOnB(),
                       preferEntertainmentOverride: true)
        await orchestrator.testAwaitEntertainmentRollback()

        XCTAssertNil(vm.studioHandoffRequest,
            "so no ChromaGlow-owned question is asked about it")
        XCTAssertEqual(recoveredEntries().count, recoveredBefore,
            "and the recovered row survives the composition start")
        XCTAssertEqual(orchestrator.testRoomOwnershipGeneration(bridgeID: "bridge-b",
                                                               roomID: "room-b2"),
                       generationBefore,
            "with its ownership generation unmoved")
        XCTAssertTrue(storeStillHolds(manifest), "and its manifest intact")
    }

    /// P7F-28 (B12b) — the replay clears the Studio mirror of the look it just
    /// stopped. A recovered row keyed by its MANIFEST must be structurally
    /// unreachable from that room-keyed removal, even when the two share a
    /// room id.
    func testAConfirmedStudioHandoffNeverClearsARecoveredNowPlayingRow() async throws {
        orchestrator.allRooms = [streamRoomOnB(), streamRoomOnB(id: "room-b-strobe")]
        stageStreamableBridge(bridgeB, active: [])
        // Deliberately the SAME room id as the app-driven owner below.
        let manifest = stageManifest(
            roomID: "room-b-strobe", bridgeIP: "192.0.2.2", bridgeID: "bridge-b",
            presetName: "Sunset Drift",
            sensorID: "S1", ruleIDs: ["R1"], scheduleID: "SC1", resourcelinkID: "L1")
        stageLive(bridgeB.v1Spy, [manifest])
        let vm = makeP7FVM()
        let composition = p7fComposition(vm)

        await orchestrator.testReconcileBridgeStoredAnimations()
        XCTAssertEqual(recoveredEntries().count, 1)

        await installStudioOwner(spy: bridgeB, bridgeID: "bridge-b",
                                 roomID: "room-b-strobe", engineKey: "strobe",
                                 configID: "area-owner")
        await vm.apply(composition.card, roomOverride: streamRoomOnB(),
                       preferEntertainmentOverride: true)
        XCTAssertEqual(vm.studioHandoffRequest?.owner.roomID, "room-b-strobe")

        await vm.confirmStudioHandoff()
        await orchestrator.testAwaitEntertainmentRollback()

        XCTAssertEqual(bridgeB.entertainmentStops.filter { $0 == "area-owner" }, ["area-owner"],
            "the app-driven look was stopped")
        XCTAssertEqual(recoveredEntries().count, 1,
            "and the recovered row — keyed by manifest, not by room — survived")
        XCTAssertEqual(recoveredEntries().first?.recovered, recoveredKey(manifest, "bridge-b"))
        XCTAssertNotNil(orchestrator.testRecoveredBridgeAnimations()[recoveredKey(manifest, "bridge-b")],
            "the bridge-stored animation is still tracked")
        XCTAssertTrue(storeStillHolds(manifest),
            "and its manifest was never swept")
        XCTAssertTrue(bridgeB.v1Spy.deletedResources.isEmpty,
            "nothing of the firmware animation was deleted")
    }

    /// P7F-29 (B-foreign) — the ChromaGlow-owned switch and the third-party
    /// takeover are two questions, and answering the first is not an answer to
    /// the second. A stranger claiming the bridge in the window between our own
    /// look's stop and the composition's start must surface as its own
    /// question — never as a stop nobody consented to, and never as REST
    /// playing underneath someone else's show.
    ///
    /// The stranger is injected by the bridge's OWN post-stop rewrite (the
    /// existing `stageDeactivationOnStop` seam), so it arrives at exactly the
    /// moment the `action=stop` lands: after the switch, before preparation.
    /// Order, not timing.
    func testAForeignSessionAppearingAfterTheSwitchRaisesItsOwnQuestion() async throws {
        stageStreamableBridge(bridgeB, active: [])
        let vm = makeP7FVM()
        let composition = p7fComposition(vm)
        await installStudioOwner(spy: bridgeB, bridgeID: "bridge-b",
                                 roomID: "room-b-strobe", engineKey: "strobe",
                                 configID: "area-owner")
        await vm.apply(composition.card, roomOverride: streamRoomOnB(),
                       preferEntertainmentOverride: true)
        XCTAssertNotNil(vm.studioHandoffRequest)

        // The moment our own stop lands, a third party claims the bridge.
        bridgeB.stageDeactivationOnStop { _ in
            Self.configsJSON(areaID: "area-b", active: ["cfg-late"])
        }

        await vm.confirmStudioHandoff()
        await orchestrator.testAwaitEntertainmentRollback()

        XCTAssertEqual(bridgeB.entertainmentStops.filter { $0 == "area-owner" }, ["area-owner"],
            "our own look was stopped exactly once, as consented")
        XCTAssertTrue(foreignStops(bridgeB, "cfg-late").isEmpty,
            "and the stranger was never stopped — this consent did not name them")
        XCTAssertTrue(bridgeB.entertainmentStarts.isEmpty,
            "the composition did not start over them")
        XCTAssertNil(vm.runningEffects[streamRoomOnB().id],
            "and no REST fallback ran underneath their show")
        XCTAssertNil(orchestrator.testCompositionTransport(roomID: streamRoomOnB().id),
            "no composition runtime of any transport was created")
        if vm.foreignTakeoverRequest == nil {
            XCTAssertNotNil(vm.studioNotice,
                "either the takeover question is asked, or the refusal is said out loud — silence is the defect")
        } else {
            XCTAssertEqual(vm.foreignTakeoverRequest?.foreignConfigID, "cfg-late",
                "the question names the session that actually appeared")
        }
    }

    /// P7F-30 — shape: the replay suppresses ONLY the two ChromaGlow-owned
    /// questions. It carries no third-party consent, and the foreign preflight
    /// is not gated by `skipHandoffConfirmation` — which is the only reason
    /// P7F-29 can hold.
    func testTheStudioHandoffReplayNeverSuppressesTheForeignPreflight() throws {
        let vmSource = try productionCode("HueHome/UI/Studio/StudioViewModel.swift")

        let replayBody = try XCTUnwrap(
            functionBody(vmSource, startingWith: "private func replayStudioHandoff("))
        let replayText = replayBody.joined(separator: "\n")
        XCTAssertTrue(replayText.contains("skipHandoffConfirmation: true"),
            "the replay suppresses the ChromaGlow-owned questions it already answered")
        XCTAssertTrue(replayText.contains("consentedPlan: request.plan"),
            "and replays the frozen plan rather than re-selecting an area")
        XCTAssertFalse(replayText.contains("foreignConsent"),
            "but carries NO third-party consent — the default nil is the whole point")
        XCTAssertTrue(vmSource.contains("foreignConsent: EntertainmentConsent? = nil"),
            "which is only safe because the parameter defaults to nil")

        let applyBody = try XCTUnwrap(
            functionBody(vmSource, startingWith: "func apply(_ card: StudioCard, roomOverride:"))
        let preflightIndex = try XCTUnwrap(
            applyBody.firstIndex { $0.contains("foreignTakeoverPreflight(") },
            "apply must still call the foreign preflight")
        let afterPreflight = applyBody[preflightIndex...]
        XCTAssertFalse(afterPreflight.contains { $0.contains("skipHandoffConfirmation") },
            "nothing from the foreign preflight onward may be gated on skipHandoffConfirmation — that is how a replay would run REST under a stranger's stream")
        let skipGates = applyBody[..<preflightIndex].filter { $0.contains("skipHandoffConfirmation") }
        XCTAssertEqual(skipGates.count, 2,
            "exactly the two ChromaGlow-owned gates use it: composition-owns and app-driven-owns")
        for gate in skipGates {
            XCTAssertTrue(gate.contains("!skipHandoffConfirmation"),
                "and each uses it only to SUPPRESS its own question: \(gate)")
        }
    }

    // ──────────────────────────────────────────────
    // Correction C — the Reduce Motion refusal is said out loud
    // ──────────────────────────────────────────────

    /// P7F-31 (C1) — the look that was playing, and its Now Playing row, are
    /// byte-identical after the refusal. A refusal that costs the user their
    /// current look is worse than the flashing it was protecting them from.
    func testAReduceMotionRefusalLeavesTheRunningLookAndNowPlayingRowIdentical() async throws {
        stageStreamableBridge(bridgeB, active: [])
        let vm = makeP7FVM()
        let room = streamRoomOnB()
        let party = try streamingCard(vm)
        await vm.apply(party, roomOverride: room, preferEntertainmentOverride: true)
        let running = try XCTUnwrap(vm.runningEffects[room.id])
        let nowPlayingBefore = orchestrator.activeEffectEntries
        let transportBefore = orchestrator.testCompositionTransport(roomID: room.id)

        vm.forcedReduceMotionForTesting = true
        let strobe = try XCTUnwrap(vm.liveModeCards.first { $0.id == "strobe" })
        await vm.apply(strobe, roomOverride: room, preferEntertainmentOverride: true)

        let after = try XCTUnwrap(vm.runningEffects[room.id],
            "the running look must still be there at all")
        XCTAssertEqual(after.cardID, running.cardID)
        XCTAssertEqual(after.room.id, running.room.id)
        XCTAssertEqual(after.lightIDs, running.lightIDs)
        XCTAssertEqual(after.isEntertainment, running.isEntertainment)
        XCTAssertEqual(after.requestedTransport, running.requestedTransport)
        XCTAssertEqual(after.transportFallback, running.transportFallback)
        XCTAssertEqual(after.recovered, running.recovered)
        XCTAssertEqual(orchestrator.activeEffectEntries, nowPlayingBefore,
            "and the Now Playing row is identical, field for field")
        XCTAssertEqual(orchestrator.testCompositionTransport(roomID: room.id), transportBefore,
            "with its transport truth unmoved")
    }

    /// P7F-32 (C2) — the refusal comes before any preparation, so no
    /// Entertainment session is opened and no candidate is left outstanding.
    /// A prepared-but-abandoned session looks owned, so the app's own cleanup
    /// would skip it forever.
    func testAReduceMotionRefusalRequestsNoEntertainmentAndLeavesNoCandidate() async throws {
        stageStreamableBridge(bridgeB, active: [])
        let vm = makeP7FVM()
        vm.forcedReduceMotionForTesting = true
        let strobe = try XCTUnwrap(vm.liveModeCards.first { $0.id == "strobe" })

        await vm.apply(strobe, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)
        await orchestrator.testAwaitEntertainmentRollback()

        XCTAssertTrue(bridgeB.entertainmentActions.isEmpty,
            "no action=start and no action=stop")
        XCTAssertTrue(bridgeB.entertainmentConfigGets.isEmpty,
            "the bridge was never even asked what it could stream")
        XCTAssertFalse(orchestrator.testHasPendingEntertainmentCandidate(),
            "nothing prepared, nothing outstanding")
        XCTAssertFalse(orchestrator.testHasEntertainmentClient(forBridge: "bridge-b"),
            "and no client installed")
    }

    /// P7F-33 (C3) — zero ROOM requests either. The existing refusal test
    /// checks the Entertainment surface only, which would still pass if the
    /// refused card quietly fell back to a REST room write.
    func testAReduceMotionRefusalSendsZeroRoomRequests() async throws {
        stageStreamableBridge(bridgeB, active: [])
        let vm = makeP7FVM()
        vm.forcedReduceMotionForTesting = true
        let strobe = try XCTUnwrap(vm.liveModeCards.first { $0.id == "strobe" })

        await vm.apply(strobe, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)
        await orchestrator.testAwaitEntertainmentRollback()

        XCTAssertTrue(bridgeB.groupedStateIDs.isEmpty,
            "no grouped_light state write")
        XCTAssertTrue(bridgeB.groupedEffectIDs.isEmpty,
            "no grouped_light effect write — a refused Strobe must not become a room flash")
        XCTAssertTrue(bridgeB.groupedPowerIDs.isEmpty, "no room power write")
        XCTAssertTrue(bridgeB.lightEffectIDs.isEmpty, "no per-light write")
        XCTAssertTrue(bridgeB.v1EffectPuts.isEmpty, "no firmware effect write")
        XCTAssertTrue(bridgeB.v1Spy.creations.isEmpty,
            "and nothing was stored on the bridge for it either")
        XCTAssertTrue(bridgeB.v1Spy.deletedResources.isEmpty)
        XCTAssertNil(vm.runningEffects[streamRoomOnB().id],
            "and it is not registered as playing")
    }

    /// P7F-34 (C4) — no ownership, candidate, prompt, or token bookkeeping,
    /// however many times the card is tapped. A refusal that accumulates state
    /// is a leak with a good excuse.
    func testARepeatedReduceMotionRefusalCreatesNoBookkeepingAtAll() async throws {
        stageStreamableBridge(bridgeB, active: [])
        let vm = makeP7FVM()
        vm.forcedReduceMotionForTesting = true
        let strobe = try XCTUnwrap(vm.liveModeCards.first { $0.id == "strobe" })

        await vm.apply(strobe, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)
        await vm.apply(strobe, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)
        await vm.apply(strobe, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)
        await orchestrator.testAwaitEntertainmentRollback()

        XCTAssertFalse(ownershipStore.isProcessOwned(bridgeID: "bridge-b", configID: "area-b"),
            "a refused start owns nothing")
        XCTAssertFalse(ownershipStore.isPersisted(bridgeID: "bridge-b", configID: "area-b"),
            "and records nothing that would outlive the app")
        XCTAssertFalse(orchestrator.testHasPendingEntertainmentCandidate())
        XCTAssertNil(vm.foreignTakeoverRequest, "no prompt of either kind")
        XCTAssertNil(vm.studioHandoffRequest)
        XCTAssertTrue(orchestrator.consumedEntertainmentConsents.isEmpty,
            "and neither token ledger recorded anything")
        XCTAssertTrue(orchestrator.consumedStudioHandoffRequests.isEmpty)
        XCTAssertTrue(orchestrator.activeEffectEntries.isEmpty,
            "and Now Playing stayed empty across all three taps")
    }

    /// P7F-35 (C5) — the exact sentence, asserted as a literal rather than
    /// against the constant, so a copy edit has to be a deliberate test edit
    /// and cannot pass by agreeing with itself.
    func testTheReduceMotionRefusalSaysExactlyTheReviewedSentence() async throws {
        stageStreamableBridge(bridgeB, active: [])
        let vm = makeP7FVM()
        vm.forcedReduceMotionForTesting = true
        let strobe = try XCTUnwrap(vm.liveModeCards.first { $0.id == "strobe" })

        await vm.apply(strobe, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)

        XCTAssertEqual(vm.studioNotice?.message,
                       "Strobe is unavailable while Reduce Motion is on.")
        XCTAssertTrue(vm.statusMessage.contains("Reduce Motion"),
            "the debug/telemetry trail keeps carrying it too")
    }

    /// P7F-36 (C6) — every entry point surfaces it. A refusal that only one of
    /// three surfaces states is still a silent tap on the other two.
    func testEveryStrobeEntryPointStatesTheReduceMotionRefusal() async throws {
        stageStreamableBridge(bridgeB, active: [])
        let vm = makeP7FVM()
        let room = streamRoomOnB()
        vm.forcedReduceMotionForTesting = true
        let strobe = try XCTUnwrap(vm.liveModeCards.first { $0.id == "strobe" })

        // 1. The deck card, tapped with a room already selected.
        vm.selectedRoom = room
        await vm.apply(strobe)
        XCTAssertEqual(vm.studioNotice?.message,
                       "Strobe is unavailable while Reduce Motion is on.",
                       "the deck card states it")

        // 2. The Siri-shaped entry, which carries its own room.
        vm.clearStudioNotice()
        await vm.apply(strobe, roomOverride: room, preferEntertainmentOverride: nil)
        XCTAssertEqual(vm.studioNotice?.message,
                       "Strobe is unavailable while Reduce Motion is on.",
                       "the room-override entry states it too")

        // 3. Perform's STROBE pad, which never routes through `apply` at all —
        //    it is a fullScreenCover over Studio, so it has to state its own.
        let performance = PerformanceViewModel(
            orchestrator: orchestrator,
            room: room,
            liveBox: CompositionParamBox(
                palette: PaletteConfig(), motion: MotionConfig(),
                envelope: EnvelopeConfig(), reaction: ReactionConfig()),
            liveName: "Aurora Drift")
        performance.forcedReduceMotionForTesting = true
        let writesBefore = writeSnapshot(bridgeB)

        performance.punchDown(.strobe)

        XCTAssertEqual(performance.strobeRefusalNotice,
                       "Strobe is unavailable while Reduce Motion is on.",
                       "Perform states it on the surface that refused")
        XCTAssertNil(performance.mix.punch,
            "and engaged no mixer state — the guard is the first statement in punchDown")
        XCTAssertFalse(performance.mix.punchHeld)
        XCTAssertEqual(writeSnapshot(bridgeB), writesBefore,
            "no punch burst, no REST, nothing reached the bridge")

        // The other pads are unaffected — this is a Strobe rule, not a Perform one.
        performance.punchDown(.blackout)
        XCTAssertEqual(performance.mix.punch, .blackout,
            "Blackout still engages under Reduce Motion")
    }

    // ──────────────────────────────────────────────
    // MARK: - Hardware convergence A: exact area choice
    // ──────────────────────────────────────────────
    //
    // Brian's bridge has an area spanning bedroom+bathroom and another
    // spanning bedroom+hallway. The selector refused to guess between them —
    // correctly — and the UI rendered that refusal as "There's no compatible
    // Entertainment Area for that room". Bedroom resolved; hallway and
    // bathroom reported nothing at all, and no surface let him say which area
    // he meant.
    //
    // These drive the REAL `apply` → `foreignTakeoverPreflight` →
    // `exactTargetDecision` path. Same discipline as every packet above:
    // presence, identity and ORDER only. No sleeps, no waiters.

    /// `area-exact` covers exactly the room (L1+L2); `area-wide` covers the
    /// room PLUS a hallway light (L3). Both are streamable, both are eligible.
    private func stageTwoOverlappingAreas(_ spy: RoutingSpyClient) {
        spy.stageLights([p7Light("L1", device: "D1"),
                         p7Light("L2", device: "D2"),
                         p7Light("L3", device: "D3")])
        spy.stageEntertainmentServices(
            #"{"data":[{"id":"E1","owner":{"rid":"D1","rtype":"device"}},"# +
            #"{"id":"E2","owner":{"rid":"D2","rtype":"device"}},"# +
            #"{"id":"E3","owner":{"rid":"D3","rtype":"device"}}]}"#)
        spy.stageEntertainmentConfigs(Self.overlappingConfigsJSON())
    }

    private static func overlappingConfigsJSON(dropL2FromWide: Bool = false) -> String {
        func channel(_ id: Int, _ ent: String) -> String {
            #"{"channel_id":\#(id),"position":{"x":0,"y":0,"z":0},"members":[{"service":{"rid":"\#(ent)","rtype":"entertainment"}}]}"#
        }
        let exact = [channel(0, "E1"), channel(1, "E2")].joined(separator: ",")
        let wideEnts = dropL2FromWide ? ["E1", "E3"] : ["E1", "E2", "E3"]
        let wide = wideEnts.enumerated().map { channel($0.offset, $0.element) }.joined(separator: ",")
        return #"{"data":["# +
            #"{"id":"area-exact","metadata":{"name":"Bedroom"},"status":"inactive","channels":[\#(exact)]},"# +
            #"{"id":"area-wide","metadata":{"name":"Bedroom + Hallway"},"status":"inactive","channels":[\#(wide)]}"# +
            #"]}"#
    }

    private func areaIDs(_ vm: StudioViewModel) -> [String] {
        (vm.areaChoiceRequest?.choices ?? []).map(\.configID)
    }

    /// HCW-01 — the defect itself. Two areas cover the room, so the app asks
    /// instead of announcing that none exists.
    func testTwoOverlappingAreasRaiseTheChooserAndMutateNothing() async throws {
        stageTwoOverlappingAreas(bridgeB)
        let vm = makeP7VM()
        let party = try streamingCard(vm)
        let writesBefore = writeSnapshot(bridgeB)

        await vm.apply(party, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)

        let request = try XCTUnwrap(vm.areaChoiceRequest,
            "two areas can serve this room — that is a question, not 'no compatible area'")
        XCTAssertEqual(request.choices.map(\.configID), ["area-exact", "area-wide"],
            "both are offered, in stable id order, neither collapsed away")
        XCTAssertEqual(request.choices.map(\.areaName), ["Bedroom", "Bedroom + Hallway"],
            "each under the name the user gave it in the Hue app")

        XCTAssertNil(vm.studioNotice,
            "and NOT the 'no compatible Entertainment Area' sentence, which would be false")
        XCTAssertNil(vm.runningEffects[streamRoomOnB().id],
            "nothing starts while the question is open")
        XCTAssertEqual(writeSnapshot(bridgeB), writesBefore,
            "the chooser is raised above every destructive step — nothing was written")
        XCTAssertTrue(bridgeB.entertainmentActions.isEmpty)
    }

    /// HCW-02 — expanded scope is disclosed BEFORE the tap, not explained after
    /// the wrong lights change.
    func testTheWiderAreaDisclosesThatItReachesOutsideTheRequestedRoom() async throws {
        stageTwoOverlappingAreas(bridgeB)
        let vm = makeP7VM()
        let party = try streamingCard(vm)

        await vm.apply(party, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)

        let choices = try XCTUnwrap(vm.areaChoiceRequest?.choices)
        let exact = try XCTUnwrap(choices.first { $0.configID == "area-exact" })
        let wide = try XCTUnwrap(choices.first { $0.configID == "area-wide" })

        XCTAssertFalse(exact.expandsScope, "this one is exactly the room")
        XCTAssertEqual(exact.extraLightCount, 0)
        XCTAssertTrue(wide.expandsScope,
            "Hue streams whole configurations — the extra light comes with it, so say so")
        XCTAssertEqual(wide.extraLightCount, 1)
        XCTAssertEqual(wide.lightCount, 2, "and what it drives inside the room is counted separately")
    }

    /// HCW-03 — the bridge is named by its LABEL. An IP identifies a route, not
    /// a box on a shelf, and it is exactly what a two-bridge home cannot map.
    func testChooserRowsCarryTheBridgeLabelAndNeverTheIP() async throws {
        stageTwoOverlappingAreas(bridgeB)
        let vm = makeP7VM()
        let party = try streamingCard(vm)

        await vm.apply(party, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)

        let choices = try XCTUnwrap(vm.areaChoiceRequest?.choices)
        XCTAssertFalse(choices.isEmpty)
        for choice in choices {
            XCTAssertFalse(choice.bridgeLabel.isEmpty, "every row can name its bridge")
            XCTAssertFalse(choice.bridgeLabel.contains("192.0.2"),
                "the IP is never the user-facing label: \(choice.bridgeLabel)")
            XCTAssertEqual(choice.bridgeID, "bridge-b")
        }
    }

    /// HCW-04 — choosing B opens B. A is never touched.
    func testChoosingOneAreaStartsExactlyThatAreaAndNeverTheOther() async throws {
        stageTwoOverlappingAreas(bridgeB)
        let vm = makeP7VM()
        let party = try streamingCard(vm)
        await vm.apply(party, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)

        let wide = try XCTUnwrap(vm.areaChoiceRequest?.choices.first { $0.configID == "area-wide" })
        await vm.confirmAreaChoice(wide)

        XCTAssertNil(vm.areaChoiceRequest, "the question is answered and closed")
        XCTAssertEqual(bridgeB.entertainmentStarts, ["area-wide"],
            "exactly the area the user named — once")
        XCTAssertFalse(bridgeB.entertainmentActions.contains { $0.configID == "area-exact" },
            "the area they did NOT pick is never opened, started, or stopped")
    }

    /// HCW-05 — a saved Streaming composition takes the same road. A second
    /// selection path is exactly how two surfaces come to disagree about which
    /// area a room streams to.
    func testASavedStreamingCompositionUsesTheSameChooser() async throws {
        stageTwoOverlappingAreas(bridgeB)
        let vm = makeP7FVM()
        let composition = p7fComposition(vm)

        await vm.apply(composition.card, roomOverride: streamRoomOnB(),
                       preferEntertainmentOverride: true)

        XCTAssertEqual(areaIDs(vm), ["area-exact", "area-wide"],
            "compositions resolve their target through the one shared decision")
        XCTAssertNil(vm.runningEffects[streamRoomOnB().id])
    }

    /// HCW-06 — Party and Thunderstorm too. Their TRANSPORT is the engine's,
    /// but WHERE they stream is still the user's.
    func testEveryStreamingEngineReachesTheSameChooser() async throws {
        for engineKey in ["party", "thunderstorm"] {
            stageTwoOverlappingAreas(bridgeB)
            orchestrator.invalidateEntertainmentCaches(forBridge: "bridge-b")
            let vm = makeP7VM()
            guard let card = vm.liveModeCards.first(where: { $0.id == engineKey }) else {
                return XCTFail("'\(engineKey)' is a streaming engine and must exist")
            }

            await vm.apply(card, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)

            XCTAssertEqual(areaIDs(vm), ["area-exact", "area-wide"],
                "'\(engineKey)' must not have its own private way of picking an area")
            vm.cancelAreaChoice()
        }
    }

    /// HCW-07 — dismissing the sheet is not an answer, and answers nothing.
    func testDismissingTheChooserStartsNothingAndWritesNothing() async throws {
        stageTwoOverlappingAreas(bridgeB)
        let vm = makeP7VM()
        let party = try streamingCard(vm)
        await vm.apply(party, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)
        XCTAssertNotNil(vm.areaChoiceRequest)
        let writesBefore = writeSnapshot(bridgeB)

        vm.cancelAreaChoice()

        XCTAssertNil(vm.areaChoiceRequest)
        XCTAssertNil(vm.runningEffects[streamRoomOnB().id], "no area was chosen, so nothing plays")
        XCTAssertEqual(writeSnapshot(bridgeB), writesBefore)
        XCTAssertTrue(bridgeB.entertainmentActions.isEmpty)
    }

    /// HCW-08 — a selection that no longer exists starts NOTHING. Not the other
    /// candidate: substituting an area the user never picked is the whole class
    /// of defect this slice exists to end.
    func testASelectedAreaThatVanishedUnderTheSheetStartsNothing() async throws {
        stageTwoOverlappingAreas(bridgeB)
        let vm = makeP7VM()
        let party = try streamingCard(vm)
        await vm.apply(party, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)
        let wide = try XCTUnwrap(vm.areaChoiceRequest?.choices.first { $0.configID == "area-wide" })

        // The user deletes that area in the Hue app while the sheet is open.
        bridgeB.stageEntertainmentConfigs(Self.configsJSON(areaID: "area-exact", active: []))

        await vm.confirmAreaChoice(wide)

        XCTAssertEqual(vm.studioNotice?.message, EntertainmentAreaChoiceCopy.staleSelection,
            "and it says so, rather than silently playing somewhere else")
        XCTAssertTrue(bridgeB.entertainmentStarts.isEmpty,
            "nothing was opened — least of all the area that was still available")
        XCTAssertNil(vm.runningEffects[streamRoomOnB().id])
    }

    /// HCW-09 — membership changing under the sheet fails closed. The frozen
    /// plan is compared by whole value, so an area re-scoped to different
    /// lights is not the area the user was shown.
    func testMembershipChangedUnderTheSheetFailsClosed() async throws {
        stageTwoOverlappingAreas(bridgeB)
        let vm = makeP7VM()
        let party = try streamingCard(vm)
        await vm.apply(party, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)
        let wide = try XCTUnwrap(vm.areaChoiceRequest?.choices.first { $0.configID == "area-wide" })

        // Same id, same name — different lights. Only a whole-value comparison
        // can tell that this is not what was on screen.
        bridgeB.stageEntertainmentServices(
            #"{"data":[{"id":"E1","owner":{"rid":"D1","rtype":"device"}},"# +
            #"{"id":"E3","owner":{"rid":"D3","rtype":"device"}}]}"#)
        bridgeB.stageEntertainmentConfigs(Self.overlappingConfigsJSON(dropL2FromWide: true))

        await vm.confirmAreaChoice(wide)

        XCTAssertTrue(bridgeB.entertainmentStarts.isEmpty,
            "an area re-scoped under the prompt streams nothing")
        XCTAssertNil(vm.runningEffects[streamRoomOnB().id])
    }

    /// HCW-10 — another bridge's areas are never candidates, even when both
    /// bridges are staged and reachable.
    func testAnotherBridgesAreasNeverAppearInTheChooser() async throws {
        stageTwoOverlappingAreas(bridgeB)
        stageStreamableBridge(bridgeA, areaID: "area-on-a")
        let vm = makeP7VM()
        let party = try streamingCard(vm)

        await vm.apply(party, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)

        let choices = try XCTUnwrap(vm.areaChoiceRequest?.choices)
        XCTAssertEqual(choices.map(\.configID), ["area-exact", "area-wide"])
        XCTAssertFalse(choices.contains { $0.configID == "area-on-a" },
            "bridge A's inventory is not bridge B's room's business")
        XCTAssertTrue(choices.allSatisfy { $0.bridgeID == "bridge-b" })
        XCTAssertTrue(bridgeA.entertainmentActions.isEmpty, "and A is never touched")
    }

    /// HCW-11 — one bridge's decision is made entirely from its own inventory.
    /// Configuration ids are unique per bridge, never globally.
    func testOneBridgesDecisionIsMadeOnlyFromItsOwnInventory() async throws {
        stageStreamableBridge(bridgeA, areaID: "area-shared")
        stageTwoOverlappingAreas(bridgeB)
        let vm = makeP7VM()
        let party = try streamingCard(vm)

        // Bridge A resolves to exactly one area and needs no chooser at all,
        // even though B is ambiguous at the same moment.
        await vm.apply(party, roomOverride: streamRoomOnA(), preferEntertainmentOverride: true)

        XCTAssertNil(vm.areaChoiceRequest, "one candidate on A — nothing to ask")
        XCTAssertEqual(bridgeA.entertainmentStarts, ["area-shared"])
        XCTAssertTrue(bridgeB.entertainmentActions.isEmpty,
            "and B's inventory played no part in A's decision")
    }

    /// HCW-12 — one candidate still auto-selects. The chooser is for genuine
    /// ambiguity; making every start a question would be its own defect.
    func testASingleCandidateStillStartsWithoutAsking() async throws {
        stageStreamableBridge(bridgeB)
        let vm = makeP7VM()
        let party = try streamingCard(vm)

        await vm.apply(party, roomOverride: streamRoomOnB(), preferEntertainmentOverride: true)

        XCTAssertNil(vm.areaChoiceRequest, "exactly one safe area — no question to ask")
        XCTAssertEqual(bridgeB.entertainmentStarts, ["area-b"])
        XCTAssertNotNil(vm.runningEffects[streamRoomOnB().id])
    }
}
