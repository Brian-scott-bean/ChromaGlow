// SavedColorStore.swift
// ChromaGlow — Scenes overhaul Phase 3
//
// The user's saved color palette ("My Colors"): swatches captured from the
// light controller or the scene builder, applied later to any light via
// tap-to-apply or drag-and-drop. Persistence is UserDefaults JSON — the
// EffectPresetsStore precedent — with an injectable suite for tests.

import SwiftUI
import UniformTypeIdentifiers

// MARK: - SavedColor

/// One saved swatch. Either xy color (color-capable capture) or mirek
/// (CT-only capture) is set — never neither. Brightness always rides along
/// so applying a swatch reproduces the full look.
struct SavedColor: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String?
    var x: Double?
    var y: Double?
    var mirek: Int?
    var brightness: Double        // 1–100
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String? = nil,
        x: Double? = nil,
        y: Double? = nil,
        mirek: Int? = nil,
        brightness: Double,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.x = x
        self.y = y
        self.mirek = mirek
        self.brightness = max(1, min(100, brightness))
        self.createdAt = createdAt
    }

    /// Display color for the swatch circle.
    var displayColor: Color {
        if let x, let y {
            return HueColorUtils.color(fromX: x, y: y, brightness: 100)
        }
        if let mirek {
            return HueColorUtils.color(fromMirek: mirek)
        }
        return .white
    }

    var accessibilityName: String {
        if let name, !name.isEmpty { return name }
        if let mirek { return "Saved white, \(HueColorUtils.kelvin(from: mirek)) kelvin" }
        return "Saved color"
    }
}

// MARK: - SavedColorStore

@MainActor
@Observable
final class SavedColorStore {
    static let shared = SavedColorStore()

    private(set) var colors: [SavedColor] = []

    private let defaults: UserDefaults
    private static let defaultsKey = "castchroma.savedColors"

    /// `defaults` is injectable for tests only.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([SavedColor].self, from: data) {
            colors = decoded
        }
    }

    /// Newest swatches first — the color you just saved is the one you'll
    /// reach for next.
    func add(_ color: SavedColor) {
        colors.insert(color, at: 0)
        persist()
    }

    func rename(id: UUID, to name: String) {
        guard let idx = colors.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        colors[idx].name = trimmed.isEmpty ? nil : trimmed
        persist()
    }

    func remove(id: UUID) {
        guard let idx = colors.firstIndex(where: { $0.id == id }) else { return }
        colors.remove(at: idx)
        persist()
    }

    func color(for id: UUID) -> SavedColor? {
        colors.first { $0.id == id }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(colors) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

// MARK: - Drag & drop

extension UTType {
    /// Exported custom type for saved-color drags (declared in Info.plist).
    static let savedColor = UTType(exportedAs: "com.lightshade.savedcolor")
}

extension SavedColor: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .savedColor)
    }
}

// MARK: - Applying a swatch to a light

extension SavedColor {
    /// What actually gets sent when this swatch lands on a given light,
    /// honoring the light's capabilities. Pure — unit-testable.
    enum Application: Equatable {
        case color(x: Double, y: Double, brightness: Double)
        case colorTemp(mirek: Int, brightness: Double)
        case brightnessOnly(Double)
    }

    /// Capability fallback: color light → xy; CT-only light → mirek if the
    /// swatch has one (a color swatch has no faithful CT rendering — fall
    /// through to brightness); dimmable-only → brightness.
    func application(
        supportsColor: Bool,
        supportsColorTemp: Bool,
        mirekMin: Int = 153,
        mirekMax: Int = 500
    ) -> Application {
        if supportsColor, let x, let y {
            return .color(x: x, y: y, brightness: brightness)
        }
        if let mirek, supportsColorTemp {
            return .colorTemp(mirek: max(mirekMin, min(mirekMax, mirek)),
                              brightness: brightness)
        }
        if supportsColor, let mirek {
            // CT swatch onto a color-only light: render the white as xy.
            let c = HueColorUtils.color(fromMirek: mirek)
            let ui = UIColor(c)
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            let (x, y) = HueColorUtils.xyFrom(hue: Double(h), saturation: Double(s), brightness: 1)
            return .color(x: x, y: y, brightness: brightness)
        }
        return .brightnessOnly(brightness)
    }
}
