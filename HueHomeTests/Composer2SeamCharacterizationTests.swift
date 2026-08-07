// Composer2SeamCharacterizationTests.swift
// ChromaGlow — Composer 2 Phase 1C1.
//
// CHARACTERIZATION ONLY. Every assertion pins what production does TODAY.
// Nothing here asserts intended future behavior, and nothing consumes a
// Composer2Flag.
//
// This file closes two rows that Phase 1B2 could only report:
//
//   • terminal Entertainment-to-REST fallback ownership — previously
//     unobservable because the fallback fires at the tail of a task in
//     `compositionEntTasks`, which is private and never awaited;
//   • `startStudioMode`'s own same-bridge engine eviction — previously
//     unobservable because the evicted runtime is removed from the map
//     before anything can read it.
//
// Discipline, carried over from Phase 1B2 deliberately:
//   • Nothing is called a DEFECT.
//   • Every source-shape claim is NON-TRANSITIVE: it speaks only about the
//     extracted declaration or brace-matched body, never about callees.
//   • Every behavioral claim names its finite completion point.
//
// EXPLICITLY NOT PROVEN HERE — and not weakened into something that looks
// like proof:
//   • that a CANCELLED composition Entertainment task terminates. Awaiting
//     one can hang precisely because its termination is the open question,
//     and no bounded alternative exists without a timing wait. No test here
//     cancels a composition Entertainment task, so none is ever abandoned
//     with an unproven lifetime. The answerable half — that production
//     abandons rather than awaits — stays where it already is, in
//     Composer2OwnershipCharacterizationTests (no `await compositionEntTasks`).
//   • any `runtimeToken` EQUALITY across two evictions. The token is
//     `ObjectIdentifier(...).hashValue`, so a released param box's address
//     may be reused; the token is correlation-grade identity exactly as its
//     own doc says, and which runtime was evicted is pinned by the
//     co-recorded roomID instead.
//   • any cross-bridge `pendingActionDeadlines` collision (hardware-only).
//   • any detached `RestSender` flush outcome.
//
// Determinism: no timing waits of any kind. Enforced by the last test here.

import XCTest
import SwiftUI
@testable import HueHome

// MARK: - Minimal recording client

/// Serves the entertainment join (`configs` + `services` + lights) a real
/// area selection needs, and records grouped writes. The rich spies are
/// private to their own files, so this one carries what these tests assert.
private final class Composer2SeamSpyClient: BridgeAPIClient, @unchecked Sendable {
    private let lock = NSLock()

    var stubConfigsJSON: String = #"{"data": []}"#
    var stubEntertainmentJSON: String = #"{"data": []}"#
    var stubLights: [HueLight] = []

    private var _actions: [(configID: String, action: String)] = []
    var actions: [(configID: String, action: String)] {
        lock.lock(); defer { lock.unlock() }
        return _actions
    }

    private var _groupedWrites: [String] = []
    var groupedWrites: [String] {
        lock.lock(); defer { lock.unlock() }
        return _groupedWrites
    }

    override func get(path: String, ip: String, token: String) async throws -> Data {
        if path.contains("entertainment_configuration") {
            lock.lock(); let json = stubConfigsJSON; lock.unlock()
            return Data(json.utf8)
        }
        if path.contains("resource/entertainment") {
            lock.lock(); let json = stubEntertainmentJSON; lock.unlock()
            return Data(json.utf8)
        }
        return Data("{}".utf8)
    }

    override func put(path: String, body: [String: Any], ip: String, token: String) async throws -> Data {
        if path.contains("entertainment_configuration/"),
           let action = body["action"] as? String,
           let configID = path.split(separator: "/").last.map(String.init) {
            lock.lock(); _actions.append((configID, action)); lock.unlock()
        }
        return Data("{}".utf8)
    }

    override func fetchLights() async throws -> [HueLight] {
        lock.lock(); defer { lock.unlock() }
        return stubLights
    }

    override func setGroupedLightEffect(id: String,
                                        on: Bool?,
                                        brightness: Double?,
                                        xy: (Double, Double)?,
                                        mirek: Int?,
                                        duration: Int) async throws {
        lock.lock(); _groupedWrites.append("effect:\(id)"); lock.unlock()
    }

    override func setGroupedLightState(id: String, on: Bool, brightness: Double) async throws {
        lock.lock(); _groupedWrites.append("state:\(id)"); lock.unlock()
    }
}

