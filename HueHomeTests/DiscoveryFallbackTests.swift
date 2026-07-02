// DiscoveryFallbackTests.swift
// HueHome Pro — Unit Tests
//
// Regression guard for audit finding M-11 (NUPnP fallback overriding mDNS):
// the cloud fallback must NEVER run once local bridges are in the chooser —
// an empty NUPnP reply used to bounce the user to "Something went wrong" and
// a non-empty one force-selected a bridge, hiding the one the user wanted.
//
// M-12 (OneShotLocation lifetime + timeout) cannot be unit-tested —
// CLLocationManager callbacks need a device/simulator location session; it
// is covered by the on-device checkpoint ("Set location" completes or fails
// within 15s, never spins forever).
//
// Audit: docs/audit/hardening-audit-2026-07-01.md M-11/M-12.

import XCTest
@testable import HueHome

@MainActor
final class DiscoveryFallbackTests: XCTestCase {

    func testCloudFallbackIsSkippedWhenLocalBridgesExist() async {
        let vm = BridgeDiscoveryViewModel()
        vm.phase = .scanning
        let local = BridgeEndpoint(name: "Local Bridge", host: "192.0.2.10", port: 443)
        vm.discoveredBridgeChoices = [local]

        // Entry guard fires before any network I/O — deterministic offline.
        await vm.discoverViaNUPnP()

        XCTAssertEqual(vm.phase, .scanning,
            "the chooser must stay up — no error phase, no force-selection (M-11)")
        XCTAssertEqual(vm.discoveredBridgeChoices, [local],
            "locally discovered bridges must survive the fallback window")
    }

    // NOTE: the "fallback still runs with an empty chooser" direction hits
    // the real discovery.meethue.com endpoint (no injection seam on
    // URLSession.shared here) — deliberately NOT unit-tested to keep the
    // suite hermetic; covered by the on-device checkpoint (mDNS blocked →
    // cloud discovery still finds the bridge).
}
