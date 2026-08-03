// BridgeAnimationCorrectnessTests.swift
// HueHome Pro — Unit Tests
//
// Regression guards for audit findings M-04 / M-05 (bridge-stored animation):
//  - resolveV1LightIDs maps v2 UUIDs → v1 numeric IDs via `id_v1` IDENTITY:
//    mismatched numeric ordering must not scramble the output, and an
//    unresolvable light fails closed instead of guessing positionally.
//  - An 8+ light room uploads successfully with every rule carrying ≤8
//    actions (≤7 light PUTs + at most one sensor advance) and full light
//    coverage per step — the v1 8-actions-per-rule limit used to abort the
//    whole upload for any normal-sized room.
//
// Audit: docs/audit/hardening-audit-2026-07-01.md §6 "Bridge animation".

import XCTest
@testable import HueHome

// MARK: - Spy v1 client

private final class AnimationSpyV1Client: HueV1Client, @unchecked Sendable {
    struct RuleRecord {
        let name: String
        let conditions: [[String: Any]]
        let actions: [[String: Any]]
    }

    private let lock = NSLock()
    private var _rules: [RuleRecord] = []
    var rules: [RuleRecord] {
        lock.lock(); defer { lock.unlock() }
        return _rules
    }
    private var nextRuleID = 0

    /// Packet 5: what the BRIDGE reports free. Generous by default so the
    /// existing coverage is unaffected; individual tests stage a shortage or
    /// a fetch failure.
    var reportedCapacity: BridgeReportedCapacity = .init(
        rulesAvailable: 250, ruleConditionsAvailable: 2500,
        ruleActionsAvailable: 2500, sensorsAvailable: 250, schedulesAvailable: 100)
    var capacityFetchError: Error?

    /// Every resource this spy was asked to CREATE, in order. A refusal must
    /// leave this empty — no write may precede a passing preflight.
    private var _creations: [String] = []
    var creations: [String] {
        lock.lock(); defer { lock.unlock() }
        return _creations
    }

    override func fetchReportedCapacity() async throws -> BridgeReportedCapacity {
        if let capacityFetchError { throw capacityFetchError }
        return reportedCapacity
    }

    override func createCLIPSensor(name: String, initialStatus: Int) async throws -> String {
        lock.lock(); _creations.append("sensor"); lock.unlock()
        return "51"
    }

    override func createRule(
        name: String,
        conditions: [[String: Any]],
        actions: [[String: Any]]
    ) async throws -> String {
        lock.lock(); defer { lock.unlock() }
        _rules.append(RuleRecord(name: name, conditions: conditions, actions: actions))
        _creations.append("rule")
        nextRuleID += 1
        return "\(nextRuleID)"
    }

    override func createRecurringSchedule(
        name: String, intervalSeconds: Int, command: [String: Any], autoDelete: Bool
    ) async throws -> String { "77" }

    override func createResourcelink(
        name: String, description: String, links: [String]
    ) async throws -> String { "88" }

    override func setSensorStatus(id: String, status: Int) async throws {}
}

// MARK: - Tests

final class BridgeAnimationCorrectnessTests: XCTestCase {

    // ──────────────────────────────────────────────
    // MARK: - M-04: id_v1 identity mapping
    // ──────────────────────────────────────────────

    private func makeLight(id: String, idV1: String?) -> HueLight {
        HueLight(
            id: id,
            metadata: LightMetadata(name: "L-\(id)", archetype: nil),
            on: OnState(on: true),
            dimming: nil, color: nil, color_temperature: nil, owner: nil,
            id_v1: idV1
        )
    }

    func testResolveV1LightIDsMapsByIdentityNotPosition() throws {
        let client = HueV1Client(ip: "192.0.2.1", token: "t")
        // Deliberately scrambled: the numerically-lowest v1 id belongs to the
        // LAST requested light. Positional mapping would return ["3","7","12"].
        let v2Lights = [
            makeLight(id: "uuid-a", idV1: "/lights/12"),
            makeLight(id: "uuid-b", idV1: "/lights/7"),
            makeLight(id: "uuid-c", idV1: "/lights/3"),
        ]
        let resolved = try client.resolveV1LightIDs(
            from: ["uuid-a", "uuid-b", "uuid-c"], v2Lights: v2Lights)
        XCTAssertEqual(resolved, ["12", "7", "3"],
                       "output[i] must be the id_v1 of input[i] — identity, not numeric order")
    }

    func testResolveV1LightIDsPassesThroughNumericInput() throws {
        let client = HueV1Client(ip: "192.0.2.1", token: "t")
        XCTAssertEqual(try client.resolveV1LightIDs(from: ["4", "2"], v2Lights: []), ["4", "2"])
    }

    func testResolveV1LightIDsFailsClosedOnUnmappableLight() {
        let client = HueV1Client(ip: "192.0.2.1", token: "t")
        let v2Lights = [makeLight(id: "uuid-a", idV1: nil)]
        XCTAssertThrowsError(
            try client.resolveV1LightIDs(from: ["uuid-a"], v2Lights: v2Lights),
            "a light without id_v1 must throw — never guess positionally (M-04)"
        )
        XCTAssertThrowsError(
            try client.resolveV1LightIDs(from: ["uuid-unknown"], v2Lights: v2Lights))
    }

    // ──────────────────────────────────────────────
    // MARK: - L-04: scene capacity never gates the rules-chain uploader
    // ──────────────────────────────────────────────

