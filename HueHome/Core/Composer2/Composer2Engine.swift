// Composer2Engine.swift
// ChromaGlow — Composer 2 lab (experimental).
//
// The pure evaluator: (composition, geometry, time, audio, state) → frames.
// No clocks, no global random source, no I/O. All per-frame randomness is
// a function of (seed, layer, slot, cell) so the same seed reproduces the
// same sequence; audio only tilts thresholds and multipliers.
//
// Per-layer pipeline, per light:
//   mask → motion (event kick applied) → palette → rhythm × weight × audio
//   × variation → event screen / colour mix → composite → master intensity
//   → gamut-C chromaticity.

import Foundation

// MARK: - Output

struct Composer2Frame: Equatable {
    let slot: Int
    let x: Double
    let y: Double
    let brightness: Double

    var isValid: Bool { x.isFinite && y.isFinite && brightness.isFinite && brightness >= 0 && brightness <= 1 }
}

// MARK: - State

struct Composer2LayerState: Equatable {
    var events: Composer2EventState?
    var smoothedDrive: Double = 0
    /// Accumulated (speed − 1) · dt — exactly 0 while nothing warps.
    var warpOffset: Double = 0
    var paletteStepPhase: Double = 0
    var lastTriggerBeatIndex: Int = .min
    var lastOnsetSeen: Double = 0
}

struct Composer2EngineState: Equatable {
    var layerIDs: [UUID] = []
    var layers: [Composer2LayerState] = []
    var lastTime: Double? = nil

    /// Keep state for layers that still exist (by id), start fresh for new ones.
    mutating func realign(to composition: Composer2Composition) {
        let ids = composition.layers.map(\.id)
        guard ids != layerIDs else { return }
        var next: [Composer2LayerState] = []
        next.reserveCapacity(ids.count)
        for id in ids {
            if let i = layerIDs.firstIndex(of: id) {
                next.append(layers[i])
            } else {
                next.append(Composer2LayerState())
            }
        }
        layerIDs = ids
        layers = next
    }

    mutating func reset() {
        layerIDs = []
        layers = []
        lastTime = nil
    }
}

// MARK: - Per-layer plan (precomputed per geometry/layer change)

struct Composer2LayerPlan: Equatable {
    let layer: Composer2Layer
    let geometryCount: Int
    let geometrySpatial: Bool
    let layerSeed: UInt64
    let eventSeed: UInt64
    let maskWeights: [Double]
    let axisPositions: [Double]
    let crossPositions: [Double]
    let jitters: [Composer2Variation.SlotJitter]
    let palette: Composer2CompiledPalette
    let events: Composer2EventSpec?
    let eventFlashLab: Composer2Lab?
    let rhythmPeriod: Double
    let motionPeriod: Double
    let masterVariation: Double

    static func build(layer: Composer2Layer, composition: Composer2Composition,
                      geometry: Composer2SlotGeometry) -> Composer2LayerPlan {
        let layerSeed = Composer2Engine.layerSeed(composition: composition, layer: layer)
        let events = layer.events?.sanitized
        let eventSeed = Composer2Engine.eventSeed(layerSeed: layerSeed, spec: events)
        let n = geometry.count
        var variation = layer.variation
        variation.amount = Composer2Math.clamp01(variation.amount * Composer2Math.clamp(composition.master.variation, 0, 2))
        let axis = geometry.projection(kind: layer.motion.axisKind, angleDegrees: layer.motion.angleDegrees)
        let crossKind: Composer2Motion.AxisKind = layer.motion.axisKind == .angle ? .angle : .principal
        let crossAngle = (layer.motion.axisKind == .angle ? layer.motion.angleDegrees : geometry.principalAngleDegrees) + 90
        let cross = geometry.hasSpatialData
            ? geometry.projection(kind: crossKind, angleDegrees: crossAngle)
            : Array(repeating: 0.5, count: n)
        let jitters = (0..<n).map { variation.slotJitter(slot: $0, seed: layerSeed) }
        return Composer2LayerPlan(
            layer: layer,
            geometryCount: n,
            geometrySpatial: geometry.hasSpatialData,
            layerSeed: layerSeed,
            eventSeed: eventSeed,
            maskWeights: layer.mask.weights(geometry: geometry, seed: Composer2Hash.mix(layerSeed, 0x3A5C)),
            axisPositions: axis,
            crossPositions: cross,
            jitters: jitters,
            palette: Composer2CompiledPalette(layer.color),
            events: events,
            eventFlashLab: events?.color.map { Composer2ColorMath.lab(fromXY: $0) },
            rhythmPeriod: layer.rhythm.sanitizedPeriod,
            motionPeriod: layer.motion.sanitizedPeriod,
            masterVariation: composition.master.variation
        )
    }

    func matches(layer: Composer2Layer, composition: Composer2Composition, geometry: Composer2SlotGeometry) -> Bool {
        self.layer == layer && geometryCount == geometry.count
            && geometrySpatial == geometry.hasSpatialData
            && masterVariation == composition.master.variation
    }
}

