// Composer2RESTCharacterizationTests.swift
// ChromaGlow — Composer 2 Phase 1B1.
//
// CHARACTERIZATION ONLY. Every assertion here pins what production does
// TODAY, including behavior that is undesirable. Nothing in this file
// asserts intended future behavior, and nothing consumes a Composer2Flag.
//
// Scope discipline — this file deliberately does NOT re-prove what the
// registered suite already proves directly:
//   • latest-wins per scope, FIFO fairness, epoch invalidation
//       → GatedBulkWriteTests (testLatestWinsIsPerScopeAndScopesAreIndependent,
//         testScopeSelectionIsFIFO, testEpochInvalidationIsVisibleBeforeClearReturns)
//   • one scope's executing work blocks another on the same sender
//       → GatedBulkWriteTests.testBurstEnqueuesNeverRunTwoClosuresConcurrently
//   • two bridges proceed independently
//       → MultiBridgeRoutingTests.testCrossBridgeIndependenceIsProvenByOrderingNotTiming
//   • scoped clear, cross-bridge stop isolation, superseded work, cancellation
//       → MultiBridgeRoutingTests packet-3 section
//   • rotation constants 5 / 4 / 20
//       → CompositionRoomPriorityScorerTests
//   • gate pacing and single retry as behavior
//       → GatedBulkWriteTests
//   • no production code consumes FlagStore / Composer2Flag
//       → FlagStoreTests.testNoProductionCodeConsumesFlagStoreYet
//
// Two tests pin DEFECTS on purpose and must be deleted with their fix:
//   • testCurrentDeltaGateIsFrameZeroOnlyAtPointZeroZeroThreeAndOne
//   • testCurrentActiveBurstBypassesTheDeltaGate
//
// Determinism: no timing waits of any kind. Enforced by the last test in
// this file, because every hardening guard's test-file list is hardcoded
// and does not cover a newly added file.

import XCTest
@testable import HueHome

// MARK: - Minimal recording client

/// Records only what these tests assert. The rich RoutingSpyClient is
/// `private` to MultiBridgeRoutingTests, so this file carries its own.
private final class Composer2RESTSpyClient: BridgeAPIClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _groupedWrites: [String] = []

    var groupedWrites: [String] {
        lock.lock(); defer { lock.unlock() }
        return _groupedWrites
    }

    private func record(_ entry: String) {
        lock.lock(); defer { lock.unlock() }
        _groupedWrites.append(entry)
    }

    override func setGroupedLight(id: String, on: Bool) async throws {
        record("setGroupedLight:\(id):\(on)")
    }

    override func setGroupedLightState(id: String, on: Bool, brightness: Double) async throws {
        record("setGroupedLightState:\(id):\(on)")
    }

    override func setGroupedLightEffect(id: String,
                                        on: Bool?,
                                        brightness: Double?,
                                        xy: (Double, Double)?,
                                        mirek: Int?,
                                        duration: Int) async throws {
        record("setGroupedLightEffect:\(id)")
    }
}

@MainActor
final class Composer2RESTCharacterizationTests: XCTestCase {

    private var bridgeA: Composer2RESTSpyClient!
    private var orchestrator: UnifiedOrchestrator!

    override func setUp() async throws {
        try await super.setUp()
        bridgeA = Composer2RESTSpyClient(bridgeID: "bridge-a", bridgeName: "Bridge A", ip: "192.0.2.1", token: "test-token")
        orchestrator = UnifiedOrchestrator()
        orchestrator.injectForTesting(clients: ["bridge-a": bridgeA])
    }

    override func tearDown() async throws {
        orchestrator = nil
        bridgeA = nil
        try await super.tearDown()
    }

    // ──────────────────────────────────────────────
    // MARK: - Fail-hard source-shape helpers
    //
    // These fail the test when a file, declaration, or body is missing —
    // they never skip, and they never fall back to a whole-file substring
    // count. Every constant below is anchored inside a NAMED declaration
    // body so a constant moving to another function is a failure.
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

    /// The brace-matched body of a declaration, located by an exact
    /// signature fragment. Fails when the signature is absent or the body
    /// comes back empty.
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

    // ──────────────────────────────────────────────
    // MARK: - A. Scheduler topology
    // ──────────────────────────────────────────────

