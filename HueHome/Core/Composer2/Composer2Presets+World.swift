// Composer2Presets+World.swift
// ChromaGlow — Composer 2 lab (experimental).
//
// Weather, nature, fire, party and calm looks — plain values of the
// universal model, held to the same house rules as the seasonal looks
// (see Composer2Presets+Seasons).

import Foundation

// MARK: - Weather

extension Composer2PresetLibrary {
    /// The shared storm sky.
    static func stormSky(_ preset: Int, _ layer: Int, colors: [Composer2XY] = [Swatch.navy, Swatch.slate, Swatch.blue],
                         low: Double = 0.06, high: Double = 0.16) -> Composer2Layer {
        Composer2Layer(
            id: layerID(preset, layer), name: "Storm Sky",
            color: palette(colors),
            motion: Composer2Motion(kind: .organic, periodSeconds: 45, spread: 0.7, smoothness: 1, travelWidth: 0.8, scale: 0.7),
            rhythm: Composer2Rhythm(shape: .breathe, periodSeconds: 20, depth: 0.6, minBrightness: low, maxBrightness: high),
            variation: .subtle)
    }

    static func rainLayer(_ preset: Int, _ layer: Int, rate: Double = 0.9, high: Double = 0.11) -> Composer2Layer {
        Composer2Layer(
            id: layerID(preset, layer), name: "Rain on the Glass", opacity: 0.55, blend: .maxBrightness,
            color: palette([Swatch.slate, Swatch.ice]),
            motion: Composer2Motion(kind: .scatter, periodSeconds: 6, spread: 1, travelWidth: 0.4),
            rhythm: Composer2Rhythm(shape: .flicker, periodSeconds: 2, depth: 0.6, minBrightness: 0.03,
                                    maxBrightness: high, flickerRate: rate),
            variation: .organic)
    }

    static func lightning(distance: Double, every delay: ClosedRange<Double>, strokes: ClosedRange<Int> = 1...3,
                          major: Double = 0.1, roll: Double = 0.35, probability: Double = 0.85,
                          cycle: Double = 0, cycleDepth: Double = 0,
                          bolt: Composer2XY = Swatch.blueWhite, sky: Composer2XY = Swatch.skyGlow) -> Composer2EventSpec {
        Composer2EventSpec(timing: .random, minDelay: delay.lowerBound, maxDelay: delay.upperBound,
                           probability: probability, burstMin: strokes.lowerBound, burstMax: strokes.upperBound,
                           spacingMin: 0.36, spacingMax: 0.6, durationMin: 0.03, durationMax: 0.07,
                           decaySeconds: 0.45, intensityMin: 0.75, intensityMax: 1,
                           targeting: .spatialBiased, spatialBias: 0.55, majorProbability: major,
                           modulates: [.brightness, .color], color: bolt,
                           shape: .lightning, distance: distance, propagation: roll, colors: [sky],
                           activityPeriod: cycle, activityDepth: cycleDepth)
    }

    static let supercell: Composer2Composition = {
        let sky = stormSky(27, 1, colors: [Swatch.stormGreen, Swatch.slate, Swatch.navy], low: 0.06, high: 0.2)
        let rain = rainLayer(27, 2, rate: 1.4, high: 0.14)
        let strikes = eventLayer(27, 3, "Strikes",
                                 events: lightning(distance: 0.15, every: 2...7, strokes: 2...4, major: 0.25))
        return look(27, "Supercell", "A green sky, a downpour, strikes right overhead.", [sky, rain, strikes])
    }()

    static let heatLightning: Composer2Composition = {
        let sky = stormSky(28, 1, colors: [Swatch.deepPurple, Swatch.dusk, Swatch.navy], low: 0.06, high: 0.14)
        let flashes = eventLayer(28, 2, "Distant Flashes",
                                 events: lightning(distance: 0.9, every: 3...9, strokes: 1...2, major: 0, roll: 0.9,
                                                   probability: 0.9, bolt: Composer2XY(x: 0.3000, y: 0.2800),
                                                   sky: Swatch.dusk))
        return look(28, "Heat Lightning", "A warm night. Silent flashes on the horizon.", [sky, flashes])
    }()

