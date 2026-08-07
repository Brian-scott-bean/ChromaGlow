// FlagStore.swift
// ChromaGlow — Core
//
// Composer 2 Phase 1A: the local runtime flag substrate (review D11).
// UserDefaults-backed, local-only — no backend, no remote config, no
// analytics, per AGENTS.md backend rules. Compile-time flags stay in
// FeatureFlags.swift; this store exists for the Composer 2 kill switches
// (review Part J), each defaulting to today's shipped behavior. Nothing
// consumes these flags yet — consumers arrive with their own packets.
//
// Persisted keys are an approved implementation decision (2026-08-06):
// the raw value IS the stable key, and keys are append-only.

import Foundation

/// The Composer 2 kill-switch flags named in
/// docs/ios/composer2-architecture-review-2026-08-01.md Part J.
enum Composer2Flag: String, CaseIterable {
    case oklabInterpolation  = "castchroma.flag.oklabInterpolation"
    case explicitOffSemantics = "castchroma.flag.explicitOffSemantics"
    case perBridgeScheduler  = "castchroma.flag.perBridgeScheduler"
    case arbiterEnforcement  = "castchroma.flag.arbiterEnforcement"
    case transportPlanner    = "castchroma.flag.transportPlanner"

    /// `false` keeps the shipped code path for every flag.
    var defaultValue: Bool { false }
}

@MainActor
final class FlagStore {
    static let shared = FlagStore()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The effective value: a stored override if one exists, else the default.
    func isEnabled(_ flag: Composer2Flag) -> Bool {
        override(for: flag) ?? flag.defaultValue
    }

    /// The stored override alone. `nil` means no override — distinct from a
    /// stored `false`, which pins the flag off even if a default changes.
    func override(for flag: Composer2Flag) -> Bool? {
        defaults.object(forKey: flag.rawValue) as? Bool
    }

    func setOverride(_ value: Bool, for flag: Composer2Flag) {
        defaults.set(value, forKey: flag.rawValue)
    }

    /// Removes one override so the flag resolves to its default again.
    func clearOverride(for flag: Composer2Flag) {
        defaults.removeObject(forKey: flag.rawValue)
    }

    /// Removes every flag override. Touches only `Composer2Flag` keys —
    /// never any other key in the suite.
    func resetAllOverrides() {
        for flag in Composer2Flag.allCases {
            defaults.removeObject(forKey: flag.rawValue)
        }
    }
}
