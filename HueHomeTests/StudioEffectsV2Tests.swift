// StudioEffectsV2Tests.swift
// HueHome Pro — Unit Tests
//
// R4 Effects port: Studio Deck 0 bridge-native activation performs the
// per-light v1 blanket THEN a gate-paced effects_v2 parameter upgrade on
// capable lights only; the live speed slider re-parameterizes the running
// effect per-light; coverage is keyed by the strategy's effect name and
// guarded in demo mode.

import XCTest
@testable import HueHome

// MARK: - Spy

/// Records grouped/per-light v1 traffic at the class-method seam and
/// effects_v2 PUTs at the raw `put(path:body:)` seam (setLightEffectV2 lives
/// in an extension, so the underlying transport method is the override point).
private final class StudioSpyClient: BridgeAPIClient, @unchecked Sendable {
    private let lock = NSLock()

    private var _groupedStateIDs: [String] = []
    var groupedStateIDs: [String] { lock.lock(); defer { lock.unlock() }; return _groupedStateIDs }

    private var _v1Effects: [String] = []   // "lightID:effect"
    var v1Effects: [String] { lock.lock(); defer { lock.unlock() }; return _v1Effects }

    private var _v2Puts: [(lightID: String, effect: String, speed: Double?, hasColor: Bool)] = []
    var v2Puts: [(lightID: String, effect: String, speed: Double?, hasColor: Bool)] {
        lock.lock(); defer { lock.unlock() }; return _v2Puts
    }

    var lightsFixture: [HueLight] = []

    override func fetchLights() async throws -> [HueLight] { lightsFixture }

    override func fetchLightIDsForGroup(groupedLightID: String) async throws -> [String] {
        lightsFixture.map(\.id)
    }

    override func setGroupedLightState(id: String, on: Bool, brightness: Double) async throws {
        lock.lock(); defer { lock.unlock() }
        _groupedStateIDs.append(id)
    }

    override func setLightNativeEffect(id: String, effect: String) async throws {
        lock.lock(); defer { lock.unlock() }
        _v1Effects.append("\(id):\(effect)")
    }

    override func put(path: String, body: [String: Any], ip: String, token: String) async throws -> Data {
        if let v2 = body["effects_v2"] as? [String: Any],
           let action = v2["action"] as? [String: Any],
           let effect = action["effect"] as? String,
           let lightID = path.components(separatedBy: "/").last {
            let params = action["parameters"] as? [String: Any]
            lock.lock()
            _v2Puts.append((
                lightID: lightID,
                effect: effect,
                speed: params?["speed"] as? Double,
                hasColor: params?["color"] != nil
            ))
            lock.unlock()
        }
        return Data(#"{"errors":[],"data":[]}"#.utf8)
    }
}

// MARK: - Tests

@MainActor
final class StudioEffectsV2Tests: XCTestCase {

    private var spy: StudioSpyClient!
    private var orchestrator: UnifiedOrchestrator!
    private var vm: StudioViewModel!

    override func setUp() async throws {
        try await super.setUp()
        spy = StudioSpyClient(bridgeID: "bridge-a", bridgeName: "Bridge A",
                              ip: "192.0.2.1", token: "spy-token")
        orchestrator = UnifiedOrchestrator()
        orchestrator.injectForTesting(clients: ["bridge-a": spy])
        vm = StudioViewModel()
        vm.configure(orchestrator: orchestrator)
        vm.selectedRoom = Self.zoneRoom(lightRIDs: ["L1", "L2", "L3"])
    }

    // Zone-style refs (rtype "light") resolve with zero inventory calls.
    private static func zoneRoom(lightRIDs: [String]) -> RoomDisplayItem {
        RoomDisplayItem(
            kind: .zone,
            id: "room-a",
            name: "Test Zone",
            archetype: nil,
            isOn: true,
            brightness: 70,
            groupedLightID: "gl-a",
            lightCount: lightRIDs.count,
            bridgeID: "bridge-a",
            childResourceRefs: lightRIDs.map { (rid: $0, rtype: "light") }
        )
    }

    private func light(_ id: String, v2Effects: [String], v1Effects: [String] = []) throws -> HueLight {
        let json = """
        {
          "id": "\(id)",
          "metadata": { "name": "Light \(id)", "archetype": "hue_bulb" },
          "on": { "on": true },
          "dimming": { "brightness": 80 },
          "effects": { "effect_values": \(Self.jsonArray(v1Effects)) },
          "effects_v2": { "action": { "effect_values": \(Self.jsonArray(v2Effects)) } }
        }
        """
        return try JSONDecoder().decode(HueLight.self, from: Data(json.utf8))
    }

    private static func jsonArray(_ items: [String]) -> String {
        "[" + items.map { "\"\($0)\"" }.joined(separator: ",") + "]"
    }

    private func cosmosCard() throws -> StudioCard {
        try XCTUnwrap(vm.effectCards.first(where: { $0.id == "cosmos" }))
    }

    // ── 1. v1 blanket then v2 upgrade on capable lights only ──

