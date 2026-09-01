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
        XCTAssertTrue(vm.runningEffects.isEmpty)
    }
}
