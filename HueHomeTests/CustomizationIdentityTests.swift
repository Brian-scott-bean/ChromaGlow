//
//  CustomizationIdentityTests.swift
//  HueHomeTests
//
//  Unified Customization Engine — Slice 1 race and identity proofs.
//
//  Every test here is deterministic: the fence and the value scopes are pure
//  and synchronous, so a race is expressed by ORDERING calls, never by
//  sleeping. Audit §24 asks for exactly this.
//

import XCTest
@testable import HueHome

// A stand-in for SwiftUI's `Color` so the pure layer stays testable without
// importing SwiftUI into the assertions.
private struct TestColor: Hashable, Sendable {
    let tag: String
}

private typealias Scopes = CustomizationValueScopes<TestColor>

@MainActor
final class CustomizationIdentityTests: XCTestCase {

    // ── Builders ────────────────────────────────────────────────

    private func identity(bridge: String?,
                          group: String = "room-1",
                          kind: RoomDisplayItem.Kind = .room,
                          card: String = "party",
                          engine: String = "party",
                          generation: UInt64 = 1) -> RunningLookIdentity {
        RunningLookIdentity(bridgeID: bridge,
                            groupID: group,
                            kind: kind,
                            cardID: card,
                            execution: .appDriven(engineKey: engine),
                            generation: CustomizationGeneration(generation))
    }

    private func speed(_ card: String = "party") -> CustomizationControlID {
        CustomizationControlID(cardID: card, paramID: "speed")
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - Identity distinctness
    // ──────────────────────────────────────────────────────────

    /// Round 4c's defect class, now expressed on the new key: two bridges can
    /// expose the SAME Hue room id, and they must never collapse.
    func testSameRoomIDOnTwoBridgesAreDistinctIdentities() {
        let a = identity(bridge: "bridge-A", group: "shared-room-id")
        let b = identity(bridge: "bridge-B", group: "shared-room-id")

        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a.targetKey, b.targetKey)
        XCTAssertFalse(a.addressesSamePlace(as: b))
    }

    /// `RoomEffectKey` has no `kind`, so a room and a zone sharing an id
    /// collapse there. `RunningLookIdentity` must not inherit that.
    func testRoomAndZoneSharingAnIDAreDistinctEvenThoughEffectKeysCollide() {
        let room = identity(bridge: "bridge-A", group: "id-7", kind: .room)
        let zone = identity(bridge: "bridge-A", group: "id-7", kind: .zone)

        XCTAssertNotEqual(room, zone)
        XCTAssertNotEqual(room.targetKey, zone.targetKey)
        XCTAssertFalse(room.addressesSamePlace(as: zone))

        // Documents the known lossiness of the OLD key — if this ever starts
        // failing, `RoomEffectKey` gained a `kind` and the comment in
        // `RunningLookIdentity.effectKey` needs updating.
        XCTAssertEqual(room.effectKey, zone.effectKey)
    }

    func testGenerationParticipatesInEqualityButNotInTargetKey() {
        let first  = identity(bridge: "b", generation: 1)
        let second = identity(bridge: "b", generation: 2)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.targetKey, second.targetKey)
        XCTAssertTrue(first.addressesSameTarget(as: second))
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - The fence
    // ──────────────────────────────────────────────────────────

    func testFenceCommitsWhenNothingMoved() {
        let captured = identity(bridge: "b")
        XCTAssertTrue(CustomizationFence.verdict(captured: captured, live: captured).isCommit)
    }

    func testFenceDropsWriteWhoseTargetMoved() {
        let captured = identity(bridge: "bridge-A")
        let live     = identity(bridge: "bridge-B")

        XCTAssertEqual(CustomizationFence.verdict(captured: captured, live: live).dropReason,
                       .targetChanged)
    }

    func testFenceDropsWriteAfterCardReplacement() {
        let captured = identity(bridge: "b", card: "party", engine: "party")
        let live     = identity(bridge: "b", card: "strobe", engine: "strobe")

        XCTAssertEqual(CustomizationFence.verdict(captured: captured, live: live).dropReason,
                       .lookReplaced)
    }

    func testFenceDropsWriteFromAnOlderRunOfTheSameLook() {
        let captured = identity(bridge: "b", generation: 1)
        let live     = identity(bridge: "b", generation: 2)

        XCTAssertEqual(CustomizationFence.verdict(captured: captured, live: live).dropReason,
                       .staleGeneration)
    }

