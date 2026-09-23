// Composer2Presets+Seasons.swift
// ChromaGlow — Composer 2 lab (experimental).
//
// Halloween, Christmas & winter, and holiday looks. Every one is a plain
// value of the universal model — palette, motion, rhythm, space, variation
// and events in different combinations. Nothing here is an engine.
//
// House rules, pinned by Composer2LabThemeTests: every colour inside gamut C;
// legal frames at 1, 5 and 20 lights; ≤ 3 flashes a second on every light
// and on the room field; almost never leaning on the wire's flash gate.

import Foundation

// MARK: - Authoring helpers (shared by the preset extensions)

extension Composer2PresetLibrary {
    static func palette(_ xys: [Composer2XY], _ interpolation: Composer2ColorSource.Interpolation = .hueArc,
                        distribution: Composer2ColorSource.Distribution = .motion, cycle: Bool = true,
                        saturation: Double = 1) -> Composer2ColorSource {
        Composer2ColorSource(stops: xys.map { Composer2PaletteStop($0) }, interpolation: interpolation,
                             saturation: saturation, distribution: distribution, cycle: cycle)
    }

    static func look(_ n: Int, _ name: String, _ subtitle: String, _ layers: [Composer2Layer]) -> Composer2Composition {
        Composer2Composition(id: id(n), name: name, subtitle: subtitle, createdAt: epoch, isBuiltIn: true, layers: layers)
    }

    /// A layer that is dark on its own and lit only by its events.
    static func eventLayer(_ preset: Int, _ layer: Int, _ name: String, opacity: Double = 1,
                           mask: Composer2LayerMask = .wholeRoom,
                           variation: Composer2Variation = .organic,
                           events: Composer2EventSpec) -> Composer2Layer {
        Composer2Layer(id: layerID(preset, layer), name: name, opacity: opacity, blend: .addLighten, mask: mask,
                       color: .solid(events.color ?? events.colors.first ?? Swatch.white),
                       motion: Composer2Motion(kind: .static),
                       rhythm: Composer2Rhythm(shape: .steady, maxBrightness: 0),
                       variation: variation, events: events)
    }

    /// Soft twinkles on one light at a time (fireflies, glints, snowflakes).
    static func twinkles(_ colors: [Composer2XY], every delay: ClosedRange<Double>,
                         lasting duration: ClosedRange<Double>, intensity: ClosedRange<Double> = 0.5...1,
                         lights: Int = 1, probability: Double = 0.9) -> Composer2EventSpec {
        Composer2EventSpec(timing: .random, minDelay: delay.lowerBound, maxDelay: delay.upperBound,
                           probability: probability, burstMin: 1, burstMax: 1,
                           durationMin: duration.lowerBound, durationMax: duration.upperBound,
                           decaySeconds: 0.3, intensityMin: intensity.lowerBound, intensityMax: intensity.upperBound,
                           targeting: .randomCount, targetCount: lights,
                           modulates: [.brightness, .color], color: colors.first,
                           shape: .twinkle, colors: colors)
    }

    /// Fireworks: a burst in one of `colors`, blooming out from where it lands.
    static func fireworks(_ colors: [Composer2XY], every delay: ClosedRange<Double>,
                          fade: Double = 0.8, bloom: Double = 0.4, focus: Double = 0.55) -> Composer2EventSpec {
        Composer2EventSpec(timing: .random, minDelay: delay.lowerBound, maxDelay: delay.upperBound,
                           probability: 0.9, burstMin: 1, burstMax: 1,
                           durationMin: 0.08, durationMax: 0.16, decaySeconds: fade,
                           intensityMin: 0.8, intensityMax: 1,
                           targeting: .spatialBiased, spatialBias: focus, majorProbability: 0.08,
                           modulates: [.brightness, .color], color: colors.first,
                           shape: .firework, propagation: bloom, colors: colors)
    }

    /// A candle flame palette that burns brighter toward its last colour.
    static func flame(_ xys: [Composer2XY]) -> Composer2ColorSource {
        palette(xys, .hueArc, distribution: .brightness, cycle: false)
    }
}

