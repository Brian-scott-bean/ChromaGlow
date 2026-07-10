// HueAppShortcuts.swift
// ChromaGlow — Siri Shortcuts
//
// AppShortcutsProvider donates phrases to Siri automatically at app launch.
// No user setup required — "Hey Siri" works after install + first launch
// (allow a few minutes for the system to index the metadata).
//
// Rules this file lives by (enforced by the appintentsmetadataprocessor):
//   - At most 10 AppShortcuts per app.
//   - At most ONE dynamic parameter per phrase, and it must be an
//     AppEntity/AppEnum — never Int/Bool/String (Siri prompts for those).
//   - Every phrase embeds \(.applicationName): a bare "turn on kitchen"
//     routes to HomeKit, not to us.

import AppIntents

struct HueAppShortcuts: AppShortcutsProvider {

    static var shortcutTileColor: ShortcutTileColor = .yellow

    static var appShortcuts: [AppShortcut] {

        // ── 1. Turn on ──────────────────────────────────────────
        AppShortcut(
            intent: GroupPowerIntent(power: .on),
            phrases: [
                "Turn on \(\.$group) in \(.applicationName)",
                "Switch on \(\.$group) in \(.applicationName)",
                "Turn on the \(\.$group) lights in \(.applicationName)",
            ],
            shortTitle: "Turn On",
            systemImageName: "lightbulb.fill"
        )

        // ── 2. Turn off ─────────────────────────────────────────
        AppShortcut(
            intent: GroupPowerIntent(power: .off),
            phrases: [
                "Turn off \(\.$group) in \(.applicationName)",
                "Switch off \(\.$group) in \(.applicationName)",
                "Turn off the \(\.$group) lights in \(.applicationName)",
            ],
            shortTitle: "Turn Off",
            systemImageName: "lightbulb.slash.fill"
        )

        // ── 3. Set brightness (Siri prompts the number) ─────────
        AppShortcut(
            intent: GroupBrightnessIntent(),
            phrases: [
                "Set \(\.$group) brightness in \(.applicationName)",
                "Dim \(\.$group) in \(.applicationName)",
                "Change \(\.$group) brightness in \(.applicationName)",
            ],
            shortTitle: "Set Brightness",
            systemImageName: "sun.max.fill"
        )

        // ── 4. Set color (Siri prompts the room) ────────────────
        AppShortcut(
            intent: GroupColorIntent(),
            phrases: [
                "Make my lights \(\.$color) in \(.applicationName)",
                "Set my lights to \(\.$color) in \(.applicationName)",
                "Turn my lights \(\.$color) in \(.applicationName)",
            ],
            shortTitle: "Set Color",
            systemImageName: "paintpalette.fill"
        )

        // ── 5. Activate scene ────────────────────────────────────
        AppShortcut(
            intent: RecallSceneIntent(),
            phrases: [
                "Activate \(\.$scene) in \(.applicationName)",
                "Start the scene \(\.$scene) in \(.applicationName)",
                "Set the scene \(\.$scene) in \(.applicationName)",
            ],
            shortTitle: "Activate Scene",
            systemImageName: "theatermasks.fill"
        )
    }
}
