// SceneUsageStoreTests.swift
// ChromaGlow — Scenes overhaul Phase 2

import XCTest
@testable import HueHome

@MainActor
final class SceneUsageStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suiteName = "SceneUsageStoreTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testRecordActivationCountsAndTimestamps() {
        let store = SceneUsageStore(defaults: defaults)
        let t1 = Date(timeIntervalSince1970: 1_000)
        let t2 = Date(timeIntervalSince1970: 2_000)

        store.recordActivation(bridgeSceneID: "scene-a", at: t1)
        store.recordActivation(bridgeSceneID: "scene-a", at: t2)
        store.recordActivation(bridgeSceneID: "scene-b", at: t1)

        XCTAssertEqual(store.useCount(bridgeSceneID: "scene-a"), 2)
        XCTAssertEqual(store.lastUsed(bridgeSceneID: "scene-a"), t2)
        XCTAssertEqual(store.useCount(bridgeSceneID: "scene-b"), 1)
        XCTAssertEqual(store.useCount(bridgeSceneID: "never-used"), 0)
        XCTAssertNil(store.lastUsed(bridgeSceneID: "never-used"))
    }

    func testUsagePersistsAcrossStoreInstances() {
        let t = Date(timeIntervalSince1970: 5_000)
        SceneUsageStore(defaults: defaults).recordActivation(bridgeSceneID: "scene-a", at: t)

        let reloaded = SceneUsageStore(defaults: defaults)
        XCTAssertEqual(reloaded.useCount(bridgeSceneID: "scene-a"), 1)
        XCTAssertEqual(reloaded.lastUsed(bridgeSceneID: "scene-a"), t)
    }

    func testPruneDropsLeastRecentlyUsedBeyondCap() {
        let store = SceneUsageStore(defaults: defaults)
        // 501 distinct scenes, strictly increasing recency.
        for i in 0...500 {
            store.recordActivation(
                bridgeSceneID: "scene-\(i)",
                at: Date(timeIntervalSince1970: Double(i))
            )
        }
        XCTAssertEqual(store.usageBySceneID.count, 500, "cap must hold at 500 entries")
        XCTAssertEqual(store.useCount(bridgeSceneID: "scene-0"), 0,
                       "the least-recently-used entry is the one dropped")
        XCTAssertEqual(store.useCount(bridgeSceneID: "scene-500"), 1)
    }

    func testTransferMovesHistoryToNewID() {
        let store = SceneUsageStore(defaults: defaults)
        let t = Date(timeIntervalSince1970: 5_000)
        store.recordActivation(bridgeSceneID: "old-id", at: t)
        store.recordActivation(bridgeSceneID: "old-id", at: t)

        store.transfer(from: "old-id", to: "new-id")

        XCTAssertEqual(store.useCount(bridgeSceneID: "new-id"), 2)
        XCTAssertEqual(store.lastUsed(bridgeSceneID: "new-id"), t)
        XCTAssertEqual(store.useCount(bridgeSceneID: "old-id"), 0, "old id must not linger")

        // Persisted, not just in-memory.
        let reloaded = SceneUsageStore(defaults: defaults)
        XCTAssertEqual(reloaded.useCount(bridgeSceneID: "new-id"), 2)
    }

    func testTransferCollisionKeepsMaxCountAndLatestDate() {
        let store = SceneUsageStore(defaults: defaults)
        let early = Date(timeIntervalSince1970: 1_000)
        let late  = Date(timeIntervalSince1970: 9_000)
        store.recordActivation(bridgeSceneID: "a", at: late)
        (0..<3).forEach { _ in store.recordActivation(bridgeSceneID: "b", at: early) }

        store.transfer(from: "b", to: "a")

        XCTAssertEqual(store.useCount(bridgeSceneID: "a"), 3)
        XCTAssertEqual(store.lastUsed(bridgeSceneID: "a"), late)
    }

    func testTransferFromUnknownIDIsNoop() {
        let store = SceneUsageStore(defaults: defaults)
        store.recordActivation(bridgeSceneID: "existing")

        store.transfer(from: "ghost", to: "existing")

        XCTAssertEqual(store.useCount(bridgeSceneID: "existing"), 1)
    }

    func testRemoveDeletesEntryPersistently() {
        let store = SceneUsageStore(defaults: defaults)
        store.recordActivation(bridgeSceneID: "doomed")

        store.remove(bridgeSceneID: "doomed")

        XCTAssertEqual(store.useCount(bridgeSceneID: "doomed"), 0)
        let reloaded = SceneUsageStore(defaults: defaults)
        XCTAssertEqual(reloaded.useCount(bridgeSceneID: "doomed"), 0)
    }
}
