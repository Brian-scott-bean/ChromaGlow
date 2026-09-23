// CompositionStoreTests.swift
// ChromaGlow — Composer library
//
// Regression coverage for delete()'s built-in handling. The old code reset a
// built-in by looking its NAME up in the catalog. Renaming is offered on every
// preset and keeps isBuiltIn true, so a renamed built-in ("Fireside" → "My
// Fire") missed the lookup, hit the early return, and became permanently
// stuck — not reset, not removed, while the confirm dialog had just promised
// "built-in presets reset to their defaults."

import XCTest
@testable import HueHome

@MainActor
final class CompositionStoreTests: XCTestCase {

    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("compositions-test-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    private func makeStore() -> CompositionStore {
        CompositionStore(fileURL: fileURL, loadsSynchronously: true)
    }

    // MARK: - The regression

    /// Rename a built-in, then delete it. It must reset to its catalog form —
    /// same id, shipped name and tuning — not get stuck under the new name.
    func testDeletingARenamedBuiltInResetsItToCatalogForm() throws {
        let store = makeStore()
        let shipped = try XCTUnwrap(store.presets.first(where: { $0.isBuiltIn }))

        var renamed = shipped
        renamed.name = "My Fire"
        renamed.motion.speed = min(100, shipped.motion.speed + 13)
        renamed.updatedAt = Date()
        store.save(renamed)

        let saved = try XCTUnwrap(store.presets.first(where: { $0.id == shipped.id }))
        XCTAssertEqual(saved.name, "My Fire", "precondition: rename persisted")

        store.delete(saved)

        let after = try XCTUnwrap(
            store.presets.first(where: { $0.id == shipped.id }),
            "built-in vanished instead of resetting")
        XCTAssertEqual(after.name, shipped.name, "reset must restore the shipped name")
        XCTAssertEqual(after.motion, shipped.motion, "reset must restore the shipped tuning")
        XCTAssertTrue(after.isBuiltIn)
    }

    func testDeletingAnUntouchedBuiltInStillResets() throws {
        let store = makeStore()
        let shipped = try XCTUnwrap(store.presets.first(where: { $0.isBuiltIn }))

        var edited = shipped
        edited.envelope.depth = 99
        edited.updatedAt = Date()
        store.save(edited)

        store.delete(edited)

        let after = try XCTUnwrap(store.presets.first(where: { $0.id == shipped.id }))
        XCTAssertEqual(after.envelope, shipped.envelope)
    }

    /// A built-in we retired from the catalog (kept in the library by the seed
    /// migrator) has no default to reset to — delete must actually delete it,
    /// not early-return into the stuck state.
    func testDeletingARetiredBuiltInRemovesIt() throws {
        let store = makeStore()

        let retired = CompositionPreset(
            id: UUID(),   // deliberately NOT in the shipped catalog
            name: "Old Favourite", icon: "sparkles", accentColorHex: "#FFB84D",
            isBuiltIn: true, category: .ambient, seasonMonths: nil,
            palette: PaletteConfig(), motion: MotionConfig(),
            envelope: EnvelopeConfig(), reaction: ReactionConfig(),
            createdAt: Date(), updatedAt: Date()
        )
        store.save(retired)
        XCTAssertTrue(store.presets.contains { $0.id == retired.id }, "precondition")

        store.delete(retired)

        XCTAssertFalse(store.presets.contains { $0.id == retired.id },
                       "a retired built-in must be deletable — there is nothing to reset to")
    }

    func testDeletingAUserPresetRemovesIt() throws {
        let store = makeStore()
        let mine = CompositionPreset(
            id: UUID(), name: "Mine", icon: "sparkles", accentColorHex: "#FFB84D",
            isBuiltIn: false, category: .myCreations, seasonMonths: nil,
            palette: PaletteConfig(), motion: MotionConfig(),
            envelope: EnvelopeConfig(), reaction: ReactionConfig(),
            createdAt: Date(), updatedAt: Date()
        )
        store.save(mine)

        store.delete(mine)

        XCTAssertFalse(store.presets.contains { $0.id == mine.id })
    }

    // MARK: - Built-in edits survive the seed migrator (audit #2)

    /// Perform's "save sequence" wrote a sequence onto an untouched built-in
    /// without bumping `updatedAt`, so `BuiltInSeedMigrator.isUnedited` still
    /// said "never touched" and the next launch refreshed it back to the
    /// catalog — the saved sequence silently vanished.
    func testADesignChangeSavedOntoAnUntouchedBuiltInSurvivesTheNextLaunch() throws {
        let store = makeStore()
        var builtIn = try XCTUnwrap(store.presets.first(where: { BuiltInSeedMigrator.isUnedited($0) }))
        builtIn.sequence = CompositionSequence(steps: [
            .init(name: "Intro", bars: 4), .init(name: "Drop", bars: 8)])
        store.save(builtIn)   // deliberately NO caller-side stamp

        let saved = try XCTUnwrap(store.presets.first(where: { $0.id == builtIn.id }))
        XCTAssertFalse(BuiltInSeedMigrator.isUnedited(saved),
                       "a built-in whose design departs from the catalog is edited")

        let relaunched = CompositionStore(fileURL: fileURL, loadsSynchronously: true)
        let after = try XCTUnwrap(relaunched.presets.first(where: { $0.id == builtIn.id }))
        XCTAssertEqual(after.sequence, builtIn.sequence,
                       "the migrator must not revert a saved edit on the next launch")
    }

    /// Audit #16 — `duplicate` rebuilt the preset field by field and left
    /// out `sequence`, so a duplicated sequenced look lost its steps.
    func testDuplicateKeepsTheSequence() throws {
        let store = makeStore()
        var source = try XCTUnwrap(store.presets.first)
        source.sequence = CompositionSequence(steps: [.init(name: "A", bars: 4),
                                                      .init(name: "B", bars: 16)],
                                              loops: false)
        store.save(source)

        let copy = store.duplicate(source)

        XCTAssertNotEqual(copy.id, source.id)
        XCTAssertEqual(copy.sequence, source.sequence)
    }

    /// The stamp must not fire for a reset: `delete` saves the catalog copy,
    /// and a reset built-in has to stay eligible for future refreshes.
    func testAResetBuiltInStaysUnedited() throws {
        let store = makeStore()
        var builtIn = try XCTUnwrap(store.presets.first(where: { BuiltInSeedMigrator.isUnedited($0) }))
        builtIn.motion.speed = min(100, builtIn.motion.speed + 11)
        store.save(builtIn)

        store.delete(builtIn)

        let after = try XCTUnwrap(store.presets.first(where: { $0.id == builtIn.id }))
        XCTAssertTrue(BuiltInSeedMigrator.isUnedited(after),
                      "a reset restores the shipped form, timestamps included")
    }
}
