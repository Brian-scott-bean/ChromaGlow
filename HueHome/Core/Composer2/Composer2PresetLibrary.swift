// Composer2PresetLibrary.swift
// ChromaGlow — Composer 2 lab (experimental).
//
// The five demonstration compositions. Every one is a plain value of the
// universal model — palette, motion, rhythm, space, audio, variation and
// events combined in different ways. Nothing here is an engine.
//
// Built-in ids follow a hand-assigned scheme (`0000000C-0002-0002-0002-…`)
// that can never collide with the legacy `…-0001-0001-0001-…` catalog.

import Foundation

enum Composer2PresetLibrary {

    // MARK: Colours (all inside gamut C — pinned by Composer2LabPresetTests)

    private enum Swatch {
        static let red = Composer2XY(x: 0.6400, y: 0.3200)
        static let deepRed = Composer2XY(x: 0.6200, y: 0.3100)
        static let orange = Composer2XY(x: 0.5600, y: 0.4000)
        static let amber = Composer2XY(x: 0.5300, y: 0.4200)
        static let candle = Composer2XY(x: 0.5000, y: 0.4100)
        static let warmWhite = Composer2XY(x: 0.4578, y: 0.4101)
        static let white = Composer2XY(x: 0.3127, y: 0.3290)
        static let blueWhite = Composer2XY(x: 0.2700, y: 0.2800)
        static let green = Composer2XY(x: 0.2100, y: 0.6200)
        static let auroraGreen = Composer2XY(x: 0.2400, y: 0.5200)
        static let eerieGreen = Composer2XY(x: 0.2800, y: 0.5200)
        static let paleGreen = Composer2XY(x: 0.3000, y: 0.4500)
        static let teal = Composer2XY(x: 0.2000, y: 0.3500)
        static let cyan = Composer2XY(x: 0.1900, y: 0.2800)
        static let blue = Composer2XY(x: 0.1700, y: 0.1000)
        static let navy = Composer2XY(x: 0.1650, y: 0.0900)
        static let slate = Composer2XY(x: 0.2100, y: 0.2000)
        static let violet = Composer2XY(x: 0.2200, y: 0.1200)
        static let purple = Composer2XY(x: 0.2600, y: 0.1300)
        static let magenta = Composer2XY(x: 0.3800, y: 0.1700)
        static let pink = Composer2XY(x: 0.4300, y: 0.2400)
    }

