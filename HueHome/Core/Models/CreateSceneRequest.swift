// CreateSceneRequest.swift
// HueHome Pro — Story 4.2
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
    // Note: speed/dynamics are only valid in PUT (recall), not POST (create).

    struct Metadata: Encodable {
        let name: String
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

    /// Build a CreateSceneRequest from a room's current light states.
    static func fromCurrentLights(
        name:   String,
        roomID: String,
        lights: [LightDisplayItem]
    ) -> CreateSceneRequest {
        let actions: [SceneAction] = lights.map { light in
            let action = SceneAction.Action(
                on:      .init(on: light.isOn),
                dimming: light.isOn ? .init(brightness: max(1, light.brightness)) : nil,
                color:   {
                    if let x = light.colorX, let y = light.colorY {
                        return .init(xy: .init(x: x, y: y))
                    }
                    return nil
                }(),
                color_temperature: {
                    if light.colorX == nil, let mirek = light.colorTempMirek {
                        return .init(mirek: mirek)
                    }
                    return nil
                }()
            )
            return SceneAction(
                target: .init(rid: light.id, rtype: "light"),
                action: action
            )
        }

        return CreateSceneRequest(
            metadata: .init(name: name),
            group:    .init(rid: roomID, rtype: "room"),
            actions:  actions
        )
    }
}
