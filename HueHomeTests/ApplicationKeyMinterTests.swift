// ApplicationKeyMinterTests.swift
// HueHome Pro — Unit Tests
//
// Family Sharing Phase 2: the extracted identity-gated key mint.
// All tests run fully offline via URLProtocol stubs. The behavior-
// preservation proof for the NORMAL pairing flow is that
// SecretLogScrubTests' H-04 pair passes unchanged — these tests cover
// what is new: parameterized devicetype / generateclientkey, error
// mapping, the expectedIdentity refusal, and the guest slug rules.

import XCTest
@testable import HueHome

// MARK: - Body-capturing URLProtocol stub

/// Like StubURLProtocol, but also records each request's method, URL, and
/// body (URLSession moves httpBody into httpBodyStream — read it back).
final class BodyCapturingStubURLProtocol: URLProtocol {

    // nonisolated(unsafe): test-only state, written by the URL-loading
    // system's single loader thread and read after the request completes —
    // never concurrently. Documents the contract instead of warning.
    nonisolated(unsafe) static var stubs: [String: (data: Data, statusCode: Int)] = [:]
    nonisolated(unsafe) static var capturedBodies: [Data] = []
    nonisolated(unsafe) static var capturedURLs: [URL] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let url = request.url {
            Self.capturedURLs.append(url)
        }
        if let body = request.httpBody {
            Self.capturedBodies.append(body)
        } else if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let bufferSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            Self.capturedBodies.append(data)
        }

        let path = request.url?.path ?? ""
        if let stub = Self.stubs[path] {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: stub.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.data)
        } else {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 404,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset() {
        stubs = [:]
        capturedBodies = []
        capturedURLs = []
    }
}

// MARK: - Tests

final class ApplicationKeyMinterTests: XCTestCase {

    private static let fakeToken     = "FAKEMINTTOKEN-abcdef0123456789-FAKEMINTTOKEN"
    private static let fakeClientKey = "FFEEDDCCBBAA99887766554433221100"

    override func setUp() {
        super.setUp()
        BodyCapturingStubURLProtocol.reset()
    }

    override func tearDown() {
        BodyCapturingStubURLProtocol.reset()
        super.tearDown()
    }

