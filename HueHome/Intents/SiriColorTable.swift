// SiriColorTable.swift
// ChromaGlow — Siri Shortcuts
//
// The named colors Siri can speak ("make my lights teal in ChromaGlow").
// Chromatic names are hue/saturation pairs pushed through the same
// battle-tested pipeline the Composer uses (HueColorUtils.xyFrom +
// clampXYToGamut C) — every case is inside gamut C by construction, and the
// unit test asserts the clamp is an identity. Whites map to mirek instead
// of xy, matching LightingPreset's warm/cool conventions.

import AppIntents

// MARK: - NamedColorChoice

enum NamedColorChoice: String, AppEnum, CaseIterable {
    // Chromatic (xy)
    case red, crimson, salmon
    case orange, peach, amber, gold, yellow
    case lime, green, mint, teal
    case cyan, skyBlue, blue, indigo
    case purple, violet, lavender
    case magenta, pink, rose
    // Whites (mirek)
    case daylight, coolWhite, neutralWhite, softWhite, warmWhite

    static var typeDisplayRepresentation: TypeDisplayRepresentation { TypeDisplayRepresentation(name: "Color") }

    static var caseDisplayRepresentations: [NamedColorChoice: DisplayRepresentation] { [
        .red: "Red", .crimson: "Crimson", .salmon: "Salmon",
        .orange: "Orange", .peach: "Peach", .amber: "Amber",
        .gold: "Gold", .yellow: "Yellow",
        .lime: "Lime", .green: "Green", .mint: "Mint", .teal: "Teal",
        .cyan: "Cyan", .skyBlue: "Sky Blue", .blue: "Blue", .indigo: "Indigo",
        .purple: "Purple", .violet: "Violet", .lavender: "Lavender",
        .magenta: "Magenta", .pink: "Pink", .rose: "Rose",
        .daylight: "Daylight", .coolWhite: "Cool White",
        .neutralWhite: "Neutral White", .softWhite: "Soft White",
        .warmWhite: "Warm White",
    ] }

    /// Name as spoken back in the result dialog.
    var spokenName: String {
        switch self {
        case .skyBlue:      return "sky blue"
        case .coolWhite:    return "cool white"
        case .neutralWhite: return "neutral white"
        case .softWhite:    return "soft white"
        case .warmWhite:    return "warm white"
        default:            return rawValue
        }
    }
}

// MARK: - SiriColorTable

enum SiriColorTable {

    enum ColorPayload: Equatable {
        case xy(x: Double, y: Double)
        case mirek(Int)
    }

    /// Chromatic hue (degrees 0–360) / saturation (0–1) definitions.
    static let chromatic: [NamedColorChoice: (hue: Double, sat: Double)] = [
        .red:      (0,   1.00), .crimson: (348, 0.95), .salmon:   (10,  0.60),
        .orange:   (25,  1.00), .peach:   (28,  0.55), .amber:    (40,  0.95),
        .gold:     (48,  0.85), .yellow:  (55,  0.90),
        .lime:     (80,  0.90), .green:   (120, 0.95), .mint:     (150, 0.60),
        .teal:     (175, 0.85), .cyan:    (187, 0.90), .skyBlue:  (200, 0.65),
        .blue:     (235, 0.95), .indigo:  (255, 0.85), .purple:   (275, 0.90),
        .violet:   (285, 0.80), .lavender: (290, 0.45), .magenta: (310, 0.95),
        .pink:     (330, 0.70), .rose:    (340, 0.85),
    ]

    /// White mirek values — all inside Hue's 153–500 range.
    static let whites: [NamedColorChoice: Int] = [
        .daylight: 156, .coolWhite: 200, .neutralWhite: 300,
        .softWhite: 370, .warmWhite: 450,
    ]

    /// What a named color sends to the bridge. Pure — unit-tested.
    static func payload(for choice: NamedColorChoice) -> ColorPayload {
        if let mirek = whites[choice] {
            return .mirek(mirek)
        }
        let def = chromatic[choice] ?? (hue: 0, sat: 1)
        let xy = HueColorUtils.xyFrom(hue: def.hue / 360.0, saturation: def.sat, brightness: 1.0)
        let clamped = HueColorUtils.clampXYToGamut(x: xy.x, y: xy.y, gamut: .c)
        return .xy(x: clamped.x, y: clamped.y)
    }
}
