// StudioViewModel.swift
// CastChroma — v0.15.0 Studio Tab
//
// Unified ViewModel replacing EffectsViewModel + SyncModeEngine.
// Owns: card catalog, room selection, param state, apply/stop logic.

import SwiftUI
import Observation

// MARK: - Data Models

struct StudioCard: Identifiable, Hashable {
    let id: String
    let name: String
    let tagline: String
    let icon: String
    let accentColor: Color
    let requiresForeground: Bool
    let params: [StudioParam]
    let strategy: StudioStrategy

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: StudioCard, rhs: StudioCard) -> Bool { lhs.id == rhs.id }
}

struct StudioParam: Identifiable {
    let id: String
    let label: String
    let kind: StudioParamKind
    let defaultValue: Double
    var displayValue: String { "\(Int(defaultValue))" }
}

enum StudioParamKind {
    case slider(min: Double, max: Double)
    case colorPicker
    case toggle
}

enum StudioStrategy {
    // Bridge-native: persists on bridge even after app closes.
    // colorloop/no_effect → grouped_light endpoint (supported natively).
    // candle/fire/sparkle/prism/opal/glisten → per-light calls (grouped_light
    // silently ignores the `effects` field for these; only individual light
    // resources support the full SupportedEffects enum).
    case bridgeNative(effect: String)
    // App-driven: loops in foreground, uses EffectsEngine/SyncEngine internally
    case appDriven(engineKey: String)

    /// Effects that grouped_light natively supports via its own `effects` schema.
    static let groupedLightNativeEffects: Set<String> = ["colorloop", "no_effect"]
}

// MARK: - StudioViewModel

@Observable
final class StudioViewModel {

    // ── Selection state ───────────────────────────────────────
    var selectedRoom: RoomDisplayItem? = nil
    var selectedCard: StudioCard?      = nil
    var runningCardID: String?         = nil

    // ── Param values (keyed by param.id) ─────────────────────
    var paramValues:  [String: Double] = [:]
    var paramColors:  [String: Color]  = [:]

    // ── Engine reference (set in configure()) ─────────────────
    private weak var orchestrator: UnifiedOrchestrator?

    // ── Preset colors for the color picker param ──────────────
    static let presetColors: [Color] = [
        HuePalette.Noir.destructive,   // red
        HuePalette.amberDeep,          // orange
        HuePalette.amber,              // amber
        HuePalette.Noir.success,       // green
        Color(hex: "#0A84FF"),          // blue — system blue, no token yet
        Color(hex: "#BF5AF2"),          // purple — no token yet
        Color.white
    ]

    // ── Card catalogs ─────────────────────────────────────────
    let effectCards: [StudioCard] = StudioViewModel.buildEffectCards()
    let liveModeCards: [StudioCard] = StudioViewModel.buildLiveModeCards()

    // ── Status ────────────────────────────────────────────────
    var statusMessage: String = ""

