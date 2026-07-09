// HueHomeWidgetControl.swift
// HueHome Pro — Control Center / Lock Screen / Action button controls (iOS 18+).
//
// WHY THIS EXISTS
// Lock Screen *accessory* widgets are not a reliable interactive surface on iOS:
// a tap tends to fall through and launch the app rather than run the button's
// intent. Controls are the sanctioned surface — the system runs their AppIntent
// directly, with the device still locked. Each control below is a thin shell
// over an intent that already exists in WidgetIntents.swift.
//
// Controls (registered in HueHomeWidgetBundle behind an availability check):
//   • RoomToggleControl — pick a room/zone, toggle it on/off
//   • SceneControl      — pick a saved Hue scene, recall it
//   • PresetControl     — pick Energize/Read/Relax/Sleep, apply everywhere
//   • AllOffControl     — kill every light on every bridge
//
// The value providers read WidgetDataStore (App Group + shared Keychain) ONLY.
// They must never hit the network: the system renders controls on demand and a
// slow provider shows a stale or blank control. Writes go through BridgeWriter's
// pinned-trust session (D-016), exactly as the widget buttons do.

import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Room toggle

/// Configuration: which room or zone does this control drive?
@available(iOS 18.0, *)
struct SelectRoomControlIntent: ControlConfigurationIntent {
    static var title: LocalizedStringResource = "Select Room"
    static var description = IntentDescription("Choose the room or zone this control turns on and off.")

    @Parameter(title: "Room or Zone")
    var room: RoomAppEntity?

    init() {}
}

/// The rendered state of the room control: its name and current on/off.
struct RoomControlValue {
    let id: String
    let name: String
    let isOn: Bool

    static let placeholder = RoomControlValue(id: "", name: "Lights", isOn: false)
}

@available(iOS 18.0, *)
struct RoomControlProvider: AppIntentControlValueProvider {
    typealias Configuration = SelectRoomControlIntent
    typealias Value = RoomControlValue

    func previewValue(configuration: SelectRoomControlIntent) -> RoomControlValue {
        guard let room = configuration.room else { return .placeholder }
        return RoomControlValue(id: room.id, name: room.name, isOn: false)
    }

    func currentValue(configuration: SelectRoomControlIntent) async throws -> RoomControlValue {
        guard let room  = configuration.room,
              let group = WidgetDataStore.shared.groups.first(where: { $0.id == room.id })
        else {
            // Configured against a group that no longer exists (bridge forgotten,
            // room deleted). Keep the chosen name so the control isn't nameless.
            return RoomControlValue(id: configuration.room?.id ?? "",
                                    name: configuration.room?.name ?? "Lights",
                                    isOn: false)
        }
        return RoomControlValue(id: group.id, name: group.name, isOn: group.isOn)
    }
}

@available(iOS 18.0, *)
struct RoomToggleControl: ControlWidget {
    static let kind = "com.lightshade.app.RoomToggleControl"

    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: Self.kind, provider: RoomControlProvider()) { value in
            ControlWidgetToggle(
                value.name,
                isOn: value.isOn,
                action: SetRoomPowerIntent(roomID: value.id)
            ) { isOn in
                Label(isOn ? "On" : "Off",
                      systemImage: isOn ? "lightbulb.fill" : "lightbulb.slash")
            }
            .tint(.orange)
        }
        .displayName("Room Lights")
        .description("Turn a room or zone on and off.")
        .promptsForUserConfiguration()
    }
}

// MARK: - Scene

/// Configuration: which saved Hue scene does this control recall?
@available(iOS 18.0, *)
struct SelectSceneControlIntent: ControlConfigurationIntent {
    static var title: LocalizedStringResource = "Select Scene"
    static var description = IntentDescription("Choose the scene this control activates.")

    @Parameter(title: "Scene")
    var scene: SceneAppEntity?

    init() {}
}

struct SceneControlValue {
    let id: String
    let name: String
    let bridgeID: String
    let groupID: String

    static let placeholder = SceneControlValue(id: "", name: "Scene", bridgeID: "", groupID: "")

    init(id: String, name: String, bridgeID: String, groupID: String) {
        self.id = id; self.name = name; self.bridgeID = bridgeID; self.groupID = groupID
    }

    init(_ entity: SceneAppEntity) {
        self.init(id: entity.id, name: entity.name,
                  bridgeID: entity.bridgeID, groupID: entity.ownerGroupID)
    }
}

@available(iOS 18.0, *)
struct SceneControlProvider: AppIntentControlValueProvider {
    typealias Configuration = SelectSceneControlIntent
    typealias Value = SceneControlValue

    func previewValue(configuration: SelectSceneControlIntent) -> SceneControlValue {
        configuration.scene.map(SceneControlValue.init) ?? .placeholder
    }

    func currentValue(configuration: SelectSceneControlIntent) async throws -> SceneControlValue {
        // A scene has no live state to show, but resolve against the store anyway
        // so a renamed scene picks up its new name. Fall back to the saved entity.
        guard let scene = configuration.scene else { return .placeholder }
        if let fresh = WidgetDataStore.shared.scenes.first(where: { $0.id == scene.id }) {
            return SceneControlValue(SceneAppEntity(fresh))
        }
        return SceneControlValue(scene)
    }
}

@available(iOS 18.0, *)
struct SceneControl: ControlWidget {
    static let kind = "com.lightshade.app.SceneControl"

    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: Self.kind, provider: SceneControlProvider()) { value in
            ControlWidgetButton(action: ActivateSceneIntent(
                sceneID: value.id, bridgeID: value.bridgeID, groupID: value.groupID
            )) {
                Label(value.name, systemImage: "wand.and.stars")
            }
            .tint(.orange)
        }
        .displayName("Activate Scene")
        .description("Recall a saved Hue scene.")
        .promptsForUserConfiguration()
    }
}

// MARK: - Preset

/// Configuration: which of the four built-in presets does this control apply?
@available(iOS 18.0, *)
struct SelectPresetControlIntent: ControlConfigurationIntent {
    static var title: LocalizedStringResource = "Select Preset"
    static var description = IntentDescription("Choose the lighting preset this control applies.")

    @Parameter(title: "Preset", default: .relax)
    var preset: PresetChoice

    init() {}
}

@available(iOS 18.0, *)
struct PresetControlProvider: AppIntentControlValueProvider {
    typealias Configuration = SelectPresetControlIntent
    typealias Value = PresetChoice

    func previewValue(configuration: SelectPresetControlIntent) -> PresetChoice {
        configuration.preset
    }

    func currentValue(configuration: SelectPresetControlIntent) async throws -> PresetChoice {
        configuration.preset
    }
}

@available(iOS 18.0, *)
struct PresetControl: ControlWidget {
    static let kind = "com.lightshade.app.PresetControl"

    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: Self.kind, provider: PresetControlProvider()) { preset in
            ControlWidgetButton(action: ApplyPresetIntent(presetID: preset.rawValue)) {
                Label(preset.label, systemImage: preset.symbolName)
            }
            .tint(.orange)
        }
        .displayName("Lighting Preset")
        .description("Apply a preset to every room and zone.")
        .promptsForUserConfiguration()
    }
}

// MARK: - All off

@available(iOS 18.0, *)
struct AllOffControl: ControlWidget {
    static let kind = "com.lightshade.app.AllOffControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: AllOffIntent()) {
                Label("All Off", systemImage: "power")
            }
            .tint(.orange)
        }
        .displayName("All Lights Off")
        .description("Turn off every room and zone.")
    }
}
