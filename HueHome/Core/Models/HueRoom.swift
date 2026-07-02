// HueRoom.swift
// CastChroma — Story 1.2
//
// Typed model for the Hue V2 /clip/v2/resource/room response.

import Foundation

// MARK: - V2 Envelope

struct HueV2Response<T: Decodable>: Decodable {
    let errors: [HueV2Error]
    let data: [T]

    private enum CodingKeys: String, CodingKey {
        case errors, data
    }

    /// L-27: elements decode leniently — one malformed resource in `data` is
    /// skipped instead of failing the whole fetch (a single out-of-spec light
    /// used to blank every room on the dashboard).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        errors = (try? container.decodeIfPresent([HueV2Error].self, forKey: .errors)) ?? []
        let wrapped = try container.decode([FailableDecodable<T>].self, forKey: .data)
        data = wrapped.compactMap(\.value)
    }
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