// MARK: - Halloween

extension Composer2PresetLibrary {
    static let jackOLantern: Composer2Composition = {
        let pumpkin = Composer2Layer(
            id: layerID(6, 1), name: "Pumpkin Flame",
            color: flame([Swatch.ember, Swatch.pumpkin, Swatch.amber, Swatch.gold]),
            motion: Composer2Motion(kind: .static),
            rhythm: Composer2Rhythm(shape: .candle, depth: 1, minBrightness: 0.3, maxBrightness: 0.95, flickerRate: 1.9),
            variation: .subtle)
        let grin = Composer2Layer(
            id: layerID(6, 2), name: "Carved Grin", opacity: 0.8, blend: .maxBrightness,
            mask: .randomSubset(fraction: 0.4),
            color: .solid(Swatch.gold),
            motion: Composer2Motion(kind: .static),
            rhythm: Composer2Rhythm(shape: .breathe, periodSeconds: 7, depth: 1, minBrightness: 0, maxBrightness: 0.55),
            variation: .organic)
        return look(6, "Jack-o'-Lantern", "A carved grin, a flame that never sits still.", [pumpkin, grin])
    }()

    static let witchesBrew: Composer2Composition = {
        let brew = Composer2Layer(
            id: layerID(7, 1), name: "Cauldron",
            color: palette([Swatch.deepPurple, Swatch.toxic, Swatch.emerald, Swatch.purple]),
            motion: Composer2Motion(kind: .organic, periodSeconds: 22, spread: 1, smoothness: 1, travelWidth: 0.8, scale: 1.3),
            rhythm: Composer2Rhythm(shape: .swell, periodSeconds: 8, attack: 0.6, depth: 1, minBrightness: 0.25, maxBrightness: 0.85),
            variation: .evolving)
        let bubbles = eventLayer(7, 2, "Bubbles",
                                 events: twinkles([Swatch.lime, Swatch.toxic], every: 0.6...1.8, lasting: 0.5...1.1,
                                                  intensity: 0.5...0.9))
        return look(7, "Witch's Brew", "Something bubbling, green and violet.", [brew, bubbles])
    }()

    static let graveyardFog: Composer2Composition = {
        let fog = Composer2Layer(
            id: layerID(8, 1), name: "Fog",
            color: palette([Swatch.slate, Swatch.stormGreen, Swatch.ice]),
            motion: Composer2Motion(kind: .organic, periodSeconds: 55, spread: 0.9, smoothness: 1, travelWidth: 0.7, scale: 0.6),
            rhythm: Composer2Rhythm(shape: .breathe, periodSeconds: 16, depth: 1, minBrightness: 0.07, maxBrightness: 0.3),
            variation: .organic)
        let soul = eventLayer(8, 2, "Wandering Soul",
                              events: Composer2EventSpec(timing: .random, minDelay: 9, maxDelay: 24, probability: 0.8,
                                                         burstMin: 1, burstMax: 1, durationMin: 2.5, durationMax: 4.5,
                                                         decaySeconds: 1.8, intensityMin: 0.45, intensityMax: 0.75,
                                                         targeting: .randomCount, targetCount: 1,
                                                         modulates: [.brightness, .color], color: Swatch.ice,
                                                         shape: .glow, colors: [Swatch.ice, Swatch.coolWhite]))
        return look(8, "Graveyard Fog", "Low mist, and a light that isn't a lantern.", [fog, soul])
    }()

