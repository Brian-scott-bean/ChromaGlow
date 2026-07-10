// GuestAccessPolicyTests.swift
// ChromaGlow — Family Sharing Phase 3 (pure enforcement semantics)
//
// The policy is deliberately orchestrator-free so every rule is provable
// here: passthrough without a grant, exact-id filtering, FAIL CLOSED on an
// empty allowlist, scene feature+room conjunction, per-bridge features,
// and the guest-only truth table (incl. the owner-also-guest mixed role).

import XCTest
@testable import HueHome

final class GuestAccessPolicyTests: XCTestCase {

    // ── Fixtures ──────────────────────────────────────────

    private func room(_ id: String, bridge: String?) -> RoomDisplayItem {
        RoomDisplayItem(
            id: id, name: "Room \(id)", archetype: nil,
            isOn: false, brightness: 50,
            groupedLightID: "gl-\(id)", lightCount: 2,
            bridgeID: bridge, childResourceRefs: []
        )
    }

    private func scene(_ id: String, room: String, bridge: String) -> GlobalSceneItem {
        GlobalSceneItem(
            id: "\(bridge):\(id)", bridgeSceneID: id, name: "Scene \(id)",
            roomID: room, bridgeID: bridge,
            isActive: false, isDynamic: false, speed: 0.5
        )
    }

    private func grant(groups: [String], features: [String] = GuestFeature.all) -> GuestGrantSnapshot {
        GuestGrantSnapshot(allowedGroupIDs: Set(groups), features: Set(features), profileName: "Alex")
    }

    // ── filterGroups ──────────────────────────────────────

    func testNilGrantPassesEverythingThrough() {
        let rooms = [room("a", bridge: "b1"), room("b", bridge: "b1")]
        XCTAssertEqual(GuestAccessPolicy.filterGroups(rooms, grant: nil), rooms)
    }

    func testFilterKeepsOnlyAllowedIDs() {
        let rooms = [room("a", bridge: "b1"), room("b", bridge: "b1"), room("c", bridge: "b1")]
        let filtered = GuestAccessPolicy.filterGroups(rooms, grant: grant(groups: ["a", "c"]))
        XCTAssertEqual(filtered.map(\.id), ["a", "c"])
    }

    func testEmptyAllowlistFailsClosed() {
        let rooms = [room("a", bridge: "b1"), room("b", bridge: "b1")]
        XCTAssertTrue(GuestAccessPolicy.filterGroups(rooms, grant: grant(groups: [])).isEmpty,
                      "an empty allowlist must yield ZERO rooms, never all rooms")
    }

    // ── filterScenes ──────────────────────────────────────

    func testScenesUntouchedWithNoGrants() {
        let scenes = [scene("s1", room: "a", bridge: "b1")]
        XCTAssertEqual(GuestAccessPolicy.filterScenes(scenes, grants: [:]), scenes)
    }

    func testScenesOnUngrantedBridgePassThrough() {
        let scenes = [scene("s1", room: "a", bridge: "owned")]
        let grants = ["granted": grant(groups: ["x"])]
        XCTAssertEqual(GuestAccessPolicy.filterScenes(scenes, grants: grants), scenes)
    }

    func testSceneInDisallowedRoomIsDropped() {
        let scenes = [scene("s1", room: "a", bridge: "b1"),
                      scene("s2", room: "hidden", bridge: "b1")]
        let grants = ["b1": grant(groups: ["a"])]
        XCTAssertEqual(GuestAccessPolicy.filterScenes(scenes, grants: grants).map(\.bridgeSceneID), ["s1"])
    }

    func testScenesFeatureMissingDropsAllOfThatBridgesScenes() {
        let scenes = [scene("s1", room: "a", bridge: "b1")]
        let grants = ["b1": grant(groups: ["a"], features: [GuestFeature.onOff])]
        XCTAssertTrue(GuestAccessPolicy.filterScenes(scenes, grants: grants).isEmpty)
    }

    // ── features(for:) ────────────────────────────────────

    func testFeaturesUnrestrictedForNilBridgeAndUngranted() {
        let grants = ["b1": grant(groups: ["a"], features: [GuestFeature.onOff])]
        XCTAssertEqual(GuestAccessPolicy.features(for: nil, grants: grants), .unrestricted)
        XCTAssertEqual(GuestAccessPolicy.features(for: "owned", grants: grants), .unrestricted)
    }

    func testFeaturesFailClosedToGrantedListOnly() {
        let grants = ["b1": grant(groups: ["a"], features: [GuestFeature.onOff])]
        let f = GuestAccessPolicy.features(for: "b1", grants: grants)
        XCTAssertTrue(f.canPower)
        XCTAssertFalse(f.canAdjust)
        XCTAssertFalse(f.canRecallScenes)
    }

    func testUnknownFutureFeatureStringGrantsNothing() {
        let grants = ["b1": grant(groups: ["a"], features: ["laserShow"])]
        let f = GuestAccessPolicy.features(for: "b1", grants: grants)
        XCTAssertFalse(f.canPower)
        XCTAssertFalse(f.canAdjust)
        XCTAssertFalse(f.canRecallScenes)
    }

    // ── isGuestOnly truth table ───────────────────────────

    func testGuestOnlyWhenEveryBridgeGranted() {
        let grants = ["b1": grant(groups: ["a"]), "b2": grant(groups: ["b"])]
        XCTAssertTrue(GuestAccessPolicy.isGuestOnly(liveBridgeIDs: ["b1", "b2"], grants: grants))
    }

    func testMixedRoleKeepsFullShell() {
        // Owner of "own", guest of "b1" — Studio and scene-create must stay.
        let grants = ["b1": grant(groups: ["a"])]
        XCTAssertFalse(GuestAccessPolicy.isGuestOnly(liveBridgeIDs: ["own", "b1"], grants: grants))
    }

    func testNoBridgesIsNeverGuestOnly() {
        XCTAssertFalse(GuestAccessPolicy.isGuestOnly(liveBridgeIDs: [String](), grants: [:]))
        XCTAssertFalse(GuestAccessPolicy.isGuestOnly(
            liveBridgeIDs: [String](),
            grants: ["stale": grant(groups: ["a"])]
        ))
    }

    func testNoGrantsIsNeverGuestOnly() {
        XCTAssertFalse(GuestAccessPolicy.isGuestOnly(liveBridgeIDs: ["b1"], grants: [:]))
    }
}
