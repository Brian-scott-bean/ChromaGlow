// Composer2LegacyImport.swift
// ChromaGlow — Composer 2 lab (experimental).
//
// Brings an existing Composer preset (four configs) into the universal model
// as ONE behavior layer. Non-destructive: the legacy preset is read, never
// written, and the imported composition carries a derived, stable id so
// importing twice yields the same document.

import Foundation

enum Composer2LegacyImport {

    /// One layer that plays like the legacy preset.
    static func layer(from preset: CompositionPreset) -> Composer2Layer {
        var layer = Composer2Layer(id: derivedLayerID(from: preset.id), name: preset.name)
        layer.color = colorSource(from: preset.palette)
        let mapped = motion(from: preset.motion)
        layer.motion = mapped.motion
        layer.events = mapped.events
        layer.rhythm = rhythm(from: preset.envelope)
        layer.audio = audio(from: preset.reaction)
        if preset.reaction.motionBeatsPerCycle > 0 {
            layer.rhythm.quantizeBeats = preset.reaction.motionBeatsPerCycle
        }
        layer.variation = preset.palette.randomize ? Composer2Variation.subtle : Composer2Variation.exact
        return layer
    }

    static func composition(from preset: CompositionPreset, now: Date) -> Composer2Composition {
        Composer2Composition(
            id: derivedCompositionID(from: preset.id),
            name: preset.name,
            subtitle: "Imported from Composer",
            createdAt: now,
            isBuiltIn: false,
            sourcePresetID: preset.id,
            layers: [layer(from: preset)])
    }

    // MARK: Palette

    static func colorSource(from palette: PaletteConfig) -> Composer2ColorSource {
        var source = Composer2ColorSource()
        switch palette.mode {
        case .solid:
            source.stops = [Composer2PaletteStop(x: palette.color1.x, y: palette.color1.y)]
            source.interpolation = .linear
        case .gradient:
            var stops = [Composer2PaletteStop(x: palette.color1.x, y: palette.color1.y),
                         Composer2PaletteStop(x: palette.color2.x, y: palette.color2.y)]
            if let c3 = palette.color3 { stops.append(Composer2PaletteStop(x: c3.x, y: c3.y)) }
            source.stops = stops
            source.interpolation = .linear
        case .spectrum:
            let sat = Composer2Math.clamp01(palette.saturation / 100)
            source.stops = (0..<8).map { i in
                let hue = Composer2Math.frac(Double(i) / 8 + palette.hueShift / 360)
                let xy = HueColorUtils.xyFrom(hue: hue, saturation: sat, brightness: 1)
                return Composer2PaletteStop(x: xy.x, y: xy.y)
            }
            source.interpolation = .hueArc
        case .temperature:
            let t = Composer2Math.clamp01(Double(palette.temperature - 153) / Double(500 - 153))
            let xy = Composer2XY(x: Composer2Math.lerp(Composer2XY.coolWhite.x, Composer2XY.warmWhite.x, t),
                                 y: Composer2Math.lerp(Composer2XY.coolWhite.y, Composer2XY.warmWhite.y, t))
            source.stops = [Composer2PaletteStop(xy)]
            source.interpolation = .linear
        }
        if palette.randomize {
            source.distribution = .randomPick
            source.drift = 0.5
        }
        return source
    }

    // MARK: Motion

