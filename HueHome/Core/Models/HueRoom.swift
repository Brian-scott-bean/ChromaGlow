// HueRoom.swift
// CastChroma — Story 1.2
//
// Typed model for the Hue V2 /clip/v2/resource/room response.

import Foundation

// MARK: - V2 Envelope

struct HueV2Response<T: Decodable>: Decodable {
    let errors: [HueV2Error]
    let data: [T]
}

struct HueV2Error: Decodable {
    let description: String
}

// MARK: - Room

struct HueRoom: Decodable, Identifiable {
    let id: String
    let metadata: RoomMetadata
    let children: [ResourceRef]       // individual light device refs
    let services: [ResourceRef]       // includes grouped_light ref used for on/off

    /// The grouped_light service ID used to toggle the whole room.
    var groupedLightID: String? {
        services.first { $0.rtype == "grouped_light" }?.rid
    }
}

struct RoomMetadata: Decodable {
    let name: String
    let archetype: String?
}

struct ResourceRef: Decodable {
    let rid: String
    let rtype: String
}
