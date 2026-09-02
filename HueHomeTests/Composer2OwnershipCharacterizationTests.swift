// Composer2OwnershipCharacterizationTests.swift
// ChromaGlow — Composer 2 Phase 1B2.
//
// CHARACTERIZATION ONLY. Every assertion pins what production does TODAY,
// including shapes that permit outcomes nobody wants. Nothing here asserts
// intended future behavior, and nothing consumes a Composer2Flag.
//
// Vocabulary discipline, deliberately:
//   • Nothing is called a DEFECT. No accepted requirement or source-of-truth
//     issue designates any of these a defect, so each is either a
//     CHARACTERIZATION FINDING (what the code does) or an ARCHITECTURAL RISK
//     (a shape permitting a bad outcome not yet proven to occur).
//   • Nothing is called PROCESS-WIDE. StudioViewModel is built as
//     `@State private var vm = StudioViewModel()` (StudioView.swift:88), a
//     View-owned instance; one-instance-per-process is NOT established. Its
//     fields are therefore "one non-keyed slot per StudioViewModel instance".
//   • Every source-shape claim is NON-TRANSITIVE: it speaks only about the
//     extracted declaration or brace-matched body, never about callees.
//   • Every behavioral claim names its finite completion point. Detached work
//     — the Task spawned by setRoom, by stopAllDayScenes, and by
//     RestSender.enqueue's flush — is NEVER observed.
//
// Scope discipline — this file does NOT re-prove what the registered suite
// already proves directly:
//   • mailbox arbitration: latest-wins per scope, FIFO, epoch invalidation
//       → GatedBulkWriteTests (testLatestWinsIsPerScopeAndScopesAreIndependent,
//         testScopeSelectionIsFIFO, testClearAllInvalidatesEveryEpochBeforeClearingPending)
//   • per-room / cross-bridge stop isolation, superseded work, cancellation
//       → MultiBridgeRoutingTests packet-3 section
//   • the per-bridge Entertainment acquisition gate
//       → MultiBridgeRoutingTests packet-1a section
//   • Entertainment refcounts, cleanup claims, cross-bridge key isolation
//       → EntertainmentOwnershipTests
//   • stale-generation rejection in ledger / rotation / prime
//       → CompositionRoomPriorityScorerTests, EntertainmentRoomSelectionTests
//   • All-Day per-room suppression across all five arms
//       → MultiBridgeRoutingTests packet-6 section
//   • no production code consumes FlagStore / Composer2Flag
//       → FlagStoreTests.testNoProductionCodeConsumesFlagStoreYet
//
// Determinism: no timing waits of any kind. Enforced by the last test here,
// because every hardening guard's file list is hardcoded and cannot cover a
// newly added file.

import XCTest
@testable import HueHome

// MARK: - Minimal recording client

/// Records only what these tests assert. The rich RoutingSpyClient is private
/// to MultiBridgeRoutingTests, so this file carries its own.
private final class Composer2OwnershipSpyClient: BridgeAPIClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _nativeEffects: [String] = []
    private var _groupedWrites: [String] = []

    var nativeEffects: [String] {
        lock.lock(); defer { lock.unlock() }
        return _nativeEffects
    }

    var groupedWrites: [String] {
        lock.lock(); defer { lock.unlock() }
        return _groupedWrites
    }

    func resetObservations() {
        lock.lock(); defer { lock.unlock() }
        _nativeEffects.removeAll()
        _groupedWrites.removeAll()
    }

    private func record(_ entry: String, native: Bool) {
        lock.lock(); defer { lock.unlock() }
        if native { _nativeEffects.append(entry) } else { _groupedWrites.append(entry) }
    }

    override func setGroupedLightNativeEffect(id: String, effect: String) async throws {
        record("\(bridgeID):\(id):\(effect)", native: true)
    }

    override func setGroupedLight(id: String, on: Bool) async throws {
        record("setGroupedLight:\(id):\(on)", native: false)
    }

    override func setGroupedLightState(id: String, on: Bool, brightness: Double) async throws {
        record("setGroupedLightState:\(id):\(on)", native: false)
    }

    override func setGroupedLightEffect(id: String,
                                        on: Bool?,
                                        brightness: Double?,
                                        xy: (Double, Double)?,
                                        mirek: Int?,
                                        duration: Int) async throws {
        record("setGroupedLightEffect:\(bridgeID):\(id)", native: false)
    }
}

