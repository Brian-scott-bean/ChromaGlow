// GuestInvitePayloadCodecTests.swift
// ChromaGlow — Family Sharing Phase 2 (per-guest invite, token-bearing)
//
// QR pixels are exercised with CIDetector, never VisionKit — the in-app
// scanner's neural inference context does not exist in the Simulator.
// The token is EXPECTED in this payload (unlike home-join); what must be
// structurally impossible is a clientkey.

import XCTest
import CoreImage
@testable import HueHome

final class GuestInvitePayloadCodecTests: XCTestCase {

    private static let fakeToken = "FAKEGUESTTOKEN-abcdef0123456789-FAKEGUESTTOKEN"

    /// 24 fixed, high-entropy v2-shaped group ids (generated once, frozen) so
    /// four-bridge fixtures don't repeat ids across bridges.
    private static let groupIDBank: [String] = [
        "3f8a1c2e-9b47-4d05-8e16-72c9d4a0b511", "b0e2497d-16f3-48c8-a52e-cd80193f6a24",
        "7c15d8f0-2a9b-4e63-91d7-05b8e4c2a6f9", "e94b06a3-c7d1-4f28-b5a0-8619f3d27c4e",
        "52d7e9c8-04af-41b6-9e83-f6a20c15d97b", "a8f31b56-e0d9-4c72-8b14-3d95e7a60f28",
        "16c0d24a-58e7-4b39-af61-92d8b5e30c7f", "d43a97e1-6b28-40f5-83c9-e5017dab264c",
        "90b5f6d2-31c8-4a07-b94e-268a0d59e1f3", "68e1a30f-d597-4c41-a26b-04f7c8d3b592",
        "2b96c7d4-80e3-4f15-9d08-a1b64e29c750", "f507d1b8-49a2-4e60-bc37-58d90f16e2a4",
        "c1e84f92-7d05-4b38-a6f1-30c2d9587be6", "49a2b60d-e8f7-4153-97cd-b41e08a5f369",
        "8d30f5c1-26b9-4ea7-b085-79f4d1c2e603", "05c9e7a4-b1d8-4620-8f3b-e62a75d09c18",
        "71f4d203-9c6e-4b85-a1d9-04b8f5e6a327", "eb28a5c6-40d1-4f79-936e-8c507b2d1af4",
        "3a61e0b9-d24f-4c58-b7a2-f19c86e04d53", "9f75c2d8-13a6-4e04-8b5f-260d94a7c1e8",
        "60d8b4f1-a92c-4753-9e10-c58f27d3ab96", "b3279e0d-58c4-4a16-bd83-71f605c9e24a",
        "14e6a8c3-06bd-4972-853a-d90b1f7e4c25", "c85f0d67-e31a-4b09-a748-2fd6c19b0e53",
    ]

    private func grant(index: Int = 0,
                       token: String = GuestInvitePayloadCodecTests.fakeToken,
                       groupCount: Int = 6,
                       expiresAt: Date = Date(timeIntervalSince1970: 1_780_000_900)) -> SharedBridgeInviteGrant {
        SharedBridgeInviteGrant(
            bid: "ECB5FAFFFE12345\(index)",
            host: "192.168.1.\(20 + index)",
            port: 443,
            name: "Bridge \(index + 1)",
            pinPK: "q83vT3o0S3VfR2l0aHViQ29weXJpZ2h0MjAyNjZBQkNERUY=",
            token: token,
            // Deterministic fixture (testEncodeIsDeterministic re-builds the
            // payload) but with real-UUID entropy — patterned ids would
            // compress unrealistically well and hollow out the size gates.
            allowedGroups: (0..<groupCount).map {
                Self.groupIDBank[(index * 7 + $0) % Self.groupIDBank.count]
            },
            features: ["onOff", "brightness", "scenes"],
            expiresAt: expiresAt
        )
    }

