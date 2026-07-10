// RoomColorWashPlanner.swift
// ChromaGlow — long-press room color wash
//
// Turns "this hue, this harmony rule, this room's bulbs" into per-light
// writes. Pure — the Dashboard popup calls it, the orchestrator just sends
// what it returns, and the tests exercise it with fixture bulbs.
//
// Distribution mirrors how a person lights a room with a palette: the harmony
// anchors cycle across the color-capable bulbs (adjacent bulbs get different
// anchors), while white-only bulbs join at the shared brightness instead of
// being left out — SavedColor.application's degradation rules, reused rather
// than re-invented.

import Foundation

enum RoomColorWashPlanner {

    struct Assignment: Equatable {
        let lightID: String
        let action: SavedColor.Application
    }

    /// One light's worth of the wash.
    /// - rule .none: every light gets the root color (or brightness if it can't).
    /// - otherwise: HarmonyEngine anchors, cycled round-robin across the room.
    static func plan(
        lights: [HueLight],
        rule: HarmonyRule,
        rootHue: Double,
        saturation: Double,
        brightness: Double,
        gamut: HueColorUtils.Gamut = .c
    ) -> [Assignment] {
        guard !lights.isEmpty else { return [] }

        // Ask the engine for as many colors as there are lights — it cycles
        // its anchors with slight sat/brightness decay, so a 12-bulb room gets
        // variety instead of four hard repeats.
        let paletteColors = HarmonyEngine.palette(
            rule: rule,
            rootHue: rootHue,
            saturation: saturation,
            brightness: 1.0,
            count: max(1, lights.count)
        )

        return lights.enumerated().map { index, light in
            let paletteColor = paletteColors[index % paletteColors.count]
            let xy = HueColorUtils.xyFrom(
                hue: paletteColor.hue,
                saturation: paletteColor.saturation,
                brightness: 1.0
            )
            let clamped = HueColorUtils.clampXYToGamut(x: xy.x, y: xy.y, gamut: gamut)

            // A transient swatch, purely to reuse the capability-degradation
            // rules the saved-color drag-drop already ships and tests.
            let swatch = SavedColor(x: clamped.x, y: clamped.y, mirek: nil, brightness: brightness)
            let action = swatch.application(
                supportsColor: light.color != nil,
                supportsColorTemp: light.color_temperature != nil,
                mirekMin: light.color_temperature?.mirek_schema?.mirek_minimum ?? 153,
                mirekMax: light.color_temperature?.mirek_schema?.mirek_maximum ?? 500
            )
            return Assignment(lightID: light.id, action: action)
        }
    }
}