    @MainActor
    private func makeMinter(logSink: (@escaping (String) -> Void) = { _ in }) -> ApplicationKeyMinter {
        let minter = ApplicationKeyMinter(appendLog: logSink)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BodyCapturingStubURLProtocol.self]
        minter.sessionOverride = URLSession(configuration: config)
        // URLProtocol stubs cannot present a server trust for TOFU capture —
        // bypass the D-016 pin acquisition step for these offline tests.
        minter.pinAcquisitionOverride = { _ in true }
        return minter
    }

    private func stubSuccess(clientkey: String?) {
        let clientKeyPart = clientkey.map { ",\"clientkey\":\"\($0)\"" } ?? ""
        let body = "[{\"success\":{\"username\":\"\(Self.fakeToken)\"\(clientKeyPart)}}]"
        BodyCapturingStubURLProtocol.stubs["/api"] = (Data(body.utf8), 200)
    }

    private var bridge: BridgeEndpoint {
        BridgeEndpoint(name: "TestBridge", host: "192.0.2.10", port: 443)
    }

    // ──────────────────────────────────────────────
    // MARK: - Success paths
    // ──────────────────────────────────────────────

    @MainActor
    func testMintSuccessParsesTokenAndClientKey() async {
        stubSuccess(clientkey: Self.fakeClientKey)
        let minter = makeMinter()

        let result = await minter.mint(
            endpoint: bridge,
            devicetype: AppBrand.hueDeviceType,
            generateClientKey: true,
            expectedIdentity: nil
        )

        guard case .success(let minted) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(minted.token, Self.fakeToken)
        XCTAssertEqual(minted.clientKey, Self.fakeClientKey)
    }

    @MainActor
    func testGuestMintSendsGuestDevicetypeAndNoClientKeyRequest() async throws {
        stubSuccess(clientkey: nil)
        let minter = makeMinter()

        let segment = ApplicationKeyMinter.guestDeviceSegment(
            profileName: "Alex", profileID: "ABCD1234-0000-0000-0000-000000000000"
        )
        let result = await minter.mint(
            endpoint: bridge,
            devicetype: AppBrand.guestHueDeviceType(deviceSegment: segment),
            generateClientKey: false,
            expectedIdentity: nil
        )

        guard case .success(let minted) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertNil(minted.clientKey, "a guest mint must never yield a clientkey")

        let bodyData = try XCTUnwrap(BodyCapturingStubURLProtocol.capturedBodies.first)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        )
        XCTAssertEqual(json["generateclientkey"] as? Bool, false,
                       "guest keys mint with generateclientkey:false (design §7.3)")
        XCTAssertEqual(json["devicetype"] as? String, "chromaglow#g-alex-abcd")
    }

    // ──────────────────────────────────────────────
    // MARK: - Failure mapping
    // ──────────────────────────────────────────────

    @MainActor
    func testLinkButtonNotPressedMapsToBridgeRefused101() async {
        let refusal = "[{\"error\":{\"type\":101,\"address\":\"\",\"description\":\"link button not pressed\"}}]"
        BodyCapturingStubURLProtocol.stubs["/api"] = (Data(refusal.utf8), 200)
        let minter = makeMinter()

        let result = await minter.mint(
            endpoint: bridge,
            devicetype: AppBrand.hueDeviceType,
            generateClientKey: true,
            expectedIdentity: nil
        )

        guard case .failure(.bridgeRefused(let type, _)) = result else {
            return XCTFail("expected bridgeRefused, got \(result)")
        }
        XCTAssertEqual(type, 101)
    }

    @MainActor
    func testEmptyResponseArrayMapsToEmptyResponse() async {
        BodyCapturingStubURLProtocol.stubs["/api"] = (Data("[]".utf8), 200)
        let minter = makeMinter()

        let result = await minter.mint(
            endpoint: bridge,
            devicetype: AppBrand.hueDeviceType,
            generateClientKey: true,
            expectedIdentity: nil
        )

        guard case .failure(.emptyResponse) = result else {
            return XCTFail("expected emptyResponse, got \(result)")
        }
    }

    @MainActor
    func testExpectedIdentityMismatchRefuses() async {
        stubSuccess(clientkey: Self.fakeClientKey)
        var lines: [String] = []
        let minter = makeMinter(logSink: { lines.append($0) })

        // pinAcquisitionOverride leaves pairedCanonicalBridgeID nil, so ANY
        // expectation must refuse — the same shape as a QR naming a bridge
        // other than the one that answered.
        let result = await minter.mint(
            endpoint: bridge,
            devicetype: AppBrand.hueDeviceType,
            generateClientKey: true,
            expectedIdentity: (bridgeID: "ECB5FAFFFE123456",
                               publicKeySHA256: "bm90LWEtcmVhbC1waW4=")
        )

        guard case .failure(.expectedIdentityMismatch) = result else {
            return XCTFail("expected expectedIdentityMismatch, got \(result)")
        }
        XCTAssertTrue(lines.contains { $0.contains("Invite identity mismatch") })
        // H-04 posture: the refusal path must not have logged the key material.
        let joined = lines.joined(separator: "\n")
        XCTAssertFalse(joined.contains(Self.fakeToken))
        XCTAssertFalse(joined.contains(Self.fakeClientKey))
    }

    // ──────────────────────────────────────────────
    // MARK: - Guest device segment rules
    // ──────────────────────────────────────────────

    func testGuestDeviceSegmentIsBoundedAndCleanCharset() {
        let cases = [
            "Alex",
            "Alexandra Rosenberg-Smith the Third",
            "  spaced   out  name  ",
            "ÜmläutÉ Nâmé",
            "日本語の名前",
            "🎉🎉🎉",
            "",
        ]
        for name in cases {
            let segment = ApplicationKeyMinter.guestDeviceSegment(
                profileName: name, profileID: UUID().uuidString
            )
            XCTAssertLessThanOrEqual(segment.count, 19,
                                     "'\(name)' → '\(segment)' exceeds Hue's 19-char device segment")
            XCTAssertTrue(segment.hasPrefix("g-"), "'\(segment)' must mark a guest key")
            XCTAssertTrue(segment.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") },
                          "'\(name)' → '\(segment)' has characters outside [a-z0-9-]")
            XCTAssertFalse(segment.contains("--"), "'\(segment)' has a collapsed-dash violation")
        }
    }

    func testGuestDeviceSegmentEmptyNameFallsBackToGuest() {
        let segment = ApplicationKeyMinter.guestDeviceSegment(
            profileName: "🎉", profileID: "ABCD1234-0000-0000-0000-000000000000"
        )
        XCTAssertEqual(segment, "g-guest-abcd")
    }

    func testGuestDeviceSegmentDistinctProfilesGetDistinctSegments() {
        let a = ApplicationKeyMinter.guestDeviceSegment(
            profileName: "Sam", profileID: "AAAA0000-0000-0000-0000-000000000000"
        )
        let b = ApplicationKeyMinter.guestDeviceSegment(
            profileName: "Sam", profileID: "BBBB0000-0000-0000-0000-000000000000"
        )
        XCTAssertNotEqual(a, b, "same name, different profiles must yield distinct bridge identities")
    }
}
