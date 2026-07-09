// WidgetIntents.swift
// LightShade — AppIntents that power interactive widget buttons (iOS 17+).
//
// Intents here (all direct, multi-bridge, openAppWhenRun = false):
//   • ToggleRoomIntent     — flip a specific room OR zone on/off
//   • AdjustBrightnessIntent — nudge a room/zone brightness up or down
//   • ActivateSceneIntent  — recall a Hue scene
//   • ApplyPresetIntent    — apply a preset across every room AND zone
//   • AllOffIntent         — turn every room and zone off instantly
//
// All intents read bridge credentials from WidgetDataStore (App Group +
// shared Keychain), fire a direct HTTPS call to each owning bridge, then
// reload widget timelines. Routing is per-group via `bridgeID`.

import AppIntents
import WidgetKit
import Foundation

// MARK: - Shared bridge write helpers

enum BridgeWriter {

    // Shared pinned bridge trust (M-01/D-016) — never trust-all.
    static let session: URLSession = {
        URLSession(configuration: .default, delegate: BridgePinnedTrustDelegate.shared, delegateQueue: nil)
    }()

    /// PUT a grouped_light resource (on/off, dimming, color temperature…).
    static func patchGroupedLight(
        id: String, body: [String: Any],
        ip: String, token: String
    ) async {
        guard let url = URL(string: "https://\(ip)/clip/v2/resource/grouped_light/\(id)") else { return }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "PUT"
        req.setValue("application/json",  forHTTPHeaderField: "Content-Type")
        req.setValue(token,               forHTTPHeaderField: "hue-application-key")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await session.data(for: req)
    }

    /// Recall a scene — mirrors HueAPIClient.activateScene.
    static func recallScene(id: String, ip: String, token: String) async {
        guard let url = URL(string: "https://\(ip)/clip/v2/resource/scene/\(id)") else { return }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(token,              forHTTPHeaderField: "hue-application-key")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["recall": ["action": "active"]])
        _ = try? await session.data(for: req)
    }
}

// MARK: - ToggleRoomIntent