    func testBridgeNativeApplySendsV1BlanketThenV2UpgradeToCapableLightsOnly() async throws {
        spy.lightsFixture = [
            try light("L1", v2Effects: ["cosmos", "candle"]),
            try light("L2", v2Effects: ["cosmos"]),
            try light("L3", v2Effects: [], v1Effects: ["candle"]),
        ]

        await vm.apply(try cosmosCard(), roomOverride: nil, preferEntertainmentOverride: nil)

        XCTAssertEqual(spy.groupedStateIDs, ["gl-a"])
        XCTAssertEqual(Set(spy.v1Effects), ["L1:cosmos", "L2:cosmos", "L3:cosmos"],
                       "v1 blanket must hit every light")
        let v2 = spy.v2Puts
        XCTAssertEqual(Set(v2.map(\.lightID)), ["L1", "L2"], "v2 upgrade targets capable lights only")
        for put in v2 {
            XCTAssertEqual(put.effect, "cosmos")
            XCTAssertEqual(put.speed ?? -1, 0.5, accuracy: 0.001, "default 50 → API 0.5")
            XCTAssertFalse(put.hasColor, "no color sent unless the user picked a tint")
        }
        XCTAssertEqual(vm.runningEffects["room-a"]?.v2CapableLightIDs.sorted(), ["L1", "L2"])
        let cov = try XCTUnwrap(vm.effectCoverage["cosmos"])
        XCTAssertEqual(cov.label, "2 of 3")
        XCTAssertFalse(cov.isFull)
    }

    // ── 2. no light can run the effect → say so, don't claim it started ──

    /// These bulbs advertise `candle` and nothing else, so nobody in the room
    /// can run Cosmos. The bridge answers each PUT with a 400 and the sender
    /// discards it, so this used to register a running effect and report a
    /// green success over a room that had not changed. It now reports the
    /// truth and registers nothing.
    func testUnsupportedEffectIsReportedRatherThanClaimedAsRunning() async throws {
        spy.lightsFixture = [
            try light("L1", v2Effects: [], v1Effects: ["candle"]),
            try light("L2", v2Effects: ["candle"]),
        ]
        vm.selectedRoom = Self.zoneRoom(lightRIDs: ["L1", "L2"])

        await vm.apply(try cosmosCard(), roomOverride: nil, preferEntertainmentOverride: nil)

        XCTAssertEqual(spy.v1Effects.count, 2, "the blanket is still attempted")
        XCTAssertTrue(spy.v2Puts.isEmpty, "no v2 traffic without capable lights")
        XCTAssertNil(vm.runningEffects["room-a"], "nothing is running — do not register an effect")
        XCTAssertEqual(vm.effectCoverage["cosmos"]?.isEmpty, true)
        XCTAssertTrue(vm.statusMessage.contains("No lights"),
                      "expected an explanation, got: \(vm.statusMessage)")
    }

    // ── 3. live speed slider lands per-light v2 while running ──

    func testSpeedSliderLandsPerLightEffectsV2WhileRunning() async throws {
        spy.lightsFixture = [
            try light("L1", v2Effects: ["cosmos"]),
            try light("L2", v2Effects: ["cosmos"]),
            try light("L3", v2Effects: []),
        ]
        await vm.apply(try cosmosCard(), roomOverride: nil, preferEntertainmentOverride: nil)
        let baseline = spy.v2Puts.count

        vm.sendParam(cardID: "cosmos", paramID: "speed", value: 80)

        // 150 ms debounce + mailbox + gate pacing — poll up to 2 s.
        var newPuts: [(lightID: String, effect: String, speed: Double?, hasColor: Bool)] = []
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(50))
            newPuts = Array(spy.v2Puts.dropFirst(baseline))
            if newPuts.count >= 2 { break }
        }
        XCTAssertEqual(Set(newPuts.map(\.lightID)), ["L1", "L2"],
                       "live speed goes only to v2-capable lights")
        for put in newPuts {
            XCTAssertEqual(put.speed ?? -1, 0.8, accuracy: 0.001, "slider 80 → API 0.8")
        }
    }

    // ── 4. coverage keyed by strategy effect name + demo guard ──

    func testRefreshCoverageKeysByStrategyEffectNameAndGuardsDemoMode() async throws {
        spy.lightsFixture = [
            try light("L1", v2Effects: ["cosmos", "opal"], v1Effects: ["candle"]),
            try light("L2", v2Effects: [], v1Effects: ["candle"]),
        ]
        vm.selectedRoom = Self.zoneRoom(lightRIDs: ["L1", "L2"])

        await vm.refreshCoverage()

        // Only .bridgeNative cards appear; keys are card ids resolved from
        // the strategy's effect-name string. Resolution is v2-first: L1
        // exposes a v2 list without candle, so its v1 candle doesn't count.
        XCTAssertEqual(vm.effectCoverage["candle"]?.label, "1 of 2")
        XCTAssertEqual(vm.effectCoverage["cosmos"]?.label, "1 of 2")
        XCTAssertNil(vm.effectCoverage["party"], "app-driven cards have no coverage")

        orchestrator.isDemoMode = true
        await vm.refreshCoverage()
        XCTAssertTrue(vm.effectCoverage.isEmpty, "demo mode clears coverage")
    }
}
