// HueIntentEntityTests.swift
// ChromaGlow — Siri Shortcuts

import XCTest
@testable import HueHome

final class HueIntentEntityTests: XCTestCase {

    private func snapshot(
        id: String = "group-1",
        name: String = "Living Room",
        kind: String? = nil,
        groupedLightId: String? = "gl-1",
        bridgeID: String? = "BRIDGE01"
    ) -> WidgetRoomSnapshot {
        WidgetRoomSnapshot(
            id: id, name: name, archetype: nil, isOn: true, brightness: 50,
            lightCount: 3, groupedLightId: groupedLightId,
            bridgeID: bridgeID, bridgeName: nil, kind: kind
        )
    }

    // ── Snapshot → entity mapping ─────────────────────────

    func testRoomSnapshotMapsToRoomEntity() {
        let entity = HueGroupEntity(snapshot: snapshot(kind: "room"))
        XCTAssertEqual(entity.id, "group-1")
        XCTAssertEqual(entity.name, "Living Room")
        XCTAssertFalse(entity.isZone)
        XCTAssertEqual(entity.groupedLightId, "gl-1")
        XCTAssertEqual(entity.bridgeID, "BRIDGE01")
    }

    func testZoneSnapshotMapsToZoneEntity() {
        XCTAssertTrue(HueGroupEntity(snapshot: snapshot(kind: "zone")).isZone)
    }

    func testLegacySnapshotWithoutKindDecodesAsRoom() {
        // Older snapshots predate the kind key — they must stay rooms.
        XCTAssertFalse(HueGroupEntity(snapshot: snapshot(kind: nil)).isZone)
    }

    // ── Spoken-name matching ──────────────────────────────

    func testMatchingIsCaseInsensitive() {
        XCTAssertTrue(HueGroupEntityQuery.matches(name: "Living Room", query: "living room"))
        XCTAssertTrue(HueGroupEntityQuery.matches(name: "Living Room", query: "LIVING ROOM"))
    }

    func testMatchingIsDiacriticInsensitive() {
        XCTAssertTrue(HueGroupEntityQuery.matches(name: "Café", query: "cafe"))
    }

    func testMatchingAcceptsContainment() {
        XCTAssertTrue(HueGroupEntityQuery.matches(name: "Living Room", query: "living"))
    }

    func testMatchingRejectsUnrelatedNames() {
        XCTAssertFalse(HueGroupEntityQuery.matches(name: "Kitchen", query: "bedroom"))
    }

    // ── PowerState semantics ──────────────────────────────

    func testPowerStateIsOn() {
        XCTAssertTrue(PowerState.on.isOn)
        XCTAssertFalse(PowerState.off.isOn)
    }

    // ── Scene entity mapping ──────────────────────────────

    func testSceneSnapshotMapsToEntity() {
        let entity = HueSceneEntity(snapshot: WidgetSceneSnapshot(
            id: "scene-1", name: "Relax", ownerGroupID: "group-1", bridgeID: "BRIDGE01"
        ))
        XCTAssertEqual(entity.id, "scene-1")
        XCTAssertEqual(entity.name, "Relax")
        XCTAssertEqual(entity.ownerGroupID, "group-1")
        XCTAssertEqual(entity.bridgeID, "BRIDGE01")
    }
}
