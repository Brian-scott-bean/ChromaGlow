// AutomationsViewModelTests.swift
// ChromaGlow — audit L-47: the optimistic toggle must fire Observation
//
// The toggle used an in-place `automations[idx].enabled` subscript write.
// iOS 17.0/17.1 Observation runtimes missed element mutations (the reason
// RoomDetailViewModel adopted full-array replacement), so the switch could
// flip on the bridge while the row's UI never re-rendered. These tests pin
// the full-array idiom independent of toolchain behavior: an observer of
// `automations` must be notified by toggle(), and the value must flip.

import XCTest
@testable import HueHome

@MainActor
final class AutomationsViewModelTests: XCTestCase {

    private func makeItem(id: String = "demo:1", enabled: Bool) -> AutomationDisplayItem {
        AutomationDisplayItem(id: id, name: "Wake up", enabled: enabled,
                              category: .wakeUp, status: nil)
    }

    // Demo-style items carry no bridgeAutomationID, so toggle() returns after
    // the optimistic write — no network task, fully synchronous under test.
    func testToggleFiresObservationAndFlipsValue() {
        let vm = AutomationsViewModel()
        vm.automations = [makeItem(enabled: false), makeItem(id: "demo:2", enabled: true)]

        var observationFired = false
        withObservationTracking {
            _ = vm.automations
        } onChange: {
            observationFired = true
        }

        vm.toggle(vm.automations[0])

        XCTAssertTrue(observationFired,
                      "the optimistic write must be a full-array replacement so Observation fires (L-47)")
        XCTAssertTrue(vm.automations[0].enabled, "toggled item flips")
        XCTAssertTrue(vm.automations[1].enabled, "other items are untouched")
    }

    func testToggleOnlyTouchesTheMatchingItem() {
        let vm = AutomationsViewModel()
        vm.automations = [
            makeItem(id: "demo:1", enabled: true),
            makeItem(id: "demo:2", enabled: false),
            makeItem(id: "demo:3", enabled: true),
        ]

        vm.toggle(vm.automations[1])

        XCTAssertEqual(vm.automations.map(\.enabled), [true, true, true])
    }
}
