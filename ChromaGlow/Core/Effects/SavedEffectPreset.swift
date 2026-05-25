// SavedEffectPreset.swift
// ChromaGlow
//
// Codable model for a user-saved effect preset (current effect + all param values).
// Persisted to UserDefaults as JSON via EffectPresetsStore.
//
// Colors are stored as HSBA component arrays [h, s, b, a] since Color isn't Codable.

import SwiftUI
import OSLog

// MARK: - SavedEffectPreset

struct SavedEffectPreset: Identifiable, Codable, Hashable {
    var id:           String = UUID().uuidString
    var name:         String
    var baseEffectID: String           // matches HueEffect.id in EffectLibrary.all

    // EffectParamState serialised as Codable-friendly types
    var sliders:   [String: Double]    = [:]
    var toggles:   [String: Bool]      = [:]
    var segmented: [String: Int]       = [:]
    var durations: [String: Int]       = [:]
    var colors:    [String: [Double]]  = [:]   // HSBA components [h, s, b, a]
    var palettes:  [String: [[Double]]] = [:]  // array of HSBA components

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Color ↔ HSBA helpers

extension Color {
    /// Encodes this color as [h, s, b, a] Double components for Codable storage.
    func hsbaComponents() -> [Double] {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return [Double(h), Double(s), Double(b), Double(a)]
    }

    /// Reconstructs a Color from previously encoded HSBA components.
    static func fromHSBA(_ c: [Double]) -> Color {
        guard c.count >= 3 else { return .white }
        return Color(hue: c[0], saturation: c[1], brightness: c[2],
                     opacity: c.count > 3 ? c[3] : 1.0)
    }
}

// MARK: - EffectPresetsStore

/// Singleton store for user-saved effect presets.
/// Uses ObservableObject + @Published so SwiftUI re-renders on every change.
final class EffectPresetsStore: ObservableObject, @unchecked Sendable {

    static let shared = EffectPresetsStore()

    @Published private(set) var presets: [SavedEffectPreset] = []

    private let key = "castchroma.savedEffectPresets"
    private let log = Logger(subsystem: "com.lightshade.app", category: "EffectPresets")

    private init() { load() }

    // ── MARK: Public API ──────────────────────────────────────────────────────

    /// Adds a new preset (or replaces an existing one with the same id).
    func save(_ preset: SavedEffectPreset) {
        if let idx = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[idx] = preset
        } else {
            presets.insert(preset, at: 0)  // newest first
        }
        persist()
        log.info("Saved preset '\(preset.name)' (base: \(preset.baseEffectID))")
    }

    /// Removes a preset permanently.
    func delete(_ preset: SavedEffectPreset) {
        presets.removeAll { $0.id == preset.id }
        persist()
        log.info("Deleted preset '\(preset.name)'")
    }

    /// Renames an existing preset in-place.
    func rename(_ preset: SavedEffectPreset, to newName: String) {
        guard let idx = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[idx].name = newName
        persist()
        log.info("Renamed preset \(preset.id) → '\(newName)'")
    }

    // ── MARK: Persistence ─────────────────────────────────────────────────────

    private func persist() {
        do {
            let data = try JSONEncoder().encode(presets)
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            log.error("Failed to persist presets: \(error.localizedDescription)")
        }
    }

    private func load() {
        guard let data   = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([SavedEffectPreset].self, from: data)
        else { return }
        presets = decoded
        log.info("Loaded \(decoded.count) saved effect preset(s)")
    }
}
