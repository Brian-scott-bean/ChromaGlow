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
}
