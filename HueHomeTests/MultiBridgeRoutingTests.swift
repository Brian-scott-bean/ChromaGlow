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
    private func inventory(_ kind: String) -> [String: [String: Any]] {
        lock.lock(); defer { lock.unlock() }
        _fetchCalls.append(kind)
        return _inventories[kind] ?? [:]
    }

    override func deleteSchedule(id: String) async throws { record("schedule:\(id)") }
    override func deleteRule(id: String) async throws { record("rule:\(id)") }
    override func deleteSensor(id: String) async throws { record("sensor:\(id)") }
    override func deleteScene(id: String) async throws { record("scene:\(id)") }
    override func deleteResourcelink(id: String) async throws { record("resourcelink:\(id)") }

    override func fetchSchedules() async throws -> [String: [String: Any]] { inventory("fetchSchedules") }
    override func fetchRules() async throws -> [String: [String: Any]] { inventory("fetchRules") }
    override func fetchSensors() async throws -> [String: [String: Any]] { inventory("fetchSensors") }
    override func fetchScenes() async throws -> [String: [String: Any]] { inventory("fetchScenes") }
    override func fetchResourcelinks() async throws -> [String: [String: Any]] { inventory("fetchResourcelinks") }
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

    /// Packet 3: `startStudioMode`'s default branch issues exactly this PUT.
    /// Overridden so the ownership tests never reach the (unroutable) TEST-NET-1
    /// address the spies are built with.
    override func setGroupedLightBrightness(id: String, brightness: Double) async throws {
        lock.lock(); defer { lock.unlock() }
        _groupedStateIDs.append(id)
    }

    override func setLightNativeEffect(id: String, effect: String) async throws {
        lock.lock(); defer { lock.unlock() }
        _v1EffectPuts.append("\(id):\(effect)")
    }

    override func fetchLights() async throws -> [HueLight] { [] }

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

        await orchestrator.stopCompositionMode(roomID: roomID, bridgeID: nil)

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

    /// Manifests staged into the shared store, torn down per test.
    private var stagedManifests: [(presetID: UUID, roomID: String)] = []

    override func tearDown() async throws {
        for staged in stagedManifests {
            BridgeAnimationStore.shared.remove(presetID: staged.presetID, roomID: staged.roomID)
        }
        stagedManifests.removeAll()
        // Packet 4: never leave an injected telemetry clock behind.
        orchestrator.testResetCompositionTelemetryClock()
        try await super.tearDown()
    }

    /// Persist a manifest with a fresh preset ID (the store keys on
    /// presetID_roomID, so same-room manifests must differ by preset).
    @discardableResult
    private func stageManifest(
        roomID: String,
        bridgeIP: String,
        presetName: String = "Packet2",
        sensorID: String,
        ruleIDs: [String],
        scheduleID: String,
        sceneIDs: [String] = [],
        resourcelinkID: String? = nil
    ) -> BridgeAnimationManifest {
        let presetID = UUID()
        let manifest = BridgeAnimationManifest(
            id: UUID(), presetID: presetID, presetName: presetName,
            roomID: roomID, roomName: roomID,
            bridgeIP: bridgeIP,
            sensorID: sensorID, ruleIDs: ruleIDs, scheduleID: scheduleID,
            sceneIDs: sceneIDs, resourcelinkID: resourcelinkID,
            stepCount: 2, intervalSeconds: 3, cycleDurationSeconds: 6,
            createdAt: Date()
        )
        BridgeAnimationStore.shared.save(manifest)
        stagedManifests.append((presetID, roomID))
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
        BridgeAnimationStore.shared.allManifests()
            .contains { $0.presetID == manifest.presetID && $0.roomID == manifest.roomID }
    }

    func testStartingARoomPreservesASiblingRoomsBridgeAnimation() async {
        let sibling = stageManifest(
            roomID: "p2-sibling-a", bridgeIP: "192.0.2.1", presetName: "Sibling A",
            sensorID: "a-sensor", ruleIDs: ["a-rule-1", "a-rule-2"], scheduleID: "a-sched",
            sceneIDs: ["a-scene"], resourcelinkID: "a-link"
        )

        // Room B has no previous animation: this is a first start, not a replacement.
        await orchestrator.testCleanupBridgeStoredForReplacement(
            roomID: "p2-sibling-b", v1Client: bridgeA.v1Spy)

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
            roomID: "p2-replace-b", v1Client: bridgeA.v1Spy)

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
            roomID: "p2-multi-b", v1Client: bridgeA.v1Spy)

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
            roomID: "p2-room-shared", v1Client: bridgeA.v1Spy)

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
            roomID: "p2-traffic-shared", v1Client: bridgeA.v1Spy)

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
            roomID: "p2-noenum-b", v1Client: bridgeA.v1Spy)

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
            roomID: "p2-order-b", v1Client: bridgeA.v1Spy)

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
            roomID: "p2-nolink-b", v1Client: bridgeA.v1Spy)

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
            roomID: "p2-sparse-b", v1Client: bridgeA.v1Spy)

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
}
