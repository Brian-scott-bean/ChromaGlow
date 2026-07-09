import XCTest
@testable import HueHome

final class RoomAndZoneDisplayModelBuilderTests: XCTestCase {

    private func ref(_ rid: String, _ rtype: String) -> ResourceRef {
        ResourceRef(rid: rid, rtype: rtype)
    }

    private func room(
        id: String,
        name: String,
        archetype: String? = "bedroom",
        children: [ResourceRef],
        groupedLightID: String
    ) -> HueRoom {
        HueRoom(
            id: id,
            metadata: RoomMetadata(name: name, archetype: archetype),
            children: children,
            services: [ref(groupedLightID, "grouped_light")]
        )
    }

    private func zone(
        id: String,
        name: String,
        archetype: String? = "zone",
        children: [ResourceRef],
        groupedLightID: String
    ) -> HueZone {
        HueZone(
            id: id,
            metadata: RoomMetadata(name: name, archetype: archetype),
            children: children,
            services: [ref(groupedLightID, "grouped_light")]
        )
    }

    private func light(
        id: String,
        ownerRID: String? = nil,
        isOn: Bool = true,
        brightness: Double = 100,
        xy: (Double, Double)? = nil,
        mirek: Int? = nil
    ) -> HueLight {
        HueLight(
            id: id,
            metadata: LightMetadata(name: "L-\(id)", archetype: nil),
            on: OnState(on: isOn),
            dimming: DimmingState(brightness: brightness),
            color: xy.map { LightColor(xy: CIExy(x: $0.0, y: $0.1), gamut_type: nil) },
            color_temperature: LightColorTemp(mirek: mirek, mirek_schema: nil, mirek_valid: nil),
            owner: ownerRID.map { ResourceRef(rid: $0, rtype: "device") }
        )
    }

    private func groupedLight(id: String, isOn: Bool, brightness: Double) -> HueGroupedLight {
        HueGroupedLight(
            id: id,
            on: OnState(on: isOn),
            dimming: DimmingState(brightness: brightness),
            type: "grouped_light"
        )
    }

    func testEmptyInputReturnsEmptyCollections() {
        let result = RoomAndZoneDisplayModelBuilder.makeDisplayModels(
            rooms: [],
            zones: [],
            lights: [],
            groupedLights: [],
            bridgeID: "bridge-a"
        )

        XCTAssertTrue(result.rooms.isEmpty)
        XCTAssertTrue(result.zones.isEmpty)
        XCTAssertTrue(result.roomLightMap.isEmpty)
        XCTAssertTrue(result.zoneLightMap.isEmpty)
    }

    func testRoomDisplayItemPreservesFieldsAndUsesDeviceOwnerFallback() {
        let roomInput = room(
            id: "room-1",
            name: "Bedroom",
            archetype: "bedroom",
            children: [ref("device-1", "device"), ref("light-direct", "light")],
            groupedLightID: "gl-room-1"
        )
        let lights = [
            light(id: "light-via-owner", ownerRID: "device-1", isOn: true, brightness: 80, xy: (0.4, 0.3)),
            light(id: "light-direct", ownerRID: "device-2", isOn: true, brightness: 20, mirek: 300),
        ]
        let grouped = [groupedLight(id: "gl-room-1", isOn: true, brightness: 42)]

        let result = RoomAndZoneDisplayModelBuilder.makeDisplayModels(
            rooms: [roomInput],
            zones: [],
            lights: lights,
            groupedLights: grouped,
            bridgeID: "bridge-a"
        )

        XCTAssertEqual(result.rooms.count, 1)
        let item = result.rooms[0]
        XCTAssertEqual(item.name, "Bedroom")
        XCTAssertEqual(item.archetype, "bedroom")
        XCTAssertEqual(item.bridgeID, "bridge-a")
        XCTAssertEqual(item.kind, .room)
        XCTAssertEqual(item.groupedLightID, "gl-room-1")
        XCTAssertEqual(
            item.childResourceRefs.map { "\($0.rid)|\($0.rtype)" },
            ["device-1|device", "light-direct|light"]
        )
        XCTAssertTrue(item.isOn)
        XCTAssertEqual(item.brightness, 42, accuracy: 0.0001)
        XCTAssertEqual(item.lightCount, 2)
        XCTAssertEqual(result.roomLightMap["light-via-owner"], "room-1")
        XCTAssertEqual(result.roomLightMap["light-direct"], "room-1")
    }

