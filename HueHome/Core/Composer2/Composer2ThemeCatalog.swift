// Composer2ThemeCatalog.swift
// ChromaGlow — Composer 2 lab (experimental).
//
// The built-in looks, grouped the way people look for them: Halloween,
// Christmas & winter, holidays, weather, nature, fire, party, calm. Every
// look is a plain value of the universal model (see Composer2PresetLibrary
// and its +Seasons / +World extensions); this file only files them.
//
// Ids are hand-assigned (`0000000C-0002-0002-0002-…`, 1…50) and never
// reused, so a user's saved copies and the catalog can never collide.

import Foundation

enum Composer2LookCategory: String, CaseIterable, Identifiable, Codable {
    case halloween, winter, holidays, weather, nature, fire, party, calm

    var id: String { rawValue }

    var title: String {
        switch self {
        case .halloween: return "Halloween"
        case .winter: return "Christmas & Winter"
        case .holidays: return "Holidays"
        case .weather: return "Weather"
        case .nature: return "Nature"
        case .fire: return "Fire & Candle"
        case .party: return "Party"
        case .calm: return "Calm"
        }
    }

    var shortTitle: String {
        switch self {
        case .winter: return "Christmas"
        case .fire: return "Fire"
        default: return title
        }
    }

    var symbol: String {
        switch self {
        case .halloween: return "moon.haze.fill"
        case .winter: return "snowflake"
        case .holidays: return "party.popper.fill"
        case .weather: return "cloud.bolt.rain.fill"
        case .nature: return "leaf.fill"
        case .fire: return "flame.fill"
        case .party: return "music.note"
        case .calm: return "moon.zzz.fill"
        }
    }

    var tagline: String {
        switch self {
        case .halloween: return "Candles, fog and things that move in the dark."
        case .winter: return "Chasing strings, twinkling fairy lights, falling snow."
        case .holidays: return "Fireworks, flags and festivals of light."
        case .weather: return "Lightning you can feel — near, far, and passing."
        case .nature: return "Aurora, ocean, fireflies and starlight."
        case .fire: return "Real flame: sway, flicker and embers."
        case .party: return "Chases, neon and light that listens."
        case .calm: return "Slow light to breathe with."
        }
    }
}

struct Composer2LookEntry: Identifiable, Equatable {
    let composition: Composer2Composition
    let category: Composer2LookCategory
    /// SF Symbol for the look's card.
    let symbol: String
    /// New in v2.2 (the card wears a small "NEW").
    let isNew: Bool

    var id: UUID { composition.id }
}

enum Composer2ThemeCatalog {
    typealias P = Composer2PresetLibrary

