// Composer2Models.swift
// ChromaGlow — Composer 2 lab (experimental).
//
// The universal behavior model. A composition is a stack of behavior layers;
// each layer combines the same primitives (mask, colour, motion, rhythm,
// audio, variation, optional events). Aurora Drift and Thunderstorm are just
// different values of this one type — there are no per-preset engines.
// Everything is Codable with tolerant decoding: only `id` is required, and a
// malformed layer drops out instead of taking the composition with it.

import Foundation

// MARK: - Blend

enum Composer2BlendMode: String, Codable, CaseIterable {
    /// Fade toward this layer (the base layer's natural mode).
    case replace
    /// Add light; the colour follows whichever side contributes more.
    case addLighten = "add_lighten"
    /// The brighter layer wins per light.
    case maxBrightness = "max_brightness"
}

/// Layers stack bottom-up over black. `replace` fades to the layer,
/// `add-lighten` adds light with contribution-weighted colour, `max` lets
/// the brighter layer win (with a 5 % soft band so ties don't chatter).
enum Composer2Blend {
    struct Accum: Equatable {
        var lab: Composer2Lab = .d65
        var brightness: Double = 0
    }

    static func composite(_ acc: inout Accum, lab: Composer2Lab, brightness rawB: Double,
                          coverage rawC: Double, mode: Composer2BlendMode) {
        let b = Composer2Math.clamp01(rawB)
        let c = Composer2Math.clamp01(rawC)
        guard c > 0 else { return }
        switch mode {
        case .replace:
            // Colour follows each side's share of the LIGHT, not coverage
            // alone: over black (brightness 0 beneath), a half-covered red
            // light is half-bright RED — mixing by coverage washed it toward
            // the accumulator's white seed and rendered pink.
            let below = (1 - c) * acc.brightness
            let above = c * b
            let w = below + above > 1e-9 ? above / (below + above) : c
            acc.brightness = Composer2Math.lerp(acc.brightness, b, c)
            acc.lab = Composer2ColorMath.mix(acc.lab, lab, t: w)
        case .addLighten:
            let add = b * c
            let total = acc.brightness + add
            let w = total > 1e-9 ? add / total : 0
            acc.lab = Composer2ColorMath.mix(acc.lab, lab, t: w)
            acc.brightness = Swift.min(1, total)
        case .maxBrightness:
            let candidate = b * c
            let w = Composer2Math.clamp01((candidate - acc.brightness) / 0.05 + 0.5)
            acc.lab = Composer2ColorMath.mix(acc.lab, lab, t: w)
            acc.brightness = Swift.max(acc.brightness, candidate)
        }
    }
}

// MARK: - Layer

struct Composer2Layer: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var enabled: Bool
    /// 0…1 how strongly the layer contributes.
    var opacity: Double
    var blend: Composer2BlendMode
    var mask: Composer2LayerMask
    var color: Composer2ColorSource
    var motion: Composer2Motion
    var rhythm: Composer2Rhythm
    var audio: Composer2AudioModulation
    var variation: Composer2Variation
    var events: Composer2EventSpec?

    init(id: UUID = UUID(), name: String = "Behavior", enabled: Bool = true, opacity: Double = 1,
         blend: Composer2BlendMode = .replace, mask: Composer2LayerMask = .wholeRoom,
         color: Composer2ColorSource = Composer2ColorSource(), motion: Composer2Motion = Composer2Motion(),
         rhythm: Composer2Rhythm = Composer2Rhythm(), audio: Composer2AudioModulation = Composer2AudioModulation(),
         variation: Composer2Variation = .exact, events: Composer2EventSpec? = nil) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.opacity = opacity
        self.blend = blend
        self.mask = mask
        self.color = color
        self.motion = motion
        self.rhythm = rhythm
        self.audio = audio
        self.variation = variation
        self.events = events
    }

    enum CodingKeys: String, CodingKey {
        case id, name, enabled, opacity, blend, mask, color, motion, rhythm, audio, variation, events
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Composer2Layer()
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? d.name
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? d.enabled
        opacity = (try? c.decode(Double.self, forKey: .opacity)) ?? d.opacity
        blend = (try? c.decode(Composer2BlendMode.self, forKey: .blend)) ?? d.blend
        mask = (try? c.decode(Composer2LayerMask.self, forKey: .mask)) ?? d.mask
        color = (try? c.decode(Composer2ColorSource.self, forKey: .color)) ?? d.color
        motion = (try? c.decode(Composer2Motion.self, forKey: .motion)) ?? d.motion
        rhythm = (try? c.decode(Composer2Rhythm.self, forKey: .rhythm)) ?? d.rhythm
        audio = (try? c.decode(Composer2AudioModulation.self, forKey: .audio)) ?? d.audio
        variation = (try? c.decode(Composer2Variation.self, forKey: .variation)) ?? d.variation
        events = try? c.decode(Composer2EventSpec.self, forKey: .events)
    }

    /// A blank layer to start building from.
    static func blank(name: String = "New Behavior") -> Composer2Layer {
        Composer2Layer(name: name, color: Composer2ColorSource(), motion: Composer2Motion(kind: .flow),
                       rhythm: Composer2Rhythm(shape: .steady))
    }

    var contributes: Bool { enabled && opacity > 0 }
}

