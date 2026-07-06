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

    /// Normalized distance from the room centroid per channel (pulseCenter).
    /// Empty = derive from the linear position by center-folding.
    var radialPositions: [Double] = []
    /// Normalized angle around the centroid per channel (spiral).
    /// Empty = use the linear position.
    var angularPositions: [Double] = []

    // ── Reaction runtime state (Phase 2) ──────────────────────
    // Mutated by render() each frame; MainActor-confined by the same
    // convention as the rest of this box (audit I-10).
    /// Speed-warped motion time — accumulates dt × speed multiplier so the
    /// `.speed` reaction target changes tempo without phase jumps.
    var warpedMotionTime: Double = 0
    /// Beat-advanced palette offset (`.color` target, quantized triggers).
    var reactionColorPhase: Double = 0
    /// Last quantized trigger index consumed (Int.min = not yet anchored).
    var lastTriggerBeatIndex: Int = .min
    /// One-pole smoothed reaction drive — finally implements `smoothing`.
    var smoothedReactionLevel: Float = 0
    /// Last onset timestamp consumed by the `.color` advance (dedup at 25 fps).
    var lastOnsetSeen: Double = 0

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

    /// Radial (distance-from-centroid) + angular (bearing) positions for the
    /// pulseCenter/spiral patterns, in entertainment channel order.
    static func computeRadialAngular(
        channels: [EntertainmentChannel]
    ) -> (radial: [Double], angular: [Double]) {
        computeRadialAngular(points: channels.map { ($0.position.x, $0.position.z) })
    }

    /// Same, in REST light order (positions bridged from the entertainment
    /// configuration). Lights without a position get center values.
    static func computeRadialAngular(
        lightPositions: [String: (x: Double, z: Double)],
        orderedLightIDs: [String]
    ) -> (radial: [Double], angular: [Double]) {
        let points = orderedLightIDs.map { id -> (Double, Double) in
            let p = lightPositions[id]
            return (p?.x ?? 0, p?.z ?? 0)
        }
        return computeRadialAngular(points: points)
    }

    private static func computeRadialAngular(
        points: [(Double, Double)]
    ) -> (radial: [Double], angular: [Double]) {
        guard points.count > 1 else {
            return (points.map { _ in 0.5 }, points.map { _ in 0.5 })
        }
        let n = Double(points.count)
        let cx = points.reduce(0.0) { $0 + $1.0 } / n
        let cz = points.reduce(0.0) { $0 + $1.1 } / n
        let dists = points.map { hypot($0.0 - cx, $0.1 - cz) }
        let maxDist = dists.max() ?? 0
        let radial = maxDist > 0.001 ? dists.map { $0 / maxDist } : dists.map { _ in 0.5 }
        let angular = points.map { (atan2($0.1 - cz, $0.0 - cx) / (2 * .pi)) + 0.5 }
        return (radial, angular)
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
    ///   - audioLevel: LEGACY mic amplitude (0–1) — used for mic sources only
    ///     while `features` is `.silent`; removed once all callers pass features.
    ///   - features: Current audio features (AGC bands, onsets) from AudioAnalysisEngine.
    ///   - beat: Shared BeatClock snapshot — beat phase is extrapolated per frame.
    ///   - hostNow: Host time (CACurrentMediaTime timebase) of this frame;
    ///     required for beat/onset sources. 0 = unavailable.
    /// - Returns: Array of LightFrame, one per channel.
    static func render(
        time: Double,
        channelIDs: [UInt8],
        params: CompositionParamBox,
        audioLevel: Float = 0,
        features: AudioFeatures = .silent,
        beat: BeatSnapshot = .none,
        hostNow: Double = 0
    ) -> [LightFrame] {
        let total = channelIDs.count
        let palette = params.palette
        let motion = params.motion
        let envelope = params.envelope
        let reaction = params.reaction

        let dt = params.lastRenderTime > 0 ? max(0.0, time - params.lastRenderTime) : 0.04

        // Advance lerp progress (0.3s transition)
        if params.spatialLerpProgress < 1.0 {
            params.spatialLerpProgress = min(1.0, params.spatialLerpProgress + dt / 0.3)
            // When lerp completes, commit target as current
            if params.spatialLerpProgress >= 1.0 {
                params.spatialPositions = params.targetSpatialPositions
            }
        }
        params.lastRenderTime = time

        // ── Reaction drive (one value per frame, uniform across lights) ──
        let hasFeatures = features.timestamp > 0
        let drive: Double
        switch reaction.source {
        case .none:
            drive = 0
        case .micAmplitude:
            drive = reaction.shapedMicLevel(Double(hasFeatures ? features.level : audioLevel))
        case .micBass:
            drive = reaction.shapedMicLevel(Double(hasFeatures ? features.bass : audioLevel))
        case .micMid:
            drive = reaction.shapedMicLevel(Double(hasFeatures ? features.mid : audioLevel))
        case .micTreble:
            drive = reaction.shapedMicLevel(Double(hasFeatures ? features.treble : audioLevel))
        case .beat, .tapTempo:
            if beat.bpm > 0, hostNow > 0 {
                // Per-beat punch: bright at the beat, exponential decay after.
                drive = exp(-beat.timeSinceBeat(at: hostNow) / reaction.punchDecayTau)
            } else if reaction.source == .tapTempo {
                // Legacy fallback: no clock running — synthesize the old
                // envelope-BPM LFO so pre-Phase-2 presets keep moving.
                let hz = envelope.bpm / 60.0
                drive = 0.5 + 0.5 * sin(2.0 * Double.pi * hz * time)
            } else {
                drive = 0
            }
        case .onset:
            if hostNow > 0, features.lastOnsetAt > 0 {
                drive = Double(exp(-(hostNow - features.lastOnsetAt) / reaction.punchDecayTau))
            } else {
                drive = Double(features.onsetStrength)
            }
        }

        // `smoothing` (0–100 → one-pole τ 0…0.5 s) — previously a dead knob.
        let tau = reaction.smoothing / 100.0 * 0.5
        let alpha = tau <= 0.001 ? 1.0 : 1.0 - exp(-dt / tau)
        params.smoothedReactionLevel += (Float(drive) - params.smoothedReactionLevel) * Float(alpha)
        let smoothed = Double(params.smoothedReactionLevel)

        // ── `.speed` target: warp motion time, never scale it (no jumps) ──
        var speedMultiplier = 1.0
        if reaction.source != .none, reaction.targets.contains(.speed) {
            speedMultiplier = 1.0 + smoothed * (reaction.intensity / 100.0) * 2.0
        }
        params.warpedMotionTime += dt * speedMultiplier
        let motionTime = params.warpedMotionTime

        // Beat-locked motion: one cycle = exactly N beats.
        var overridePeriod: Double?
        if reaction.motionBeatsPerCycle > 0, beat.bpm > 0 {
            overridePeriod = reaction.motionBeatsPerCycle * beat.beatInterval
        }

        // ── `.color` target: quantized palette-phase advance per beat/onset,
        // continuous offset for mic sources ──
        var continuousColorOffset = 0.0
        if reaction.source != .none, reaction.targets.contains(.color) {
            switch reaction.source {
            case .beat, .tapTempo:
                if beat.bpm > 0, hostNow > 0, reaction.quantizeBeats > 0 {
                    let qIndex = Int(floor(Double(beat.beatIndex(at: hostNow)) / reaction.quantizeBeats))
                    if params.lastTriggerBeatIndex == .min {
                        params.lastTriggerBeatIndex = qIndex
                    } else if qIndex > params.lastTriggerBeatIndex {
                        let steps = Double(qIndex - params.lastTriggerBeatIndex)
                        params.reactionColorPhase =
                            (params.reactionColorPhase + reaction.colorStepPerTrigger * steps)
                            .truncatingRemainder(dividingBy: 1.0)
                        params.lastTriggerBeatIndex = qIndex
                    }
                }
            case .onset:
                if features.lastOnsetAt > params.lastOnsetSeen {
                    params.lastOnsetSeen = features.lastOnsetAt
                    params.reactionColorPhase =
                        (params.reactionColorPhase + reaction.colorStepPerTrigger)
                        .truncatingRemainder(dividingBy: 1.0)
                }
            case .micAmplitude, .micBass, .micMid, .micTreble:
                continuousColorOffset = smoothed * (reaction.intensity / 100.0) * 0.5
            case .none:
                break
            }
        }
        let colorOffset = params.reactionColorPhase + continuousColorOffset

        // Palette randomize (previously a dead knob): each light drifts
        // between stable per-cycle random palette positions.
        let randomizePeriod = max(0.5, overridePeriod ?? motion.periodSeconds)

        let applyBrightness = reaction.source != .none && reaction.targets.contains(.brightness)

        return channelIDs.enumerated().map { (index, channelID) in
            // 1. Motion: palette phase + intensity weight for this light.
            let position: Double
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
                position = pos
            } else {
                position = total > 1 ? Double(index) / Double(total - 1) : 0.5
            }

            let sample = motion.sample(
                position: position,
                radial: index < params.radialPositions.count ? params.radialPositions[index] : nil,
                angular: index < params.angularPositions.count ? params.angularPositions[index] : nil,
                lightIndex: index,
                time: motionTime,
                overridePeriod: overridePeriod
            )

            // 2. Palette: randomize overrides the motion phase with a smooth
            // per-light random drift; the reaction color offset shifts either.
            var phase = sample.phase
            if palette.randomize {
                let cellPos = motionTime / randomizePeriod
                let cell = Int(floor(cellPos))
                let ft = cellPos - floor(cellPos)
                let s = ft * ft * (3 - 2 * ft)
                let h1 = Self.hash01(index, cell)
                let h2 = Self.hash01(index, cell + 1)
                phase = h1 * (1 - s) + h2 * s
            }
            phase = (phase + colorOffset).truncatingRemainder(dividingBy: 1.0)
            if phase < 0 { phase += 1 }
            let color = palette.color(at: phase)

            // 3. Envelope brightness × motion weight (spread's beam shaping).
            var bri = envelope.value(at: time) * sample.weight

            // 4. Brightness reaction with the smoothed drive.
            if applyBrightness {
                bri *= reaction.brightnessScale(drive: smoothed)
            }

            // Clamp final brightness
            bri = min(1.0, max(0.0, bri))

            return LightFrame(channelID: channelID, x: color.x, y: color.y, brightness: bri)
        }
    }

    /// Deterministic per-light hash → 0–1 (palette randomize).
    static func hash01(_ index: Int, _ cell: Int) -> Double {
        let v = sin(Double(index &* 7919 &+ cell &* 104729) + 0.731) * 43758.5453
        return v - floor(v)
    }
}

