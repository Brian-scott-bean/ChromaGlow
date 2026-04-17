// HueZone.swift
// HueHome Pro — Stage 2B
//
// Hue CLIP v2 Zone model.
//
// Key difference from HueRoom:
//   Room.children  → device refs  (rtype: "device") — lights are services of those devices
//   Zone.children  → light refs   (rtype: "light")  — lights referenced directly
//
// This means zone light matching never needs the device-owner fallback
// and the lightIDToZoneID reverse map is trivially built (light.id == ref.rid).

import Foundation

struct HueZone: Decodable, Identifiable {
    let id: String
    let metadata: RoomMetadata    // shared type from HueRoom.swift
    let children: [ResourceRef]   // rtype: "light" — direct light UUID refs
    let services: [ResourceRef]   // includes grouped_light ref for on/off/brightness

    /// The grouped_light service used to toggle and dim the entire zone.
    var groupedLightID: String? {
        services.first { $0.rtype == "grouped_light" }?.rid
    }
}