    /// Packet 5 replaced `canFitOneAnimation`'s flat `>= 12 free rules` with a
    /// requirement computed from the arithmetic the uploader executes. The old
    /// gate under-counted by half for a full room, so a bridge with 13 free
    /// slots passed and then threw partway through the rule loop.
    private func capacity(
        rules: Int? = 250, conditions: Int? = 2500, actions: Int? = 2500,
        sensors: Int? = 250, schedules: Int? = 100
    ) -> BridgeReportedCapacity {
        .init(rulesAvailable: rules, ruleConditionsAvailable: conditions,
              ruleActionsAvailable: actions, sensorsAvailable: sensors,
              schedulesAvailable: schedules)
    }

    func testSceneStarvedBridgeStillFitsOneAnimation() {
        // The uploader drives light states directly (sceneIDs is always []),
        // so scene capacity is not modelled at all and cannot gate (L-04).
        let need = BridgeStoredRequirement(lights: 6, steps: 8)
        XCTAssertEqual(capacity().verdict(for: need), .fits)
    }

    func testRuleStarvedBridgeReportsInsufficient() {
        let need = BridgeStoredRequirement(lights: 6, steps: 8)   // 8 rules
        guard case .insufficient(_, _, let shortages) =
                capacity(rules: 5).verdict(for: need) else {
            return XCTFail("a bridge with 5 free rules cannot fit an 8-rule look")
        }
        XCTAssertEqual(shortages, [.rules])
    }

    // ──────────────────────────────────────────────
    // MARK: - Composer 2 packet 5: aggregate capacity, honest refusal
    // ──────────────────────────────────────────────

    /// Upload a room of `lights` bulbs through the real engine.
    private func upload(
        lights: Int, spy: AnimationSpyV1Client
    ) async throws -> BridgeAnimationManifest {
        let engine = BridgeAnimationEngine()
        let preset = try XCTUnwrap(
            CompositionStore.builtInPresets.first { !$0.reaction.requiresMic })
        let room = RoomDisplayItem(
            id: "room-\(lights)", name: "Room", archetype: nil,
            isOn: true, brightness: 50,
            groupedLightID: "gl", lightCount: lights,
            bridgeID: "bridge-a", childResourceRefs: [])
        let v2IDs = (1...lights).map { "uuid-\($0)" }
        let v2Lights = (1...lights).map { makeLight(id: "uuid-\($0)", idV1: "/lights/\($0)") }
        return try await engine.upload(
            preset: preset, room: room, lightIDs: v2IDs, v2Lights: v2Lights,
            gamut: .c, v1Client: spy)
    }

    // MARK: The requirement formula

    // Conditions and actions are AGGREGATE bridge-wide consumption, not
    // per-rule maxima. Reading the nested capability numbers as per-rule
    // limits would have compared 8 against 8 and always passed, missing the
    // case where a bridge has plenty of free rules but not enough free
    // actions to fill them.
    func testRequirementFormulaForSixLightsAndEightSteps() {
        let need = BridgeStoredRequirement(lights: 6, steps: 8)
        XCTAssertEqual(need.ruleResources, 8)     // 8 × ceil(6/7) = 8 × 1
        XCTAssertEqual(need.ruleConditions, 16)   // two per rule
        XCTAssertEqual(need.ruleActions, 55)      // 8×6 = 48, +7 sensor advances
    }

    func testRequirementFormulaForTwentyLightsAndEightSteps() {
        let need = BridgeStoredRequirement(lights: 20, steps: 8)
        XCTAssertEqual(need.ruleResources, 24)    // 8 × ceil(20/7) = 8 × 3
        XCTAssertEqual(need.ruleConditions, 48)
        XCTAssertEqual(need.ruleActions, 167)     // 160 + 7
    }

    func testRequirementFormulaForTwentyFiveLightsAndEightSteps() {
        let need = BridgeStoredRequirement(lights: 25, steps: 8)
        XCTAssertEqual(need.ruleResources, 32)    // 8 × ceil(25/7) = 8 × 4
        XCTAssertEqual(need.ruleConditions, 64)
        XCTAssertEqual(need.ruleActions, 207)     // 200 + 7
    }

    func testCeilDivIsIntegerArithmeticWithNoFloatingPointRounding() {
        for l in 0...64 {
            XCTAssertEqual(BridgeStoredRequirement.ceilDiv(l, 7), (l + 6) / 7, "l=\(l)")
        }
        // The final step carries no sensor advance, so a one-step look adds none.
        XCTAssertEqual(BridgeStoredRequirement(lights: 4, steps: 1).ruleActions, 4)
    }

    // MARK: No truncation

    func testTwentyFiveLightRoomCoversEveryLightInEveryStep() async throws {
        let spy = AnimationSpyV1Client(ip: "192.0.2.1", token: "t")
        _ = try await upload(lights: 25, spy: spy)

        // Before packet 5 this room rendered 20 frames and lights 21–25 were
        // absent from every rule — silently, with the log still claiming 25.
        let step0Rules = spy.rules.filter { rule in
            rule.conditions.contains {
                ($0["value"] as? String) == "0" && ($0["operator"] as? String) == "eq"
            }
        }
        let addresses = Set(step0Rules.flatMap(\.actions).compactMap { action -> String? in
            guard let a = action["address"] as? String, a.hasPrefix("/lights/") else { return nil }
            return a
        })
        XCTAssertEqual(addresses.count, 25, "every light must appear in step 0")
        for i in 1...25 {
            XCTAssertTrue(addresses.contains("/lights/\(i)/state"), "light \(i) missing")
        }
        for rule in spy.rules {
            XCTAssertLessThanOrEqual(rule.actions.count, 8,
                "the per-rule ceiling still holds at 25 lights")
        }
    }

