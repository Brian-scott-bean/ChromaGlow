// HueIntentClientTests.swift
// ChromaGlow — Siri Shortcuts

import XCTest
@testable import HueHome

final class HueIntentClientTests: XCTestCase {

    /// [String: Any] bodies can't be compared directly — round-trip through
    /// JSONSerialization and compare as NSDictionary.
    private func assertBody(_ body: [String: Any], equals expected: [String: Any],
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(NSDictionary(dictionary: body), NSDictionary(dictionary: expected),
                       file: file, line: line)
    }

    func testColorBodyTurnsOnAndGlides() {
        assertBody(HueIntentAPIClient.colorBody(x: 0.42, y: 0.33), equals: [
            "on":       ["on": true],
            "color":    ["xy": ["x": 0.42, "y": 0.33]],
            "dynamics": ["duration": 400],
        ])
    }

    func testColorTempBodyClampsToHueMirekRange() {
        let low = HueIntentAPIClient.colorTempBody(mirek: 100)
        XCTAssertEqual((low["color_temperature"] as? [String: Any])?["mirek"] as? Int, 153)
        let high = HueIntentAPIClient.colorTempBody(mirek: 900)
        XCTAssertEqual((high["color_temperature"] as? [String: Any])?["mirek"] as? Int, 500)
        let valid = HueIntentAPIClient.colorTempBody(mirek: 370)
        XCTAssertEqual((valid["color_temperature"] as? [String: Any])?["mirek"] as? Int, 370)
    }

    func testPresetBodyMatchesWidgetShape() {
        // Same shape ApplyPresetIntent (widget) sends — one contract.
        assertBody(HueIntentAPIClient.presetBody(brightness: 80, mirek: 350), equals: [
            "on":                ["on": true],
            "dimming":           ["brightness": 80.0],
            "color_temperature": ["mirek": 350],
            "dynamics":          ["duration": 800],
        ])
    }

    func testStopEffectsBodyIsNoEffect() {
        assertBody(HueIntentAPIClient.stopEffectsBody, equals: [
            "effects": ["effect": "no_effect"],
        ])
    }
}