// MARK: - Engine

enum Composer2Engine {
    /// Randomness is keyed by layer identity, not index, so reordering layers
    /// does not reshuffle what each light does.
    static func layerSeed(composition: Composer2Composition, layer: Composer2Layer) -> UInt64 {
        if let explicit = layer.variation.seed { return explicit }
        return Composer2Hash.mix(composition.master.seed, Composer2Hash.seed(from: layer.id))
    }

    static func eventSeed(layerSeed: UInt64, spec: Composer2EventSpec?) -> UInt64 {
        if let explicit = spec?.seed { return explicit }
        return Composer2Hash.mix(layerSeed, 0xE7E)
    }

    static func plans(for composition: Composer2Composition, geometry: Composer2SlotGeometry) -> [Composer2LayerPlan] {
        composition.layers.map { Composer2LayerPlan.build(layer: $0, composition: composition, geometry: geometry) }
    }

    /// Pure evaluation with fresh plan buffers (tests, previews).
    static func evaluate(_ composition: Composer2Composition, time: Double, geometry: Composer2SlotGeometry,
                         state: inout Composer2EngineState, audio: AudioFeatures = .silent,
                         beat: BeatSnapshot = .none, hostNow: Double = 0, eventCap: Double = 1) -> [Composer2Frame] {
        var plans = self.plans(for: composition, geometry: geometry)
        var frames: [Composer2Frame] = []
        evaluate(composition, time: time, geometry: geometry, plans: &plans, state: &state,
                 audio: audio, beat: beat, hostNow: hostNow, eventCap: eventCap, into: &frames)
        return frames
    }

