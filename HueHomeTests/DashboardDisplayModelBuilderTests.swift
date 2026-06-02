// DashboardDisplayModelBuilderTests.swift
// ChromaGlow — IOS-REF-001R

import XCTest
@testable import HueHome

final class DashboardDisplayModelBuilderTests: XCTestCase {

    // MARK: - Helpers

    private func room(
        id: String,
        name: String,
        kind: RoomDisplayItem.Kind = .room,
        bridgeID: String = "bridge-a",
        isOn: Bool = true,
        brightness: Double = 50,
        refs: [(rid: String, rtype: String)] = [("light-1", "light")]
    ) -> RoomDisplayItem {
        RoomDisplayItem(
            kind: kind,
            id: id,
            name: name,
            archetype: "bedroom",
            isOn: isOn,
            brightness: brightness,
            groupedLightID: "gl-\(id)",
            lightCount: 3,
            bridgeID: bridgeID,
            childResourceRefs: refs,
            dominantColorX: 0.41,
            dominantColorY: 0.37,
            dominantMirek: 366
        )
    }

    private func assertChildRefsEqual(
        _ actual: [(rid: String, rtype: String)],
        _ expected: [(rid: String, rtype: String)],
        file: StaticString = #file,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            actual.map { "\($0.rid)|\($0.rtype)" },
            expected.map { "\($0.rid)|\($0.rtype)" },
            file: file,
            line: line
        )
    }

    private func assertRoomFieldsEqual(
        _ actual: RoomDisplayItem,
        _ expected: RoomDisplayItem,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.id, expected.id, file: file, line: line)
        XCTAssertEqual(actual.kind, expected.kind, file: file, line: line)
        XCTAssertEqual(actual.name, expected.name, file: file, line: line)
        XCTAssertEqual(actual.archetype, expected.archetype, file: file, line: line)
        XCTAssertEqual(actual.isOn, expected.isOn, file: file, line: line)
        XCTAssertEqual(actual.brightness, expected.brightness, file: file, line: line)
        XCTAssertEqual(actual.groupedLightID, expected.groupedLightID, file: file, line: line)
        XCTAssertEqual(actual.lightCount, expected.lightCount, file: file, line: line)
        XCTAssertEqual(actual.bridgeID, expected.bridgeID, file: file, line: line)
        assertChildRefsEqual(actual.childResourceRefs, expected.childResourceRefs, file: file, line: line)
        XCTAssertEqual(actual.dominantColorX, expected.dominantColorX, file: file, line: line)
        XCTAssertEqual(actual.dominantColorY, expected.dominantColorY, file: file, line: line)
        XCTAssertEqual(actual.dominantMirek, expected.dominantMirek, file: file, line: line)
    }

    // MARK: - Tests

    func testMakeRooms_emptyInput_returnsEmptyArray() {
        let result = DashboardDisplayModelBuilder.makeRooms(from: [:])
        XCTAssertTrue(result.isEmpty)
    }

    func testMakeRooms_multiBridgeInput_flattensAndSortsAlphabetically() {
        let attic = room(id: "r-attic", name: "Attic", bridgeID: "bridge-b")
        let bedroom = room(id: "r-bedroom", name: "Bedroom", bridgeID: "bridge-a")
        let zara = room(id: "r-zara", name: "Zara", bridgeID: "bridge-a")

        let input: [String: [RoomDisplayItem]] = [
            "bridge-b": [zara, attic],
            "bridge-a": [bedroom],
        ]

        let result = DashboardDisplayModelBuilder.makeRooms(from: input)

        XCTAssertEqual(result.map(\.name), ["Attic", "Bedroom", "Zara"])
    }

    func testMakeRooms_duplicateIDs_keepsOneItem() {
        let first = room(id: "dup-id", name: "Alpha", bridgeID: "bridge-a")
        let second = room(id: "dup-id", name: "Beta", bridgeID: "bridge-b")

        let result = DashboardDisplayModelBuilder.makeRooms(from: [
            "bridge-a": [first],
            "bridge-b": [second],
        ])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, "dup-id")
    }

    func testMakeRooms_duplicateIDs_sortsBeforeDeduplicating() {
        let zulu = room(id: "dup-id", name: "Zulu", bridgeID: "bridge-b")
        let alpha = room(id: "dup-id", name: "Alpha", bridgeID: "bridge-a")

        let result = DashboardDisplayModelBuilder.makeRooms(from: [
            "bridge-b": [zulu],
            "bridge-a": [alpha],
        ])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].name, "Alpha")
    }

    func testMakeRooms_sameNameDifferentIDs_keepsBothItems() {
        let one = room(id: "id-1", name: "Office", bridgeID: "bridge-a")
        let two = room(id: "id-2", name: "Office", bridgeID: "bridge-b")

        let result = DashboardDisplayModelBuilder.makeRooms(from: [
            "bridge-a": [two],
            "bridge-b": [one],
        ])

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(Set(result.map(\.id)), ["id-1", "id-2"])
    }

    func testMakeRooms_preservesDisplayStateFields() {
        var item = room(
            id: "preserve-id",
            name: "Preserve",
            kind: .zone,
            bridgeID: "bridge-p",
            isOn: false,
            brightness: 12.5,
            refs: [("rid-a", "light"), ("rid-b", "device")]
        )
        item.kind = .zone

        let result = DashboardDisplayModelBuilder.makeRooms(from: [
            "bridge-p": [item],
        ])

        XCTAssertEqual(result.count, 1)
        assertRoomFieldsEqual(result[0], item)
    }

    func testMakeRooms_doesNotMutateInput() {
        let bedroom = room(id: "r-bedroom", name: "Bedroom")
        let attic = room(id: "r-attic", name: "Attic")
        var input: [String: [RoomDisplayItem]] = [
            "bridge-a": [bedroom, attic],
        ]
        let snapshot = input

        _ = DashboardDisplayModelBuilder.makeRooms(from: input)

        XCTAssertEqual(input.keys.sorted(), snapshot.keys.sorted())
        XCTAssertEqual(input["bridge-a"]?.map(\.id), snapshot["bridge-a"]?.map(\.id))
        XCTAssertEqual(input["bridge-a"]?.map(\.name), snapshot["bridge-a"]?.map(\.name))
    }
}
