// WidgetTimelineRobustnessTests.swift
// HueHome Pro — Unit Tests
//
// Regression guards for round-2 checkpoint Item 3 (blurry/redacted widget):
// the widget's timeline generation must always return fast. The grouped_light
// refresh runs under a HARD wall-clock budget — an unreachable bridge (phone
// off the home Wi-Fi, stale IP after DHCP) must cost at most the budget, not
// the transport's full timeout, because WidgetKit throttles slow extensions
// into the blurred placeholder rendering.

import XCTest
@testable import HueHome

/// URLProtocol that accepts every request and never completes it — models an
/// unreachable bridge that neither answers nor refuses the connection.
final class HangingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { /* hang forever */ }
    override func stopLoading() {}
}

final class WidgetTimelineRobustnessTests: XCTestCase {

    override func tearDown() {
        WidgetAPIClient.sessionOverride = nil
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testBoundedFetchReturnsNilWithinBudgetWhenBridgeUnreachable() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HangingURLProtocol.self]
        WidgetAPIClient.sessionOverride = URLSession(configuration: config)

        let start = Date()
        let result = await WidgetAPIClient.fetchGroupedLightsBounded(
            ip: "192.0.2.99", token: "irrelevant", budget: 0.5
        )
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNil(result, "a hanging transport must resolve to nil, not throw or hang")
        XCTAssertLessThan(elapsed, 5,
                          "the budget must bound the fetch — got \(elapsed)s for a 0.5s budget")
    }

    func testBoundedFetchReturnsDataWhenBridgeResponds() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        WidgetAPIClient.sessionOverride = URLSession(configuration: config)

        let body = #"{"data":[{"id":"gl-1","on":{"on":true},"dimming":{"brightness":72.0}}]}"#
        StubURLProtocol.stubs["/clip/v2/resource/grouped_light"] = (Data(body.utf8), 200)

        let result = await WidgetAPIClient.fetchGroupedLightsBounded(
            ip: "192.0.2.10", token: "irrelevant", budget: 4
        )

        XCTAssertEqual(result?.count, 1)
        XCTAssertEqual(result?.first?.id, "gl-1")
        XCTAssertEqual(result?.first?.on.on, true)
        XCTAssertEqual(result?.first?.dimming?.brightness, 72.0)
    }
}