    // MARK: Refusal — measured, and before any write

    func testInsufficientCapacityRefusesBeforeCreatingAnything() async throws {
        let spy = AnimationSpyV1Client(ip: "192.0.2.1", token: "t")
        // 25 lights × 8 steps needs 32 rules; offer 20.
        spy.reportedCapacity = capacity(rules: 20)

        do {
            _ = try await upload(lights: 25, spy: spy)
            XCTFail("expected a capacity refusal")
        } catch let error as BridgeAnimationError {
            guard case .bridgeCapacityInsufficient(_, _, let shortages) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(shortages, [.rules])
        }
        XCTAssertTrue(spy.creations.isEmpty,
            "a refusal must create NOTHING on the bridge — no sensor, no rules")
    }

    /// The case a per-rule reading of the nested numbers would have missed
    /// entirely: plenty of free rules, not enough free actions to fill them.
    func testAggregateActionShortageRefusesEvenWithAmpleFreeRules() async throws {
        let spy = AnimationSpyV1Client(ip: "192.0.2.1", token: "t")
        spy.reportedCapacity = capacity(rules: 250, actions: 100)   // needs 167

        do {
            _ = try await upload(lights: 20, spy: spy)
            XCTFail("expected a capacity refusal")
        } catch let error as BridgeAnimationError {
            guard case .bridgeCapacityInsufficient(_, _, let shortages) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(shortages, [.ruleActions])
        }
        XCTAssertTrue(spy.creations.isEmpty)
    }

    /// Every shortage refuses, and only a rules-ONLY shortage may name rule
    /// slots. Four of the five would otherwise show a number about the wrong
    /// resource.
    func testEveryShortageRefusesAndOnlyRulesMayClaimRuleSlots() {
        let need = BridgeStoredRequirement(lights: 20, steps: 8)
        let cases: [(BridgeStoredRequirement.Shortage, BridgeReportedCapacity)] = [
            (.rules,           capacity(rules: 1)),
            (.ruleConditions,  capacity(conditions: 1)),
            (.ruleActions,     capacity(actions: 1)),
            (.sensors,         capacity(sensors: 0)),
            (.schedules,       capacity(schedules: 0)),
        ]
        for (expected, reported) in cases {
            guard case .insufficient(let required, let cap, let shortages) =
                    reported.verdict(for: need) else {
                XCTFail("\(expected) should be insufficient"); continue
            }
            XCTAssertEqual(shortages, [expected])
            let message = BridgeAnimationError
                .bridgeCapacityInsufficient(required: required, reported: cap,
                                            shortages: shortages)
                .errorDescription ?? ""
            if expected == .rules {
                XCTAssertTrue(message.contains("free rule slots"),
                    "a rules shortage may quote the rule figure: \(message)")
            } else {
                XCTAssertFalse(message.contains("rule slots"),
                    "\(expected) is not a rule-slot shortage, but the copy said so: \(message)")
                XCTAssertTrue(message.contains("enough free space"))
            }
            XCTAssertFalse(message.contains("about 12"), "the old fixed figure is gone")
        }
    }

    func testAMultiFieldShortageNeverNamesRuleSlots() {
        let need = BridgeStoredRequirement(lights: 20, steps: 8)
        guard case .insufficient(let required, let cap, let shortages) =
                capacity(rules: 1, actions: 1).verdict(for: need) else {
            return XCTFail("expected insufficient")
        }
        XCTAssertEqual(shortages, [.rules, .ruleActions])
        let message = BridgeAnimationError
            .bridgeCapacityInsufficient(required: required, reported: cap, shortages: shortages)
            .errorDescription ?? ""
        XCTAssertFalse(message.contains("rule slots"),
            "with two resources short, naming only rules would be misleading")
    }

    func testDiagnosticsCarryAllFiveFiguresWhateverTheSentenceSaid() {
        let need = BridgeStoredRequirement(lights: 20, steps: 8)
        let summary = capacity(sensors: 0).diagnosticSummary(for: need)
        for fragment in ["rules need 24", "conditions need 48", "actions need 167",
                         "sensors need 1", "schedules need 1"] {
            XCTAssertTrue(summary.contains(fragment), "missing \(fragment) in: \(summary)")
        }
    }

    // MARK: Unknown capacity fails closed