    /// The load-bearing asymmetry Composer 2 will change: mailboxes and
    /// pacing gates are per-bridge, but the composition ticker is a single
    /// process-wide task. `Composer2Flag.perBridgeScheduler` exists for
    /// exactly this, and it is unconsumed today.
    func testCurrentCompositionSchedulerIsASingleProcessWideTicker() throws {
        let src = try productionSource(orchestratorPath)

        // Per-bridge: senders and gates are keyed dictionaries.
        requireContains("private var restSendersByBridge: [String: RestSender] = [:]",
                        in: src, "REST senders are per bridge")
        requireContains("private var allDayRestSendersByBridge: [String: RestSender] = [:]",
                        in: src, "All-Day senders are per bridge")
        requireContains("private var commandGates: [String: BridgeCommandGate] = [:]",
                        in: src, "command gates are per bridge")

        // Process-wide: the ticker is one unkeyed task, not a dictionary.
        requireContains("private var compositionSchedulerTask: Task<Void, Never>?",
                        in: src, "composition ticker is a single unkeyed task")
        requireAbsent("compositionSchedulerTasksByBridge", in: src,
                      "there is no per-bridge scheduler task map")
        requireAbsent("schedulerTasksByBridge", in: src,
                      "there is no per-bridge scheduler task map")
    }

    /// One room is selected per pass, across every bridge — so a room on one
    /// bridge waits behind a room on another at the scheduler level even
    /// though their mailboxes are independent.
    func testCurrentSchedulerSelectsOneRoomPerPassAcrossAllBridges() throws {
        let src = try productionSource(orchestratorPath)
        let body = try requireBody("private func runCompositionScheduler() async {",
                                   in: src, of: orchestratorPath)

        requireContains("while !Task.isCancelled {", in: body, "the ticker is a single loop")
        requireContains("guard let playbackKey = nextCompositionRoomPriority(now: now),",
                        in: body, "one playback key is chosen per pass")

        let selections = body.components(separatedBy: "nextCompositionRoomPriority(now:").count - 1
        XCTAssertEqual(selections, 1,
                       "exactly one room-selection call per scheduler pass")
    }

    /// Pacing constants, each anchored inside the declaration that owns it.
    func testCurrentSchedulerPacingConstantsAreUnchanged() throws {
        let src = try productionSource(orchestratorPath)

        let scheduler = try requireBody("private func runCompositionScheduler() async {",
                                        in: src, of: orchestratorPath)
        requireContains("let tickInterval: Duration = .milliseconds(120)",
                        in: scheduler, "scheduler tick interval")
        requireContains("current.nextDueAt = now + 0.12",
                        in: scheduler, "per-room next-due increment")

        let gradient = try requireBody("private func makeComposerGradientWork(",
                                       in: src, of: orchestratorPath)
        requireContains("try? await Task.sleep(for: .milliseconds(80))",
                        in: gradient, "gradient inter-batch gap")

        let perLight = try requireBody("private func makeComposerPerLightWork(",
                                       in: src, of: orchestratorPath)
        requireContains("try? await Task.sleep(for: .milliseconds(80))",
                        in: perLight, "per-light inter-batch gap")

        let stop = try requireBody("func stopCompositionMode(roomID: String, bridgeID: String?) async {",
                                   in: src, of: orchestratorPath)
        requireContains("try? await Task.sleep(for: .milliseconds(150))",
                        in: stop, "post-clear settle window")
    }

    /// CHARACTERIZATION OF DEFECT — delete with the fix.
    /// The whole room's "did anything change" decision is proxied through
    /// frame[0] alone, at fixed thresholds. A user edit that barely moves
    /// light 0 suppresses the frame for every other light in the room.
    func testCurrentDeltaGateIsFrameZeroOnlyAtPointZeroZeroThreeAndOne() throws {
        let src = try productionSource(orchestratorPath)
        let body = try requireBody("private func runCompositionScheduler() async {",
                                   in: src, of: orchestratorPath)

        requireContains("let firstFrame = frames[0]", in: body,
                        "the gate samples only the first frame")
        requireContains("let briDelta = abs(firstBri - (runtime.lastSentBri ?? -999))",
                        in: body, "brightness delta is computed from frame 0")
        requireContains("&& colorDelta < 0.003 && briDelta < 1.0 {",
                        in: body, "delta-gate thresholds")
    }

    /// CHARACTERIZATION OF DEFECT — delete with the fix.
    /// The forced-burst window is the only escape hatch from the frame[0]
    /// gate above.
    func testCurrentActiveBurstBypassesTheDeltaGate() throws {
        let src = try productionSource(orchestratorPath)
        let body = try requireBody("private func runCompositionScheduler() async {",
                                   in: src, of: orchestratorPath)

        requireContains("let userEditBurstActive = runtime.paramBox.forceRESTBurstUntil > now",
                        in: body, "burst window is read from the param box")
        requireContains("if !userEditBurstActive && !rotationIncomplete",
                        in: body, "an active burst skips the suppression branch")
    }

    /// The gate's constants as real symbols, not source text.
    func testCurrentGatePacingConstantsAreUnchanged() {
        XCTAssertEqual(BridgeCommandGate.minInterval, .milliseconds(100))
        XCTAssertEqual(BridgeCommandGate.retryBackoff, .milliseconds(400))
    }

