//
//  StudioProductionWiringTests.swift
//  HueHomeTests
//
//  Unified Customization Engine — Slice 2 (Production Truth Wiring).
//
//  The Slice 1 tests proved the FOUNDATION behaves; these prove the ACTUAL
//  production paths honor the identity contract. Every test drives the same
//  API the shipping UI drives: `beginParamEdit` / `updateParamEdit` /
//  `commitParam`, `paramValue` / `paramColor`, `resetParams`,
//  `installRunningIdentity`, `stopRunningScopes`, `rekeyRunningInstance`,
//  and the orchestrator's room-guarded `updateStudioParams`.
//
//  Convention (audit §24 / Slice 1): every race is expressed by CALL ORDERING
//  against the pure fence — no sleeps, no waiters.
//

import XCTest
import SwiftUI
@testable import HueHome

/// Records the coalesced bridge writes R4D emits.
///
/// `setLightEffectV2` lives in an EXTENSION of `HueAPIClient`, so it is
/// statically dispatched and cannot be overridden by a subclass — the send site
/// holds an `HueAPIClient`, so an override would never be called. The v2 bodies
/// are therefore recorded one layer down, in the `put(path:body:ip:token:)` the
/// extension funnels through, which is the same request the bridge would see.
private final class WiringSpyClient: BridgeAPIClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _v2Puts: [(lightID: String, body: [String: Any])] = []
    private var _groupedEffectPuts: [(id: String, brightness: Double?, xy: (Double, Double)?, mirek: Int?)] = []

    /// Every `effects_v2` PUT, in order: which light, and the action payload.
    var v2Puts: [(lightID: String, body: [String: Any])] {
        lock.lock(); defer { lock.unlock() }
        return _v2Puts
    }
    /// Every grouped-light effect PUT, in order, with the fields it carried.
    var groupedEffectPuts: [(id: String, brightness: Double?, xy: (Double, Double)?, mirek: Int?)] {
        lock.lock(); defer { lock.unlock() }
        return _groupedEffectPuts
    }

    override func fetchLights() async throws -> [HueLight] { [] }
    override func fetchRooms() async throws -> [HueRoom] { [] }
    override func fetchZones() async throws -> [HueZone] { [] }
    override func fetchGroupedLights() async throws -> [HueGroupedLight] { [] }
    override func fetchScenes() async throws -> [HueScene] { [] }
    override func fetchLightIDsForGroup(groupedLightID: String) async throws -> [String] { [] }
    override func setLightNativeEffect(id: String, effect: String) async throws {}
    override func setGroupedLightState(id: String, on: Bool, brightness: Double) async throws {}
    override func setGroupedLight(id: String, on: Bool) async throws {}

    override func setGroupedLightEffect(
        id: String, on: Bool?, brightness: Double?,
        xy: (Double, Double)?, mirek: Int?, duration: Int
    ) async throws {
        lock.lock()
        _groupedEffectPuts.append((id: id, brightness: brightness, xy: xy, mirek: mirek))
        lock.unlock()
    }

    override func get(path: String, ip: String, token: String) async throws -> Data {
        Data(#"{"data": []}"#.utf8)
    }

    override func put(path: String, body: [String: Any], ip: String, token: String) async throws -> Data {
        if let v2 = body["effects_v2"] as? [String: Any],
           let action = v2["action"] as? [String: Any],
           let lightID = path.split(separator: "/").last.map(String.init) {
            lock.lock(); _v2Puts.append((lightID: lightID, body: action)); lock.unlock()
        }
        return Data("{}".utf8)
    }
}

@MainActor
final class StudioProductionWiringTests: XCTestCase {

