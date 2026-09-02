//
//  StudioPreviewLiveProductionTests.swift
//  HueHomeTests
//
//  Unified Customization Engine — R4C (Preview Live on the PRODUCTION path).
//
//  `PreviewLiveTests` drives the pure machine: snapshot, fence, verdict. It
//  cannot see any of the four defects that actually shipped, because all four
//  live in the wiring around the machine:
//
//    1. `isPreviewingLive` was set BEFORE the apply and never rolled back, so
//       a refusal (Reduce Motion, a handoff prompt, an unsupported room) left
//       the browser offering "Keep It / Put It Back" for a look that never
//       started.
//    2. Stop and Stop All never cleared the preview state, so "Put It Back"
//       survived the target it was fenced on.
//    3. A `.drop` verdict was silent — the button did nothing and said nothing.
//    4. The restore overwrote the card's PERSISTED defaults before an apply
//       that could itself bail, corrupting state the user meets again next
//       time they tap the card.
//
//  These tests drive the same API the shipping UI drives — `beginPreviewLive`,
//  `cancelPreviewLive`, `commitPreviewLive`, `stopActiveTarget`, `stopAll` —
//  against a real orchestrator with a recording bridge client.
//
//  DETERMINISM (Guard 12): no `Task.sleep`, no `XCTWaiter`, no
//  `wait(for:timeout:)`. Every await is a production call that completes.
//

import XCTest
import SwiftUI
@testable import HueHome

// MARK: - Spy

/// Records every bridge write so "the cancel touched nothing" is a counted
/// fact rather than an assertion about code shape.
private final class PreviewSpyClient: BridgeAPIClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _writes: [String] = []

    /// Every mutating request this client was asked to make, in order.
    var writes: [String] {
        lock.lock(); defer { lock.unlock() }
        return _writes
    }

    private func record(_ entry: String) {
        lock.lock(); _writes.append(entry); lock.unlock()
    }

    override func fetchLights() async throws -> [HueLight] { [] }
    override func fetchRooms() async throws -> [HueRoom] { [] }
    override func fetchZones() async throws -> [HueZone] { [] }
    override func fetchGroupedLights() async throws -> [HueGroupedLight] { [] }
    override func fetchScenes() async throws -> [HueScene] { [] }
    override func fetchLightIDsForGroup(groupedLightID: String) async throws -> [String] { [] }

    override func setGroupedLightState(id: String, on: Bool, brightness: Double) async throws {
        record("groupedState:\(id):bri=\(Int(brightness.rounded()))")
    }
    override func setGroupedLightBrightness(id: String, brightness: Double) async throws {
        record("groupedBrightness:\(id)")
    }
    override func setGroupedLight(id: String, on: Bool) async throws {
        record("groupedPower:\(id):\(on)")
    }
    override func setGroupedLightEffect(
        id: String, on: Bool?, brightness: Double?,
        xy: (Double, Double)?, mirek: Int?, duration: Int
    ) async throws {
        record("groupedEffect:\(id)")
    }
    override func setLightNativeEffect(id: String, effect: String) async throws {
        record("lightEffect:\(id):\(effect)")
    }
    override func setLightColor(id: String, x: Double, y: Double) async throws {
        record("lightColor:\(id)")
    }
    override func get(path: String, ip: String, token: String) async throws -> Data {
        Data(#"{"data": []}"#.utf8)
    }
    override func put(path: String, body: [String: Any], ip: String, token: String) async throws -> Data {
        record("put:\(path)")
        return Data("{}".utf8)
    }
}

// MARK: - Tests

@MainActor
final class StudioPreviewLiveProductionTests: XCTestCase {

    private var vm: StudioViewModel!
    private var orchestrator: UnifiedOrchestrator!
    private var bridge: PreviewSpyClient!

    override func setUp() async throws {
        try await super.setUp()
        bridge = PreviewSpyClient(bridgeID: "bridge-a", bridgeName: "Bridge A",
                                  ip: "192.0.2.1", token: "spy-token")
        orchestrator = UnifiedOrchestrator()
        orchestrator.injectForTesting(clients: ["bridge-a": bridge])
        vm = StudioViewModel()
        vm.configure(orchestrator: orchestrator)
    }

    override func tearDown() async throws {
        await orchestrator.stopStudioMode()
        vm = nil
        orchestrator = nil
        bridge = nil
        try await super.tearDown()
    }

    // ── Fixtures ────────────────────────────────────────────────

    private func room(_ id: String = "room-a") -> RoomDisplayItem {
        RoomDisplayItem(
            kind: .room, id: id, name: id, archetype: nil, isOn: true, brightness: 60,
            groupedLightID: "gl-\(id)", lightCount: 2, bridgeID: "bridge-a",
            childResourceRefs: [(rid: "L1", rtype: "light")])
    }

    private func card(_ id: String) throws -> StudioCard {
        try XCTUnwrap((vm.liveModeCards + vm.effectCards).first { $0.id == id })
    }

    /// Start Ambient on `target` through the real apply, then move one live
    /// value off its catalog default so a restore has something exact to prove.
    @discardableResult
    private func startAmbient(on target: RoomDisplayItem, speed: Double) async throws -> StudioCard {
        let ambient = try card("ambient")
        vm.selectedRoom = target
        await vm.apply(ambient, roomOverride: target, preferEntertainmentOverride: nil)
        XCTAssertEqual(vm.runningEffect(for: target)?.cardID, "ambient",
                       "the previous look must genuinely be running before an audition")
        let session = try XCTUnwrap(vm.beginParamEdit(cardID: "ambient", paramID: "speed"))
        vm.updateParamEdit(session, value: speed)
        vm.endParamEdit(session)
        return ambient
    }

    // ── Cancel: the exact restore ───────────────────────────────

    /// "Put It Back" reinstates the previous look AND its exact live values on
    /// the exact target — not the card's catalog defaults, and not the values
    /// the audition happened to leave behind.
    ///
    /// The scopes are FORCED APART first (L1). A live edit writes scope 2 AND
    /// the card's persisted defaults, so asserting "speed is 33" after a
    /// restore proved nothing while both scopes already said 33 — the restore
    /// could have read either, or neither. Here the defaults are moved to a
    /// DIFFERENT value than the running instance before the audition, so only
    /// a restore that reads the SNAPSHOT can produce the instance's value. The
    /// restored identity is checked whole, too: same place, same look, same
    /// execution, under a NEWER generation.
    func testCancelRestoresThePreviousLooksExactLiveValuesOnTheExactTarget() async throws {
        let target = room()
        try await startAmbient(on: target, speed: 33)
        let before = try XCTUnwrap(vm.runningEffect(for: target))
        // A colour on the exact instance too — numbers alone would not catch a
        // restore that dropped the colour half of the snapshot.
        let colorSession = try XCTUnwrap(
            vm.beginParamEdit(cardID: "ambient", paramID: "base_color"))
        vm.updateParamEdit(colorSession, color: .green)
        vm.endParamEdit(colorSession)

        // FORCE scope 1 ≠ scope 2: park the selection on an idle room, where a
        // one-shot write is a defaults-only write, and move the defaults away
        // from what the running instance holds.
        let idle = room("room-idle")
        vm.selectedRoom = idle
        vm.commitParam(cardID: "ambient", paramID: "speed", value: 91)
        vm.commitColorParam(cardID: "ambient", paramID: "base_color", color: .red)
        vm.selectedRoom = target
        XCTAssertEqual(vm.valueScopes.defaults(forCard: "ambient").numbers["speed"], 91,
                       "the defaults now disagree with the running instance")
        XCTAssertEqual(vm.paramValue(for: "ambient", paramID: "speed", default: -1), 33,
                       "…which still holds its own value")

        let candle = try card("candle")
        await vm.beginPreviewLive(card: candle)
        XCTAssertEqual(vm.runningEffect(for: target)?.cardID, "candle", "the audition started")
        XCTAssertTrue(vm.isPreviewingLive, "…and the browser can offer Put It Back")
        XCTAssertEqual(vm.previewAuditionCardID, "candle",
                       "the audition names the card it belongs to")

        await vm.cancelPreviewLive()

        let restored = try XCTUnwrap(vm.runningEffect(for: target))
        XCTAssertEqual(restored.cardID, "ambient",
                       "the previous look is back on the exact target")
        vm.selectedRoom = target
        XCTAssertEqual(vm.paramValue(for: "ambient", paramID: "speed", default: -1), 33,
                       "…with the SNAPSHOT's values, not the defaults that moved to 91")
        XCTAssertEqual(vm.paramColor(for: "ambient", paramID: "base_color"), Color.green,
                       "…colours included")

        // The identity is the same PLACE and the same LOOK, under a new run.
        XCTAssertEqual(restored.identity.bridgeID, before.identity.bridgeID)
        XCTAssertEqual(restored.identity.groupID, before.identity.groupID)
        XCTAssertEqual(restored.identity.kind, before.identity.kind)
        XCTAssertEqual(restored.identity.cardID, before.identity.cardID)
        XCTAssertEqual(restored.identity.execution, before.identity.execution)
        XCTAssertGreaterThan(restored.identity.generation, before.identity.generation,
                             "a restore is a genuine restart, so it mints a newer generation")

        XCTAssertFalse(vm.isPreviewingLive, "the audition is over")
        XCTAssertNil(vm.previewLiveRoom)
        XCTAssertNil(vm.previewAuditionCardID)
        XCTAssertFalse(vm.previewLive.isPreviewing)
    }

