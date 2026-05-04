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

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
