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
        record("groupedState:\(id)")
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
    func testCancelRestoresThePreviousLooksExactLiveValuesOnTheExactTarget() async throws {
        let target = room()
        try await startAmbient(on: target, speed: 33)
        let candle = try card("candle")

        await vm.beginPreviewLive(card: candle)
        XCTAssertEqual(vm.runningEffect(for: target)?.cardID, "candle", "the audition started")
        XCTAssertTrue(vm.isPreviewingLive, "…and the browser can offer Put It Back")

        await vm.cancelPreviewLive()

        XCTAssertEqual(vm.runningEffect(for: target)?.cardID, "ambient",
                       "the previous look is back on the exact target")
        vm.selectedRoom = target
        XCTAssertEqual(vm.paramValue(for: "ambient", paramID: "speed", default: -1), 33,
                       "…with the exact live values it had, not the catalog defaults")
        XCTAssertFalse(vm.isPreviewingLive, "the audition is over")
        XCTAssertNil(vm.previewLiveRoom)
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

        vm.commitPreviewLive()

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
}
