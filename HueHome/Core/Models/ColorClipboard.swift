// ColorClipboard.swift
// ChromaGlow — light-card color copy/paste
//
// The session color clipboard behind "Copy Color" on a light card. Holds one
// transient SavedColor (never added to SavedColorStore) so a copied look can
// be pasted onto other lights — in this room or, because the clipboard is
// app-wide, after navigating to any other room or zone. In-memory only: a
// clipboard that outlives the session would paste stale looks.

import Foundation

@MainActor
@Observable
final class ColorClipboard {
    static let shared = ColorClipboard()

    private(set) var copied: SavedColor? = nil

    var hasColor: Bool { copied != nil }

    init() {}

    func copy(_ color: SavedColor) {
        copied = color
    }

    func clear() {
        copied = nil
    }

    /// What "Copy Color" captures from a light. Pure — unit-testable.
    ///
    /// The bridge nulls `color_temperature.mirek` while a light renders xy
    /// color (`mirek_valid` false), so a non-nil mirek means the light is
    /// currently in CT mode and mirek is the faithful representation — it
    /// wins over any stale xy the model still carries. An OFF light captures
    /// its last-known look ("copy what this light looks like when on").
    /// Returns nil for dimmable-only lights: a brightness-only copy is not
    /// a color, so callers hide Copy/Save instead of offering a no-op.
    static func capture(from light: LightDisplayItem) -> SavedColor? {
        if let mirek = light.colorTempMirek {
            return SavedColor(mirek: mirek, brightness: light.brightness)
        }
        if let x = light.colorX, let y = light.colorY {
            return SavedColor(x: x, y: y, brightness: light.brightness)
        }
        return nil
    }
}