    // ── Refusal: nothing started, so nothing is offered ─────────

    /// A refused audition rolls the preview state back completely. Strobe under
    /// Reduce Motion is the exact refusal that ships: it returns from the very
    /// top of `apply`, before anything is prepared or torn down.
    func testARefusedAuditionRollsThePreviewStateBackAndLeavesThePreviousLookAlone() async throws {
        let target = room()
        try await startAmbient(on: target, speed: 33)
        let strobe = try card("strobe")
        vm.forcedReduceMotionForTesting = true

        await vm.beginPreviewLive(card: strobe)

        XCTAssertEqual(vm.studioNotice?.message, StudioSafetyCopy.strobeReduceMotion,
                       "the refusal is SAID")
        XCTAssertFalse(vm.isPreviewingLive,
                       "no audition started, so the browser must not offer to undo one")
        XCTAssertFalse(vm.previewLive.isPreviewing, "the snapshot was consumed, not left dangling")
        XCTAssertNil(vm.previewLive.previewIdentity)
        XCTAssertNil(vm.previewLiveRoom)
        XCTAssertEqual(vm.runningEffect(for: target)?.cardID, "ambient",
                       "the previous look is untouched")
        vm.selectedRoom = target
        XCTAssertEqual(vm.paramValue(for: "ambient", paramID: "speed", default: -1), 33,
                       "…including its live values")
    }

    // ── The world moved on ──────────────────────────────────────

    /// The audition's target is stopped while the audition is live. The
    /// snapshot can never be restored onto it now, so the state is consumed at
    /// the stop, the user is TOLD, and the later cancel writes nothing at all.
    func testStoppingTheAuditionedTargetDropsTheRestoreSaysSoAndWritesNothing() async throws {
        let target = room()
        try await startAmbient(on: target, speed: 33)
        let candle = try card("candle")
        await vm.beginPreviewLive(card: candle)
        XCTAssertTrue(vm.isPreviewingLive)

        await vm.stopActiveTarget(StudioSelectionKey(room: target))

        XCTAssertEqual(vm.studioNotice?.message, PreviewLiveCopy.restoreDropped,
                       "the audition's target went away — say so, do not fail silently")
        XCTAssertFalse(vm.isPreviewingLive, "Put It Back is withdrawn with its target")
        XCTAssertNil(vm.previewLive.previewIdentity)

        let writesBeforeCancel = bridge.writes.count
        await vm.cancelPreviewLive()

        XCTAssertEqual(bridge.writes.count, writesBeforeCancel,
                       "the cancel restored nothing, so it wrote nothing")
        XCTAssertNil(vm.runningEffect(for: target),
                     "…and did not resurrect a look on a stopped room")
    }

    /// Stop All clears the audition unconditionally: no target survives, so no
    /// snapshot can be restored onto one.
    func testStopAllClearsTheAudition() async throws {
        let target = room()
        try await startAmbient(on: target, speed: 33)
        let candle = try card("candle")
        await vm.beginPreviewLive(card: candle)
        XCTAssertTrue(vm.isPreviewingLive)

        await vm.stopAll()

        XCTAssertFalse(vm.isPreviewingLive)
        XCTAssertFalse(vm.previewLive.isPreviewing)
        XCTAssertNil(vm.previewLive.previewIdentity)
        XCTAssertNil(vm.previewLiveRoom)
        XCTAssertTrue(vm.runningEffects.isEmpty)
    }

    // ── Keep It ─────────────────────────────────────────────────

    /// "Keep It" discards the snapshot and leaves the audition running as an
    /// ordinary instance — current, editable, and with nothing left to undo.
    func testCommitKeepsTheAuditionRunningUnderItsCurrentIdentity() async throws {
        let target = room()
        try await startAmbient(on: target, speed: 33)
        let candle = try card("candle")
        await vm.beginPreviewLive(card: candle)

        await vm.commitPreviewLive()

        let kept = try XCTUnwrap(vm.runningEffect(for: target))
        XCTAssertEqual(kept.cardID, "candle", "the audition is the keeper")
        XCTAssertTrue(vm.valueScopes.isCurrent(kept.identity),
                      "…and it is an ordinary current instance, editable like any other")
        XCTAssertFalse(vm.isPreviewingLive)
        XCTAssertFalse(vm.previewLive.isPreviewing)
        XCTAssertNil(vm.previewLive.previewIdentity)
        XCTAssertNil(vm.previewLiveRoom)
    }

    // ── Auditioning twice ───────────────────────────────────────

    /// A second audition chains onto the ORIGINAL snapshot. Re-snapshotting
    /// would capture the FIRST audition as "the previous look", so Put It Back
    /// would restore the thing the user had already rejected and the look they
    /// actually started with would be unrecoverable.
    func testASecondAuditionKeepsTheOriginalSnapshot() async throws {
        let target = room()
        try await startAmbient(on: target, speed: 33)
        let candle = try card("candle")
        let fire = try card("fire")

        await vm.beginPreviewLive(card: candle)
        XCTAssertEqual(vm.previewLive.snapshot?.previous?.cardID, "ambient")

        await vm.beginPreviewLive(card: fire)
        XCTAssertEqual(vm.runningEffect(for: target)?.cardID, "fire", "the second audition started")
        XCTAssertEqual(vm.previewLive.snapshot?.previous?.cardID, "ambient",
                       "the snapshot still describes the look the user began with")
        XCTAssertEqual(vm.previewLive.previewIdentity?.cardID, "fire",
                       "…while the fence follows the audition actually playing")
        XCTAssertTrue(vm.isPreviewingLive)

        await vm.cancelPreviewLive()

        XCTAssertEqual(vm.runningEffect(for: target)?.cardID, "ambient",
                       "Put It Back reaches past both auditions")
        vm.selectedRoom = target
        XCTAssertEqual(vm.paramValue(for: "ambient", paramID: "speed", default: -1), 33,
                       "…with the original exact values")
    }

    /// The audition's own replacement teardown must NOT consume the snapshot —
    /// that stop is part of starting the audition, not the world moving on.
    func testAnAuditionsOwnReplacementStopDoesNotConsumeTheSnapshot() async throws {
        let target = room()
        try await startAmbient(on: target, speed: 33)
        let candle = try card("candle")

        await vm.beginPreviewLive(card: candle)

        XCTAssertTrue(vm.previewLive.isPreviewing,
                      "the audition's replacement stop left the snapshot intact")
        XCTAssertEqual(vm.previewLive.previewIdentity?.cardID, "candle")
        XCTAssertNotEqual(vm.studioNotice?.message, PreviewLiveCopy.restoreDropped,
                          "…and said nothing about a dropped restore")
    }

    // ── H2: "did the audition start" is an IDENTITY question ────

    /// Auditioning the card that is ALREADY running there, and having the apply
    /// refuse, must not be read as a start.
    ///
    /// `started.cardID == card.id` answered "yes" for exactly this case: the
    /// row is untouched, but it names the audition's card. The browser then
    /// offered "Put It Back" for a look that never changed, and pressing it
    /// stopped and restarted the running look for nothing.
    func testAuditioningTheAlreadyRunningCardUnderARefusalIsNotAStart() async throws {
        let target = room()
        let strobe = try card("strobe")
        vm.selectedRoom = target
        // The row is installed through the production identity helper rather
        // than `apply`: the streaming engines cannot open a session against a
        // bridge with no Entertainment area, and what is under test is the
        // audition's start-detection, not how the row got there.
        let identity = vm.installRunningIdentity(
            room: target, card: strobe, execution: .appDriven(engineKey: "strobe"))
        vm.runningEffects[StudioSelectionKey(room: target)] = RunningEffect(
            cardID: strobe.id, card: strobe, room: target, lightIDs: ["L1"],
            isEntertainment: false, requestedTransport: nil, transportFallback: false,
            identity: identity)
        let running = try XCTUnwrap(vm.runningEffect(for: target),
                                    "Strobe must genuinely be running before the refusal")
        XCTAssertEqual(running.cardID, "strobe")

        // Now the SAME card is auditioned and the apply refuses at the top.
        vm.forcedReduceMotionForTesting = true
        vm.studioNotice = nil
        await vm.beginPreviewLive(card: strobe)

        XCTAssertEqual(vm.studioNotice?.message, StudioSafetyCopy.strobeReduceMotion,
                       "the only thing said is the refusal itself")
        XCTAssertFalse(vm.isPreviewingLive,
                       "nothing started, so nothing may be offered as undoable")
        XCTAssertFalse(vm.previewLive.isPreviewing, "the snapshot was consumed")
        XCTAssertNil(vm.previewLive.previewIdentity)
        XCTAssertNil(vm.previewLiveRoom)
        XCTAssertNil(vm.previewAuditionCardID)
        XCTAssertEqual(vm.runningEffect(for: target)?.identity, running.identity,
                       "the row is the SAME run — the refusal changed nothing at all")
    }