    func testUnknownCapacityFromAFailedFetchCreatesNothing() async throws {
        let spy = AnimationSpyV1Client(ip: "192.0.2.1", token: "t")
        spy.capacityFetchError = HueAPIError.httpError(500)

        do {
            _ = try await upload(lights: 6, spy: spy)
            XCTFail("expected a fail-closed refusal")
        } catch let error as BridgeAnimationError {
            guard case .bridgeCapacityUnknown = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
        XCTAssertTrue(spy.creations.isEmpty,
            "silence about capacity is never permission — fail closed, write nothing")
    }

    func testUnknownCapacityFromAnIncompleteBodyCreatesNothing() async throws {
        for missing in [
            capacity(rules: nil),
            capacity(conditions: nil),
            capacity(actions: nil),
            capacity(sensors: nil),
            capacity(schedules: nil),
        ] {
            let spy = AnimationSpyV1Client(ip: "192.0.2.1", token: "t")
            spy.reportedCapacity = missing
            do {
                _ = try await upload(lights: 6, spy: spy)
                XCTFail("a missing figure must not be treated as available")
            } catch let error as BridgeAnimationError {
                guard case .bridgeCapacityUnknown = error else {
                    return XCTFail("wrong error: \(error)")
                }
            }
            XCTAssertTrue(spy.creations.isEmpty)
        }
    }

    func testUnknownCapacityNeverClaimsTheBridgeIsFull() {
        let message = BridgeAnimationError
            .bridgeCapacityUnknown(reason: "bridge did not report rules.available")
            .errorDescription ?? ""
        XCTAssertFalse(message.contains("almost full"))
        XCTAssertFalse(message.contains("enough free space"))
        XCTAssertTrue(message.contains("Couldn't check"))
    }

    // MARK: /capabilities decoding

    private func decode(_ json: String) -> BridgeReportedCapacity {
        HueV1Client.decodeReportedCapacity(Data(json.utf8))
    }

    /// Documented v1 `/capabilities` shape. NOTE: this fixture proves the
    /// PARSER, not the schema — it is authored, not captured from hardware, so
    /// it is never treated as evidence about a real bridge. The device
    /// checklist captures a real body so this can be tightened.
    func testCapabilitiesDecodesTheDocumentedShape() {
        let reported = decode("""
        {"lights":{"available":13,"total":63},
         "sensors":{"available":191,"total":250},
         "groups":{"available":60},
         "scenes":{"available":172,"total":200},
         "rules":{"available":233,"total":250,
                  "conditions":{"available":1500,"total":1500},
                  "actions":{"available":900,"total":1000}},
         "schedules":{"available":95,"total":100},
         "resourcelinks":{"available":63,"total":64}}
        """)
        XCTAssertEqual(reported.rulesAvailable, 233)
        XCTAssertEqual(reported.ruleConditionsAvailable, 1500)
        XCTAssertEqual(reported.ruleActionsAvailable, 900)
        XCTAssertEqual(reported.sensorsAvailable, 191)
        XCTAssertEqual(reported.schedulesAvailable, 95)
    }

    func testCapabilitiesMissingRulesIsUnknownNotZero() {
        let reported = decode("""
        {"sensors":{"available":191},"schedules":{"available":95}}
        """)
        XCTAssertNil(reported.rulesAvailable)
        let need = BridgeStoredRequirement(lights: 6, steps: 8)
        guard case .unknown = reported.verdict(for: need) else {
            return XCTFail("a missing figure must be unknown, never a zero that 'fits'")
        }
    }

    func testCapabilitiesWithRulesButNoNestedRecordsIsUnknown() {
        let reported = decode("""
        {"rules":{"available":233},"sensors":{"available":5},"schedules":{"available":5}}
        """)
        XCTAssertEqual(reported.rulesAvailable, 233)
        XCTAssertNil(reported.ruleActionsAvailable)
        guard case .unknown = reported.verdict(
            for: BridgeStoredRequirement(lights: 6, steps: 8)) else {
            return XCTFail("nested action capacity is required")
        }
    }

    func testMalformedAndEmptyCapabilitiesBodiesAreUnknown() {
        for body in ["", "not json", "[]", "{}"] {
            let reported = decode(body)
            XCTAssertEqual(reported, .unknown, "body \"\(body)\" should decode to unknown")
        }
    }

    // MARK: v1 HTTP-200 error envelope

    func testErrorEnvelopeParsesToATypedAPIErrorNotADecodeFailure() throws {
        let body = Data("""
        [{"error":{"type":601,"address":"/rules","description":"resource, /rules, is not available"}}]
        """.utf8)
        let parsed = try XCTUnwrap(HueV1Client.parsedAPIError(from: body))
        guard case .apiError(let type, let address, let description) = parsed else {
            return XCTFail("expected a typed apiError")
        }
        XCTAssertEqual(type, 601)
        XCTAssertEqual(address, "/rules")
        XCTAssertEqual(description, "resource, /rules, is not available")
    }

    /// The envelope is EXTRACTED, never classified. Even a description that
    /// reads like exhaustion must not become a capacity claim: the string is
    /// brittle and possibly localized, no captured hardware response justifies
    /// a discriminator yet, and preflight is a point-in-time check — a failure
    /// after it passed is not evidence the bridge is full.
    func testAnErrorEnvelopeIsNeverClassifiedAsCapacityFromItsDescription() throws {
        let body = Data("""
        [{"error":{"type":601,"address":"/rules","description":"resource, /rules, is not available"}}]
        """.utf8)
        let parsed = try XCTUnwrap(HueV1Client.parsedAPIError(from: body))
        let message = parsed.localizedDescription
        XCTAssertFalse(message.contains("almost full"))
        XCTAssertFalse(message.contains("free rule slots"))

        // And the source carries no description-matching predicate.
        let engineSource = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("HueHome/Core/Network/BridgeAnimationEngine.swift"),
            encoding: .utf8)
        for smell in ["is not available", "description?.contains", "description.contains"] {
            XCTAssertFalse(engineSource.contains(smell),
                "capacity must not be inferred from error text (\(smell))")
        }
    }

