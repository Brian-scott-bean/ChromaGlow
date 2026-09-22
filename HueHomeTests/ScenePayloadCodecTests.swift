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

    // MARK: - Hostile payloads (audit #3)

    private func shareURL(json: String) throws -> URL {
        let blob = ScenePayloadCodec.base64URLEncode(try ScenePayloadCodec.compress(Data(json.utf8)))
        return try XCTUnwrap(URL(string: "lightshade://share?d=\(blob)"))
    }

    /// A hand-crafted link used to reach the engine unclamped: Int.min
    /// temperature overflowed `temperature - 153`, a negative chase offset
    /// made `0..<heads` an invalid range, a huge step `bars` overflowed
    /// `bars * beatsPerBar`, a vanishing `quantizeBeats` trapped an `Int`
    /// conversion, and an unclamped BPM ran past the flash ceiling.
    func testAHostileShareLinkDecodesClampedToTheAuthoringRanges() throws {
        let json = """
        {"v":1,"kind":"composition","scene":{
          "name":"Hostile","icon":"sparkles","accentColorHex":"#FF0000","category":"Ambient",
          "seasonMonths":[0,6,99],
          "palette":{"mode":"temperature","temperature":-9223372036854775808,
                     "color1":{"x":-5,"y":1e300},"color2":{"x":0.5,"y":0.4},
                     "hueShift":1e308,"saturation":-1e308},
          "motion":{"pattern":"chase","speed":1e308,"spread":-1e308,"offset":-1e308,
                    "motionAngle":1e308},
          "envelope":{"shape":"pulse","bpm":100000,"depth":500,"attack":-3,"decay":1e9,
                      "dutyCycle":0,"minBrightness":-10,"maxBrightness":1e6},
          "reaction":{"source":"beat","sensitivity":1e308,"smoothing":-1,"intensity":1e308,
                      "threshold":1e308,"quantizeBeats":1e-300,"colorStepPerTrigger":1e308,
                      "motionBeatsPerCycle":1e-300,"punchDecay":-1e308},
          "sequence":{"loops":true,"steps":[
             {"name":"Evil","bars":9223372036854775807,"crossfadeBeats":9223372036854775807,
              "envelope":{"bpm":1e308},"motion":{"pattern":"chase","offset":-1e308}}]}
        }}
        """
        let scene = try ScenePayloadCodec.decode(try shareURL(json: json))

        XCTAssertTrue((153...500).contains(scene.palette.temperature))
        XCTAssertTrue((0...1).contains(scene.palette.color1.x))
        XCTAssertTrue((0...1).contains(scene.palette.color1.y))
        XCTAssertEqual(scene.palette.hueShift, 180)
        XCTAssertEqual(scene.palette.saturation, 0)
        XCTAssertEqual(scene.motion.speed, 100)
        XCTAssertEqual(scene.motion.spread, 0)
        XCTAssertEqual(scene.motion.offset, 0)
        XCTAssertTrue((0..<360).contains(scene.motion.motionAngle))
        XCTAssertEqual(scene.envelope.bpm, 240, "the authoring flash ceiling holds")
        XCTAssertEqual(scene.envelope.depth, 100)
        XCTAssertEqual(scene.envelope.attack, 0)
        XCTAssertEqual(scene.envelope.decay, 100)
        XCTAssertEqual(scene.envelope.dutyCycle, 10)
        XCTAssertEqual(scene.envelope.minBrightness, 0)
        XCTAssertEqual(scene.envelope.maxBrightness, 100)
        XCTAssertEqual(scene.reaction.sensitivity, 100)
        XCTAssertEqual(scene.reaction.smoothing, 0)
        XCTAssertEqual(scene.reaction.quantizeBeats, 0.25)
        XCTAssertEqual(scene.reaction.colorStepPerTrigger, 1)
        XCTAssertEqual(scene.reaction.motionBeatsPerCycle, 1)
        XCTAssertEqual(scene.reaction.punchDecay, 0)
        XCTAssertEqual(scene.seasonMonths, [6])
        let step = try XCTUnwrap(scene.sequence?.steps.first)
        XCTAssertEqual(step.bars, 32)
        XCTAssertEqual(step.crossfadeBeats, 16)
        XCTAssertEqual(step.envelope.bpm, 240)
        XCTAssertEqual(step.motion.offset, 0)

        // The formerly trapping paths now run.
        _ = scene.palette.color(at: 0.5)
        _ = scene.motion.sample(position: 0.3, radial: nil, angular: nil, lightIndex: 0, time: 1)
        _ = step.motion.sample(position: 0.3, radial: nil, angular: nil, lightIndex: 1, time: 2)

        // And what reaches the library is the clamped scene.
        let preset = scene.makePreset()
        XCTAssertEqual(preset.envelope.bpm, 240)
        XCTAssertEqual(preset.sequence?.steps.first?.bars, 32)
    }

    /// `makePreset` sanitizes on its own, whatever produced the scene.
    func testMakePresetClampsAnUnsanitizedScene() {
        var hostile = samplePreset
        hostile.palette.temperature = Int.min
        hostile.motion.offset = -1e9
        hostile.envelope.bpm = 1e9
        hostile.reaction.quantizeBeats = 0
        let preset = SharedScene(preset: hostile).makePreset()
        XCTAssertEqual(preset.palette.temperature, 153)
        XCTAssertEqual(preset.motion.offset, 0)
        XCTAssertEqual(preset.envelope.bpm, 240)
        XCTAssertEqual(preset.reaction.quantizeBeats, 0.25)
    }

    /// Sanitizing is a no-op on everything the app itself authors: every
    /// built-in survives it unchanged (so a share round trip stays exact).
    func testSanitizingLeavesEveryBuiltInUntouched() {
        for preset in CompositionStore.builtInPresets {
            let scene = SharedScene(preset: preset)
            XCTAssertEqual(scene.sanitizedForImport(), scene, preset.name)
        }
    }
}

