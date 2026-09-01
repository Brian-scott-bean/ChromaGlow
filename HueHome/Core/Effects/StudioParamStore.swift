// StudioParamStore.swift
// CastChroma — per-card last-used Studio params (adjustment-settings revamp).
//
// Effects/Live card slider positions used to be session-only in-memory
// dicts — every tweak was lost on relaunch (compositions persist via
// CompositionStore; engine cards had nothing). This store remembers the
// last-used values per card as UserDefaults JSON, following the
// EffectPresetsStore precedent: colors as HSBA arrays, and every value
// clamped against the card catalogs on load so stale or corrupt data can
// never push an out-of-range value into an engine loop (the L-41/L-54
// sanitizer pattern).

import SwiftUI

@MainActor
final class StudioParamStore {
    static let shared = StudioParamStore()

    static let storageKey = "studio.lastParams.v1"

    private struct Snapshot: Codable {
        var values: [String: [String: Double]] = [:]
        var colors: [String: [String: [Double]]] = [:]   // HSBA arrays
    }

    private let defaults: UserDefaults
    private var saveTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Load persisted params, clamped against the card catalogs. Unknown
    /// card ids (removed cards, composition UUIDs) and unknown param ids
    /// (removed params, session-only beat keys) are dropped.
    func load(cards: [StudioCard]) -> (values: [String: [String: Double]],
                                       colors: [String: [String: Color]]) {
        guard let data = defaults.data(forKey: Self.storageKey),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            return ([:], [:])
        }
        let cardsByID = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })

        var values: [String: [String: Double]] = [:]
        for (cardID, params) in snapshot.values {
            guard let card = cardsByID[cardID] else { continue }
            var clamped: [String: Double] = [:]
            for (paramID, raw) in params {
                guard raw.isFinite,
                      let param = card.params.first(where: { $0.id == paramID }),
                      let value = Self.clamp(raw, to: param.kind) else { continue }
                clamped[paramID] = value
            }
            if !clamped.isEmpty { values[cardID] = clamped }
        }

        var colors: [String: [String: Color]] = [:]
        for (cardID, params) in snapshot.colors {
            guard let card = cardsByID[cardID] else { continue }
            var restored: [String: Color] = [:]
            for (paramID, hsba) in params {
                guard hsba.count == 4, hsba.allSatisfy({ $0.isFinite }),
                      let param = card.params.first(where: { $0.id == paramID }),
                      case .colorPicker = param.kind else { continue }
                restored[paramID] = Color.fromHSBA(hsba.map { min(1, max(0, $0)) })
            }
            if !restored.isEmpty { colors[cardID] = restored }
        }

        return (values, colors)
    }

    /// Debounced (~1s) persist of the defaults dicts — called from every
    /// committed customization write; trailing write wins.
    func scheduleSave(values: [String: [String: Double]],
                      colors: [String: [String: Color]]) {
        let colorArrays = colors.mapValues { $0.mapValues { $0.hsbaComponents() } }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            self.write(values: values, colors: colorArrays)
        }
    }

    /// Immediate persist — reset paths and tests.
    func saveNow(values: [String: [String: Double]],
                 colors: [String: [String: Color]]) {
        saveTask?.cancel()
        write(values: values, colors: colors.mapValues { $0.mapValues { $0.hsbaComponents() } })
    }

    private func write(values: [String: [String: Double]],
                       colors: [String: [String: [Double]]]) {
        let snapshot = Snapshot(values: values, colors: colors)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    /// Clamp a raw persisted value to a param's declared value space.
    static func clamp(_ value: Double, to kind: StudioParamKind) -> Double? {
        switch kind {
        case .slider(let min, let max):
            return Swift.min(max, Swift.max(min, value))
        case .toggle:
            return value > 0.5 ? 1 : 0
        case .segmented(let options):
            return options.min { abs($0.value - value) < abs($1.value - value) }?.value
        case .colorPicker:
            return nil   // colors live in the colors dict
        }
    }
}
