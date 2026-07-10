// RoomColorWashPlannerTests.swift
// ChromaGlow — long-press room color wash
//
// The planner decides what each bulb in a room gets when a harmony palette is
// spread across it. The rules that matter: adjacent color bulbs wear different
// anchors (that IS harmony), white-only bulbs join at the shared brightness
// instead of being skipped, and nothing ever emits an out-of-range color.

import XCTest
@testable import HueHome

final class RoomColorWashPlannerTests: XCTestCase {

    private func light(_ id: String, color: Bool, ct: Bool = false) throws -> HueLight {
        let colorJSON = color ? #""color": { "xy": { "x": 0.4, "y": 0.4 } },"# : ""
        let ctJSON = ct
            ? #""color_temperature": { "mirek": 366, "mirek_schema": { "mirek_minimum": 153, "mirek_maximum": 500 } },"#
            : ""
        let json = """
        {
          "id": "\(id)",
          "metadata": { "name": "Light \(id)", "archetype": "hue_bulb" },
          "on": { "on": true },
          \(colorJSON)
          \(ctJSON)
          "dimming": { "brightness": 80 }
        }
        """
        return try JSONDecoder().decode(HueLight.self, from: Data(json.utf8))
    }

    // MARK: - Distribution

    func testSingleColorGivesEveryColorBulbTheSameColor() throws {
        let lights = [try light("1", color: true), try light("2", color: true)]

        let plan = RoomColorWashPlanner.plan(
            lights: lights, rule: .none, rootHue: 0.6, saturation: 0.8, brightness: 70)

        XCTAssertEqual(plan.count, 2)
        XCTAssertEqual(plan[0].action, plan[1].action, "rule .none is one color for all")
        guard case .color(_, _, let bri) = plan[0].action else { return XCTFail("expected color") }
        XCTAssertEqual(bri, 70)
    }

    /// The point of harmony: neighbours differ.
    func testHarmonySpreadsDifferentAnchorsAcrossAdjacentBulbs() throws {
        let lights = try (1...4).map { try light("\($0)", color: true) }

        let plan = RoomColorWashPlanner.plan(
            lights: lights, rule: .complementary, rootHue: 0.0, saturation: 0.9, brightness: 80)

        XCTAssertEqual(plan.count, 4)
        XCTAssertNotEqual(plan[0].action, plan[1].action,
                          "adjacent bulbs must wear different harmony anchors")
    }

    // MARK: - Capability degradation

    func testWhiteOnlyBulbsJoinAtTheSharedBrightness() throws {
        let lights = [
            try light("1", color: true),
            try light("2", color: false),          // dimmable-only
            try light("3", color: false, ct: true) // CT-only
        ]

        let plan = RoomColorWashPlanner.plan(
            lights: lights, rule: .triadic, rootHue: 0.3, saturation: 0.8, brightness: 55)

        guard case .color = plan[0].action else { return XCTFail("color bulb should get color") }
        // A color palette has no faithful CT rendering — both non-color bulbs
        // fall through to brightness (SavedColor.application's rule).
        XCTAssertEqual(plan[1].action, .brightnessOnly(55))
        XCTAssertEqual(plan[2].action, .brightnessOnly(55))
    }

    // MARK: - Legality

    func testEveryEmittedColorIsInsideGamutAndCIE() throws {
        let lights = try (1...12).map { try light("\($0)", color: true) }

        for rule in HarmonyRule.allCases {
            let plan = RoomColorWashPlanner.plan(
                lights: lights, rule: rule, rootHue: 0.83, saturation: 1.0, brightness: 100)
            for assignment in plan {
                guard case .color(let x, let y, _) = assignment.action else { continue }
                XCTAssertTrue((0...1).contains(x), "\(rule): x=\(x)")
                XCTAssertTrue((0...1).contains(y), "\(rule): y=\(y)")
                let clamped = HueColorUtils.clampXYToGamut(x: x, y: y, gamut: .c)
                XCTAssertEqual(clamped.x, x, accuracy: 1e-9, "\(rule): outside gamut C")
                XCTAssertEqual(clamped.y, y, accuracy: 1e-9, "\(rule): outside gamut C")
            }
        }
    }

    func testEmptyRoomPlansNothing() {
        XCTAssertTrue(RoomColorWashPlanner.plan(
            lights: [], rule: .triadic, rootHue: 0.5, saturation: 1, brightness: 50).isEmpty)
    }
}
