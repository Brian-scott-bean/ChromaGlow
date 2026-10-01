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
    /// The stored per-light looks, read ONLY for preview colours. Same
    /// tolerance as `palette`: a variant this decode can't read leaves the
    /// preview to the palette or the name tint, never fails the listing.
    let previewActions: [ScenePreviewAction]?

    private enum CodingKeys: String, CodingKey {
        case id, metadata, group, status, speed, type, palette
        case previewActions = "actions"
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
        previewActions = try? c.decode([ScenePreviewAction].self, forKey: .previewActions)
    }

    /// True while the bridge reports the scene recalled. CLIP v2 answers
    /// "inactive" | "static" | "dynamic_palette" — there is no "active",
    /// which the Room page used to test for, so its tiles never said "On now".
    var isRecalled: Bool {
        guard let active = status?.active else { return false }
        return active != "inactive"
    }

    /// True when this is a Hue dynamic palette scene (colours auto-cycle).
    /// Falls back to checking status.active for older firmware that omits `type`.
    var isDynamic: Bool {
        type == "dynamic" || status?.active == "dynamic_palette"
    }

    /// Up to 3 colour points for previews: the dynamic palette when the
    /// scene has one, otherwise the colours its lights are stored at ([] when
    /// neither can be read — the card falls back to its name tint).
    ///
    /// A plain scene has no palette, so every one of them used to preview in
    /// a tint guessed from its NAME — the red/blue/green "Test 1" showed
    /// lavender (build-60 regression M-4).
    var paletteXY: [SceneXY] {
        if let entries = palette?.color {
            let points = entries.prefix(3).compactMap { entry -> SceneXY? in
                guard let xy = entry.color?.xy else { return nil }
                return SceneXY(x: xy.x, y: xy.y)
            }
            if !points.isEmpty { return points }
        }
        return Self.previewXY(from: previewActions ?? [])
    }

    /// Distinct colours of the lights a scene turns on, in stored order, up
    /// to three. A white is placed on the black-body curve from its mirek.
    static func previewXY(from actions: [ScenePreviewAction]) -> [SceneXY] {
        var out: [SceneXY] = []
        for entry in actions {
            let state = entry.action
            guard state?.on?.on != false else { continue }
            let point: SceneXY
            if let xy = state?.color?.xy {
                point = SceneXY(x: xy.x, y: xy.y)
            } else if let mirek = state?.color_temperature?.mirek {
                let xy = HueColorUtils.planckianXY(mirek: mirek)
                point = SceneXY(x: xy.x, y: xy.y)
            } else {
                continue
            }
            // "Distinct" to the eye — two lights a hair apart are one colour.
            let isNew = out.allSatisfy { abs($0.x - point.x) > 0.01 || abs($0.y - point.y) > 0.01 }
            if isNew { out.append(point) }
            if out.count == 3 { break }
        }
        return out
    }
}

/// One stored scene action, decoded leniently for previews: every field is
/// optional and unknown keys (gradient, effects…) are ignored.
struct ScenePreviewAction: Decodable {
    let action: SceneActionState?
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