    // ── B1: what a snapshot cannot promise, it must refuse ──────

    /// A running composition's unsaved live state is its param box, which the
    /// snapshot cannot hold. Preview Live refuses rather than destroy it on the
    /// one button that promises an exact undo.
    func testPreviewLiveRefusesToRunOverACompositionBeingEdited() async throws {
        let target = room()
        try await startAmbient(on: target, speed: 33)

        // Turn the row into a composition with a LIVE editor box, exactly as
        // the composition arm of `apply` leaves it.
        let preset = CompositionPreset(
            id: UUID(), name: "Aurora Drift", icon: "sparkles", accentColorHex: "#FFB84D",
            isBuiltIn: false, category: .ambient, seasonMonths: nil,
            palette: PaletteConfig(), motion: MotionConfig(),
            envelope: EnvelopeConfig(), reaction: ReactionConfig(),
            createdAt: Date(timeIntervalSince1970: 1_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_000_000))
        let compositionCard = vm.studioCard(for: preset)
        let key = StudioSelectionKey(room: target)
        vm.runningEffects[key]?.card = compositionCard
        vm.testInstallCompositionBox(CompositionParamBox(preset: preset), at: key)
        let untouched = try XCTUnwrap(vm.runningEffect(for: target)).identity
        let candle = try card("candle")
        await vm.beginPreviewLive(card: candle)

        XCTAssertEqual(vm.studioNotice?.message,
                       PreviewLiveCopy.compositionCannotBePreviewedOver,
                       "the refusal is SAID, not a button that does nothing")
        XCTAssertFalse(vm.previewLive.isPreviewing, "no snapshot may be armed")
        XCTAssertNil(vm.previewLiveRoom)
        XCTAssertFalse(vm.isPreviewingLive)
        XCTAssertEqual(vm.runningEffect(for: target)?.identity, untouched,
                       "the composition is still the same run")
        XCTAssertNotNil(vm.testActiveCompositionBox(bridgeID: "bridge-a", roomID: "room-a"),
                        "…and its live editor box was never evicted")
        XCTAssertFalse(bridge.writes.contains { $0.hasPrefix("lightEffect:") },
                       "…and the candidate never reached a single light")
    }

    /// A recovered bridge-stored animation has no restartable card, so there is
    /// nothing "Put It Back" could put back.
    func testPreviewLiveRefusesToRunOverARecoveredRow() async throws {
        let target = room()
        try await startAmbient(on: target, speed: 33)
        let key = StudioSelectionKey(room: target)
        vm.runningEffects[key]?.recovered = UnifiedOrchestrator.RecoveredBridgeAnimationKey(
            bridgeID: "bridge-a", manifestID: UUID())
        let untouched = try XCTUnwrap(vm.runningEffect(for: target)).identity

        let candle = try card("candle")
        await vm.beginPreviewLive(card: candle)

        XCTAssertEqual(vm.studioNotice?.message,
                       PreviewLiveCopy.recoveredCannotBePreviewedOver)
        XCTAssertFalse(vm.previewLive.isPreviewing)
        XCTAssertNil(vm.previewLiveRoom)
        XCTAssertEqual(vm.runningEffect(for: target)?.identity, untouched)
    }

    // ── M1: one audition, one room ──────────────────────────────

    /// A chained audition on a DIFFERENT room would move `previewIdentity` to
    /// room B while `previewLiveRoom` still named room A: the cancel would
    /// fence B's audition against A's row, drop, and A's original look would be
    /// unrecoverable. The second audition is refused, and the room the user has
    /// to deal with is NAMED.
    func testAChainedAuditionOnADifferentRoomIsRefusedAndNamesTheArmedRoom() async throws {
        let roomA = room("room-a")
        let roomB = room("room-b")
        try await startAmbient(on: roomA, speed: 33)
        let candle = try card("candle")
        await vm.beginPreviewLive(card: candle)
        XCTAssertTrue(vm.isPreviewingLive)

        vm.selectedRoom = roomB
        let fire = try card("fire")
        await vm.beginPreviewLive(card: fire)

        XCTAssertEqual(vm.studioNotice?.message,
                       PreviewLiveCopy.finishPreviewFirst(in: roomA.name))
        XCTAssertNil(vm.runningEffect(for: roomB), "nothing started on the second room")
        XCTAssertEqual(vm.previewLiveRoom?.id, roomA.id,
                       "the armed room is unchanged")
        XCTAssertEqual(vm.previewLive.previewIdentity?.cardID, "candle",
                       "…and so is the audition the fence names")
        XCTAssertEqual(vm.previewLive.snapshot?.previous?.cardID, "ambient")

        // The original room is still fully restorable.
        vm.selectedRoom = roomA
        await vm.cancelPreviewLive()
        XCTAssertEqual(vm.runningEffect(for: roomA)?.cardID, "ambient")
    }

    // ── M3: putting a room back is not switching it off ─────────

    /// Cancelling an audition over a target that was IDLE stops the preview and
    /// leaves the lights as they were. The explicit stop sends a grouped
    /// `on: false`, which darkens a room the user never asked to darken and
    /// gives them no undo from the browser.
    func testCancellingAnAuditionOverAnIdleRoomDoesNotSwitchTheLightsOff() async throws {
        let target = room()
        vm.selectedRoom = target
        let candle = try card("candle")

        await vm.beginPreviewLive(card: candle)
        XCTAssertEqual(vm.runningEffect(for: target)?.cardID, "candle",
                       "the audition started on an idle room")
        XCTAssertNil(vm.previewLive.snapshot?.previous, "…which had nothing running")

        await vm.cancelPreviewLive()

        XCTAssertNil(vm.runningEffect(for: target), "the audition is gone")
        XCTAssertFalse(bridge.writes.contains("groupedPower:gl-room-a:false"), """
            an idle-but-LIT room must keep its lights: 'put it back' restores \
            what was playing, it does not switch the room off
            """)
    }

    // ── M4: rows can vanish without `stopEffect` ────────────────

    /// A lost Entertainment session removes the audition's row directly. The
    /// snapshot can never be restored onto it now, so the machine is consumed
    /// and the user is told — the same answer `stopEffect` gives.
    func testALostSessionOnTheAuditionsRowConsumesTheAuditionAndSaysSo() async throws {
        let target = room()
        vm.selectedRoom = target
        let candle = try card("candle")
        await vm.apply(candle, roomOverride: target, preferEntertainmentOverride: nil)
        XCTAssertEqual(vm.runningEffect(for: target)?.cardID, "candle")

        let ambient = try card("ambient")
        await vm.beginPreviewLive(card: ambient)
        XCTAssertTrue(vm.isPreviewingLive, "the audition is live")
        // The engine fell back to REST under the spy client; the event this
        // covers is the streaming one, so mark the row as the stream it would
        // have been.
        vm.runningEffects[StudioSelectionKey(room: target)]?.isEntertainment = true
        vm.studioNotice = nil

        orchestrator.testEmitStudioRuntimeEvent(
            .entertainmentSessionLost(bridgeID: "bridge-a", roomID: "room-a"))

        XCTAssertNil(vm.runningEffect(for: target), "the row went away")
        XCTAssertEqual(vm.studioNotice?.message, PreviewLiveCopy.restoreDropped,
                       "…and the withdrawn Put It Back is explained, not silent")
        XCTAssertFalse(vm.isPreviewingLive)
        XCTAssertNil(vm.previewLive.previewIdentity)
        XCTAssertNil(vm.previewLiveRoom)
    }

    // ── L3: a replacement during the audition drops the restore ─

    /// Applying a third look over a live audition is the world moving on: the
    /// audition's row is replaced, so its snapshot is consumed at the stop and
    /// a later "Put It Back" writes nothing.
    func testAReplacementDuringTheAuditionDropsTheRestoreAndWritesNothing() async throws {
        let target = room()
        try await startAmbient(on: target, speed: 33)
        let candle = try card("candle")
        await vm.beginPreviewLive(card: candle)
        XCTAssertTrue(vm.isPreviewingLive)

        let fire = try card("fire")
        await vm.apply(fire, roomOverride: target, preferEntertainmentOverride: nil)

        XCTAssertEqual(vm.studioNotice?.message, PreviewLiveCopy.restoreDropped)
        XCTAssertFalse(vm.isPreviewingLive)
        XCTAssertNil(vm.previewLive.previewIdentity)

        let writesBeforeCancel = bridge.writes.count
        await vm.cancelPreviewLive()

        XCTAssertEqual(bridge.writes.count, writesBeforeCancel,
                       "the cancel restored nothing, so it wrote nothing")
        XCTAssertEqual(vm.runningEffect(for: target)?.cardID, "fire",
                       "…and left the look that actually took the room alone")
    }

