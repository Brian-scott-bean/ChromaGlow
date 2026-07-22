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

    // MARK: - L-16: manual-entry host validation

    func testValidatedManualHostAcceptsRealAddresses() {
        XCTAssertEqual(BridgeEndpoint.validatedManualHost("192.168.1.100"), "192.168.1.100")
        XCTAssertEqual(BridgeEndpoint.validatedManualHost("  10.0.0.2  "), "10.0.0.2")
        XCTAssertEqual(BridgeEndpoint.validatedManualHost("100.64.3.7"), "100.64.3.7",
                       "CGNAT/VPN space is legal — no private-range hard-block")
        XCTAssertEqual(BridgeEndpoint.validatedManualHost("fd00::1"), "fd00::1")
        XCTAssertEqual(BridgeEndpoint.validatedManualHost("philips-hue.local"), "philips-hue.local")
        XCTAssertEqual(BridgeEndpoint.validatedManualHost("bridge"), "bridge")
    }

    func testValidatedManualHostRefusesTypos() {
        XCTAssertNil(BridgeEndpoint.validatedManualHost(""))
        XCTAssertNil(BridgeEndpoint.validatedManualHost("   "))
        XCTAssertNil(BridgeEndpoint.validatedManualHost("192.168.1.999"),
                     "out-of-range octet is a typo, not a hostname")
        XCTAssertNil(BridgeEndpoint.validatedManualHost("192.168.1"),
                     "truncated IPv4 must not pass as a DNS name")
        XCTAssertNil(BridgeEndpoint.validatedManualHost("01.2.3.4"),
                     "leading-zero octets are rejected (Darwin inet_pton is lenient — we guard)")
        XCTAssertNil(BridgeEndpoint.validatedManualHost("192.168 .1.2"))
        XCTAssertNil(BridgeEndpoint.validatedManualHost("bridge..local"),
                     "empty label")
        XCTAssertNil(BridgeEndpoint.validatedManualHost("-bridge.local"))
        XCTAssertNil(BridgeEndpoint.validatedManualHost("bridge_1.local"),
                     "underscore is not RFC-1123")
        XCTAssertNil(BridgeEndpoint.validatedManualHost("http://192.168.1.5"),
                     "URLs are not hosts")
        XCTAssertNil(BridgeEndpoint.validatedManualHost("🌈.local"))
        XCTAssertNil(BridgeEndpoint.validatedManualHost(String(repeating: "a", count: 260)))
    }
}