@MainActor
final class Composer2OwnershipCharacterizationTests: XCTestCase {

    private var bridgeA: Composer2OwnershipSpyClient!
    private var bridgeB: Composer2OwnershipSpyClient!
    private var orchestrator: UnifiedOrchestrator!

    override func setUp() async throws {
        try await super.setUp()
        bridgeA = Composer2OwnershipSpyClient(
            bridgeID: "bridge-a", bridgeName: "Bridge A", ip: "192.0.2.1", token: "test-token")
        bridgeB = Composer2OwnershipSpyClient(
            bridgeID: "bridge-b", bridgeName: "Bridge B", ip: "192.0.2.2", token: "test-token")
        orchestrator = UnifiedOrchestrator()
        orchestrator.injectForTesting(clients: ["bridge-a": bridgeA, "bridge-b": bridgeB])
    }

    override func tearDown() async throws {
        orchestrator = nil
        bridgeA = nil
        bridgeB = nil
        try await super.tearDown()
    }

    // ──────────────────────────────────────────────
    // MARK: - Fail-hard source-shape helpers
    //
    // These fail when a file, declaration, or body is missing — they never
    // skip, and never fall back to a whole-repository substring count. Every
    // claim is anchored inside a NAMED declaration body, so a symbol moving
    // to another function is a failure rather than a silent pass.
    // ──────────────────────────────────────────────