// MARK: - Scene list palette decode (true-color previews)

/// The scene LIST decode gained a tolerant `palette` field for true-color
/// previews. The load-bearing rule stands: listing must never depend on
/// palette (or any optional field) decoding — only id/metadata/group can
/// fail an element.
final class HueScenePaletteDecodeTests: XCTestCase {

    private func decodeScene(_ json: String) throws -> HueScene {
        try JSONDecoder().decode(HueScene.self, from: Data(json.utf8))
    }

    func testGarbagePaletteNeverBreaksSceneDecoding() throws {
        let json = """
        {"id":"s1","metadata":{"name":"Calm"},"group":{"rid":"r1","rtype":"room"},
         "palette": {"color": "THIS SHOULD BE AN ARRAY"}}
        """
        let scene = try decodeScene(json)
        XCTAssertEqual(scene.id, "s1")
        XCTAssertNil(scene.palette)
        XCTAssertTrue(scene.paletteXY.isEmpty)
    }

    func testWellFormedPaletteExtractsUpToThreePoints() throws {
        let json = """
        {"id":"s2","metadata":{"name":"Sunset"},"group":{"rid":"r1","rtype":"room"},
         "speed":0.7,
         "palette":{"color":[
            {"color":{"xy":{"x":0.55,"y":0.39}},"dimming":{"brightness":80}},
            {"color":{"xy":{"x":0.64,"y":0.33}},"dimming":{"brightness":60}},
            {"color":{"xy":{"x":0.31,"y":0.32}},"dimming":{"brightness":40}},
            {"color":{"xy":{"x":0.20,"y":0.20}},"dimming":{"brightness":20}}
         ]}}
        """
        let scene = try decodeScene(json)
        let xy = scene.paletteXY
        XCTAssertEqual(xy.count, 3, "previews cap at 3 points")
        XCTAssertEqual(xy[0].x, 0.55, accuracy: 0.0001)
        XCTAssertEqual(xy[2].y, 0.32, accuracy: 0.0001)
        XCTAssertEqual(scene.speed ?? 0, 0.7, accuracy: 0.0001)
    }

    func testMissingRequiredFieldStillFailsTheElement() {
        let json = #"{"metadata":{"name":"NoID"},"group":{"rid":"r","rtype":"room"}}"#
        XCTAssertThrowsError(try decodeScene(json))
    }
}