    // ── H3: a DEFERRED restore is not a refused one ─────────────

    /// The restore's apply raises a lifecycle prompt. Nothing has been refused:
    /// the confirmation will run the apply for real, and it must start from the
    /// SNAPSHOT's values. Rolling the defaults back here — and saying "we
    /// couldn't put it back" — answered a question the user has not answered.
    func testARestoreWaitingOnAPromptKeepsTheSnapshotValuesAndSaysNothing() async throws {
        let target = room()
        try await startAmbient(on: target, speed: 33)
        // Move the defaults away so "the snapshot's values survived" is a real
        // claim rather than a coincidence.
        let idle = room("room-idle")
        vm.selectedRoom = idle
        vm.commitParam(cardID: "ambient", paramID: "speed", value: 91)
        vm.selectedRoom = target

        let candle = try card("candle")
        await vm.beginPreviewLive(card: candle)
        XCTAssertTrue(vm.isPreviewingLive)

        // A Composer session now owns the bridge, so the restore's app-driven
        // apply must ASK before taking it.
        orchestrator.testStageEntertainmentOwner(roomID: "room-composer", bridgeID: "bridge-a")
        vm.studioNotice = nil

        await vm.cancelPreviewLive()

        XCTAssertNotNil(vm.entertainmentHandoffPrompt,
                        "the restore is waiting on the user, not refused")
        XCTAssertNil(vm.studioNotice,
                     "a standing question must not also be reported as a failure")
        XCTAssertEqual(vm.valueScopes.defaults(forCard: "ambient").numbers["speed"], 33, """
            the confirmation's apply seeds from the defaults — rolling them back \
            under an open prompt is what made it restore the WRONG values
            """)
        XCTAssertFalse(vm.isPreviewingLive)
        XCTAssertNil(vm.previewLiveRoom)
    }

    /// The same restore, genuinely REFUSED with no prompt standing: the
    /// defaults roll back and the drop is said.
    func testARefusedRestoreRollsTheDefaultsBackAndSaysSo() async throws {
        let target = room()
        try await startAmbient(on: target, speed: 44)
        // Defaults deliberately away from the instance's value.
        let idle = room("room-idle")
        vm.selectedRoom = idle
        vm.commitParam(cardID: "ambient", paramID: "speed", value: 91)
        vm.selectedRoom = target

        let candle = try card("candle")
        await vm.beginPreviewLive(card: candle)
        XCTAssertTrue(vm.isPreviewingLive)

        // The restore's apply will now refuse: the bridge this room lives on
        // has no resolvable client, which returns from the top of `apply`
        // without asking anything.
        orchestrator.injectForTesting(clients: [:])
        vm.studioNotice = nil
        await vm.cancelPreviewLive()

        XCTAssertNil(vm.entertainmentHandoffPrompt, "no question was asked")
        XCTAssertEqual(vm.studioNotice?.message, PreviewLiveCopy.restoreDropped,
                       "a restore that did not land is SAID")
        XCTAssertEqual(vm.valueScopes.defaults(forCard: "ambient").numbers["speed"], 91, """
            the pre-restore defaults are restored: a look that was never put \
            back must not leave the user's persisted values overwritten
            """)
        XCTAssertFalse(vm.isPreviewingLive)
    }

    // ── M5: an audition behind a prompt is deferred, not refused ─

    /// The AUDITION's own apply raises a prompt. Treating that as a refusal
    /// consumed the snapshot silently — so when the user confirmed, the
    /// audition became permanent with no Put It Back at all.
    func testAnAuditionWaitingOnAPromptKeepsItsSnapshotAndArmsOnConfirmation() async throws {
        let target = room()
        vm.selectedRoom = target
        let candle = try card("candle")
        await vm.apply(candle, roomOverride: target, preferEntertainmentOverride: nil)
        XCTAssertEqual(vm.runningEffect(for: target)?.cardID, "candle")

        // A Composer session owns the bridge, so an app-driven audition asks.
        orchestrator.testStageEntertainmentOwner(roomID: "room-composer", bridgeID: "bridge-a")
        let ambient = try card("ambient")
        await vm.beginPreviewLive(card: ambient)

        XCTAssertNotNil(vm.entertainmentHandoffPrompt, "the audition is waiting")
        XCTAssertTrue(vm.previewLive.isPreviewing,
                      "…and its snapshot must survive the wait")
        XCTAssertEqual(vm.previewLive.snapshot?.previous?.cardID, "candle")
        XCTAssertFalse(vm.isPreviewingLive,
                       "nothing is playing yet, so nothing is offered as undoable")
        XCTAssertFalse(vm.isAuditionInFlight)

        await vm.confirmEntertainmentHandoff()

        XCTAssertEqual(vm.runningEffect(for: target)?.cardID, "ambient",
                       "the confirmation started the audition")
        XCTAssertTrue(vm.isPreviewingLive,
                      "…so NOW Put It Back is real")
        XCTAssertEqual(vm.previewAuditionCardID, "ambient")

        await vm.cancelPreviewLive()
        XCTAssertEqual(vm.runningEffect(for: target)?.cardID, "candle",
                       "and it puts the previous look back")
    }

    /// Dismissing that prompt means the audition never happened — its snapshot
    /// is consumed rather than left as a fence a later cancel could measure
    /// against.
    func testDismissingThePromptConsumesTheWaitingAuditionsSnapshot() async throws {
        let target = room()
        vm.selectedRoom = target
        let candle = try card("candle")
        await vm.apply(candle, roomOverride: target, preferEntertainmentOverride: nil)

        orchestrator.testStageEntertainmentOwner(roomID: "room-composer", bridgeID: "bridge-a")
        let ambient = try card("ambient")
        await vm.beginPreviewLive(card: ambient)
        XCTAssertTrue(vm.previewLive.isPreviewing)

        vm.cancelEntertainmentHandoff()

        XCTAssertFalse(vm.previewLive.isPreviewing, "the snapshot is consumed")
        XCTAssertNil(vm.previewLiveRoom)
        XCTAssertFalse(vm.isPreviewingLive)
        XCTAssertEqual(vm.runningEffect(for: target)?.cardID, "candle",
                       "…and nothing was touched")
    }

    // ── H2: a confirmation that starts nothing must RELEASE the audition ──

    /// A confirmation can end without starting anything: a `.failed`
    /// resolution, an unreadable bridge, a stale area choice, an owner that
    /// changed into something the consent did not name, or a replayed apply
    /// that simply refuses. Every one of those left the deferred audition
    /// ARMED — `previewLive.isPreviewing` true with no `previewIdentity` — so
    /// no surface could offer Keep It or Put It Back, nothing consumed the
    /// machine, and EVERY OTHER ROOM's Preview Live was refused with "finish
    /// the preview in Room A first" for the rest of the session.
    func testAConfirmationThatStartsNothingReleasesTheDeferredAudition() async throws {
        let target = room()
        vm.selectedRoom = target
        let candle = try card("candle")
        await vm.apply(candle, roomOverride: target, preferEntertainmentOverride: nil)
        XCTAssertEqual(vm.runningEffect(for: target)?.cardID, "candle")

        // A Composer session owns the bridge, so the app-driven audition asks
        // instead of starting: it is DEFERRED, and keeps its snapshot.
        orchestrator.testStageEntertainmentOwner(roomID: "room-composer", bridgeID: "bridge-a")
        let ambient = try card("ambient")
        await vm.beginPreviewLive(card: ambient)
        XCTAssertNotNil(vm.entertainmentHandoffPrompt, "the audition is waiting")
        XCTAssertTrue(vm.previewLive.isPreviewing, "…with its snapshot armed")
        XCTAssertFalse(vm.isPreviewingLive, "…and nothing offered as undoable yet")

        // The replay asks the SECOND question — a third party holds the area —
        // and the user agrees to take it over. The takeover then fails: the
        // bridge cannot be read.
        vm.entertainmentHandoffPrompt = nil
        vm.foreignTakeoverRequest = StudioViewModel.ForeignTakeoverRequest(
            plan: EntertainmentTakeoverPlan(
                bridgeID: "bridge-a", roomID: target.id,
                config: EntertainmentConfig(id: "area-a", name: "Living", channels: []),
                channelIDs: [0]),
            foreignConfigID: "foreign-1",
            card: ambient, room: target, preferEntertainmentOverride: nil)
        orchestrator.injectForTesting(clients: [:])
        vm.studioNotice = nil

        await vm.confirmForeignTakeover()

        XCTAssertNil(vm.foreignTakeoverRequest, "the request was consumed")
        XCTAssertNotNil(vm.studioNotice, "the failure is SAID — never a silent no-op")
        XCTAssertFalse(vm.previewLive.isPreviewing, """
            nothing started, so the deferred audition is released rather than \
            left armed with no way to resolve it
            """)
        XCTAssertNil(vm.previewLive.previewIdentity)
        XCTAssertNil(vm.previewLiveRoom)
        XCTAssertFalse(vm.isPreviewingLive)
        XCTAssertEqual(vm.runningEffect(for: target)?.cardID, "candle",
                       "…and the look that was there is untouched")

        // The proof that matters to the user: another room can be auditioned.
        orchestrator.injectForTesting(clients: ["bridge-a": bridge])
        let other = room("room-b")
        vm.selectedRoom = other
        vm.studioNotice = nil
        await vm.beginPreviewLive(card: candle)

        XCTAssertNotEqual(vm.studioNotice?.message,
                          PreviewLiveCopy.finishPreviewFirst(in: target.name),
                          "no phantom audition is blocking the rest of the app")
        XCTAssertEqual(vm.runningEffect(for: other)?.cardID, "candle",
                       "…and the new audition genuinely started")
        XCTAssertTrue(vm.isPreviewingLive)
    }

