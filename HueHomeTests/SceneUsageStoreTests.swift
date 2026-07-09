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
}