    static let poltergeist: Composer2Composition = {
        let lamp = Composer2Layer(
            id: layerID(9, 1), name: "Lamp Light",
            color: .solid(Swatch.candle),
            motion: Composer2Motion(kind: .static),
            rhythm: Composer2Rhythm(shape: .steady, maxBrightness: 0.28),
            variation: .subtle)
        let presence = Composer2Layer(
            id: layerID(9, 2), name: "Presence", opacity: 0.8, blend: .addLighten,
            color: .solid(Swatch.ice),
            motion: Composer2Motion(kind: .chase, periodSeconds: 11, spread: 1, smoothness: 1, travelWidth: 0.18),
            rhythm: Composer2Rhythm(shape: .breathe, periodSeconds: 5.5, depth: 1, minBrightness: 0.1, maxBrightness: 0.6),
            variation: .organic)
        let unrest = eventLayer(9, 3, "Unrest",
                                events: Composer2EventSpec(timing: .random, minDelay: 7, maxDelay: 20, probability: 0.75,
                                                           burstMin: 2, burstMax: 4, spacingMin: 0.4, spacingMax: 0.8,
                                                           durationMin: 0.05, durationMax: 0.12, decaySeconds: 0.25,
                                                           intensityMin: 0.55, intensityMax: 0.9,
                                                           targeting: .randomCount, targetCount: 2,
                                                           modulates: [.brightness, .color], color: Swatch.coolWhite))
        return look(9, "Poltergeist", "Something moves between the lamps.", [lamp, presence, unrest])
    }()

    static let bloodMoon: Composer2Composition = {
        let moon = Composer2Layer(
            id: layerID(10, 1), name: "Blood Moon",
            color: palette([Swatch.blood, Swatch.deepRed, Swatch.ember]),
            motion: Composer2Motion(kind: .organic, periodSeconds: 60, spread: 0.8, smoothness: 1, travelWidth: 0.8, scale: 0.5),
            rhythm: Composer2Rhythm(shape: .breathe, periodSeconds: 18, depth: 1, minBrightness: 0.12, maxBrightness: 0.55),
            variation: .organic)
        let stars = Composer2Layer(
            id: layerID(10, 2), name: "Cold Stars", blend: .maxBrightness,
            mask: .randomSubset(fraction: 0.35),
            color: .solid(Swatch.coolWhite),
            motion: Composer2Motion(kind: .static),
            rhythm: Composer2Rhythm(shape: .twinkle, periodSeconds: 3.2, depth: 1, duty: 0.45,
                                    minBrightness: 0, maxBrightness: 0.3),
            variation: .organic)
        return look(10, "Blood Moon", "A red sky. Cold stars.", [moon, stars])
    }()

    static let madScientist: Composer2Composition = {
        let lab = Composer2Layer(
            id: layerID(11, 1), name: "Lab Glow",
            color: palette([Swatch.toxic, Swatch.teal, Swatch.emerald]),
            motion: Composer2Motion(kind: .wave, periodSeconds: 7, spread: 0.8, smoothness: 1, travelWidth: 1),
            rhythm: Composer2Rhythm(shape: .steady, maxBrightness: 0.55),
            variation: .subtle)
        let arcs = eventLayer(11, 2, "Tesla Arcs",
                              events: Composer2EventSpec(timing: .random, minDelay: 3, maxDelay: 9, probability: 0.85,
                                                         burstMin: 1, burstMax: 2, spacingMin: 0.36, spacingMax: 0.5,
                                                         durationMin: 0.02, durationMax: 0.05, decaySeconds: 0.25,
                                                         intensityMin: 0.6, intensityMax: 0.9,
                                                         targeting: .spatialBiased, spatialBias: 0.8,
                                                         modulates: [.brightness, .color], color: Swatch.teslaViolet,
                                                         shape: .lightning, distance: 0.2, colors: [Swatch.purple]))
        return look(11, "Mad Scientist", "Bubbling beakers and arcs of violet current.", [lab, arcs])
    }()

    static let trickOrTreat: Composer2Composition = {
        let march = Composer2Layer(
            id: layerID(12, 1), name: "Candy March",
            color: palette([Swatch.pumpkin, Swatch.purple, Swatch.toxic], .stepped),
            motion: Composer2Motion(kind: .march, periodSeconds: 3.3, smoothness: 0.35, steps: 3),
            rhythm: Composer2Rhythm(shape: .steady, maxBrightness: 0.85),
            variation: .exact)
        let sweets = eventLayer(12, 2, "Sweets",
                                events: twinkles([Swatch.gold, Swatch.hotPink], every: 0.8...2, lasting: 0.4...0.8))
        return look(12, "Trick or Treat", "Orange, purple and green, marching door to door.", [march, sweets])
    }()
}