    private func payload(bridgeCount: Int = 1) -> GuestInvitePayload {
        GuestInvitePayload(
            bridges: (0..<bridgeCount).map { grant(index: $0) },
            homeName: "Brian's Home",
            profileName: "Alex",
            issuedAt: Date(timeIntervalSince1970: 1_780_000_000)
        )
    }

    // ── Round trip ────────────────────────────────────────

    func testRoundTripPreservesPayload() throws {
        let original = payload(bridgeCount: 2)
        let url = try InvitePayloadCodec.encodeInvite(original)
        let decoded = try InvitePayloadCodec.decodeInvite(url)
        XCTAssertEqual(decoded, original)
    }

    func testEncodeIsDeterministic() throws {
        let a = try InvitePayloadCodec.encodeInvite(payload())
        let b = try InvitePayloadCodec.encodeInvite(payload())
        XCTAssertEqual(a, b)
    }

    func testPayloadCarriesTokenButStructurallyNoClientKey() throws {
        // The token is the point of this payload — but a clientkey must be
        // impossible: no field exists, and the raw JSON never contains the
        // key name in either Hue (clientkey) or Swift (clientKey) spelling.
        let url = try InvitePayloadCodec.encodeInvite(payload())
        let blob = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            .queryItems!.first { $0.name == ScenePayloadCodec.queryKey }!.value!
        let json = try ScenePayloadCodec.decompress(ScenePayloadCodec.base64URLDecode(blob)!)
        let text = String(data: json, encoding: .utf8)!
        XCTAssertTrue(text.contains(Self.fakeToken), "the minted guest key must ride the payload")
        XCTAssertFalse(text.lowercased().contains("clientkey"),
                       "an entertainment clientkey must never appear in any share payload")
    }

    // ── Refusal discipline ────────────────────────────────

