// WhitelistRedactionTests.swift
// ChromaGlow — Family Sharing Phase 4 (H-03 for whitelist surfaces)
//
// Whitelist elements are OTHER apps' application keys. These tests gate
// the same commit that introduces the first whitelist API call: every
// textual pathway (path pre-logs, execute's redacted post-log, error-body
// sanitizer, and the WhitelistEntry type's own printable forms) must mask
// the element. Plus the pure delete-outcome mapping: the verify-by-re-read
// is the ONLY trusted signal.

import XCTest
@testable import HueHome

final class WhitelistRedactionTests: XCTestCase {

    private static let foreignKey = "OTHERAPPSKEY-0123456789abcdef-OTHERAPPSKEY"

    private func entry(element: String = WhitelistRedactionTests.foreignKey,
                       name: String = "hue_essentials#pixel") -> HueV1Client.WhitelistEntry {
        HueV1Client.WhitelistEntry(element: element, name: name,
                                   createDate: "2025-01-01T00:00:00",
                                   lastUseDate: "2026-07-01T00:00:00")
    }

    // ── Path redaction ────────────────────────────────────

    func testRedactedPathMasksWhitelistElementWithApiPrefix() {
        let redacted = HueV1Client.redactedPath(
            fromV1URLPath: "/api/OWNERTOKEN/config/whitelist/\(Self.foreignKey)"
        )
        XCTAssertEqual(redacted, "/config/whitelist/<redacted>")
        XCTAssertFalse(redacted.contains(Self.foreignKey))
    }

    func testMaskWhitelistElementOnBarePath() {
        XCTAssertEqual(
            HueV1Client.maskWhitelistElement(in: "/config/whitelist/\(Self.foreignKey)"),
            "/config/whitelist/<redacted>"
        )
    }

    func testMaskLeavesWhitelistlessPathsAlone() {
        XCTAssertEqual(HueV1Client.maskWhitelistElement(in: "/config"), "/config")
        XCTAssertEqual(HueV1Client.maskWhitelistElement(in: "/lights"), "/lights")
        XCTAssertEqual(HueV1Client.maskWhitelistElement(in: "/schedules/3"), "/schedules/3")
    }

    func testMaskHandlesTrailingWhitelistWithoutElement() {
        // GET /config/whitelist (no element) must not crash or over-mask.
        XCTAssertEqual(
            HueV1Client.maskWhitelistElement(in: "/config/whitelist"),
            "/config/whitelist"
        )
    }

    // ── Error-body sanitizer ──────────────────────────────

    func testSanitizedForLogScrubsWhitelistAddressEchoes() {
        let client = HueV1Client(ip: "192.0.2.10", token: "own-token")
        let body = #"[{"error":{"type":3,"address":"/config/whitelist/\#(Self.foreignKey)","description":"resource not available"}}]"#
        let sanitized = client.sanitizedForLog(body)
        XCTAssertFalse(sanitized.contains(Self.foreignKey),
                       "another app's key survived the sanitizer")
        XCTAssertTrue(sanitized.contains("resource not available"))
    }

    // ── WhitelistEntry printable forms ────────────────────

    func testEntryTextualFormsNeverContainTheElement() {
        let e = entry()
        XCTAssertFalse(String(describing: e).contains(Self.foreignKey))
        XCTAssertFalse(String(reflecting: e).contains(Self.foreignKey))
        XCTAssertFalse(e.displayID.contains(Self.foreignKey))
        XCTAssertTrue(e.displayID.count <= 8, "displayID must stay a stub")
    }

    // ── Delete-outcome mapping (pure) ─────────────────────

    func testRereadAbsenceIsVerifiedDeleteEvenIfBridgeErrored() {
        // The DELETE 403'd but the re-read no longer lists it (e.g. another
        // controller removed it concurrently) — gone is gone.
        let outcome = HueV1Client.whitelistDeleteOutcome(
            afterReread: [entry(element: "some-other-key")],
            element: Self.foreignKey,
            bridgeError: "HTTP 403"
        )
        XCTAssertEqual(outcome, .deletedVerified)
    }

    func testStillPresentWithBridgeErrorIsUnsupported() {
        let outcome = HueV1Client.whitelistDeleteOutcome(
            afterReread: [entry()],
            element: Self.foreignKey,
            bridgeError: "method, DELETE, not available for resource"
        )
        XCTAssertEqual(outcome, .unsupportedByFirmware("method, DELETE, not available for resource"))
    }

    func testStillPresentDespiteClaimedSuccessIsStillPresent() {
        let outcome = HueV1Client.whitelistDeleteOutcome(
            afterReread: [entry()],
            element: Self.foreignKey,
            bridgeError: nil
        )
        XCTAssertEqual(outcome, .stillPresent)
    }

    func testWhitelistGoneOnRereadIsUnsupported() {
        // Modern firmware may omit the whitelist entirely — nothing to
        // verify against, so honesty demands "unsupported".
        let outcome = HueV1Client.whitelistDeleteOutcome(
            afterReread: nil,
            element: Self.foreignKey,
            bridgeError: nil
        )
        guard case .unsupportedByFirmware = outcome else {
            return XCTFail("expected unsupportedByFirmware, got \(outcome)")
        }
    }
}