    // ── M1: a CHAINED audition deferred behind a prompt ─────────

    /// Audition A starts, audition B is chained onto it and its apply raises a
    /// prompt. The confirmation replays that apply — and the replay performs
    /// B's REPLACEMENT teardown of A's row.
    ///
    /// `beginPreviewLiveCore` brackets its own apply in `isAuditionInFlight`
    /// for exactly this reason: without it the teardown runs
    /// `removeRunningRow` → `notePreviewRowRemoved`, which consumes the
    /// machine and posts "we couldn't put it back", and
    /// `notePreviewAuditionOutcome` then fails its `isPreviewing` guard. B ran
    /// with no undo at all, and the original look was unrecoverable.
    func testAChainedAuditionDeferredBehindAPromptKeepsTheOriginalSnapshot() async throws {
        let target = room()
        vm.selectedRoom = target
        // The ORIGINAL look — the one "Put It Back" must still reach at the end.
        let candle = try card("candle")
        await vm.apply(candle, roomOverride: target, preferEntertainmentOverride: nil)
        XCTAssertEqual(vm.runningEffect(for: target)?.cardID, "candle")

        // Audition A: another bridge-native look, which starts immediately.
        let fire = try card("fire")
        await vm.beginPreviewLive(card: fire)
        XCTAssertEqual(vm.runningEffect(for: target)?.cardID, "fire")
        XCTAssertTrue(vm.isPreviewingLive)
        XCTAssertEqual(vm.previewLive.snapshot?.previous?.cardID, "candle",
                       "the snapshot names the ORIGINAL look")

        // Audition B chains onto that same snapshot — and its app-driven apply
        // has to ask, because a Composer session owns the bridge.
        orchestrator.testStageEntertainmentOwner(roomID: "room-composer", bridgeID: "bridge-a")
        let ambient = try card("ambient")
        vm.studioNotice = nil
        await vm.beginPreviewLive(card: ambient)
        XCTAssertNotNil(vm.entertainmentHandoffPrompt, "B is waiting on the user")
        XCTAssertEqual(vm.previewLive.snapshot?.previous?.cardID, "candle",
                       "…still chained onto the original snapshot")
        XCTAssertEqual(vm.previewLive.previewIdentity?.cardID, "fire",
                       "…while the armed audition is still A, which is what is playing")

        await vm.confirmEntertainmentHandoff()

        XCTAssertEqual(vm.runningEffect(for: target)?.cardID, "ambient",
                       "the confirmation started B")
        XCTAssertNotEqual(vm.studioNotice?.message, PreviewLiveCopy.restoreDropped, """
            B's own replacement teardown of A's row is part of STARTING B, not \
            the world moving on — announcing a dropped restore there is how the \
            undo disappeared mid-audition
            """)
        XCTAssertTrue(vm.isPreviewingLive, "…and Put It Back is still real")
        XCTAssertEqual(vm.previewAuditionCardID, "ambient",
                       "the armed audition is B, under B's own identity")
        XCTAssertFalse(vm.isAuditionInFlight, "the flag is lowered again after the replay")

        await vm.cancelPreviewLive()
        XCTAssertEqual(vm.runningEffect(for: target)?.cardID, "candle", """
            …and Put It Back still reaches the ORIGINAL look, which is the whole \
            promise a chained audition makes
            """)
    }

    // ── M2: a RESTORE deferred behind a prompt is settled either way ──

    /// The confirmation REFUSES. `cancelPreviewLiveCore` left the snapshot's
    /// values in the card's persisted defaults deliberately (H3) and consumed
    /// the machine, so nothing was left to roll them back: the user kept a
    /// silently overwritten set of defaults for a look that was never put
    /// back, with no sentence saying so.
    func testARestoreDeferredBehindAPromptRollsBackWhenTheConfirmationRefuses() async throws {
        let target = room()
        try await startAmbient(on: target, speed: 33)
        let idle = room("room-idle")
        vm.selectedRoom = idle
        vm.commitParam(cardID: "ambient", paramID: "speed", value: 91)
        vm.selectedRoom = target

        let candle = try card("candle")
        await vm.beginPreviewLive(card: candle)
        XCTAssertTrue(vm.isPreviewingLive)

        // The restore's apply has to ask, so it is DEFERRED.
        orchestrator.testStageEntertainmentOwner(roomID: "room-composer", bridgeID: "bridge-a")
        vm.studioNotice = nil
        await vm.cancelPreviewLive()
        XCTAssertNotNil(vm.entertainmentHandoffPrompt)
        XCTAssertEqual(vm.valueScopes.defaults(forCard: "ambient").numbers["speed"], 33,
                       "the confirmation must start from the snapshot's values")

        // …and the confirmation's replay refuses: the bridge cannot be read.
        orchestrator.injectForTesting(clients: [:])
        await vm.confirmEntertainmentHandoff()

        XCTAssertNotEqual(vm.runningEffect(for: target)?.cardID, "ambient",
                          "the restore did not land")
        XCTAssertEqual(vm.valueScopes.defaults(forCard: "ambient").numbers["speed"], 91, """
            …so the pre-restore defaults come back: a look that was never put \
            back must not leave the user's persisted values overwritten
            """)
        XCTAssertEqual(vm.studioNotice?.message, PreviewLiveCopy.restoreDropped,
                       "…and the drop is SAID, exactly as an immediate refusal says it")
    }

    /// The confirmation SUCCEEDS: the restore landed, so the snapshot's values
    /// are the ones the user is now looking at. Nothing rolls back, and
    /// nothing claims a dropped restore.
    func testARestoreDeferredBehindAPromptKeepsItsValuesWhenTheConfirmationStartsIt() async throws {
        let target = room()
        try await startAmbient(on: target, speed: 33)
        let idle = room("room-idle")
        vm.selectedRoom = idle
        vm.commitParam(cardID: "ambient", paramID: "speed", value: 91)
        vm.selectedRoom = target

        let candle = try card("candle")
        await vm.beginPreviewLive(card: candle)
        orchestrator.testStageEntertainmentOwner(roomID: "room-composer", bridgeID: "bridge-a")
        vm.studioNotice = nil
        await vm.cancelPreviewLive()
        XCTAssertNotNil(vm.entertainmentHandoffPrompt)

        await vm.confirmEntertainmentHandoff()

        XCTAssertEqual(vm.runningEffect(for: target)?.cardID, "ambient",
                       "the confirmation put the previous look back")
        XCTAssertEqual(vm.valueScopes.defaults(forCard: "ambient").numbers["speed"], 33, """
            …with the snapshot's values, which are now the ones on screen — \
            rolling them back here would contradict the restore that just ran
            """)
        XCTAssertNotEqual(vm.studioNotice?.message, PreviewLiveCopy.restoreDropped,
                          "nothing was dropped")
        XCTAssertTrue(vm.pendingRestoreRollbacks.isEmpty, "the deferral is settled")
    }

    // ── The other two prompts defer and release the same way ────