    func testZoneDisplayItemPreservesFieldsAndDirectMapping() {
        let zoneInput = zone(
            id: "zone-1",
            name: "Downstairs",
            archetype: "living_room",
            children: [ref("zone-light-1", "light"), ref("zone-light-2", "light")],
            groupedLightID: "gl-zone-1"
        )
        let lights = [
            light(id: "zone-light-1", ownerRID: "device-1", isOn: true, brightness: 33, xy: (0.2, 0.3)),
            light(id: "zone-light-2", ownerRID: "device-2", isOn: false, brightness: 90, xy: (0.5, 0.4)),
        ]
        let grouped = [groupedLight(id: "gl-zone-1", isOn: true, brightness: 55)]

        let result = RoomAndZoneDisplayModelBuilder.makeDisplayModels(
            rooms: [],
            zones: [zoneInput],
            lights: lights,
            groupedLights: grouped,
            bridgeID: "bridge-z"
        )

        XCTAssertEqual(result.zones.count, 1)
        let item = result.zones[0]
        XCTAssertEqual(item.name, "Downstairs")
        XCTAssertEqual(item.archetype, "living_room")
        XCTAssertEqual(item.bridgeID, "bridge-z")
        XCTAssertEqual(item.kind, .zone)
        XCTAssertEqual(item.groupedLightID, "gl-zone-1")
        XCTAssertEqual(
            item.childResourceRefs.map { "\($0.rid)|\($0.rtype)" },
            ["zone-light-1|light", "zone-light-2|light"]
        )
        XCTAssertTrue(item.isOn)
        XCTAssertEqual(item.brightness, 55, accuracy: 0.0001)
        XCTAssertEqual(item.lightCount, 2)
        XCTAssertEqual(result.zoneLightMap["zone-light-1"], "zone-1")
        XCTAssertEqual(result.zoneLightMap["zone-light-2"], "zone-1")
    }

    func testDominantStateChoosesBrightestOnColorThenMirekWithFallbacks() {
        let roomInput = room(
            id: "room-1",
            name: "Kitchen",
            children: [ref("light-1", "light"), ref("light-2", "light"), ref("light-3", "light")],
            groupedLightID: "gl-room"
        )

        let colorWins = RoomAndZoneDisplayModelBuilder.makeDisplayModels(
            rooms: [roomInput],
            zones: [],
            lights: [
                light(id: "light-1", isOn: true, brightness: 20, xy: (0.1, 0.2)),
                light(id: "light-2", isOn: true, brightness: 80, xy: (0.3, 0.4)),
                light(id: "light-3", isOn: true, brightness: 99, mirek: 250),
            ],
            groupedLights: [groupedLight(id: "gl-room", isOn: true, brightness: 80)],
            bridgeID: "bridge-a"
        )
        XCTAssertEqual(colorWins.rooms[0].dominantColorX ?? -1, 0.3, accuracy: 0.0001)
        XCTAssertEqual(colorWins.rooms[0].dominantColorY ?? -1, 0.4, accuracy: 0.0001)
        XCTAssertNil(colorWins.rooms[0].dominantMirek)

        let mirekFallback = RoomAndZoneDisplayModelBuilder.makeDisplayModels(
            rooms: [roomInput],
            zones: [],
            lights: [
                light(id: "light-1", isOn: true, brightness: 20, mirek: 400),
                light(id: "light-2", isOn: true, brightness: 90, mirek: 220),
                light(id: "light-3", isOn: false, brightness: 100, xy: (0.9, 0.1)),
            ],
            groupedLights: [groupedLight(id: "gl-room", isOn: true, brightness: 60)],
            bridgeID: "bridge-a"
        )
        XCTAssertNil(mirekFallback.rooms[0].dominantColorX)
        XCTAssertNil(mirekFallback.rooms[0].dominantColorY)
        XCTAssertEqual(mirekFallback.rooms[0].dominantMirek, 220)

        // grouped_light lag: gl reports off but a member light is on — the
        // member-light cross-check must win (and dominant color follows).
        let groupedOff = RoomAndZoneDisplayModelBuilder.makeDisplayModels(
            rooms: [roomInput],
            zones: [],
            lights: [
                light(id: "light-1", isOn: true, brightness: 100, xy: (0.6, 0.2)),
            ],
            groupedLights: [groupedLight(id: "gl-room", isOn: false, brightness: 12)],
            bridgeID: "bridge-a"
        )
        XCTAssertTrue(groupedOff.rooms[0].isOn,
                      "a lit member light must prove the room on despite grouped_light lag")
        XCTAssertEqual(groupedOff.rooms[0].brightness, 100, accuracy: 0.0001)
        XCTAssertEqual(groupedOff.rooms[0].dominantColorX ?? -1, 0.6, accuracy: 0.0001)
        XCTAssertEqual(groupedOff.rooms[0].dominantColorY ?? -1, 0.2, accuracy: 0.0001)
    }

