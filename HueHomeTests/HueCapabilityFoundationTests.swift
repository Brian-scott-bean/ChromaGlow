// HueCapabilityFoundationTests.swift
// HueHome Pro — Unit Tests
//
// Round 3 Phase A: golden-JSON tests for the pure request-body builders
// (effects_v2, timed_effects, signaling, gradient), HueLight capability
// decode, and EffectCapabilityResolver coverage math. No network.

import XCTest
@testable import HueHome

final class HueCapabilityFoundationTests: XCTestCase {

    // MARK: - EffectsV2Body golden JSON

    func testEffectsV2BodyFullParameters() {
        let body = EffectsV2Body(effect: "cosmos", speed: 0.7,
                                 colorXY: CGPoint(x: 0.2, y: 0.4), mirek: 300)
        let expected: [String: Any] = [
            "effects_v2": [
                "action": [
                    "effect": "cosmos",
                    "parameters": [
                        "speed": 0.7,
                        "color": ["xy": ["x": 0.2, "y": 0.4]],
                        "color_temperature": ["mirek": 300],
                    ],
                ],
            ],
        ]
        XCTAssertEqual(body.dictionary() as NSDictionary, expected as NSDictionary)
    }

    func testEffectsV2BodyBareEffectOmitsParameters() {
        let body = EffectsV2Body(effect: "no_effect")
        let expected: [String: Any] = ["effects_v2": ["action": ["effect": "no_effect"]]]
        XCTAssertEqual(body.dictionary() as NSDictionary, expected as NSDictionary)
    }

    func testEffectsV2BodyClampsSpeedAndMirek() {
        let dict = EffectsV2Body(effect: "candle", speed: 1.7, mirek: 9000).dictionary()
        let action = ((dict["effects_v2"] as? [String: Any])?["action"] as? [String: Any])
        let params = action?["parameters"] as? [String: Any]
        XCTAssertEqual(params?["speed"] as? Double, 1.0)
        XCTAssertEqual((params?["color_temperature"] as? [String: Any])?["mirek"] as? Int, 500)
    }

    // MARK: - TimedEffectsBody golden JSON

    func testTimedEffectsBodySunriseWithDuration() {
        let body = TimedEffectsBody(effect: "sunrise", durationMs: 900_000)
        let expected: [String: Any] = [
            "timed_effects": ["effect": "sunrise", "duration": 900_000],
        ]
        XCTAssertEqual(body.dictionary() as NSDictionary, expected as NSDictionary)
    }

    func testTimedEffectsBodyClampsToSixHours() {
        let dict = TimedEffectsBody(effect: "sunset", durationMs: 99_999_999).dictionary()
        let timed = dict["timed_effects"] as? [String: Any]
        XCTAssertEqual(timed?["duration"] as? Int, TimedEffectsBody.maxDurationMs)
    }

    // MARK: - SignalingBody golden JSON

    func testSignalingIdentify() {
        let expected: [String: Any] = [
            "signaling": ["signal": "on_off", "duration": 3000],
        ]
        XCTAssertEqual(SignalingBody.identify().dictionary() as NSDictionary,
                       expected as NSDictionary)
    }

    func testSignalingPunchBurstTwoColors() {
        let body = SignalingBody.punchBurst(a: CGPoint(x: 0.64, y: 0.33),
                                            b: CGPoint(x: 0.15, y: 0.06))
        let expected: [String: Any] = [
            "signaling": [
                "signal": "alternating",
                "duration": 2000,
                "colors": [
                    ["color": ["xy": ["x": 0.64, "y": 0.33]]],
                    ["color": ["xy": ["x": 0.15, "y": 0.06]]],
                ],
            ],
        ]
        XCTAssertEqual(body.dictionary() as NSDictionary, expected as NSDictionary)
    }

