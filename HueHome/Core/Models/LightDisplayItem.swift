// LightDisplayItem.swift
// CastChroma — Epic 3 / Story 3.1 → 3.3 (color + color temp fields added)
//
// UI-ready individual light model. Mirrors RoomDisplayItem's pattern.

import Foundation
import SwiftUI

struct LightDisplayItem: Identifiable, Hashable {
    let id: String          // light resource ID (V2 UUID)
    let name: String
    let archetype: String?
    var isOn: Bool
    var brightness: Double  // 1–100

    // ── Color (CIE 1931 xy) ──────────────────────
    // nil = bulb doesn't support full color
    var colorX: Double?
    var colorY: Double?
    var supportsColor: Bool { colorX != nil }

    // ── Color Temperature ─────────────────────────
    // nil = bulb doesn't support color temperature
    var colorTempMirek: Int?
    var mirekMin: Int       // e.g. 153  (6500 K)
    var mirekMax: Int       // e.g. 500  (2000 K)
    var supportsColorTemp: Bool { colorTempMirek != nil || mirekMin != mirekMax }

    // Equatable is synthesized — compares ALL fields (not just id).
    // This is critical: SwiftUI's ForEach diff uses == to detect changes.
    // If == only compared id, onChange(of: light.colorX) would never fire
    // because SwiftUI would think the item hadn't changed.
    // Hash must include volatile fields so SwiftUI's ForEach detects changes.
    // If hash only used id, the collection hash wouldn't change when colors
    // update, and ForEach might skip re-evaluating its content closure.
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(isOn)
        hasher.combine(brightness)
        hasher.combine(colorX)
        hasher.combine(colorY)
        hasher.combine(colorTempMirek)
    }
}

// MARK: - HueLight mapping

extension LightDisplayItem {
    /// UI model from a decoded CLIP v2 light — the one mapping every surface
    /// shares (lifted from RoomDetailViewModel in R4's Scenes block). Lives
    /// in an extension so the memberwise init survives.
    /// Mirek schema falls back to the full Hue range; brightness to 100.
    init(from light: HueLight) {
        self.init(
            id:             light.id,
            name:           light.metadata.name,
            archetype:      light.metadata.archetype,
            isOn:           light.on.on,
            brightness:     light.dimming?.brightness ?? 100.0,
            colorX:         light.color?.xy.x,
            colorY:         light.color?.xy.y,
            colorTempMirek: light.color_temperature?.mirek,
            mirekMin:       light.color_temperature?.mirek_schema?.mirek_minimum ?? 153,
            mirekMax:       light.color_temperature?.mirek_schema?.mirek_maximum ?? 500
        )
    }
}