    /// `confirmAreaChoice` on a stale choice starts nothing. Its `defer` is
    /// the only thing that releases the audition waiting behind it — without
    /// it, every other room's Preview Live is refused for the rest of the
    /// session.
    func testAStaleAreaChoiceReleasesTheDeferredAudition() async throws {
        let target = room()
        vm.selectedRoom = target
        let candle = try card("candle")
        await vm.apply(candle, roomOverride: target, preferEntertainmentOverride: nil)

        orchestrator.testStageEntertainmentOwner(roomID: "room-composer", bridgeID: "bridge-a")
        let ambient = try card("ambient")
        await vm.beginPreviewLive(card: ambient)
        XCTAssertTrue(vm.previewLive.isPreviewing, "the audition is deferred, with its snapshot")

        // The area chooser is the question standing now, and the choice it is
        // answered with can no longer be revalidated.
        vm.entertainmentHandoffPrompt = nil
        let plan = EntertainmentTakeoverPlan(
            bridgeID: "bridge-a", roomID: target.id,
            config: EntertainmentConfig(id: "area-a", name: "Living", channels: []),
            channelIDs: [0])
        let choice = UnifiedOrchestrator.EntertainmentAreaChoice(
            configID: "area-a", areaName: "Living", bridgeID: "bridge-a",
            bridgeLabel: "Bridge A", roomNames: [target.name], lightCount: 2,
            extraLightCount: 0, plan: plan)
        vm.areaChoiceRequest = StudioViewModel.EntertainmentAreaChoiceRequest(
            choices: [choice], card: ambient, room: target,
            preferEntertainmentOverride: nil)
        orchestrator.injectForTesting(clients: [:])
        vm.studioNotice = nil

        await vm.confirmAreaChoice(choice)

        XCTAssertNil(vm.areaChoiceRequest, "the request was consumed")
        XCTAssertNotNil(vm.studioNotice, "the refusal is SAID")
        XCTAssertFalse(vm.previewLive.isPreviewing,
                       "nothing started, so the deferred audition is released")
        XCTAssertNil(vm.previewLiveRoom)
        XCTAssertFalse(vm.isPreviewingLive)
        XCTAssertEqual(vm.runningEffect(for: target)?.cardID, "candle",
                       "…and the look that was there is untouched")
    }

    /// The same for `confirmStudioHandoff`: a `.failed` resolution starts
    /// nothing, and the audition behind it must not stay armed.
    func testAFailedStudioHandoffReleasesTheDeferredAudition() async throws {
        let target = room()
        vm.selectedRoom = target
        let candle = try card("candle")
        await vm.apply(candle, roomOverride: target, preferEntertainmentOverride: nil)

        orchestrator.testStageEntertainmentOwner(roomID: "room-composer", bridgeID: "bridge-a")
        let ambient = try card("ambient")
        await vm.beginPreviewLive(card: ambient)
        XCTAssertTrue(vm.previewLive.isPreviewing, "the audition is deferred, with its snapshot")

        vm.entertainmentHandoffPrompt = nil
        let plan = EntertainmentTakeoverPlan(
            bridgeID: "bridge-a", roomID: target.id,
            config: EntertainmentConfig(id: "area-a", name: "Living", channels: []),
            channelIDs: [0])
        vm.studioHandoffRequest = StudioViewModel.StudioHandoffRequest(
            plan: plan,
            owner: UnifiedOrchestrator.StudioEntertainmentOwner(
                bridgeID: "bridge-a", roomID: "room-other",
                engineKey: "party", configID: "area-a"),
            runningLookName: "Party", requestedLookName: "Ambient",
            card: ambient, room: target, preferEntertainmentOverride: nil)
        orchestrator.injectForTesting(clients: [:])
        vm.studioNotice = nil

        await vm.confirmStudioHandoff()

        XCTAssertNil(vm.studioHandoffRequest, "the request was consumed")
        XCTAssertNotNil(vm.studioNotice, "the failure is SAID")
        XCTAssertFalse(vm.previewLive.isPreviewing,
                       "nothing started, so the deferred audition is released")
        XCTAssertNil(vm.previewLiveRoom)
        XCTAssertFalse(vm.isPreviewingLive)
        XCTAssertEqual(vm.runningEffect(for: target)?.cardID, "candle",
                       "…and the look that was there is untouched")
    }

    // ── The restore copies values, it does not invent them ──────

    /// "Put It Back" seeds the card's persisted defaults from the snapshot —
    /// the copy-once idiom. It must copy only what the previous instance
    /// ACTUALLY held.
    ///
    /// A running set materialized with every catalog parameter made this write
    /// a stored value for every control the user never touched. Warmth is the
    /// one that shows: its apply-time sentinel is "a stored default exists ⇒
    /// the user set it", so one Preview Live cancel was enough to make every
    /// later start of that card ship a mirek nobody chose.
    func testARestoreDoesNotInventPersistedDefaultsForUntouchedParams() async throws {
        let target = room()
        vm.selectedRoom = target
        vm.valueScopes.clearDefaults(forCard: "candle")
        let candle = try card("candle")
        await vm.apply(candle, roomOverride: target, preferEntertainmentOverride: nil)
        XCTAssertEqual(vm.runningEffect(for: target)?.cardID, "candle")

        // The user moves exactly ONE control on the running instance.
        let session = try XCTUnwrap(vm.beginParamEdit(cardID: "candle", paramID: "speed"))
        vm.updateParamEdit(session, value: 80)
        vm.endParamEdit(session)
        XCTAssertNil(vm.valueScopes.defaults(forCard: "candle").numbers["warmth"],
                     "warmth was never touched, so nothing stores one yet")

        let fire = try card("fire")
        await vm.beginPreviewLive(card: fire)
        XCTAssertEqual(vm.runningEffect(for: target)?.cardID, "fire", "the audition started")

        await vm.cancelPreviewLive()

        XCTAssertEqual(vm.runningEffect(for: target)?.cardID, "candle",
                       "the previous look is back")
        vm.selectedRoom = target
        XCTAssertEqual(vm.paramValue(for: "candle", paramID: "speed", default: -1), 80,
                       "…with the value the user actually set")
        XCTAssertNil(vm.valueScopes.defaults(forCard: "candle").numbers["warmth"], """
            …and the restore did not invent a warmth default on the way, which \
            would make every later start of this card send a mirek the user \
            never chose
            """)
        XCTAssertNil(vm.valueScopes.defaults(forCard: "candle").numbers["brightness"],
                     "…nor any other control they never touched")
    }

    /// …and it must not DELETE the defaults it is SILENT about (H1).
    ///
    /// The snapshot's value set is the previous instance's sparse own-values
    /// over the base frozen when it started, so a default written AFTER that
    /// instant — a setup slider moved in the look browser on an idle room —
    /// is invisible to it. Seeding it through `setDefaults` raw replaced the
    /// whole dictionary and erased exactly those.
    func testARestoreDoesNotDeleteDefaultsWrittenAfterTheInstanceStarted() async throws {
        let target = room()
        vm.selectedRoom = target
        vm.valueScopes.clearDefaults(forCard: "candle")
        let candle = try card("candle")
        await vm.apply(candle, roomOverride: target, preferEntertainmentOverride: nil)

        let session = try XCTUnwrap(vm.beginParamEdit(cardID: "candle", paramID: "speed"))
        vm.updateParamEdit(session, value: 80)
        vm.endParamEdit(session)

        // A defaults-only write from an IDLE room, landing after the running
        // instance froze its base — the running set has no opinion about it.
        let idle = room("room-idle")
        vm.selectedRoom = idle
        vm.commitParam(cardID: "candle", paramID: "brightness", value: 42)
        vm.selectedRoom = target

        let fire = try card("fire")
        await vm.beginPreviewLive(card: fire)
        XCTAssertEqual(vm.runningEffect(for: target)?.cardID, "fire", "the audition started")

        await vm.cancelPreviewLive()

        XCTAssertEqual(vm.runningEffect(for: target)?.cardID, "candle", "the previous look is back")
        let defaults = vm.valueScopes.defaults(forCard: "candle")
        XCTAssertEqual(defaults.numbers["speed"], 80,
                       "the snapshot still wins for what the instance actually held")
        XCTAssertEqual(defaults.numbers["brightness"], 42, """
            …and a default the restored instance never had an opinion about \
            survives the restore instead of being erased by it
            """)
        XCTAssertNil(defaults.numbers["warmth"], "…while nothing is invented")
    }

    // ── The SAME-CARD audition (fifth review round) ─────────────

