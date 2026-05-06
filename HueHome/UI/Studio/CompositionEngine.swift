// CompositionEngine.swift
// ChromaGlow — Composer v0.17.0
//
// Real-time render engine for compositions. Composes four layers
// (Palette, Motion, Envelope, Reaction) into per-light CIE xy + brightness
// output at 25fps (entertainment) or 5fps (REST fallback).
//
// Thread safety: layer configs are value types read from a reference-type
// wrapper (CompositionParamBox) each frame — same pattern as StudioParamBox.

import SwiftUI

// MARK: - CompositionParamBox

/// Mutable reference container for live composition params.
/// The render loop reads from this each frame; the UI writes to it on slider drag.
/// Same pattern as `StudioParamBox` in UnifiedOrchestrator.
final class CompositionParamBox: @unchecked Sendable {
    var palette: PaletteConfig
    var motion: MotionConfig
    var envelope: EnvelopeConfig
    var reaction: ReactionConfig

    init(preset: CompositionPreset) {
        self.palette = preset.palette
        self.motion = preset.motion
        self.envelope = preset.envelope
        self.reaction = preset.reaction
    }

    init(palette: PaletteConfig, motion: MotionConfig, envelope: EnvelopeConfig, reaction: ReactionConfig) {
        self.palette = palette
        self.motion = motion
        self.envelope = envelope
        self.reaction = reaction
    }
}

// MARK: - LightFrame

/// Output for a single light in a single render frame.
struct LightFrame {
    let channelID: UInt8
    let x: Double       // CIE 1931 x
    let y: Double       // CIE 1931 y
    let brightness: Double  // 0.0–1.0
}

// MARK: - CompositionEngine

/// Pure render engine — no I/O, no bridge calls. Given time + params, outputs frames.
/// The caller (UnifiedOrchestrator) handles transport (DTLS or REST).
enum CompositionEngine {

    /// Render one frame for all lights.
    ///
    /// - Parameters:
    ///   - time: Elapsed seconds since composition started (monotonic).
    ///   - channelIDs: Entertainment API channel IDs for each light.
    ///   - params: Live composition parameters (read each frame for slider responsiveness).
    ///   - audioLevel: Normalized audio amplitude (0.0–1.0) from mic, or 0 if no reaction.
    /// - Returns: Array of LightFrame, one per channel.
    static func render(
        time: Double,
        channelIDs: [UInt8],
        params: CompositionParamBox,
        audioLevel: Float = 0
    ) -> [LightFrame] {
        let total = channelIDs.count
        let palette = params.palette
        let motion = params.motion
        let envelope = params.envelope
        let reaction = params.reaction

        return channelIDs.enumerated().map { (index, channelID) in
            // 1. Motion: where is this light in the palette cycle?
            let phase = motion.phase(lightIndex: index, total: total, time: time)

            // 2. Palette: what CIE xy color at this phase?
            let color = palette.color(at: phase)

            // 3. Envelope: what brightness at this time?
            var bri = envelope.value(at: time)

            // 4. Reaction: modify brightness based on audio input
            bri = reaction.apply(baseBrightness: bri, audioLevel: audioLevel, time: time)

            // Clamp final brightness
            bri = min(1.0, max(0.0, bri))

            return LightFrame(channelID: channelID, x: color.x, y: color.y, brightness: bri)
        }
    }
}