    func testSuccessAndUnrelatedBodiesAreNotErrorEnvelopes() {
        XCTAssertNil(HueV1Client.parsedAPIError(
            from: Data(#"[{"success":{"id":"42"}}]"#.utf8)))
        XCTAssertNil(HueV1Client.parsedAPIError(from: Data("{}".utf8)))
        XCTAssertNil(HueV1Client.parsedAPIError(from: Data("garbage".utf8)))
    }

    func testAnUnrelatedErrorEnvelopeStillParsesAsATypedError() throws {
        let body = Data("""
        [{"error":{"type":7,"address":"/rules/1/name","description":"invalid value"}}]
        """.utf8)
        let parsed = try XCTUnwrap(HueV1Client.parsedAPIError(from: body))
        guard case .apiError(let type, _, _) = parsed else {
            return XCTFail("expected a typed apiError")
        }
        XCTAssertEqual(type, 7)
    }

    // ──────────────────────────────────────────────
    // MARK: - M-05: 8+ light rooms chunk to ≤8 actions per rule
    // ──────────────────────────────────────────────

    func testEightPlusLightRoomUploadsWithChunkedRules() async throws {
        let spy = AnimationSpyV1Client(ip: "192.0.2.1", token: "t")
        let engine = BridgeAnimationEngine()

        let preset = try XCTUnwrap(
            CompositionStore.builtInPresets.first { !$0.reaction.requiresMic },
            "a mic-free built-in preset expected")
        let room = RoomDisplayItem(
            id: "room-9", name: "Big Room", archetype: nil,
            isOn: true, brightness: 50,
            groupedLightID: "gl-9", lightCount: 9,
            bridgeID: "bridge-a", childResourceRefs: [])

        // 9 lights — used to abort: 9 light PUTs + 1 advance = 10 actions > 8.
        let v2IDs = (1...9).map { "uuid-\($0)" }
        let v2Lights = (1...9).map { makeLight(id: "uuid-\($0)", idV1: "/lights/\($0)") }

        let manifest = try await engine.upload(
            preset: preset, room: room,
            lightIDs: v2IDs, v2Lights: v2Lights,
            gamut: .c, v1Client: spy)

        let rules = spy.rules
        XCTAssertFalse(rules.isEmpty)
        XCTAssertEqual(manifest.ruleIDs.count, rules.count)

        // Hard v1 limit: no rule may exceed 8 actions.
        for rule in rules {
            XCTAssertLessThanOrEqual(rule.actions.count, 8,
                "rule '\(rule.name)' has \(rule.actions.count) actions — v1 caps at 8 (M-05)")
        }

        // Per step: every one of the 9 lights receives exactly one PUT, and
        // at most one rule carries the sensor-advance action.
        let step0Rules = rules.filter { rule in
            rule.conditions.contains {
                ($0["value"] as? String) == "0" && ($0["operator"] as? String) == "eq"
            }
        }
        XCTAssertGreaterThanOrEqual(step0Rules.count, 2,
            "9 lights need at least two chunked rules per step")
        let step0LightAddresses = step0Rules.flatMap(\.actions).compactMap { action -> String? in
            guard let address = action["address"] as? String,
                  address.hasPrefix("/lights/") else { return nil }
            return address
        }
        XCTAssertEqual(Set(step0LightAddresses).count, 9,
            "all 9 lights must be covered across step-0 chunk rules")
        XCTAssertEqual(step0LightAddresses.count, 9,
            "no light may be driven twice in one step")
        let step0Advances = step0Rules.flatMap(\.actions).filter { action in
            (action["address"] as? String)?.contains("/sensors/") == true
        }
        XCTAssertEqual(step0Advances.count, 1,
            "exactly one step-0 rule advances the sensor — duplicates would skip steps")
    }
}

// MARK: - Composer 2 packet 8: identity, liveness and honest cleanup
//
// Every test below is a PURE decision — no orchestrator, no shared store, no
// network — so what is proven here is the rule itself, not a wiring accident.
// No Task.sleep, no XCTWaiter, no wait(for:), no elapsed-time assertion.

/// A v1 delete/read spy that can fail, or answer "already gone".
private final class CleanupSpyV1Client: HueV1Client, @unchecked Sendable {
    private let lock = NSLock()
    private var _attempted: [String] = []
    private var _fetchCalls: [String] = []
    var attempted: [String] { lock.lock(); defer { lock.unlock() }; return _attempted }
    /// A cleanup that reads the bridge would break packet 2's guarantee that a
    /// normal replacement never enumerates it, so this must stay empty.
    var fetchCalls: [String] { lock.lock(); defer { lock.unlock() }; return _fetchCalls }

    /// Entries the bridge ANSWERS and refuses → `.partial`.
    var refusing: Set<String> = []
    /// Entries no request reaches at all → `.bridgeUnreadable`.
    var unreachable: Set<String> = []
    /// Entries the bridge says are already gone → still `.removed`.
    var alreadyAbsent: Set<String> = []

    private func perform(_ entry: String) throws {
        lock.lock(); _attempted.append(entry); lock.unlock()
        if alreadyAbsent.contains(entry) {
            try HueV1Client.throwUnlessDeleted(
                Data(#"[{"error":{"type":3,"address":"/x","description":"not available"}}]"#.utf8))
            return
        }
        if unreachable.contains(entry) { throw HueAPIError.httpError(500) }
        if refusing.contains(entry) {
            throw HueV1ClientError.apiError(type: 1, address: "/x", description: "unauthorized user")
        }
    }
    private func note(_ kind: String) { lock.lock(); _fetchCalls.append(kind); lock.unlock() }

    override func deleteSchedule(id: String) async throws { try perform("schedule:\(id)") }
    override func deleteRule(id: String) async throws { try perform("rule:\(id)") }
    override func deleteSensor(id: String) async throws { try perform("sensor:\(id)") }
    override func deleteScene(id: String) async throws { try perform("scene:\(id)") }
    override func deleteResourcelink(id: String) async throws { try perform("resourcelink:\(id)") }

    override func fetchSchedules() async throws -> [String: [String: Any]] { note("schedules"); return [:] }
    override func fetchRules() async throws -> [String: [String: Any]] { note("rules"); return [:] }
    override func fetchSensors() async throws -> [String: [String: Any]] { note("sensors"); return [:] }
    override func fetchScenes() async throws -> [String: [String: Any]] { note("scenes"); return [:] }
    override func fetchResourcelinks() async throws -> [String: [String: Any]] { note("resourcelinks"); return [:] }
}

final class BridgeAnimationPacket8Tests: XCTestCase {

    // ── Fixtures ────────────────────────────────────────────────────────

    private func manifest(
        bridgeID: String? = "bridge-a",
        sensorID: String = "S1",
        ruleIDs: [String] = ["R1", "R2"],
        scheduleID: String = "SC1",
        sceneIDs: [String] = [],
        resourcelinkID: String? = "L1"
    ) -> BridgeAnimationManifest {
        BridgeAnimationManifest(
            id: UUID(), presetID: UUID(), presetName: "Sunset Drift",
            roomID: "room-1", roomName: "Living Room",
            bridgeIP: "192.0.2.1", bridgeID: bridgeID,
            sensorID: sensorID, ruleIDs: ruleIDs, scheduleID: scheduleID,
            sceneIDs: sceneIDs, resourcelinkID: resourcelinkID,
            stepCount: 2, intervalSeconds: 3, cycleDurationSeconds: 6,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func inventory(
        schedules: [String: Bool] = ["SC1": true],
        rules: Set<String> = ["R1", "R2"],
        sensors: Set<String> = ["S1"],
        scenes: Set<String>? = nil,
        resourcelinks: Set<String>? = ["L1"]
    ) -> BridgeAnimationInventory {
        BridgeAnimationInventory(
            schedules: schedules, rules: rules, sensors: sensors,
            scenes: scenes, resourcelinks: resourcelinks)
    }

    // ── Persisted-manifest migration ────────────────────────────────────

    /// The highest-value single test in the packet. A non-optional `bridgeID`,
    /// or a hand-written decoder that forgot `decodeIfPresent`, throws here —
    /// `BridgeAnimationStore.load()` swallows that, and EVERY manifest on disk
    /// is lost. That would turn this packet's fix into a worse version of the
    /// bug it fixes.
    func testALegacyManifestJSONWithoutBridgeIDStillDecodes() throws {
        let legacy = """
        [{
          "id":"11111111-1111-1111-1111-111111111111",
          "presetID":"22222222-2222-2222-2222-222222222222",
          "presetName":"Sunset Drift",
          "roomID":"room-1","roomName":"Living Room",
          "bridgeIP":"192.0.2.1",
          "sensorID":"S1","ruleIDs":["R1","R2"],"scheduleID":"SC1",
          "sceneIDs":[],"resourcelinkID":"L1",
          "stepCount":2,"intervalSeconds":3,"cycleDurationSeconds":6,
          "createdAt":723456789.0
        }]
        """
        let decoded = try BridgeAnimationStore.decodeManifests(Data(legacy.utf8))

        XCTAssertEqual(decoded.count, 1, "a pre-packet-8 file must still decode")
        let only = try XCTUnwrap(decoded.first)
        XCTAssertNil(only.bridgeID, "an absent bridgeID decodes to nil, never a throw")
        XCTAssertEqual(only.presetName, "Sunset Drift")
        XCTAssertEqual(only.roomID, "room-1")
        XCTAssertEqual(only.bridgeIP, "192.0.2.1")
        XCTAssertEqual(only.ruleIDs, ["R1", "R2"])
        XCTAssertEqual(only.scheduleID, "SC1")
        XCTAssertEqual(only.resourcelinkID, "L1")
    }

    /// Re-encoding an untouched legacy manifest must not invent the key, so a
    /// build that merely READS the file cannot change what an older build sees.
    func testAnUntouchedLegacyManifestReEncodesWithoutABridgeIDKey() throws {
        let legacy = manifest(bridgeID: nil)
        let json = try XCTUnwrap(String(data: try JSONEncoder().encode([legacy]), encoding: .utf8))
        XCTAssertFalse(json.contains("bridgeID"), "a nil bridgeID must be omitted, not written as null")

        let upgraded = legacy.adoptingBridgeID("bridge-a")
        let upgradedJSON = try XCTUnwrap(String(data: try JSONEncoder().encode([upgraded]), encoding: .utf8))
        XCTAssertTrue(upgradedJSON.contains("bridge-a"))

        // Round-trips, and the id is stable so teardown can still find it.
        let reread = try BridgeAnimationStore.decodeManifests(try JSONEncoder().encode([upgraded]))
        XCTAssertEqual(reread.first?.bridgeID, "bridge-a")
        XCTAssertEqual(reread.first?.id, legacy.id)
        XCTAssertEqual(reread.first, upgraded, "the whole value is the freshness fingerprint")
    }

    /// `adoptingBridgeID` changes nothing else — the fingerprint must move for
    /// the bridge id and for nothing besides.
    func testAdoptingABridgeIDChangesOnlyTheBridgeID() {
        let legacy = manifest(bridgeID: nil)
        let upgraded = legacy.adoptingBridgeID("bridge-a")
        XCTAssertNotEqual(legacy, upgraded)
        XCTAssertEqual(upgraded.adoptingBridgeID("bridge-a"), upgraded, "idempotent")
        XCTAssertEqual(upgraded.id, legacy.id)
        XCTAssertEqual(upgraded.sensorID, legacy.sensorID)
        XCTAssertEqual(upgraded.ruleIDs, legacy.ruleIDs)
        XCTAssertEqual(upgraded.createdAt, legacy.createdAt)
    }

    // ── Liveness truth table ────────────────────────────────────────────

    func testAFullyPresentEnabledAnimationIsLive() {
        XCTAssertEqual(BridgeAnimationEngine.liveness(of: manifest(), in: inventory()), .live)
    }

    /// A schedule that exists but is disabled drives nothing. Treating presence
    /// alone as "running" is how a phantom Now Playing row appears.
    func testADisabledScheduleIsNotRunning() {
        let result = BridgeAnimationEngine.liveness(
            of: manifest(), in: inventory(schedules: ["SC1": false]))
        guard case .notRunning(let residue) = result else { return XCTFail("expected notRunning") }
        XCTAssertEqual(residue.scheduleID, "SC1", "the schedule still exists, so cleanup must remove it")
        XCTAssertEqual(residue.ruleIDs, ["R1", "R2"])
        XCTAssertEqual(residue.sensorID, "S1")
    }

    func testAMissingScheduleIsNotRunning() {
        let result = BridgeAnimationEngine.liveness(of: manifest(), in: inventory(schedules: [:]))
        guard case .notRunning(let residue) = result else { return XCTFail("expected notRunning") }
        XCTAssertNil(residue.scheduleID, "a schedule the bridge does not have is not in the delete set")
    }

    func testAMissingSensorIsNotRunning() {
        let result = BridgeAnimationEngine.liveness(of: manifest(), in: inventory(sensors: []))
        guard case .notRunning(let residue) = result else { return XCTFail("expected notRunning") }
        XCTAssertNil(residue.sensorID)
    }

    /// One broken link breaks the chain: a partially-present rule set cannot
    /// produce the animation the manifest describes.
    func testASingleMissingRuleIsNotRunning() {
        let result = BridgeAnimationEngine.liveness(of: manifest(), in: inventory(rules: ["R1"]))
        guard case .notRunning(let residue) = result else { return XCTFail("expected notRunning") }
        XCTAssertEqual(residue.ruleIDs, ["R1"], "only the rule that still exists may be deleted")
    }

    /// The resourcelink is a grouping convenience whose creation is allowed to
    /// fail during upload — requiring it would declare healthy looks dead.
    func testAMissingResourcelinkIsStillLive() {
        XCTAssertEqual(
            BridgeAnimationEngine.liveness(of: manifest(), in: inventory(resourcelinks: [])),
            .live)
    }

    func testAllScenesPresentIsLiveAndOneMissingSceneIsNot() {
        let withScenes = manifest(sceneIDs: ["SC-A", "SC-B"])
        XCTAssertEqual(
            BridgeAnimationEngine.liveness(of: withScenes, in: inventory(scenes: ["SC-A", "SC-B"])),
            .live)
        let partial = BridgeAnimationEngine.liveness(
            of: withScenes, in: inventory(scenes: ["SC-A"]))
        guard case .notRunning(let residue) = partial else { return XCTFail("expected notRunning") }
        XCTAssertEqual(residue.sceneIDs, ["SC-A"])
    }

    /// Fail closed. An unread category is not evidence, and evidence is what
    /// authorises a delete.
    func testAnUnreadSceneCategoryIsIndeterminateNotAbsent() {
        let withScenes = manifest(sceneIDs: ["SC-A"])
        guard case .indeterminate = BridgeAnimationEngine.liveness(
            of: withScenes, in: inventory(scenes: nil)) else {
            return XCTFail("an unread category must never resolve to a verdict")
        }
    }

    func testAnUnreadResourcelinkCategoryIsIndeterminate() {
        guard case .indeterminate = BridgeAnimationEngine.liveness(
            of: manifest(), in: inventory(resourcelinks: nil)) else {
            return XCTFail("an unread category must never resolve to a verdict")
        }
    }

    /// The one state that authorises dropping the manifest outright.
    func testAnEntirelyAbsentAnimationProvesTotalAbsence() {
        let result = BridgeAnimationEngine.liveness(
            of: manifest(),
            in: inventory(schedules: [:], rules: [], sensors: [], resourcelinks: []))
        guard case .notRunning(let residue) = result else { return XCTFail("expected notRunning") }
        XCTAssertTrue(residue.isEmpty, "nothing remains, so the evidence may be retired")
    }

    /// Foreign resources are never in the residue. `CG_` is a shared prefix,
    /// not an ownership claim — packet 2's rule, restated at launch.
    func testResidueNeverIncludesResourcesThisManifestDoesNotName() {
        let residue = BridgeAnimationEngine.residue(
            of: manifest(),
            in: inventory(schedules: ["SC1": true, "SC9": true],
                          rules: ["R1", "R2", "R9"],
                          sensors: ["S1", "S9"],
                          resourcelinks: ["L1", "L9"]))
        XCTAssertEqual(residue.scheduleID, "SC1")
        XCTAssertEqual(residue.ruleIDs, ["R1", "R2"])
        XCTAssertEqual(residue.sensorID, "S1")
        XCTAssertEqual(residue.resourcelinkID, "L1")
    }

    // ── The `[:]`-swallow regression guards ─────────────────────────────

    /// Before packet 8 both of these produced `[:]`, so "the bridge refused me"
    /// and "this bridge has no rules" were the same answer — and reconciliation
    /// would have read the refusal as proof of absence and deleted.
    func testAnEmptyCollectionDecodesButAnErrorEnvelopeThrows() throws {
        let empty = try HueV1Client.decodeResourceMap(Data("{}".utf8), path: "/rules")
        XCTAssertTrue(empty.isEmpty, "a genuinely empty bridge still decodes normally")

        XCTAssertThrowsError(
            try HueV1Client.decodeResourceMap(
                Data(#"[{"error":{"type":1,"address":"/rules","description":"unauthorized user"}}]"#.utf8),
                path: "/rules"),
            "an HTTP-200 error envelope must never look like an empty inventory")
    }

    func testAlreadyAbsentCountsAsDeletedButAnyOtherRefusalThrows() throws {
        XCTAssertNoThrow(try HueV1Client.throwUnlessDeleted(
            Data(#"[{"success":{"/rules/1":"deleted"}}]"#.utf8)))
        XCTAssertNoThrow(
            try HueV1Client.throwUnlessDeleted(
                Data(#"[{"error":{"type":3,"address":"/rules/1","description":"not available"}}]"#.utf8)),
            "type 3 means the delete's goal is already met")
        XCTAssertThrowsError(
            try HueV1Client.throwUnlessDeleted(
                Data(#"[{"error":{"type":1,"address":"/rules/1","description":"unauthorized user"}}]"#.utf8)),
            "any other refusal is a failure, not a silent success")
    }

    // ── Typed cleanup result ────────────────────────────────────────────

    func testACleanTeardownReportsRemovedAndReadsNothing() async {
        let spy = CleanupSpyV1Client(ip: "192.0.2.1", token: "t")
        let result = await BridgeAnimationEngine().stop(manifest: manifest(), v1Client: spy)

        XCTAssertEqual(result, .removed)
        XCTAssertEqual(spy.attempted,
                       ["schedule:SC1", "rule:R1", "rule:R2", "sensor:S1", "resourcelink:L1"],
                       "dependency-safe order is unchanged from before packet 8")
        XCTAssertTrue(spy.fetchCalls.isEmpty,
                      "cleanup must never enumerate the bridge (packet 2)")
    }

    /// A user who deleted the resources by hand must not leave the manifest
    /// permanently unprunable.
    func testAnAlreadyAbsentResourceStillReportsRemoved() async {
        let spy = CleanupSpyV1Client(ip: "192.0.2.1", token: "t")
        spy.alreadyAbsent = ["rule:R2", "sensor:S1"]
        let result = await BridgeAnimationEngine().stop(manifest: manifest(), v1Client: spy)
        XCTAssertEqual(result, .removed)
    }

    func testARefusedDeleteReportsPartialNamingOnlyWhatMayRemain() async {
        let spy = CleanupSpyV1Client(ip: "192.0.2.1", token: "t")
        spy.refusing = ["rule:R2"]
        let result = await BridgeAnimationEngine().stop(manifest: manifest(), v1Client: spy)

        guard case .partial(let remaining) = result else { return XCTFail("expected partial") }
        XCTAssertEqual(remaining.ruleIDs, ["R2"])
        XCTAssertNil(remaining.scheduleID)
        XCTAssertNil(remaining.sensorID)
        XCTAssertEqual(spy.attempted.count, 5,
                       "every step is still attempted — aborting early leaves rules firing")
    }

    func testAnUnreachableBridgeReportsBridgeUnreadableNotPartial() async {
        let spy = CleanupSpyV1Client(ip: "192.0.2.1", token: "t")
        spy.unreachable = ["schedule:SC1", "rule:R1", "rule:R2", "sensor:S1", "resourcelink:L1"]
        let result = await BridgeAnimationEngine().stop(manifest: manifest(), v1Client: spy)

        guard case .bridgeUnreadable(let remaining) = result else {
            return XCTFail("expected bridgeUnreadable")
        }
        XCTAssertEqual(remaining.scheduleID, "SC1")
        XCTAssertEqual(remaining.ruleIDs, ["R1", "R2"])
    }

    /// One reachable answer proves the bridge is talking to us, so a mixed
    /// outcome is a refusal to act on — not a connectivity problem to wait out.
    func testAMixedOutcomeReportsPartialRatherThanUnreadable() async {
        let spy = CleanupSpyV1Client(ip: "192.0.2.1", token: "t")
        spy.unreachable = ["schedule:SC1"]
        spy.refusing = ["rule:R1"]
        let result = await BridgeAnimationEngine().stop(manifest: manifest(), v1Client: spy)
        guard case .partial = result else { return XCTFail("expected partial") }
    }

    /// Reconciliation passes a residue so it deletes only what the bridge still
    /// holds — never the manifest's full list, which would aim deletes at ids
    /// another controller may since have reused.
    func testANarrowedResidueDeletesExactlyThatSubset() async {
        let spy = CleanupSpyV1Client(ip: "192.0.2.1", token: "t")
        let residue = BridgeAnimationResidue(sensorID: "S1")
        let result = await BridgeAnimationEngine().stop(
            manifest: manifest(), v1Client: spy, only: residue)

        XCTAssertEqual(result, .removed)
        XCTAssertEqual(spy.attempted, ["sensor:S1"])
        XCTAssertTrue(spy.fetchCalls.isEmpty)
    }
}
