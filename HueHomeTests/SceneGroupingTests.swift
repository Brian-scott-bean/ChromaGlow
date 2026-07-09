// SceneGroupingTests.swift
// ChromaGlow — Scenes overhaul Phase 1
//
// Pure-logic tests for the Scenes tab sectioning/sorting model:
// room+zone name resolution (the zone-name bug), section ordering,
// orphan handling, favorites-shelf ordering, and flat sorts.

import XCTest
@testable import HueHome

final class SceneGroupingTests: XCTestCase {

    // ── Fixtures ──────────────────────────────────────────

    private func scene(
        _ name: String,
        roomID: String,
        bridgeID: String = "bridge-1",
        isActive: Bool = false
    ) -> GlobalSceneItem {
        GlobalSceneItem(
            id: "\(bridgeID):\(name)",
            bridgeSceneID: name,
            name: name,
            roomID: roomID,
            bridgeID: bridgeID,
            isActive: isActive,
            isDynamic: false,
            speed: 0.5
        )
    }

    private func group(
        id: String,
        name: String,
        archetype: String? = nil,
        kind: RoomDisplayItem.Kind = .room
    ) -> RoomDisplayItem {
        RoomDisplayItem(
            kind: kind,
            id: id,
            name: name,
            archetype: archetype,
            isOn: false,
            brightness: 50,
            groupedLightID: "gl-\(id)",
            lightCount: 2,
            bridgeID: "bridge-1",
            childResourceRefs: []
        )
    }

    // ── Room index: rooms AND zones ───────────────────────

    func testRoomIndexResolvesZoneNames() {
        // The old ScenesTabView lookup searched allRooms only, so a scene
        // owned by a ZONE displayed as "Other". The index must cover both.
        let index = SceneGrouping.roomIndex(groups: [
            group(id: "room-1", name: "Bedroom", archetype: "bedroom"),
            group(id: "zone-1", name: "Downstairs", archetype: "living_room", kind: .zone),
        ])

        let zoneScene = scene("Evening", roomID: "zone-1")
        XCTAssertEqual(SceneGrouping.roomName(for: zoneScene, index: index), "Downstairs",
                       "zone scenes must resolve their zone's name, not fall back to Other")
        XCTAssertEqual(SceneGrouping.roomArchetype(for: zoneScene, index: index), "living_room")

        let orphan = scene("Ghost", roomID: "deleted-room")
        XCTAssertEqual(SceneGrouping.roomName(for: orphan, index: index), "Other")
    }

    // ── Sections ──────────────────────────────────────────

    func testSectionsAlphabeticalWithOrphansLast() {
        let index = SceneGrouping.roomIndex(groups: [
            group(id: "room-k", name: "Kitchen"),
            group(id: "room-b", name: "Bedroom"),
            group(id: "zone-d", name: "Downstairs", kind: .zone),
        ])
        let scenes = [
            scene("S1", roomID: "room-k"),
            scene("S2", roomID: "room-b", isActive: true),
            scene("S3", roomID: "room-b"),
            scene("S4", roomID: "zone-d"),
            scene("S5", roomID: "gone-room"),
        ]

        let sections = SceneGrouping.sections(scenes: scenes, index: index)

        XCTAssertEqual(sections.map(\.title), ["Bedroom", "Downstairs", "Kitchen", "Other"])
        XCTAssertEqual(sections[0].scenes.map(\.name), ["S2", "S3"],
                       "input scene order must be preserved inside a section")
        XCTAssertEqual(sections[0].activeCount, 1)
        XCTAssertEqual(sections.last?.id, SceneGrouping.otherSectionID)
        XCTAssertEqual(sections.last?.scenes.map(\.name), ["S5"])
    }

    func testSectionsOmitEmptyRoomsAndOtherWhenNoOrphans() {
        let index = SceneGrouping.roomIndex(groups: [
            group(id: "room-1", name: "Bedroom"),
            group(id: "room-2", name: "Office"),   // no scenes
        ])
        let sections = SceneGrouping.sections(
            scenes: [scene("S1", roomID: "room-1")],
            index: index
        )
        XCTAssertEqual(sections.map(\.title), ["Bedroom"],
                       "rooms without scenes get no section; no orphans → no Other")
    }

    // ── Favorites shelf ───────────────────────────────────

    func testFavoritesFollowCSVOrderAndSkipUnknownIDs() {
        let scenes = [
            scene("Alpha", roomID: "r1"),
            scene("Beta",  roomID: "r1"),
            scene("Gamma", roomID: "r2"),
        ]
        // CSV order = starring order (Gamma first), with one stale id.
        let favorites = SceneGrouping.favorites(
            scenes: scenes,
            favoriteIDsCSV: "Gamma,deleted-scene,Alpha"
        )
        XCTAssertEqual(favorites.map(\.name), ["Gamma", "Alpha"])
    }

    // ── Flat sorts ────────────────────────────────────────

    func testFlatSortedAlphabetical() {
        let sorted = SceneGrouping.flatSorted(
            scenes: [scene("Zen", roomID: "r"), scene("Aurora", roomID: "r")],
            mode: .alphabetical
        )
        XCTAssertEqual(sorted.map(\.name), ["Aurora", "Zen"])
    }

    func testFlatSortedRecentPutsUsedFirstThenAlphabetical() {
        let a = scene("Aurora", roomID: "r")
        let b = scene("Beach",  roomID: "r")
        let c = scene("Cave",   roomID: "r")
        let dates = ["Beach": Date(timeIntervalSince1970: 2_000),
                     "Cave":  Date(timeIntervalSince1970: 1_000)]

        let sorted = SceneGrouping.flatSorted(
            scenes: [a, b, c],
            mode: .recent,
            lastUsed: { dates[$0.name] }
        )
        XCTAssertEqual(sorted.map(\.name), ["Beach", "Cave", "Aurora"],
                       "recently used first, never-used tail stays alphabetical")
    }

    func testFlatSortedMostUsedByCountThenName() {
        let sorted = SceneGrouping.flatSorted(
            scenes: [scene("A", roomID: "r"), scene("B", roomID: "r"), scene("C", roomID: "r")],
            mode: .mostUsed,
            useCount: { ["B": 5, "C": 5, "A": 1][$0.name] ?? 0 }
        )
        XCTAssertEqual(sorted.map(\.name), ["B", "C", "A"])
    }
}
