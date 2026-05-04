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
    var colorX: Double?
    var colorY: Double?
    /// True if the bulb hardware supports full color. Stored property —
    /// NOT derived from colorX != nil, because colorX is cleared when the
    /// light is in color-temperature mode.
    var supportsColor: Bool

    // ── Color Temperature ─────────────────────────
    var colorTempMirek: Int?
    var mirekMin: Int       // e.g. 153  (6500 K)
    var mirekMax: Int       // e.g. 500  (2000 K)
    var supportsColorTemp: Bool { mirekMin != mirekMax }

    /// Which mode the light is currently in. Determines which color
    /// representation resolveGlowColor should use.
    var isColorTempMode: Bool = false

    static func == (lhs: LightDisplayItem, rhs: LightDisplayItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