    static func motion(from legacy: MotionConfig) -> (motion: Composer2Motion, events: Composer2EventSpec?) {
        var m = Composer2Motion()
        m.periodSeconds = legacy.periodSeconds
        m.reverse = !legacy.forward
        m.mirror = legacy.mirror
        m.spread = Composer2Math.clamp01(legacy.offset / 100)
        if legacy.motionAngle < 0 {
            m.axisKind = .principal
        } else {
            m.axisKind = .angle
            m.angleDegrees = legacy.motionAngle
        }
        var events: Composer2EventSpec? = nil
        switch legacy.pattern {
        case .static:
            m.kind = .static
        case .cascade:
            m.kind = .flow
        case .wave:
            m.kind = .wave
        case .scatter:
            m.kind = .scatter
            m.travelWidth = 0.6 + Composer2Math.clamp01(legacy.spread / 100) * 0.4
        case .bounce:
            m.kind = .bounce
        case .chase:
            m.kind = .chase
            m.steps = 1 + Int((Composer2Math.clamp01(legacy.offset / 100) * 3).rounded())
            m.smoothness = 0
            m.travelWidth = 0.05 + Composer2Math.clamp01(legacy.spread / 100) * 0.6
        case .comet:
            m.kind = .chase
            m.smoothness = 1
            m.travelWidth = 0.05 + Composer2Math.clamp01(legacy.spread / 100) * 0.6
        case .pulseCenter:
            m.kind = .wave
            m.axisKind = .radial
        case .spiral:
            m.kind = .flow
            m.axisKind = .angular
        case .twinkle:
            m.kind = .static
            events = Composer2EventSpec(timing: .fixed, interval: Swift.max(0.34, legacy.periodSeconds / 8),
                                        probability: 0.25 + Composer2Math.clamp01(legacy.offset / 100) * 0.45,
                                        burstMin: 1, burstMax: 1, durationMin: 0.06, durationMax: 0.06,
                                        decaySeconds: 0.15, intensityMin: 0.6, intensityMax: 1,
                                        targeting: .randomCount, targetCount: 1, modulates: [.brightness])
        }
        return (m, events)
    }

    // MARK: Rhythm

    static func rhythm(from envelope: EnvelopeConfig) -> Composer2Rhythm {
        var r = Composer2Rhythm()
        switch envelope.shape {
        case .steady: r.shape = .steady
        case .breathe: r.shape = .breathe
        case .heartbeat: r.shape = .heartbeat
        case .pulse: r.shape = .pulse
        case .flicker: r.shape = .flicker
        case .swell: r.shape = .swell
        }
        r.periodSeconds = 60 / Swift.max(1, envelope.bpm)
        r.attack = Composer2Math.clamp01(envelope.attack / 100)
        r.decay = Composer2Math.clamp01(envelope.decay / 100)
        r.depth = Composer2Math.clamp01(envelope.depth / 100)
        r.duty = Composer2Math.clamp01(envelope.dutyCycle / 100)
        r.minBrightness = Composer2Math.clamp01(envelope.minBrightness / 100)
        r.maxBrightness = Composer2Math.clamp01(envelope.maxBrightness / 100)
        return r
    }

    // MARK: Audio

    static func audio(from reaction: ReactionConfig) -> Composer2AudioModulation {
        var a = Composer2AudioModulation()
        switch reaction.source {
        case .none: a.source = .off
        case .micAmplitude: a.source = .amplitude
        case .micBass: a.source = .bass
        case .micMid: a.source = .mid
        case .micTreble: a.source = .treble
        case .tapTempo, .beat: a.source = .beat
        case .onset: a.source = .onset
        }
        var targets: Set<Composer2AudioModulation.Target> = []
        for t in reaction.targets {
            switch t {
            case .brightness: targets.insert(.brightness)
            case .color: targets.insert(.palettePosition)
            case .speed: targets.insert(.motionSpeed)
            }
        }
        a.targets = targets.isEmpty ? [.brightness] : targets
        a.sensitivity = Composer2Math.clamp01(reaction.sensitivity / 100)
        a.smoothing = Composer2Math.clamp01(reaction.smoothing / 100)
        a.intensity = Composer2Math.clamp01(reaction.intensity / 100)
        a.threshold = Composer2Math.clamp01(reaction.threshold / 100)
        a.quantizeBeats = reaction.quantizeBeats
        a.paletteStep = reaction.colorStepPerTrigger
        a.punchDecay = Composer2Math.clamp01(reaction.punchDecay / 100)
        return a
    }

    // MARK: Identity

    /// A stable id derived from the legacy preset's bytes (bit-flipped in the
    /// first byte so it never equals the source id).
    static func derivedCompositionID(from source: UUID) -> UUID {
        transform(source, mask: 0xC2)
    }

    static func derivedLayerID(from source: UUID) -> UUID {
        transform(source, mask: 0x1A)
    }

    private static func transform(_ source: UUID, mask: UInt8) -> UUID {
        var u = source.uuid
        u.0 ^= mask
        u.15 ^= mask
        return UUID(uuid: u)
    }
}
