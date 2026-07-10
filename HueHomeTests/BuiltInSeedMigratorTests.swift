// BuiltInSeedMigratorTests.swift
// ChromaGlow — Composer library
//
// This code decides whether to overwrite something in a user's library, so the
// tests that matter most are the ones that prove it doesn't. A preset the user
// renamed, retuned, or built themselves must come out the other side untouched,
// no matter what the shipped catalog says.

import XCTest
@testable import HueHome

final class BuiltInSeedMigratorTests: XCTestCase {

    private typealias Migrator = BuiltInSeedMigrator

    // MARK: - Fixtures

    private func makeBuiltIn(
        id: UUID = UUID(),
        name: String = "Shipped",
        speed: Double = 40,
        createdAt: Date = Date(timeIntervalSince1970: 1_000_000)
    ) -> CompositionPreset {
        CompositionPreset(
            id: id, name: name, icon: "sparkles", accentColorHex: "#FFB84D",
            isBuiltIn: true, category: .ambient, seasonMonths: nil,
            palette: PaletteConfig(),
            motion: MotionConfig(speed: speed),
            envelope: EnvelopeConfig(),
            reaction: ReactionConfig(),
            createdAt: createdAt, updatedAt: createdAt   // seeded: equal timestamps
        )
    }

    private func edited(_ preset: CompositionPreset, by seconds: TimeInterval = 60) -> CompositionPreset {
        var copy = preset
        copy.updatedAt = preset.createdAt.addingTimeInterval(seconds)
        return copy
    }

    // MARK: - Adding

    func testAPresetShippedAfterTheFileWasWrittenIsAdded() {
        let old = makeBuiltIn(name: "Ocean Drift")
        let new = makeBuiltIn(name: "Nebula Drift")

        let result = Migrator.migrate(stored: [old], builtIns: [old, new])

        XCTAssertEqual(result.presets.count, 2)
        XCTAssertEqual(result.added, ["Nebula Drift"])
        XCTAssertTrue(result.didChange)
        XCTAssertTrue(result.presets.contains { $0.id == new.id })
    }

    func testAddingIsIdempotentAcrossLaunches() {
        let old = makeBuiltIn(name: "Ocean Drift")
        let new = makeBuiltIn(name: "Nebula Drift")

        let first = Migrator.migrate(stored: [old], builtIns: [old, new])
        let second = Migrator.migrate(stored: first.presets, builtIns: [old, new])

        XCTAssertEqual(second.presets.count, 2, "a second launch duplicated the catalog")
        XCTAssertFalse(second.didChange)
    }

    /// New presets land after the user's own, so a fresh release does not
    /// reshuffle a library someone has learned the shape of.
    func testNewcomersAreAppendedNotInterleaved() {
        let builtIn = makeBuiltIn(name: "Ocean Drift")
        let newcomer = makeBuiltIn(name: "Galaxy")
        var mine = makeBuiltIn(name: "My Scene")
        mine.isBuiltIn = false

        let result = Migrator.migrate(stored: [builtIn, mine], builtIns: [builtIn, newcomer])

        XCTAssertEqual(result.presets.map(\.name), ["Ocean Drift", "My Scene", "Galaxy"])
    }

    // MARK: - Refreshing (the gamut fixes reaching existing installs)

    func testAnUneditedBuiltInIsRefreshedToItsShippedForm() {
        let id = UUID()
        let stale = makeBuiltIn(id: id, name: "St. Patrick's", speed: 35)
        var fixed = stale
        fixed.palette.color1 = CodableColor(x: 0.1920, y: 0.6808)   // the in-gamut green

        let result = Migrator.migrate(stored: [stale], builtIns: [fixed])

        XCTAssertEqual(result.refreshed, ["St. Patrick's"])
        XCTAssertEqual(result.presets.first?.palette.color1, fixed.palette.color1)
    }

    /// The whole point of `isUnedited`. Someone who retuned a built-in keeps
    /// their version, gamut fix or not.
    func testAnEditedBuiltInIsNeverOverwritten() {
        let id = UUID()
        let shipped = makeBuiltIn(id: id, name: "Ocean Drift", speed: 40)
        let mine = edited(makeBuiltIn(id: id, name: "Ocean Drift", speed: 88))

        let result = Migrator.migrate(stored: [mine], builtIns: [shipped])

        XCTAssertEqual(result.refreshed, [])
        XCTAssertFalse(result.didChange)
        XCTAssertEqual(result.presets.first?.motion.speed, 88, "the user's tuning was clobbered")
    }

    func testARenamedBuiltInKeepsItsName() {
        let id = UUID()
        let shipped = makeBuiltIn(id: id, name: "Ocean Drift")
        var renamed = makeBuiltIn(id: id, name: "Brian's Ocean")
        renamed.updatedAt = renamed.createdAt.addingTimeInterval(30)

        let result = Migrator.migrate(stored: [renamed], builtIns: [shipped])

        XCTAssertEqual(result.presets.first?.name, "Brian's Ocean")
    }