// MARK: - Christmas & winter

extension Composer2PresetLibrary {
    static let classicC9: Composer2Composition = {
        let bulbs = Composer2Layer(
            id: layerID(13, 1), name: "C9 Bulbs",
            color: palette([Swatch.red, Swatch.pumpkin, Swatch.green, Swatch.royal, Swatch.magenta], .stepped),
            motion: Composer2Motion(kind: .march, periodSeconds: 6.5, smoothness: 0.3, steps: 5),
            rhythm: Composer2Rhythm(shape: .steady, maxBrightness: 0.9),
            variation: .exact)
        let glint = eventLayer(13, 2, "Glint",
                               events: twinkles([Swatch.warmWhite], every: 0.7...2.0, lasting: 0.3...0.6, intensity: 0.4...0.7))
        return look(13, "Classic C9 String", "Red, orange, green, blue, pink — stepping down the line.", [bulbs, glint])
    }()

    static let theaterChase: Composer2Composition = {
        let glow = Composer2Layer(
            id: layerID(14, 1), name: "Warm Glow",
            color: .solid(Swatch.warmWhite),
            motion: Composer2Motion(kind: .static),
            rhythm: Composer2Rhythm(shape: .steady, maxBrightness: 0.18),
            variation: .exact)
        let chase = Composer2Layer(
            id: layerID(14, 2), name: "Marquee", blend: .maxBrightness,
            color: .solid(Swatch.warmWhite),
            motion: Composer2Motion(kind: .march, periodSeconds: 1.5, smoothness: 0.25, travelWidth: 0.34, steps: 3),
            rhythm: Composer2Rhythm(shape: .steady, maxBrightness: 1),
            variation: .exact)
        return look(14, "Theater Chase", "Every third bulb, racing like a marquee.", [glow, chase])
    }()

    static let candyCane: Composer2Composition = {
        let stripes = Composer2Layer(
            id: layerID(15, 1), name: "Stripes",
            color: palette([Swatch.red, Swatch.red, Swatch.white, Swatch.white], .linear),
            motion: Composer2Motion(kind: .march, periodSeconds: 4, smoothness: 0.6, steps: 4),
            rhythm: Composer2Rhythm(shape: .steady, maxBrightness: 0.9),
            variation: .exact)
        return look(15, "Candy Cane", "Red and white stripes, turning slowly.", [stripes])
    }()

    static let fairyLights: Composer2Composition = {
        let fairy = Composer2Layer(
            id: layerID(16, 1), name: "Fairy Glow",
            color: palette([Swatch.warmWhite, Swatch.gold, Swatch.candle], distribution: .randomPick),
            motion: Composer2Motion(kind: .static),
            rhythm: Composer2Rhythm(shape: .twinkle, periodSeconds: 2.6, attack: 0.6, decay: 0.6, depth: 1, duty: 0.6,
                                    minBrightness: 0.35, maxBrightness: 1),
            variation: .organic)
        let sparkle = eventLayer(16, 2, "Sparkle", opacity: 0.7,
                                 events: twinkles([Swatch.warmWhite, Swatch.gold], every: 0.4...1.2, lasting: 0.35...0.7))
        return look(16, "Fairy Lights", "Warm pinpricks that breathe in and out.", [fairy, sparkle])
    }()

    static let silentNight: Composer2Composition = {
        let candles = Composer2Layer(
            id: layerID(17, 1), name: "Candles",
            color: flame([Swatch.ember, Swatch.candle, Swatch.warmWhite]),
            motion: Composer2Motion(kind: .static),
            rhythm: Composer2Rhythm(shape: .candle, depth: 1, minBrightness: 0.35, maxBrightness: 0.8, flickerRate: 1.1),
            variation: .subtle)
        let moonlight = Composer2Layer(
            id: layerID(17, 2), name: "Moonlight", opacity: 0.35, blend: .maxBrightness,
            color: .solid(Swatch.pastelBlue),
            motion: Composer2Motion(kind: .wave, periodSeconds: 30, spread: 0.6, smoothness: 1, travelWidth: 0.5),
            rhythm: Composer2Rhythm(shape: .steady, maxBrightness: 0.35),
            variation: .subtle)
        return look(17, "Silent Night", "Candlelight, and moonlight through the window.", [candles, moonlight])
    }()

