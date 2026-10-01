// Composer2BehaviorLibrary.swift
// ChromaGlow — Composer 2 lab (experimental), v2.2.
//
// Ready-made behaviors to stack onto any look: "add lightning", "add a
// string-light chase", "add fireflies". Each is one plain layer of the
// universal model, tuned to the same house rules as the built-in looks —
// in gamut, legal at any room size, and shaped for the flash budget.

import Foundation

enum Composer2BehaviorTemplate: String, CaseIterable, Identifiable {
    // Moments
    case lightning, heatLightning, fireworks, sparkle, fireflies, ghost, shootingStar
    // Motion
    case stringChase, theaterChase, wave, aurora, rainbow, candyStripes
    // Glow
    case candle, fire, embers, breathe, heartbeat, twinkleStars, rain, fog
    // Sound
    case beatPulse, bassGlow, hitsColour

    enum Group: String, CaseIterable, Identifiable {
        case moments, motion, glow, sound
        var id: String { rawValue }
        var title: String {
            switch self {
            case .moments: return "Moments"
            case .motion: return "Motion"
            case .glow: return "Glow"
            case .sound: return "Sound"
            }
        }
        var subtitle: String {
            switch self {
            case .moments: return "Every so often, something happens."
            case .motion: return "Color travelling through the room."
            case .glow: return "Light that breathes, flickers and settles."
            case .sound: return "Light that listens."
            }
        }
    }

    var id: String { rawValue }

    var group: Group {
        switch self {
        case .lightning, .heatLightning, .fireworks, .sparkle, .fireflies, .ghost, .shootingStar: return .moments
        case .stringChase, .theaterChase, .wave, .aurora, .rainbow, .candyStripes: return .motion
        case .candle, .fire, .embers, .breathe, .heartbeat, .twinkleStars, .rain, .fog: return .glow
        case .beatPulse, .bassGlow, .hitsColour: return .sound
        }
    }

    var title: String {
        switch self {
        case .lightning: return "Lightning"
        case .heatLightning: return "Heat lightning"
        case .fireworks: return "Fireworks"
        case .sparkle: return "Sparkle"
        case .fireflies: return "Fireflies"
        case .ghost: return "Ghostly glow"
        case .shootingStar: return "Shooting star"
        case .stringChase: return "String-light chase"
        case .theaterChase: return "Theater chase"
        case .wave: return "Wave"
        case .aurora: return "Aurora flow"
        case .rainbow: return "Rainbow"
        case .candyStripes: return "Stripes"
        case .candle: return "Candle flame"
        case .fire: return "Fire"
        case .embers: return "Embers"
        case .breathe: return "Breathe"
        case .heartbeat: return "Heartbeat"
        case .twinkleStars: return "Twinkling stars"
        case .rain: return "Rain on the glass"
        case .fog: return "Drifting fog"
        case .beatPulse: return "Beat pulse"
        case .bassGlow: return "Bass glow"
        case .hitsColour: return "Color on every hit"
        }
    }

    var subtitle: String {
        switch self {
        case .lightning: return "Real strikes: leader, strokes, afterglow."
        case .heatLightning: return "Silent flashes on the horizon."
        case .fireworks: return "Colored bursts that bloom and crackle."
        case .sparkle: return "Quick glints on single lights."
        case .fireflies: return "Soft yellow-green blinks in the dark."
        case .ghost: return "A slow glow appears… and fades."
        case .shootingStar: return "A streak sweeping across the room."
        case .stringChase: return "Classic multicolor bulbs stepping along."
        case .theaterChase: return "Every third bulb, racing."
        case .wave: return "A swell rolling through the room."
        case .aurora: return "Slow, flowing, never repeating."
        case .rainbow: return "The spectrum rolling past."
        case .candyStripes: return "Two colors in stripes, turning."
        case .candle: return "Sway, flicker, the odd gutter."
        case .fire: return "Bigger, hotter, hungrier flame."
        case .embers: return "Red points glowing up and fading."
        case .breathe: return "In… and out."
        case .heartbeat: return "Two beats, a rest."
        case .twinkleStars: return "Each light twinkles on its own."
        case .rain: return "A fine, dim, restless texture."
        case .fog: return "Low mist moving slowly."
        case .beatPulse: return "Pulses on the beat — tap or listen."
        case .bassGlow: return "Swells with the low end."
        case .hitsColour: return "Steps the color on every hit."
        }
    }

