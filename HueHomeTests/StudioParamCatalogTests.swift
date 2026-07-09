// StudioParamCatalogTests.swift
// HueHome Pro — Unit Tests
//
// Adjustment-settings revamp: the card catalogs must stay honest. Every
// declared param is read by something (sendParam, an engine loop, or the
// v2 apply path), essential density stays scannable, and params the audit
// removed as dead never come back silently.

import XCTest
@testable import HueHome

@MainActor
final class StudioParamCatalogTests: XCTestCase {

    private var vm: StudioViewModel!

    override func setUp() async throws {
        vm = StudioViewModel()
    }

    private var allCards: [StudioCard] { vm.effectCards + vm.liveModeCards }

    // ── Density ───────────────────────────────────────────────

    /// The compact tray shows essential params inline — keep it scannable.
    func testEveryCardHasOneToThreeEssentialParams() {
        for card in allCards {
            let count = card.params.filter { $0.tier == .essential }.count
            XCTAssertTrue((1...3).contains(count),
                          "\(card.id) has \(count) essential params")
        }
    }

    func testParamIDsAreUniquePerCard() {
        for card in allCards {
            let ids = card.params.map(\.id)
            XCTAssertEqual(ids.count, Set(ids).count, "\(card.id) has duplicate param ids")
        }
    }

    // ── Dead params stay dead ─────────────────────────────────

    /// Audit (2026-07-09): these params were never read by any engine loop
    /// or send path. If one returns, it must come with a consumer.
    func testRemovedDeadParamsAreAbsent() {
        let dead: [(card: String, param: String)] = [
            ("thunderstorm", "brightness"),   // loops read frequency/flash_intensity/min_brightness only
            ("party", "saturation"),          // never read anywhere
            ("prism", "saturation"),          // explicit no-op branch in sendParam
            ("ambient", "color"),             // ambient engine is CT-only (sends xy: nil)
        ]
        for (cardID, paramID) in dead {
            let card = allCards.first { $0.id == cardID }
            XCTAssertNotNil(card, cardID)
            XCTAssertFalse(card!.params.contains { $0.id == paramID },
                           "\(cardID).\(paramID) is a dead param — removed by the 2026-07 audit")
        }
    }

    /// Every app-driven param id must be read by its engine loop (verified
    /// against UnifiedOrchestrator run* loops, 2026-07-09). Locks drift in
    /// both directions: catalogs can't grow dead sliders, and renames that
    /// break the engine key contract fail here.
    func testAppDrivenParamsMatchEngineReadKeys() {
        let engineReads: [String: Set<String>] = [
            "party": ["speed", "brightness", "min_brightness", "smoothness",
                      "color"],  // "color" wired as palette tint (C10, same round)
            "strobe": ["speed", "brightness", "min_brightness", "duty_cycle", "flash_color"],
            "thunderstorm": ["frequency", "flash_intensity", "min_brightness", "ambient_color"],
            "ambient": ["speed", "brightness", "warmth", "smoothness", "min_brightness"],
        ]
        for card in vm.liveModeCards {
            guard let allowed = engineReads[card.id] else {
                XCTFail("no engine-read allowlist for \(card.id)"); continue
            }
            for param in card.params {
                XCTAssertTrue(allowed.contains(param.id),
                              "\(card.id).\(param.id) is not read by the \(card.id) engine loop")
            }
        }
    }

    // ── Formatters ────────────────────────────────────────────

    /// The Hz readout mirrors the engine mapping (0.5–3.0 Hz) and therefore
    /// documents the WCAG ≤3 flashes/sec ceiling at full slider deflection.
    func testFlashHzFormatterMatchesEngineMappingAndWCAGCeiling() {
        XCTAssertEqual(StudioParamFormat.flashHz(0), "0.5 Hz")
        XCTAssertEqual(StudioParamFormat.flashHz(100), "3.0 Hz")
        XCTAssertEqual(StudioParamFormat.flashHz(150), "3.0 Hz")  // clamped
    }

    func testKelvinFormatterConvertsMirek() {
        XCTAssertEqual(StudioParamFormat.kelvin(366), "2700K")
        XCTAssertEqual(StudioParamFormat.kelvin(153), "6500K")
        XCTAssertEqual(StudioParamFormat.kelvin(500), "2000K")
    }

    /// Transition preset values must stay within the old slider's range —
    /// they feed the same `dynamics.duration` field.
    func testTransitionOptionsAreValidDurations() {
        for option in StudioParamFormat.transitionOptions {
            XCTAssertTrue((0...6000).contains(option.value), option.label)
        }
        // Every card's transition default must be one of the preset values,
        // so the segmented row's nearest-snap never moves a fresh default.
        let presetValues = Set(StudioParamFormat.transitionOptions.map(\.value))
        for card in allCards {
            guard let transition = card.params.first(where: { $0.id == "transition" }) else { continue }
            XCTAssertTrue(presetValues.contains(transition.defaultValue),
                          "\(card.id) transition default \(transition.defaultValue) is not a preset")
        }
    }

    // ── ENT-only flags ────────────────────────────────────────

    /// Strobe's REST fallback runs a fixed 900 ms cycle and ignores these.
    func testStrobeEntOnlyFlags() {
        let strobe = vm.liveModeCards.first { $0.id == "strobe" }!
        for id in ["speed", "flash_color", "duty_cycle"] {
            XCTAssertTrue(strobe.params.first { $0.id == id }!.entOnly, id)
        }
        XCTAssertFalse(strobe.params.first { $0.id == "brightness" }!.entOnly)
    }
}
