// SceneProvenanceStoreTests.swift
// HueHome Pro — Unit Tests
//
// R4 Scenes block: local provenance for Studio-exported dynamic scenes
// (key format locked to GlobalSceneItem.id) and the FavoriteSceneCSV
// helpers that guard the shared "favoriteSceneIDs" contract — RAW bridge
// scene UUIDs, order-preserving, Dashboard-parse compatible.

import XCTest
@testable import HueHome

@MainActor
final class SceneProvenanceStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "test.provenance.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    // ── Provenance store ──────────────────────────────────────

    func testMarkPersistsAcrossStoreInstances() {
        let store = SceneProvenanceStore(defaults: defaults)
        store.markStudioExported(bridgeID: "b1", sceneID: "s1")

        let second = SceneProvenanceStore(defaults: defaults)
        XCTAssertTrue(second.isStudioScene(key: "b1:s1"))
        XCTAssertFalse(second.isStudioScene(key: "b1:other"))
    }

    func testKeyFormatMatchesGlobalSceneItemID() {
        // The orchestrator builds GlobalSceneItem.id as "\(bridgeID):\(scene.id)".
        // The store's key MUST stay byte-identical or every badge disappears.
        let scene = GlobalSceneItem(
            id: "bridge-1:scene-9", bridgeSceneID: "scene-9", name: "Party",
            roomID: "room-1", bridgeID: "bridge-1",
            isActive: false, isDynamic: true, speed: 0.5
        )
        XCTAssertEqual(SceneProvenanceStore.key(bridgeID: "bridge-1", sceneID: "scene-9"),
                       scene.id)
    }

    func testMarkIsIdempotentAndRemoveDeletesPersistently() {
        let store = SceneProvenanceStore(defaults: defaults)
        store.markStudioExported(bridgeID: "b1", sceneID: "s1")
        store.markStudioExported(bridgeID: "b1", sceneID: "s1")
        XCTAssertEqual(store.studioSceneKeys.count, 1)

        store.remove(key: "b1:s1")
        XCTAssertFalse(store.isStudioScene(key: "b1:s1"))
        XCTAssertFalse(SceneProvenanceStore(defaults: defaults).isStudioScene(key: "b1:s1"))
    }

    func testRemoveUnknownKeyIsNoop() {
        let store = SceneProvenanceStore(defaults: defaults)
        store.markStudioExported(bridgeID: "b1", sceneID: "s1")
        store.remove(key: "never-existed")
        XCTAssertEqual(store.studioSceneKeys, ["b1:s1"])
    }

    func testCorruptDefaultsValueYieldsEmptySet() {
        defaults.set(42, forKey: "castchroma.studioExportedSceneKeys")
        let store = SceneProvenanceStore(defaults: defaults)
        XCTAssertTrue(store.studioSceneKeys.isEmpty)
    }

    // ── FavoriteSceneCSV ──────────────────────────────────────

    func testToggleAppendsRawBridgeSceneIDNotCompositeKey() {
        let scene = GlobalSceneItem(
            id: "bridge-1:scene-9", bridgeSceneID: "scene-9", name: "Party",
            roomID: "room-1", bridgeID: "bridge-1",
            isActive: false, isDynamic: false, speed: 0.5
        )
        let raw = FavoriteSceneCSV.toggled("", id: scene.bridgeSceneID)
        XCTAssertEqual(raw, "scene-9")
        XCTAssertFalse(raw.contains(":"),
                       "favorites store RAW scene UUIDs — the Dashboard resolves by bridgeSceneID")
    }

    func testTogglePreservesOrderOnRemove() {
        var raw = "a,b,c"
        raw = FavoriteSceneCSV.toggled(raw, id: "b")
        XCTAssertEqual(raw, "a,c", "removal must not reorder the surviving pills")
        raw = FavoriteSceneCSV.toggled(raw, id: "d")
        XCTAssertEqual(raw, "a,c,d", "additions append at the end")
    }

    func testRoundTripMatchesDashboardParse() {
        // DashboardView parses with split(separator: ",") — lock compatibility.
        let raw = FavoriteSceneCSV.toggled(FavoriteSceneCSV.toggled("", id: "x1"), id: "x2")
        let dashboardParse = Set(raw.split(separator: ",").map(String.init))
        XCTAssertEqual(dashboardParse, ["x1", "x2"])
    }

    func testEmptyAndDanglingCommasTolerated() {
        XCTAssertEqual(FavoriteSceneCSV.ids(from: ""), [])
        XCTAssertEqual(FavoriteSceneCSV.ids(from: ",,a,,b,"), ["a", "b"])
        XCTAssertTrue(FavoriteSceneCSV.contains("a,b", id: "a"))
        XCTAssertFalse(FavoriteSceneCSV.contains("ab,c", id: "a"))
        XCTAssertEqual(FavoriteSceneCSV.removing("a,b,a", id: "a"), "b")
    }
}
