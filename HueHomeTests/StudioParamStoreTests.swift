// StudioParamStoreTests.swift
// HueHome Pro — Unit Tests
//
// Per-card last-used param persistence: round-trips through UserDefaults
// JSON, clamps every value to the card's declared ranges on load, and drops
// unknown card/param ids (stale beat keys, composition UUIDs, removed
// params) instead of resurrecting them.

import XCTest
import SwiftUI
@testable import HueHome

@MainActor
final class StudioParamStoreTests: XCTestCase {

    private var suite: UserDefaults!
    private var store: StudioParamStore!
    private var vm: StudioViewModel!

    override func setUp() async throws {
        suite = UserDefaults(suiteName: "StudioParamStoreTests")!
        suite.removePersistentDomain(forName: "StudioParamStoreTests")
        store = StudioParamStore(defaults: suite)
        vm = StudioViewModel()
    }

    override func tearDown() async throws {
        suite.removePersistentDomain(forName: "StudioParamStoreTests")
    }

    private var cards: [StudioCard] { vm.effectCards + vm.liveModeCards }

    func testValuesAndColorsRoundTrip() {
        store.saveNow(
            values: ["party": ["speed": 42, "brightness": 77]],
            colors: ["strobe": ["flash_color": Color(hue: 0.5, saturation: 1, brightness: 1)]]
        )
        let loaded = store.load(cards: cards)
        XCTAssertEqual(loaded.values["party"]?["speed"], 42)
        XCTAssertEqual(loaded.values["party"]?["brightness"], 77)
        let restored = loaded.colors["strobe"]?["flash_color"]
        XCTAssertNotNil(restored)
        XCTAssertEqual(restored!.hsbaComponents()[0], 0.5, accuracy: 0.01)
    }

    func testOutOfRangeValuesClampOnLoad() {
        // brightness slider is 1...100; speed 0...100.
        store.saveNow(values: ["party": ["speed": 900, "brightness": -50]], colors: [:])
        let loaded = store.load(cards: cards)
        XCTAssertEqual(loaded.values["party"]?["speed"], 100)
        XCTAssertEqual(loaded.values["party"]?["brightness"], 1)
    }

    func testUnknownCardAndParamIDsAreDropped() {
        store.saveNow(
            values: [
                "deadcard": ["speed": 50],                       // removed/unknown card
                "party": ["saturation": 80, "beat_mode": 1],     // removed param + session-only beat key
                "3F2504E0-4F89-11D3-9A0C-0305E82C3301": ["x": 1] // composition UUID
            ],
            colors: ["party": ["nonexistent": .red]]
        )
        let loaded = store.load(cards: cards)
        XCTAssertNil(loaded.values["deadcard"])
        XCTAssertNil(loaded.values["party"])   // both entries dropped -> empty -> omitted
        XCTAssertNil(loaded.values["3F2504E0-4F89-11D3-9A0C-0305E82C3301"])
        XCTAssertNil(loaded.colors["party"])
    }

    func testClampNormalizesTogglesAndSnapsSegmented() {
        XCTAssertEqual(StudioParamStore.clamp(0.9, to: .toggle), 1)
        XCTAssertEqual(StudioParamStore.clamp(0.2, to: .toggle), 0)
        // Segmented snaps to the nearest declared option.
        let snapped = StudioParamStore.clamp(
            700, to: .segmented(options: StudioParamFormat.transitionOptions))
        XCTAssertEqual(snapped, 400)
        XCTAssertNil(StudioParamStore.clamp(1, to: .colorPicker))
    }

    func testCorruptDataLoadsEmpty() {
        suite.set(Data("not json".utf8), forKey: StudioParamStore.storageKey)
        let loaded = store.load(cards: cards)
        XCTAssertTrue(loaded.values.isEmpty)
        XCTAssertTrue(loaded.colors.isEmpty)
    }
}