    func testMemberLightCrossCheckOverridesLaggingGroupedLight() {
        let roomInput = room(
            id: "room-1",
            name: "Den",
            children: [ref("light-1", "light"), ref("light-2", "light"), ref("light-3", "light")],
            groupedLightID: "gl-room"
        )

        // gl off, two lights on → room on, brightness = average of ON lights only.
        let lagging = RoomAndZoneDisplayModelBuilder.makeDisplayModels(
            rooms: [roomInput],
            zones: [],
            lights: [
                light(id: "light-1", isOn: true, brightness: 40, xy: (0.3, 0.3)),
                light(id: "light-2", isOn: true, brightness: 80, mirek: 300),
                light(id: "light-3", isOn: false, brightness: 100, xy: (0.9, 0.1)),
            ],
            groupedLights: [groupedLight(id: "gl-room", isOn: false, brightness: 5)],
            bridgeID: "bridge-a"
        )
        XCTAssertTrue(lagging.rooms[0].isOn)
        XCTAssertEqual(lagging.rooms[0].brightness, 60, accuracy: 0.0001,
                       "brightness must average the ON member lights, ignoring off ones")

        // All member lights off + gl off → room stays off (no false positives).
        let allOff = RoomAndZoneDisplayModelBuilder.makeDisplayModels(
            rooms: [roomInput],
            zones: [],
            lights: [
                light(id: "light-1", isOn: false, brightness: 40),
                light(id: "light-2", isOn: false, brightness: 80),
            ],
            groupedLights: [groupedLight(id: "gl-room", isOn: false, brightness: 5)],
            bridgeID: "bridge-a"
        )
        XCTAssertFalse(allOff.rooms[0].isOn)

        // gl ON stays authoritative — cross-check never runs when gl says on.
        let glOn = RoomAndZoneDisplayModelBuilder.makeDisplayModels(
            rooms: [roomInput],
            zones: [],
            lights: [light(id: "light-1", isOn: true, brightness: 40)],
            groupedLights: [groupedLight(id: "gl-room", isOn: true, brightness: 77)],
            bridgeID: "bridge-a"
        )
        XCTAssertTrue(glOn.rooms[0].isOn)
        XCTAssertEqual(glOn.rooms[0].brightness, 77, accuracy: 0.0001,
                       "grouped_light brightness stays authoritative when it reports on")
    }

    func testZoneMemberLightCrossCheckMirrorsRooms() {
        let zoneInput = zone(
            id: "zone-1",
            name: "Upstairs",
            children: [ref("z-light-1", "light"), ref("z-light-2", "light")],
            groupedLightID: "gl-zone"
        )
        let lagging = RoomAndZoneDisplayModelBuilder.makeDisplayModels(
            rooms: [],
            zones: [zoneInput],
            lights: [
                light(id: "z-light-1", isOn: true, brightness: 50, xy: (0.4, 0.4)),
                light(id: "z-light-2", isOn: false, brightness: 90),
            ],
            groupedLights: [groupedLight(id: "gl-zone", isOn: false, brightness: 8)],
            bridgeID: "bridge-a"
        )
        XCTAssertTrue(lagging.zones[0].isOn,
                      "zones must apply the same member-light cross-check as rooms")
        XCTAssertEqual(lagging.zones[0].brightness, 50, accuracy: 0.0001)
        XCTAssertEqual(lagging.zones[0].dominantColorX ?? -1, 0.4, accuracy: 0.0001)

        let allOff = RoomAndZoneDisplayModelBuilder.makeDisplayModels(
            rooms: [],
            zones: [zoneInput],
            lights: [
                light(id: "z-light-1", isOn: false, brightness: 50),
                light(id: "z-light-2", isOn: false, brightness: 90),
            ],
            groupedLights: [groupedLight(id: "gl-zone", isOn: false, brightness: 8)],
            bridgeID: "bridge-a"
        )
        XCTAssertFalse(allOff.zones[0].isOn)
    }