    /// The Composer REST path does not use the pacing gate at all — its work
    /// builders dispatch batches concurrently and pace themselves with the
    /// 80 ms gap pinned above.
    func testCurrentComposerWorkBuildersDoNotUseTheCommandGate() throws {
        let src = try productionSource(orchestratorPath)
        for signature in ["private func makeComposerGradientWork(",
                          "private func makeComposerPerLightWork(",
                          "private func makeComposerGroupedWork("] {
            let body = try requireBody(signature, in: src, of: orchestratorPath)
            requireAbsent("gate.send(", in: body, "\(signature) does not use the gate")
            requireAbsent("commandGate(", in: body, "\(signature) does not resolve a gate")
        }
    }

    /// Studio live-param writes DO use the gate, and every one of them opts
    /// out of its retry: a superseded frame must not be resent.
    func testCurrentStudioParamWritesOptOutOfGateRetry() throws {
        let path = "HueHome/UI/Studio/StudioViewModel.swift"
        let src = try productionSource(path)
        for signature in ["func sendParam(cardID:", "func sendColorParam(cardID:"] {
            let body = try requireBody(signature, in: src, of: path)
            requireContains("gate.send(retry: false)", in: body,
                            "\(signature) opts out of gate retry")
            requireAbsent("gate.send(retry: true)", in: body,
                          "\(signature) never opts into gate retry")
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - B. Behavioral
    // ──────────────────────────────────────────────

    /// The burst deadline only ever extends — a shorter request cannot pull
    /// an existing window in.
    func testCurrentTriggerRESTBurstExtendsItsDeadlineMonotonically() {
        let box = CompositionParamBox(palette: PaletteConfig(),
                                      motion: MotionConfig(),
                                      envelope: EnvelopeConfig(),
                                      reaction: ReactionConfig())
        XCTAssertEqual(box.forceRESTBurstUntil, 0, "no burst window by default")

        box.triggerRESTBurst(seconds: 60)
        let long = box.forceRESTBurstUntil
        XCTAssertGreaterThan(long, 0, "a burst sets a future deadline")

        box.triggerRESTBurst(seconds: 1)
        XCTAssertEqual(box.forceRESTBurstUntil, long,
                       "a shorter burst never shortens an active window")

        box.triggerRESTBurst(seconds: 600)
        XCTAssertGreaterThan(box.forceRESTBurstUntil, long,
                             "a longer burst extends the window")
    }

    /// `RestScope` takes no bridge parameter. Bridge identity is absent from
    /// the scope and is supplied externally by the owning per-bridge
    /// dictionaries — nothing here claims anything beyond that.
    func testCurrentRestScopeIdentityIsRoomAndOwnerOnly() throws {
        let path = "HueHome/Core/Network/RestSender.swift"
        let src = try productionSource(path)
        let decl = try requireBody("struct RestScope: Hashable, Sendable {", in: src, of: path)

        requireContains("let roomID: String", in: decl, "RestScope declares roomID")
        requireContains("let owner: RestScopeOwner", in: decl, "RestScope declares owner")
        requireAbsent("bridgeID", in: decl, "RestScope declares no bridge identity")

        let a = RestScope(roomID: "room-1", owner: .composer)
        let b = RestScope(roomID: "room-1", owner: .composer)
        XCTAssertEqual(a, b, "same room and owner compare equal")
        XCTAssertEqual(a.hashValue, b.hashValue, "same room and owner hash equal")

        XCTAssertNotEqual(a, RestScope(roomID: "room-1", owner: .studio),
                          "owner participates in identity")
        XCTAssertNotEqual(a, RestScope(roomID: "room-2", owner: .composer),
                          "room participates in identity")
    }

    /// Composer and All-Day work for the SAME bridge and room live in two
    /// different sender actors, so they are separated by ownership policy
    /// rather than by a shared queue.
    func testCurrentComposerAndAllDayUseSeparateSendersForTheSameBridgeAndRoom() throws {
        let composer = orchestrator.testRestSender(for: "bridge-a")
        let allDay = try XCTUnwrap(orchestrator.testAllDayRestSender(for: "bridge-a"),
                                   "All-Day mailbox should exist for a live bridge")

        XCTAssertFalse(composer === allDay,
                       "Composer and All-Day use distinct sender actors")
        XCTAssertTrue(orchestrator.testRestSenderBridgeKeys().contains("bridge-a"))
        XCTAssertTrue(orchestrator.testAllDayRestSenderBridgeKeys().contains("bridge-a"))
    }

    // ──────────────────────────────────────────────
    // MARK: - C. Paths that bypass the mailbox
    //
    // `commandGates` is private with no inventory accessor, and
    // `commandGate(for:)` creates lazily — asking would conjure the very
    // gate we mean to prove absent. So the mailbox claim is behavioral and
    // the gate claim is source-shape, each on its own mechanism.
    // ──────────────────────────────────────────────

    /// A dashboard room write reaches the real code path — proven by its
    /// synchronous optimistic update — while creating no REST sender.
    func testCurrentRoomWritesCreateNoRestSender() {
        let room = RoomDisplayItem(
            id: "room-a", name: "Living A", archetype: nil,
            isOn: false, brightness: 40,
            groupedLightID: "gl-room-a", lightCount: 2,
            bridgeID: "bridge-a",
            childResourceRefs: [(rid: "LA1", rtype: "light")]
        )
        orchestrator.allRooms = [room]
        XCTAssertTrue(orchestrator.testRestSenderBridgeKeys().isEmpty,
                      "no sender exists before the write")

        orchestrator.setRoom(room, isOn: true)

        XCTAssertEqual(orchestrator.allRooms.first?.isOn, true,
                       "the real path ran: the optimistic update applied")
        XCTAssertTrue(orchestrator.testRestSenderBridgeKeys().isEmpty,
                      "a room write creates no REST sender")
    }

    /// Neither room-write body reaches the mailbox or the gate directly.
    /// This is a statement about these two extracted bodies only — a callee
    /// could still reach either, and this test does not rule that out.
    func testCurrentRoomAndLightWriteBodiesReferenceNeitherMailboxNorGate() throws {
        let src = try productionSource(orchestratorPath)

        let setRoom = try requireBody("func setRoom(_ item: RoomDisplayItem, isOn desiredState: Bool) {",
                                      in: src, of: orchestratorPath)
        requireContains("try await client.setGroupedLight(id: glID, on: desiredState)",
                        in: setRoom, "setRoom writes directly to the client")

        let setBrightness = try requireBody("func setBrightness(_ brightness: Double, for item: RoomDisplayItem) {",
                                            in: src, of: orchestratorPath)
        requireContains("try await client.setGroupedLightState(id: glID, on: true, brightness: clamped)",
                        in: setBrightness, "setBrightness writes directly to the client")

        for (name, body) in [("setRoom", setRoom), ("setBrightness", setBrightness)] {
            requireAbsent("restSender(", in: body, "\(name) body does not resolve a mailbox")
            requireAbsent(".enqueue(", in: body, "\(name) body does not enqueue")
            requireAbsent("commandGate(", in: body, "\(name) body does not resolve a gate")
        }
    }

    /// The composition prime writes through the client and creates no
    /// mailbox — it is deliberately outside the queue.
    func testCurrentCompositionPrimeWriteCreatesNoRestSender() async {
        let room = RoomDisplayItem(
            id: "room-prime", name: "Prime A", archetype: nil,
            isOn: true, brightness: 60,
            groupedLightID: "gl-room-prime", lightCount: 2,
            bridgeID: "bridge-a",
            childResourceRefs: [(rid: "LA1", rtype: "light")]
        )
        orchestrator.allRooms = [room]

        await orchestrator.testPerformCompositionPrime(room: room, generation: 1)

        XCTAssertEqual(bridgeA.groupedWrites, ["setGroupedLightEffect:gl-room-prime"],
                       "the prime issues exactly one grouped write")
        XCTAssertTrue(orchestrator.testRestSenderBridgeKeys().isEmpty,
                      "the prime creates no REST sender")
    }

    /// The prime body itself writes directly and references neither the
    /// mailbox nor the gate. Scoped to this extracted body only.
    func testCurrentCompositionPrimeBodyWritesDirectlyWithoutMailboxOrGate() throws {
        let src = try productionSource(orchestratorPath)
        let body = try requireBody("private func performCompositionPrime(",
                                   in: src, of: orchestratorPath)

        requireContains("try await api.setGroupedLightEffect(", in: body,
                        "the prime writes directly to the client")
        requireAbsent("restSender(", in: body, "the prime body does not resolve a mailbox")
        requireAbsent(".enqueue(", in: body, "the prime body does not enqueue")
        requireAbsent("commandGate(", in: body, "the prime body does not resolve a gate")
    }

    // ──────────────────────────────────────────────
    // MARK: - Self-guard
    // ──────────────────────────────────────────────

    /// No hardening guard covers a newly added test file, so this file
    /// polices its own determinism. The forbidden tokens are assembled at
    /// runtime from fragments, and the scan runs over source with comments
    /// and string literals removed — so this test cannot match its own
    /// guard text.
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
                         "expectation" + "("]
        for token in forbidden {
            XCTAssertFalse(scanned.contains(token),
                           "this file must contain no timing wait — found: \(token)")
        }
    }
}