/// Holds the Entertainment client the production path built, captured inside
/// the configurator hook — the only place a test is handed that exact object.
private final class ClientCaptureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _client: HueEntertainmentClient?
    var client: HueEntertainmentClient? {
        get { lock.lock(); defer { lock.unlock() }; return _client }
        set { lock.lock(); _client = newValue; lock.unlock() }
    }
}

@MainActor
final class Composer2SeamCharacterizationTests: XCTestCase {

    private var bridgeA: Composer2SeamSpyClient!
    private var orchestrator: UnifiedOrchestrator!
    private let bridgeAID = "bridge-a"

    override func setUp() async throws {
        try await super.setUp()
        bridgeA = Composer2SeamSpyClient(bridgeID: bridgeAID, bridgeName: "Bridge A",
                                         ip: "192.0.2.1", token: "t")
        orchestrator = UnifiedOrchestrator()
        orchestrator.injectForTesting(clients: [bridgeAID: bridgeA])
        // Entertainment acquisition gates on a client key before anything
        // else. Non-hex on purpose: the DTLS decode must refuse before any
        // socket exists, and the stub transport replaces the socket anyway.
        try KeychainManager.shared.saveCredentials(
            ip: "192.0.2.1", token: "t", clientKey: "ZZ-not-hex", for: bridgeAID)
    }

    override func tearDown() async throws {
        await orchestrator.stopStudioMode()
        KeychainManager.shared.deleteCredentials(for: bridgeAID)
        orchestrator = nil
        bridgeA = nil
        try await super.tearDown()
    }

    // ──────────────────────────────────────────────
    // MARK: - Fixtures
    // ──────────────────────────────────────────────

    private func room(_ id: String, lightIDs: [String]) -> RoomDisplayItem {
        RoomDisplayItem(
            kind: .room,
            id: id, name: id, archetype: nil,
            isOn: true, brightness: 100,
            groupedLightID: "grouped-\(id)", lightCount: lightIDs.count,
            bridgeID: bridgeAID,
            childResourceRefs: lightIDs.map { (rid: $0, rtype: "light") }
        )
    }

    private func light(_ id: String, device: String) -> HueLight {
        HueLight(
            id: id,
            metadata: LightMetadata(name: id, archetype: nil),
            on: OnState(on: true),
            dimming: DimmingState(brightness: 100),
            color: nil,
            color_temperature: nil,
            owner: ResourceRef(rid: device, rtype: "device")
        )
    }

    /// One bridge, one area covering exactly `room-a`'s two lights.
    private func stageStreamableBridge() {
        bridgeA.stubLights = [light("L1", device: "D1"), light("L2", device: "D2")]
        bridgeA.stubEntertainmentJSON =
            #"{"data":[{"id":"E1","owner":{"rid":"D1","rtype":"device"}},"# +
            #"{"id":"E2","owner":{"rid":"D2","rtype":"device"}}]}"#
        let channels =
            #"{"channel_id":0,"position":{"x":0,"y":0,"z":0},"members":[{"service":{"rid":"E1","rtype":"entertainment"}}]},"# +
            #"{"channel_id":1,"position":{"x":0,"y":0,"z":0},"members":[{"service":{"rid":"E2","rtype":"entertainment"}}]}"#
        bridgeA.stubConfigsJSON =
            #"{"data":[{"id":"area-a","metadata":{"name":"Bedroom"},"channels":[\#(channels)]}]}"#
    }

    private func paramBox() -> CompositionParamBox {
        CompositionParamBox(palette: PaletteConfig(), motion: MotionConfig(),
                            envelope: EnvelopeConfig(), reaction: ReactionConfig())
    }

    // ──────────────────────────────────────────────
    // MARK: - Fail-hard source-shape helpers
    //
    // These fail when a file or declaration is missing — they never skip, and
    // never fall back to a whole-file substring count.
    // ──────────────────────────────────────────────

    private var orchestratorPath: String { "HueHome/Core/Network/UnifiedOrchestrator.swift" }

