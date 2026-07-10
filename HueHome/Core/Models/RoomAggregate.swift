// RoomAggregate.swift
// CastChroma — room/zone master-bar aggregate (live-update fix).
//
// RoomDetail's master switch and brightness slider were an on-appear
// snapshot: turning lights off one by one left the bar lit until the user
// left and re-entered the screen. The aggregate is derived from the room's
// COMPLETE member-light list, so — unlike the dashboard's deliberate
// ON-only cross-check over partial state — the all-off ⇒ off direction is
// safe to conclude here.

import Foundation

enum RoomAggregate {
    struct State: Equatable {
        var isOn: Bool
        var brightness: Double
    }

    /// isOn = any member on; brightness = average brightness of ON members,
    /// clamped to the 1–100 UI range. When nothing is on, brightness holds
    /// `fallbackBrightness` so the slider stays where the user left it
    /// instead of snapping to a default when the room comes back on.
    static func derive(from lights: [LightDisplayItem],
                       fallbackBrightness: Double) -> State {
        let onLights = lights.filter(\.isOn)
        guard !onLights.isEmpty else {
            return State(isOn: false, brightness: fallbackBrightness)
        }
        let average = onLights.map(\.brightness).reduce(0, +) / Double(onLights.count)
        return State(isOn: true, brightness: min(100, max(1, average)))
    }
}
