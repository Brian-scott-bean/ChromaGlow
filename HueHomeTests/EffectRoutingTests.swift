// EffectRoutingTests.swift
// ChromaGlow — firmware effects (Studio Deck 0)
//
// A light that cannot run an effect answers the PUT with a 400, and the sender
// discards it. That made "no light in this room supports Cosmos" and "Cosmos is
// now running" look identical from the outside: a green status message and a
// dark room.
//
// `EffectCapabilityResolver.routing` decides from the lights' own capability
// lists, before anything is sent. These tests pin the three answers it can give.

import XCTest
@testable import HueHome

final class EffectRoutingTests: XCTestCase {

    private typealias Resolver = EffectCapabilityResolver

    private func light(_ id: String, v2Effects: [String] = [], v1Effects: [String] = []) throws -> HueLight {
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

    // MARK: - The case that used to lie

    /// Bulbs that advertise effects, none of them this one. That is a real
    /// answer from the bridge, and it deserves a real answer to the user.
    func testARoomThatCannotRunTheEffectIsReportedUnsupported() throws {
        let whiteOnly = [
            try light("1", v1Effects: ["candle"]),
            try light("2", v1Effects: ["candle", "fire"]),
        ]

        let routing = Resolver.routing(for: "cosmos", lights: whiteOnly, fallbackIDs: ["1", "2"])

        XCTAssertEqual(routing, .unsupported(effect: "cosmos"))
    }

    /// A light that lists *other* effects still cannot run this one.
    func testAnUnrelatedEffectListDoesNotCountAsSupport() throws {
        let lights = [try light("1", v2Effects: ["candle", "fire"])]

        XCTAssertEqual(Resolver.routing(for: "cosmos", lights: lights, fallbackIDs: ["1"]),
                       .unsupported(effect: "cosmos"))
    }

    // MARK: - Targeting

    /// Only capable lights are addressed. Blasting the rest earns a 400 each and
    /// spends the command gate on nothing.
    func testOnlyCapableLightsAreTargeted() throws {
        let lights = [
            try light("1", v2Effects: ["cosmos"]),
            try light("2"),
            try light("3", v2Effects: ["cosmos"]),
        ]

        guard case .run(let ids, let coverage) =
            Resolver.routing(for: "cosmos", lights: lights, fallbackIDs: ["1", "2", "3"])
        else { return XCTFail("expected .run") }

        XCTAssertEqual(ids, ["1", "3"])
        XCTAssertEqual(coverage.total, 3)
        XCTAssertEqual(coverage.count, 2)
        XCTAssertFalse(coverage.isFull)
        XCTAssertEqual(coverage.label, "2 of 3")
    }

    func testFullCoverageIsReportedAsFull() throws {
        let lights = [try light("1", v2Effects: ["candle"]), try light("2", v2Effects: ["candle"])]

        guard case .run(let ids, let coverage) =
            Resolver.routing(for: "candle", lights: lights, fallbackIDs: ["1", "2"])
        else { return XCTFail("expected .run") }

        XCTAssertEqual(ids, ["1", "2"])
        XCTAssertTrue(coverage.isFull)
    }

    /// Older bulbs advertise effects only on the v1 `effects` list. They can
    /// still run the effect — parameterless — and must not be excluded.
    func testV1OnlyLightsAreStillCapable() throws {
        let lights = [
            try light("1", v2Effects: ["candle"]),
            try light("2", v1Effects: ["candle"]),
        ]

        guard case .run(let ids, _) =
            Resolver.routing(for: "candle", lights: lights, fallbackIDs: ["1", "2"])
        else { return XCTFail("expected .run") }

        XCTAssertEqual(ids, ["1", "2"], "a v1-only bulb was dropped from a v1-capable effect")
    }

    /// v2 wins when present: `effectValues` reads the v2 list and ignores v1.
    /// A bulb whose v2 list omits the effect cannot run it, whatever v1 claims.
    func testV2ListShadowsTheV1List() throws {
        let lights = [try light("1", v2Effects: ["candle"], v1Effects: ["cosmos"])]

        XCTAssertEqual(Resolver.routing(for: "cosmos", lights: lights, fallbackIDs: ["1"]),
                       .unsupported(effect: "cosmos"))
    }

    // MARK: - Unknown capability

    /// A failed light fetch must not block an effect that would have worked.
    /// Send to everything and let the bridge arbitrate.
    func testUnreadableRoomFallsBackToSendingEverything() {
        let routing = Resolver.routing(for: "cosmos", lights: [], fallbackIDs: ["1", "2"])
        XCTAssertEqual(routing, .runUnverified(lightIDs: ["1", "2"]))
    }

    /// An empty room with no fallback is still "unverified", not "unsupported" —
    /// we know nothing about lights we never saw.
    func testEmptyRoomIsUnverifiedNotUnsupported() {
        XCTAssertEqual(Resolver.routing(for: "cosmos", lights: [], fallbackIDs: []),
                       .runUnverified(lightIDs: []))
    }

    /// If not one light reports *any* firmware effect, we are reading a
    /// capability list that isn't there — a decode gap or a firmware that omits
    /// the field. Refusing every effect on that evidence would turn one missing
    /// JSON key into "Deck 0 does nothing".
    func testARoomReportingNoCapabilitiesAtAllIsUnverifiedNotUnsupported() throws {
        let silent = [try light("1"), try light("2")]

        XCTAssertEqual(Resolver.routing(for: "cosmos", lights: silent, fallbackIDs: ["1", "2"]),
                       .runUnverified(lightIDs: ["1", "2"]))
    }

    /// But one light that *does* report capabilities makes the room's silence
    /// meaningful: the others genuinely cannot run it.
    func testOneReportingLightMakesTheRestsSilenceMeaningful() throws {
        let lights = [try light("1", v2Effects: ["candle"]), try light("2")]

        XCTAssertEqual(Resolver.routing(for: "cosmos", lights: lights, fallbackIDs: ["1", "2"]),
                       .unsupported(effect: "cosmos"))
    }

    // MARK: - Every shipped bridge-native effect

    /// Each effect in the library must route cleanly for a bulb that advertises
    /// it — a typo in an effect name would otherwise show up as a dark room.
    func testEveryBridgeNativeEffectRoutesForACapableBulb() throws {
        let nativeNames: [String] = EffectLibrary.all.compactMap { effect in
            if case .bridgeNative(let name) = effect.strategy { return name }
            return nil
        }
        XCTAssertGreaterThanOrEqual(nativeNames.count, 10, "expected the effects_v2 set")

        for name in nativeNames {
            let bulb = [try light("1", v2Effects: [name])]
            guard case .run(let ids, let coverage) =
                Resolver.routing(for: name, lights: bulb, fallbackIDs: ["1"])
            else { return XCTFail("\(name) did not route to .run") }
            XCTAssertEqual(ids, ["1"], name)
            XCTAssertTrue(coverage.isFull, name)
        }
    }
}
