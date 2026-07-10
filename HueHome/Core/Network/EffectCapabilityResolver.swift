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

    /// What to do when the user taps a firmware-effect card.
    ///
    /// The bridge answers an effect it cannot run with a 400, and the sender
    /// discards it. So a room of white-only bulbs used to report a cheerful
    /// "🟢 Cosmos → Kitchen" while nothing whatsoever happened. Deciding this
    /// up front, from the lights' own capability lists, is the difference
    /// between a scene that works and a scene that lies.
    enum Routing: Equatable {
        /// Send to these lights. `coverage` drives the "4 of 6" badge.
        case run(lightIDs: [String], coverage: Coverage)
        /// Not one light can run it. Say so; do not pretend to start.
        case unsupported(effect: String)
        /// We could not read the room's lights, so capability is unknown.
        /// Send to everything and let the bridge decide — a transient fetch
        /// failure must not block a user from an effect that would work.
        case runUnverified(lightIDs: [String])
    }

    static func routing(for effect: String, lights: [HueLight], fallbackIDs: [String]) -> Routing {
        guard !lights.isEmpty else { return .runUnverified(lightIDs: fallbackIDs) }

        // If not one light advertises any firmware effect, we are reading a
        // capability list that is not there — a decode gap or a firmware that
        // omits the field — rather than a room of incapable bulbs. Refusing
        // every effect on that evidence would be worse than trying.
        let anyCapabilityReported = lights.contains { !effectValues(for: $0).isEmpty }
        guard anyCapabilityReported else { return .runUnverified(lightIDs: fallbackIDs) }

        let coverage = coverage(for: effect, lights: lights)
        guard !coverage.isEmpty else { return .unsupported(effect: effect) }
        return .run(lightIDs: coverage.capableIDs, coverage: coverage)
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
