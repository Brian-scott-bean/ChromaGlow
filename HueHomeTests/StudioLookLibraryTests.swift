//
//  StudioLookLibraryTests.swift
//  HueHomeTests
//
//  Unified Customization Engine — Slice 2. Favorites/Recents persistence and
//  the per-target session working memory.
//

import XCTest
@testable import HueHome

@MainActor
final class StudioLookLibraryTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suiteName = "StudioLookLibraryTests"

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            defaults = UserDefaults(suiteName: suiteName)
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            defaults.removePersistentDomain(forName: suiteName)
            defaults = nil
        }
        super.tearDown()
    }

    // ── Favorites ───────────────────────────────────────────────

    func testFavoritesToggleAndPersistAcrossReload() {
        let store = StudioLookLibraryStore(defaults: defaults)
        store.toggleFavorite("party")
        store.toggleFavorite("candle")
        XCTAssertTrue(store.isFavorite("party"))

        let reloaded = StudioLookLibraryStore(defaults: defaults)
        XCTAssertEqual(reloaded.favoriteLookIDs, ["party", "candle"])

        reloaded.toggleFavorite("party")
        XCTAssertFalse(reloaded.isFavorite("party"))
        XCTAssertEqual(StudioLookLibraryStore(defaults: defaults).favoriteLookIDs, ["candle"])
    }

    // ── Recents ─────────────────────────────────────────────────

    func testRecentsFrontLoadDeduplicateAndCap() {
        let store = StudioLookLibraryStore(defaults: defaults)
        for id in ["a", "b", "c", "a"] { store.noteApplied(id) }
        XCTAssertEqual(store.recentLookIDs, ["a", "c", "b"],
                       "re-applying moves to the front without duplicating")

        for id in ["d", "e", "f", "g", "h", "i"] { store.noteApplied(id) }
        XCTAssertEqual(store.recentLookIDs.count, 8, "recents cap at eight")
        XCTAssertEqual(store.recentLookIDs.first, "i")

        let reloaded = StudioLookLibraryStore(defaults: defaults)
        XCTAssertEqual(reloaded.recentLookIDs, store.recentLookIDs)
    }

    func testCorruptCSVLoadsSafely() {
        defaults.set(",,party,,party,", forKey: "studio.favoriteLookIDs.v1")
        let store = StudioLookLibraryStore(defaults: defaults)
        XCTAssertEqual(store.favoriteLookIDs, ["party"],
                       "empties and duplicates are dropped, never crashed on")
    }

    // ── Session working memory (spec §14.4) ─────────────────────

    private func target(_ group: String, card: String = "party",
                        kind: RoomDisplayItem.Kind = .room) -> RunningLookTargetKey {
        RunningLookTargetKey(bridgeID: "bridge-a", groupID: group, kind: kind,
                             cardID: card, execution: .appDriven(engineKey: card))
    }

    func testWorkingMemoryIsPerTargetAndRestoredOnSwitch() {
        let memory = StudioSessionWorkingMemory()
        let a = target("room-a"), b = target("room-b")

        memory.update(a) { $0.identityPanelOpen = true }
        memory.update(a) { $0.expandedColorControlID =
            CustomizationControlID(cardID: "party", paramID: "color") }

        XCTAssertTrue(memory.state(for: a).identityPanelOpen)
        XCTAssertFalse(memory.state(for: b).identityPanelOpen,
                       "another target starts clean")
        // Switching back restores A's expansions exactly.
        XCTAssertEqual(memory.state(for: a).expandedColorControlID?.paramID, "color")
    }

    func testDuplicateGroupIDsAcrossKindsStayDistinct() {
        let memory = StudioSessionWorkingMemory()
        let room = target("shared", kind: .room)
        let zone = target("shared", kind: .zone)
        memory.update(room) { $0.identityPanelOpen = true }
        XCTAssertFalse(memory.state(for: zone).identityPanelOpen)
    }

    func testStoppingATargetClearsOnlyItsMemory() {
        let memory = StudioSessionWorkingMemory()
        let a = target("room-a"), b = target("room-b")
        memory.update(a) { $0.identityPanelOpen = true }
        memory.update(b) { $0.identityPanelOpen = true }

        memory.clear(for: a)
        XCTAssertFalse(memory.state(for: a).identityPanelOpen)
        XCTAssertTrue(memory.state(for: b).identityPanelOpen)

        memory.clearAll()
        XCTAssertFalse(memory.state(for: b).identityPanelOpen,
                       "session end clears every expansion (spec §14.4)")
        XCTAssertTrue(memory.isEmpty)
    }
}