// MARK: - Composition

struct Composer2MasterControls: Codable, Equatable {
    /// 0…1 overall brightness scale.
    var intensity: Double = 1
    /// Global time multiplier (0.25…4).
    var speed: Double = 1
    /// 0…1 quick-mode "energy" (drives the variation preset and event chance).
    var energy: Double = 0.5
    /// Global variation scale, 0…2 (1 = as authored). Quick mode's Energy
    /// drives this so it never rewrites a layer's own variation settings.
    var variation: Double = 1
    var seed: UInt64
    /// How often events happen, ×0.25…×4 (1 = as authored). The storm's
    /// "Frequency" dial — only the schedule changes.
    var eventRate: Double = 1
    /// 0…1 how strongly events land (1 = as authored).
    var eventStrength: Double = 1

    init(intensity: Double = 1, speed: Double = 1, energy: Double = 0.5, variation: Double = 1, seed: UInt64,
         eventRate: Double = 1, eventStrength: Double = 1) {
        self.intensity = intensity
        self.speed = speed
        self.energy = energy
        self.variation = variation
        self.seed = seed
        self.eventRate = eventRate
        self.eventStrength = eventStrength
    }

    enum CodingKeys: String, CodingKey { case intensity, speed, energy, variation, seed, eventRate, eventStrength }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        intensity = (try? c.decode(Double.self, forKey: .intensity)) ?? 1
        speed = (try? c.decode(Double.self, forKey: .speed)) ?? 1
        energy = (try? c.decode(Double.self, forKey: .energy)) ?? 0.5
        variation = (try? c.decode(Double.self, forKey: .variation)) ?? 1
        seed = Composer2SeedCoding.decode(from: c, forKey: .seed) ?? 0x5EED_C0DE
        eventRate = (try? c.decode(Double.self, forKey: .eventRate)) ?? 1
        eventStrength = (try? c.decode(Double.self, forKey: .eventStrength)) ?? 1
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(intensity, forKey: .intensity)
        try c.encode(speed, forKey: .speed)
        try c.encode(energy, forKey: .energy)
        try c.encode(variation, forKey: .variation)
        try Composer2SeedCoding.encode(seed, to: &c, forKey: .seed)
        try c.encode(eventRate, forKey: .eventRate)
        try c.encode(eventStrength, forKey: .eventStrength)
    }

    var sanitizedSpeed: Double { Composer2Math.clamp(speed.isFinite ? speed : 1, 0.25, 4) }
    var sanitizedEventRate: Double { Composer2Math.clamp(eventRate.isFinite ? eventRate : 1, 0.25, 4) }
    var sanitizedEventStrength: Double { Composer2Math.clamp01(eventStrength.isFinite ? eventStrength : 1) }
}

struct Composer2TargetHint: Codable, Equatable {
    var roomID: String?
    var bridgeID: String?

    init(roomID: String? = nil, bridgeID: String? = nil) {
        self.roomID = roomID
        self.bridgeID = bridgeID
    }
}

struct Composer2Composition: Codable, Equatable, Identifiable {
    static let currentSchema = 1