    /// Production source with comment-only lines stripped, so a doc comment
    /// naming a symbol is never mistaken for a call site.
    private func productionSource(_ relativePath: String,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // HueHomeTests/
            .deletingLastPathComponent()   // repo root
        let url = repoRoot.appendingPathComponent(relativePath)
        guard let raw = try? String(contentsOf: url, encoding: .utf8), !raw.isEmpty else {
            XCTFail("Missing or empty production file: \(relativePath)", file: file, line: line)
            throw CharacterizationFailure.missingFile(relativePath)
        }
        return raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The brace-matched body of a declaration, located by an exact signature
    /// fragment. Fails when the signature is absent or the body is empty.
    private func requireBody(_ signature: String,
                             in source: String,
                             of path: String,
                             file: StaticString = #filePath,
                             line: UInt = #line) throws -> String {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: { $0.contains(signature) }) else {
            XCTFail("\(path): declaration not found: \(signature)", file: file, line: line)
            throw CharacterizationFailure.missingSymbol(signature)
        }
        var depth = 0
        var started = false
        var body: [String] = []
        for current in lines[start...] {
            for ch in current {
                if ch == "{" { depth += 1; started = true }
                if ch == "}" { depth -= 1 }
            }
            if started { body.append(current) }
            if started && depth == 0 { break }
        }
        let joined = body.joined(separator: "\n")
        guard started, !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            XCTFail("\(path): empty body for: \(signature)", file: file, line: line)
            throw CharacterizationFailure.emptyBody(signature)
        }
        return joined
    }

    /// A single non-empty declaration line located by an exact fragment.
    private func requireDeclaration(_ fragment: String,
                                    in source: String,
                                    of path: String,
                                    file: StaticString = #filePath,
                                    line: UInt = #line) throws -> String {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let found = lines.first(where: { $0.contains(fragment) }),
              !found.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            XCTFail("\(path): declaration not found: \(fragment)", file: file, line: line)
            throw CharacterizationFailure.missingSymbol(fragment)
        }
        return found
    }

    /// The `case` names declared directly in an extracted enum body.
    private func caseNames(in body: String) -> [String] {
        body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("case ") }
            .map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
    }

    private func requireContains(_ needle: String,
                                 in body: String,
                                 _ what: String,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) {
        XCTAssertTrue(body.contains(needle),
                      "\(what): expected to find \(needle)", file: file, line: line)
    }

    private func requireAbsent(_ needle: String,
                               in body: String,
                               _ what: String,
                               file: StaticString = #filePath,
                               line: UInt = #line) {
        XCTAssertFalse(body.contains(needle),
                       "\(what): did not expect \(needle)", file: file, line: line)
    }

    private enum CharacterizationFailure: Error {
        case missingFile(String)
        case missingSymbol(String)
        case emptyBody(String)
    }

    private var orchestratorPath: String { "HueHome/Core/Network/UnifiedOrchestrator.swift" }
    private var restSenderPath: String { "HueHome/Core/Network/RestSender.swift" }
    private var studioVMPath: String { "HueHome/UI/Studio/StudioViewModel.swift" }

    private func room(_ id: String, bridge: String?, grouped: String) -> RoomDisplayItem {
        RoomDisplayItem(
            id: id, name: id, archetype: nil,
            isOn: false, brightness: 40,
            groupedLightID: grouped, lightCount: 1,
            bridgeID: bridge,
            childResourceRefs: [(rid: "\(id)-L1", rtype: "light")]
        )
    }

    // ──────────────────────────────────────────────
    // MARK: - A. Ownership identity shape
    // ──────────────────────────────────────────────

    /// Two SEPARATE owner enums exist. This deliberately does NOT call their
    /// vocabularies disjoint — both declare a `studio` case.
    ///
    /// NON-TRANSITIVE: speaks only about these two extracted enum bodies. It
    /// says nothing about how producers are mapped onto these cases, nor that
    /// firmware producers are unrepresented by some other mechanism.
    func testCurrentOwnerVocabulariesUseSeparateTypesAndCurrentCases() throws {
        let restSrc = try productionSource(restSenderPath)
        let ownerBody = try requireBody("enum RestScopeOwner: String, Hashable, Sendable {",
                                        in: restSrc, of: restSenderPath)
        XCTAssertEqual(caseNames(in: ownerBody), ["composer", "studio", "allDay"],
                       "RestScopeOwner declares exactly these three cases today")

        let orchSrc = try productionSource(orchestratorPath)
        let requesterBody = try requireBody("enum EntertainmentRequester: Equatable, Sendable {",
                                            in: orchSrc, of: orchestratorPath)
        XCTAssertEqual(caseNames(in: requesterBody), ["studio", "composition"],
                       "EntertainmentRequester declares exactly these two cases today")

        XCTAssertTrue(caseNames(in: ownerBody).contains("studio")
                      && caseNames(in: requesterBody).contains("studio"),
                      "both enums declare a studio case — they are separate types, not disjoint vocabularies")
    }

    /// A bridgeless room collapses onto the shared "legacy" bridge key, so two
    /// bridgeless rooms sharing a room id address ONE playback key.
    ///
    /// Finite completion: synchronous value construction and comparison.
    func testCurrentPlaybackKeyNormalizesBridgelessRoomsOntoOneLegacyKey() {
        let viaNil = UnifiedOrchestrator.CompositionPlaybackKey(bridgeID: nil, roomID: "room-1")
        let viaLegacy = UnifiedOrchestrator.CompositionPlaybackKey(bridgeKey: "legacy", roomID: "room-1")

        XCTAssertEqual(viaNil, viaLegacy, "a nil bridge normalizes to the legacy key")
        XCTAssertEqual(viaNil.hashValue, viaLegacy.hashValue, "and hashes with it")
        XCTAssertEqual(viaNil.bridgeKey, "legacy", "the stored key is the legacy spelling")

        let otherBridgelessRoom = UnifiedOrchestrator.CompositionPlaybackKey(
            bridgeID: nil, roomID: "room-1")
        XCTAssertEqual(viaNil, otherBridgelessRoom,
                       "two bridgeless rooms with one room id produce a single key")

        XCTAssertNotEqual(viaNil,
                          UnifiedOrchestrator.CompositionPlaybackKey(bridgeID: "bridge-a", roomID: "room-1"),
                          "a named bridge is a different key")
    }

    /// The presentation key and the runtime key disagree about bridgelessness:
    /// RoomEffectKey keeps the Optional, CompositionPlaybackKey collapses it.
    ///
    /// Finite completion: synchronous value comparison.
    func testCurrentRoomEffectKeyKeepsBridgeOptionalWhilePlaybackKeyNormalizes() {
        let effectNil = RoomEffectKey(bridgeID: nil, roomID: "room-1")
        let effectLegacy = RoomEffectKey(bridgeID: "legacy", roomID: "room-1")
        XCTAssertNotEqual(effectNil, effectLegacy,
                          "RoomEffectKey does NOT normalize nil onto legacy")

        let playbackNil = UnifiedOrchestrator.CompositionPlaybackKey(bridgeID: nil, roomID: "room-1")
        let playbackLegacy = UnifiedOrchestrator.CompositionPlaybackKey(bridgeID: "legacy", roomID: "room-1")
        XCTAssertEqual(playbackNil, playbackLegacy,
                       "CompositionPlaybackKey DOES collapse the same pair")
    }

    /// One ownership record carries an explicit generation; the Studio engine
    /// runtime carries none.
    ///
    /// NON-TRANSITIVE: about these two extracted declarations only. It does NOT
    /// claim Studio lacks staleness protection — UnifiedOrchestrator records
    /// that Studio staleness moved to the REST scope epoch.
    func testCurrentBridgeNativeTokenDeclaresAGenerationAndStudioRuntimeDoesNot() throws {
        let src = try productionSource(orchestratorPath)

        let token = try requireBody("struct BridgeNativeOwnershipToken: Hashable, Sendable {",
                                    in: src, of: orchestratorPath)
        requireContains("let generation: Int", in: token,
                        "BridgeNativeOwnershipToken declares a generation")
        requireContains("let key: BridgeNativeOwnershipKey", in: token,
                        "and the bridge+room key it qualifies")

        let runtime = try requireBody("private struct StudioEngineRuntime {",
                                      in: src, of: orchestratorPath)
        requireContains("let roomID: String", in: runtime, "StudioEngineRuntime declares a room")
        requireAbsent("generation", in: runtime,
                      "StudioEngineRuntime declares no generation field")
    }

    // ──────────────────────────────────────────────
    // MARK: - B. Cross-producer arbitration
    // ──────────────────────────────────────────────

    /// A manual room write does not disturb an active composition's ownership.
    ///
    /// Finite completion: `setRoom` is SYNCHRONOUS and has returned before any
    /// assertion runs. The detached Task it spawns for the network PUT is
    /// deliberately NOT observed, so this claim is scoped to the synchronous
    /// portion only.
    ///
    /// Anti-vacuity: activeness is not assumed from staging. Production's own
    /// predicate `isAppDrivenGroup` is asserted first, so the staged state is
    /// one production itself treats as an app-driven owner.
    func testCurrentSynchronousRoomWriteLeavesStagedCompositionOwnershipUnchanged() {
        let target = room("room-1", bridge: "bridge-a", grouped: "gl-room-1")
        orchestrator.allRooms = [target]
        orchestrator.testStageRESTComposition(
            roomID: "room-1", bridgeID: "bridge-a", api: bridgeA, generation: 7, lightIDs: ["room-1-L1"])

        XCTAssertTrue(orchestrator.testIsAppDrivenGroup(bridgeID: "bridge-a", roomID: "room-1"),
                      "production's own predicate must call the staged state app-driven")

        let generationBefore = orchestrator.testCompositionGeneration(bridgeID: "bridge-a", roomID: "room-1")
        let claimBefore = orchestrator.testCompositionTransport(bridgeID: "bridge-a", roomID: "room-1")
        XCTAssertEqual(generationBefore, 7)
        XCTAssertEqual(claimBefore, .rest)

        orchestrator.setRoom(target, isOn: true)

        XCTAssertEqual(orchestrator.testCompositionGeneration(bridgeID: "bridge-a", roomID: "room-1"),
                       generationBefore, "the manual write moved no generation")
        XCTAssertTrue(orchestrator.testHasCompositionRuntime(bridgeID: "bridge-a", roomID: "room-1"),
                      "the runtime is still installed")
        XCTAssertEqual(orchestrator.testCompositionTransport(bridgeID: "bridge-a", roomID: "room-1"),
                       claimBefore, "the exact transport claim is unchanged")
        XCTAssertTrue(orchestrator.testIsAppDrivenGroup(bridgeID: "bridge-a", roomID: "room-1"),
                      "and the room is still owned")
    }

    /// The manual write bodies reach no ownership machinery directly.
    ///
    /// NON-TRANSITIVE: about these three extracted bodies only. A callee could
    /// still reach ownership state; this test does not rule that out. Distinct
    /// from Phase 1B1's mailbox/gate claim, which is a different mechanism.
    func testCurrentManualWriteBodiesContainNoDirectOwnershipCalls() throws {
        let src = try productionSource(orchestratorPath)
        let bodies = [
            "func setRoom(_ item: RoomDisplayItem, isOn desiredState: Bool) {",
            "func setBrightness(_ brightness: Double, for item: RoomDisplayItem) {",
            "func activateGlobalScene(_ scene: GlobalSceneItem) {",
        ]
        for signature in bodies {
            let body = try requireBody(signature, in: src, of: orchestratorPath)
            for symbol in ["isAllDayWriteAllowed",
                           "stopCompositionMode",
                           "noteRoomOwnershipChange",
                           "compositionRuntimes"] {
                requireAbsent(symbol, in: body, "\(signature) names no \(symbol)")
            }
        }
    }

    /// The bridge-native automation arm writes a firmware effect and records no
    /// bridge-native owner for it.
    ///
    /// Finite completion: `applyAutomationEffect` is async and awaits
    /// `gatedBulkWrite`, which awaits a structured `withTaskGroup`. No detached
    /// work is involved.
    ///
    /// Anti-vacuity: the spy assertion proves the `.bridgeNative` arm actually
    /// executed. A silently skipped write fails here rather than passing on an
    /// empty owner inventory.
    func testCurrentAutomationNativeEffectWritesYetStampsNoBridgeNativeOwner() async throws {
        let target = room("room-1", bridge: "bridge-a", grouped: "gl-room-1")
        orchestrator.allRooms = [target]
        orchestrator.testSeedBridgeGroups(bridgeID: "bridge-a", rooms: [target])

        XCTAssertTrue(orchestrator.testBridgeNativeOwners().isEmpty,
                      "no bridge-native owner exists before the automation")

        let candle = try XCTUnwrap(EffectLibrary.all.first { $0.id == "candle" },
                                   "the candle effect must exist to select the bridgeNative arm")
        guard case .bridgeNative(let effectName) = candle.strategy else {
            return XCTFail("candle must use the bridgeNative strategy for this test to mean anything")
        }
        XCTAssertEqual(effectName, "candle")

        await orchestrator.applyAutomationEffect(id: "candle")

        XCTAssertEqual(bridgeA.nativeEffects, ["bridge-a:gl-room-1:candle"],
                       "the bridgeNative arm really did write the firmware effect")
        XCTAssertTrue(orchestrator.testBridgeNativeOwners().isEmpty,
                      "yet no bridge-native ownership was recorded for that write")
    }

    // ──────────────────────────────────────────────
    // MARK: - C. Stop blast radius
    // ──────────────────────────────────────────────

    /// A Studio teardown invalidates a Composer scope belonging to a different
    /// room, because it clears every scope on every sender.
    ///
    /// Finite completion: three ordinary awaits. `enqueue` registers the epoch
    /// SYNCHRONOUSLY inside the actor turn, `stopStudioMode()` awaits its own
    /// `clearAll()`, and `isCurrent` is a plain actor read. There is no
    /// handshake and no observation of the detached flush — the enqueued
    /// closure never needs to run for this to complete.
    func testCurrentStopStudioModeInvalidatesAnotherRoomsComposerEpoch() async {
        let sender = orchestrator.testRestSender(for: "bridge-a")
        let composerScope = RestScope(roomID: "room-composer", owner: .composer)

        _ = await sender.enqueue(scope: composerScope) { _ in }
        let currentBefore = await sender.isCurrent(scope: composerScope, epoch: 0)
        XCTAssertTrue(currentBefore, "the composer scope is current once registered")

        await orchestrator.stopStudioMode()

        let currentAfter = await sender.isCurrent(scope: composerScope, epoch: 0)
        XCTAssertFalse(currentAfter,
                       "stopping Studio invalidated a Composer scope for an unrelated room")
    }

    /// The same Studio teardown leaves Composer runtime state installed.
    ///
    /// Finite completion: awaiting `stopStudioMode()`; both reads are
    /// synchronous.
    func testCurrentStopStudioModeLeavesCompositionRuntimeInstalled() async {
        orchestrator.allRooms = [room("room-1", bridge: "bridge-a", grouped: "gl-room-1")]
        orchestrator.testStageRESTComposition(
            roomID: "room-1", bridgeID: "bridge-a", api: bridgeA, generation: 5, lightIDs: ["room-1-L1"])

        await orchestrator.stopStudioMode()

        XCTAssertTrue(orchestrator.testHasCompositionRuntime(bridgeID: "bridge-a", roomID: "room-1"),
                      "the composition runtime survives a Studio teardown")
        XCTAssertEqual(orchestrator.testCompositionGeneration(bridgeID: "bridge-a", roomID: "room-1"), 5,
                       "and its generation is untouched")
    }

    // ──────────────────────────────────────────────
    // MARK: - D. Start-path replacement
    //
    // Both are strictly non-transitive statements about ONE extracted body.
    // ──────────────────────────────────────────────

    /// The start path bumps its own generation and issues no direct scope clear.
    ///
    /// NON-TRANSITIVE: makes NO claim that a callee cannot clear a scope.
    func testCurrentCompositionStartBodyUpdatesGenerationAndCallsNoDirectScopeClear() throws {
        let src = try productionSource(orchestratorPath)
        let body = try requireBody("func startCompositionMode(", in: src, of: orchestratorPath)

        requireContains("compositionGenerations[playbackKey] = nextGeneration", in: body,
                        "the start path writes its own generation")
        requireAbsent("clear(scope:", in: body,
                      "the extracted start body issues no direct scope clear")
    }

    /// The Entertainment replacement cancels the prior task and does not
    /// directly await it.
    ///
    /// NON-TRANSITIVE: makes NO claim that a callee cannot await that task.
    func testCurrentEntertainmentReplacementBodyCancelsPriorTaskWithNoDirectAwaitOfIt() throws {
        let src = try productionSource(orchestratorPath)
        let body = try requireBody("func startCompositionMode(", in: src, of: orchestratorPath)

        requireContains("compositionEntTasks[bridgeID]?.cancel()", in: body,
                        "the prior Entertainment task is cancelled")
        requireAbsent("await compositionEntTasks", in: body,
                      "the extracted body awaits no prior Entertainment task value")
    }

    // ──────────────────────────────────────────────
    // MARK: - E. Keying of state
    // ──────────────────────────────────────────────

    /// All-Day carries ONE generation counter shared by every bridge, so a
    /// single stop invalidates work for all of them.
    ///
    /// Finite completion: the counter bump is synchronous; each tick returns at
    /// its own `guard allDayGeneration == generation`.
    ///
    /// Anti-vacuity: a positive control first proves BOTH bridges are eligible —
    /// a tick at the CURRENT generation materializes an All-Day mailbox for each
    /// (the accessor creates lazily), which can only happen after both the
    /// bridge-eligibility and the room-ownership guards pass.
    ///
    /// Honest scope: the HTTP PUT lives in RestSender's detached flush and is
    /// NOT observed. The claim is about mailbox creation, not the write. The
    /// detached cleanup Task spawned by stopAllDayScenes is not observed either.
    func testCurrentAllDayStopBumpsOneCounterThatRejectsBothBridgesTicks() async {
        orchestrator.allRooms = [
            room("room-a", bridge: "bridge-a", grouped: "gl-room-a"),
            room("room-b", bridge: "bridge-b", grouped: "gl-room-b"),
        ]
        let anchor = UnifiedOrchestrator.AllDayAnchor(
            lat: 39.74, lon: -104.99, timeZoneID: "America/Denver", updatedAt: Date())

        XCTAssertTrue(orchestrator.testAllDayRestSenderBridgeKeys().isEmpty,
                      "no All-Day mailbox exists before the first tick")

        let generationBefore = orchestrator.testAllDayGeneration()

        // POSITIVE CONTROL: at the current generation both bridges are eligible
        // and each reaches the lazily-creating mailbox accessor.
        await orchestrator.testTickAllDayScenes(anchor: anchor, generation: generationBefore)
        XCTAssertEqual(orchestrator.testAllDayRestSenderBridgeKeys(), ["bridge-a", "bridge-b"],
                       "both bridges were eligible and reached their All-Day mailbox")

        orchestrator.stopAllDayScenes()

        XCTAssertEqual(orchestrator.testAllDayGeneration(), generationBefore + 1,
                       "one shared counter advanced by exactly one")
        XCTAssertTrue(orchestrator.testAllDayRestSenderBridgeKeys().isEmpty,
                      "the stop detached every All-Day mailbox")

        // The stale tick must be rejected for BOTH bridges by that one counter.
        await orchestrator.testTickAllDayScenes(anchor: anchor, generation: generationBefore)

        XCTAssertTrue(orchestrator.testAllDayRestSenderBridgeKeys().isEmpty,
                      "a tick at the pre-stop generation reached no enqueue on either bridge")
    }

    /// Slice 2 rewired the Studio live-param debounce: the old one non-keyed
    /// `paramTask` slot (cancelled unconditionally by every send, from any
    /// room) is gone, replaced by one pending send PER EXACT RUNNING TARGET.
    ///
    /// NON-TRANSITIVE and PER-INSTANCE: about the extracted declaration only.
    func testCurrentStudioParamDebounceIsKeyedByExactRunningTarget() throws {
        let src = try productionSource(studioVMPath)

        XCTAssertFalse(src.contains("private var paramTask"),
                       "the single global debounce slot is retired")
        XCTAssertFalse(src.contains("func sendParam("),
                       "the selectedRoom-re-reading send path is retired")

        let decl = try requireDeclaration("var paramSendTasks", in: src, of: studioVMPath)
        requireContains("[RunningLookTargetKey: Task<Void, Never>]", in: decl,
                        "pending sends are keyed by exact running target — two targets' edits never cancel each other")
    }

    /// The explicit-stop marker is one non-keyed field per StudioViewModel
    /// instance, and the stop path reads it after suspending.
    ///
    /// NON-TRANSITIVE and PER-INSTANCE: same scoping as the debounce test. The
    /// read-after-await ordering is asserted over the extracted body only; no
    /// claim is made about which callers can actually interleave.
    func testCurrentIsExplicitStopIsOneNonKeyedFieldPerViewModelInstance() throws {
        let src = try productionSource(studioVMPath)

        let decl = try requireDeclaration("private var isExplicitStop", in: src, of: studioVMPath)
        requireAbsent("[", in: decl, "isExplicitStop is not keyed by bridge or room")

        let body = try requireBody("private func stopEffect(on rowKey: StudioSelectionKey,",
                                   in: src, of: studioVMPath)
        let firstAwait = try XCTUnwrap(body.range(of: "await"),
                                       "the stop path must contain a suspension point")
        let readsMarker = try XCTUnwrap(body.range(of: "isExplicitStop"),
                                        "the stop path must read the marker")
        XCTAssertTrue(readsMarker.lowerBound > firstAwait.lowerBound,
                      "the extracted body reads isExplicitStop after suspending at least once")
    }

    // ──────────────────────────────────────────────
    // MARK: - F. Split state
    // ──────────────────────────────────────────────

    /// One suppression predicate reads two different bridgeless spellings.
    ///
    /// NON-TRANSITIVE: about the extracted body only; no claim about which arms
    /// callers actually reach.
    func testCurrentAllDaySuppressionBodyReadsTwoBridgelessSpellings() throws {
        let src = try productionSource(orchestratorPath)
        let body = try requireBody(
            "private func isAllDayWriteAllowed(bridgeID: String?, roomID: String) -> Bool {",
            in: src, of: orchestratorPath)

        requireContains("?? \"legacy\"", in: body, "some arms spell bridgelessness as legacy")
        requireContains("?? \"\"", in: body, "other arms spell it as the empty string")
    }

    /// The SSE-suppression deadline map is keyed by a bare grouped-light id
    /// with no bridge component.
    ///
    /// NON-TRANSITIVE: about the extracted declaration and the two extracted
    /// write-site bodies only.
    ///
    /// EXPLICITLY NOT ASSERTED: any runtime cross-bridge collision. Hue resource
    /// ids are bridge-local UUIDs and no evidence either way was found, so that
    /// consequence remains unproven and is characterized nowhere in this file.
    func testCurrentPendingActionDeadlinesAreKeyedByBareResourceID() throws {
        let src = try productionSource(orchestratorPath)

        let decl = try requireDeclaration("private var pendingActionDeadlines", in: src,
                                          of: orchestratorPath)
        requireContains("[String: Date]", in: decl,
                        "the map is keyed by a bare String, not a bridge-qualified key")

        for signature in ["func setRoom(_ item: RoomDisplayItem, isOn desiredState: Bool) {",
                          "func setBrightness(_ brightness: Double, for item: RoomDisplayItem) {"] {
            let body = try requireBody(signature, in: src, of: orchestratorPath)
            requireContains("pendingActionDeadlines[glID]", in: body,
                            "\(signature) keys the deadline by the grouped-light id alone")
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - G. Determinism
    // ──────────────────────────────────────────────

    /// No hardening guard covers a newly added test file, so this file polices
    /// its own determinism. The forbidden tokens are assembled at runtime from
    /// fragments, and the scan runs over source with comments and string
    /// literals removed — so this test cannot match its own guard text.
    func testThisFileUsesNoTimingWaits() throws {
        let raw = try XCTUnwrap(try? String(contentsOfFile: #filePath, encoding: .utf8),
                                "could not read this test file")

        var stripped: [String] = []
        for original in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(original)
            if text.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
            var out = ""
            var inString = false
            var escaped = false
            for ch in text {
                if escaped { escaped = false; continue }
                if ch == "\\" && inString { escaped = true; continue }
                if ch == "\"" { inString.toggle(); continue }
                if !inString { out.append(ch) }
            }
            stripped.append(out)
        }
        let scanned = stripped.joined(separator: "\n")

        let forbidden = ["Task" + "." + "sleep",
                         "XCT" + "Waiter",
                         "wait" + "(for:",
                         "expect" + "ation("]
        for token in forbidden {
            XCTAssertFalse(scanned.contains(token),
                           "this file must contain no timing wait — found: \(token)")
        }
    }
}
