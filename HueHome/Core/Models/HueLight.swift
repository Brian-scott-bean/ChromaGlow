// HueLight.swift
// CastChroma — Story 1.2 / Story 3.3 (color + color temp fields added)
//
// Typed model for the Hue V2 /clip/v2/resource/light response.
// Color and color_temperature are optional — nil means the bulb doesn't support that capability.

import Foundation

struct HueLight: Decodable, Identifiable {
    let id: String
    let metadata: LightMetadata
    let on: OnState
    let dimming: DimmingState?
    let color: LightColor?              // nil = white-only bulb
    let color_temperature: LightColorTemp?  // nil = no CT support
    let owner: ResourceRef?             // points to the device that owns this light
    /// Legacy v1 resource path ("/lights/N") — the identity link for the v1
    /// rules/schedules API (M-04). nil on payloads that omit it.
    let id_v1: String?

    // Round 3 capability fields (all additive — nil on lights/firmware that
    // lack them). These are what EffectCapabilityResolver reads; the app
    // never guesses capability from model IDs.
    let effects: LightEffectsV1?            // deprecated enum API (fallback path)
    let effects_v2: LightEffectsV2?         // current API: params + effect_values discovery
    let timed_effects: LightTimedEffects?   // bridge-side sunrise/sunset
    let gradient: LightGradient?            // gradient strip: points_capable etc.

    init(
        id: String,
        metadata: LightMetadata,
        on: OnState,
        dimming: DimmingState?,
        color: LightColor?,
        color_temperature: LightColorTemp?,
        owner: ResourceRef?,
        id_v1: String? = nil,
        effects: LightEffectsV1? = nil,
        effects_v2: LightEffectsV2? = nil,
        timed_effects: LightTimedEffects? = nil,
        gradient: LightGradient? = nil
    ) {
        self.id = id
        self.metadata = metadata
        self.on = on
        self.dimming = dimming
        self.color = color
        self.color_temperature = color_temperature
        self.owner = owner
        self.id_v1 = id_v1
        self.effects = effects
        self.effects_v2 = effects_v2
        self.timed_effects = timed_effects
        self.gradient = gradient
    }
}

struct LightMetadata: Decodable {
    let name: String
    let archetype: String?
}

struct OnState: Decodable {
    let on: Bool
}

struct DimmingState: Decodable {
    let brightness: Double
}

// MARK: - Color (CIE 1931 xy)

struct LightColor: Decodable {
    let xy: CIExy
    let gamut_type: String?    // "A" | "B" | "C" — colour accuracy tier
}

struct CIExy: Decodable {
    let x: Double
    let y: Double
}

// MARK: - Color Temperature

struct LightColorTemp: Decodable {
    let mirek: Int?                     // current value (nil if light is in color mode)
    let mirek_schema: MirekSchema?      // capability range
    let mirek_valid: Bool?              // false if CT is overridden by a color command
}

struct MirekSchema: Decodable {
    let mirek_minimum: Int              // e.g. 153  (≈ 6500K daylight)
    let mirek_maximum: Int              // e.g. 500  (≈ 2000K candlelight)
}

// MARK: - Firmware effect capability (Round 3)

/// Deprecated v1 `effects` block — still populated by every bridge; used
/// only as the capability fallback when `effects_v2` is absent.
struct LightEffectsV1: Decodable {
    let effect_values: [String]?        // effects this light can run
    let status: String?                 // currently running effect ("no_effect" = idle)
}

/// Current `effects_v2` block: capability discovery lives under
/// action.effect_values; the live state (and its parameters) under status.
struct LightEffectsV2: Decodable {
    struct Action: Decodable {
        let effect_values: [String]?
    }
    struct Status: Decodable {
        let effect: String?
        let effect_values: [String]?
    }
    let action: Action?
    let status: Status?
}

/// Bridge-side timed effects (sunrise/sunset with a duration).
struct LightTimedEffects: Decodable {
    let effect_values: [String]?
    let status: String?
}

/// Gradient capability (Play gradient strip, Signe, gradient lightstrip).
struct LightGradient: Decodable {
    let points_capable: Int?            // how many gradient points it accepts (≤5)
    let mode: String?
    let mode_values: [String]?
    let pixel_count: Int?
}