    static let snowfall: Composer2Composition = {
        let night = Composer2Layer(
            id: layerID(18, 1), name: "Winter Night",
            color: palette([Swatch.ice, Swatch.pastelBlue, Swatch.coolWhite]),
            motion: Composer2Motion(kind: .organic, periodSeconds: 40, spread: 0.8, smoothness: 1, travelWidth: 0.8, scale: 0.8),
            rhythm: Composer2Rhythm(shape: .breathe, periodSeconds: 14, depth: 1, minBrightness: 0.18, maxBrightness: 0.42),
            variation: .organic)
        let flakes = eventLayer(18, 2, "Flakes",
                                events: twinkles([Swatch.white, Swatch.coolWhite], every: 0.25...0.8,
                                                 lasting: 0.9...1.8, intensity: 0.35...0.7))
        return look(18, "Snowfall", "Soft blue night. Flakes catching the light.", [night, flakes])
    }()

    static let goldenOrnaments: Composer2Composition = {
        let garland = Composer2Layer(
            id: layerID(19, 1), name: "Garland",
            color: palette([Swatch.red, Swatch.gold, Swatch.green]),
            motion: Composer2Motion(kind: .flow, periodSeconds: 24, spread: 1, smoothness: 1, travelWidth: 1),
            rhythm: Composer2Rhythm(shape: .breathe, periodSeconds: 10, depth: 1, minBrightness: 0.45, maxBrightness: 0.85),
            variation: .subtle)
        let glints = eventLayer(19, 2, "Gold Glints",
                                events: twinkles([Swatch.gold, Swatch.yellow], every: 0.5...1.4, lasting: 0.3...0.7))
        return look(19, "Golden Ornaments", "Red, gold and green, with glints of gold.", [garland, glints])
    }()
}

// MARK: - Holidays

extension Composer2PresetLibrary {
    static let fourthOfJuly: Composer2Composition = {
        let stripes = Composer2Layer(
            id: layerID(20, 1), name: "Stars & Stripes",
            color: palette([Swatch.red, Swatch.white, Swatch.royal], .linear),
            motion: Composer2Motion(kind: .march, periodSeconds: 4.5, smoothness: 0.5, steps: 3),
            rhythm: Composer2Rhythm(shape: .steady, maxBrightness: 0.5),
            variation: .exact)
        let show = eventLayer(20, 2, "Fireworks",
                                   events: fireworks([Swatch.red, Swatch.white, Swatch.royal, Swatch.skyBlue],
                                                     every: 1.4...4, fade: 0.8, bloom: 0.35))
        return look(20, "Fourth of July", "Red, white and blue — and the sky lighting up.", [stripes, show])
    }()

    static let newYearsEve: Composer2Composition = {
        let midnight = Composer2Layer(
            id: layerID(21, 1), name: "Midnight",
            color: palette([Swatch.navy, Swatch.deepPurple]),
            motion: Composer2Motion(kind: .organic, periodSeconds: 40, spread: 0.8, smoothness: 1, scale: 0.7),
            rhythm: Composer2Rhythm(shape: .steady, maxBrightness: 0.08),
            variation: .subtle)
        let show = eventLayer(21, 2, "Fireworks",
                                   events: fireworks([Swatch.gold, Swatch.magenta, Swatch.skyBlue, Swatch.emerald,
                                                      Swatch.red, Swatch.white],
                                                     every: 0.9...2.6, fade: 0.9, bloom: 0.45, focus: 0.5))
        let glitter = eventLayer(21, 3, "Glitter", opacity: 0.6,
                                 events: twinkles([Swatch.gold, Swatch.white], every: 0.2...0.6, lasting: 0.25...0.5))
        return look(21, "New Year's Eve", "Fireworks over midnight. Glitter everywhere.", [midnight, show, glitter])
    }()

