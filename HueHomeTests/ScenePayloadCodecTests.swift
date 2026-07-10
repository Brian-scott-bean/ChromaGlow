// ScenePayloadCodecTests.swift
// ChromaGlow — scene sharing
//
// The share link is the only copy of a shared scene, so the round trip has to
// be exact and the failure modes have to be loud. These tests also measure the
// real built-in catalog against QR capacity — if a future preset grows past it,
// the size test says so before a user finds a blank square in the share sheet.

import XCTest
@testable import HueHome

final class ScenePayloadCodecTests: XCTestCase {

    private var samplePreset: CompositionPreset {
        CompositionStore.builtInPresets.first { $0.name == "Northern Lights" }
            ?? CompositionStore.builtInPresets[0]
    }

    // MARK: - Round trip

    func testRoundTripPreservesEveryDesignField() throws {
        let original = samplePreset
        let url = try ScenePayloadCodec.encode(original)
        let decoded = try ScenePayloadCodec.decode(url)

        XCTAssertEqual(decoded, SharedScene(preset: original))
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.palette, original.palette)
        XCTAssertEqual(decoded.motion, original.motion)
        XCTAssertEqual(decoded.envelope, original.envelope)
        XCTAssertEqual(decoded.reaction, original.reaction)
        XCTAssertEqual(decoded.preferredTransport, original.preferredTransport)
    }

    func testEveryBuiltInPresetRoundTrips() throws {
        for preset in CompositionStore.builtInPresets {
            let url = try ScenePayloadCodec.encode(preset)
            let decoded = try ScenePayloadCodec.decode(url)
            XCTAssertEqual(decoded, SharedScene(preset: preset), preset.name)
        }
    }

    /// The same scene must always produce the same link — a re-share should look
    /// like the same QR, not a new one.
    func testEncodingIsDeterministic() throws {
        let preset = samplePreset
        let a = try ScenePayloadCodec.encode(preset)
        let b = try ScenePayloadCodec.encode(preset)
        XCTAssertEqual(a, b)
    }

    // MARK: - Identity is not shared

    /// A shared scene arrives as the receiver's own creation. It must not carry
    /// the sender's id (which would overwrite their preset of the same id), nor
    /// claim to be built-in, nor leak the prompt that generated it.
    func testImportedSceneGetsFreshIdentityAndDropsProvenance() throws {
        var original = samplePreset
        original.aiPrompt = "a secret prompt"
        original.providerModel = "some-model"
        XCTAssertTrue(original.isBuiltIn, "precondition: sample is a built-in")

        let decoded = try ScenePayloadCodec.decode(try ScenePayloadCodec.encode(original))
        let imported = decoded.makePreset()

        XCTAssertNotEqual(imported.id, original.id)
        XCTAssertFalse(imported.isBuiltIn)
        XCTAssertNil(imported.aiPrompt)
        XCTAssertNil(imported.providerModel)
        XCTAssertEqual(imported.name, original.name)
        XCTAssertEqual(imported.palette, original.palette)
    }

    func testTwoImportsOfTheSameLinkDoNotCollide() throws {
        let url = try ScenePayloadCodec.encode(samplePreset)
        let first = try ScenePayloadCodec.decode(url).makePreset()
        let second = try ScenePayloadCodec.decode(url).makePreset()
        XCTAssertNotEqual(first.id, second.id)
    }

    // MARK: - Rejection

    func testRejectsForeignSchemeAndHost() {
        for raw in ["https://example.com/share?d=abc",
                    "lightshade://room/42",
                    "lightshade://share",
                    "lightshade://share?d="] {
            let url = URL(string: raw)!
            XCTAssertThrowsError(try ScenePayloadCodec.decode(url), raw) { error in
                XCTAssertEqual(error as? ScenePayloadError, .notAShareLink, raw)
            }
        }
    }

    func testRejectsGarbagePayload() {
        let url = URL(string: "lightshade://share?d=not-real-base64-zlib")!
        XCTAssertThrowsError(try ScenePayloadCodec.decode(url)) { error in
            XCTAssertEqual(error as? ScenePayloadError, .malformedPayload)
        }
    }

    /// Truncation must fail loudly. A half-decompressed scene that "mostly
    /// works" is worse than a refusal.
    func testRejectsTruncatedPayload() throws {
        let url = try ScenePayloadCodec.encode(samplePreset)
        let blob = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            .queryItems!.first(where: { $0.name == "d" })!.value!
        let truncated = String(blob.prefix(blob.count / 2))
        let bad = URL(string: "lightshade://share?d=\(truncated)")!

        XCTAssertThrowsError(try ScenePayloadCodec.decode(bad)) { error in
            XCTAssertEqual(error as? ScenePayloadError, .malformedPayload)
        }
    }

    /// A v2 producer must not be silently misread as v1.
    func testRejectsFutureVersionInsteadOfGuessing() throws {
        let json = #"{"v":2,"kind":"composition","scene":{}}"#.data(using: .utf8)!
        let blob = ScenePayloadCodec.base64URLEncode(try ScenePayloadCodec.compress(json))
        let url = URL(string: "lightshade://share?d=\(blob)")!

        XCTAssertThrowsError(try ScenePayloadCodec.decode(url)) { error in
            XCTAssertEqual(error as? ScenePayloadError, .unsupportedVersion(2))
        }
    }

    func testRejectsUnknownKind() throws {
        let json = #"{"v":1,"kind":"bridge_scene","scene":{}}"#.data(using: .utf8)!
        let blob = ScenePayloadCodec.base64URLEncode(try ScenePayloadCodec.compress(json))
        let url = URL(string: "lightshade://share?d=\(blob)")!

        XCTAssertThrowsError(try ScenePayloadCodec.decode(url)) { error in
            XCTAssertEqual(error as? ScenePayloadError, .unsupportedKind("bridge_scene"))
        }
    }

    // MARK: - base64url

    func testBase64URLIsQuerySafeAndReversible() throws {
        // Every byte value, so `+` and `/` are guaranteed to appear pre-substitution.
        let data = Data((0...255).map { UInt8($0) })
        let encoded = ScenePayloadCodec.base64URLEncode(data)

        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains("="))
        XCTAssertEqual(ScenePayloadCodec.base64URLDecode(encoded), data)
    }

    func testBase64URLDecodeHandlesEveryPaddingLength() {
        for length in 1...8 {
            let data = Data(repeating: 0xAB, count: length)
            let encoded = ScenePayloadCodec.base64URLEncode(data)
            XCTAssertEqual(ScenePayloadCodec.base64URLDecode(encoded), data, "length \(length)")
        }
    }

    // MARK: - Size

    /// The whole shipped catalog must fit in a QR, and comfortably — a symbol
    /// near the capacity ceiling scans badly off a glossy phone screen. This is
    /// the test that fires when someone adds a preset with a long sequence.
    func testEveryBuiltInPresetFitsComfortablyInAQRCode() throws {
        var worst = (name: "", bytes: 0)
        for preset in CompositionStore.builtInPresets {
            let bytes = try ScenePayloadCodec.encode(preset).absoluteString.utf8.count
            if bytes > worst.bytes { worst = (preset.name, bytes) }

            XCTAssertLessThanOrEqual(
                bytes, SceneQRRenderer.byteCapacityLevelM,
                "\(preset.name) encodes to \(bytes)B, past level-M QR capacity")
        }
        XCTAssertLessThanOrEqual(
            worst.bytes, SceneQRRenderer.comfortableByteCount,
            "largest built-in is '\(worst.name)' at \(worst.bytes)B — past the "
            + "\(SceneQRRenderer.comfortableByteCount)B comfortable scan budget")
    }

    /// Compression is load-bearing for QR capacity, not a nicety.
    func testCompressionMeaningfullyShrinksAPreset() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let raw = try encoder.encode(SharedScene(preset: samplePreset))
        let squeezed = try ScenePayloadCodec.compress(raw)

        XCTAssertLessThan(squeezed.count, raw.count)
        XCTAssertEqual(try ScenePayloadCodec.decompress(squeezed), raw)
    }
}
