// BridgeAuthorizationMonitorTests.swift
// ChromaGlow — Family Sharing Phase 4 (cooperative wipe signal)
//
// The contract under test is the NEGATIVE space: transient failures must
// never look like revocation. The status rule is pure
// (HueAPIClient.isExplicitUnauthorizedStatus) and gates the only call
// site; the monitor itself is dumb set+token state.

import XCTest
@testable import HueHome

@MainActor
final class BridgeAuthorizationMonitorTests: XCTestCase {

    // ── The one rule: what counts as explicit ─────────────

    func testOnlyAuthRefusalStatusesAreExplicit() {
        XCTAssertTrue(HueAPIClient.isExplicitUnauthorizedStatus(401))
        XCTAssertTrue(HueAPIClient.isExplicitUnauthorizedStatus(403))
    }

    func testTransientAndServerFailuresAreNeverExplicit() {
        // Timeouts surface as thrown URLErrors (no status at all — the
        // hook can't fire), and these statuses must not count either.
        for status in [0, 400, 404, 408, 429, 500, 502, 503, 504] {
            XCTAssertFalse(HueAPIClient.isExplicitUnauthorizedStatus(status),
                           "HTTP \(status) must never trigger a wipe")
        }
    }

    // ── Monitor state semantics ───────────────────────────

    func testReportInsertsAndBumpsToken() {
        let monitor = BridgeAuthorizationMonitor()
        let before = monitor.signalToken

        monitor.reportExplicitUnauthorized(bridgeID: "bridge-1")

        XCTAssertEqual(monitor.unauthorizedBridgeIDs, ["bridge-1"])
        XCTAssertNotEqual(monitor.signalToken, before)
    }

    func testRepeatReportsCollapseInSetButStillSignal() {
        // A 403 storm (many in-flight requests failing together) must not
        // multiply wipe work — set membership collapses — but each report
        // still moves the token so a consumer that just drained re-checks.
        let monitor = BridgeAuthorizationMonitor()
        monitor.reportExplicitUnauthorized(bridgeID: "bridge-1")
        let afterFirst = monitor.signalToken

        monitor.reportExplicitUnauthorized(bridgeID: "bridge-1")

        XCTAssertEqual(monitor.unauthorizedBridgeIDs.count, 1)
        XCTAssertNotEqual(monitor.signalToken, afterFirst)
    }

    func testClearRemovesOnlyThatBridge() {
        let monitor = BridgeAuthorizationMonitor()
        monitor.reportExplicitUnauthorized(bridgeID: "bridge-1")
        monitor.reportExplicitUnauthorized(bridgeID: "bridge-2")

        monitor.clear(bridgeID: "bridge-1")

        XCTAssertEqual(monitor.unauthorizedBridgeIDs, ["bridge-2"])
    }

    // ── Client hook firing ────────────────────────────────

    func testClientHookRespectsTheStatusRule() {
        // The execute() call site is `if isExplicitUnauthorizedStatus {
        // onExplicitUnauthorized?() }` — simulate both sides of the gate
        // exactly as the call site composes them. (The hook is @Sendable,
        // so the counter is a reference box.)
        final class Counter: @unchecked Sendable { var value = 0 }
        let fired = Counter()
        let client = BridgeAPIClient(bridgeID: "bridge-1", bridgeName: "Test",
                                     ip: "192.0.2.10", token: "t")
        client.onExplicitUnauthorized = { fired.value += 1 }

        for status in [200, 404, 500, 503] where HueAPIClient.isExplicitUnauthorizedStatus(status) {
            client.onExplicitUnauthorized?()
        }
        XCTAssertEqual(fired.value, 0)

        for status in [401, 403] where HueAPIClient.isExplicitUnauthorizedStatus(status) {
            client.onExplicitUnauthorized?()
        }
        XCTAssertEqual(fired.value, 2)
    }

    // MARK: - Light reachability (device round, build 58)

    /// Brian's bridge's real reply to a PUT on a bulb switched off at the
    /// wall (build 57): HTTP 207 carrying data AND a communication error.
    private static let unreachableReply = #"{"data":[{"rid":"a7325ab7-32db-4b43-ae7b-216b10919c62","rtype":"light"}],"errors":[{"description":"device (light) a7325ab7-32db-4b43-ae7b-216b10919c62 has communication issues, command (.on.on) may not have effect","error_code":"communication_error"}]}"#

    func testCommunicationErrorReplyIsRecognisedAndNothingElseIs() {
        XCTAssertTrue(HueAPIClient.reportsCommunicationIssue(Data(Self.unreachableReply.utf8)))
        XCTAssertFalse(HueAPIClient.reportsCommunicationIssue(
            Data(#"{"data":[{"rid":"x","rtype":"light"}],"errors":[]}"#.utf8)))
        XCTAssertFalse(HueAPIClient.reportsCommunicationIssue(
            Data(#"{"data":[],"errors":[{"description":"invalid value for brightness"}]}"#.utf8)))
        XCTAssertFalse(HueAPIClient.reportsCommunicationIssue(Data()))
        XCTAssertFalse(HueAPIClient.reportsCommunicationIssue(Data("[]".utf8)))
    }

    func testOnlyASingleLightPutPathNamesALight() {
        XCTAssertEqual(HueAPIClient.lightID(fromPutPath: "/clip/v2/resource/light/abc-1"), "abc-1")
        XCTAssertNil(HueAPIClient.lightID(fromPutPath: "/clip/v2/resource/grouped_light/abc-1"))
        XCTAssertNil(HueAPIClient.lightID(fromPutPath: "/clip/v2/resource/light/"))
        XCTAssertNil(HueAPIClient.lightID(fromPutPath: "/clip/v2/resource/light"))
        XCTAssertNil(HueAPIClient.lightID(fromPutPath: "/clip/v2/resource/light/abc/extra"))
    }

    func testLightRepliesMarkAndClearAndReportOnlyChanges() {
        final class Events: @unchecked Sendable { var list: [String] = [] }
        let events = Events()
        let client = BridgeAPIClient(bridgeID: "bridge-1", bridgeName: "Test",
                                     ip: "192.0.2.10", token: "t")
        client.onLightReachabilityChanged = { id, ok in events.list.append("\(id):\(ok)") }
        let clean = Data(#"{"data":[{"rid":"L1","rtype":"light"}],"errors":[]}"#.utf8)
        let dead = Data(Self.unreachableReply.utf8)

        client.noteLightReply(path: "/clip/v2/resource/light/L1", data: clean)
        XCTAssertFalse(client.isLightUnresponsive("L1"))
        XCTAssertEqual(events.list, [], "a clean reply for a responding light is not a change")

        client.noteLightReply(path: "/clip/v2/resource/light/L1", data: dead)
        client.noteLightReply(path: "/clip/v2/resource/light/L1", data: dead)
        XCTAssertTrue(client.isLightUnresponsive("L1"))
        XCTAssertEqual(events.list, ["L1:false"], "reported once, on the change")

        client.noteLightReply(path: "/clip/v2/resource/grouped_light/G1", data: clean)
        XCTAssertTrue(client.isLightUnresponsive("L1"), "a group reply says nothing about one bulb")

        client.noteLightReply(path: "/clip/v2/resource/light/L1", data: clean)
        XCTAssertFalse(client.isLightUnresponsive("L1"))
        XCTAssertEqual(events.list, ["L1:false", "L1:true"])
    }

}