    func testDecodeInviteRefusesUnknownVersion() throws {
        let url = try encodeRaw(#"{"v": 99, "kind": "invite", "invite": {}}"#)
        XCTAssertThrowsError(try InvitePayloadCodec.decodeInvite(url)) { error in
            XCTAssertEqual(error as? InvitePayloadError, .unsupportedVersion(99))
        }
    }

    func testDecodeInviteRefusesHomeJoinLink() throws {
        // The two invite kinds must refuse each other — a home-join QR
        // scanned where a token invite is expected fails closed.
        let homeJoin = HomeJoinPayload(
            bridges: [SharedBridgeJoin(bid: "ECB5FAFFFE123450", host: "192.168.1.20",
                                       port: 443, name: "Bridge",
                                       pinPK: "q83vT3o0S3VfR2l0aHViQ29weXJpZ2h0MjAyNjZBQkNERUY=")],
            homeName: "x", issuedAt: Date(timeIntervalSince1970: 1_780_000_000)
        )
        let url = try InvitePayloadCodec.encode(homeJoin)
        XCTAssertThrowsError(try InvitePayloadCodec.decodeInvite(url)) { error in
            XCTAssertEqual(error as? InvitePayloadError, .notAnInvite("home-join"))
        }
    }

    func testHomeJoinDecoderRefusesInviteLink() throws {
        let url = try InvitePayloadCodec.encodeInvite(payload())
        XCTAssertThrowsError(try InvitePayloadCodec.decode(url)) { error in
            XCTAssertEqual(error as? InvitePayloadError, .notAnInvite("invite"))
        }
    }

    func testSceneDecoderRefusesInviteLinkWithItsOwnError() throws {
        // Shipped builds' scene codec refuses gracefully — this is what makes
        // the new kind safe to encounter for old app versions.
        let url = try InvitePayloadCodec.encodeInvite(payload())
        XCTAssertThrowsError(try ScenePayloadCodec.decode(url)) { error in
            XCTAssertEqual(error as? ScenePayloadError, .unsupportedKind("invite"))
        }
    }

    func testDecodeInviteRefusesEmptyBridgeList() throws {
        let url = try encodeRaw(#"{"v": 1, "kind": "invite", "invite": {"bridges": [], "homeName": "x", "profileName": "p", "issuedAt": "2026-07-10T00:00:00Z"}}"#)
        XCTAssertThrowsError(try InvitePayloadCodec.decodeInvite(url)) { error in
            XCTAssertEqual(error as? InvitePayloadError, .malformedPayload)
        }
    }

    func testDecodeInviteRefusesEmptyToken() throws {
        var tokenless = payload()
        tokenless.bridges[0].token = ""
        let url = try InvitePayloadCodec.encodeInvite(tokenless)
        XCTAssertThrowsError(try InvitePayloadCodec.decodeInvite(url)) { error in
            XCTAssertEqual(error as? InvitePayloadError, .malformedPayload)
        }
    }

    func testDecodeInviteRefusesForeignURL() {
        XCTAssertThrowsError(try InvitePayloadCodec.decodeInvite(URL(string: "https://example.com")!)) { error in
            XCTAssertEqual(error as? InvitePayloadError, .notAShareLink)
        }
    }

    func testProbeKindRoutesInvite() throws {
        let url = try InvitePayloadCodec.encodeInvite(payload())
        let probed = try ScenePayloadCodec.probeKind(url)
        XCTAssertEqual(probed.kind, "invite")
        XCTAssertEqual(probed.v, 1)
    }

    // ── Expiry boundaries (pure) ──────────────────────────

    func testGrantValidJustInsideSkewGrace() {
        let expires = Date(timeIntervalSince1970: 1_780_000_900)
        let g = grant(expiresAt: expires)
        let now = expires.addingTimeInterval(InvitePayloadCodec.acceptSkewGrace - 1)
        XCTAssertFalse(g.isExpired(now: now))
    }

    func testGrantExpiredJustOutsideSkewGrace() {
        let expires = Date(timeIntervalSince1970: 1_780_000_900)
        let g = grant(expiresAt: expires)
        let now = expires.addingTimeInterval(InvitePayloadCodec.acceptSkewGrace + 1)
        XCTAssertTrue(g.isExpired(now: now))
    }

    func testPayloadExpiresOnlyWhenEveryBridgeDoes() {
        let early = Date(timeIntervalSince1970: 1_780_000_900)
        let late  = early.addingTimeInterval(3600)
        let mixed = GuestInvitePayload(
            bridges: [grant(index: 0, expiresAt: early), grant(index: 1, expiresAt: late)],
            homeName: "x", profileName: "p",
            issuedAt: Date(timeIntervalSince1970: 1_780_000_000)
        )
        let betweenThem = early.addingTimeInterval(InvitePayloadCodec.acceptSkewGrace + 60)
        XCTAssertFalse(mixed.isExpired(now: betweenThem),
                       "one live bridge keeps the invite acceptable")
        let afterBoth = late.addingTimeInterval(InvitePayloadCodec.acceptSkewGrace + 60)
        XCTAssertTrue(mixed.isExpired(now: afterBoth))
    }

    // ── Size + QR pixels ──────────────────────────────────

    func testSingleBridgeInviteStaysComfortablySmall() throws {
        // 1 bridge, 6 group UUIDs, 40+-char token — the realistic worst case
        // for a one-bridge home must render as a calm, scannable QR.
        let url = try InvitePayloadCodec.encodeInvite(payload())
        XCTAssertLessThan(url.absoluteString.utf8.count, SceneQRRenderer.comfortableByteCount)
    }

    func testFourBridgeInviteFitsLevelM() throws {
        let url = try InvitePayloadCodec.encodeInvite(payload(bridgeCount: 4))
        XCTAssertLessThan(url.absoluteString.utf8.count, SceneQRRenderer.byteCapacityLevelM)
    }

    func testQRPixelsRoundTripViaCIDetector() throws {
        let original = payload()
        let url = try InvitePayloadCodec.encodeInvite(original)
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
        XCTAssertEqual(try InvitePayloadCodec.decodeInvite(scanned), original)
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
