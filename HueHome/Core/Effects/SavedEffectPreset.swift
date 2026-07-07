// SavedEffectPreset.swift
// CastChroma
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

    // Round 3: beat-clock binding. Optional so presets saved before the
    // Universal Beat Panel decode unchanged (nil = free-running).
    var beat: BeatBinding? = nil

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

// MARK: - EffectParamState
//
// Runtime parameter state for a firmware/app effect. Moved here from the
// deleted EffectsViewModel (R4 dead-surface cleanup): TimedEffectRouting
// consumes paramsAreDefault(...) and the L-41/L-54 sanitizer is test-locked.

struct EffectParamState {
    var sliders:   [String: Double]  = [:]
    var colors:    [String: Color]   = [:]
    var palettes:  [String: [Color]] = [:]
    var toggles:   [String: Bool]    = [:]
    var segmented: [String: Int]     = [:]
    var durations: [String: Int]     = [:]
    /// Round 3: binding to the shared BeatClock (.off = legacy slider timing).
    var beat: BeatBinding = .off

    mutating func load(from params: [EffectParam]) {
        for param in params {
            switch param {
            case .slider(let k, _, let v, _, _, _):         sliders[k]   = v
            case .colorSwatch(let k, _, let c):             colors[k]    = c
            case .colorPalette(let k, _, let cs, _):        palettes[k]  = cs
            case .toggle(let k, _, let v):                  toggles[k]   = v
            case .segmented(let k, _, _, let i):            segmented[k] = i
            case .durationPicker(let k, _, let s, _, _):    durations[k] = s
            }
        }
    }

    func sliderValue(_ key: String, default d: Double = 0)     -> Double { sliders[key]   ?? d }
    func boolValue  (_ key: String, default d: Bool = false)   -> Bool   { toggles[key]   ?? d }
    func colorValue (_ key: String, default d: Color = .white) -> Color  { colors[key]    ?? d }
    func paletteValue(_ key: String)                           -> [Color] { palettes[key]  ?? [] }
    func segmentIndex(_ key: String, default d: Int = 0)       -> Int    { segmented[key] ?? d }
    func durationValue(_ key: String, default d: Int = 900)    -> Int    { durations[key] ?? d }

    /// L-41/L-54: builds state from a saved preset with every value clamped to
    /// the effect's parameter schema. Preset JSON is persisted (and can drift
    /// across versions or be hand-edited); unclamped values reach trap sites —
    /// segmented indices into fixed arrays, UInt64 conversions of negative
    /// intervals, and a ÷value Kelvin formatter. Keys absent from the schema
    /// are dropped; keys absent from the preset keep their schema defaults.
    static func sanitized(from preset: SavedEffectPreset, for effect: HueEffect) -> EffectParamState {
        var state = EffectParamState()
        state.load(from: effect.params)
        for param in effect.params {
            switch param {
            case .slider(let key, _, _, let range, _, _):
                if let v = preset.sliders[key] {
                    state.sliders[key] = min(max(v, range.lowerBound), range.upperBound)
                }
            case .toggle(let key, _, _):
                if let v = preset.toggles[key] { state.toggles[key] = v }
            case .segmented(let key, _, let options, _):
                if let idx = preset.segmented[key], !options.isEmpty {
                    state.segmented[key] = max(0, min(options.count - 1, idx))
                }
            case .durationPicker(let key, _, _, let options, _):
                if let secs = preset.durations[key], !options.isEmpty {
                    state.durations[key] = options.min { abs($0 - secs) < abs($1 - secs) } ?? secs
                }
            case .colorSwatch(let key, _, _):
                if let hsba = preset.colors[key] { state.colors[key] = Color.fromHSBA(hsba) }
            case .colorPalette(let key, _, _, _):
                if let arr = preset.palettes[key] { state.palettes[key] = arr.map { Color.fromHSBA($0) } }
            }
        }
        // BeatBinding self-sanitizes (init snaps beatsPerCycle to the allowed
        // steps and clamps the phase offset); nil = pre-Round-3 preset.
        state.beat = preset.beat ?? .off
        return state
    }
}
