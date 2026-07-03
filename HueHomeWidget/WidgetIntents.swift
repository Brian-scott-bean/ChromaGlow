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
        switch id {
        case "energize": return (100, 156)
        case "read":     return (75,  280)
        case "relax":    return (40,  420)
        case "sleep":    return (6,   490)
        default:         return (60,  350)
        }
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
        store.markAllGroupsOff()
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