    static let passingStorm: Composer2Composition = {
        let sky = stormSky(29, 1)
        let rain = rainLayer(29, 2)
        let storm = eventLayer(29, 3, "The Storm",
                               events: lightning(distance: 0.35, every: 3...10, strokes: 1...3, major: 0.1,
                                                 probability: 0.95, cycle: 240, cycleDepth: 0.85))
        return look(29, "Passing Storm", "Rolls in, breaks overhead, and moves on — every four minutes.", [sky, rain, storm])
    }()

    static let rainyNight: Composer2Composition = {
        let rain = Composer2Layer(
            id: layerID(30, 1), name: "Rain",
            color: palette([Swatch.navy, Swatch.slate, Swatch.ice]),
            motion: Composer2Motion(kind: .organic, periodSeconds: 35, spread: 0.8, smoothness: 1, travelWidth: 0.8, scale: 0.9),
            rhythm: Composer2Rhythm(shape: .breathe, periodSeconds: 12, depth: 1, minBrightness: 0.1, maxBrightness: 0.28),
            variation: .organic)
        let drops = eventLayer(30, 2, "Drops",
                               events: twinkles([Swatch.ice, Swatch.coolWhite], every: 0.15...0.5,
                                                lasting: 0.25...0.5, intensity: 0.25...0.5))
        return look(30, "Rainy Night", "Streetlight through rain on the window.", [rain, drops])
    }()
}

// MARK: - Nature

extension Composer2PresetLibrary {
    static let oceanWaves: Composer2Composition = {
        let swell = Composer2Layer(
            id: layerID(31, 1), name: "Swell",
            color: palette([Swatch.navy, Swatch.teal, Swatch.cyan, Swatch.seafoam]),
            motion: Composer2Motion(kind: .wave, periodSeconds: 9, spread: 1, smoothness: 1, travelWidth: 1),
            rhythm: Composer2Rhythm(shape: .swell, periodSeconds: 9, attack: 0.6, depth: 1, minBrightness: 0.35, maxBrightness: 0.85),
            variation: .organic)
        let foam = Composer2Layer(
            id: layerID(31, 2), name: "Foam", opacity: 0.7, blend: .addLighten,
            mask: .randomSubset(fraction: 0.5),
            color: .solid(Swatch.white),
            motion: Composer2Motion(kind: .static),
            rhythm: Composer2Rhythm(shape: .twinkle, periodSeconds: 4, depth: 1, duty: 0.4, minBrightness: 0, maxBrightness: 0.35),
            variation: .organic)
        return look(31, "Ocean Waves", "Swells rolling through, foam catching light.", [swell, foam])
    }()

    static let fireflies: Composer2Composition = {
        let meadow = Composer2Layer(
            id: layerID(32, 1), name: "Meadow at Night",
            color: palette([Swatch.navy, Swatch.stormGreen]),
            motion: Composer2Motion(kind: .organic, periodSeconds: 45, spread: 0.8, smoothness: 1, scale: 0.7),
            rhythm: Composer2Rhythm(shape: .steady, maxBrightness: 0.07),
            variation: .subtle)
        let flies = eventLayer(32, 2, "Fireflies",
                               events: Composer2EventSpec(timing: .random, minDelay: 0.3, maxDelay: 1.2, probability: 0.95,
                                                          burstMin: 1, burstMax: 2, spacingMin: 0.5, spacingMax: 1,
                                                          durationMin: 0.6, durationMax: 1.3,
                                                          intensityMin: 0.6, intensityMax: 1,
                                                          targeting: .randomCount, targetCount: 1,
                                                          modulates: [.brightness, .color], color: Swatch.firefly,
                                                          shape: .twinkle, colors: [Swatch.firefly, Swatch.yellow]))
        return look(32, "Fireflies", "A summer meadow after dark.", [meadow, flies])
    }()

