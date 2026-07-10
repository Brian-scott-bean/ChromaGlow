// LightingPreset+UI.swift
// ChromaGlow — chip styling for the shared lighting presets
//
// The catalog itself is pure Foundation (it also compiles into the widget and
// watch targets); the tint each chip wears on iPhone is styling, and it lives
// here so Dashboard and RoomDetail render the same preset the same way.

import SwiftUI

extension LightingPreset {
    var chipColor: Color {
        switch id {
        case "energize": return Color(hue: 0.58, saturation: 0.7, brightness: 1.0)
        case "read":     return Color(hue: 0.12, saturation: 0.6, brightness: 1.0)
        case "relax":    return Color(hue: 0.09, saturation: 0.8, brightness: 0.9)
        case "sleep":    return Color(hue: 0.07, saturation: 0.7, brightness: 0.7)
        default:         return HuePalette.amber
        }
    }
}
