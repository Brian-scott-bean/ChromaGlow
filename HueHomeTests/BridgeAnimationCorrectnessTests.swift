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

    override func fetchResourceCapacity() async throws -> BridgeResourceCapacity {
        BridgeResourceCapacity(rulesUsed: 0, rulesTotal: 250,
                               sensorsUsed: 0, sensorsTotal: 250,
                               schedulesUsed: 0, schedulesTotal: 100,
                               scenesUsed: 0, scenesTotal: 200)
    }

    override func createCLIPSensor(name: String, initialStatus: Int) async throws -> String { "51" }

    override func createRule(
        name: String,
        conditions: [[String: Any]],
        actions: [[String: Any]]
    ) async throws -> String {
        lock.lock(); defer { lock.unlock() }
        _rules.append(RuleRecord(name: name, conditions: conditions, actions: actions))
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

    func testSceneStarvedBridgeStillFitsOneAnimation() {
        // The uploader drives light states directly (sceneIDs is always []),
        // so a bridge with zero free scene slots must still accept an animation.
        let cap = BridgeResourceCapacity(rulesUsed: 0, rulesTotal: 250,
                                         sensorsUsed: 0, sensorsTotal: 250,
                                         schedulesUsed: 0, schedulesTotal: 100,
                                         scenesUsed: 200, scenesTotal: 200)
        XCTAssertTrue(cap.canFitOneAnimation,
                      "free scenes are not consumed by the rules-chain path (L-04)")
    }

    func testRuleStarvedBridgeReportsFull() {
        let cap = BridgeResourceCapacity(rulesUsed: 245, rulesTotal: 250,
                                         sensorsUsed: 0, sensorsTotal: 250,
                                         schedulesUsed: 0, schedulesTotal: 100,
                                         scenesUsed: 0, scenesTotal: 200)
        XCTAssertFalse(cap.canFitOneAnimation,
                       "rules remain the real constraint — 12 free required")
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