    private static func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "0000000C-0002-0002-0002-%012d", n))!
    }

    private static func layerID(_ preset: Int, _ layer: Int) -> UUID {
        UUID(uuidString: String(format: "0000000C-0003-%04d-%04d-000000000000", preset, layer))!
    }

    /// Built-ins carry a fixed timestamp so they compare equal across launches.
    static let epoch = Date(timeIntervalSince1970: 1_788_000_000)

    // MARK: Aurora Drift

    static let auroraDrift: Composer2Composition = {
        var aurora = Composer2Layer(
            id: layerID(1, 1), name: "Aurora Flow",
            color: Composer2ColorSource(stops: [Swatch.teal, Swatch.auroraGreen, Swatch.violet, Swatch.magenta]
                                            .map { Composer2PaletteStop($0) },
                                        interpolation: .hueArc, saturation: 1.05),
            motion: Composer2Motion(kind: .organic, periodSeconds: 40, axisKind: .principal,
                                    spread: 0.9, smoothness: 1, travelWidth: 0.85, scale: 0.8),
            rhythm: Composer2Rhythm(shape: .breathe, periodSeconds: 14, attack: 0.5, decay: 0.5,
                                    depth: 0.25, minBrightness: 0.35, maxBrightness: 1),
            variation: Composer2Variation.organic)
        aurora.variation.perLightPhase = 0.6
        aurora.variation.evolveRate = 0.05
        return Composer2Composition(
            id: id(1), name: "Aurora Drift", subtitle: "Flowing color. Endless horizons.",
            createdAt: epoch, isBuiltIn: true, layers: [aurora])
    }()

    // MARK: Lava Lamp

    static let lavaLamp: Composer2Composition = {
        var base = Composer2Layer(
            id: layerID(2, 1), name: "Lava Base",
            color: Composer2ColorSource(stops: [Swatch.deepRed, Swatch.orange, Swatch.magenta]
                                            .map { Composer2PaletteStop($0) },
                                        interpolation: .hueArc),
            motion: Composer2Motion(kind: .organic, periodSeconds: 25, axisKind: .principal,
                                    spread: 1, smoothness: 1, travelWidth: 0.7, scale: 0.6),
            rhythm: Composer2Rhythm(shape: .swell, periodSeconds: 9, attack: 0.6, decay: 0.4,
                                    depth: 0.35, minBrightness: 0.3, maxBrightness: 1),
            variation: Composer2Variation.evolving)
        base.variation.speedVariation = 0.5
        base.variation.perLightPhase = 1
        let blobs = Composer2Layer(
            id: layerID(2, 2), name: "Blobs", opacity: 0.4, blend: .addLighten,
            color: Composer2ColorSource.solid(Swatch.amber),
            motion: Composer2Motion(kind: .organic, periodSeconds: 17, axisKind: .angle, angleDegrees: 55,
                                    spread: 1, smoothness: 1, travelWidth: 0.35, scale: 1.4),
            rhythm: Composer2Rhythm(shape: .steady, maxBrightness: 0.9),
            variation: Composer2Variation.organic)
        return Composer2Composition(
            id: id(2), name: "Lava Lamp", subtitle: "Slow blobs. Never the same twice.",
            createdAt: epoch, isBuiltIn: true, layers: [base, blobs])
    }()

    // MARK: Christmas Chase

    static let christmasChase: Composer2Composition = {
        let chase = Composer2Layer(
            id: layerID(3, 1), name: "Chase",
            color: Composer2ColorSource(stops: [Swatch.red, Swatch.green, Swatch.white]
                                            .map { Composer2PaletteStop($0) },
                                        interpolation: .stepped),
            motion: Composer2Motion(kind: .chase, periodSeconds: 3, axisKind: .principal,
                                    spread: 1, smoothness: 0, travelWidth: 1, steps: 3, edge: .wrap),
            rhythm: Composer2Rhythm(shape: .steady, maxBrightness: 1),
            variation: Composer2Variation.exact)
        let sparkle = Composer2Layer(
            id: layerID(3, 2), name: "Sparkle", opacity: 0.6, blend: .addLighten,
            color: Composer2ColorSource.solid(Swatch.white),
            motion: Composer2Motion(kind: .static),
            rhythm: Composer2Rhythm(shape: .steady, maxBrightness: 0),
            variation: Composer2Variation.subtle,
            events: Composer2EventSpec(timing: .fixed, interval: 0.5, probability: 0.7,
                                       burstMin: 1, burstMax: 1, durationMin: 0.08, durationMax: 0.08,
                                       decaySeconds: 0.15, intensityMin: 0.8, intensityMax: 1,
                                       targeting: .randomCount, targetCount: 1, modulates: [.brightness]))
        return Composer2Composition(
            id: id(3), name: "Christmas Chase", subtitle: "Red, green and white on the move.",
            createdAt: epoch, isBuiltIn: true, layers: [chase, sparkle])
    }()

    // MARK: Haunted House

    static let hauntedHouse: Composer2Composition = {
        let base = Composer2Layer(
            id: layerID(4, 1), name: "Dim Base",
            color: Composer2ColorSource(stops: [Swatch.purple, Swatch.eerieGreen].map { Composer2PaletteStop($0) },
                                        interpolation: .hueArc, saturation: 0.9),
            motion: Composer2Motion(kind: .organic, periodSeconds: 60, spread: 0.8, smoothness: 1, scale: 0.5),
            rhythm: Composer2Rhythm(shape: .steady, maxBrightness: 0.18),
            variation: Composer2Variation.subtle)
        let candles = Composer2Layer(
            id: layerID(4, 2), name: "Candle Flicker", opacity: 0.5, blend: .addLighten,
            mask: Composer2LayerMask.randomSubset(fraction: 0.5),
            color: Composer2ColorSource.solid(Swatch.candle),
            motion: Composer2Motion(kind: .static),
            rhythm: Composer2Rhythm(shape: .flicker, periodSeconds: 2, depth: 0.7,
                                    minBrightness: 0.1, maxBrightness: 0.7, flickerRate: 1.6),
            variation: Composer2Variation.organic)
        let pulse = Composer2Layer(
            id: layerID(4, 3), name: "Slow Pulse", opacity: 0.8, blend: .maxBrightness,
            color: Composer2ColorSource.solid(Swatch.violet),
            motion: Composer2Motion(kind: .wave, periodSeconds: 22, axisKind: .principal, spread: 0.5,
                                    smoothness: 1, travelWidth: 1),
            rhythm: Composer2Rhythm(shape: .breathe, periodSeconds: 11, attack: 0.5, decay: 0.5,
                                    depth: 0.8, minBrightness: 0.05, maxBrightness: 0.55),
            variation: Composer2Variation.organic)
        let flashes = Composer2Layer(
            id: layerID(4, 4), name: "Eerie Flashes", blend: .addLighten,
            color: Composer2ColorSource.solid(Swatch.paleGreen),
            motion: Composer2Motion(kind: .static),
            rhythm: Composer2Rhythm(shape: .steady, maxBrightness: 0),
            variation: Composer2Variation.organic,
            events: Composer2EventSpec(timing: .random, minDelay: 20, maxDelay: 60, probability: 0.6,
                                       burstMin: 1, burstMax: 2, spacingMin: 0.4, spacingMax: 0.8,
                                       durationMin: 0.05, durationMax: 0.12, decaySeconds: 0.6,
                                       intensityMin: 0.5, intensityMax: 0.9,
                                       targeting: .spatialBiased, spatialBias: 0.7,
                                       modulates: [.brightness, .color], color: Swatch.paleGreen))
        return Composer2Composition(
            id: id(4), name: "Haunted House", subtitle: "Candles, cold pulses, and something in the corner.",
            createdAt: epoch, isBuiltIn: true, layers: [base, candles, pulse, flashes])
    }()

    // MARK: Thunderstorm

    static let thunderstorm: Composer2Composition = {
        let sky = Composer2Layer(
            id: layerID(5, 1), name: "Storm Sky",
            color: Composer2ColorSource(stops: [Swatch.navy, Swatch.slate, Swatch.blue].map { Composer2PaletteStop($0) },
                                        interpolation: .hueArc),
            motion: Composer2Motion(kind: .organic, periodSeconds: 45, spread: 0.7, smoothness: 1,
                                    travelWidth: 0.8, scale: 0.7),
            rhythm: Composer2Rhythm(shape: .breathe, periodSeconds: 20, depth: 0.6,
                                    minBrightness: 0.06, maxBrightness: 0.16),
            variation: Composer2Variation.subtle)
        let lightning = Composer2Layer(
            id: layerID(5, 2), name: "Lightning", blend: .addLighten,
            color: Composer2ColorSource.solid(Swatch.blueWhite),
            motion: Composer2Motion(kind: .static),
            rhythm: Composer2Rhythm(shape: .steady, maxBrightness: 0),
            variation: Composer2Variation.organic,
            events: Composer2EventSpec(timing: .random, minDelay: 6, maxDelay: 18, probability: 0.8,
                                       burstMin: 1, burstMax: 3,
                                       spacingMin: BeatMath.FlashSafety.minOnsetLedgerPeriod, spacingMax: 0.55,
                                       durationMin: 0.06, durationMax: 0.14, decaySeconds: 0.35,
                                       intensityMin: 0.6, intensityMax: 1,
                                       targeting: .spatialBiased, spatialBias: 0.5,
                                       majorProbability: 0.15,
                                       modulates: [.brightness, .color], color: Swatch.blueWhite))
        return Composer2Composition(
            id: id(5), name: "Thunderstorm", subtitle: "Dark skies. Lightning you can tune.",
            createdAt: epoch, isBuiltIn: true, layers: [sky, lightning])
    }()

    static let all: [Composer2Composition] = [auroraDrift, lavaLamp, christmasChase, hauntedHouse, thunderstorm]

    static func composition(id: UUID) -> Composer2Composition? {
        all.first { $0.id == id }
    }

    static func isBuiltIn(id: UUID) -> Bool {
        all.contains { $0.id == id }
    }

    /// Icon for the mood chips (SF Symbol).
    static func symbol(for id: UUID) -> String {
        switch id {
        case auroraDrift.id: return "wind"
        case lavaLamp.id: return "drop.fill"
        case christmasChase.id: return "snowflake"
        case hauntedHouse.id: return "moon.haze.fill"
        case thunderstorm.id: return "cloud.bolt.fill"
        default: return "sparkles"
        }
    }
}
