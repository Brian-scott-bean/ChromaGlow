// WidgetIntents.swift
// LightShade — AppIntents that power interactive widget buttons (iOS 17+).
//
// Three intents live here:
//   • ToggleRoomIntent  — tap to flip a specific room on/off
//   • ApplyPresetIntent — tap a preset chip to apply across all rooms
//   • AllOffIntent      — turn every room off instantly
//
// All intents read bridge credentials from WidgetDataStore (App Group),
// fire a direct HTTPS call to the bridge, then reload widget timelines.

import AppIntents
import WidgetKit
import Foundation

// MARK: - Shared bridge write helpers

private enum BridgeWriter {

    // Shared pinned bridge trust (M-01/D-016) — never trust-all.
    static let session: URLSession = {
        URLSession(configuration: .default, delegate: BridgePinnedTrustDelegate.shared, delegateQueue: nil)
    }()

    // PATCH a grouped_light resource.
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
}

// MARK: - ToggleRoomIntent

/// Tapping a room row's power button fires this intent.
/// The widget passes the current on-state so we can invert it without
/// a round-trip fetch first.
struct ToggleRoomIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Room"
    static var description = IntentDescription("Turn a specific room on or off.")
    static var openAppWhenRun: Bool = false

    /// Stable room identifier from WidgetDataStore.
    @Parameter(title: "Room ID")      var roomID: String
    @Parameter(title: "Currently On") var currentlyOn: Bool

    init() { roomID = ""; currentlyOn = false }
    init(roomID: String, currentlyOn: Bool) {
        self.roomID      = roomID
        self.currentlyOn = currentlyOn
    }

    func perform() async throws -> some IntentResult {
        let store = WidgetDataStore.shared
        guard let room  = store.rooms.first(where: { $0.id == roomID }),
              let creds = store.credentials(for: room.bridgeID),
              let glID  = room.groupedLightId else {
            return .result()
        }
        let newState: Bool = !currentlyOn
        await BridgeWriter.patchGroupedLight(
            id: glID,
            body: ["on": ["on": newState]],
            ip: creds.ip, token: creds.token
        )
        // Update cached snapshot so widget shows correct state before next refresh
        var updated = store.rooms
        if let idx = updated.firstIndex(where: { $0.id == roomID }) {
            updated[idx].isOn = newState
        }
        store.write(rooms: updated)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

// MARK: - ApplyPresetIntent

/// Tapping a preset chip (Energize / Read / Relax / Sleep) fires this intent.
/// It applies the preset across every room simultaneously.
struct ApplyPresetIntent: AppIntent {
    static var title: LocalizedStringResource = "Apply Preset"
    static var description = IntentDescription("Apply a lighting preset to all rooms.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Preset ID") var presetID: String   // "energize" | "read" | "relax" | "sleep"

    init() { presetID = "relax" }
    init(presetID: String) { self.presetID = presetID }

    func perform() async throws -> some IntentResult {
        let store = WidgetDataStore.shared
        let (brightness, mirek) = Self.params(for: presetID)
        await withTaskGroup(of: Void.self) { group in
            for room in store.rooms {
                guard let glID = room.groupedLightId,
                      let creds = store.credentials(for: room.bridgeID) else { continue }
                let capturedID = glID
                let body: [String: Any] = [
                    "on":      ["on": true],
                    "dimming": ["brightness": brightness],
                    "color_temperature": ["mirek": mirek],
                    "dynamics": ["duration": 800]
                ]
                group.addTask {
                    await BridgeWriter.patchGroupedLight(
                        id: capturedID,
                        body: body,
                        ip: creds.ip,
                        token: creds.token
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

/// Turns every room off — shown as a global power button in the small widget.
struct AllOffIntent: AppIntent {
    static var title: LocalizedStringResource = "All Lights Off"
    static var description = IntentDescription("Turn off every room at once.")
    static var openAppWhenRun: Bool = false

    init() {}

    func perform() async throws -> some IntentResult {
        let store = WidgetDataStore.shared
        await withTaskGroup(of: Void.self) { group in
            for room in store.rooms {
                guard let glID = room.groupedLightId,
                      let creds = store.credentials(for: room.bridgeID) else { continue }
                let capturedID = glID
                let body: [String: Any] = ["on": ["on": false]]
                group.addTask {
                    await BridgeWriter.patchGroupedLight(
                        id: capturedID,
                        body: body,
                        ip: creds.ip,
                        token: creds.token
                    )
                }
            }
        }
        // Optimistically mark all rooms off in cache
        let allOff = store.rooms.map { r -> WidgetRoomSnapshot in
            var copy = r; copy.isOn = false; return copy
        }
        store.write(rooms: allOff)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