    static let entries: [Composer2LookEntry] = [
        // Halloween
        .init(composition: P.hauntedHouse, category: .halloween, symbol: "moon.haze.fill", isNew: false),
        .init(composition: P.jackOLantern, category: .halloween, symbol: "flame.fill", isNew: true),
        .init(composition: P.witchesBrew, category: .halloween, symbol: "flask.fill", isNew: true),
        .init(composition: P.graveyardFog, category: .halloween, symbol: "cloud.fog.fill", isNew: true),
        .init(composition: P.poltergeist, category: .halloween, symbol: "eye.fill", isNew: true),
        .init(composition: P.bloodMoon, category: .halloween, symbol: "moon.fill", isNew: true),
        .init(composition: P.madScientist, category: .halloween, symbol: "bolt.circle.fill", isNew: true),
        .init(composition: P.trickOrTreat, category: .halloween, symbol: "theatermasks.fill", isNew: true),
        // Christmas & winter
        .init(composition: P.christmasChase, category: .winter, symbol: "snowflake", isNew: false),
        .init(composition: P.classicC9, category: .winter, symbol: "lightbulb.2.fill", isNew: true),
        .init(composition: P.theaterChase, category: .winter, symbol: "lightbulb.led.fill", isNew: true),
        .init(composition: P.candyCane, category: .winter, symbol: "gift.fill", isNew: true),
        .init(composition: P.fairyLights, category: .winter, symbol: "sparkles", isNew: true),
        .init(composition: P.silentNight, category: .winter, symbol: "moon.stars.fill", isNew: true),
        .init(composition: P.snowfall, category: .winter, symbol: "cloud.snow.fill", isNew: true),
        .init(composition: P.goldenOrnaments, category: .winter, symbol: "star.fill", isNew: true),
        // Holidays
        .init(composition: P.fourthOfJuly, category: .holidays, symbol: "flag.fill", isNew: true),
        .init(composition: P.newYearsEve, category: .holidays, symbol: "party.popper.fill", isNew: true),
        .init(composition: P.valentine, category: .holidays, symbol: "heart.fill", isNew: true),
        .init(composition: P.stPatricks, category: .holidays, symbol: "leaf.fill", isNew: true),
        .init(composition: P.hanukkah, category: .holidays, symbol: "flame", isNew: true),
        .init(composition: P.diwali, category: .holidays, symbol: "sparkle", isNew: true),
        .init(composition: P.easterPastels, category: .holidays, symbol: "camera.macro", isNew: true),
        // Weather
        .init(composition: P.thunderstorm, category: .weather, symbol: "cloud.bolt.fill", isNew: false),
        .init(composition: P.supercell, category: .weather, symbol: "tornado", isNew: true),
        .init(composition: P.heatLightning, category: .weather, symbol: "cloud.sun.bolt.fill", isNew: true),
        .init(composition: P.passingStorm, category: .weather, symbol: "cloud.bolt.rain.fill", isNew: true),
        .init(composition: P.rainyNight, category: .weather, symbol: "cloud.rain.fill", isNew: true),
        // Nature
        .init(composition: P.auroraDrift, category: .nature, symbol: "wind", isNew: false),
        .init(composition: P.oceanWaves, category: .nature, symbol: "water.waves", isNew: true),
        .init(composition: P.fireflies, category: .nature, symbol: "sparkle.magnifyingglass", isNew: true),
        .init(composition: P.starryNight, category: .nature, symbol: "moon.stars", isNew: true),
        .init(composition: P.underwater, category: .nature, symbol: "fish.fill", isNew: true),
        .init(composition: P.enchantedForest, category: .nature, symbol: "tree.fill", isNew: true),
        .init(composition: P.goldenHour, category: .nature, symbol: "sun.horizon.fill", isNew: true),
        .init(composition: P.sunsetGlow, category: .nature, symbol: "sunset.fill", isNew: true),
        // Fire & candle
        .init(composition: P.fireplace, category: .fire, symbol: "fireplace.fill", isNew: true),
        .init(composition: P.candlelight, category: .fire, symbol: "flame.fill", isNew: true),
        .init(composition: P.campfire, category: .fire, symbol: "tent.fill", isNew: true),
        .init(composition: P.lavaLamp, category: .fire, symbol: "drop.fill", isNew: false),
        // Party
        .init(composition: P.discoFever, category: .party, symbol: "music.note", isNew: true),
        .init(composition: P.neonNights, category: .party, symbol: "light.beacon.max.fill", isNew: true),
        .init(composition: P.rainbowWave, category: .party, symbol: "rainbow", isNew: true),
        .init(composition: P.beatDrop, category: .party, symbol: "waveform", isNew: true),
        .init(composition: P.clubPulse, category: .party, symbol: "speaker.wave.3.fill", isNew: true),
        // Calm
        .init(composition: P.breathingCalm, category: .calm, symbol: "lungs.fill", isNew: true),
        .init(composition: P.cloudDrift, category: .calm, symbol: "cloud.fill", isNew: true),
        .init(composition: P.cozyEvening, category: .calm, symbol: "cup.and.saucer.fill", isNew: true),
        .init(composition: P.deepFocus, category: .calm, symbol: "scope", isNew: true)
    ]

    private static let byID: [UUID: Composer2LookEntry] = Dictionary(
        entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    static func entry(id: UUID) -> Composer2LookEntry? { byID[id] }

    static func entries(in category: Composer2LookCategory) -> [Composer2LookEntry] {
        entries.filter { $0.category == category }
    }

    /// The looks the library opens on — one showpiece per mood.
    static let featuredIDs: [UUID] = [
        P.thunderstorm.id, P.classicC9.id, P.jackOLantern.id, P.newYearsEve.id,
        P.auroraDrift.id, P.fireplace.id
    ]

    static var featured: [Composer2LookEntry] { featuredIDs.compactMap { entry(id: $0) } }
}
