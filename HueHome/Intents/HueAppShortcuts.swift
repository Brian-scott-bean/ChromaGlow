// HueAppShortcuts.swift
// CastChroma — Siri Shortcuts
//
// AppShortcutsProvider donates phrases to Siri automatically at app launch.
// No user setup required — "Hey Siri" works immediately after install.
//
// Phrases users can say:
//   "Turn on Living Room in HueHome"
//   "Turn off Kitchen in HueHome"
//   "Set Living Room to 50 percent in HueHome"
//   "Set brightness of Bedroom in HueHome"

import AppIntents

struct HueAppShortcuts: AppShortcutsProvider {

    static var shortcutTileColor: ShortcutTileColor = .yellow

    static var appShortcuts: [AppShortcut] {

        // ── Toggle room on/off ──────────────────────────────────
        AppShortcut(
            intent: ToggleRoomIntent(),
            phrases: [
                "Turn on \(\.$room) in \(.applicationName)",
                "Turn off \(\.$room) in \(.applicationName)",
                "Switch on \(\.$room) in \(.applicationName)",
                "Switch off \(\.$room) in \(.applicationName)",
            ],
            shortTitle: "Toggle Room",
            systemImageName: "lightbulb.fill"
        )

        // ── Set brightness ──────────────────────────────────────
        AppShortcut(
            intent: SetBrightnessIntent(),
            phrases: [
                "Set \(\.$room) to \(\.$brightness) percent in \(.applicationName)",
                "Set brightness of \(\.$room) in \(.applicationName)",
                "Dim \(\.$room) in \(.applicationName)",
            ],
            shortTitle: "Set Brightness",
            systemImageName: "sun.max.fill"
        )
    }
}
