//
//  StudioBoardDescriptor.swift
//  HueHome
//
//  Unified Customization Engine — Slice 2 (per-look board composition).
//
//  Each Effect / Live look composes its own board on the shared invisible
//  grid (spec §3): a deliberately chosen HERO interaction, primary and
//  supporting controls, an inline color section where the look genuinely
//  supports color, and the Beat section for engines with proven material
//  BeatBinding consumption (audit §2C).
//
//  This replaces the retired tier-driven inline/overflow partition. There is
//  no "Advanced" bucket (spec §2.3): every control lives in the one board,
//  quieter or louder by PROMINENCE, never buried. Pure and deterministic —
//  the structure tests pin that every declared parameter appears exactly
//  once and that the hero is always a declared control.
//

import Foundation

/// Which primitive renders a control (spec §4 vocabulary).
enum BoardPrimitive: String, Hashable, Sendable {
    /// Rotary encoder — rates, character, temperature.
    case knob
    /// Vertical level fader — brightness/level/intensity semantics.
    case fader
    /// Quiet discrete selector (chips).
    case chips
    /// Illuminated toggle.
    case toggle
    /// The inline B+ color editor.
    case colorEditor
}

/// How loudly a control sits on the board at rest.
enum BoardProminence: String, Hashable, Sendable {
    /// The look's designed hero — subtly more prominent, top of the board.
    case hero
    /// The look's everyday controls.
    case primary
    /// Quieter refinements — smaller, further down, never hidden.
    case supporting
}

struct BoardControl: Hashable, Sendable {
    let paramID: String
    let primitive: BoardPrimitive
    let prominence: BoardProminence
}

enum BoardSectionKind: String, Hashable, Sendable {
    case controls
    case color
    case beat
}

struct BoardSection: Hashable, Sendable {
    let kind: BoardSectionKind
    let controls: [BoardControl]
}

struct StudioBoardDescriptor: Hashable, Sendable {
    let cardID: String
    /// The designed hero parameter — always one of the card's declared
    /// params (or nil for cards with no parameters, e.g. recovered mirrors).
    let heroParamID: String?
    let sections: [BoardSection]

    var allControls: [BoardControl] { sections.flatMap(\.controls) }
}

enum StudioBoardCatalog {

    /// The designed hero per look (spec §3.2 — chosen by the core character
    /// of the look, not by frequency of use).
    static let heroes: [String: String] = [
        // Effects — flame looks lead with character/warmth, tint looks with
        // their color, motion looks with their rate.
        "candle": "warmth",
        "fire": "speed",
        "sparkle": "speed",
        "prism": "speed",
        "opal": "base_color",
        "glisten": "speed",
        "cosmos": "base_color",
        "enchant": "base_color",
        "sunbeam": "brightness",
        "underwater": "base_color",
        "colorloop": "speed",
        // Live — party is color-energy, strobe is pulse timing,
        // thunderstorm is storm intensity, ambient is warmth.
        "party": "color",
        "strobe": "speed",
        "thunderstorm": "frequency",
        "ambient": "warmth",
    ]

    /// Level-semantics params render as faders; rate/character params as
    /// knobs (spec §4 table).
    private static let faderParams: Set<String> = [
        "brightness", "flash_intensity", "min_brightness",
    ]

    static func primitive(for param: StudioParam) -> BoardPrimitive {
        switch param.kind {
        case .colorPicker:  return .colorEditor
        case .toggle:       return .toggle
        case .segmented:    return .chips
        case .slider:
            return faderParams.contains(param.id) ? .fader : .knob
        }
    }

    /// The board for one card. Deterministic: catalog order within each
    /// prominence band, hero first, color after controls unless the hero IS
    /// the color (then color leads), Beat last and only for app-driven
    /// engines with proven consumption.
    static func descriptor(for card: StudioCard) -> StudioBoardDescriptor {
        let declaredIDs = card.params.map(\.id)
        let hero = heroes[card.id].flatMap { declaredIDs.contains($0) ? $0 : nil }

        var colorControls: [BoardControl] = []
        var heroBand: [BoardControl] = []
        var primaryBand: [BoardControl] = []
        var supportingBand: [BoardControl] = []

        for param in card.params {
            let primitive = primitive(for: param)
            let prominence: BoardProminence =
                param.id == hero ? .hero
                : (param.tier == .essential ? .primary : .supporting)
            let control = BoardControl(paramID: param.id,
                                       primitive: primitive,
                                       prominence: prominence)
            if primitive == .colorEditor {
                colorControls.append(control)
            } else if prominence == .hero {
                heroBand.append(control)
            } else if prominence == .primary {
                primaryBand.append(control)
            } else {
                supportingBand.append(control)
            }
        }

        var sections: [BoardSection] = []
        let controlsSection = BoardSection(kind: .controls,
                                           controls: heroBand + primaryBand + supportingBand)
        let colorSection = colorControls.isEmpty
            ? nil : BoardSection(kind: .color, controls: colorControls)

        let heroIsColor = colorControls.contains { $0.prominence == .hero }
        if heroIsColor, let colorSection {
            sections.append(colorSection)
            if !controlsSection.controls.isEmpty { sections.append(controlsSection) }
        } else {
            if !controlsSection.controls.isEmpty { sections.append(controlsSection) }
            if let colorSection { sections.append(colorSection) }
        }

        // Beat: only engines with PROVEN material BeatBinding consumption
        // (audit §2C — currently all four app-driven engines).
        if case .appDriven(let engineKey) = card.strategy,
           beatConsumingEngines.contains(engineKey) {
            sections.append(BoardSection(kind: .beat, controls: []))
        }

        return StudioBoardDescriptor(cardID: card.id, heroParamID: hero,
                                     sections: sections)
    }

    /// Engines whose loops provably derive output from `BeatBinding`
    /// (division/phase materially alter timing/selection — audit §2C table).
    /// An engine absent here renders NO Beat instrument, whatever it reads.
    static let beatConsumingEngines: Set<String> = [
        "party", "strobe", "thunderstorm", "ambient",
    ]
}
