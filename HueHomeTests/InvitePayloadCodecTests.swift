// InvitePayloadCodecTests.swift
// ChromaGlow — Share Invite (home-join)
//
// QR pixels are exercised with CIDetector, never VisionKit — the in-app
// scanner's neural inference context does not exist in the Simulator.

import XCTest
import CoreImage
@testable import HueHome

final class InvitePayloadCodecTests: XCTestCase {

    private func payload(bridgeCount: Int = 1) -> HomeJoinPayload {
        HomeJoinPayload(
            bridges: (0..<bridgeCount).map { i in
                SharedBridgeJoin(
                    bid: "ECB5FAFFFE12345\(i)",
                    host: "192.168.1.\(20 + i)",
                    port: 443,
                    name: "Bridge \(i + 1)",
                    pinPK: "q83vT3o0S3VfR2l0aHViQ29weXJpZ2h0MjAyNjZBQkNERUY="
                )
            },
            homeName: "Brian's Home",
            issuedAt: Date(timeIntervalSince1970: 1_780_000_000)
        )
    }

    // ── Round trip ────────────────────────────────────────

    func testRoundTripPreservesPayload() throws {
        let original = payload(bridgeCount: 2)
        let url = try InvitePayloadCodec.encode(original)
        let decoded = try InvitePayloadCodec.decode(url)
        XCTAssertEqual(decoded, original)
    }

    func testEncodeIsDeterministic() throws {
        let a = try InvitePayloadCodec.encode(payload())
        let b = try InvitePayloadCodec.encode(payload())
        XCTAssertEqual(a, b, "re-sharing the same home must produce the same QR")
    }

    func testPayloadCarriesNoSecrets() throws {
        // Structural guarantee: the wire type has no token/clientkey field.
        // Belt-and-braces: the raw JSON never contains those key names.
        let url = try InvitePayloadCodec.encode(payload())
        let blob = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            .queryItems!.first { $0.name == ScenePayloadCodec.queryKey }!.value!
        let json = try ScenePayloadCodec.decompress(ScenePayloadCodec.base64URLDecode(blob)!)
        let text = String(data: json, encoding: .utf8)!
        XCTAssertFalse(text.contains("token"))
        XCTAssertFalse(text.contains("clientkey"))
    }

    // ── Refusal discipline ────────────────────────────────

    func testDecodeRefusesUnknownVersion() throws {
        let url = try encodeRaw(#"{"v": 99, "kind": "home-join", "join": {"bridges": [], "homeName": "x", "issuedAt": "2026-07-10T00:00:00Z"}}"#)
        XCTAssertThrowsError(try InvitePayloadCodec.decode(url)) { error in
            XCTAssertEqual(error as? InvitePayloadError, .unsupportedVersion(99))
        }
    }

    func testDecodeRefusesWrongKind() throws {
        // A scene share link scanned into the invite flow must refuse cleanly.
        let url = try encodeRaw(#"{"v": 1, "kind": "composition", "scene": {}}"#)
        XCTAssertThrowsError(try InvitePayloadCodec.decode(url)) { error in
            XCTAssertEqual(error as? InvitePayloadError, .notAnInvite("composition"))
        }
    }

    func testDecodeRefusesEmptyBridgeList() throws {
        let url = try encodeRaw(#"{"v": 1, "kind": "home-join", "join": {"bridges": [], "homeName": "x", "issuedAt": "2026-07-10T00:00:00Z"}}"#)
        XCTAssertThrowsError(try InvitePayloadCodec.decode(url)) { error in
            XCTAssertEqual(error as? InvitePayloadError, .malformedPayload)
        }
    }

    func testDecodeRefusesForeignURL() {
        XCTAssertThrowsError(try InvitePayloadCodec.decode(URL(string: "https://example.com")!)) { error in
            XCTAssertEqual(error as? InvitePayloadError, .notAShareLink)
        }
    }

    // ── Scene codec unaffected + probe routing ────────────

    func testSceneDecoderRefusesInviteLinkWithItsOwnError() throws {
        let url = try InvitePayloadCodec.encode(payload())
        XCTAssertThrowsError(try ScenePayloadCodec.decode(url)) { error in
            XCTAssertEqual(error as? ScenePayloadError, .unsupportedKind("home-join"))
        }
    }

    func testProbeKindDistinguishesTheTwoFamilies() throws {
        let invite = try InvitePayloadCodec.encode(payload())
        let probed = try ScenePayloadCodec.probeKind(invite)
        XCTAssertEqual(probed.kind, "home-join")
        XCTAssertEqual(probed.v, 1)
    }

    // ── Size + QR pixels ──────────────────────────────────

    func testSingleBridgePayloadStaysComfortablySmall() throws {
        let url = try InvitePayloadCodec.encode(payload())
        XCTAssertLessThan(url.absoluteString.utf8.count, SceneQRRenderer.comfortableByteCount,
                          "a one-bridge invite must never be a dense QR")
    }

    func testFourBridgePayloadFitsLevelM() throws {
        let url = try InvitePayloadCodec.encode(payload(bridgeCount: 4))
        XCTAssertLessThan(url.absoluteString.utf8.count, SceneQRRenderer.byteCapacityLevelM)
    }

    func testQRPixelsRoundTripViaCIDetector() throws {
        let original = payload()
        let url = try InvitePayloadCodec.encode(original)
        let image = try SceneQRRenderer.render(url)

        guard let ci = CIImage(image: image),
              let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                        options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]),
              let feature = detector.features(in: ci).compactMap({ $0 as? CIQRCodeFeature }).first,
              let message = feature.messageString,
              let scanned = URL(string: message)
        else {
            return XCTFail("QR did not scan")
        }
        XCTAssertEqual(try InvitePayloadCodec.decode(scanned), original)
    }

    // ── Helpers ───────────────────────────────────────────

    private func encodeRaw(_ json: String) throws -> URL {
        let squeezed = try ScenePayloadCodec.compress(Data(json.utf8))
        var components = URLComponents()
        components.scheme = ScenePayloadCodec.scheme
        components.host = ScenePayloadCodec.host
        components.queryItems = [URLQueryItem(name: ScenePayloadCodec.queryKey,
                                              value: ScenePayloadCodec.base64URLEncode(squeezed))]
        return components.url!
    }
}
