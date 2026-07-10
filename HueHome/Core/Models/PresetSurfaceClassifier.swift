// PresetSurfaceClassifier.swift
// ChromaGlow — where a Composer creation belongs
//
// A composition isn't always "a composition" to the person who made it. One
// that sits still is a scene; one that moves is an effect; one that listens to
// the room is a live mode. The Studio decks and the Scenes tab already draw
// those lines for built-in cards — this classifier draws the same lines for
// Composer creations, so a saved thunderstorm shows up next to the shipped
// one instead of hiding on the Composer deck.
//
// Derived, never stored: the answer comes from the preset's own layers, so it
// can't go stale when the user edits the preset, and nothing needs migrating.

import Foundation

enum PresetSurface: Equatable {
    /// Reacts to sound or beat — belongs with party/strobe/thunderstorm on the
    /// Live deck. Checked first: a reactive preset is live even when its look
    /// is otherwise static (the hybrid tier).
    case live
    /// A static look — steady envelope, no motion, no reaction. That is a
    /// scene by any name, and it can live on the bridge as one.
    case scene
    /// Everything else: it moves or breathes on its own, like the firmware
    /// effects on Deck 0.
    case effect
}

enum PresetSurfaceClassifier {

    static func surface(for preset: CompositionPreset) -> PresetSurface {
        if preset.reaction.source != .none { return .live }
        if preset.capabilityTier == .bridgeOptimized { return .scene }
        return .effect
    }
}