    var symbol: String {
        switch self {
        case .lightning: return "cloud.bolt.fill"
        case .heatLightning: return "cloud.sun.bolt.fill"
        case .fireworks: return "sparkles"
        case .sparkle: return "sparkle"
        case .fireflies: return "sparkle.magnifyingglass"
        case .ghost: return "moon.haze.fill"
        case .shootingStar: return "moon.stars.fill"
        case .stringChase: return "lightbulb.2.fill"
        case .theaterChase: return "lightbulb.led.fill"
        case .wave: return "water.waves"
        case .aurora: return "wind"
        case .rainbow: return "rainbow"
        case .candyStripes: return "line.3.horizontal"
        case .candle: return "flame.fill"
        case .fire: return "fireplace.fill"
        case .embers: return "flame"
        case .breathe: return "lungs.fill"
        case .heartbeat: return "heart.fill"
        case .twinkleStars: return "star.fill"
        case .rain: return "cloud.rain.fill"
        case .fog: return "cloud.fog.fill"
        case .beatPulse: return "metronome.fill"
        case .bassGlow: return "speaker.wave.3.fill"
        case .hitsColour: return "waveform"
        }
    }

    /// A fresh layer of this behavior (the caller assigns a new id).
    func layer() -> Composer2Layer {
        typealias P = Composer2PresetLibrary
        typealias S = Composer2PresetLibrary.Swatch
        var l: Composer2Layer
        switch self {
        case .lightning:
            l = P.eventLayer(0, 0, title, events: P.lightning(distance: 0.35, every: 5...16))
        case .heatLightning:
            l = P.eventLayer(0, 0, title, events: P.lightning(distance: 0.9, every: 3...9, strokes: 1...2, major: 0,
                                                              roll: 0.9, probability: 0.9,
                                                              bolt: Composer2XY(x: 0.3000, y: 0.2800), sky: S.dusk))
        case .fireworks:
            l = P.eventLayer(0, 0, title, events: P.fireworks([S.gold, S.magenta, S.skyBlue, S.emerald, S.red, S.white],
                                                              every: 1...3))
        case .sparkle:
            l = P.eventLayer(0, 0, title, events: P.twinkles([S.white, S.gold], every: 0.4...1.2, lasting: 0.2...0.45))
        case .fireflies:
            l = P.eventLayer(0, 0, title, events: P.twinkles([S.firefly, S.yellow], every: 0.4...1.4, lasting: 0.6...1.3))
        case .ghost:
            l = P.eventLayer(0, 0, title, events: Composer2EventSpec(
                timing: .random, minDelay: 9, maxDelay: 24, probability: 0.8, burstMin: 1, burstMax: 1,
                durationMin: 2.5, durationMax: 4.5, decaySeconds: 1.8, intensityMin: 0.45, intensityMax: 0.75,
                targeting: .randomCount, targetCount: 1, modulates: [.brightness, .color], color: S.ice,
                shape: .glow, colors: [S.ice, S.coolWhite]))
        case .shootingStar:
            l = P.eventLayer(0, 0, title, events: Composer2EventSpec(
                timing: .random, minDelay: 12, maxDelay: 30, probability: 0.85, burstMin: 1, burstMax: 1,
                durationMin: 0.25, durationMax: 0.4, decaySeconds: 0.35, intensityMin: 0.5, intensityMax: 0.8,
                targeting: .all, modulates: [.brightness, .color], color: S.coolWhite, shape: .glow, propagation: 1.0))
        case .stringChase:
            l = Composer2Layer(name: title, color: P.palette([S.red, S.pumpkin, S.green, S.royal, S.magenta], .stepped),
                               motion: Composer2Motion(kind: .march, periodSeconds: 6.5, smoothness: 0.3, steps: 5),
                               rhythm: Composer2Rhythm(shape: .steady, maxBrightness: 0.9))
        case .theaterChase:
            l = Composer2Layer(name: title, blend: .maxBrightness, color: .solid(S.warmWhite),
                               motion: Composer2Motion(kind: .march, periodSeconds: 1.5, smoothness: 0.25,
                                                       travelWidth: 0.34, steps: 3),
                               rhythm: Composer2Rhythm(shape: .steady, maxBrightness: 1))
        case .wave:
            l = Composer2Layer(name: title, color: P.palette([S.navy, S.teal, S.cyan, S.seafoam]),
                               motion: Composer2Motion(kind: .wave, periodSeconds: 9, spread: 1, smoothness: 1, travelWidth: 1),
                               rhythm: Composer2Rhythm(shape: .swell, periodSeconds: 9, attack: 0.6, depth: 1,
                                                       minBrightness: 0.35, maxBrightness: 0.85),
                               variation: .organic)
        case .aurora:
            l = Composer2Layer(name: title, color: P.palette([S.teal, S.auroraGreen, S.violet, S.magenta]),
                               motion: Composer2Motion(kind: .organic, periodSeconds: 40, spread: 0.9, smoothness: 1,
                                                       travelWidth: 0.85, scale: 0.8),
                               rhythm: Composer2Rhythm(shape: .breathe, periodSeconds: 14, depth: 0.25,
                                                       minBrightness: 0.35, maxBrightness: 1),
                               variation: .organic)
        case .rainbow:
            l = Composer2Layer(name: title, color: P.palette([S.red, S.pumpkin, S.yellow, S.lime, S.green, S.cyan, S.royal, S.magenta]),
                               motion: Composer2Motion(kind: .flow, periodSeconds: 10, spread: 1, smoothness: 1, travelWidth: 1),
                               rhythm: Composer2Rhythm(shape: .steady, maxBrightness: 0.9))
        case .candyStripes:
            l = Composer2Layer(name: title, color: P.palette([S.red, S.red, S.white, S.white], .linear),
                               motion: Composer2Motion(kind: .march, periodSeconds: 4, smoothness: 0.6, steps: 4),
                               rhythm: Composer2Rhythm(shape: .steady, maxBrightness: 0.9))
        case .candle:
            l = Composer2Layer(name: title, color: P.flame([S.candle, S.warmWhite]),
                               motion: Composer2Motion(kind: .static),
                               rhythm: Composer2Rhythm(shape: .candle, depth: 1, minBrightness: 0.5, maxBrightness: 0.85,
                                                       flickerRate: 1.2),
                               variation: .subtle)
        case .fire:
            l = Composer2Layer(name: title, color: P.flame([S.ember, S.sunset, S.amber, S.gold]),
                               motion: Composer2Motion(kind: .static),
                               rhythm: Composer2Rhythm(shape: .candle, depth: 1, minBrightness: 0.25, maxBrightness: 1,
                                                       flickerRate: 2.2),
                               variation: .organic)
        case .embers:
            l = P.eventLayer(0, 0, title, events: P.twinkles([S.ember, S.blood], every: 0.8...2.5, lasting: 0.5...1.2,
                                                             intensity: 0.3...0.6))
        case .breathe:
            l = Composer2Layer(name: title, color: P.palette([S.teal, S.lavender]),
                               motion: Composer2Motion(kind: .flow, periodSeconds: 40, spread: 0.5, smoothness: 1, travelWidth: 1),
                               rhythm: Composer2Rhythm(shape: .breathe, periodSeconds: 10, depth: 1,
                                                       minBrightness: 0.25, maxBrightness: 0.75))
        case .heartbeat:
            l = Composer2Layer(name: title, color: P.palette([S.hotPink, S.red]),
                               motion: Composer2Motion(kind: .static),
                               rhythm: Composer2Rhythm(shape: .heartbeat, periodSeconds: 1.7, depth: 1,
                                                       minBrightness: 0.45, maxBrightness: 0.95))
        case .twinkleStars:
            l = Composer2Layer(name: title, blend: .maxBrightness, color: .solid(S.coolWhite),
                               motion: Composer2Motion(kind: .static),
                               rhythm: Composer2Rhythm(shape: .twinkle, periodSeconds: 3.5, depth: 1, duty: 0.5,
                                                       minBrightness: 0.02, maxBrightness: 0.4),
                               variation: .organic)
        case .rain:
            l = P.rainLayer(0, 0)
            l.name = title
        case .fog:
            l = Composer2Layer(name: title, color: P.palette([S.slate, S.stormGreen, S.ice]),
                               motion: Composer2Motion(kind: .organic, periodSeconds: 55, spread: 0.9, smoothness: 1,
                                                       travelWidth: 0.7, scale: 0.6),
                               rhythm: Composer2Rhythm(shape: .breathe, periodSeconds: 16, depth: 1,
                                                       minBrightness: 0.07, maxBrightness: 0.3),
                               variation: .organic)
        case .beatPulse:
            l = Composer2Layer(name: title, color: P.palette([S.purple, S.hotPink, S.royal]),
                               motion: Composer2Motion(kind: .wave, periodSeconds: 6, spread: 1, smoothness: 1, travelWidth: 1),
                               rhythm: Composer2Rhythm(shape: .steady, maxBrightness: 0.5),
                               audio: Composer2AudioModulation(source: .beat, intensity: 0.7,
                                                               targets: [.brightness, .palettePosition],
                                                               quantizeBeats: 1, paletteStep: 0.25))
        case .bassGlow:
            l = Composer2Layer(name: title, blend: .maxBrightness, color: .solid(S.violet),
                               motion: Composer2Motion(kind: .static),
                               rhythm: Composer2Rhythm(shape: .steady, maxBrightness: 0.25),
                               audio: Composer2AudioModulation(source: .bass, sensitivity: 0.75, intensity: 0.9,
                                                               targets: [.brightness]))
        case .hitsColour:
            l = Composer2Layer(name: title, color: P.palette([S.magenta, S.cyan, S.gold, S.violet]),
                               motion: Composer2Motion(kind: .flow, periodSeconds: 8, spread: 1, smoothness: 1, travelWidth: 1),
                               rhythm: Composer2Rhythm(shape: .steady, maxBrightness: 0.55),
                               audio: Composer2AudioModulation(source: .onset, intensity: 0.8,
                                                               targets: [.brightness, .palettePosition],
                                                               paletteStep: 0.25, punchDecay: 0.35))
        }
        l.name = title
        return l
    }

    static func templates(in group: Group) -> [Composer2BehaviorTemplate] {
        allCases.filter { $0.group == group }
    }
}