    static let starryNight: Composer2Composition = {
        let sky = Composer2Layer(
            id: layerID(33, 1), name: "Night Sky",
            color: palette([Swatch.navy, Swatch.royal, Swatch.deepPurple]),
            motion: Composer2Motion(kind: .organic, periodSeconds: 80, spread: 0.8, smoothness: 1, scale: 0.5),
            rhythm: Composer2Rhythm(shape: .steady, maxBrightness: 0.12),
            variation: .subtle)
        let stars = Composer2Layer(
            id: layerID(33, 2), name: "Stars", blend: .maxBrightness,
            color: .solid(Swatch.coolWhite),
            motion: Composer2Motion(kind: .static),
            rhythm: Composer2Rhythm(shape: .twinkle, periodSeconds: 3.5, depth: 1, duty: 0.5, minBrightness: 0.02, maxBrightness: 0.4),
            variation: .organic)
        // A glow that sweeps from where it lands across the room: a meteor.
        let meteor = eventLayer(33, 3, "Shooting Star",
                                events: Composer2EventSpec(timing: .random, minDelay: 12, maxDelay: 30, probability: 0.85,
                                                           burstMin: 1, burstMax: 1, durationMin: 0.25, durationMax: 0.4,
                                                           decaySeconds: 0.35, intensityMin: 0.5, intensityMax: 0.8,
                                                           targeting: .all,
                                                           modulates: [.brightness, .color], color: Swatch.coolWhite,
                                                           shape: .glow, propagation: 1.0))
        return look(33, "Starry Night", "Deep blue, twinkling stars, the odd shooting star.", [sky, stars, meteor])
    }()

    static let underwater: Composer2Composition = {
        let water = Composer2Layer(
            id: layerID(34, 1), name: "Deep Water",
            color: palette([Swatch.royal, Swatch.teal, Swatch.cyan, Swatch.seafoam]),
            motion: Composer2Motion(kind: .organic, periodSeconds: 14, spread: 1, smoothness: 1, travelWidth: 0.6, scale: 2.4),
            rhythm: Composer2Rhythm(shape: .steady, maxBrightness: 0.75),
            variation: .evolving)
        let caustics = Composer2Layer(
            id: layerID(34, 2), name: "Caustics", opacity: 0.6, blend: .maxBrightness,
            color: .solid(Swatch.ice),
            motion: Composer2Motion(kind: .scatter, periodSeconds: 3, spread: 1, travelWidth: 0.3),
            rhythm: Composer2Rhythm(shape: .flicker, periodSeconds: 2, depth: 1, minBrightness: 0.1, maxBrightness: 0.5, flickerRate: 1.3),
            variation: .organic)
        return look(34, "Underwater", "Sunlight rippling through deep water.", [water, caustics])
    }()

    static let enchantedForest: Composer2Composition = {
        let forest = Composer2Layer(
            id: layerID(35, 1), name: "Canopy",
            color: palette([Swatch.emerald, Swatch.green, Swatch.seafoam, Swatch.lime]),
            motion: Composer2Motion(kind: .organic, periodSeconds: 40, spread: 1, smoothness: 1, travelWidth: 0.8, scale: 1.1),
            rhythm: Composer2Rhythm(shape: .breathe, periodSeconds: 16, depth: 1, minBrightness: 0.3, maxBrightness: 0.6),
            variation: .organic)
        let sprites = eventLayer(35, 2, "Sprites",
                                 events: twinkles([Swatch.firefly, Swatch.mint], every: 0.8...2.2, lasting: 0.7...1.4))
        return look(35, "Enchanted Forest", "Green light through leaves, and something sparkling.", [forest, sprites])
    }()

    static let goldenHour: Composer2Composition = {
        let light = Composer2Layer(
            id: layerID(36, 1), name: "Golden Hour",
            color: palette([Swatch.sunset, Swatch.amber, Swatch.gold, Swatch.warmWhite]),
            motion: Composer2Motion(kind: .organic, periodSeconds: 70, spread: 0.8, smoothness: 1, scale: 0.6),
            rhythm: Composer2Rhythm(shape: .steady, maxBrightness: 0.9),
            variation: .subtle)
        return look(36, "Golden Hour", "The last warm hour of the day.", [light])
    }()

    static let sunsetGlow: Composer2Composition = {
        let sunset = Composer2Layer(
            id: layerID(37, 1), name: "Sunset",
            color: palette([Swatch.magenta, Swatch.hotPink, Swatch.sunset, Swatch.amber, Swatch.dusk]),
            motion: Composer2Motion(kind: .flow, periodSeconds: 60, spread: 0.7, smoothness: 1, travelWidth: 1),
            rhythm: Composer2Rhythm(shape: .breathe, periodSeconds: 20, depth: 1, minBrightness: 0.5, maxBrightness: 0.9),
            variation: .subtle)
        return look(37, "Sunset Glow", "Magenta, coral and amber, melting together.", [sunset])
    }()
}

// MARK: - Fire & candle

