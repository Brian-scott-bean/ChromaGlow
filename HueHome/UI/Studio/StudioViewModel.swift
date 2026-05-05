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
    let tier: ParamTier
    var displayValue: String { "\(Int(defaultValue))" }

    enum ParamTier: String {
        case essential  // Always visible in compact mixer tray
        case color      // Color section of param sheet
        case advanced   // Advanced section of param sheet
    }
}

enum StudioParamKind {
    case slider(min: Double, max: Double)
    case colorPicker
    case toggle
}

enum StudioStrategy {
    case bridgeNative(effect: String)
    case appDriven(engineKey: String)

    static let groupedLightNativeEffects: Set<String> = ["colorloop", "no_effect"]
}

// MARK: - StudioViewModel

@Observable
final class StudioViewModel {

    // ── Selection state ───────────────────────────────────────
    var selectedRoom: RoomDisplayItem? = nil
    var selectedCard: StudioCard?      = nil
    var runningCardID: String?         = nil

    // ── Param values (namespaced: cardID → paramID → value) ──
    // Composition-ready: each card gets its own param namespace.
    var paramValues:  [String: [String: Double]] = [:]
    var paramColors:  [String: [String: Color]]  = [:]

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
        if selectedRoom == nil, let first = orchestrator.allRooms.first {
            selectedRoom = first
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Param Access (composition-ready)
    // ──────────────────────────────────────────────

    /// Read a param value for a specific card, falling back to the param's default.
    func paramValue(for cardID: String, paramID: String, default defaultVal: Double) -> Double {
        paramValues[cardID]?[paramID] ?? defaultVal
    }

    /// Write a param value for a specific card.
    func setParamValue(for cardID: String, paramID: String, value: Double) {
        if paramValues[cardID] == nil { paramValues[cardID] = [:] }
        paramValues[cardID]?[paramID] = value
    }

    /// Read a param color for a specific card.
    func paramColor(for cardID: String, paramID: String) -> Color? {
        paramColors[cardID]?[paramID]
    }

    /// Write a param color for a specific card.
    func setParamColor(for cardID: String, paramID: String, color: Color) {
        if paramColors[cardID] == nil { paramColors[cardID] = [:] }
        paramColors[cardID]?[paramID] = color
    }

    // ──────────────────────────────────────────────
    // MARK: - Apply / Stop
    // ──────────────────────────────────────────────

    @MainActor
    func apply(_ card: StudioCard) async {
        print("[Studio] apply '\(card.name)' — selectedRoom: \(selectedRoom?.name ?? "nil")")
        guard let room = selectedRoom else {
            statusMessage = "⚠ Select a room first"
            print("[Studio] ❌ No room selected")
            return
        }
        guard let groupedLightID = room.groupedLightID else {
            statusMessage = "⚠ Room '\(room.name)' has no grouped light"
            print("[Studio] ❌ Room '\(room.name)' has no groupedLightID")
            return
        }
        guard let orchestrator else {
            print("[Studio] ❌ orchestrator is nil")
            return
        }
        guard let api = orchestrator.hueClient(for: room.bridgeID) else {
            print("[Studio] ❌ hueClient(for: \(room.bridgeID ?? "nil")) returned nil")
            return
        }
        print("[Studio] ✅ All guards passed — groupedLightID: \(groupedLightID), bridgeID: \(room.bridgeID ?? "nil"), strategy: \(card.strategy)")

        // ── Stop any currently running effect first ─────────────────
        if let runningID = runningCardID,
           let runningCard = (effectCards + liveModeCards).first(where: { $0.id == runningID }) {
            print("[Studio] Stopping previous: \(runningCard.name)")
            await stop(runningCard)
        }

        let brightness = paramValue(for: card.id, paramID: "brightness", default: 70)

        // ── Ensure lights are on first ──────────────────────────────
        try? await api.setGroupedLight(id: groupedLightID, on: true)

        switch card.strategy {
        case .bridgeNative(let effectName):
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
            // Flatten namespaced params for engine compatibility
            let flatValues = paramValues[card.id] ?? [:]
            let flatColors = paramColors[card.id] ?? [:]
            await orchestrator.startStudioMode(
                key: engineKey,
                room: room,
                params: flatValues,
                colors: flatColors
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

        try? await api.setGroupedLight(id: groupedLightID, on: false)

        await MainActor.run {
            runningCardID = nil
            statusMessage = ""
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Live Param Updates
    // ──────────────────────────────────────────────

    private var paramTask: Task<Void, Never>?

    /// Debounced param update — dispatches to the correct API call based on param ID.
    /// Waits 150ms after last change, then sends one PUT.
    @MainActor
    func sendParam(cardID: String, paramID: String, value: Double) {
        paramTask?.cancel()
        paramTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }

            guard let room = selectedRoom,
                  let groupedLightID = room.groupedLightID,
                  let orchestrator,
                  let api = orchestrator.hueClient(for: room.bridgeID) else { return }

            switch paramID {
            case "brightness":
                try? await api.setGroupedLightBrightness(id: groupedLightID, brightness: value)
            case "warmth":
                // mirek range: 153 (cool) – 500 (warm)
                let mirek = Int(value.rounded())
                try? await api.setGroupedLightColorTemp(id: groupedLightID, mirek: mirek)
            case "transition":
                // dynamics.duration in ms — applied on next state change
                break // Stored locally, used on next apply()
            default:
                // App-driven params (speed, sensitivity, min_brightness, etc.)
                // are read by the engine loop directly from paramValues
                break
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Card Catalog
    // ──────────────────────────────────────────────

    private static func buildEffectCards() -> [StudioCard] {
        return [
            StudioCard(
                id: "candle",
                name: "Candle",
                tagline: "Warm flickering flame, perfect for dinner or relaxation",
                icon: "flame.fill",
                accentColor: Color(hex: "#FF9500"),
                requiresForeground: false,
                params: [
                    StudioParam(id: "brightness", label: "Brightness", kind: .slider(min: 1, max: 100), defaultValue: 70, tier: .essential),
                    StudioParam(id: "warmth", label: "Warmth", kind: .slider(min: 153, max: 500), defaultValue: 366, tier: .color),
                    StudioParam(id: "base_color", label: "Base Color", kind: .colorPicker, defaultValue: 0, tier: .color),
                    StudioParam(id: "transition", label: "Smoothness", kind: .slider(min: 0, max: 6000), defaultValue: 500, tier: .advanced),
                ],
                strategy: .bridgeNative(effect: "candle")
            ),
            StudioCard(
                id: "fire",
                name: "Fire",
                tagline: "Intense fire effect with deep amber and red tones",
                icon: "flame",
                accentColor: Color(hex: "#FF3B30"),
                requiresForeground: false,
                params: [
                    StudioParam(id: "brightness", label: "Brightness", kind: .slider(min: 1, max: 100), defaultValue: 70, tier: .essential),
                    StudioParam(id: "warmth", label: "Warmth", kind: .slider(min: 153, max: 500), defaultValue: 400, tier: .color),
                    StudioParam(id: "base_color", label: "Base Color", kind: .colorPicker, defaultValue: 0, tier: .color),
                    StudioParam(id: "transition", label: "Smoothness", kind: .slider(min: 0, max: 6000), defaultValue: 300, tier: .advanced),
                ],
                strategy: .bridgeNative(effect: "fire")
            ),
            StudioCard(
                id: "sparkle",
                name: "Sparkle",
                tagline: "Gentle random twinkle across all lights",
                icon: "sparkles",
                accentColor: Color(hex: "#FFC107"),
                requiresForeground: false,
                params: [
                    StudioParam(id: "brightness", label: "Brightness", kind: .slider(min: 1, max: 100), defaultValue: 70, tier: .essential),
                    StudioParam(id: "base_color", label: "Base Color", kind: .colorPicker, defaultValue: 0, tier: .color),
                    StudioParam(id: "transition", label: "Smoothness", kind: .slider(min: 0, max: 6000), defaultValue: 400, tier: .advanced),
                ],
                strategy: .bridgeNative(effect: "sparkle")
            ),
            StudioCard(
                id: "prism",
                name: "Prism",
                tagline: "Slow color cycling through the full spectrum",
                icon: "camera.filters",
                accentColor: Color(hex: "#BF5AF2"),
                requiresForeground: false,
                params: [
                    StudioParam(id: "brightness", label: "Brightness", kind: .slider(min: 1, max: 100), defaultValue: 70, tier: .essential),
                    StudioParam(id: "speed", label: "Speed", kind: .slider(min: 0, max: 100), defaultValue: 50, tier: .essential),
                    StudioParam(id: "transition", label: "Smoothness", kind: .slider(min: 0, max: 6000), defaultValue: 1000, tier: .advanced),
                    StudioParam(id: "saturation", label: "Saturation", kind: .slider(min: 0, max: 100), defaultValue: 100, tier: .advanced),
                ],
                strategy: .bridgeNative(effect: "prism")
            ),
            StudioCard(
                id: "opal",
                name: "Opal",
                tagline: "Iridescent pastel color shifts",
                icon: "circle.hexagongrid.fill",
                accentColor: Color(hex: "#40D9BF"),
                requiresForeground: false,
                params: [
                    StudioParam(id: "brightness", label: "Brightness", kind: .slider(min: 1, max: 100), defaultValue: 70, tier: .essential),
                    StudioParam(id: "warmth", label: "Warmth", kind: .slider(min: 153, max: 500), defaultValue: 300, tier: .color),
                    StudioParam(id: "base_color", label: "Base Color", kind: .colorPicker, defaultValue: 0, tier: .color),
                    StudioParam(id: "transition", label: "Smoothness", kind: .slider(min: 0, max: 6000), defaultValue: 800, tier: .advanced),
                ],
                strategy: .bridgeNative(effect: "opal")
            ),
            StudioCard(
                id: "glisten",
                name: "Glisten",
                tagline: "Quick bright flashes like sunlight on water",
                icon: "rays",
                accentColor: Color(hex: "#0A84FF"),
                requiresForeground: false,
                params: [
                    StudioParam(id: "brightness", label: "Brightness", kind: .slider(min: 1, max: 100), defaultValue: 70, tier: .essential),
                    StudioParam(id: "base_color", label: "Base Color", kind: .colorPicker, defaultValue: 0, tier: .color),
                    StudioParam(id: "transition", label: "Smoothness", kind: .slider(min: 0, max: 6000), defaultValue: 300, tier: .advanced),
                ],
                strategy: .bridgeNative(effect: "glisten")
            ),
            StudioCard(
                id: "colorloop",
                name: "Color Loop",
                tagline: "Continuous slow hue rotation — classic Hue effect",
                icon: "arrow.triangle.2.circlepath",
                accentColor: Color(hex: "#30D158"),
                requiresForeground: false,
                params: [
                    StudioParam(id: "brightness", label: "Brightness", kind: .slider(min: 1, max: 100), defaultValue: 70, tier: .essential),
                    StudioParam(id: "speed", label: "Speed", kind: .slider(min: 0, max: 100), defaultValue: 50, tier: .essential),
                    StudioParam(id: "transition", label: "Smoothness", kind: .slider(min: 0, max: 6000), defaultValue: 1000, tier: .advanced),
                ],
                strategy: .bridgeNative(effect: "colorloop")
            ),
        ]
    }

    private static func buildLiveModeCards() -> [StudioCard] {
        return [
            StudioCard(
                id: "music_sync",
                name: "Music Sync",
                tagline: "Lights pulse and flash to your music in real time via microphone",
                icon: "waveform.and.mic",
                accentColor: Color(hex: "#FF4D8C"),
                requiresForeground: true,
                params: [
                    StudioParam(id: "sensitivity", label: "Sensitivity", kind: .slider(min: 0, max: 100), defaultValue: 70, tier: .essential),
                    StudioParam(id: "brightness", label: "Brightness", kind: .slider(min: 1, max: 100), defaultValue: 80, tier: .essential),
                    StudioParam(id: "color", label: "Color Palette", kind: .colorPicker, defaultValue: 0, tier: .color),
                    StudioParam(id: "min_brightness", label: "Min Brightness", kind: .slider(min: 1, max: 50), defaultValue: 10, tier: .advanced),
                    StudioParam(id: "smoothness", label: "Smoothness", kind: .slider(min: 0, max: 100), defaultValue: 30, tier: .advanced),
                    StudioParam(id: "saturation", label: "Saturation", kind: .slider(min: 0, max: 100), defaultValue: 100, tier: .advanced),
                ],
                strategy: .appDriven(engineKey: "mic")
            ),
            StudioCard(
                id: "gaming",
                name: "Gaming",
                tagline: "Dynamic hue shifts during intense gaming sessions",
                icon: "gamecontroller.fill",
                accentColor: Color(hex: "#0A84FF"),
                requiresForeground: true,
                params: [
                    StudioParam(id: "brightness", label: "Brightness", kind: .slider(min: 1, max: 100), defaultValue: 80, tier: .essential),
                    StudioParam(id: "speed", label: "Speed", kind: .slider(min: 0, max: 100), defaultValue: 50, tier: .essential),
                    StudioParam(id: "warmth", label: "Warmth", kind: .slider(min: 153, max: 500), defaultValue: 300, tier: .color),
                    StudioParam(id: "saturation", label: "Saturation", kind: .slider(min: 0, max: 100), defaultValue: 80, tier: .advanced),
                    StudioParam(id: "min_brightness", label: "Min Brightness", kind: .slider(min: 1, max: 50), defaultValue: 15, tier: .advanced),
                ],
                strategy: .appDriven(engineKey: "gaming")
            ),
            StudioCard(
                id: "party",
                name: "Party",
                tagline: "Fast multi-color flashes synchronized across the room",
                icon: "party.popper.fill",
                accentColor: Color(hex: "#BF5AF2"),
                requiresForeground: true,
                params: [
                    StudioParam(id: "speed", label: "Speed", kind: .slider(min: 0, max: 100), defaultValue: 60, tier: .essential),
                    StudioParam(id: "brightness", label: "Brightness", kind: .slider(min: 1, max: 100), defaultValue: 90, tier: .essential),
                    StudioParam(id: "color", label: "Flash Color", kind: .colorPicker, defaultValue: 0, tier: .color),
                    StudioParam(id: "min_brightness", label: "Min Brightness", kind: .slider(min: 0, max: 50), defaultValue: 5, tier: .advanced),
                    StudioParam(id: "smoothness", label: "Smoothness", kind: .slider(min: 0, max: 100), defaultValue: 20, tier: .advanced),
                    StudioParam(id: "saturation", label: "Saturation", kind: .slider(min: 0, max: 100), defaultValue: 100, tier: .advanced),
                ],
                strategy: .appDriven(engineKey: "party")
            ),
            StudioCard(
                id: "strobe",
                name: "Strobe",
                tagline: "High-frequency white flash — use responsibly",
                icon: "bolt.fill",
                accentColor: Color(hex: "#FFC107"),
                requiresForeground: true,
                params: [
                    StudioParam(id: "speed", label: "Speed", kind: .slider(min: 0, max: 100), defaultValue: 50, tier: .essential),
                    StudioParam(id: "brightness", label: "Brightness", kind: .slider(min: 1, max: 100), defaultValue: 100, tier: .essential),
                    StudioParam(id: "flash_color", label: "Flash Color", kind: .colorPicker, defaultValue: 0, tier: .color),
                    StudioParam(id: "min_brightness", label: "Min Brightness", kind: .slider(min: 0, max: 50), defaultValue: 0, tier: .advanced),
                    StudioParam(id: "duty_cycle", label: "Duty Cycle", kind: .slider(min: 10, max: 90), defaultValue: 50, tier: .advanced),
                ],
                strategy: .appDriven(engineKey: "strobe")
            ),
            StudioCard(
                id: "thunderstorm",
                name: "Thunderstorm",
                tagline: "Random lightning strikes with dim ambient fill",
                icon: "cloud.bolt.fill",
                accentColor: Color(hex: "#668AFF"),
                requiresForeground: true,
                params: [
                    StudioParam(id: "brightness", label: "Brightness", kind: .slider(min: 1, max: 100), defaultValue: 80, tier: .essential),
                    StudioParam(id: "frequency", label: "Storm Intensity", kind: .slider(min: 0, max: 100), defaultValue: 50, tier: .essential),
                    StudioParam(id: "ambient_color", label: "Ambient Color", kind: .colorPicker, defaultValue: 0, tier: .color),
                    StudioParam(id: "flash_intensity", label: "Flash Intensity", kind: .slider(min: 20, max: 100), defaultValue: 90, tier: .advanced),
                    StudioParam(id: "min_brightness", label: "Min Brightness", kind: .slider(min: 1, max: 30), defaultValue: 5, tier: .advanced),
                ],
                strategy: .appDriven(engineKey: "thunderstorm")
            ),
            StudioCard(
                id: "ambient",
                name: "Ambient",
                tagline: "Slow breathing color shifts that blend with your room",
                icon: "aqi.low",
                accentColor: Color(hex: "#40D9BF"),
                requiresForeground: true,
                params: [
                    StudioParam(id: "speed", label: "Speed", kind: .slider(min: 0, max: 100), defaultValue: 30, tier: .essential),
                    StudioParam(id: "brightness", label: "Brightness", kind: .slider(min: 1, max: 100), defaultValue: 70, tier: .essential),
                    StudioParam(id: "color", label: "Color Palette", kind: .colorPicker, defaultValue: 0, tier: .color),
                    StudioParam(id: "warmth", label: "Warmth", kind: .slider(min: 153, max: 500), defaultValue: 350, tier: .color),
                    StudioParam(id: "smoothness", label: "Smoothness", kind: .slider(min: 0, max: 100), defaultValue: 70, tier: .advanced),
                    StudioParam(id: "min_brightness", label: "Min Brightness", kind: .slider(min: 1, max: 50), defaultValue: 15, tier: .advanced),
                ],
                strategy: .appDriven(engineKey: "ambient")
            ),
        ]
    }
}

