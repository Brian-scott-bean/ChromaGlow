// HueScene.swift
// HueHome Pro — Epic 4 / Story 4.1
//
// Typed model for the Hue V2 /clip/v2/resource/scene response.
// A scene stores a named set of light actions tied to a room or zone.

import Foundation

struct HueScene: Decodable, Identifiable {
    let id: String
    let metadata: SceneMetadata
    let group: SceneGroup           // links scene to a room or zone
    let status: SceneStatus?        // current activation state (may be absent on older firmware)
    let speed: Double?              // transition speed 0.0–1.0
    let type: String?               // "static" | "dynamic" (CLIP v2 resource type field)

    /// True when this is a Hue dynamic palette scene (colours auto-cycle).
    /// Falls back to checking status.active for older firmware that omits `type`.
    var isDynamic: Bool {
        type == "dynamic" || status?.active == "dynamic_palette"
    }
}

struct SceneMetadata: Decodable {
    let name: String
}

/// The room or zone this scene belongs to.
struct SceneGroup: Decodable {
    let rid: String     // room/zone UUID
    let rtype: String   // "room" | "zone"
}

/// Whether the scene is currently active on the Bridge.
struct SceneStatus: Decodable {
    let active: String?  // "active" | "inactive" | "static" | "dynamic_palette"
}
