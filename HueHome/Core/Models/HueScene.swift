// HueScene.swift
// CastChroma — Epic 4 / Story 4.1
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
    /// Scene-level palette from the LIST payload, used for true-color
    /// previews. Decode-TOLERANT by construction — scene listing must never
    /// depend on palette (or any optional field) decoding; only id/metadata/
    /// group can fail an element.
    let palette: ScenePaletteDetail?

    private enum CodingKeys: String, CodingKey {
        case id, metadata, group, status, speed, type, palette
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id       = try c.decode(String.self, forKey: .id)
        metadata = try c.decode(SceneMetadata.self, forKey: .metadata)
        group    = try c.decode(SceneGroup.self, forKey: .group)
        status   = try? c.decode(SceneStatus.self, forKey: .status)
        speed    = try? c.decode(Double.self, forKey: .speed)
        type     = try? c.decode(String.self, forKey: .type)
        palette  = try? c.decode(ScenePaletteDetail.self, forKey: .palette)
    }

    /// True when this is a Hue dynamic palette scene (colours auto-cycle).
    /// Falls back to checking status.active for older firmware that omits `type`.
    var isDynamic: Bool {
        type == "dynamic" || status?.active == "dynamic_palette"
    }

    /// Up to 3 palette color points for previews ([] when absent/foreign).
    var paletteXY: [SceneXY] {
        guard let entries = palette?.color else { return [] }
        return entries.prefix(3).compactMap { entry in
            guard let xy = entry.color?.xy else { return nil }
            return SceneXY(x: xy.x, y: xy.y)
        }
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

// ══════════════════════════════════════════════════════════
// MARK: - HueSceneDetail (on-demand GET /scene/{id})
// ══════════════════════════════════════════════════════════
//
// Full scene resource, fetched ONLY when a flow needs the stored per-light
// actions (scene copy/move). DELIBERATELY separate from the HueScene list
// decode: `decode` is all-or-nothing across the response array, and odd
// firmware action variants (gradient/effect blocks) must never be able to
// break scene LISTING. Every action field is optional; unknown keys are
// ignored by Codable.

struct HueSceneDetail: Decodable, Identifiable {
    let id: String
    let metadata: SceneMetadata
    let group: SceneGroup
    let actions: [SceneActionDetail]?
    let palette: ScenePaletteDetail?
    let speed: Double?
    let auto_dynamic: Bool?
}

/// One stored action: which light, and what it's set to.
struct SceneActionDetail: Decodable {
    let target: SceneActionTarget
    let action: SceneActionState
}

struct SceneActionTarget: Decodable {
    let rid: String
    let rtype: String   // "light"
}

struct SceneActionState: Decodable {
    let on: SceneActionOn?
    let dimming: SceneActionDimming?
    let color: SceneActionColor?
    let color_temperature: SceneActionCT?
}

struct SceneActionOn: Decodable { let on: Bool }
struct SceneActionDimming: Decodable { let brightness: Double? }
struct SceneActionColor: Decodable {
    struct XY: Decodable { let x: Double; let y: Double }
    let xy: XY?
}
struct SceneActionCT: Decodable { let mirek: Int? }

/// Dynamic-scene palette (scene-level, not per-light — copies across rooms
/// verbatim). Only the color entries are re-encoded on copy; CT palette
/// entries are rare and dropped with a preview note.
struct ScenePaletteDetail: Decodable {
    struct ColorEntry: Decodable {
        let color: SceneActionColor?
        let dimming: SceneActionDimming?
    }
    let color: [ColorEntry]?
    let dimming: [SceneActionDimming]?
}
