// CreateSceneRequest.swift
// CastChroma — Story 4.2
//
// Encodable request body for POST /clip/v2/resource/scene.
// Captures per-light state (on/off, brightness, color, color temp).

import Foundation

// MARK: - CreateSceneRequest

struct CreateSceneRequest: Encodable {

    // CLIP v2 requires "type": "scene" in every POST /resource/scene body.
    // Omitting it causes an immediate HTTP 400 regardless of other fields.
    let type:     String = "scene"
    let metadata: Metadata
    let group:    GroupRef
    let actions:  [SceneAction]
    // Round 3 (E): dynamic-scene authoring. A palette + auto_dynamic makes
    // the bridge cycle colors forever with zero app involvement; `speed`
    // sets the cycle rate (0…1). All nil for classic static scenes —
    // synthesized Encodable omits them (encodeIfPresent).
    var palette:      Palette? = nil
    var speed:        Double?  = nil
    var auto_dynamic: Bool?    = nil
    // Note: `recall` remains PUT-only; palette/speed/auto_dynamic are valid on POST.

    struct Metadata: Encodable {
        let name: String
    }

    /// The dynamic palette the bridge cycles through.
    struct Palette: Encodable {
        struct PaletteColor: Encodable {
            let color:   SceneAction.Action.ColorXY
            let dimming: SceneAction.Action.Dimming
        }
        let color: [PaletteColor]
        let dimming: [SceneAction.Action.Dimming]
        let color_temperature: [SceneAction.Action.ColorTemp]
    }

    struct GroupRef: Encodable {
        let rid:   String
        let rtype: String
    }

    // MARK: - SceneAction

    struct SceneAction: Encodable {
        let target: TargetRef
        let action: Action

        struct TargetRef: Encodable {
            let rid:   String
            let rtype: String
        }

        struct Action: Encodable {
            let on:                 OnState?
            let dimming:            Dimming?
            let color:              ColorXY?
            let color_temperature:  ColorTemp?

            struct OnState:   Encodable { let on: Bool }
            struct Dimming:   Encodable { let brightness: Double }
            struct ColorXY:   Encodable {
                let xy: XY
                struct XY: Encodable { let x: Double; let y: Double }
            }
            struct ColorTemp: Encodable { let mirek: Int }
        }
    }
}

// MARK: - Convenience Builder

extension CreateSceneRequest {

    /// Build a CreateSceneRequest from a room's (or zone's) current light states.
    ///
    /// - Parameters:
    ///   - name:       Human-readable scene name.
    ///   - groupID:    Hue room or zone UUID.
    ///   - groupRtype: `"room"` or `"zone"` — must match what the bridge has for this ID.
    ///   - lights:     Current light states to snapshot.
    static func fromCurrentLights(
        name:       String,
        groupID:    String,
        groupRtype: String = "room",
        lights:     [LightDisplayItem]
    ) -> CreateSceneRequest {
        let actions: [SceneAction] = lights.map { light in
            let action = SceneAction.Action(
                on:      .init(on: light.isOn),
                // Only send dimming for on lights — bridge ignores dimming for off lights
                // in a scene, but some firmware versions reject it with 400.
                dimming: light.isOn ? .init(brightness: max(1.0, min(100.0, light.brightness))) : nil,
                color:   {
                    guard let x = light.colorX, let y = light.colorY else { return nil }
                    // CIE xy values must be in [0, 1] — clamp defensively.
                    return .init(xy: .init(x: max(0, min(1, x)), y: max(0, min(1, y))))
                }(),
                color_temperature: {
                    // Only send CT when there's no colour data (mutually exclusive).
                    guard light.colorX == nil, let mirek = light.colorTempMirek else { return nil }
                    // Clamp to the light's valid mirek range (default 153–500 = 6500K–2000K).
                    let clamped = max(light.mirekMin, min(light.mirekMax, mirek))
                    return .init(mirek: clamped)
                }()
            )
            return SceneAction(
                target: .init(rid: light.id, rtype: "light"),
                action: action
            )
        }

        return CreateSceneRequest(
            metadata: .init(name: name),
            group:    .init(rid: groupID, rtype: groupRtype),
            actions:  actions
        )
    }

    /// Build from raw HueLight objects fetched directly from the bridge.
    /// Used by the global Scenes tab create flow where LightDisplayItem isn't available.
    static func fromHueLights(
        name:       String,
        groupID:    String,
        groupRtype: String = "room",
        lights:     [HueLight]
    ) -> CreateSceneRequest {
        let actions: [SceneAction] = lights.map { light in
            let isOn  = light.on.on
            let mirek = light.color_temperature?.mirek
            let xy    = light.color.map { ($0.xy.x, $0.xy.y) }
            let action = SceneAction.Action(
                on:      .init(on: isOn),
                dimming: isOn ? light.dimming.map { .init(brightness: max(1, min(100, $0.brightness))) } : nil,
                color:   xy.map { .init(xy: .init(x: $0.0, y: $0.1)) },
                color_temperature: (xy == nil && mirek != nil)
                    ? light.color_temperature.flatMap { ct in ct.mirek.map { .init(mirek: $0) } }
                    : nil
            )
            return SceneAction(
                target: .init(rid: light.id, rtype: "light"),
                action: action
            )
        }
        return CreateSceneRequest(
            metadata: .init(name: name),
            group:    .init(rid: groupID, rtype: groupRtype),
            actions:  actions
        )
    }

    /// Round 3 (E): author a NATIVE dynamic scene from a Composer palette.
    /// The bridge cycles `paletteXY` forever — app closed, phone away.
    /// Color-capable lights start on the first palette color; white-only
    /// lights just get brightness (they follow the dimming palette).
    static func dynamicScene(
        name:       String,
        groupID:    String,
        groupRtype: String = "room",
        lights:     [HueLight],
        paletteXY:  [(x: Double, y: Double)],
        brightness: Double = 80,
        speed:      Double = 0.5,
        autoDynamic: Bool = true
    ) -> CreateSceneRequest {
        let bri = max(1.0, min(100.0, brightness))
        // CLIP caps the color palette at 9 entries; clamp xy defensively.
        let palettePoints = paletteXY.prefix(9).map { point in
            Palette.PaletteColor(
                color: .init(xy: .init(x: max(0, min(1, point.x)), y: max(0, min(1, point.y)))),
                dimming: .init(brightness: bri)
            )
        }
        let first = palettePoints.first
        let actions: [SceneAction] = lights.map { light in
            let supportsColor = light.color != nil
            return SceneAction(
                target: .init(rid: light.id, rtype: "light"),
                action: .init(
                    on: .init(on: true),
                    dimming: .init(brightness: bri),
                    color: supportsColor ? first?.color : nil,
                    color_temperature: nil
                )
            )
        }
        return CreateSceneRequest(
            metadata: .init(name: name),
            group:    .init(rid: groupID, rtype: groupRtype),
            actions:  actions,
            palette:  Palette(color: Array(palettePoints),
                              dimming: [.init(brightness: bri)],
                              color_temperature: []),
            speed:    max(0.0, min(1.0, speed)),
            auto_dynamic: autoDynamic
        )
    }
}