    func testOverlapAndMultiBridgeIsolation() {
        let roomA = room(id: "room-a", name: "Room A", children: [ref("shared-light", "light")], groupedLightID: "gl-a")
        let zoneA = zone(id: "zone-a", name: "Zone A", children: [ref("shared-light", "light")], groupedLightID: "gl-z")
        let roomB = room(id: "room-b", name: "Room B", children: [ref("light-b", "light")], groupedLightID: "gl-b")

        let lights = [
            light(id: "shared-light", isOn: true, brightness: 80, xy: (0.2, 0.2)),
            light(id: "light-b", isOn: true, brightness: 40, mirek: 330),
        ]
        let grouped = [
            groupedLight(id: "gl-a", isOn: true, brightness: 66),
            groupedLight(id: "gl-z", isOn: true, brightness: 22),
            groupedLight(id: "gl-b", isOn: true, brightness: 77),
        ]

        let bridgeAResult = RoomAndZoneDisplayModelBuilder.makeDisplayModels(
            rooms: [roomA],
            zones: [zoneA],
            lights: lights,
            groupedLights: grouped,
            bridgeID: "bridge-a"
        )
        let bridgeBResult = RoomAndZoneDisplayModelBuilder.makeDisplayModels(
            rooms: [roomB],
            zones: [],
            lights: lights,
            groupedLights: grouped,
            bridgeID: "bridge-b"
        )

        XCTAssertEqual(bridgeAResult.roomLightMap["shared-light"], "room-a")
        XCTAssertEqual(bridgeAResult.zoneLightMap["shared-light"], "zone-a")
        XCTAssertEqual(bridgeAResult.rooms[0].bridgeID, "bridge-a")
        XCTAssertEqual(bridgeAResult.zones[0].bridgeID, "bridge-a")
        XCTAssertEqual(bridgeBResult.rooms[0].bridgeID, "bridge-b")
        XCTAssertEqual(bridgeBResult.rooms[0].id, "room-b")
    }

    func testInputImmutability() {
        let rooms = [
            room(id: "room-1", name: "Room 1", children: [ref("device-1", "device")], groupedLightID: "gl-1"),
        ]
        let zones = [
            zone(id: "zone-1", name: "Zone 1", children: [ref("light-1", "light")], groupedLightID: "gl-z"),
        ]
        let lights = [
            light(id: "light-1", ownerRID: "device-1", isOn: true, brightness: 50, xy: (0.4, 0.4)),
        ]
        let groupedLights = [
            groupedLight(id: "gl-1", isOn: true, brightness: 60),
            groupedLight(id: "gl-z", isOn: true, brightness: 30),
        ]

        let roomsSnapshot = rooms.map {
            "\($0.id)|\($0.metadata.name)|\($0.children.map(\.rid).joined(separator: ","))|\($0.services.map(\.rid).joined(separator: ","))"
        }
        let zonesSnapshot = zones.map {
            "\($0.id)|\($0.metadata.name)|\($0.children.map(\.rid).joined(separator: ","))|\($0.services.map(\.rid).joined(separator: ","))"
        }
        let lightsSnapshot = lights.map {
            "\($0.id)|\($0.owner?.rid ?? "")|\($0.on.on)|\($0.dimming?.brightness ?? -1)|\($0.color?.xy.x ?? -1)|\($0.color?.xy.y ?? -1)|\($0.color_temperature?.mirek ?? -1)"
        }
        let groupedSnapshot = groupedLights.map {
            "\($0.id)|\($0.on.on)|\($0.dimming?.brightness ?? -1)"
        }

        _ = RoomAndZoneDisplayModelBuilder.makeDisplayModels(
            rooms: rooms,
            zones: zones,
            lights: lights,
            groupedLights: groupedLights,
            bridgeID: "bridge-a"
        )

        XCTAssertEqual(
            rooms.map {
                "\($0.id)|\($0.metadata.name)|\($0.children.map(\.rid).joined(separator: ","))|\($0.services.map(\.rid).joined(separator: ","))"
            },
            roomsSnapshot
        )
        XCTAssertEqual(
            zones.map {
                "\($0.id)|\($0.metadata.name)|\($0.children.map(\.rid).joined(separator: ","))|\($0.services.map(\.rid).joined(separator: ","))"
            },
            zonesSnapshot
        )
        XCTAssertEqual(
            lights.map {
                "\($0.id)|\($0.owner?.rid ?? "")|\($0.on.on)|\($0.dimming?.brightness ?? -1)|\($0.color?.xy.x ?? -1)|\($0.color?.xy.y ?? -1)|\($0.color_temperature?.mirek ?? -1)"
            },
            lightsSnapshot
        )
        XCTAssertEqual(
            groupedLights.map { "\($0.id)|\($0.on.on)|\($0.dimming?.brightness ?? -1)" },
            groupedSnapshot
        )
    }
}