    /// Buffer-reusing evaluation (the live path).
    static func evaluate(_ composition: Composer2Composition, time rawTime: Double, geometry: Composer2SlotGeometry,
                         plans: inout [Composer2LayerPlan], state: inout Composer2EngineState,
                         audio: AudioFeatures, beat: BeatSnapshot, hostNow: Double, eventCap: Double,
                         into frames: inout [Composer2Frame]) {
        frames.removeAll(keepingCapacity: true)
        let n = geometry.count
        let time = rawTime.isFinite ? rawTime : (state.lastTime ?? 0)
        state.realign(to: composition)
        let dt = state.lastTime.map { Composer2Math.clamp(time - $0, 0, 0.5) } ?? 0
        state.lastTime = time
        guard n > 0 else { return }

        if plans.count != composition.layers.count {
            plans = self.plans(for: composition, geometry: geometry)
        }

        var acc = [Composer2Blend.Accum](repeating: Composer2Blend.Accum(), count: n)
        let masterSpeed = composition.master.sanitizedSpeed
        let cap = Composer2Math.clamp01(eventCap)

        for li in 0..<composition.layers.count {
            let layer = composition.layers[li]
            if !plans[li].matches(layer: layer, composition: composition, geometry: geometry) {
                plans[li] = Composer2LayerPlan.build(layer: layer, composition: composition, geometry: geometry)
            }
            let plan = plans[li]
            var ls = state.layers[li]
            defer { state.layers[li] = ls }
            guard layer.contributes else {
                ls.events = nil
                continue
            }

            // ── Audio drive (one value per frame, uniform across lights) ──
            let mod = layer.audio
            let drive: Double
            if mod.isActive {
                let raw = mod.rawDrive(features: audio, beat: beat, hostNow: hostNow)
                let tau = mod.smoothingTau
                let alpha = tau <= 0.001 ? 1.0 : 1.0 - exp(-dt / tau)
                ls.smoothedDrive += (raw - ls.smoothedDrive) * alpha
                drive = Composer2Math.clamp01(ls.smoothedDrive)
            } else {
                ls.smoothedDrive = 0
                drive = 0
            }

            // ── Speed warp: accumulate, never scale (no phase jumps) ──
            let speedMult = masterSpeed * mod.speedMultiplier(drive: drive)
            if speedMult != 1 { ls.warpOffset += dt * (speedMult - 1) }
            let motionTime = time + ls.warpOffset

            // ── Palette stepping on beat / onset ──
            if mod.isActive, mod.targets.contains(.palettePosition) {
                switch mod.source {
                case .beat:
                    if beat.bpm > 0, hostNow > 0, mod.quantizeBeats > 0 {
                        let q = Composer2Math.safeFloorInt(Double(beat.beatIndex(at: hostNow)) / mod.quantizeBeats)
                        if ls.lastTriggerBeatIndex == .min {
                            ls.lastTriggerBeatIndex = q
                        } else if q > ls.lastTriggerBeatIndex {
                            let steps = Double(q - ls.lastTriggerBeatIndex)
                            ls.paletteStepPhase = Composer2Math.frac(ls.paletteStepPhase + mod.paletteStep * steps)
                            ls.lastTriggerBeatIndex = q
                        }
                    }
                case .onset:
                    if audio.lastOnsetAt > ls.lastOnsetSeen {
                        ls.lastOnsetSeen = audio.lastOnsetAt
                        ls.paletteStepPhase = Composer2Math.frac(ls.paletteStepPhase + mod.paletteStep)
                    }
                default:
                    break
                }
            }
            let paletteOffset = ls.paletteStepPhase + mod.paletteOffset(drive: drive)

            // ── Events ──
            var eventSpec: Composer2EventSpec? = nil
            if let spec = plan.events {
                eventSpec = spec
                let timing = layer.variation.effectiveEventTiming
                if ls.events == nil {
                    ls.events = Composer2EventState.initial(spec: spec, eventSeed: plan.eventSeed,
                                                            startTime: time, timingVariation: timing)
                }
                var force = false
                if mod.triggerEventsOnOnset, mod.isActive, audio.lastOnsetAt > 0, audio.lastOnsetAt > ls.lastOnsetSeen {
                    force = true
                    ls.lastOnsetSeen = audio.lastOnsetAt
                }
                ls.events?.advance(to: time, spec: spec, eventSeed: plan.eventSeed, geometry: geometry,
                                   timingVariation: timing, probabilityBoost: mod.probabilityBoost(drive: drive),
                                   forceOpportunity: force)
                if let current = ls.events?.current, current.targets.count != n {
                    ls.events?.rebuildTargets(geometry: geometry, eventSeed: plan.eventSeed, spec: spec)
                }
            } else {
                ls.events = nil
            }

            let brightnessScale = mod.brightnessScale(drive: drive)
            let punch = mod.punch(drive: drive)
            let evolving = layer.variation.evolveRate > 0
            let coverageBase = Composer2Math.clamp01(layer.opacity)
            let modulatesBrightness = eventSpec?.modulates.contains(.brightness) ?? false
            let modulatesColor = (eventSpec?.modulates.contains(.color) ?? false) && plan.eventFlashLab != nil
            let modulatesMotion = eventSpec?.modulates.contains(.motion) ?? false
            let randomPickCell = Swift.max(0.5, plan.motionPeriod)
            let stopCount = plan.palette.stopCount
            let rhythm = layer.rhythm
            let beatLocked = rhythm.quantizeBeats > 0 && beat.bpm > 0 && hostNow > 0

            for i in 0..<n {
                let m = plan.maskWeights[i]
                guard m > 0 else { continue }
                let jitter = evolving
                    ? layer.variation.slotJitter(slot: i, seed: plan.layerSeed, time: time)
                    : plan.jitters[i]
                let pos = Composer2Math.clamp01(plan.axisPositions[i] + jitter.position)
                let tSlot = motionTime * (1 + jitter.speed)
                let e = Composer2Math.clamp01((ls.events?.sample(slot: i, time: time) ?? 0) * cap)

                let sample = layer.motion.sample(slot: i, position: pos, cross: plan.crossPositions[i],
                                                 time: tSlot, seed: plan.layerSeed)
                var phase = sample.phase
                switch layer.color.distribution {
                case .motion:
                    break
                case .spatial:
                    phase = pos
                case .uniform:
                    phase = 0
                case .randomPick:
                    let cell = Composer2Math.safeFloorInt(motionTime / randomPickCell)
                    let pick = Swift.min(stopCount - 1, Int(Composer2Hash.unit(plan.layerSeed, i, cell, salt: 0x91C) * Double(stopCount)))
                    phase = stopCount > 0 ? plan.palette.positions[Swift.max(0, pick)] : 0
                }
                phase += jitter.phase
                phase += layer.variation.drift(slot: i, seed: plan.layerSeed, time: time)
                phase += paletteOffset
                if modulatesMotion, let spec = eventSpec { phase += spec.motionKick * e }
                var lab = plan.palette.sample(phase)

                let cyclePhase: Double
                if beatLocked {
                    let beats = (hostNow - beat.beatEpoch) / beat.beatInterval
                    cyclePhase = beats / rhythm.quantizeBeats
                } else {
                    cyclePhase = time / plan.rhythmPeriod
                }
                var bri = rhythm.value(cyclePhase: cyclePhase + jitter.phase, time: time, slot: i, seed: plan.layerSeed)
                bri *= sample.weight * brightnessScale * (1 - jitter.brightness)
                if punch > 0 { bri += (1 - bri) * punch }

                if e > 0 {
                    if modulatesBrightness { bri += (1 - bri) * e }
                    if modulatesColor, let flash = plan.eventFlashLab {
                        lab = Composer2ColorMath.mixHueArc(lab, flash, t: e)
                    }
                }
                Composer2Blend.composite(&acc[i], lab: lab, brightness: bri, coverage: coverageBase * m, mode: layer.blend)
            }
        }

        let intensity = Composer2Math.clamp01(composition.master.intensity)
        frames.reserveCapacity(n)
        for i in 0..<n {
            let xy = Composer2ColorMath.xy(fromLab: acc[i].lab)
            let bri = Composer2Math.clamp01(acc[i].brightness * intensity)
            frames.append(Composer2Frame(slot: i, x: xy.x, y: xy.y, brightness: bri))
        }
    }
}