    /// Preview Live on the look that is ALREADY running is a legal audition —
    /// the browser offers the button there, and `notePreviewAuditionOutcome`
    /// only asks for a CHANGED IDENTITY, not a changed card. So the audition
    /// instance and the previous instance can share one card, and every live
    /// commit on the audition also writes that card's persisted defaults.
    ///
    /// THE DEFECT. The restore layered the snapshot over `defaults(forCard:)`
    /// as they are NOW, which by then held the AUDITION's warmth — a key the
    /// previous instance never had, so the snapshot is silent about it and
    /// layering keeps it. "Put It Back" restarted the previous look with a
    /// mirek it had never sent (spec §16.5 asks for the wire restored
    /// exactly), and the apply-time sentinel "a stored warmth default ⇒ the
    /// user chose it" was armed for every later start of that card.
    func testASameCardAuditionsOwnEditsAreNotKeptByThePutItBackRestore() async throws {
        let target = room()
        vm.selectedRoom = target
        vm.valueScopes.clearDefaults(forCard: "candle")
        let candle = try card("candle")
        await vm.apply(candle, roomOverride: target, preferEntertainmentOverride: nil)
        let previous = try XCTUnwrap(vm.runningEffect(for: target)?.identity)

        // The previous instance holds exactly ONE thing the user set.
        let speed = try XCTUnwrap(vm.beginParamEdit(cardID: "candle", paramID: "speed"))
        vm.updateParamEdit(speed, value: 80)
        vm.endParamEdit(speed)
        XCTAssertNil(vm.valueScopes.defaults(forCard: "candle").numbers["warmth"],
                     "warmth was never touched, so nothing stores one yet")

        // Audition the SAME card on the SAME room — a new run of one look.
        await vm.beginPreviewLive(card: candle)
        let audition = try XCTUnwrap(vm.runningEffect(for: target)?.identity)
        XCTAssertNotEqual(audition, previous,
                          "the audition is a genuinely new run, not the old row renamed")
        XCTAssertTrue(vm.isPreviewingLive)

        // …and the user moves warmth ON THE AUDITION.
        vm.commitParam(cardID: "candle", paramID: "warmth", value: 300)
        XCTAssertEqual(vm.valueScopes.live(for: audition).numbers["warmth"], 300,
                       "the edit landed on the audition instance")
        XCTAssertEqual(vm.valueScopes.defaults(forCard: "candle").numbers["warmth"], 300,
                       "…and tracked into the card's defaults, as every live edit does")

        await vm.cancelPreviewLive()

        let restored = try XCTUnwrap(vm.runningEffect(for: target))
        XCTAssertEqual(restored.cardID, "candle", "the previous look is back")
        XCTAssertNotEqual(restored.identity, audition, "…as a new run, not the audition's")
        XCTAssertNil(vm.valueScopes.defaults(forCard: "candle").numbers["warmth"], """
            the audition's own edit does not survive the undo of that audition — \
            keeping it makes every later start of this card ship a mirek nobody chose
            """)
        XCTAssertNil(vm.valueScopes.live(for: restored.identity).numbers["warmth"], """
            …so the restarted instance sends no warmth either, which is what \
            "put it back exactly" means on the wire
            """)
        XCTAssertEqual(vm.valueScopes.live(for: restored.identity).numbers["speed"], 80,
                       "…while the value the previous instance really held is exact")
    }

    /// The mirror, so the subtraction cannot become "throw the defaults away"
    /// (H1 intent preserved). A default written AFTER the previous instance
    /// started, which the audition never touched, still survives the restore.
    func testASameCardAuditionStillKeepsDefaultsWrittenAfterTheInstanceStarted() async throws {
        let target = room()
        vm.selectedRoom = target
        vm.valueScopes.clearDefaults(forCard: "candle")
        let candle = try card("candle")
        await vm.apply(candle, roomOverride: target, preferEntertainmentOverride: nil)

        let speed = try XCTUnwrap(vm.beginParamEdit(cardID: "candle", paramID: "speed"))
        vm.updateParamEdit(speed, value: 80)
        vm.endParamEdit(speed)

        // A setup slider moved in the look browser on an IDLE room: a
        // defaults-only write, landing after the running instance froze its
        // base, which the snapshot is therefore silent about.
        let idle = room("room-idle")
        vm.selectedRoom = idle
        vm.commitParam(cardID: "candle", paramID: "brightness", value: 42)
        vm.selectedRoom = target

        await vm.beginPreviewLive(card: candle)
        vm.commitParam(cardID: "candle", paramID: "warmth", value: 300)

        await vm.cancelPreviewLive()

        let defaults = vm.valueScopes.defaults(forCard: "candle")
        XCTAssertEqual(defaults.numbers["speed"], 80,
                       "the snapshot still wins for what the instance actually held")
        XCTAssertEqual(defaults.numbers["brightness"], 42, """
            …a default the restored instance never had an opinion about survives, \
            because only the AUDITION's own keys are subtracted
            """)
        XCTAssertNil(defaults.numbers["warmth"], "…and the audition's own key is gone")
    }

    // ── "Did the restore land" is an IDENTITY question too ──────

    /// The same H2 lesson `notePreviewAuditionOutcome` learned, on the other
    /// side of the audition (fifth review round).
    ///
    /// The landed test was `runningEffect(for: room)?.cardID != previous.cardID`.
    /// For a SAME-CARD audition the row already names `previous.cardID` before
    /// the restore apply, so a restore that was flatly REFUSED read as
    /// "landed": the defaults were left holding the snapshot's values, nothing
    /// rolled them back, and no "we couldn't put it back" was said. Put It Back
    /// silently did nothing, and the whole M2 deferred machinery was
    /// unreachable for that entire class.
    func testASameCardAuditionsRefusedPutItBackRollsTheDefaultsBackAndSaysSo() async throws {
        let target = room()
        vm.selectedRoom = target
        vm.valueScopes.clearDefaults(forCard: "candle")
        let candle = try card("candle")
        await vm.apply(candle, roomOverride: target, preferEntertainmentOverride: nil)

        let speed = try XCTUnwrap(vm.beginParamEdit(cardID: "candle", paramID: "speed"))
        vm.updateParamEdit(speed, value: 44)
        vm.endParamEdit(speed)
        // Force scope 1 apart from scope 2, so "the defaults rolled back" is a
        // claim only a rollback can satisfy.
        let idle = room("room-idle")
        vm.selectedRoom = idle
        vm.commitParam(cardID: "candle", paramID: "speed", value: 91)
        vm.selectedRoom = target
        let previous = try XCTUnwrap(vm.runningEffect(for: target)?.identity)

        // Audition the card that is ALREADY running there, and edit it.
        await vm.beginPreviewLive(card: candle)
        let audition = try XCTUnwrap(vm.runningEffect(for: target)?.identity)
        XCTAssertNotEqual(audition, previous, "a genuinely new run of the same card")
        vm.commitParam(cardID: "candle", paramID: "warmth", value: 300)

        // The restore's apply now refuses outright: this room's bridge has no
        // resolvable client, which returns from the top of `apply` without
        // asking anything.
        orchestrator.injectForTesting(clients: [:])
        vm.studioNotice = nil
        await vm.cancelPreviewLive()

        XCTAssertNil(vm.entertainmentHandoffPrompt, "no question was asked")
        XCTAssertEqual(vm.runningEffect(for: target)?.identity, audition, """
            the refused restore left the AUDITION standing — which is exactly \
            why a card-id test called it a success
            """)
        XCTAssertEqual(vm.studioNotice?.message, PreviewLiveCopy.restoreDropped,
                       "a restore that did not land is SAID")
        XCTAssertEqual(vm.valueScopes.defaults(forCard: "candle").numbers["speed"], 91, """
            the pre-restore defaults come back: a look that was never put back \
            must not leave the user's persisted values overwritten
            """)
        XCTAssertEqual(vm.valueScopes.defaults(forCard: "candle").numbers["warmth"], 300, """
            …the world exactly as it was, audition writes included — the \
            rollback baseline is deliberately the untrimmed `before`
            """)
        XCTAssertFalse(vm.isPreviewingLive)
    }

    /// …and the DEFERRED flavour, where the same card-id test made the M2
    /// rollback unreachable: the restore waits behind a prompt, the
    /// confirmation refuses, and the row still names the card because the
    /// audition was that same card all along.
    func testASameCardAuditionsDeferredRestoreThatNeverLandsRollsBackAndSaysSo() async throws {
        let target = room()
        try await startAmbient(on: target, speed: 44)
        let idle = room("room-idle")
        vm.selectedRoom = idle
        vm.commitParam(cardID: "ambient", paramID: "speed", value: 91)
        vm.selectedRoom = target

        let ambient = try card("ambient")
        await vm.beginPreviewLive(card: ambient)
        XCTAssertEqual(vm.runningEffect(for: target)?.cardID, "ambient")
        XCTAssertTrue(vm.isPreviewingLive, "the same card is a legal audition")

        // A Composer session owns the bridge, so the restore's apply ASKS.
        orchestrator.testStageEntertainmentOwner(roomID: "room-composer", bridgeID: "bridge-a")
        vm.studioNotice = nil
        await vm.cancelPreviewLive()
        XCTAssertNotNil(vm.entertainmentHandoffPrompt, "the restore is deferred, not refused")
        XCTAssertNotNil(vm.pendingRestoreRollbacks["ambient"], "…with its rollback held")
        XCTAssertNil(vm.studioNotice, "a standing question is not a failure")

        // The confirmation's replay then refuses: the bridge is unreadable.
        orchestrator.injectForTesting(clients: [:])
        await vm.confirmEntertainmentHandoff()

        XCTAssertEqual(vm.valueScopes.defaults(forCard: "ambient").numbers["speed"], 91, """
            the deferred rollback ran: the row still NAMES the card, because the \
            audition was that same card — only its identity says nothing restarted
            """)
        XCTAssertEqual(vm.studioNotice?.message, PreviewLiveCopy.restoreDropped)
        XCTAssertTrue(vm.pendingRestoreRollbacks.isEmpty, "settled either way")
    }