extension Composer2PresetLibrary {
    static let fireplace: Composer2Composition = {
        let flames = Composer2Layer(
            id: layerID(38, 1), name: "Flames",
            color: flame([Swatch.ember, Swatch.sunset, Swatch.amber, Swatch.gold]),
            motion: Composer2Motion(kind: .static),
            rhythm: Composer2Rhythm(shape: .candle, depth: 1, minBrightness: 0.25, maxBrightness: 1, flickerRate: 2.2),
            variation: .organic)
        let embers = eventLayer(38, 2, "Embers",
                                events: twinkles([Swatch.ember, Swatch.blood], every: 0.8...2.5,
                                                 lasting: 0.5...1.2, intensity: 0.3...0.6))
        return look(38, "Fireplace", "Logs burning low, embers glowing.", [flames, embers])
    }()

    static let candlelight: Composer2Composition = {
        let candle = Composer2Layer(
            id: layerID(39, 1), name: "Candle",
            color: flame([Swatch.candle, Swatch.warmWhite]),
            motion: Composer2Motion(kind: .static),
            rhythm: Composer2Rhythm(shape: .candle, depth: 1, minBrightness: 0.5, maxBrightness: 0.85, flickerRate: 1.2),
            variation: .subtle)
        return look(39, "Candlelight", "A room full of candles, breathing gently.", [candle])
    }()

    static let campfire: Composer2Composition = {
        let fire = Composer2Layer(
            id: layerID(40, 1), name: "Campfire",
            color: flame([Swatch.blood, Swatch.ember, Swatch.pumpkin, Swatch.gold]),
            motion: Composer2Motion(kind: .static),
            rhythm: Composer2Rhythm(shape: .candle, depth: 1, minBrightness: 0.2, maxBrightness: 1, flickerRate: 2.2),
            variation: .organic)
        let sparks = eventLayer(40, 2, "Sparks",
                                events: twinkles([Swatch.gold, Swatch.yellow], every: 0.45...1.1,
                                                 lasting: 0.2...0.4, intensity: 0.4...0.8))
        return look(40, "Campfire", "Crackling flames and sparks rising into the dark.", [fire, sparks])
    }()
}

// MARK: - Party

extension Composer2PresetLibrary {
    static let discoFever: Composer2Composition = {
        let floor = Composer2Layer(
            id: layerID(41, 1), name: "Dance Floor",
            color: palette([Swatch.magenta, Swatch.cyan, Swatch.yellow, Swatch.purple], .stepped),
            motion: Composer2Motion(kind: .march, periodSeconds: 2, smoothness: 0.2, steps: 4),
            rhythm: Composer2Rhythm(shape: .steady, maxBrightness: 1),
            variation: .exact)
        let mirrorball = eventLayer(41, 2, "Mirror Ball",
                                    events: twinkles([Swatch.white], every: 0.3...0.8, lasting: 0.15...0.3))
        return look(41, "Disco Fever", "Color squares chasing, a mirror ball glinting.", [floor, mirrorball])
    }()

    static let neonNights: Composer2Composition = {
        let neon = Composer2Layer(
            id: layerID(42, 1), name: "Neon",
            color: palette([Swatch.hotPink, Swatch.cyan, Swatch.violet], saturation: 1.15),
            motion: Composer2Motion(kind: .flow, periodSeconds: 7, spread: 1, smoothness: 1, travelWidth: 1),
            rhythm: Composer2Rhythm(shape: .pulse, periodSeconds: 1, depth: 0.45, duty: 0.6, minBrightness: 0, maxBrightness: 1),
            variation: .subtle)
        return look(42, "Neon Nights", "Hot pink, electric cyan, a pulse underneath.", [neon])
    }()

    static let rainbowWave: Composer2Composition = {
        let rainbow = Composer2Layer(
            id: layerID(43, 1), name: "Rainbow",
            color: palette([Swatch.red, Swatch.pumpkin, Swatch.yellow, Swatch.lime, Swatch.green,
                            Swatch.cyan, Swatch.royal, Swatch.magenta]),
            motion: Composer2Motion(kind: .flow, periodSeconds: 10, spread: 1, smoothness: 1, travelWidth: 1),
            rhythm: Composer2Rhythm(shape: .steady, maxBrightness: 0.9),
            variation: .exact)
        return look(43, "Rainbow Wave", "The whole spectrum, rolling through the room.", [rainbow])
    }()

