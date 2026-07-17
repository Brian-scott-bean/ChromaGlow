import Foundation

enum RoomAndZoneDisplayModelBuilder {
    static func makeDisplayModels(
        rooms: [HueRoom],
        zones: [HueZone],
        lights: [HueLight],
        groupedLights: [HueGroupedLight],
        bridgeID: String
    ) -> (
        rooms: [RoomDisplayItem],
        zones: [RoomDisplayItem],
        roomLightMap: [String: String],
        zoneLightMap: [String: String]
    ) {
        // Keys come straight from the bridge; a duplicated id must not trap
        // the dashboard rebuild (audit L-26).
        let glByID = Dictionary(groupedLights.map { ($0.id, $0) },
                                uniquingKeysWith: { first, _ in first })

        var roomItems: [RoomDisplayItem] = []
        var roomLightMap: [String: String] = [:]
        for room in rooms {
            var isOn = false
            var brightness = 100.0
            if let glID = room.groupedLightID, let gl = glByID[glID] {
                isOn = gl.on.on
                brightness = max(1, gl.dimming?.brightness ?? 100)
            }
            let roomLights = lights.filter { light in
                room.children.contains { ref in
                    ref.rid == light.id || ref.rid == (light.owner?.rid ?? "")
                }
            }

            // grouped_light can lag after scene activation / per-light control
            // and report off while member lights are on. Trust the lights —
            // same cross-check RoomDetailViewModel.loadRoomState applies.
            // One-directional: lights can prove a room ON, never off.
            if !isOn {
                let onLights = roomLights.filter { $0.on.on }
                if !onLights.isEmpty {
                    isOn = true
                    let avg = onLights
                        .map { $0.dimming?.brightness ?? 100 }
                        .reduce(0, +) / Double(onLights.count)
                    brightness = max(1, avg)
                }
            }

            var dominantColorXY: (x: Double, y: Double)? = nil
            var dominantMirek: Int? = nil
            if isOn {
                let onLights = roomLights.filter { $0.on.on }
                if let best = onLights.filter({ $0.color != nil })
                    .max(by: { ($0.dimming?.brightness ?? 0) < ($1.dimming?.brightness ?? 0) }) {
                    dominantColorXY = (best.color!.xy.x, best.color!.xy.y)
                } else if let best = onLights.filter({ $0.color_temperature?.mirek != nil })
                    .max(by: { ($0.dimming?.brightness ?? 0) < ($1.dimming?.brightness ?? 0) }),
                    let mirek = best.color_temperature?.mirek {
                    dominantMirek = mirek
                }
            }

            for light in roomLights { roomLightMap[light.id] = room.id }
            roomItems.append(
                RoomDisplayItem(
                    id: room.id,
                    name: room.metadata.name,
                    archetype: room.metadata.archetype,
                    isOn: isOn,
                    brightness: brightness,
                    groupedLightID: room.groupedLightID,
                    lightCount: roomLights.count,
                    bridgeID: bridgeID,
                    childResourceRefs: room.children.map { ($0.rid, $0.rtype) },
                    dominantColorX: dominantColorXY?.x,
                    dominantColorY: dominantColorXY?.y,
                    dominantMirek: dominantMirek
                )
            )
        }

        var zoneItems: [RoomDisplayItem] = []
        var zoneLightMap: [String: String] = [:]
        for zone in zones {
            var isOn = false
            var brightness = 100.0
            if let glID = zone.groupedLightID, let gl = glByID[glID] {
                isOn = gl.on.on
                brightness = max(1, gl.dimming?.brightness ?? 100)
            }
            let zoneLights = lights.filter { light in
                zone.children.contains { $0.rid == light.id }
            }

            // Same grouped_light-lag cross-check as rooms above.
            if !isOn {
                let onLights = zoneLights.filter { $0.on.on }
                if !onLights.isEmpty {
                    isOn = true
                    let avg = onLights
                        .map { $0.dimming?.brightness ?? 100 }
                        .reduce(0, +) / Double(onLights.count)
                    brightness = max(1, avg)
                }
            }

            var dominantColorXY: (x: Double, y: Double)? = nil
            var dominantMirek: Int? = nil
            if isOn {
                let onLights = zoneLights.filter { $0.on.on }
                if let best = onLights.filter({ $0.color != nil })
                    .max(by: { ($0.dimming?.brightness ?? 0) < ($1.dimming?.brightness ?? 0) }) {
                    dominantColorXY = (best.color!.xy.x, best.color!.xy.y)
                } else if let best = onLights.filter({ $0.color_temperature?.mirek != nil })
                    .max(by: { ($0.dimming?.brightness ?? 0) < ($1.dimming?.brightness ?? 0) }),
                    let mirek = best.color_temperature?.mirek {
                    dominantMirek = mirek
                }
            }

            for light in zoneLights { zoneLightMap[light.id] = zone.id }
            var item = RoomDisplayItem(
                id: zone.id,
                name: zone.metadata.name,
                archetype: zone.metadata.archetype,
                isOn: isOn,
                brightness: brightness,
                groupedLightID: zone.groupedLightID,
                lightCount: zoneLights.count,
                bridgeID: bridgeID,
                childResourceRefs: zone.children.map { ($0.rid, $0.rtype) },
                dominantColorX: dominantColorXY?.x,
                dominantColorY: dominantColorXY?.y,
                dominantMirek: dominantMirek
            )
            item.kind = .zone
            zoneItems.append(item)
        }

        return (
            rooms: roomItems,
            zones: zoneItems,
            roomLightMap: roomLightMap,
            zoneLightMap: zoneLightMap
        )
    }
}
