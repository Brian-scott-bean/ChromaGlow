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

    // MARK: - TimedEffectRouting (Phase C)

    func testTimedRoutingNativeWhenDefaultAndFullSupport() {
        let lights = [light(id: "A", timed: ["sunrise", "sunset"]),
                      light(id: "B", timed: ["sunrise", "sunset"])]
        XCTAssertEqual(TimedEffectRouting.route(effectID: "sunrise",
                                                paramsAreDefault: true, lights: lights),
                       .native(effect: "sunrise"))
    }

    func testTimedRoutingFallsBackOnCustomizationAndPartialSupport() {
        let full = [light(id: "A", timed: ["sunset"])]
        XCTAssertEqual(TimedEffectRouting.route(effectID: "sunset",
                                                paramsAreDefault: false, lights: full),
                       .appRamp(reason: .customized))

        let partial = [light(id: "A", timed: ["sunset"]), light(id: "B")]
        XCTAssertEqual(TimedEffectRouting.route(effectID: "sunset",
                                                paramsAreDefault: true, lights: partial),
                       .appRamp(reason: .partialSupport))

        XCTAssertEqual(TimedEffectRouting.route(effectID: "winddown",
                                                paramsAreDefault: true, lights: full),
                       .appRamp(reason: .notMappable))

        XCTAssertEqual(TimedEffectRouting.route(effectID: "sunrise",
                                                paramsAreDefault: true, lights: []),
                       .appRamp(reason: .noLights))
    }

    func testTimedRoutingParamsAreDefault() {
        var state = EffectParamState()
        // Empty state reads the card defaults → default.
        XCTAssertTrue(TimedEffectRouting.paramsAreDefault(effectID: "sunrise", state: state))
        state.sliders["endBrightness"] = 70   // customized
        XCTAssertFalse(TimedEffectRouting.paramsAreDefault(effectID: "sunrise", state: state))

        var sunset = EffectParamState()
        XCTAssertTrue(TimedEffectRouting.paramsAreDefault(effectID: "sunset", state: sunset))
        sunset.toggles["turnOff"] = false     // firmware sunset always ends off
        XCTAssertFalse(TimedEffectRouting.paramsAreDefault(effectID: "sunset", state: sunset))
    }

    // MARK: - Dynamic scene authoring (Phase E)

    func testDynamicSceneRequestEncodesPaletteSpeedAndAutoDynamic() throws {
        let colorLight = light(id: "C1")
        // Give it color capability so it gets the first palette color.
        let colored = HueLight(
            id: "C1", metadata: LightMetadata(name: "C1", archetype: nil),
            on: OnState(on: true), dimming: nil,
            color: LightColor(xy: CIExy(x: 0.3, y: 0.3), gamut_type: "C"),
            color_temperature: nil, owner: nil
        )
        _ = colorLight
        let request = CreateSceneRequest.dynamicScene(
            name: "Sunset Groove", groupID: "room-1", groupRtype: "room",
            lights: [colored],
            paletteXY: [(0.64, 0.33), (0.17, 0.70)],
            brightness: 80, speed: 0.6, autoDynamic: true
        )
        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["type"] as? String, "scene")
        XCTAssertEqual(json["speed"] as? Double, 0.6)
        XCTAssertEqual(json["auto_dynamic"] as? Bool, true)

        let palette = try XCTUnwrap(json["palette"] as? [String: Any])
        let colors = try XCTUnwrap(palette["color"] as? [[String: Any]])
        XCTAssertEqual(colors.count, 2)

        let actions = try XCTUnwrap(json["actions"] as? [[String: Any]])
        XCTAssertEqual(actions.count, 1)
        let action = try XCTUnwrap(actions.first?["action"] as? [String: Any])
        XCTAssertNotNil(action["color"])   // color light seeds first palette color
    }

    func testStaticSceneRequestOmitsDynamicFields() throws {
        let request = CreateSceneRequest.fromHueLights(
            name: "Static", groupID: "room-1", lights: [light(id: "A")])
        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["palette"])       // pre-R3 body unchanged on the wire
        XCTAssertNil(json["speed"])
        XCTAssertNil(json["auto_dynamic"])
    }

    func testTimedEffectsBodyClearsFirmwareEffectInSamePut() {
        let body = TimedEffectsBody(effect: "sunrise", durationMs: 60_000,
                                    clearFirmwareEffect: true)
        let expected: [String: Any] = [
            "timed_effects": ["effect": "sunrise", "duration": 60_000],
            "effects": ["effect": "no_effect"],
        ]
        XCTAssertEqual(body.dictionary() as NSDictionary, expected as NSDictionary)
    }

    // MARK: - ControlMappingEngine (Phase G)

    func testRotaryEmitsImmediatelyThenCoalesces() {
        var engine = ControlMappingEngine()
        // First twist: immediate emit (leading edge — latency matters).
        XCTAssertEqual(engine.handleRotary(clockwise: true, steps: 5, now: 10.0),
                       .nudgeBPM(delta: 1.0))
        // Bursts inside the 100 ms window coalesce silently…
        XCTAssertEqual(engine.handleRotary(clockwise: true, steps: 3, now: 10.03), .none)
        XCTAssertEqual(engine.handleRotary(clockwise: true, steps: 2, now: 10.06), .none)
        // …and flush (5 pending steps) on the first event past the window.
        XCTAssertEqual(engine.handleRotary(clockwise: true, steps: 4, now: 10.15),
                       .nudgeBPM(delta: 9 * ControlMappingEngine.bpmPerStep))
    }

    func testRotaryCounterClockwiseIsNegativeAndCancelsOut() {
        var engine = ControlMappingEngine()
        XCTAssertEqual(engine.handleRotary(clockwise: false, steps: 10, now: 0),
                       .nudgeBPM(delta: -2.0))
        // Opposite twists inside one window cancel to zero → no action.
        _ = engine.handleRotary(clockwise: true, steps: 4, now: 0.02)
        XCTAssertEqual(engine.handleRotary(clockwise: false, steps: 4, now: 0.2), .none)
    }

    func testButtonMappingDJMode() {
        let engine = ControlMappingEngine()
        XCTAssertEqual(engine.handleButton(controlID: 1, event: "initial_press"), .tapTempo)
        XCTAssertEqual(engine.handleButton(controlID: 1, event: "long_press"), .resyncDownbeat)
        XCTAssertEqual(engine.handleButton(controlID: 2, event: "initial_press"), .punchBurst(slot: 0))
        XCTAssertEqual(engine.handleButton(controlID: 4, event: "initial_press"), .punchBurst(slot: 2))
        // Pads mirror the on-screen hold-to-engage: lifting releases.
        XCTAssertEqual(engine.handleButton(controlID: 2, event: "short_release"), .punchRelease)
        XCTAssertEqual(engine.handleButton(controlID: 3, event: "long_release"), .punchRelease)
        // Button 1 releases stay inert (tap tempo fires on press alone).
        XCTAssertEqual(engine.handleButton(controlID: 1, event: "short_release"), .none)
        XCTAssertEqual(engine.handleButton(controlID: 9, event: "initial_press"), .none)
    }

    // MARK: - GradientChannelMap (Phase F)

    func testGradientMapNilWithoutStrips() {
        let lights = [light(id: "A"), light(id: "B")]
        XCTAssertNil(GradientChannelMap.build(orderedLightIDs: ["A", "B"], lights: lights))
    }

    func testGradientMapExpandsStripAndPreservesOrder() throws {
        let lights = [light(id: "strip", gradientPoints: 5),
                      light(id: "b1"), light(id: "b2")]
        let map = try XCTUnwrap(GradientChannelMap.build(
            orderedLightIDs: ["b1", "strip", "b2"], lights: lights))
        XCTAssertEqual(map.entries.map(\.lightID), ["b1", "strip", "b2"])
        XCTAssertEqual(map.entries.map(\.channelCount), [1, 5, 1])
        XCTAssertEqual(map.entries[1].channelRange, 1..<6)
        XCTAssertEqual(map.totalChannels, 7)
    }

    func testGradientMapRespectsPointsCapable() {
        let lights = [light(id: "s3", gradientPoints: 3)]
        let map = GradientChannelMap.build(orderedLightIDs: ["s3"], lights: lights)
        XCTAssertEqual(map?.entries.first?.channelCount, 3)
    }

    func testGradientMapBudgetNeverStarvesLaterLights() {
        // 17 bulbs + strip + 2 bulbs = 20 lights: after reserving one
        // channel for every light, nothing is left for the strip to expand
        // into (20 − 17 − 2 = 1) — it stays flat, so the map is nil and the
        // room takes the plain per-light path.
        var ids = (0..<17).map { "b\($0)" }
        ids.append("strip")
        ids.append(contentsOf: ["t1", "t2"])
        var lights = ids.map { light(id: $0) }
        lights[17] = light(id: "strip", gradientPoints: 5)

        XCTAssertNil(GradientChannelMap.build(orderedLightIDs: ids, lights: lights))
    }

    func testGradientMapBudgetTrimsStrip() throws {
        // 16 bulbs + strip + 1 bulb: strip can expand into 20-16-1 = 3 channels.
        var ids = (0..<16).map { "b\($0)" }
        ids.append("strip")
        ids.append("tail")
        var lights = ids.map { light(id: $0) }
        lights[16] = light(id: "strip", gradientPoints: 5)

        let map = try XCTUnwrap(GradientChannelMap.build(orderedLightIDs: ids, lights: lights))
        XCTAssertEqual(map.entries[16].channelCount, 3)
        XCTAssertEqual(map.entries[17].channelCount, 1)
        XCTAssertEqual(map.totalChannels, 20)
        XCTAssertLessThanOrEqual(map.totalChannels, GradientChannelMap.channelBudget)
    }

    func testGradientBodyWithFrameExtras() {
        let body = GradientBody(pointsXY: [CGPoint(x: 0.2, y: 0.3), CGPoint(x: 0.4, y: 0.5)],
                                brightness: 60, on: true, durationMs: 200)
        let dict = body.dictionary()
        XCTAssertEqual((dict["on"] as? [String: Any])?["on"] as? Bool, true)
        XCTAssertEqual((dict["dimming"] as? [String: Any])?["brightness"] as? Double, 60)
        XCTAssertEqual((dict["dynamics"] as? [String: Any])?["duration"] as? Int, 200)
        XCTAssertNotNil(dict["gradient"])
    }

    func testSSEDecodesButtonAndRotaryEvents() throws {
        let json = """
        [{"id":"b-1","type":"button",
          "button":{"button_report":{"event":"initial_press"}}},
         {"id":"r-1","type":"relative_rotary",
          "relative_rotary":{"rotary_report":{"action":"start",
            "rotation":{"direction":"counter_clock_wise","steps":12,"duration":400}}}}]
        """
        let updates = try JSONDecoder().decode([SSEResourceUpdate].self, from: Data(json.utf8))
        XCTAssertEqual(updates[0].button?.event, "initial_press")
        XCTAssertEqual(updates[1].relativeRotary?.rotation?.steps, 12)
        XCTAssertEqual(updates[1].relativeRotary?.rotation?.direction, "counter_clock_wise")
    }
}