    private var vm: StudioViewModel!
    private var orchestrator: UnifiedOrchestrator!

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            vm = StudioViewModel()
            orchestrator = UnifiedOrchestrator()
            vm.configure(orchestrator: orchestrator)
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            vm = nil
            orchestrator = nil
        }
        super.tearDown()
    }

    // ── Fixtures ────────────────────────────────────────────────

    private func room(_ id: String, bridge: String? = "bridge-a",
                      kind: RoomDisplayItem.Kind = .room) -> RoomDisplayItem {
        RoomDisplayItem(
            kind: kind,
            id: id, name: id, archetype: nil, isOn: true, brightness: 60,
            groupedLightID: "gl-\(id)", lightCount: 2, bridgeID: bridge,
            childResourceRefs: [])
    }

    private func partyCard() -> StudioCard {
        vm.liveModeCards.first { $0.id == "party" }!
    }

    /// Start the card on a target through the PRODUCTION identity install —
    /// the same helper every `apply()` arm composes.
    @discardableResult
    private func startRunning(_ card: StudioCard, on target: RoomDisplayItem,
                              isEntertainment: Bool = false) -> RunningLookIdentity {
        var execution: CustomizationExecution = .appDriven(engineKey: "party")
        switch card.strategy {
        case .bridgeNative(let effect): execution = .bridgeNative(effect: effect)
        case .appDriven(let key):       execution = .appDriven(engineKey: key)
        case .composition(let pid):     execution = .composition(presetID: pid)
        }
        let identity = vm.installRunningIdentity(room: target, card: card, execution: execution)
        vm.runningEffects[StudioSelectionKey(room: target)] = RunningEffect(
            cardID: card.id, card: card, room: target, lightIDs: ["L1"],
            isEntertainment: isEntertainment, requestedTransport: nil,
            transportFallback: false, identity: identity)
        return identity
    }

    /// Edit through the production gesture path with the selection on `target`.
    private func edit(_ card: StudioCard, on target: RoomDisplayItem,
                      paramID: String = "speed", value: Double) {
        vm.selectedRoom = target
        let session = vm.beginParamEdit(cardID: card.id, paramID: paramID)
        XCTAssertNotNil(session, "the card is running on the selected target")
        vm.updateParamEdit(session!, value: value)
        vm.endParamEdit(session!)
    }

    /// What the UI's slider row would display: the accessor with the catalog
    /// default, exactly as `StudioParamRow` passes it.
    private func displayedSpeed(_ card: StudioCard, on target: RoomDisplayItem) -> Double {
        vm.selectedRoom = target
        let catalogDefault = card.params.first { $0.id == "speed" }!.defaultValue
        return vm.paramValue(for: card.id, paramID: "speed", default: catalogDefault)
    }

    // ── Same card, independent targets ──────────────────────────

    func testSameCardOnTwoBridgesHoldsIndependentValuesThroughTheProductionPath() {
        let a = room("room-1", bridge: "bridge-a")
        let b = room("room-1", bridge: "bridge-b")   // SAME room id, other bridge
        let card = partyCard()
        startRunning(card, on: a)
        startRunning(card, on: b)

        edit(card, on: a, value: 20)
        edit(card, on: b, value: 80)

        XCTAssertEqual(displayedSpeed(card, on: a), 20, "bridge A shows its own instance")
        XCTAssertEqual(displayedSpeed(card, on: b), 80, "bridge B shows its own instance")
    }

    func testTwoRoomsOnTheSameBridgeHoldIndependentValuesThroughTheProductionPath() {
        let a = room("room-a"), b = room("room-b")
        let card = partyCard()
        startRunning(card, on: a)
        startRunning(card, on: b)

        edit(card, on: a, value: 25)
        edit(card, on: b, value: 75)

        XCTAssertEqual(displayedSpeed(card, on: a), 25)
        XCTAssertEqual(displayedSpeed(card, on: b), 75, "a sibling room on the SAME bridge is independent")
    }

    /// BINDING correction #1: a room and a zone sharing an identifier on one
    /// bridge remain independently represented, routed, edited, and stopped —
    /// the production running collection is kind-aware.
    func testRoomAndZoneSharingAnIDRemainIndependentInProduction() async {
        let asRoom = room("shared-id", kind: .room)
        let asZone = room("shared-id", kind: .zone)
        let card = partyCard()
        startRunning(card, on: asRoom)
        startRunning(card, on: asZone)

        XCTAssertEqual(vm.runningEffects.count, 2,
                       "two rows — the kind-aware key does not collapse them")

        edit(card, on: asRoom, value: 30)
        edit(card, on: asZone, value: 90)
        XCTAssertEqual(displayedSpeed(card, on: asRoom), 30)
        XCTAssertEqual(displayedSpeed(card, on: asZone), 90)

        // Stop the ZONE's instance; the room's survives untouched.
        vm.stopRunningScopes(forRowAt: StudioSelectionKey(room: asZone))
        vm.runningEffects.removeValue(forKey: StudioSelectionKey(room: asZone))
        XCTAssertNotNil(vm.runningEffect(for: asRoom), "the room's row survives")
        XCTAssertEqual(displayedSpeed(card, on: asRoom), 30, "…with its exact values")

        // A record carrying only bridge+id cannot say which one it means —
        // resolution fails closed while both were present, resolves after.
        startRunning(card, on: asZone)
        XCTAssertNil(vm.runningKey(bridgeID: "bridge-a", groupID: "shared-id"),
                     "bridge+id alone is ambiguous while a room AND a zone hold the id")
    }

    // ── Gesture capture vs selection movement ───────────────────

    func testDragCapturedOnOneRoomDoesNotLandOnASiblingAfterSelectionMoves() {
        let a = room("room-a"), b = room("room-b")
        let card = partyCard()
        startRunning(card, on: a)
        startRunning(card, on: b)
        edit(card, on: b, value: 50)   // B's baseline

        // The finger lands on A…
        vm.selectedRoom = a
        let session = vm.beginParamEdit(cardID: card.id, paramID: "speed")!
        // …the wheel commits B mid-drag…
        vm.selectedRoom = b
        // …and the remaining ticks still address A, never B.
        vm.updateParamEdit(session, value: 5)
        vm.endParamEdit(session)

        XCTAssertEqual(displayedSpeed(card, on: a), 5, "the captured target got the value")
        XCTAssertEqual(displayedSpeed(card, on: b), 50, "the newly selected room did not")
    }

    // ── Reset isolation ─────────────────────────────────────────

    func testResetOnOneInstanceLeavesTheSameCardEverywhereElse() async {
        let a = room("room-a"), b = room("room-b")
        let other = room("room-a", bridge: "bridge-b")
        let card = partyCard()
        startRunning(card, on: a)
        startRunning(card, on: b)
        startRunning(card, on: other)
        edit(card, on: a, value: 11)
        edit(card, on: b, value: 22)
        edit(card, on: other, value: 33)

        vm.selectedRoom = a
        await vm.resetParams(for: card)

        let catalogDefault = card.params.first { $0.id == "speed" }!.defaultValue
        XCTAssertEqual(displayedSpeed(card, on: a), catalogDefault, "A reset to defaults")
        XCTAssertEqual(displayedSpeed(card, on: b), 22, "same-bridge sibling untouched")
        XCTAssertEqual(displayedSpeed(card, on: other), 33, "other bridge untouched")
    }

    func testResetDefeatsAWriteCapturedBeforeIt() async {
        let a = room("room-a")
        let card = partyCard()
        startRunning(card, on: a)

        vm.selectedRoom = a
        let staleSession = vm.beginParamEdit(cardID: card.id, paramID: "speed")!
        await vm.resetParams(for: card)
        vm.updateParamEdit(staleSession, value: 99)   // authored pre-reset

        let catalogDefault = card.params.first { $0.id == "speed" }!.defaultValue
        XCTAssertEqual(displayedSpeed(card, on: a), catalogDefault,
                       "the pre-reset write lost the generation fence")
    }

    // ── Stop isolation and fencing ──────────────────────────────

    func testStopOnOneTargetLeavesTheOthersAndFencesItsPendingWrites() {
        let a = room("room-a"), b = room("room-b")
        let card = partyCard()
        let identityA = startRunning(card, on: a)
        startRunning(card, on: b)
        edit(card, on: b, value: 60)

        vm.selectedRoom = a
        let session = vm.beginParamEdit(cardID: card.id, paramID: "speed")!
        vm.stopRunningScopes(forRowAt: StudioSelectionKey(room: a))
        vm.runningEffects.removeValue(forKey: StudioSelectionKey(room: a))

        XCTAssertFalse(vm.valueScopes.isCurrent(identityA),
                       "the debounced send's post-sleep re-fence now drops")
        vm.updateParamEdit(session, value: 99)   // the late tick
        XCTAssertEqual(vm.valueScopes.runningTargetCount, 1, "nothing resurrected A")
        XCTAssertEqual(displayedSpeed(card, on: b), 60, "B untouched by A's stop or late write")
    }

    func testCardReplacementFencesTheOldCardsWrites() {
        let a = room("room-a")
        let party = partyCard()
        let strobe = vm.liveModeCards.first { $0.id == "strobe" }!
        startRunning(party, on: a)

        vm.selectedRoom = a
        let staleSession = vm.beginParamEdit(cardID: party.id, paramID: "speed")!

        // The replacement, through the production teardown + install pair.
        vm.stopRunningScopes(forRowAt: StudioSelectionKey(room: a))
        startRunning(strobe, on: a)

        vm.updateParamEdit(staleSession, value: 99)
        vm.selectedRoom = a
        XCTAssertEqual(vm.paramValue(for: strobe.id, paramID: "speed",
                                     default: strobe.params.first { $0.id == "speed" }!.defaultValue),
                       strobe.params.first { $0.id == "speed" }!.defaultValue,
                       "the old card's write never reached the replacement")
        XCTAssertFalse(vm.valueScopes.isCurrent(staleSession.identity))
    }

    func testRekeyOnTransportChangeFencesWritesWithoutBlankingLiveValues() {
        let a = room("room-a")
        let card = partyCard()
        startRunning(card, on: a)
        edit(card, on: a, value: 42)

        vm.selectedRoom = a
        let preRekeySession = vm.beginParamEdit(cardID: card.id, paramID: "speed")!
        vm.rekeyRunningInstance(at: StudioSelectionKey(room: a), reason: .transportChanged)

        XCTAssertEqual(displayedSpeed(card, on: a), 42,
                       "the screen keeps the real values — no silent blanking")
        vm.updateParamEdit(preRekeySession, value: 99)
        XCTAssertEqual(displayedSpeed(card, on: a), 42,
                       "…while the pre-rekey write is fenced out")
    }

    // ── Defaults vs live separation ─────────────────────────────

    func testEditingWhileNotRunningWritesDefaultsOnly() {
        let a = room("room-a")
        let card = partyCard()
        vm.selectedRoom = a

        XCTAssertNil(vm.beginParamEdit(cardID: card.id, paramID: "speed"),
                     "no running instance → no live session")
        vm.commitParam(cardID: card.id, paramID: "speed", value: 64)

        XCTAssertEqual(vm.paramValue(for: card.id, paramID: "speed", default: -1), 64,
                       "the default is what the card will next start with")
        XCTAssertEqual(vm.valueScopes.runningTargetCount, 0, "nothing started running")
    }

    func testLiveEditUpdatesTheCardsNextStartDefaults() {
        let a = room("room-a")
        let card = partyCard()
        startRunning(card, on: a)
        edit(card, on: a, value: 77)

        XCTAssertEqual(vm.valueScopes.defaults(forCard: card.id).numbers["speed"], 77,
                       "last-used behavior: the live edit becomes the next-start default")
    }

    // ── The orchestrator room guard ─────────────────────────────

    func testUpdateStudioParamsRefusesASiblingRoomOnTheSameBridge() {
        orchestrator.testInstallStudioEngineRuntime(
            bridgeKey: "bridge-a", roomID: "room-a", values: ["speed": 50])

        orchestrator.updateStudioParams(values: ["speed": 99], colors: [:],
                                        bridgeID: "bridge-a", roomID: "room-b")
        XCTAssertEqual(orchestrator.testStudioParamBoxValues(forBridge: "bridge-a")?["speed"], 50,
                       "a write naming a sibling room does not touch the runtime's box")

        orchestrator.updateStudioParams(values: ["speed": 99], colors: [:],
                                        bridgeID: "bridge-a", roomID: "room-a")
        XCTAssertEqual(orchestrator.testStudioParamBoxValues(forBridge: "bridge-a")?["speed"], 99,
                       "the owning room's write lands")
    }

    func testCommittedEditReachesExactlyTheOwningEngineBox() {
        let a = room("room-a"), b = room("room-b", bridge: "bridge-b")
        let card = partyCard()
        startRunning(card, on: a)
        startRunning(card, on: b)
        orchestrator.testInstallStudioEngineRuntime(bridgeKey: "bridge-a", roomID: "room-a")
        orchestrator.testInstallStudioEngineRuntime(bridgeKey: "bridge-b", roomID: "room-b")

        edit(card, on: a, value: 15)
        XCTAssertEqual(orchestrator.testStudioParamBoxValues(forBridge: "bridge-a")?["speed"], 15)
        XCTAssertNil(orchestrator.testStudioParamBoxValues(forBridge: "bridge-b")?["speed"],
                     "the other bridge's engine box is untouched")

        edit(card, on: b, value: 85)
        XCTAssertEqual(orchestrator.testStudioParamBoxValues(forBridge: "bridge-b")?["speed"], 85)
        XCTAssertEqual(orchestrator.testStudioParamBoxValues(forBridge: "bridge-a")?["speed"], 15)
    }

    // ── Session manager (2C) ────────────────────────────────────

    /// Apply Current Look copies the source's exact live values ONCE; the
    /// two instances then diverge freely (spec §14.6/§14.7).
    func testApplyCurrentLookCopiesOnceThenInstancesDiverge() {
        let a = room("room-a"), b = room("room-b")
        let card = partyCard()
        startRunning(card, on: a)
        edit(card, on: a, value: 33)

        // Viewing A (active), then selecting idle B — A is the source.
        vm.selectedRoom = a
        vm.noteSelectionChanged()
        vm.selectedRoom = b
        vm.noteSelectionChanged()
        XCTAssertEqual(vm.applyCurrentLookSource?.room.id, "room-a")

        // The production copy-once seed, then the start apply() performs.
        let seeded = vm.seedApplyCurrentLook()
        XCTAssertEqual(seeded?.id, card.id)
        startRunning(card, on: b)

        XCTAssertEqual(displayedSpeed(card, on: b), 33, "the copy landed once")
        edit(card, on: b, value: 77)
        XCTAssertEqual(displayedSpeed(card, on: a), 33, "…and the source never links")
        XCTAssertEqual(displayedSpeed(card, on: b), 77)
    }

    func testApplyCurrentLookOffersNoSourceWhenSelectedRoomIsActive() {
        let a = room("room-a")
        let card = partyCard()
        startRunning(card, on: a)
        vm.selectedRoom = a
        vm.noteSelectionChanged()
        XCTAssertNil(vm.applyCurrentLookSource,
                     "an active selected room needs no Apply-Current-Look path")
    }

    /// The session-manager row stop: exact kind-aware key, sibling survives,
    /// and the stopped target's session memory dies with it.
    func testStopActiveTargetIsExactAndClearsItsWorkingMemory() async {
        let asRoom = room("shared-id", kind: .room)
        let asZone = room("shared-id", kind: .zone)
        let card = partyCard()
        let roomIdentity = startRunning(card, on: asRoom)
        startRunning(card, on: asZone)
        vm.sessionMemory.update(roomIdentity.targetKey) { $0.identityPanelOpen = true }

        await vm.stopActiveTarget(StudioSelectionKey(room: asRoom))

        XCTAssertNil(vm.runningEffect(for: asRoom), "the exact row stopped")
        XCTAssertNotNil(vm.runningEffect(for: asZone), "the same-id zone twin survives")
        XCTAssertFalse(vm.sessionMemory.state(for: roomIdentity.targetKey).identityPanelOpen,
                       "the stopped target's expansions die with it")
        XCTAssertFalse(vm.valueScopes.isCurrent(roomIdentity),
                       "its pending writes are fenced")
    }

    // ── Stop All ────────────────────────────────────────────────

    func testStopAllClearsEveryTargetAndPendingSendSlot() async {
        let a = room("room-a"), b = room("room-b", bridge: "bridge-b")
        let card = partyCard()
        startRunning(card, on: a)
        startRunning(card, on: b)
        edit(card, on: a, value: 10)
        edit(card, on: b, value: 90)

        await vm.stopAll()

        XCTAssertEqual(vm.valueScopes.runningTargetCount, 0)
        XCTAssertTrue(vm.paramSendTasks.isEmpty, "no pending send survives Stop All")
        XCTAssertTrue(vm.pendingParamSends.isEmpty,
                      "…and no accumulated field survives it either")
        XCTAssertTrue(vm.runningEffects.isEmpty)
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - R4A: runtime truth corrections
    // ──────────────────────────────────────────────────────────
    //
    // Two orchestrator-side events used to change what was RUNNING without
    // ever reaching Studio's mirror. The row went on claiming a transport
    // that no longer existed, so every live control resolved against it.

    private func compositionCard() -> StudioCard {
        vm.studioCard(for: CompositionPreset(
            id: UUID(), name: "Aurora Drift", icon: "sparkles", accentColorHex: "#FFB84D",
            isBuiltIn: false, category: .ambient, seasonMonths: nil,
            palette: PaletteConfig(), motion: MotionConfig(),
            envelope: EnvelopeConfig(), reaction: ReactionConfig(),
            createdAt: Date(timeIntervalSince1970: 1_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_000_000)))
    }

    /// A lost Studio session removes EXACTLY the streaming row it names — and
    /// fences the writes captured against it. Another bridge's row, which has
    /// its own session, is untouched.
    func testSessionLostRemovesExactlyTheStreamingRowAndFencesItsCapturedWrites() {
        let a = room("room-1", bridge: "bridge-a")
        let b = room("room-1", bridge: "bridge-b")   // SAME room id, other bridge
        let card = partyCard()
        let identityA = startRunning(card, on: a, isEntertainment: true)
        let identityB = startRunning(card, on: b, isEntertainment: true)

        // A drag captured while the session was still alive.
        vm.selectedRoom = a
        let captured = vm.beginParamEdit(cardID: card.id, paramID: "speed")!

        orchestrator.testEmitStudioRuntimeEvent(
            .entertainmentSessionLost(bridgeID: "bridge-a", roomID: "room-1"))

        XCTAssertNil(vm.runningEffect(for: a),
                     "a row with no session behind it is a claim about nothing")
        XCTAssertNotNil(vm.runningEffect(for: b),
                        "the other bridge streams independently and must survive")
        XCTAssertFalse(vm.valueScopes.isCurrent(identityA), "its scope is retired")
        XCTAssertTrue(vm.valueScopes.isCurrent(identityB))

        vm.updateParamEdit(captured, value: 99)
        XCTAssertNil(vm.paramSendTasks[identityA.targetKey],
                     "a write captured before the loss lands on nothing")
    }

    /// A Room-mode row has no session to lose. Rewriting it would be inventing
    /// a state change, so the event is ignored.
    func testSessionLostIgnoresARoomModeRow() {
        let a = room("room-a")
        let card = partyCard()
        let identity = startRunning(card, on: a, isEntertainment: false)

        orchestrator.testEmitStudioRuntimeEvent(
            .entertainmentSessionLost(bridgeID: "bridge-a", roomID: "room-a"))

        XCTAssertNotNil(vm.runningEffect(for: a), "Room mode was never streaming")
        XCTAssertTrue(vm.valueScopes.isCurrent(identity), "…so nothing was fenced")
    }

    /// A composition failing over DTLS→REST flips the row's transport and
    /// rekeys it — WITHOUT blanking the values on screen — and the snapshot the
    /// resolver reads follows to `.roomREST`.
    func testCompositionFallbackFlipsTransportAndRekeysWithValuesPreserved() throws {
        let a = room("room-a")
        let card = compositionCard()
        let identity = startRunning(card, on: a, isEntertainment: true)
        edit(card, on: a, value: 42)
        XCTAssertEqual(vm.targetSnapshot(for: try XCTUnwrap(vm.runningEffect(for: a))).transport,
                       .entertainment, "the row starts out claiming the stream")

        orchestrator.testEmitStudioRuntimeEvent(
            .compositionFellBackToREST(bridgeID: "bridge-a", roomID: "room-a"))

        let row = try XCTUnwrap(vm.runningEffect(for: a))
        XCTAssertFalse(row.isEntertainment, "the row stops claiming a stream it does not have")
        XCTAssertTrue(row.transportFallback, "…and records WHY it is on Room mode")
        XCTAssertEqual(vm.targetSnapshot(for: row).transport, .roomREST,
                       "the resolver now measures the transport that is really carrying it")
        vm.selectedRoom = a
        XCTAssertEqual(vm.paramValue(for: card.id, paramID: "speed", default: -1), 42,
                       "the look never stopped — the screen keeps its real values")
        XCTAssertFalse(vm.valueScopes.isCurrent(identity),
                       "…while writes authored against the streaming run are fenced")
        XCTAssertTrue(vm.valueScopes.isCurrent(row.identity))
    }

    /// The seam fires in the SAME actor turn as the orchestrator's own fence:
    /// after the runtime is retired and BEFORE `stopSession()` suspends. A
    /// handler that ran later could act on a successor's row.
    func testReconcileAfterLoopInvokesTheStudioHandlerBeforeStoppingTheSession() async throws {
        let client = HueEntertainmentClient(
            bridgeID: "bridge-a", bridgeIP: "192.0.2.1",
            username: "spy-token", clientKeyHex: "00",
            restClient: WiringSpyClient(bridgeID: "bridge-a", bridgeName: "Bridge A",
                                        ip: "192.0.2.1", token: "spy-token"))
        orchestrator.testInstallStudioEntertainmentOwner(
            UnifiedOrchestrator.StudioEntertainmentOwner(
                bridgeID: "bridge-a", roomID: "room-a",
                engineKey: "party", configID: "cfg-1"),
            client: client)
        orchestrator.testForceStudioSessionTerminallyFailed = true
        orchestrator.testResetStopAudit()

        var handlerFired = false
        var stopSessionAlreadyRecordedWhenHandlerRan = true
        orchestrator.studioRuntimeEventHandler = { [orchestrator] _ in
            handlerFired = true
            stopSessionAlreadyRecordedWhenHandlerRan = orchestrator!.stopAuditEvents
                .contains { $0.operation == .clientStopSession }
        }

        await orchestrator.testReconcileStudioSessionAfterLoop(
            bridgeID: "bridge-a", roomID: "room-a")

        XCTAssertTrue(handlerFired, "the reconciliation tells Studio its session is gone")
        XCTAssertFalse(stopSessionAlreadyRecordedWhenHandlerRan,
                       "…before the teardown suspends on stopSession()")
        XCTAssertTrue(orchestrator.stopAuditEvents.contains { $0.operation == .clientStopSession },
                      "…and the teardown did then run")
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - R4D: coalesced per-target sends
    // ──────────────────────────────────────────────────────────

    /// Two params committed inside one debounce window reach the bridge
    /// TOGETHER — one `effects_v2` body per light, carrying both.
    ///
    /// Before R4D the slot held a single (number|color) pair, so the second
    /// commit cancelled the first param's task and the first param's value
    /// never reached the bridge at all.
    func testTwoParamsInOneDebounceWindowReachTheBridgeInOneV2BodyPerLight() async throws {
        let spy = WiringSpyClient(bridgeID: "bridge-a", bridgeName: "Bridge A",
                                  ip: "192.0.2.1", token: "spy-token")
        orchestrator.injectForTesting(clients: ["bridge-a": spy])

        let a = room("room-a")
        let candle = vm.effectCards.first { $0.id == "candle" }!
        let identity = vm.installRunningIdentity(
            room: a, card: candle, execution: .bridgeNative(effect: "candle"))
        vm.runningEffects[StudioSelectionKey(room: a)] = RunningEffect(
            cardID: candle.id, card: candle, room: a, lightIDs: ["L1", "L2"],
            isEntertainment: false, requestedTransport: nil, transportFallback: false,
            identity: identity, v2CapableLightIDs: ["L1", "L2"])

        // Two commits, no interval between them — exactly the double-drag that
        // used to lose the first value.
        edit(candle, on: a, paramID: "speed", value: 80)
        edit(candle, on: a, paramID: "warmth", value: 250)

        await vm.testFlushPendingParamSends(for: identity.targetKey)
        await drainStudioMailbox(bridgeID: "bridge-a", roomID: "room-a")

        XCTAssertEqual(spy.v2Puts.count, 2, "one PUT per v2-capable light — not one per param")
        XCTAssertEqual(spy.v2Puts.map(\.lightID), ["L1", "L2"])
        for put in spy.v2Puts {
            XCTAssertEqual(put.body["effect"] as? String, "candle")
            let params = try XCTUnwrap(put.body["parameters"] as? [String: Any],
                                       "the body must carry parameters")
            XCTAssertEqual(params["speed"] as? Double, 0.8, "speed survived the window")
            let temperature = try XCTUnwrap(params["color_temperature"] as? [String: Any])
            XCTAssertEqual(temperature["mirek"] as? Int, 250, "…and so did warmth")
        }
        XCTAssertTrue(spy.groupedEffectPuts.isEmpty,
                      "a v2-capable bridge-native look re-parameterizes the effect, "
                      + "never a grouped PUT that would fight it")
        XCTAssertNil(vm.pendingParamSends[identity.targetKey],
                     "the window is consumed by its send, not inherited by the next one")
    }

    /// Grouped-routed params coalesce the same way: brightness and the legacy
    /// colour fallback share ONE grouped PUT on a v1-only room.
    func testGroupedRoutedParamsCoalesceIntoOneGroupedPut() async throws {
        let spy = WiringSpyClient(bridgeID: "bridge-a", bridgeName: "Bridge A",
                                  ip: "192.0.2.1", token: "spy-token")
        orchestrator.injectForTesting(clients: ["bridge-a": spy])

        let a = room("room-a")
        let candle = vm.effectCards.first { $0.id == "candle" }!
        let identity = vm.installRunningIdentity(
            room: a, card: candle, execution: .bridgeNative(effect: "candle"))
        vm.runningEffects[StudioSelectionKey(room: a)] = RunningEffect(
            cardID: candle.id, card: candle, room: a, lightIDs: ["L1"],
            isEntertainment: false, requestedTransport: nil, transportFallback: false,
            identity: identity, v2CapableLightIDs: [])   // v1-only room

        edit(candle, on: a, paramID: "brightness", value: 55)
        edit(candle, on: a, paramID: "warmth", value: 300)

        await vm.testFlushPendingParamSends(for: identity.targetKey)
        await drainStudioMailbox(bridgeID: "bridge-a", roomID: "room-a")

        XCTAssertEqual(spy.groupedEffectPuts.count, 1,
                       "one PUT carrying every grouped field the window changed")
        XCTAssertEqual(spy.groupedEffectPuts.first?.brightness, 55)
        XCTAssertEqual(spy.groupedEffectPuts.first?.mirek, 300)
        XCTAssertTrue(spy.v2Puts.isEmpty, "there is no v2-capable light to address")
    }

    /// A window whose instance was superseded between the last commit and the
    /// send reaches the bridge not at all.
    func testACoalescedWindowIsFencedOnTheCapturedIdentity() async {
        let spy = WiringSpyClient(bridgeID: "bridge-a", bridgeName: "Bridge A",
                                  ip: "192.0.2.1", token: "spy-token")
        orchestrator.injectForTesting(clients: ["bridge-a": spy])

        let a = room("room-a")
        let candle = vm.effectCards.first { $0.id == "candle" }!
        let identity = vm.installRunningIdentity(
            room: a, card: candle, execution: .bridgeNative(effect: "candle"))
        vm.runningEffects[StudioSelectionKey(room: a)] = RunningEffect(
            cardID: candle.id, card: candle, room: a, lightIDs: ["L1"],
            isEntertainment: false, requestedTransport: nil, transportFallback: false,
            identity: identity, v2CapableLightIDs: ["L1"])

        edit(candle, on: a, paramID: "speed", value: 80)
        vm.rekeyRunningInstance(at: StudioSelectionKey(room: a), reason: .transportChanged)

        await vm.testFlushPendingParamSends(for: identity.targetKey)
        await drainStudioMailbox(bridgeID: "bridge-a", roomID: "room-a")

        XCTAssertTrue(spy.v2Puts.isEmpty,
                      "the rekey retired the window; nothing authored before it may land")
    }

    /// Drain the bridge's Studio mailbox deterministically.
    ///
    /// `RestSender` flushes on an unstructured task, so "the write has reached
    /// the client" cannot be observed by returning from `enqueue`. Instead a
    /// sentinel is enqueued on a DIFFERENT scope: the sender's cross-scope
    /// order is FIFO, so the sentinel's closure cannot run until the Studio
    /// scope's closure has finished. No sleeps, no polling.
    private func drainStudioMailbox(bridgeID: String, roomID: String) async {
        let sender = orchestrator.testRestSender(for: bridgeID)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let box = ContinuationBox(cont)
            Task {
                await sender.enqueue(
                    scope: RestScope(roomID: "\(roomID)-drain-sentinel", owner: .studio)
                ) { _ in box.resume() }
            }
        }
    }
}

/// One-shot continuation carrier — the mailbox closure is `@Sendable`, and a
/// `CheckedContinuation` captured directly would not cross that boundary.
private final class ContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<Void, Never>?
    init(_ cont: CheckedContinuation<Void, Never>) { self.cont = cont }
    func resume() {
        lock.lock()
        let pending = cont
        cont = nil
        lock.unlock()
        pending?.resume()
    }
}