    /// A refreshed preset must stay eligible for the next refresh, or the gamut
    /// fix would be the last update a preset ever receives.
    func testARefreshedPresetRemainsUneditedForTheNextRelease() {
        let id = UUID()
        let v1 = makeBuiltIn(id: id, speed: 40)
        var v2 = makeBuiltIn(id: id, speed: 50)
        v2.createdAt = Date(timeIntervalSince1970: 2_000_000)
        v2.updatedAt = v2.createdAt

        let afterV2 = Migrator.migrate(stored: [v1], builtIns: [v2])
        let refreshed = try! XCTUnwrap(afterV2.presets.first)
        XCTAssertTrue(Migrator.isUnedited(refreshed))

        var v3 = v2
        v3.motion.speed = 60
        let afterV3 = Migrator.migrate(stored: [refreshed], builtIns: [v3])
        XCTAssertEqual(afterV3.presets.first?.motion.speed, 60)
    }

    func testAnIdenticalBuiltInIsNotReportedAsRefreshed() {
        let preset = makeBuiltIn()
        let result = Migrator.migrate(stored: [preset], builtIns: [preset])
        XCTAssertFalse(result.didChange)
        XCTAssertEqual(result.refreshed, [])
    }

    // MARK: - Never touching user data

    func testUserCreatedPresetsSurviveUntouched() {
        var mine = makeBuiltIn(name: "My Scene", speed: 77)
        mine.isBuiltIn = false

        let result = Migrator.migrate(stored: [mine], builtIns: [makeBuiltIn(name: "Ocean Drift")])

        let survivor = result.presets.first { $0.id == mine.id }
        XCTAssertEqual(survivor?.motion.speed, 77)
        XCTAssertEqual(survivor?.name, "My Scene")
    }

    /// A preset whose id collides with a shipped one but that the user marked as
    /// their own must not be silently reclaimed by the catalog.
    func testAUserOwnedPresetSharingAShippedIDIsNotReclaimed() {
        let id = UUID()
        let shipped = makeBuiltIn(id: id, name: "Ocean Drift", speed: 40)
        var mine = makeBuiltIn(id: id, name: "Ocean Drift", speed: 12)
        mine.isBuiltIn = false

        let result = Migrator.migrate(stored: [mine], builtIns: [shipped])
        XCTAssertEqual(result.presets.first?.motion.speed, 12)
        XCTAssertFalse(result.presets.first?.isBuiltIn ?? true)
    }

    /// A built-in we stopped shipping stays in the library. Removing it from the
    /// catalog is our decision; deleting it from someone's library is not.
    func testARetiredBuiltInIsKept() {
        let retired = makeBuiltIn(name: "Old Favourite")
        let current = makeBuiltIn(name: "Ocean Drift")

        let result = Migrator.migrate(stored: [retired], builtIns: [current])

        XCTAssertTrue(result.presets.contains { $0.name == "Old Favourite" })
        XCTAssertTrue(result.presets.contains { $0.name == "Ocean Drift" })
    }

    // MARK: - Edge cases

    /// An empty library is first launch (or recovery from a corrupt file). Both
    /// want the catalog verbatim, and neither should report a migration.
    func testEmptyLibrarySeedsTheCatalogWithoutClaimingAMigration() {
        let catalog = [makeBuiltIn(name: "A"), makeBuiltIn(name: "B")]
        let result = Migrator.migrate(stored: [], builtIns: catalog)

        XCTAssertEqual(result.presets.count, 2)
        XCTAssertEqual(result.added, [])
        XCTAssertFalse(result.didChange, "a first-launch seed is not a migration")
    }

    func testTimestampSlackToleratesJSONRoundTripping() {
        var preset = makeBuiltIn()
        preset.updatedAt = preset.createdAt.addingTimeInterval(Migrator.timestampEpsilon / 2)
        XCTAssertTrue(Migrator.isUnedited(preset), "sub-millisecond drift is not an edit")

        preset.updatedAt = preset.createdAt.addingTimeInterval(1)
        XCTAssertFalse(Migrator.isUnedited(preset))
    }

    // MARK: - Against the real catalog

    /// The shipped catalog reconciled against itself must be a no-op — otherwise
    /// every launch would churn.
    func testTheRealCatalogIsStableAgainstItself() {
        let catalog = CompositionStore.builtInPresets
        let result = Migrator.migrate(stored: catalog, builtIns: catalog)
        XCTAssertFalse(result.didChange)
        XCTAssertEqual(result.presets.count, catalog.count)
    }

    /// A library seeded by an older build (fewer presets) gains the newcomers
    /// and keeps its count consistent.
    func testAnOlderLibraryGainsExactlyTheMissingPresets() {
        let catalog = CompositionStore.builtInPresets
        guard catalog.count > 5 else { return XCTFail("catalog too small to test") }
        let older = Array(catalog.prefix(catalog.count - 3))

        let result = Migrator.migrate(stored: older, builtIns: catalog)

        XCTAssertEqual(result.presets.count, catalog.count)
        XCTAssertEqual(result.added.count, 3)
        XCTAssertEqual(Set(result.presets.map(\.id)), Set(catalog.map(\.id)))
    }
}