    func testSignalingDropsExtraColorsAndClampsDuration() {
        let body = SignalingBody(signal: .alternating, durationMs: 99_000_000,
                                 colorsXY: [CGPoint(x: 0.1, y: 0.1),
                                            CGPoint(x: 0.2, y: 0.2),
                                            CGPoint(x: 0.3, y: 0.3)])
        let signaling = body.dictionary()["signaling"] as? [String: Any]
        XCTAssertEqual((signaling?["colors"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(signaling?["duration"] as? Int, SignalingBody.maxDurationMs)
    }

    // MARK: - GradientBody golden JSON

    func testGradientBodyThreePoints() {
        let body = GradientBody(pointsXY: [CGPoint(x: 0.64, y: 0.33),
                                           CGPoint(x: 0.17, y: 0.70),
                                           CGPoint(x: 0.15, y: 0.06)])
        let expected: [String: Any] = [
            "gradient": [
                "points": [
                    ["color": ["xy": ["x": 0.64, "y": 0.33]]],
                    ["color": ["xy": ["x": 0.17, "y": 0.70]]],
                    ["color": ["xy": ["x": 0.15, "y": 0.06]]],
                ],
            ],
        ]
        XCTAssertEqual(body.dictionary() as NSDictionary, expected as NSDictionary)
    }

    func testGradientBodyPadsSinglePointToTwo() {
        let dict = GradientBody(pointsXY: [CGPoint(x: 0.3, y: 0.3)]).dictionary()
        let points = (dict["gradient"] as? [String: Any])?["points"] as? [[String: Any]]
        XCTAssertEqual(points?.count, 2)   // bridge rejects <2 points
    }

    func testGradientBodyCapsAtFivePoints() {
        let seven = (0..<7).map { CGPoint(x: Double($0) / 10, y: 0.3) }
        let dict = GradientBody(pointsXY: seven).dictionary()
        let points = (dict["gradient"] as? [String: Any])?["points"] as? [[String: Any]]
        XCTAssertEqual(points?.count, GradientBody.maxPoints)
    }

    // MARK: - HueLight capability decode

    func testHueLightDecodesCapabilityBlocks() throws {
        let json = """
        {
          "id": "L1",
          "metadata": { "name": "Strip", "archetype": "hue_lightstrip" },
          "on": { "on": true },
          "dimming": { "brightness": 80 },
          "effects": { "effect_values": ["candle", "fire"], "status": "no_effect" },
          "effects_v2": {
            "action": { "effect_values": ["cosmos", "candle", "underwater"] },
            "status": { "effect": "no_effect" }
          },
          "timed_effects": { "effect_values": ["sunrise", "sunset"], "status": "no_effect" },
          "gradient": { "points_capable": 5, "mode": "interpolated_palette",
                        "mode_values": ["interpolated_palette"], "pixel_count": 40 }
        }
        """
        let light = try JSONDecoder().decode(HueLight.self, from: Data(json.utf8))
        XCTAssertEqual(light.effects_v2?.action?.effect_values,
                       ["cosmos", "candle", "underwater"])
        XCTAssertEqual(light.timed_effects?.effect_values, ["sunrise", "sunset"])
        XCTAssertEqual(light.gradient?.points_capable, 5)
        XCTAssertEqual(light.gradient?.pixel_count, 40)
        XCTAssertEqual(light.effects?.effect_values, ["candle", "fire"])
    }

    func testHueLightDecodesWithoutCapabilityBlocks() throws {
        // Pre-Round-3 shaped payload (and white-only bulbs) must keep decoding.
        let json = """
        { "id": "L2", "metadata": { "name": "Bulb" }, "on": { "on": false } }
        """
        let light = try JSONDecoder().decode(HueLight.self, from: Data(json.utf8))
        XCTAssertNil(light.effects_v2)
        XCTAssertNil(light.timed_effects)
        XCTAssertNil(light.gradient)
    }

    // MARK: - EffectCapabilityResolver

    private func light(id: String,
                       v2: [String]? = nil,
                       v1: [String]? = nil,
                       timed: [String]? = nil,
                       gradientPoints: Int? = nil) -> HueLight {
        HueLight(
            id: id,
            metadata: LightMetadata(name: id, archetype: nil),
            on: OnState(on: true),
            dimming: nil, color: nil, color_temperature: nil, owner: nil,
            effects: v1.map { LightEffectsV1(effect_values: $0, status: nil) },
            effects_v2: v2.map {
                LightEffectsV2(action: .init(effect_values: $0), status: nil)
            },
            timed_effects: timed.map { LightTimedEffects(effect_values: $0, status: nil) },
            gradient: gradientPoints.map {
                LightGradient(points_capable: $0, mode: nil, mode_values: nil, pixel_count: nil)
            }
        )
    }

    func testCoveragePrefersV2AndFallsBackToV1() {
        let lights = [
            light(id: "A", v2: ["cosmos", "candle"]),
            light(id: "B", v1: ["candle"]),          // v1-only light
            light(id: "C"),                            // no effects at all
        ]
        let cosmos = EffectCapabilityResolver.coverage(for: "cosmos", lights: lights)
        XCTAssertEqual(cosmos.capableIDs, ["A"])
        XCTAssertEqual(cosmos.total, 3)
        XCTAssertFalse(cosmos.isFull)

        let candle = EffectCapabilityResolver.coverage(for: "candle", lights: lights)
        XCTAssertEqual(candle.capableIDs, ["A", "B"])
        XCTAssertEqual(candle.label, "2 of 3")
    }

    func testNativeTimedEffectRequiresFullCoverage() {
        let full = [light(id: "A", timed: ["sunrise"]), light(id: "B", timed: ["sunrise"])]
        XCTAssertTrue(EffectCapabilityResolver.canRunNativeTimedEffect("sunrise", lights: full))

        let partial = [light(id: "A", timed: ["sunrise"]), light(id: "B")]
        XCTAssertFalse(EffectCapabilityResolver.canRunNativeTimedEffect("sunrise", lights: partial))

        XCTAssertFalse(EffectCapabilityResolver.canRunNativeTimedEffect("sunrise", lights: []))
    }

    func testGradientLightsFilter() {
        let lights = [light(id: "strip", gradientPoints: 5),
                      light(id: "bulb"),
                      light(id: "weird", gradientPoints: 1)]
        XCTAssertEqual(EffectCapabilityResolver.gradientLights(lights).map(\.id), ["strip"])
    }
}
