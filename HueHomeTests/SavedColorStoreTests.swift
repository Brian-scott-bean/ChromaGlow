// SavedColorStoreTests.swift
// ChromaGlow — Scenes overhaul Phase 3

import XCTest
@testable import HueHome

@MainActor
final class SavedColorStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suiteName = "SavedColorStoreTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // ── Store CRUD + persistence ──────────────────────────

    func testAddInsertsNewestFirstAndPersists() {
        let store = SavedColorStore(defaults: defaults)
        let first  = SavedColor(x: 0.4, y: 0.4, brightness: 80)
        let second = SavedColor(mirek: 300, brightness: 50)

        store.add(first)
        store.add(second)
        XCTAssertEqual(store.colors.map(\.id), [second.id, first.id],
                       "the just-saved swatch must be the first one you reach for")

        let reloaded = SavedColorStore(defaults: defaults)
        XCTAssertEqual(reloaded.colors, store.colors)
    }

    func testRenameAndRemove() {
        let store = SavedColorStore(defaults: defaults)
        let swatch = SavedColor(x: 0.3, y: 0.3, brightness: 100)
        store.add(swatch)

        store.rename(id: swatch.id, to: "  Sunset  ")
        XCTAssertEqual(store.color(for: swatch.id)?.name, "Sunset")

        store.rename(id: swatch.id, to: "   ")
        XCTAssertNil(store.color(for: swatch.id)?.name,
                     "a blank rename clears the name instead of storing whitespace")

        store.remove(id: swatch.id)
        XCTAssertTrue(store.colors.isEmpty)
        XCTAssertTrue(SavedColorStore(defaults: defaults).colors.isEmpty)
    }

    func testBrightnessClampsToHueRange() {
        XCTAssertEqual(SavedColor(x: 0.3, y: 0.3, brightness: 0).brightness, 1,
                       "the bridge rejects brightness 0 — clamp to 1")
        XCTAssertEqual(SavedColor(x: 0.3, y: 0.3, brightness: 250).brightness, 100)
    }

    // ── Capability fallback (application) ─────────────────

    func testColorSwatchOnColorLightAppliesXY() {
        let swatch = SavedColor(x: 0.42, y: 0.33, brightness: 75)
        let app = swatch.application(supportsColor: true, supportsColorTemp: true)
        XCTAssertEqual(app, .color(x: 0.42, y: 0.33, brightness: 75))
    }

    func testCTSwatchOnCTOnlyLightClampsMirekToLightRange() {
        let swatch = SavedColor(mirek: 500, brightness: 60)
        let app = swatch.application(
            supportsColor: false, supportsColorTemp: true,
            mirekMin: 153, mirekMax: 454
        )
        XCTAssertEqual(app, .colorTemp(mirek: 454, brightness: 60))
    }

    func testColorSwatchOnCTOnlyLightFallsBackToBrightness() {
        // A color swatch has no faithful CT rendering — brightness only.
        let swatch = SavedColor(x: 0.42, y: 0.33, brightness: 75)
        let app = swatch.application(supportsColor: false, supportsColorTemp: true)
        XCTAssertEqual(app, .brightnessOnly(75))
    }

    func testAnySwatchOnDimmableOnlyLightAppliesBrightness() {
        let colorSwatch = SavedColor(x: 0.42, y: 0.33, brightness: 75)
        XCTAssertEqual(colorSwatch.application(supportsColor: false, supportsColorTemp: false),
                       .brightnessOnly(75))
        let ctSwatch = SavedColor(mirek: 300, brightness: 40)
        XCTAssertEqual(ctSwatch.application(supportsColor: false, supportsColorTemp: false),
                       .brightnessOnly(40))
    }

    func testCTSwatchOnColorOnlyLightRendersAsXY() {
        let swatch = SavedColor(mirek: 300, brightness: 60)
        let app = swatch.application(supportsColor: true, supportsColorTemp: false)
        if case .color(_, _, let brightness) = app {
            XCTAssertEqual(brightness, 60)
        } else {
            XCTFail("a CT swatch on a color-capable light should render its white as xy, got \(app)")
        }
    }
}