    func testFenceDropsWriteWhenNothingIsRunning() {
        XCTAssertEqual(CustomizationFence.verdict(captured: identity(bridge: "b"), live: nil).dropReason,
                       .nothingRunning)
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - Multi-bridge live-value independence  (audit §16)
    // ──────────────────────────────────────────────────────────

    /// The headline defect: on current `main` this is impossible, because
    /// `paramValues` is keyed by card id alone.
    func testSameCardOnTwoBridgesHoldsIndependentLiveValues() {
        let scopes = Scopes()
        let a = identity(bridge: "bridge-A", group: "shared-room-id")
        let b = identity(bridge: "bridge-B", group: "shared-room-id")

        scopes.startRunning(a)
        scopes.startRunning(b)

        scopes.commit(captured: a, control: speed(), number: 20)
        scopes.commit(captured: b, control: speed(), number: 80)

        XCTAssertEqual(scopes.live(for: a).numbers["speed"], 20)
        XCTAssertEqual(scopes.live(for: b).numbers["speed"], 80)
        XCTAssertEqual(scopes.runningTargetCount, 2)
    }

    func testStoppingOneBridgeLeavesTheOtherRunning() {
        let scopes = Scopes()
        let a = identity(bridge: "bridge-A")
        let b = identity(bridge: "bridge-B")
        scopes.startRunning(a)
        scopes.startRunning(b)
        scopes.commit(captured: b, control: speed(), number: 55)

        scopes.stopRunning(a)

        XCTAssertNil(scopes.liveIdentity(for: a))
        XCTAssertEqual(scopes.live(for: b).numbers["speed"], 55)
    }

    /// Today `resetParams` nils the card-global dict, so this cannot hold.
    func testResettingOneInstanceDoesNotDisturbTheOther() {
        let scopes = Scopes()
        let a = identity(bridge: "bridge-A")
        let b = identity(bridge: "bridge-B")
        scopes.setDefaults(CustomizationValueSet(numbers: ["speed": 50]), forCard: "party")
        scopes.startRunning(a)
        scopes.startRunning(b)
        scopes.commit(captured: a, control: speed(), number: 10)
        scopes.commit(captured: b, control: speed(), number: 90)

        scopes.reset(a, newGeneration: CustomizationGeneration(2))

        XCTAssertEqual(scopes.live(for: a).numbers["speed"], 50, "reset instance returns to defaults")
        XCTAssertEqual(scopes.live(for: b).numbers["speed"], 90, "other bridge is untouched")
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - Draft races  (spec §18.3)
    // ──────────────────────────────────────────────────────────

    /// A drag begun on room A must never commit to room B.
    func testDraftStartedOnOneRoomDoesNotCommitToAnother() {
        let scopes = Scopes()
        let a = identity(bridge: "bridge-A", group: "room-A")
        let b = identity(bridge: "bridge-B", group: "room-B")
        scopes.startRunning(a)
        scopes.startRunning(b)

        scopes.beginDraft(control: speed(), on: a)
        scopes.updateDraft(number: 42)
        scopes.stopRunning(a)                  // A goes away mid-gesture

        let result = scopes.commitDraft()

        XCTAssertEqual(result.dropReason, .nothingRunning)
        XCTAssertNil(scopes.live(for: b).numbers["speed"], "B never saw A's draft")
    }

    func testDraftSurvivesAnUnrelatedSelectionChange() {
        let scopes = Scopes()
        let a = identity(bridge: "bridge-A")
        let b = identity(bridge: "bridge-B")
        scopes.startRunning(a)
        scopes.startRunning(b)

        scopes.beginDraft(control: speed(), on: a)
        scopes.updateDraft(number: 33)
        // The user's eye moves to B, but the finger is still on A's control.
        let result = scopes.commitDraft()

        XCTAssertTrue(result.didCommit)
        XCTAssertEqual(scopes.live(for: a).numbers["speed"], 33)
        XCTAssertNil(scopes.live(for: b).numbers["speed"])
    }

    func testCancelledDraftCommitsNothing() {
        let scopes = Scopes()
        let a = identity(bridge: "bridge-A")
        scopes.startRunning(a)

        scopes.beginDraft(control: speed(), on: a)
        scopes.updateDraft(number: 77)
        scopes.cancelDraft()

        XCTAssertEqual(scopes.commitDraft().dropReason, .nothingRunning)
        XCTAssertNil(scopes.live(for: a).numbers["speed"])
    }

    func testDraftForAControlOnAnotherCardIsRefused() {
        let scopes = Scopes()
        let a = identity(bridge: "b", card: "party", engine: "party")
        scopes.startRunning(a)

        let result = scopes.commit(captured: a,
                                   control: CustomizationControlID(cardID: "strobe",
                                                                   paramID: "speed"),
                                   number: 5)

        XCTAssertEqual(result.dropReason, .lookReplaced)
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - Late writes  (audit §24)
    // ──────────────────────────────────────────────────────────

    func testDebouncedWriteLandingAfterStopIsDropped() {
        let scopes = Scopes()
        let running = identity(bridge: "b")
        scopes.startRunning(running)

        let captured = running          // debounce captured this
        scopes.stopRunning(running)     // …then the user hit Stop

        XCTAssertEqual(scopes.commit(captured: captured, control: speed(), number: 99).dropReason,
                       .nothingRunning)
    }

    func testResetDefeatsAPendingWrite() {
        let scopes = Scopes()
        let running = identity(bridge: "b", generation: 1)
        scopes.setDefaults(CustomizationValueSet(numbers: ["speed": 50]), forCard: "party")
        scopes.startRunning(running)

        let captured = running                                    // pending write
        scopes.reset(running, newGeneration: CustomizationGeneration(2))

        XCTAssertEqual(scopes.commit(captured: captured, control: speed(), number: 99).dropReason,
                       .staleGeneration)
        XCTAssertEqual(scopes.live(for: running).numbers["speed"], 50,
                       "reset value survives the stale write")
    }

    func testCardReplacementDefeatsAPendingWrite() {
        let scopes = Scopes()
        let party  = identity(bridge: "b", card: "party",  engine: "party")
        let strobe = identity(bridge: "b", card: "strobe", engine: "strobe")
        scopes.startRunning(party)

        let captured = party
        scopes.stopRunning(party)
        scopes.startRunning(strobe)

        XCTAssertEqual(scopes.commit(captured: captured, control: speed(), number: 12).dropReason,
                       .nothingRunning)
        XCTAssertNil(scopes.live(for: strobe).numbers["speed"])
    }

    /// A capability refresh, transport change or bridge reconnect bumps the
    /// generation so in-flight writes are fenced — but it must NOT blank what
    /// is on screen. The look never stopped.
    func testTransportChangeFencesWritesWithoutLosingLiveValues() {
        let scopes = Scopes()
        let g1 = identity(bridge: "b", generation: 1)
        scopes.startRunning(g1)
        scopes.commit(captured: g1, control: speed(), number: 64)

        let g2 = scopes.rekey(g1, to: CustomizationGeneration(2))
        XCTAssertNotNil(g2)

        XCTAssertEqual(scopes.live(for: g1).numbers["speed"], 64,
                       "live value survives the generation bump")
        XCTAssertEqual(scopes.commit(captured: g1, control: speed(), number: 1).dropReason,
                       .staleGeneration,
                       "a write authored before the bump is refused")
        XCTAssertTrue(scopes.commit(captured: g2!, control: speed(), number: 70).didCommit,
                      "a write authored after the bump lands")
    }

    func testBridgeReconnectFencesInFlightWritesForThatTargetOnly() {
        let scopes = Scopes()
        let a1 = identity(bridge: "bridge-A", generation: 1)
        let b1 = identity(bridge: "bridge-B", generation: 1)
        scopes.startRunning(a1)
        scopes.startRunning(b1)

        // Only bridge A reconnected.
        _ = scopes.rekey(a1, to: CustomizationGeneration(2))

        XCTAssertEqual(scopes.commit(captured: a1, control: speed(), number: 5).dropReason,
                       .staleGeneration)
        XCTAssertTrue(scopes.commit(captured: b1, control: speed(), number: 5).didCommit,
                      "bridge B was never disturbed")
    }

    func testRekeyOfANonRunningTargetIsRefused() {
        let scopes = Scopes()
        XCTAssertNil(scopes.rekey(identity(bridge: "b"), to: CustomizationGeneration(2)))
    }

    func testStopAllClearsEveryTarget() {
        let scopes = Scopes()
        scopes.startRunning(identity(bridge: "bridge-A"))
        scopes.startRunning(identity(bridge: "bridge-B"))
        XCTAssertEqual(scopes.runningTargetCount, 2)

        scopes.stopAll()

        XCTAssertEqual(scopes.runningTargetCount, 0)
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - Generation counter
    // ──────────────────────────────────────────────────────────

    func testGenerationCounterIsMonotonicAndRecordsItsReason() {
        let counter = CustomizationGenerationCounter()
        XCTAssertEqual(counter.current, .initial)

        let first = counter.bump(.selectionChanged)
        let second = counter.bump(.transportChanged)

        XCTAssertLessThan(first, second)
        XCTAssertEqual(counter.lastReason, .transportChanged)
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - Scope separation  (spec §18)
    // ──────────────────────────────────────────────────────────

    func testLiveValuesLayerOverPersistedDefaults() {
        let scopes = Scopes()
        scopes.setDefaults(CustomizationValueSet(numbers: ["speed": 50, "brightness": 90]),
                           forCard: "party")
        let running = identity(bridge: "b")
        scopes.startRunning(running)
        scopes.commit(captured: running, control: speed(), number: 20)

        let live = scopes.live(for: running)
        XCTAssertEqual(live.numbers["speed"], 20,      "live value wins")
        XCTAssertEqual(live.numbers["brightness"], 90, "untouched default shows through")
    }

    func testClearingDefaultsDoesNotStopARunningInstance() {
        let scopes = Scopes()
        scopes.setDefaults(CustomizationValueSet(numbers: ["speed": 50]), forCard: "party")
        let running = identity(bridge: "b")
        scopes.startRunning(running)
        scopes.commit(captured: running, control: speed(), number: 20)

        scopes.clearDefaults(forCard: "party")

        XCTAssertNotNil(scopes.liveIdentity(for: running))
        XCTAssertEqual(scopes.live(for: running).numbers["speed"], 20)
    }
}