    static let beatDrop: Composer2Composition = {
        let hits = Composer2Layer(
            id: layerID(44, 1), name: "Hits",
            color: palette([Swatch.magenta, Swatch.cyan, Swatch.gold, Swatch.violet]),
            motion: Composer2Motion(kind: .flow, periodSeconds: 8, spread: 1, smoothness: 1, travelWidth: 1),
            rhythm: Composer2Rhythm(shape: .steady, maxBrightness: 0.55),
            audio: Composer2AudioModulation(source: .onset, intensity: 0.8, targets: [.brightness, .palettePosition],
                                            paletteStep: 0.25, punchDecay: 0.35),
            variation: .subtle)
        let bass = Composer2Layer(
            id: layerID(44, 2), name: "Bass", opacity: 0.7, blend: .maxBrightness,
            mask: .randomSubset(fraction: 0.5),
            color: .solid(Swatch.violet),
            motion: Composer2Motion(kind: .static),
            rhythm: Composer2Rhythm(shape: .steady, maxBrightness: 0.25),
            audio: Composer2AudioModulation(source: .bass, sensitivity: 0.75, intensity: 0.9, targets: [.brightness]),
            variation: .subtle)
        return look(44, "Beat Drop", "Listens to the room — every hit changes color.", [hits, bass])
    }()

    static let clubPulse: Composer2Composition = {
        let pulse = Composer2Layer(
            id: layerID(45, 1), name: "Pulse",
            color: palette([Swatch.purple, Swatch.hotPink, Swatch.royal]),
            motion: Composer2Motion(kind: .wave, periodSeconds: 6, spread: 1, smoothness: 1, travelWidth: 1),
            rhythm: Composer2Rhythm(shape: .steady, maxBrightness: 0.5),
            audio: Composer2AudioModulation(source: .beat, intensity: 0.7, targets: [.brightness, .palettePosition],
                                            quantizeBeats: 1, paletteStep: 0.25),
            variation: .subtle)
        return look(45, "Club Pulse", "Locks to the beat — tap tempo or let it listen.", [pulse])
    }()
}

// MARK: - Calm

extension Composer2PresetLibrary {
    static let breathingCalm: Composer2Composition = {
        let breath = Composer2Layer(
            id: layerID(46, 1), name: "Breath",
            color: palette([Swatch.teal, Swatch.lavender]),
            motion: Composer2Motion(kind: .flow, periodSeconds: 40, spread: 0.5, smoothness: 1, travelWidth: 1),
            rhythm: Composer2Rhythm(shape: .breathe, periodSeconds: 10, depth: 1, minBrightness: 0.25, maxBrightness: 0.75),
            variation: .exact)
        return look(46, "Breathing Calm", "Six slow breaths a minute. Follow the light.", [breath])
    }()

    static let cloudDrift: Composer2Composition = {
        let clouds = Composer2Layer(
            id: layerID(47, 1), name: "Clouds",
            color: palette([Swatch.pastelBlue, Swatch.white, Swatch.ice]),
            motion: Composer2Motion(kind: .organic, periodSeconds: 60, spread: 0.9, smoothness: 1, travelWidth: 0.9, scale: 0.7),
            rhythm: Composer2Rhythm(shape: .steady, maxBrightness: 0.7),
            variation: .organic)
        return look(47, "Cloud Drift", "Pale sky and slow white clouds.", [clouds])
    }()

    static let cozyEvening: Composer2Composition = {
        let cozy = Composer2Layer(
            id: layerID(48, 1), name: "Cozy",
            color: palette([Swatch.candle, Swatch.warmWhite, Swatch.amber]),
            motion: Composer2Motion(kind: .organic, periodSeconds: 70, spread: 0.8, smoothness: 1, scale: 0.6),
            rhythm: Composer2Rhythm(shape: .breathe, periodSeconds: 20, depth: 1, minBrightness: 0.45, maxBrightness: 0.65),
            variation: .subtle)
        return look(48, "Cozy Evening", "Warm, low, and barely moving.", [cozy])
    }()

    static let deepFocus: Composer2Composition = {
        let focus = Composer2Layer(
            id: layerID(49, 1), name: "Daylight",
            color: palette([Swatch.coolWhite, Swatch.white]),
            motion: Composer2Motion(kind: .organic, periodSeconds: 120, spread: 0.3, smoothness: 1, scale: 0.4),
            rhythm: Composer2Rhythm(shape: .steady, maxBrightness: 0.95),
            variation: .subtle)
        return look(49, "Deep Focus", "Clear, cool daylight with the faintest drift.", [focus])
    }()
}
