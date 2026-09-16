// Composer2LiveOutput.swift
// ChromaGlow — Composer 2 lab (experimental).
//
// The runtime that stands between the pure engine and the existing render
// loops. It conforms to `CompositionFrameSource`, so a legacy
// `CompositionParamBox` whose `frameSource` is this object streams Composer 2
// frames through the orchestrator's untouched transport, safety gate,
// failover and stop paths. It is main-actor confined by convention — the
// same contract as `CompositionParamBox` itself — and holds every piece of
// per-frame mutable state so nothing observable is written at frame rate.

import Foundation

final class Composer2LiveOutput: CompositionFrameSource, @unchecked Sendable {

    /// The composition being played. Edits land here synchronously; the next
    /// frame picks them up — no session restart, no task per slider tick.
    var composition: Composer2Composition {
        didSet { if composition != oldValue { plansDirty = true } }
    }

    /// 0…1 cap on event flashes (Dim Flashing Lights ⇒ 0.3). Applied on the
    /// wire and on screen alike.
    var eventCap: Double = 1

    /// Light identities per render slot when a layout could resolve them.
    var layoutLightIDs: [String]? {
        didSet { geometry = geometry.withLightIDs(layoutLightIDs); plansDirty = true }
    }

    private(set) var state = Composer2EngineState()
    private(set) var geometry = Composer2SlotGeometry.linear(count: 0)
    private(set) var lastFrames: [Composer2Frame] = []
    /// Engine time of the last render (any path).
    private(set) var lastRenderTime: Double?
    /// Host time when the LIVE loop last asked for a frame (0 = never).
    private(set) var lastLiveRenderAt: Double = 0

    private var plans: [Composer2LayerPlan] = []
    private var plansDirty = true
    private var frameBuffer: [Composer2Frame] = []
    private var cachedRadial: [Double] = []
    private var cachedAngular: [Double] = []
    private var geometryFromBox = false

    /// A backwards jump larger than this resets the engine state.
    static let backwardsResetTolerance: Double = 0.5

    init(composition: Composer2Composition) {
        self.composition = composition
    }

    func reset() {
        state.reset()
        plansDirty = true
        lastRenderTime = nil
        lastLiveRenderAt = 0
    }

    /// The preview's geometry (a UI layout). Ignored once a live loop has
    /// installed the orchestrator's own slot geometry.
    func setPreviewGeometry(_ g: Composer2SlotGeometry) {
        guard !geometryFromBox else { return }
        if g != geometry {
            geometry = g.withLightIDs(layoutLightIDs ?? g.lightIDs)
            plansDirty = true
        }
    }

    /// Forget the live geometry (after a stop) so previews may lay out again.
    func releaseLiveGeometry() {
        geometryFromBox = false
        cachedRadial = []
        cachedAngular = []
        lastLiveRenderAt = 0
    }

    // MARK: CompositionFrameSource

    func renderFrames(time: Double, channelIDs: [Int], params: CompositionParamBox,
                      features: AudioFeatures, beat: BeatSnapshot, hostNow: Double) -> [LightFrame] {
        lastLiveRenderAt = hostNow
        installGeometry(count: channelIDs.count, radial: params.radialPositions, angular: params.angularPositions)
        let frames = evaluate(time: time, features: features, beat: beat, hostNow: hostNow)
        guard frames.count == channelIDs.count else { return [] }
        var out: [LightFrame] = []
        out.reserveCapacity(frames.count)
        for (i, f) in frames.enumerated() {
            out.append(LightFrame(channelID: channelIDs[i], x: f.x, y: f.y, brightness: f.brightness))
        }
        return out
    }

    // MARK: Evaluation

    /// Evaluate on the current geometry. Shared by the live loop and the
    /// on-screen preview so both show the same frames.
    @discardableResult
    func evaluate(time rawTime: Double, features: AudioFeatures = .silent, beat: BeatSnapshot = .none,
                  hostNow: Double = 0) -> [Composer2Frame] {
        var time = rawTime.isFinite ? rawTime : (lastRenderTime ?? 0)
        if let last = lastRenderTime, time < last - Composer2LiveOutput.backwardsResetTolerance {
            state.reset()
            plansDirty = true
        }
        if time.isNaN { time = 0 }
        if plansDirty {
            plans = Composer2Engine.plans(for: composition, geometry: geometry)
            plansDirty = false
        }
        Composer2Engine.evaluate(composition, time: time, geometry: geometry, plans: &plans, state: &state,
                                 audio: features, beat: beat, hostNow: hostNow, eventCap: eventCap,
                                 into: &frameBuffer)
        lastRenderTime = time
        lastFrames = frameBuffer
        return frameBuffer
    }

    private func installGeometry(count: Int, radial: [Double], angular: [Double]) {
        let usable = radial.count == count && angular.count == count && count > 0
        if usable {
            if geometryFromBox, cachedRadial == radial, cachedAngular == angular, geometry.count == count { return }
            cachedRadial = radial
            cachedAngular = angular
            geometry = Composer2SlotGeometry(radial: radial, angular: angular, lightIDs: layoutLightIDs)
        } else {
            if geometryFromBox, geometry.count == count, !geometry.hasSpatialData { return }
            cachedRadial = []
            cachedAngular = []
            geometry = .linear(count: count, lightIDs: layoutLightIDs)
        }
        geometryFromBox = true
        plansDirty = true
    }

    // MARK: Legacy box mirroring

    /// The legacy reaction source that makes the orchestrator hold the
    /// microphone exactly when this composition needs it.
    func mirroredReactionSource() -> ReactionConfig.Source {
        if composition.usesMicrophoneBands { return .micAmplitude }
        if composition.usesBeatClock { return .beat }
        return .none
    }
}