    @MainActor
    func configure(orchestrator: UnifiedOrchestrator) {
        self.orchestrator = orchestrator
        // Auto-select first room if only one bridge/room available
        if selectedRoom == nil, let first = orchestrator.allRooms.first {
            selectedRoom = first
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Apply / Stop
    // ──────────────────────────────────────────────

    @MainActor
    func apply(_ card: StudioCard) async {
        guard let room = selectedRoom else {
            statusMessage = "⚠ Select a room first"
            return
        }
        guard let groupedLightID = room.groupedLightID else {
            statusMessage = "⚠ Room '\(room.name)' has no grouped light"
            return
        }
        guard let orchestrator else { return }
        guard let api = orchestrator.hueClient(for: room.bridgeID) else { return }

        let brightness = paramValues["brightness"] ?? 70

        switch card.strategy {
        case .bridgeNative(let effectName):
            // ── Hybrid API strategy ──────────────────────────────────────────
            // grouped_light only supports colorloop + no_effect in its effects
            // schema. The richer effects (candle, fire, sparkle, prism, opal,
            // glisten) are only supported by individual light resources.
            // The bridge returns HTTP 200 for grouped_light + complex effect
            // but silently ignores the field — nothing happens.
            //
            // Fix: use grouped_light for colorloop; per-light for everything
            // else. Swallow per-light 400s (unsupported effect on that bulb
            // model) so one incompatible bulb doesn't kill the whole room.
            if StudioStrategy.groupedLightNativeEffects.contains(effectName) {
                try? await api.setGroupedLightNativeEffect(id: groupedLightID, effect: effectName)
            } else {
                let lightIDs = (try? await api.fetchLightIDsForGroup(groupedLightID: groupedLightID)) ?? []
                if lightIDs.isEmpty {
                    statusMessage = "⚠ No lights found in this room"
                    return
                }
                await withTaskGroup(of: Void.self) { group in
                    for id in lightIDs {
                        group.addTask {
                            // try? swallows 400 json-schema errors for bulbs
                            // that don't support this effect (e.g. white-only).
                            try? await api.setLightNativeEffect(id: id, effect: effectName)
                        }
                    }
                }
            }

            if brightness != 70 {
                try? await api.setGroupedLightBrightness(id: groupedLightID, brightness: brightness)
            }
            runningCardID = card.id
            statusMessage = "'\(card.name)' running on bridge — persists after closing ✓"

        case .appDriven(let engineKey):
            await orchestrator.startStudioMode(
                key: engineKey,
                room: room,
                params: paramValues,
                colors: paramColors
            )
            runningCardID = card.id
            statusMessage = "'\(card.name)' running"
        }
    }

    @MainActor
    func stop(_ card: StudioCard) async {
        guard let room = selectedRoom,
              let groupedLightID = room.groupedLightID,
              let orchestrator,
              let api = orchestrator.hueClient(for: room.bridgeID) else { return }

        switch card.strategy {
        case .bridgeNative:
            try? await api.setGroupedLightNativeEffect(id: groupedLightID, effect: "no_effect")
        case .appDriven:
            await orchestrator.stopStudioMode()
        }
        await MainActor.run {
            runningCardID = nil
            statusMessage = ""
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Card Catalog
    // ──────────────────────────────────────────────

    private static func buildEffectCards() -> [StudioCard] {
        let brightnessParam = StudioParam(
            id: "brightness", label: "Brightness",
            kind: .slider(min: 1, max: 100), defaultValue: 70
        )
        let speedParam = StudioParam(
            id: "speed", label: "Speed",
            kind: .slider(min: 0, max: 100), defaultValue: 50
        )

        return [
            StudioCard(
                id: "candle",
                name: "Candle",
                tagline: "Warm flickering flame, perfect for dinner or relaxation",
                icon: "flame.fill",
                accentColor: Color(hex: "#FF9500"),
                requiresForeground: false,
                params: [brightnessParam],
                strategy: .bridgeNative(effect: "candle")
            ),
            StudioCard(
                id: "fire",
                name: "Fire",
                tagline: "Intense fire effect with deep amber and red tones",
                icon: "flame",
                accentColor: Color(hex: "#FF3B30"),
                requiresForeground: false,
                params: [brightnessParam],
                strategy: .bridgeNative(effect: "fire")
            ),
            StudioCard(
                id: "sparkle",
                name: "Sparkle",
                tagline: "Gentle random twinkle across all lights",
                icon: "sparkles",
                accentColor: Color(hex: "#FFC107"),
                requiresForeground: false,
                params: [brightnessParam],
                strategy: .bridgeNative(effect: "sparkle")
            ),
            StudioCard(
                id: "prism",
                name: "Prism",
                tagline: "Slow color cycling through the full spectrum",
                icon: "camera.filters",
                accentColor: Color(hex: "#BF5AF2"),
                requiresForeground: false,
                params: [brightnessParam, speedParam],
                strategy: .bridgeNative(effect: "prism")
            ),
            StudioCard(
                id: "opal",
                name: "Opal",
                tagline: "Iridescent pastel color shifts",
                icon: "circle.hexagongrid.fill",
                accentColor: Color(hex: "#40D9BF"),
                requiresForeground: false,
                params: [brightnessParam],
                strategy: .bridgeNative(effect: "opal")
            ),
            StudioCard(
                id: "glisten",
                name: "Glisten",
                tagline: "Quick bright flashes like sunlight on water",
                icon: "rays",
                accentColor: Color(hex: "#0A84FF"),
                requiresForeground: false,
                params: [brightnessParam],
                strategy: .bridgeNative(effect: "glisten")
            ),
            StudioCard(
                id: "colorloop",
                name: "Color Loop",
                tagline: "Continuous slow hue rotation — classic Hue effect",
                icon: "arrow.triangle.2.circlepath",
                accentColor: Color(hex: "#30D158"),
                requiresForeground: false,
                params: [brightnessParam, speedParam],
                strategy: .bridgeNative(effect: "colorloop")
            ),
        ]
    }

    private static func buildLiveModeCards() -> [StudioCard] {
        let brightnessParam = StudioParam(
            id: "brightness", label: "Brightness",
            kind: .slider(min: 1, max: 100), defaultValue: 80
        )
        let sensitivityParam = StudioParam(
            id: "sensitivity", label: "Sensitivity",
            kind: .slider(min: 0, max: 100), defaultValue: 70
        )
        let speedParam = StudioParam(
            id: "speed", label: "Speed",
            kind: .slider(min: 0, max: 100), defaultValue: 50
        )
        let colorParam = StudioParam(
            id: "color", label: "Color",
            kind: .colorPicker, defaultValue: 0
        )

        return [
            StudioCard(
                id: "music_sync",
                name: "Music Sync",
                tagline: "Lights pulse and flash to your music in real time via microphone",
                icon: "waveform.and.mic",
                accentColor: Color(hex: "#FF4D8C"),
                requiresForeground: true,
                params: [sensitivityParam, brightnessParam],
                strategy: .appDriven(engineKey: "mic")
            ),
            StudioCard(
                id: "gaming",
                name: "Gaming",
                tagline: "Dynamic hue shifts during intense gaming sessions",
                icon: "gamecontroller.fill",
                accentColor: Color(hex: "#0A84FF"),
                requiresForeground: true,
                params: [brightnessParam, speedParam],
                strategy: .appDriven(engineKey: "gaming")
            ),
            StudioCard(
                id: "party",
                name: "Party",
                tagline: "Fast multi-color flashes synchronized across the room",
                icon: "party.popper.fill",
                accentColor: Color(hex: "#BF5AF2"),
                requiresForeground: true,
                params: [speedParam, colorParam],
                strategy: .appDriven(engineKey: "party")
            ),
            StudioCard(
                id: "strobe",
                name: "Strobe",
                tagline: "High-frequency white flash — use responsibly",
                icon: "bolt.fill",
                accentColor: Color(hex: "#FFC107"),
                requiresForeground: true,
                params: [speedParam, brightnessParam],
                strategy: .appDriven(engineKey: "strobe")
            ),
            StudioCard(
                id: "thunderstorm",
                name: "Thunderstorm",
                tagline: "Random lightning strikes with dim ambient fill",
                icon: "cloud.bolt.fill",
                accentColor: Color(hex: "#668AFF"),
                requiresForeground: true,
                params: [brightnessParam],
                strategy: .appDriven(engineKey: "thunderstorm")
            ),
            StudioCard(
                id: "ambient",
                name: "Ambient",
                tagline: "Slow breathing color shifts that blend with your room",
                icon: "aqi.low",
                accentColor: Color(hex: "#40D9BF"),
                requiresForeground: true,
                params: [speedParam, brightnessParam, colorParam],
                strategy: .appDriven(engineKey: "ambient")
            ),
        ]
    }
}