    static let valentine: Composer2Composition = {
        let hearts = Composer2Layer(
            id: layerID(22, 1), name: "Heartbeat",
            color: palette([Swatch.hotPink, Swatch.red, Swatch.blush, Swatch.magenta]),
            motion: Composer2Motion(kind: .flow, periodSeconds: 18, spread: 0.8, smoothness: 1, travelWidth: 1),
            rhythm: Composer2Rhythm(shape: .heartbeat, periodSeconds: 1.7, depth: 1, minBrightness: 0.45, maxBrightness: 0.95),
            variation: .subtle)
        return look(22, "Valentine's Glow", "Pinks and reds with a heartbeat.", [hearts])
    }()

    static let stPatricks: Composer2Composition = {
        let clover = Composer2Layer(
            id: layerID(23, 1), name: "Clover",
            color: palette([Swatch.emerald, Swatch.green, Swatch.lime]),
            motion: Composer2Motion(kind: .flow, periodSeconds: 20, spread: 1, smoothness: 1, travelWidth: 1),
            rhythm: Composer2Rhythm(shape: .breathe, periodSeconds: 12, depth: 1, minBrightness: 0.4, maxBrightness: 0.85),
            variation: .subtle)
        let gold = eventLayer(23, 2, "Pot of Gold",
                              events: twinkles([Swatch.gold, Swatch.yellow], every: 0.6...1.6, lasting: 0.4...0.8))
        return look(23, "St. Patrick's", "Every green there is, and a little gold.", [clover, gold])
    }()

    static let hanukkah: Composer2Composition = {
        let light = Composer2Layer(
            id: layerID(24, 1), name: "Blue & White",
            color: palette([Swatch.royal, Swatch.skyBlue, Swatch.white]),
            motion: Composer2Motion(kind: .flow, periodSeconds: 30, spread: 0.8, smoothness: 1, travelWidth: 1),
            rhythm: Composer2Rhythm(shape: .steady, maxBrightness: 0.6),
            variation: .subtle)
        let candles = Composer2Layer(
            id: layerID(24, 2), name: "Candles", blend: .maxBrightness,
            mask: .randomSubset(fraction: 0.5),
            color: flame([Swatch.candle, Swatch.gold, Swatch.warmWhite]),
            motion: Composer2Motion(kind: .static),
            rhythm: Composer2Rhythm(shape: .candle, depth: 1, minBrightness: 0.3, maxBrightness: 0.95, flickerRate: 1.4),
            variation: .subtle)
        return look(24, "Festival of Lights", "Blue and white, and candles burning bright.", [light, candles])
    }()

    static let diwali: Composer2Composition = {
        let diyas = Composer2Layer(
            id: layerID(25, 1), name: "Diyas",
            color: flame([Swatch.ember, Swatch.pumpkin, Swatch.gold]),
            motion: Composer2Motion(kind: .static),
            rhythm: Composer2Rhythm(shape: .candle, depth: 1, minBrightness: 0.35, maxBrightness: 1, flickerRate: 1.6),
            variation: .organic)
        let celebration = eventLayer(25, 2, "Celebration",
                                     events: fireworks([Swatch.gold, Swatch.magenta, Swatch.pumpkin, Swatch.emerald],
                                                       every: 3...8, fade: 0.7, bloom: 0.3))
        return look(25, "Diwali", "Rows of golden diyas, and the sky celebrating.", [diyas, celebration])
    }()

    static let easterPastels: Composer2Composition = {
        let pastels = Composer2Layer(
            id: layerID(26, 1), name: "Pastels",
            color: palette([Swatch.blush, Swatch.pastelYellow, Swatch.mint, Swatch.lavender, Swatch.pastelBlue]),
            motion: Composer2Motion(kind: .flow, periodSeconds: 26, spread: 1, smoothness: 1, travelWidth: 1),
            rhythm: Composer2Rhythm(shape: .breathe, periodSeconds: 12, depth: 1, minBrightness: 0.45, maxBrightness: 0.8),
            variation: .subtle)
        return look(26, "Spring Pastels", "Soft pinks, butter yellow, mint and lilac.", [pastels])
    }()
}
