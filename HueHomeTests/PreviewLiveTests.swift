//
//  PreviewLiveTests.swift
//  HueHomeTests
//
//  Unified Customization Engine — Slice 2. Deterministic Preview Live
//  restore fencing (spec §16.5 / audit §24): every race is call ordering
//  against the pure fence — no sleeps.
//

import XCTest
@testable import HueHome

@MainActor
final class PreviewLiveTests: XCTestCase {

    private typealias Machine = PreviewLiveMachine<String>
    private typealias Values = CustomizationValueSet<String>

    private func identity(card: String = "party", group: String = "room-a",
                          kind: RoomDisplayItem.Kind = .room,
                          generation: UInt64 = 1) -> RunningLookIdentity {
        RunningLookIdentity(bridgeID: "bridge-a", groupID: group, kind: kind,
                            cardID: card, execution: .appDriven(engineKey: card),
                            generation: CustomizationGeneration(generation))
    }

    /// Cancel restores the EXACT previous look and values when the audition
    /// is still what runs on the target.
    func testCancelRestoresTheExactPreviousSnapshot() {
        let machine = Machine()
        let previous = identity(card: "party", generation: 1)
        let values = Values(numbers: ["speed": 42], colors: ["color": "amber"])

        _ = machine.begin(previous: previous, previousValues: values,
                          previousWasStreaming: true)
        let preview = identity(card: "strobe", generation: 2)
        machine.previewStarted(preview)

        guard case .restore(let snap) = machine.cancelVerdict(live: preview) else {
            return XCTFail("audition unchanged — cancel must restore")
        }
        XCTAssertEqual(snap.previous, previous)
        XCTAssertEqual(snap.previousValues, values, "exact live values, not defaults")
        XCTAssertTrue(snap.previousWasStreaming)
        XCTAssertFalse(machine.isPreviewing, "a preview never outlives its answer")
    }

    /// The selection moved to another target mid-preview — the restore must
    /// not cross identity.
    func testSelectionChangeFencesTheRestore() {
        let machine = Machine()
        _ = machine.begin(previous: identity(generation: 1),
                          previousValues: Values(), previousWasStreaming: false)
        machine.previewStarted(identity(card: "strobe", generation: 2))

        let elsewhere = identity(card: "strobe", group: "room-b", generation: 2)
        guard case .drop(let reason) = machine.cancelVerdict(live: elsewhere) else {
            return XCTFail("a restore aimed at room-a must not land via room-b")
        }
        XCTAssertEqual(reason, .targetChanged)
    }

    /// Stop during the preview — nothing runs, nothing may be resurrected.
    func testStopFencesTheRestore() {
        let machine = Machine()
        _ = machine.begin(previous: identity(generation: 1),
                          previousValues: Values(), previousWasStreaming: false)
        machine.previewStarted(identity(card: "strobe", generation: 2))

        guard case .drop(let reason) = machine.cancelVerdict(live: nil) else {
            return XCTFail("a stop must fence the restore")
        }
        XCTAssertEqual(reason, .nothingRunning)
    }

    /// The auditioned card was replaced by yet another look — the restore
    /// belongs to a world that no longer exists.
    func testCardReplacementFencesTheRestore() {
        let machine = Machine()
        _ = machine.begin(previous: identity(generation: 1),
                          previousValues: Values(), previousWasStreaming: false)
        machine.previewStarted(identity(card: "strobe", generation: 2))

        let replacement = identity(card: "thunderstorm", generation: 3)
        guard case .drop(let reason) = machine.cancelVerdict(live: replacement) else {
            return XCTFail("a replacement must fence the restore")
        }
        XCTAssertEqual(reason, .lookReplaced)
    }

    /// A generation bump (transport change, reconnect) on the SAME preview
    /// look fences the stale restore.
    func testGenerationBumpFencesTheRestore() {
        let machine = Machine()
        _ = machine.begin(previous: identity(generation: 1),
                          previousValues: Values(), previousWasStreaming: false)
        machine.previewStarted(identity(card: "strobe", generation: 2))

        let rekeyed = identity(card: "strobe", generation: 7)
        guard case .drop(let reason) = machine.cancelVerdict(live: rekeyed) else {
            return XCTFail("a stale generation must fence the restore")
        }
        XCTAssertEqual(reason, .staleGeneration)
    }

    /// A room and a zone sharing an id are different targets — the fence
    /// carries kind.
    func testRoomVsZoneFencesTheRestore() {
        let machine = Machine()
        _ = machine.begin(previous: identity(generation: 1),
                          previousValues: Values(), previousWasStreaming: false)
        machine.previewStarted(identity(card: "strobe", kind: .room, generation: 2))

        let zoneTwin = identity(card: "strobe", kind: .zone, generation: 2)
        guard case .drop = machine.cancelVerdict(live: zoneTwin) else {
            return XCTFail("a zone twin must not satisfy a room's restore fence")
        }
    }

    /// Apply commits: the snapshot is discarded and a later cancel restores
    /// nothing.
    func testApplyCommitsAndDiscardsTheSnapshot() {
        let machine = Machine()
        _ = machine.begin(previous: identity(generation: 1),
                          previousValues: Values(), previousWasStreaming: false)
        let preview = identity(card: "strobe", generation: 2)
        machine.previewStarted(preview)

        machine.commit()
        XCTAssertFalse(machine.isPreviewing)
        guard case .drop = machine.cancelVerdict(live: preview) else {
            return XCTFail("after apply there is nothing to restore")
        }
    }

    /// A snapshot without a started audition changed nothing — cancel is a
    /// no-op drop, never a blind restore.
    func testCancelBeforeTheAuditionStartsRestoresNothing() {
        let machine = Machine()
        _ = machine.begin(previous: identity(generation: 1),
                          previousValues: Values(), previousWasStreaming: false)
        guard case .drop = machine.cancelVerdict(live: identity(generation: 1)) else {
            return XCTFail("nothing was changed, so nothing may be restored")
        }
    }

    /// Auditioning from an IDLE target: cancel just stops the preview —
    /// there is no previous look to bring back, and the snapshot says so.
    func testIdleTargetSnapshotCarriesNoPreviousLook() {
        let machine = Machine()
        let snap = machine.begin(previous: nil, previousValues: nil,
                                 previousWasStreaming: false)
        XCTAssertNil(snap.previous)
        machine.previewStarted(identity(card: "strobe", generation: 2))
        guard case .restore(let restored) = machine.cancelVerdict(
            live: identity(card: "strobe", generation: 2)) else {
            return XCTFail("cancel on an untouched audition is answerable")
        }
        XCTAssertNil(restored.previous, "restore of an idle target = stop the preview")
    }
}
