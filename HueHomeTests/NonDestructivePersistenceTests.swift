// NonDestructivePersistenceTests.swift
// HueHome Pro — Unit Tests
//
// Regression guards for audit findings M-13 / L-27 (data-loss on decode):
//  - CompositionStore.load(): one malformed element preserves the rest,
//    writes a timestamped .bak, and NEVER overwrites compositions.json on a
//    decode error (the old catch reseeded built-ins over the user's library).
//  - An old-schema preset missing late-added sub-config fields (e.g.
//    MotionConfig.motionAngle) decodes with defaults — no reseed.
//  - HueV2Response decodes `data` leniently: one malformed resource is
//    skipped instead of blanking the whole fetch.
//
// Audit: docs/audit/hardening-audit-2026-07-01.md §6 "Model decoding & crash-safety".

import XCTest
@testable import HueHome

@MainActor
final class NonDestructivePersistenceTests: XCTestCase {

    private var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("compositions.json")
    }
    private var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Snapshot of the real compositions.json (test host shares the app's
    /// Documents directory) so this suite never clobbers real data.
    private var savedFileData: Data?
    private var preexistingBackups: Set<String> = []

    override func setUp() {
        super.setUp()
        savedFileData = try? Data(contentsOf: fileURL)
        preexistingBackups = currentBackupNames()
    }

    override func tearDown() {
        if let savedFileData {
            try? savedFileData.write(to: fileURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: fileURL)
        }
        // Remove any backups this suite created.
        for name in currentBackupNames().subtracting(preexistingBackups) {
            try? FileManager.default.removeItem(at: documentsURL.appendingPathComponent(name))
        }
        super.tearDown()
    }

    private func currentBackupNames() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: documentsURL.path)) ?? []
        return Set(names.filter { $0.hasPrefix("compositions-") && $0.hasSuffix(".bak") })
    }

    private func newBackups() -> Set<String> {
        currentBackupNames().subtracting(preexistingBackups)
    }

    /// Minimal valid preset JSON the current schema accepts.
    private func validPresetJSON(name: String) -> String {
        """
        {
          "id": "\(UUID().uuidString)",
          "name": "\(name)",
          "icon": "sparkles",
          "accentColorHex": "#FFAA33",
          "isBuiltIn": false,
          "category": "Ambient",
          "palette": {},
          "motion": {},
          "envelope": {},
          "reaction": {},
          "createdAt": 700000000,
          "updatedAt": 700000000
        }
        """
    }

    // ──────────────────────────────────────────────
    // MARK: - M-13: one malformed element preserves the rest
    // ──────────────────────────────────────────────

    func testMalformedElementPreservesRestWritesBackupAndNeverOverwritesSource() throws {
        let json = "[\(validPresetJSON(name: "Keep Me")), 42, \(validPresetJSON(name: "Keep Me Too"))]"
        let original = Data(json.utf8)
        try original.write(to: fileURL, options: .atomic)

        let store = CompositionStore()

        XCTAssertTrue(store.presets.contains { $0.name == "Keep Me" })
        XCTAssertTrue(store.presets.contains { $0.name == "Keep Me Too" })
        XCTAssertEqual(try Data(contentsOf: fileURL), original,
                       "the source file must NEVER be overwritten on a decode problem (M-13)")
        XCTAssertFalse(newBackups().isEmpty,
                       "a timestamped .bak must be written when elements are dropped")
    }

    func testTotalDecodeFailureBacksUpAndDoesNotPersistDefaults() throws {
        let original = Data("THIS IS NOT JSON".utf8)
        try original.write(to: fileURL, options: .atomic)

        let store = CompositionStore()

        XCTAssertFalse(store.presets.isEmpty, "store runs on built-ins in memory")
        XCTAssertEqual(try Data(contentsOf: fileURL), original,
                       "reseed must not touch the source file — that was the data-loss path")
        XCTAssertFalse(newBackups().isEmpty)
    }

    // ──────────────────────────────────────────────
    // MARK: - M-13: old-schema JSON (missing sub-config fields) must not reseed
    // ──────────────────────────────────────────────

    func testOldSchemaPresetMissingSubConfigFieldsDecodesWithDefaults() throws {
        // Old-schema motion: missing the late-added motionAngle; palette
        // missing randomize/harmonyRule — exactly the git-history drift that
        // used to fail keyNotFound and wipe the library.
        let oldSchema = """
        [{
          "id": "\(UUID().uuidString)",
          "name": "Legacy Preset",
          "icon": "sparkles",
          "accentColorHex": "#AA33FF",
          "isBuiltIn": false,
          "category": "Energetic",
          "palette": {"mode": "solid", "color1": {"x": 0.5, "y": 0.4}},
          "motion": {"pattern": "wave", "speed": 55},
          "envelope": {"shape": "pulse", "bpm": 100},
          "reaction": {"source": "none"},
          "createdAt": 700000000,
          "updatedAt": 700000000
        }]
        """
        let original = Data(oldSchema.utf8)
        try original.write(to: fileURL, options: .atomic)

        let store = CompositionStore()

        let legacy = try XCTUnwrap(store.presets.first { $0.name == "Legacy Preset" },
                                   "old-schema preset must survive the upgrade — no reseed")
        XCTAssertEqual(legacy.motion.pattern, .wave)
        XCTAssertEqual(legacy.motion.speed, 55)
        XCTAssertEqual(legacy.motion.motionAngle, -1, "late-added field takes its default")
        XCTAssertEqual(legacy.palette.mode, .solid)
        XCTAssertEqual(legacy.palette.randomize, false)
        XCTAssertEqual(legacy.envelope.shape, .pulse)
        XCTAssertTrue(newBackups().isEmpty, "a clean lenient decode must not trigger a backup")
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
    }

    // ──────────────────────────────────────────────
    // MARK: - Round-trip: current schema encodes/decodes losslessly
    // ──────────────────────────────────────────────

    func testSubConfigRoundTripPreservesValues() throws {
        let palette = PaletteConfig(mode: .spectrum, hueShift: 45, saturation: 80, randomize: true)
        let motion = MotionConfig(pattern: .bounce, speed: 90, motionAngle: 180)
        let envelope = EnvelopeConfig(shape: .flicker, bpm: 120, minBrightness: 5)
        let reaction = ReactionConfig(source: .micBass, targets: [.color, .speed])

        let decoder = JSONDecoder(), encoder = JSONEncoder()
        XCTAssertEqual(try decoder.decode(PaletteConfig.self, from: encoder.encode(palette)), palette)
        XCTAssertEqual(try decoder.decode(MotionConfig.self, from: encoder.encode(motion)), motion)
        XCTAssertEqual(try decoder.decode(EnvelopeConfig.self, from: encoder.encode(envelope)), envelope)
        XCTAssertEqual(try decoder.decode(ReactionConfig.self, from: encoder.encode(reaction)), reaction)
    }

    // ──────────────────────────────────────────────
    // MARK: - L-27: HueV2Response tolerates one malformed element
    // ──────────────────────────────────────────────

    func testHueV2ResponseSkipsMalformedElement() throws {
        let json = """
        {
          "errors": [],
          "data": [
            {"id": "light-1", "metadata": {"name": "Good"}, "on": {"on": true}},
            {"id": "light-2"},
            {"id": "light-3", "metadata": {"name": "Also Good"}, "on": {"on": false}}
          ]
        }
        """
        let response = try JSONDecoder().decode(HueV2Response<HueLight>.self, from: Data(json.utf8))
        XCTAssertEqual(response.data.map(\.id), ["light-1", "light-3"],
                       "one malformed light must be skipped, not blank the fetch (L-27)")
    }

    func testHueV2ResponseToleratesMissingErrorsKey() throws {
        let json = """
        {"data": [{"id": "light-1", "metadata": {"name": "L"}, "on": {"on": true}}]}
        """
        let response = try JSONDecoder().decode(HueV2Response<HueLight>.self, from: Data(json.utf8))
        XCTAssertEqual(response.data.count, 1)
        XCTAssertTrue(response.errors.isEmpty)
    }
}