    /// TWO restores can be waiting at once, and both must be settled.
    ///
    /// `pendingRestoreRollback` was a single optional guarded by
    /// `?.cardID != previous.cardID`, so a second deferred restore for a
    /// DIFFERENT card simply dropped the first one: card X kept the previous
    /// look's values persisted under a card that was never put back, and
    /// nothing was ever said about it. The machine is consumed by each cancel,
    /// so the user is free to audition again while a restore waits — this is a
    /// sequence the UI positively invites.
    func testTwoDeferredRestoresForDifferentCardsAreBothSettled() async throws {
        let target = room()
        try await startAmbient(on: target, speed: 44)
        let idle = room("room-idle")
        vm.selectedRoom = idle
        vm.commitParam(cardID: "ambient", paramID: "speed", value: 91)
        vm.selectedRoom = target

        // Audition 1: candle over ambient, with a value of its own.
        let candle = try card("candle")
        await vm.beginPreviewLive(card: candle)
        let candleSpeed = try XCTUnwrap(vm.beginParamEdit(cardID: "candle", paramID: "speed"))
        vm.updateParamEdit(candleSpeed, value: 20)
        vm.endParamEdit(candleSpeed)
        vm.selectedRoom = idle
        vm.commitParam(cardID: "candle", paramID: "speed", value: 77)
        vm.selectedRoom = target

        // Put It Back for AMBIENT — deferred behind a handoff prompt.
        orchestrator.testStageEntertainmentOwner(roomID: "room-composer", bridgeID: "bridge-a")
        vm.studioNotice = nil
        await vm.cancelPreviewLive()
        XCTAssertNotNil(vm.entertainmentHandoffPrompt)
        XCTAssertNotNil(vm.pendingRestoreRollbacks["ambient"], "ambient's rollback is held")

        // The machine is consumed, so a SECOND audition is offered and taken.
        let fire = try card("fire")
        await vm.beginPreviewLive(card: fire)
        XCTAssertEqual(vm.runningEffect(for: target)?.cardID, "fire", "audition 2 is playing")

        // Put It Back for CANDLE — its apply refuses outright, but a question is
        // still standing, so this restore is deferred too.
        orchestrator.injectForTesting(clients: [:])
        vm.studioNotice = nil
        await vm.cancelPreviewLive()

        XCTAssertNotNil(vm.pendingRestoreRollbacks["candle"], "candle's rollback is held")
        XCTAssertNotNil(vm.pendingRestoreRollbacks["ambient"], """
            …and it did NOT evict ambient's: one slot meant the second card \
            silently threw the first card's undo away
            """)

        // The question is dismissed: every waiting restore is settled now.
        vm.cancelEntertainmentHandoff()

        XCTAssertEqual(vm.valueScopes.defaults(forCard: "ambient").numbers["speed"], 91,
                       "ambient's pre-restore defaults came back")
        XCTAssertEqual(vm.valueScopes.defaults(forCard: "candle").numbers["speed"], 77,
                       "…and so did candle's")
        XCTAssertEqual(vm.studioNotice?.message, PreviewLiveCopy.restoreDropped,
                       "one sentence covers the pass, however many restores it dropped")
        XCTAssertTrue(vm.pendingRestoreRollbacks.isEmpty)
    }

    // ── The deferral is NAMED, not "any replay" (fifth review round) ──

    /// HIJACK. An audition is playing; the user then DELIBERATELY applies a
    /// different card to the same room, and that apply raises a prompt.
    ///
    /// The confirmation's replay used to run with `isAuditionInFlight` raised
    /// merely because a preview was armed — so the replacement stop's
    /// `notePreviewRowRemoved` was suppressed instead of consuming the machine,
    /// and the unconditional `notePreviewAuditionOutcome` then armed the
    /// DELIBERATE apply as the audition. "Put It Back" offered to undo a change
    /// the user had made on purpose.
    func testAConfirmedDeliberateApplyOnTheAuditionsRoomIsNotArmedAsTheAudition() async throws {
        let target = room()
        vm.selectedRoom = target
        let candle = try card("candle")
        await vm.apply(candle, roomOverride: target, preferEntertainmentOverride: nil)

        let fire = try card("fire")
        await vm.beginPreviewLive(card: fire)
        XCTAssertEqual(vm.runningEffect(for: target)?.cardID, "fire", "the audition is playing")
        XCTAssertTrue(vm.isPreviewingLive)

        // Nothing to do with the audition: the user applies a third card to the
        // same room, and it has to ask because a Composer session owns the
        // bridge.
        orchestrator.testStageEntertainmentOwner(roomID: "room-composer", bridgeID: "bridge-a")
        let ambient = try card("ambient")
        vm.studioNotice = nil
        await vm.apply(ambient, roomOverride: target, preferEntertainmentOverride: nil)
        XCTAssertNotNil(vm.entertainmentHandoffPrompt, "the deliberate apply is the one asking")

        await vm.confirmEntertainmentHandoff()

        XCTAssertEqual(vm.runningEffect(for: target)?.cardID, "ambient",
                       "the user's own apply landed")
        XCTAssertEqual(vm.studioNotice?.message, PreviewLiveCopy.restoreDropped, """
            the audition's row was replaced by something that is NOT the \
            audition's own replay, so the undo is dropped and SAID
            """)
        XCTAssertFalse(vm.previewLive.isPreviewing, "the machine is consumed")
        XCTAssertNil(vm.previewAuditionCardID, """
            …and the deliberate apply is emphatically not armed as an audition \
            Put It Back could undo
            """)
        XCTAssertFalse(vm.isPreviewingLive)
        XCTAssertNil(vm.previewLiveRoom)
    }

    /// STRANDING. An audition is playing on room A; the user applies to room B
    /// on the same bridge; the prompt is confirmed and the replay's
    /// one-engine-per-bridge teardown removes room A's row.
    ///
    /// With the flag wrongly raised, that removal was silent: the machine
    /// stayed armed on a row that no longer exists, nothing said "we couldn't
    /// put it back", and every other room's Preview Live was refused with
    /// "finish the preview in Room A first" for the rest of the session.
    func testAConfirmedApplyOnAnotherRoomThatTearsTheAuditionDownSaysSoAndFreesPreviewLive() async throws {
        let target = room()
        vm.selectedRoom = target
        let candle = try card("candle")
        await vm.apply(candle, roomOverride: target, preferEntertainmentOverride: nil)

        // An APP-DRIVEN audition, so the engine-singleton rule can reach it.
        let ambient = try card("ambient")
        await vm.beginPreviewLive(card: ambient)
        XCTAssertEqual(vm.runningEffect(for: target)?.cardID, "ambient", "the audition is playing")
        XCTAssertTrue(vm.isPreviewingLive)

        // A different room on the same bridge, and a Composer session owns it.
        let other = room("room-b")
        vm.selectedRoom = other
        orchestrator.testStageEntertainmentOwner(roomID: "room-composer", bridgeID: "bridge-a")
        vm.studioNotice = nil
        await vm.apply(ambient, roomOverride: other, preferEntertainmentOverride: nil)
        XCTAssertNotNil(vm.entertainmentHandoffPrompt)

        await vm.confirmEntertainmentHandoff()

        XCTAssertNil(vm.runningEffect(for: target), """
            room A's row went with the one-Studio-engine-per-bridge rule — the \
            audition's target no longer exists
            """)
        XCTAssertEqual(vm.studioNotice?.message, PreviewLiveCopy.restoreDropped,
                       "…which is SAID, because the affordance vanished")
        XCTAssertFalse(vm.previewLive.isPreviewing, "the machine is consumed, not stranded")
        XCTAssertNil(vm.previewLiveRoom)
        XCTAssertFalse(vm.isPreviewingLive)

        // The proof that matters to the user: the app is not locked out.
        vm.studioNotice = nil
        vm.selectedRoom = other
        await vm.beginPreviewLive(card: candle)
        XCTAssertNotEqual(vm.studioNotice?.message,
                          PreviewLiveCopy.finishPreviewFirst(in: target.name),
                          "no phantom audition is blocking the rest of the app")
    }

    // ── M5: the restore reproduces the OBSERVED transport ───────

    /// Source shape, because the defect is a value the spy cannot see: the
    /// restore used to pass `previousWasStreaming ? true : nil`. `nil` means
    /// "re-derive the preference", so a previous look that had FALLEN BACK to
    /// REST could come back streaming — the restore would not reproduce what
    /// was actually there.
    func testTheRestorePassesTheObservedTransportBothWays() throws {
        let code = try productionCode(
            "HueHome/UI/Studio/StudioViewModel+CustomizationWiring.swift")
        XCTAssertTrue(code.contains("preferEntertainmentOverride: snapshot.previousWasStreaming"),
                      "the restore must pass the observed transport, not a one-sided hint")
        XCTAssertFalse(code.contains("snapshot.previousWasStreaming ? true : nil"),
                       "`? true : nil` lets a REST fallback come back streaming")
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

}