/// Tapping a room/zone row's power button fires this intent.
/// The widget passes the current on-state so we can invert it without
/// a round-trip fetch first. Works for rooms AND zones (both in `groups`).
struct ToggleRoomIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Lights"
    static var description = IntentDescription("Turn a specific room or zone on or off.")
    static var openAppWhenRun: Bool = false

    /// Stable room/zone identifier from WidgetDataStore.
    @Parameter(title: "Group ID")     var roomID: String
    @Parameter(title: "Currently On") var currentlyOn: Bool

    init() { roomID = ""; currentlyOn = false }
    init(roomID: String, currentlyOn: Bool) {
        self.roomID      = roomID
        self.currentlyOn = currentlyOn
    }

    func perform() async throws -> some IntentResult {
        let store = WidgetDataStore.shared
        guard let group = store.groups.first(where: { $0.id == roomID }),
              let creds = store.credentials(for: group.bridgeID),
              let glID  = group.groupedLightId else {
            return .result()
        }
        let newState = !currentlyOn
        await BridgeWriter.patchGroupedLight(
            id: glID,
            body: ["on": ["on": newState]],
            ip: creds.ip, token: creds.token
        )
        store.applyOptimistic(groupID: roomID, isOn: newState)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

// MARK: - SetRoomPowerIntent

/// Backs `ControlWidgetToggle` (Control Center / Lock Screen / Action button).
///
/// Distinct from `ToggleRoomIntent`, which inverts a state the widget captured
/// at render time. A `SetValueIntent` is handed the ABSOLUTE state the user just
/// asked for, so the control can't desync from a stale timeline snapshot.
/// The `value` parameter name is fixed by the SetValueIntent protocol.
@available(iOS 18.0, *)
struct SetRoomPowerIntent: SetValueIntent {
    static var title: LocalizedStringResource = "Set Room Power"
    static var description = IntentDescription("Turn a specific room or zone on or off.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "On")       var value: Bool
    @Parameter(title: "Group ID") var roomID: String

    init() { value = false; roomID = "" }
    init(roomID: String) { self.value = false; self.roomID = roomID }

    func perform() async throws -> some IntentResult {
        let store = WidgetDataStore.shared
        guard let group = store.groups.first(where: { $0.id == roomID }),
              let creds = store.credentials(for: group.bridgeID),
              let glID  = group.groupedLightId else {
            return .result()
        }
        await BridgeWriter.patchGroupedLight(
            id: glID,
            body: ["on": ["on": value]],
            ip: creds.ip, token: creds.token
        )
        store.applyOptimistic(groupID: roomID, isOn: value)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

// MARK: - AdjustBrightnessIntent

/// A −/+ button nudges a room/zone brightness by a delta (percentage points).
/// Reads the cached brightness, clamps to 1–100, and turns the group on.
struct AdjustBrightnessIntent: AppIntent {
    static var title: LocalizedStringResource = "Adjust Brightness"
    static var description = IntentDescription("Raise or lower a room or zone's brightness.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Group ID") var roomID: String
    @Parameter(title: "Delta")    var delta: Int   // e.g. +20 / −20 (percentage points)

    init() { roomID = ""; delta = 0 }
    init(roomID: String, delta: Int) {
        self.roomID = roomID
        self.delta  = delta
    }

    func perform() async throws -> some IntentResult {
        let store = WidgetDataStore.shared
        guard let group = store.groups.first(where: { $0.id == roomID }),
              let creds = store.credentials(for: group.bridgeID),
              let glID  = group.groupedLightId else {
            return .result()
        }
        let target = min(100, max(1, group.brightness + Double(delta)))
        await BridgeWriter.patchGroupedLight(
            id: glID,
            body: ["on": ["on": true], "dimming": ["brightness": target]],
            ip: creds.ip, token: creds.token
        )
        store.applyOptimistic(groupID: roomID, isOn: true, brightness: target)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

// MARK: - ActivateSceneIntent

/// Tapping a scene chip recalls that Hue scene on its owning bridge.
struct ActivateSceneIntent: AppIntent {
    static var title: LocalizedStringResource = "Activate Scene"
    static var description = IntentDescription("Recall a Hue scene.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Scene ID")  var sceneID: String
    @Parameter(title: "Bridge ID") var bridgeID: String
    /// The owning room/zone id — used to mark it on optimistically.
    @Parameter(title: "Group ID")  var groupID: String

    init() { sceneID = ""; bridgeID = ""; groupID = "" }
    init(sceneID: String, bridgeID: String, groupID: String) {
        self.sceneID  = sceneID
        self.bridgeID = bridgeID
        self.groupID  = groupID
    }

    func perform() async throws -> some IntentResult {
        let store = WidgetDataStore.shared
        guard let creds = store.credentials(for: bridgeID.isEmpty ? nil : bridgeID) else {
            return .result()
        }
        await BridgeWriter.recallScene(id: sceneID, ip: creds.ip, token: creds.token)
        if !groupID.isEmpty { store.applyOptimistic(groupID: groupID, isOn: true) }
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

// MARK: - ApplyPresetIntent

/// Tapping a preset chip (Energize / Read / Relax / Sleep) fires this intent.
/// It applies the preset across every room AND zone simultaneously.
struct ApplyPresetIntent: AppIntent {
    static var title: LocalizedStringResource = "Apply Preset"
    static var description = IntentDescription("Apply a lighting preset to all rooms and zones.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Preset ID") var presetID: String   // "energize" | "read" | "relax" | "sleep"

    init() { presetID = "relax" }
    init(presetID: String) { self.presetID = presetID }

    func perform() async throws -> some IntentResult {
        let store = WidgetDataStore.shared
        let (brightness, mirek) = Self.params(for: presetID)
        await withTaskGroup(of: Void.self) { group in
            for item in store.groups {
                guard let glID = item.groupedLightId,
                      let creds = store.credentials(for: item.bridgeID) else { continue }
                let capturedID = glID
                let body: [String: Any] = [
                    "on":      ["on": true],
                    "dimming": ["brightness": brightness],
                    "color_temperature": ["mirek": mirek],
                    "dynamics": ["duration": 800]
                ]
                group.addTask {
                    await BridgeWriter.patchGroupedLight(
                        id: capturedID, body: body, ip: creds.ip, token: creds.token
                    )
                }
            }
        }
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }

    private static func params(for id: String) -> (brightness: Double, mirek: Int) {
        switch PresetChoice(rawValue: id) {
        case .energize: return (100, 156)
        case .read:     return (75,  280)
        case .relax:    return (40,  420)
        case .sleep:    return (6,   490)
        case nil:       return (60,  350)
        }
    }
}

// MARK: - PresetChoice

/// The four built-in presets, as a pickable option for the Control Center /
/// Lock Screen preset control. `rawValue` is the `presetID` ApplyPresetIntent
/// already expects — do not rename the cases.
enum PresetChoice: String, AppEnum, CaseIterable {
    case energize, read, relax, sleep

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Lighting Preset")

    static var caseDisplayRepresentations: [PresetChoice: DisplayRepresentation] = [
        .energize: DisplayRepresentation(title: "Energize", image: .init(systemName: "bolt.fill")),
        .read:     DisplayRepresentation(title: "Read",     image: .init(systemName: "book.fill")),
        .relax:    DisplayRepresentation(title: "Relax",    image: .init(systemName: "moon.stars.fill")),
        .sleep:    DisplayRepresentation(title: "Sleep",    image: .init(systemName: "zzz")),
    ]

    var label: String {
        switch self {
        case .energize: return "Energize"
        case .read:     return "Read"
        case .relax:    return "Relax"
        case .sleep:    return "Sleep"
        }
    }

    var symbolName: String {
        switch self {
        case .energize: return "bolt.fill"
        case .read:     return "book.fill"
        case .relax:    return "moon.stars.fill"
        case .sleep:    return "zzz"
        }
    }
}

// MARK: - WidgetPageIntent

/// Pages the Large widget through the full room+zone list (WidgetKit can't
/// scroll, so ◀ / ▶ buttons step a shared page index instead). The index lives
/// in the App Group; the provider clamps it and the view slices by it.
struct WidgetPageIntent: AppIntent {
    static var title: LocalizedStringResource = "Change Widget Page"
    static var description = IntentDescription("Page through the light list on the Large widget.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Direction") var direction: Int   // +1 next, −1 previous
    @Parameter(title: "Page Size") var pageSize: Int

    init() { direction = 0; pageSize = 6 }
    init(direction: Int, pageSize: Int) {
        self.direction = direction
        self.pageSize  = pageSize
    }

    func perform() async throws -> some IntentResult {
        let store  = WidgetDataStore.shared
        let total  = store.groups.count
        let size   = max(1, pageSize)
        let pages  = max(1, (total + size - 1) / size)
        let next   = store.largePage + direction
        store.largePage = min(max(0, next), pages - 1)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

// MARK: - AllOffIntent

/// Turns every room and zone off — shown as a global power button.
struct AllOffIntent: AppIntent {
    static var title: LocalizedStringResource = "All Lights Off"
    static var description = IntentDescription("Turn off every room and zone at once.")
    static var openAppWhenRun: Bool = false

    init() {}

    func perform() async throws -> some IntentResult {
        let store = WidgetDataStore.shared
        await withTaskGroup(of: Void.self) { group in
            for item in store.groups {
                guard let glID = item.groupedLightId,
                      let creds = store.credentials(for: item.bridgeID) else { continue }
                let capturedID = glID
                group.addTask {
                    await BridgeWriter.patchGroupedLight(
                        id: capturedID, body: ["on": ["on": false]], ip: creds.ip, token: creds.token
                    )
                }
            }
        }
        store.markAllGroups(on: false)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

// MARK: - SetAllLightsPowerIntent

/// Backs the "All Lights" `ControlWidgetToggle` — the master switch on the Lock
/// Screen and in Control Center.
///
/// Turning ON does not merely send `on: true`, which would restore each group's
/// last level: after a Sleep preset the whole house would come back at 6%. It
/// applies a deliberate "welcome home" state instead.
@available(iOS 18.0, *)
struct SetAllLightsPowerIntent: SetValueIntent {
    static var title: LocalizedStringResource = "All Lights"
    static var description = IntentDescription("Turn every room and zone on or off.")
    static var openAppWhenRun: Bool = false

    /// Parameter name fixed by the SetValueIntent protocol.
    @Parameter(title: "On") var value: Bool

    /// Bright enough to be useful, warm enough not to be harsh.
    private static let onBrightness: Double = 80
    private static let onMirek: Int = 350

    init() { value = false }

    func perform() async throws -> some IntentResult {
        let store = WidgetDataStore.shared
        let body: [String: Any] = value
            ? ["on":                ["on": true],
               "dimming":           ["brightness": Self.onBrightness],
               "color_temperature": ["mirek": Self.onMirek],
               "dynamics":          ["duration": 800]]
            : ["on": ["on": false]]

        await withTaskGroup(of: Void.self) { group in
            for item in store.groups {
                guard let glID = item.groupedLightId,
                      let creds = store.credentials(for: item.bridgeID) else { continue }
                let capturedID = glID
                group.addTask {
                    await BridgeWriter.patchGroupedLight(
                        id: capturedID, body: body, ip: creds.ip, token: creds.token
                    )
                }
            }
        }
        store.markAllGroups(on: value, brightness: value ? Self.onBrightness : nil)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