    var schema: Int
    let id: UUID
    var name: String
    var subtitle: String
    var createdAt: Date
    var updatedAt: Date
    var isBuiltIn: Bool
    /// The legacy Composer preset this was imported from, if any.
    var sourcePresetID: UUID?
    var target: Composer2TargetHint
    var master: Composer2MasterControls
    var layers: [Composer2Layer]

    init(id: UUID = UUID(), name: String, subtitle: String = "", createdAt: Date, updatedAt: Date? = nil,
         isBuiltIn: Bool = false, sourcePresetID: UUID? = nil, target: Composer2TargetHint = Composer2TargetHint(),
         master: Composer2MasterControls? = nil, layers: [Composer2Layer]) {
        self.schema = Composer2Composition.currentSchema
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.isBuiltIn = isBuiltIn
        self.sourcePresetID = sourcePresetID
        self.target = target
        self.master = master ?? Composer2MasterControls(seed: Composer2Hash.seed(from: id))
        self.layers = layers
    }

    enum CodingKeys: String, CodingKey {
        case schema, id, name, subtitle, createdAt, updatedAt, isBuiltIn, sourcePresetID, target, master, layers
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(UUID.self, forKey: .id)
        self.id = id
        schema = (try? c.decode(Int.self, forKey: .schema)) ?? Composer2Composition.currentSchema
        name = (try? c.decode(String.self, forKey: .name)) ?? "Untitled"
        subtitle = (try? c.decode(String.self, forKey: .subtitle)) ?? ""
        let created = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date(timeIntervalSince1970: 0)
        createdAt = created
        updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? created
        isBuiltIn = (try? c.decode(Bool.self, forKey: .isBuiltIn)) ?? false
        sourcePresetID = try? c.decode(UUID.self, forKey: .sourcePresetID)
        target = (try? c.decode(Composer2TargetHint.self, forKey: .target)) ?? Composer2TargetHint()
        master = (try? c.decode(Composer2MasterControls.self, forKey: .master))
            ?? Composer2MasterControls(seed: Composer2Hash.seed(from: id))
        let failable = (try? c.decode([FailableDecodable<Composer2Layer>].self, forKey: .layers)) ?? []
        layers = failable.compactMap(\.value)
    }

    var hasVisibleOutput: Bool { layers.contains { $0.contributes } }
    var usesAudio: Bool { layers.contains { $0.contributes && $0.audio.isActive } }
    var usesMicrophoneBands: Bool { layers.contains { $0.contributes && $0.audio.usesMicrophoneBands } }
    var usesBeatClock: Bool { layers.contains { $0.contributes && $0.audio.source == .beat } }
    var hasEvents: Bool { layers.contains { $0.contributes && $0.events != nil } }

    /// The first two palette stops of the first visible layer — used to seed
    /// the legacy prime frame so the first thing the room shows is coherent.
    var primaryStops: [Composer2XY] {
        let layer = layers.first { $0.contributes } ?? layers.first
        let stops = (layer?.color.sanitizedStops ?? [Composer2PaletteStop(.d65)]).map(\.xy)
        if stops.count >= 2 { return Array(stops.prefix(2)) }
        return [stops[0], stops[0]]
    }

    /// A copy with a fresh identity (duplicate / save-as-new) that PLAYS THE
    /// SAME: every layer's effective seed is pinned before its id changes.
    /// Seeds used to derive from the layer id and the composition's master
    /// seed, so saving a tuned look as new silently reshuffled which lights
    /// flickered, when events fired and who they hit — the saved look never
    /// matched what was auditioned.
    func duplicated(name newName: String, at date: Date) -> Composer2Composition {
        let pinned: [Composer2Layer] = layers.map { layer in
            var l = layer
            if l.variation.seed == nil {
                l.variation.seed = Composer2Engine.layerSeed(composition: self, layer: layer)
            }
            l.id = UUID()
            return l
        }
        return Composer2Composition(id: UUID(), name: newName, subtitle: subtitle, createdAt: date,
                                    updatedAt: date, isBuiltIn: false, sourcePresetID: sourcePresetID,
                                    target: target, master: master, layers: pinned)
    }
}
