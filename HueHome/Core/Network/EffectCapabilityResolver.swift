// EffectCapabilityResolver.swift
// ChromaGlow — Round 3 Phase A (full Hue power)
//
// Pure capability resolution from decoded HueLight fields — never guessed
// from model IDs. This is what puts the "4 of 6 lights" coverage badge on
// effect cards and routes native-vs-fallback decisions (effects_v2 → v1
// enum, timed_effects → app ramp, gradient channel mapping).

import Foundation

enum EffectCapabilityResolver {

    /// Which of `lights` can run `effect`, and out of how many.
    struct Coverage: Equatable {
        let capableIDs: [String]
        let total: Int

        var count: Int { capableIDs.count }
        var isFull: Bool { total > 0 && count == total }
        var isEmpty: Bool { capableIDs.isEmpty }

        /// "4 of 6" — the badge string.
        var label: String { "\(count) of \(total)" }
    }

    // ── effects_v2 / v1 firmware effects ──

    /// True when the light exposes the modern parameterized effect API.
    static func supportsEffectsV2(_ light: HueLight) -> Bool {
        light.effects_v2?.action?.effect_values?.isEmpty == false
    }

    /// Effects this light can run — v2 capability list when present,
    /// legacy v1 list otherwise.
    static func effectValues(for light: HueLight) -> [String] {
        if let v2 = light.effects_v2?.action?.effect_values, !v2.isEmpty { return v2 }
        return light.effects?.effect_values ?? []
    }

    /// Coverage of one firmware effect across a room's lights.
    static func coverage(for effect: String, lights: [HueLight]) -> Coverage {
        let capable = lights.filter { effectValues(for: $0).contains(effect) }
        return Coverage(capableIDs: capable.map(\.id), total: lights.count)
    }

    // ── timed_effects ──

    static func timedEffectCoverage(for effect: String, lights: [HueLight]) -> Coverage {
        let capable = lights.filter { $0.timed_effects?.effect_values?.contains(effect) == true }
        return Coverage(capableIDs: capable.map(\.id), total: lights.count)
    }

    /// Native timed_effects routing rule: bridge-side only when EVERY target
    /// light supports it — a half-native sunrise looks broken.
    static func canRunNativeTimedEffect(_ effect: String, lights: [HueLight]) -> Bool {
        !lights.isEmpty && timedEffectCoverage(for: effect, lights: lights).isFull
    }

    // ── gradient ──

    /// Lights that accept 2+ gradient points (strip-class hardware).
    static func gradientLights(_ lights: [HueLight]) -> [HueLight] {
        lights.filter { ($0.gradient?.points_capable ?? 0) >= 2 }
    }
}
