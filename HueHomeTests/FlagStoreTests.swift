// FlagStoreTests.swift
// ChromaGlow — Composer 2 Phase 1A
//
// Proves the FlagStore contract: defaults preserve shipped behavior,
// overrides are tri-state (missing ≠ false), reset touches only flag
// keys, suites are isolated, and nothing in production consumes the
// store yet. Tests never touch the standard user-defaults domain —
// every store gets its own uniquely named suite, removed in teardown.

import XCTest
@testable import HueHome

@MainActor
final class FlagStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: FlagStore!

    override func setUp() {
        super.setUp()
        suiteName = "FlagStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = FlagStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        store = nil
        suiteName = nil
        super.tearDown()
    }

    // 1. Documented defaults preserve current production behavior.
    func testDefaultsAreAllFalsePreservingCurrentBehavior() {
        for flag in Composer2Flag.allCases {
            XCTAssertFalse(flag.defaultValue,
                           "\(flag) must default to the shipped code path (false)")
            XCTAssertFalse(store.isEnabled(flag))
        }
    }

    // 2. A missing override resolves to the default.
    func testMissingOverrideResolvesToDefault() {
        for flag in Composer2Flag.allCases {
            XCTAssertNil(store.override(for: flag))
            XCTAssertEqual(store.isEnabled(flag), flag.defaultValue)
        }
    }

    // 3. A true override persists and reads back.
    func testTrueOverridePersistsAndReads() {
        store.setOverride(true, for: .perBridgeScheduler)
        XCTAssertEqual(store.override(for: .perBridgeScheduler), true)
        XCTAssertTrue(store.isEnabled(.perBridgeScheduler))

        let rereader = FlagStore(defaults: defaults)
        XCTAssertTrue(rereader.isEnabled(.perBridgeScheduler))
    }

    // 4. A false override persists, reads back, and is distinct from missing.
    func testFalseOverridePersistsAndReadsDistinctFromMissing() {
        store.setOverride(false, for: .oklabInterpolation)
        XCTAssertEqual(store.override(for: .oklabInterpolation), false,
                       "a stored false is an override, not a missing value")
        XCTAssertFalse(store.isEnabled(.oklabInterpolation))
        XCTAssertNil(store.override(for: .transportPlanner),
                     "an untouched flag stays missing, not false")
    }

    // 5. Clearing one override restores its default.
    func testClearingOneOverrideRestoresDefault() {
        store.setOverride(true, for: .arbiterEnforcement)
        store.setOverride(true, for: .transportPlanner)
        store.clearOverride(for: .arbiterEnforcement)

        XCTAssertNil(store.override(for: .arbiterEnforcement))
        XCTAssertEqual(store.isEnabled(.arbiterEnforcement),
                       Composer2Flag.arbiterEnforcement.defaultValue)
        XCTAssertEqual(store.override(for: .transportPlanner), true,
                       "clearing one flag must not clear another")
    }

    // 6. Resetting all overrides restores every documented default.
    func testResettingAllOverridesRestoresEveryDefault() {
        for flag in Composer2Flag.allCases {
            store.setOverride(!flag.defaultValue, for: flag)
        }
        store.resetAllOverrides()
        for flag in Composer2Flag.allCases {
            XCTAssertNil(store.override(for: flag))
            XCTAssertEqual(store.isEnabled(flag), flag.defaultValue)
        }
    }

    // 7. One injected suite cannot leak into another.
    func testInjectedSuitesDoNotLeakBetweenEachOther() throws {
        let otherName = "FlagStoreTests-\(UUID().uuidString)"
        let otherDefaults = try XCTUnwrap(UserDefaults(suiteName: otherName))
        defer { otherDefaults.removePersistentDomain(forName: otherName) }
        let otherStore = FlagStore(defaults: otherDefaults)

        store.setOverride(true, for: .explicitOffSemantics)

        XCTAssertNil(otherStore.override(for: .explicitOffSemantics))
        XCTAssertFalse(otherStore.isEnabled(.explicitOffSemantics))
    }

    // 8. This test file never touches the standard defaults domain.
    //    (Structural: the source must not contain the standard-domain
    //    accessor; the literal is split so this guard cannot match itself.)
    func testFlagStoreTestsNeverTouchStandardUserDefaults() throws {
        let source = try String(contentsOfFile: #filePath, encoding: .utf8)
        let forbidden = "UserDefaults" + ".standard"
        XCTAssertFalse(source.contains(forbidden),
                       "FlagStoreTests must only use injected suites")
    }

    // 9. Stable production raw keys match the approved contract verbatim.
    func testStableProductionRawKeysMatchApprovedContract() {
        let approved: [Composer2Flag: String] = [
            .oklabInterpolation:   "castchroma.flag.oklabInterpolation",
            .explicitOffSemantics: "castchroma.flag.explicitOffSemantics",
            .perBridgeScheduler:   "castchroma.flag.perBridgeScheduler",
            .arbiterEnforcement:   "castchroma.flag.arbiterEnforcement",
            .transportPlanner:     "castchroma.flag.transportPlanner",
        ]
        XCTAssertEqual(Set(Composer2Flag.allCases), Set(approved.keys),
                       "every flag must appear in the approved key list")
        for (flag, key) in approved {
            XCTAssertEqual(flag.rawValue, key,
                           "persisted keys are append-only and must never drift")
        }
    }

    // 10. A flag reset never removes unrelated keys from the suite.
    func testResetPreservesUnrelatedKeys() {
        defaults.set("keep-me", forKey: "castchroma.unrelated.key")
        defaults.set(7, forKey: "some.other.subsystem")
        for flag in Composer2Flag.allCases {
            store.setOverride(true, for: flag)
        }

        store.resetAllOverrides()

        XCTAssertEqual(defaults.string(forKey: "castchroma.unrelated.key"), "keep-me")
        XCTAssertEqual(defaults.integer(forKey: "some.other.subsystem"), 7)
    }

    // 11. Constructing and reading the store writes nothing.
    func testConstructingAndReadingWritesNothing() {
        let before = defaults.persistentDomain(forName: suiteName) ?? [:]

        let freshStore = FlagStore(defaults: defaults)
        for flag in Composer2Flag.allCases {
            _ = freshStore.isEnabled(flag)
            _ = freshStore.override(for: flag)
        }

        let after = defaults.persistentDomain(forName: suiteName) ?? [:]
        XCTAssertEqual(Set(before.keys), Set(after.keys),
                       "reads must not create keys")
        for flag in Composer2Flag.allCases {
            XCTAssertNil(after[flag.rawValue])
        }
    }

    // 12. No production code consumes the store in this packet: the only
    //     production source mentioning FlagStore is its own definition.
    func testNoProductionCodeConsumesFlagStoreYet() throws {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let productionRoot = testsDir.deletingLastPathComponent()
            .appendingPathComponent("HueHome")
        var isDirectory: ObjCBool = false
        let rootExists = FileManager.default.fileExists(atPath: productionRoot.path,
                                                        isDirectory: &isDirectory)
        XCTAssertTrue(rootExists && isDirectory.boolValue,
                      "production-source root must resolve; the scan is the proof")

        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: productionRoot, includingPropertiesForKeys: nil))
        var scannedCount = 0
        var sawDefinition = false
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            scannedCount += 1
            guard url.lastPathComponent != "FlagStore.swift" else {
                sawDefinition = true
                continue
            }
            if source.contains("FlagStore") || source.contains("Composer2Flag") {
                offenders.append(url.lastPathComponent)
            }
        }
        XCTAssertGreaterThan(scannedCount, 0,
                             "an empty scan proves nothing — the walk must cover sources")
        XCTAssertTrue(sawDefinition,
                      "the scan must have visited FlagStore.swift itself")
        XCTAssertTrue(offenders.isEmpty,
                      "no consumer is authorized in Phase 1A: \(offenders)")
    }
}
