// HueAPIClient+Effects.swift
// ChromaGlow — Round 3 Phase A (full Hue power)
//
// effects_v2 (the CURRENT firmware-effect API: per-effect speed/color/mirek
// parameters) and timed_effects (bridge-side sunrise/sunset that survive the
// app being killed). Request bodies are pure value-type builders so they can
// be golden-JSON tested without a network.
//
// Rules: effects_v2 and timed_effects are LIGHT-level resources — capability
// is per light (EffectCapabilityResolver), so callers fan out gate-paced
// per-light PUTs to the capable set. The legacy v1 `effects.effect` enum on
// grouped_light remains the fallback for bridges/lights without v2.

import Foundation

// MARK: - EffectsV2Body

/// PUT /clip/v2/resource/light/{id} → {"effects_v2": {"action": …}}
struct EffectsV2Body: Equatable {
    var effect: String                       // "cosmos" | "candle" | … | "no_effect"
    var speed: Double? = nil                 // 0…1 (clamped)
    var colorXY: CGPoint? = nil              // CIE xy
    var mirek: Int? = nil                    // 153…500 (clamped)

    func dictionary() -> [String: Any] {
        var action: [String: Any] = ["effect": effect]
        var parameters: [String: Any] = [:]
        if let speed {
            parameters["speed"] = min(1.0, max(0.0, speed))
        }
        if let colorXY {
            parameters["color"] = ["xy": ["x": Double(colorXY.x), "y": Double(colorXY.y)]]
        }
        if let mirek {
            parameters["color_temperature"] = ["mirek": min(500, max(153, mirek))]
        }
        if !parameters.isEmpty { action["parameters"] = parameters }
        return ["effects_v2": ["action": action]]
    }
}

// MARK: - TimedEffectsBody

/// PUT /clip/v2/resource/light/{id} → {"timed_effects": …}
struct TimedEffectsBody: Equatable {
    /// Bridge cap: 6 h.
    static let maxDurationMs = 21_600_000

    var effect: String                       // "sunrise" | "sunset" | "no_effect"
    var durationMs: Int? = nil
    /// A running firmware effect takes precedence over timed_effects on the
    /// bridge — set this to clear it in the SAME PUT (one paced command).
    var clearFirmwareEffect = false

    func dictionary() -> [String: Any] {
        var timed: [String: Any] = ["effect": effect]
        if let durationMs {
            timed["duration"] = min(Self.maxDurationMs, max(0, durationMs))
        }
        var body: [String: Any] = ["timed_effects": timed]
        if clearFirmwareEffect {
            body["effects"] = ["effect": "no_effect"]
        }
        return body
    }
}

// MARK: - Client methods

extension HueAPIClient {

    /// Run (or stop, with effect "no_effect") an effects_v2 firmware effect
    /// with real parameters on one light. Throws HueAPIError.httpError(400)
    /// on lights that reject v2 — callers fall back to the v1 enum.
    func setLightEffectV2(id: String, body: EffectsV2Body) async throws {
        let (ip, token) = try credentials()
        let data = try await put(
            path: "/clip/v2/resource/light/\(id)",
            body: body.dictionary(), ip: ip, token: token
        )
        logRaw(data, label: "PUT /light/\(id) effects_v2 \(body.effect)")
    }

    /// Start (or cancel) a bridge-side timed effect. The ramp lives on the
    /// bridge — it completes even if this app is force-quit mid-way.
    func setLightTimedEffect(id: String, body: TimedEffectsBody) async throws {
        let (ip, token) = try credentials()
        let data = try await put(
            path: "/clip/v2/resource/light/\(id)",
            body: body.dictionary(), ip: ip, token: token
        )
        logRaw(data, label: "PUT /light/\(id) timed_effects \(body.effect)")
    }
}
