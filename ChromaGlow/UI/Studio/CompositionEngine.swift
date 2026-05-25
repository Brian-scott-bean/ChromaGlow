// CompositionEngine.swift
// ChromaGlow — Composer v0.18.0
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
    var isColorPadInteracting: Bool = false
    /// UI-driven short burst window to bypass REST low-power skipping
    /// so direct user edits flush to the bridge immediately.
    var forceRESTBurstUntil: TimeInterval = 0

    // ── Spatial Motion ────────────────────────────────────────
    /// Pre-computed normalized spatial positions (0–1) for each channel.
    /// Ordered to match channelIDs in render(). Empty = use index fallback.
    var spatialPositions: [Double] = []
    /// Target positions for smooth lerp transitions when angle changes.
    var targetSpatialPositions: [Double] = []
    /// Progress 0→1 for lerp from spatialPositions to targetSpatialPositions.
    /// 1.0 = transition complete, use targetSpatialPositions directly.
    var spatialLerpProgress: Double = 1.0
    /// Timestamp of last render frame — used to advance lerp progress.
    var lastRenderTime: Double = 0

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

    func triggerRESTBurst(seconds: TimeInterval = 0.55) {
        let now = Date().timeIntervalSinceReferenceDate
        forceRESTBurstUntil = max(forceRESTBurstUntil, now + seconds)
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

    // ──────────────────────────────────────────────
    // MARK: - Spatial Position Computation
    // ──────────────────────────────────────────────

    /// Project light positions onto a 2D direction vector.
    /// Returns positions ordered to match the given lightIDs (for REST transport).
    ///
    /// - Parameters:
    ///   - lightPositions: Pre-built map of lightID → (x, z) position.
    ///     Built by the orchestrator by bridging entertainment service IDs → device → light IDs.
    ///   - orderedLightIDs: REST light IDs in render order.
    ///   - motionAngle: Direction angle in degrees (0–360).
    static func computeSpatialPositions(
        lightPositions: [String: (x: Double, z: Double)],
        orderedLightIDs: [String],
        motionAngle: Double
    ) -> [Double] {
        guard orderedLightIDs.count > 1 else {
            return orderedLightIDs.isEmpty ? [] : [0.5]
        }

        let rad = motionAngle * .pi / 180.0
        let dx = cos(rad), dz = sin(rad)

        var projections: [Double] = []
        var hasMissing = false
        for lightID in orderedLightIDs {
            if let pos = lightPositions[lightID] {
                projections.append(pos.x * dx + pos.z * dz)
            } else {
                hasMissing = true
                projections.append(0)
            }
        }

        // If any light has no position, fall back to index-based
        guard !hasMissing else { return [] }

        return normalizeProjections(projections)
    }

    /// Project entertainment channel positions onto a 2D direction vector.
    /// Returns positions in entertainment channel order (for DTLS transport).
    static func computeSpatialPositionsForEntertainment(
        channels: [EntertainmentChannel],
        motionAngle: Double
    ) -> [Double] {
        guard channels.count > 1 else {
            return channels.isEmpty ? [] : [0.5]
        }

        let rad = motionAngle * .pi / 180.0
        let dx = cos(rad), dz = sin(rad)

        let projections = channels.map { ch in
            ch.position.x * dx + ch.position.z * dz
        }

        return normalizeProjections(projections)
    }

    /// Normalize projections to 0–1 range.
    private static func normalizeProjections(_ projections: [Double]) -> [Double] {
        let minP = projections.min() ?? 0
        let maxP = projections.max() ?? 1
        let range = maxP - minP
        guard range > 0.001 else {
            return projections.map { _ in 0.5 }
        }
        return projections.map { ($0 - minP) / range }
    }

    /// Compute the principal axis angle (PCA) of entertainment channel positions.
    /// Returns the angle (0–360°) along which lights have maximum spread.
    /// Used as the default motionAngle when the user hasn't set one.
    static func principalAngle(channels: [EntertainmentChannel]) -> Double {
        guard channels.count > 1 else { return 0 }

        // Compute mean
        let n = Double(channels.count)
        let meanX = channels.reduce(0.0) { $0 + $1.position.x } / n
        let meanZ = channels.reduce(0.0) { $0 + $1.position.z } / n

        // Compute covariance matrix elements [cxx, cxz; cxz, czz]
        var cxx = 0.0, cxz = 0.0, czz = 0.0
        for ch in channels {
            let dx = ch.position.x - meanX
            let dz = ch.position.z - meanZ
            cxx += dx * dx
            cxz += dx * dz
            czz += dz * dz
        }

        // Principal eigenvector via atan2 of the 2x2 symmetric matrix
        // θ = 0.5 * atan2(2 * cxz, cxx - czz)
        let angle = 0.5 * atan2(2.0 * cxz, cxx - czz)
        var degrees = angle * 180.0 / .pi
        if degrees < 0 { degrees += 360 }
        return degrees
    }

    // ──────────────────────────────────────────────
    // MARK: - Render
    // ──────────────────────────────────────────────

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

        // Advance lerp progress (0.3s transition)
        if params.spatialLerpProgress < 1.0 {
            let deltaTime = params.lastRenderTime > 0 ? time - params.lastRenderTime : 0.04
            params.spatialLerpProgress = min(1.0, params.spatialLerpProgress + deltaTime / 0.3)
            // When lerp completes, commit target as current
            if params.spatialLerpProgress >= 1.0 {
                params.spatialPositions = params.targetSpatialPositions
            }
        }
        params.lastRenderTime = time

        return channelIDs.enumerated().map { (index, channelID) in
            // 1. Motion: where is this light in the palette cycle?
            let phase: Double
            let useSpatial = index < params.spatialPositions.count
                && motion.pattern != .scatter
            if useSpatial {
                // Interpolate between old and new positions during transition
                var pos = params.spatialPositions[index]
                if params.spatialLerpProgress < 1.0,
                   index < params.targetSpatialPositions.count {
                    let t = params.spatialLerpProgress
                    pos = pos * (1.0 - t) + params.targetSpatialPositions[index] * t
                }
                phase = motion.phase(spatialPosition: pos, time: time)
            } else {
                phase = motion.phase(lightIndex: index, total: total, time: time)
            }

            // 2. Palette: what CIE xy color at this phase?
            let color = palette.color(at: phase)

            // 3. Envelope: what brightness at this time?
            var bri = envelope.value(at: time)

            // 4. Reaction: mic bands use external audioLevel; tap tempo is BPM-synced (no mic).
            let reactionAudio: Float
            switch reaction.source {
            case .tapTempo:
                let hz = envelope.bpm / 60.0
                reactionAudio = Float(0.5 + 0.5 * sin(2.0 * Double.pi * hz * time))
            case .micAmplitude, .micBass, .micMid, .micTreble:
                reactionAudio = audioLevel
            case .none:
                reactionAudio = 0
            }

            bri = reaction.apply(baseBrightness: bri, audioLevel: reactionAudio, time: time)

            // Clamp final brightness
            bri = min(1.0, max(0.0, bri))

            return LightFrame(channelID: channelID, x: color.x, y: color.y, brightness: bri)
        }
    }
}

