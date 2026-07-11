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

    static var shortcutTileColor: ShortcutTileColor { .yellow }

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

        // ── 6. Lighting preset (whole home unless a room is given) ──
        AppShortcut(
            intent: LightingPresetIntent(),
            phrases: [
                "Set the lights to \(\.$preset) in \(.applicationName)",
                "Apply \(\.$preset) in \(.applicationName)",
                "\(\.$preset) my lights in \(.applicationName)",
            ],
            shortTitle: "Apply Preset",
            systemImageName: "slider.horizontal.3"
        )

        // ── 7. All lights on/off ─────────────────────────────────
        AppShortcut(
            intent: AllLightsIntent(),
            phrases: [
                "Turn \(\.$power) all lights in \(.applicationName)",
                "All lights \(\.$power) in \(.applicationName)",
                "Turn \(\.$power) all the lights in \(.applicationName)",
            ],
            shortTitle: "All Lights",
            systemImageName: "house.fill"
        )

        // ── 8. Start a Composer scene (opens the app) ────────────
        AppShortcut(
            intent: StartCompositionIntent(),
            phrases: [
                "Start \(\.$composition) in \(.applicationName)",
                "Play \(\.$composition) in \(.applicationName)",
                "Run \(\.$composition) in \(.applicationName)",
            ],
            shortTitle: "Start Composer Scene",
            systemImageName: "sparkles"
        )

        // ── 9. Start a Studio effect (opens the app) ─────────────
        AppShortcut(
            intent: StartStudioEffectIntent(),
            phrases: [
                "Start the \(\.$effect) effect in \(.applicationName)",
                "Run \(\.$effect) in \(.applicationName)",
                "Start \(\.$effect) lights in \(.applicationName)",
            ],
            shortTitle: "Start Effect",
            systemImageName: "wand.and.stars"
        )

        // ── 10. Stop effects (lights stay on) ────────────────────
        // ⚠️ THE 10-SHORTCUT HARD CAP IS FULLY ALLOCATED. An 11th entry
        // silently fails at metadata processing — a new Siri-phrased intent
        // must EVICT one of these ten.
        AppShortcut(
            intent: StopLightEffectsIntent(),
            phrases: [
                "Stop the lights in \(.applicationName)",
                "Stop light effects in \(.applicationName)",
                "Stop the light show in \(.applicationName)",
            ],
            shortTitle: "Stop Effects",
            systemImageName: "stop.circle.fill"
        )
    }
}
