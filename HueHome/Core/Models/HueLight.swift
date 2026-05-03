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