    private func productionSource(_ relativePath: String,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // HueHomeTests/
            .deletingLastPathComponent()   // repo root
        let url = repoRoot.appendingPathComponent(relativePath)
        guard let raw = try? String(contentsOf: url, encoding: .utf8), !raw.isEmpty else {
            XCTFail("Missing or empty production file: \(relativePath)", file: file, line: line)
            throw SeamCharacterizationFailure.missingFile(relativePath)
        }
        return raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private func requireBody(_ signature: String,
                             in source: String,
                             of path: String,
                             file: StaticString = #filePath,
                             line: UInt = #line) throws -> String {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: { $0.contains(signature) }) else {
            XCTFail("\(path): declaration not found: \(signature)", file: file, line: line)
            throw SeamCharacterizationFailure.missingSymbol(signature)
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
            throw SeamCharacterizationFailure.emptyBody(signature)
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

    private enum SeamCharacterizationFailure: Error {
        case missingFile(String)
        case missingSymbol(String)
        case emptyBody(String)
    }

    // ──────────────────────────────────────────────
    // MARK: - A. Terminal Entertainment-to-REST fallback ownership
    // ──────────────────────────────────────────────

    /// The row Phase 1B1 reported rather than proved.
    ///
    /// FINITE COMPLETION POINT: `await entTask.value`. The task is NEVER
    /// cancelled here. `noteTerminalFailure()` — internal precisely so tests
    /// can drive the abandonment path without a live socket — flips the flag
    /// the render loop reads at the top of each frame, so the loop breaks and
    /// the task's own tail runs the fallback. Nothing polls, sleeps, or waits.
    func testCurrentTerminalDTLSFailureMovesCompositionOwnershipToREST() async throws {
        stageStreamableBridge()
        let roomA = room("room-a", lightIDs: ["L1", "L2"])
        let captured = ClientCaptureBox()
        orchestrator.injectForTesting(entertainmentClientConfigurator: { client in
            // Everything above the socket runs for real; only the socket is
            // stubbed, so the production commit path is the path under test.
            await client.testEnableStubTransport()
            captured.client = client
        })
        await orchestrator.warmEntertainmentCaches(for: roomA)

        // ANTI-VACUITY: no composer REST mailbox exists for this bridge yet,
        // so the one asserted after the fallback cannot be a leftover.
        XCTAssertFalse(orchestrator.testRestSenderBridgeKeys().contains(bridgeAID),
            "no REST mailbox may exist for this bridge before the fallback")

        let outcome = await orchestrator.startCompositionMode(
            room: roomA, paramBox: paramBox(), preferEntertainment: true)

        // ANTI-VACUITY: the Entertainment transport really was live. Without
        // this the `.rest` assertion below would pass on a room that never
        // streamed at all.
        XCTAssertEqual(outcome, .started(transport: .entertainment),
            "the fallback is only meaningful if Entertainment actually started")
        XCTAssertEqual(
            orchestrator.testCompositionTransport(bridgeID: bridgeAID, roomID: "room-a"),
            .entertainment)
        XCTAssertTrue(orchestrator.testHasCompositionEntertainmentTask(forBridge: bridgeAID))
        XCTAssertEqual(orchestrator.testCompositionEntertainmentRoom(forBridge: bridgeAID),
                       "room-a")

        // Capture THAT task handle, before the fallback removes its entry.
        let entTask = try XCTUnwrap(
            orchestrator.testCaptureCompositionEntertainmentTask(forBridge: bridgeAID),
            "the Entertainment render task must be installed to be captured")

        // Exhaust the bounded reconnect, exactly as the client itself does.
        let entClient = try XCTUnwrap(captured.client,
            "the configurator must have been handed the production client")
        await entClient.noteTerminalFailure()

        await entTask.value

        // The ownership transition, read through non-mutating accessors only.
        XCTAssertEqual(
            orchestrator.testCompositionTransport(bridgeID: bridgeAID, roomID: "room-a"),
            .rest,
            "a terminally failed session must hand the room to REST, not freeze it")
        XCTAssertTrue(
            orchestrator.testHasCompositionRuntime(bridgeID: bridgeAID, roomID: "room-a"),
            "the composition keeps running — on the other transport")
        XCTAssertFalse(orchestrator.testHasCompositionEntertainmentTask(forBridge: bridgeAID),
            "the Entertainment task is released, not left installed")
        XCTAssertNil(orchestrator.testCompositionEntertainmentRoom(forBridge: bridgeAID),
            "and the bridge's Entertainment room claim is withdrawn")
        XCTAssertTrue(orchestrator.testRestSenderBridgeKeys().contains(bridgeAID),
            "the REST mailbox the room now writes through exists")

        await orchestrator.stopCompositionMode(roomID: "room-a", bridgeID: bridgeAID)
    }

    // ──────────────────────────────────────────────
    // MARK: - B. The capture seam itself
    // ──────────────────────────────────────────────

    /// The accessor test A depends on is a pure slot read — it must not be
    /// able to perturb the very state the behavioral test measures.
    ///
    /// Source-shape, and NON-TRANSITIVE: this speaks only about the extracted
    /// accessor body. It makes no claim about callees, and deliberately does
    /// not start a second composition merely to demonstrate Swift's handle
    /// semantics — doing so would cancel a task whose termination this packet
    /// cannot prove, and abandon it.
    func testCurrentCompositionEntertainmentTaskCaptureIsAPureSlotRead() throws {
        let src = try productionSource(orchestratorPath)
        let body = try requireBody(
            "func testCaptureCompositionEntertainmentTask(forBridge bridgeID: String)",
            in: src, of: orchestratorPath)

        requireContains("compositionEntTasks[bridgeID]", in: body,
                        "the accessor returns the existing slot")
        requireAbsent("=", in: body, "the accessor assigns nothing")
        requireAbsent("removeValue", in: body, "the accessor removes nothing")
        requireAbsent("cancel(", in: body, "the accessor cancels nothing")
        requireAbsent("await", in: body, "the accessor awaits nothing")
        requireAbsent("var ", in: body, "the accessor introduces no stored property")
    }

    // ──────────────────────────────────────────────
    // MARK: - C. startStudioMode's own engine eviction
    // ──────────────────────────────────────────────

    /// A same-bridge Studio start evicts the bridge's previous engine runtime.
    /// Phase 1B2 could only characterize the shape: the runtime is removed
    /// from the map before it is cancelled, so `testStudioEngineTaskIsCancelled`
    /// — which reads the CURRENT slot — can never see the evicted one.
    ///
    /// FINITE COMPLETION POINT: `startStudioMode` returning. The audit event
    /// is recorded synchronously inside it; nothing detached is observed.
    ///
    /// The event's identity is `stopAuditToken(previous.paramBox)`, the same
    /// idiom `stopStudioMode` already uses. Token EQUALITY across evictions is
    /// deliberately not asserted (see this file's header); which runtime was
    /// evicted is pinned by the co-recorded roomID.
    func testCurrentStartStudioModeEvictionRecordsTheEvictedRuntimesRoomAndIdentity() async throws {
        let roomA = room("room-a", lightIDs: ["L1", "L2"])
        let roomB = room("room-b", lightIDs: ["L1", "L2"])

        // Stage the runtime that is about to be evicted — an inert task, a
        // real box, no loop.
        orchestrator.testInstallStudioEngineRuntime(bridgeKey: bridgeAID, roomID: "room-a")

        // ANTI-VACUITY: a runtime genuinely exists to evict, and it is the
        // one this test names.
        XCTAssertTrue(orchestrator.testHasStudioEngineTask(forBridge: bridgeAID))
        XCTAssertEqual(orchestrator.testStudioEngineRuntimeRoom(forBridge: bridgeAID), "room-a")
        XCTAssertEqual(orchestrator.testStudioEngineTaskIsCancelled(forBridge: bridgeAID), false,
            "the staged runtime must start uncancelled, or the eviction proves nothing")

        orchestrator.testResetStopAudit()

        // A non-streaming card on the SAME bridge, different room: the exact
        // one-engine-per-bridge eviction, with no Entertainment involved.
        _ = await orchestrator.startStudioMode(
            key: "candle", room: roomB, params: [:], colors: [:])

        let evictions = orchestrator.stopAuditEvents.filter {
            $0.route == .applyEngineSingleton && $0.operation == .taskCancelled
        }
        XCTAssertEqual(evictions.count, 1,
            "exactly one engine eviction is recorded: \(orchestrator.stopAuditEvents)")
        let event = try XCTUnwrap(evictions.first)
        XCTAssertEqual(event.roomID, "room-a",
            "the event names the EVICTED room, not the incoming one")
        XCTAssertEqual(event.bridgeID, bridgeAID)
        XCTAssertEqual(event.cardOrEffectID, "candle",
            "the incoming card is the attribution, the evicted room is the subject")
        XCTAssertNotNil(event.runtimeToken,
            "the evicted runtime's identity is captured, not just its room")

        _ = roomA
    }

    // ──────────────────────────────────────────────
    // MARK: - D. Determinism self-guard
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
