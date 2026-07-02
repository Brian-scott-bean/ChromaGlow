// SecretLogScrubTests.swift
// HueHome Pro — Unit Tests
//
// Regression guards for audit findings H-03 / H-04 (secrets in logs):
//  - The v1 client's log redaction strips the /api/{token} URL segment and
//    scrubs token echoes out of bridge error bodies.
//  - A full stubbed pairing run leaves no application-key / client-key
//    substring in the pairing log lines (the on-screen debug log source).
//
// Audit: docs/audit/hardening-audit-2026-07-01.md §6 "Secret logging".

import XCTest
@testable import HueHome

final class SecretLogScrubTests: XCTestCase {

    private static let fakeToken     = "FAKETESTTOKEN-abcdef0123456789-FAKETESTTOKEN"
    private static let fakeClientKey = "00112233445566778899AABBCCDDEEFF"

    // The pairing flow persists credentials to the real (legacy) Keychain
    // slots. Snapshot and restore them so this test can never clobber an
    // actual pairing on the machine/device running the suite.
    private var savedToken:     String?
    private var savedIP:        String?
    private var savedClientKey: String?

    override func setUp() {
        super.setUp()
        savedToken     = try? KeychainManager.shared.loadAPIToken()
        savedIP        = try? KeychainManager.shared.loadBridgeIP()
        savedClientKey = try? KeychainManager.shared.load(for: "hue_client_key")
        StubURLProtocol.reset()
    }

    override func tearDown() {
        if let savedToken     { try? KeychainManager.shared.saveAPIToken(savedToken) }
        else                  { try? KeychainManager.shared.deleteAPIToken() }
        if let savedIP        { try? KeychainManager.shared.saveBridgeIP(savedIP) }
        else                  { try? KeychainManager.shared.deleteBridgeIP() }
        if let savedClientKey { try? KeychainManager.shared.save(value: savedClientKey, for: "hue_client_key") }
        else                  { try? KeychainManager.shared.delete(for: "hue_client_key") }
        StubURLProtocol.reset()
        super.tearDown()
    }

    // ──────────────────────────────────────────────
    // MARK: - H-03: v1 URL/token redaction
    // ──────────────────────────────────────────────

    func testRedactedPathStripsTokenFromV1Path() {
        let redacted = HueV1Client.redactedPath(
            fromV1URLPath: "/api/\(Self.fakeToken)/schedules/3"
        )
        XCTAssertEqual(redacted, "/schedules/3")
        XCTAssertFalse(redacted.contains(Self.fakeToken))
    }

    func testRedactedPathHandlesBareApiTokenRoot() {
        let redacted = HueV1Client.redactedPath(fromV1URLPath: "/api/\(Self.fakeToken)")
        XCTAssertEqual(redacted, "/")
        XCTAssertFalse(redacted.contains(Self.fakeToken))
    }

    func testRedactedPathLeavesNonAPIPathsAlone() {
        XCTAssertEqual(
            HueV1Client.redactedPath(fromV1URLPath: "/clip/v2/resource/light"),
            "/clip/v2/resource/light"
        )
    }

    func testSanitizedForLogScrubsTokenFromErrorBodies() {
        let client = HueV1Client(ip: "192.0.2.10", token: Self.fakeToken)
        let body = "[{\"error\":{\"type\":1,\"address\":\"/api/\(Self.fakeToken)/lights\",\"description\":\"unauthorized user\"}}]"
        let sanitized = client.sanitizedForLog(body)
        XCTAssertFalse(sanitized.contains(Self.fakeToken), "token echoed in sanitized error body")
        XCTAssertTrue(sanitized.contains("unauthorized user"), "sanitizer must keep the useful error text")
    }

    func testSanitizedForLogScrubsForeignAPISegments() {
        // Even a token that is not this client's own must not survive an
        // /api/{…} path segment.
        let client = HueV1Client(ip: "192.0.2.10", token: "other-token")
        let sanitized = client.sanitizedForLog("PUT /api/\(Self.fakeToken)/groups/0/action failed")
        XCTAssertFalse(sanitized.contains(Self.fakeToken))
    }

    // ──────────────────────────────────────────────
    // MARK: - H-04: post-pairing log scrape
    // ──────────────────────────────────────────────

    @MainActor
    func testPairingLogLinesNeverContainSecrets() async throws {
        let vm = BridgeDiscoveryViewModel()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        vm.pairingSessionOverride = URLSession(configuration: config)
        // URLProtocol stubs cannot present a server trust for TOFU capture —
        // bypass the D-016 pin acquisition step for this offline test.
        vm.pinAcquisitionOverride = { _ in true }

        let success = "[{\"success\":{\"username\":\"\(Self.fakeToken)\",\"clientkey\":\"\(Self.fakeClientKey)\"}}]"
        StubURLProtocol.stubs["/api"] = (Data(success.utf8), 200)

        let bridge = BridgeEndpoint(name: "TestBridge", host: "192.0.2.10", port: 443)
        vm.pairWithBridge(bridge)

        // Poll for the async pairing task to finish (5s ceiling).
        for _ in 0..<100 {
            if case .paired = vm.phase { break }
            if case .error = vm.phase { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard case .paired(let ip, _) = vm.phase else {
            return XCTFail("pairing did not complete; phase=\(vm.phase)")
        }
        XCTAssertEqual(ip, "192.0.2.10")

        let joined = vm.logLines.joined(separator: "\n")
        XCTAssertFalse(joined.contains(Self.fakeToken),
                       "application key leaked into pairing log lines")
        XCTAssertFalse(joined.contains(Self.fakeClientKey),
                       "entertainment client key leaked into pairing log lines")
    }

    @MainActor
    func testPairingErrorLogLinesContainNoSecrets() async throws {
        let vm = BridgeDiscoveryViewModel()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        vm.pairingSessionOverride = URLSession(configuration: config)

        let linkButtonError = "[{\"error\":{\"type\":101,\"address\":\"\",\"description\":\"link button not pressed\"}}]"
        StubURLProtocol.stubs["/api"] = (Data(linkButtonError.utf8), 200)

        let bridge = BridgeEndpoint(name: "TestBridge", host: "192.0.2.10", port: 443)
        vm.pairWithBridge(bridge)

        for _ in 0..<100 {
            if case .bridgeFound = vm.phase { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard case .bridgeFound = vm.phase else {
            return XCTFail("expected retryable bridgeFound phase; got \(vm.phase)")
        }
        let joined = vm.logLines.joined(separator: "\n")
        XCTAssertFalse(joined.contains(Self.fakeToken))
        XCTAssertFalse(joined.contains(Self.fakeClientKey))
    }
}
