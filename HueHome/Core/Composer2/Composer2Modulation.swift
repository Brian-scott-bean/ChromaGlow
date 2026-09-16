// Composer2Modulation.swift
// ChromaGlow — Composer 2 lab (experimental).
//
// Audio modulation and variation: the two primitives that make a behavior
// respond (to sound) and feel alive (seeded, reproducible variety).
// Both are pure value types; the engine holds the little state they need
// (smoothed drive, warped time) so these stay testable on their own.

import Foundation

// MARK: - Seed coding

/// Seeds are `UInt64` but JSON numbers lose precision above 2^53, so seeds
/// travel as decimal strings and decode from either a string or a number.
enum Composer2SeedCoding {
    static func encode(_ seed: UInt64?, into container: inout KeyedEncodingContainer<some CodingKey>,
                       forKey key: some CodingKey) throws {
        // Generic key types can't be mixed; callers use the typed helpers below.
    }

    static func decode<K: CodingKey>(from container: KeyedDecodingContainer<K>, forKey key: K) -> UInt64? {
        if let s = try? container.decode(String.self, forKey: key), let v = UInt64(s) { return v }
        if let v = try? container.decode(UInt64.self, forKey: key) { return v }
        if let d = try? container.decode(Double.self, forKey: key), d.isFinite, d >= 0, d < 1.8e19 {
            return UInt64(d)
        }
        return nil
    }

    static func encode<K: CodingKey>(_ seed: UInt64?, to container: inout KeyedEncodingContainer<K>, forKey key: K) throws {
        if let seed { try container.encode(String(seed), forKey: key) }
    }
}

// MARK: - Audio modulation

struct Composer2AudioModulation: Codable, Equatable {
    enum Source: String, Codable, CaseIterable {
        case off
        case amplitude
        case bass
        case mid
        case treble
        case beat
        case onset
    }

    enum Target: String, Codable, CaseIterable {
        case brightness
        case palettePosition = "palette_position"
        case motionSpeed = "motion_speed"
        case eventProbability = "event_probability"
    }

    /// How a brightness target responds: `punch` adds light on sound (the
    /// look stays as authored when quiet); `dimWhenQuiet` is the legacy
    /// Composer rule that dims to (1 − intensity) in silence.
    enum BrightnessMode: String, Codable, CaseIterable {
        case punch
        case dimWhenQuiet = "dim_when_quiet"
    }

    var source: Source = .off
    var brightnessMode: BrightnessMode = .punch
    var sensitivity: Double = 0.7
    /// Noise gate 0…1.
    var threshold: Double = 0.1
    /// One-pole smoothing 0…1 (τ 0…0.5 s).
    var smoothing: Double = 0.3
    var intensity: Double = 0.7
    var targets: Set<Target> = [.brightness]
    var quantizeBeats: Double = 1
    var paletteStep: Double = 0.25
    /// 0…1 punch decay for beat/onset sources (τ 0.08…0.6 s).
    var punchDecay: Double = 0.4
    var triggerEventsOnOnset: Bool = false

    init(source: Source = .off, brightnessMode: BrightnessMode = .punch, sensitivity: Double = 0.7,
         threshold: Double = 0.1, smoothing: Double = 0.3,
         intensity: Double = 0.7, targets: Set<Target> = [.brightness], quantizeBeats: Double = 1,
         paletteStep: Double = 0.25, punchDecay: Double = 0.4, triggerEventsOnOnset: Bool = false) {
        self.source = source
        self.brightnessMode = brightnessMode
        self.sensitivity = sensitivity
        self.threshold = threshold
        self.smoothing = smoothing
        self.intensity = intensity
        self.targets = targets
        self.quantizeBeats = quantizeBeats
        self.paletteStep = paletteStep
        self.punchDecay = punchDecay
        self.triggerEventsOnOnset = triggerEventsOnOnset
    }

    enum CodingKeys: String, CodingKey {
        case source, brightnessMode, sensitivity, threshold, smoothing, intensity, targets, quantizeBeats, paletteStep, punchDecay, triggerEventsOnOnset
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Composer2AudioModulation()
        source = (try? c.decode(Source.self, forKey: .source)) ?? d.source
        brightnessMode = (try? c.decode(BrightnessMode.self, forKey: .brightnessMode)) ?? d.brightnessMode
        sensitivity = (try? c.decode(Double.self, forKey: .sensitivity)) ?? d.sensitivity
        threshold = (try? c.decode(Double.self, forKey: .threshold)) ?? d.threshold
        smoothing = (try? c.decode(Double.self, forKey: .smoothing)) ?? d.smoothing
        intensity = (try? c.decode(Double.self, forKey: .intensity)) ?? d.intensity
        if let raw = try? c.decode([String].self, forKey: .targets) {
            targets = Set(raw.compactMap(Target.init(rawValue:)))
        } else {
            targets = d.targets
        }
        quantizeBeats = (try? c.decode(Double.self, forKey: .quantizeBeats)) ?? d.quantizeBeats
        paletteStep = (try? c.decode(Double.self, forKey: .paletteStep)) ?? d.paletteStep
        punchDecay = (try? c.decode(Double.self, forKey: .punchDecay)) ?? d.punchDecay
        triggerEventsOnOnset = (try? c.decode(Bool.self, forKey: .triggerEventsOnOnset)) ?? d.triggerEventsOnOnset
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(source, forKey: .source)
        try c.encode(brightnessMode, forKey: .brightnessMode)
        try c.encode(sensitivity, forKey: .sensitivity)
        try c.encode(threshold, forKey: .threshold)
        try c.encode(smoothing, forKey: .smoothing)
        try c.encode(intensity, forKey: .intensity)
        try c.encode(targets.map(\.rawValue).sorted(), forKey: .targets)
        try c.encode(quantizeBeats, forKey: .quantizeBeats)
        try c.encode(paletteStep, forKey: .paletteStep)
        try c.encode(punchDecay, forKey: .punchDecay)
        try c.encode(triggerEventsOnOnset, forKey: .triggerEventsOnOnset)
    }

    var isActive: Bool { source != .off }

    /// True when this source reads the microphone's analysis bands.
    var usesMicrophoneBands: Bool {
        switch source {
        case .amplitude, .bass, .mid, .treble, .onset: return true
        case .beat, .off: return false
        }
    }

    var punchDecayTau: Double { 0.08 + Composer2Math.clamp01(punchDecay) * 0.52 }
    var smoothingTau: Double { Composer2Math.clamp01(smoothing) * 0.5 }

    /// The raw 0…1 drive this frame, before smoothing.
    func rawDrive(features: AudioFeatures, beat: BeatSnapshot, hostNow: Double) -> Double {
        switch source {
        case .off:
            return 0
        case .amplitude:
            return shaped(Double(features.level))
        case .bass:
            return shaped(Double(features.bass))
        case .mid:
            return shaped(Double(features.mid))
        case .treble:
            return shaped(Double(features.treble))
        case .beat:
            guard beat.bpm > 0, hostNow > 0 else { return 0 }
            return Composer2Math.clamp01(exp(-beat.timeSinceBeat(at: hostNow) / punchDecayTau))
        case .onset:
            if hostNow > 0, features.lastOnsetAt > 0 {
                return Composer2Math.clamp01(exp(-(hostNow - features.lastOnsetAt) / punchDecayTau))
            }
            return Composer2Math.clamp01(Double(features.onsetStrength))
        }
    }

    /// Gate below the threshold, then scale by sensitivity.
    func shaped(_ level: Double) -> Double {
        let gate = Composer2Math.clamp(threshold, 0, 0.95)
        let gated = Swift.max(0, (Composer2Math.clamp01(level) - gate)) / (1 - gate)
        return Composer2Math.clamp01(gated * (0.5 + Composer2Math.clamp01(sensitivity) * 1.5))
    }

    /// Multiplier on brightness (legacy `dimWhenQuiet` only): quiet dims
    /// toward (1 − intensity), loud restores full. `punch` returns 1.
    func brightnessScale(drive: Double) -> Double {
        guard targets.contains(.brightness), isActive, brightnessMode == .dimWhenQuiet else { return 1 }
        let k = Composer2Math.clamp01(intensity)
        return Composer2Math.clamp01(1 - k * (1 - Composer2Math.clamp01(drive)))
    }

    /// Additive brightness on sound (`punch` only): 0…1 share of the headroom to add.
    func punch(drive: Double) -> Double {
        guard targets.contains(.brightness), isActive, brightnessMode == .punch else { return 0 }
        return Composer2Math.clamp01(drive) * Composer2Math.clamp01(intensity)
    }

    func speedMultiplier(drive: Double) -> Double {
        guard targets.contains(.motionSpeed), isActive else { return 1 }
        return 1 + Composer2Math.clamp01(drive) * Composer2Math.clamp01(intensity) * 2
    }

    func probabilityBoost(drive: Double) -> Double {
        guard targets.contains(.eventProbability), isActive else { return 0 }
        return Composer2Math.clamp01(drive) * Composer2Math.clamp01(intensity)
    }

    /// Continuous palette offset for band sources (beat/onset step instead).
    func paletteOffset(drive: Double) -> Double {
        guard targets.contains(.palettePosition), isActive, usesMicrophoneBands, source != .onset else { return 0 }
        return Composer2Math.clamp01(drive) * Composer2Math.clamp01(intensity) * 0.5
    }
}

// MARK: - Variation

struct Composer2Variation: Codable, Equatable {
    /// Master 0…1 amount that scales every other field.
    var amount: Double = 0
    /// Explicit seed; nil derives one from the layer identity.
    var seed: UInt64? = nil
    var speedVariation: Double = 0
    var brightnessVariation: Double = 0
    var paletteDrift: Double = 0
    var perLightPhase: Double = 0
    /// 0…1 share of the configured event delay range that is actually used.
    var eventTiming: Double = 1
    var spatialRandomness: Double = 0
    /// > 0 lets per-light randomness slowly wander instead of staying frozen.
    var evolveRate: Double = 0

    init(amount: Double = 0, seed: UInt64? = nil, speedVariation: Double = 0, brightnessVariation: Double = 0,
         paletteDrift: Double = 0, perLightPhase: Double = 0, eventTiming: Double = 1,
         spatialRandomness: Double = 0, evolveRate: Double = 0) {
        self.amount = amount
        self.seed = seed
        self.speedVariation = speedVariation
        self.brightnessVariation = brightnessVariation
        self.paletteDrift = paletteDrift
        self.perLightPhase = perLightPhase
        self.eventTiming = eventTiming
        self.spatialRandomness = spatialRandomness
        self.evolveRate = evolveRate
    }

    enum CodingKeys: String, CodingKey {
        case amount, seed, speedVariation, brightnessVariation, paletteDrift, perLightPhase, eventTiming, spatialRandomness, evolveRate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Composer2Variation()
        amount = (try? c.decode(Double.self, forKey: .amount)) ?? d.amount
        seed = Composer2SeedCoding.decode(from: c, forKey: .seed)
        speedVariation = (try? c.decode(Double.self, forKey: .speedVariation)) ?? d.speedVariation
        brightnessVariation = (try? c.decode(Double.self, forKey: .brightnessVariation)) ?? d.brightnessVariation
        paletteDrift = (try? c.decode(Double.self, forKey: .paletteDrift)) ?? d.paletteDrift
        perLightPhase = (try? c.decode(Double.self, forKey: .perLightPhase)) ?? d.perLightPhase
        eventTiming = (try? c.decode(Double.self, forKey: .eventTiming)) ?? d.eventTiming
        spatialRandomness = (try? c.decode(Double.self, forKey: .spatialRandomness)) ?? d.spatialRandomness
        evolveRate = (try? c.decode(Double.self, forKey: .evolveRate)) ?? d.evolveRate
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(amount, forKey: .amount)
        try Composer2SeedCoding.encode(seed, to: &c, forKey: .seed)
        try c.encode(speedVariation, forKey: .speedVariation)
        try c.encode(brightnessVariation, forKey: .brightnessVariation)
        try c.encode(paletteDrift, forKey: .paletteDrift)
        try c.encode(perLightPhase, forKey: .perLightPhase)
        try c.encode(eventTiming, forKey: .eventTiming)
        try c.encode(spatialRandomness, forKey: .spatialRandomness)
        try c.encode(evolveRate, forKey: .evolveRate)
    }

    // Presets — the same five words the UI shows.
    static let exact = Composer2Variation()
    static let subtle = Composer2Variation(amount: 0.25, speedVariation: 0.2, brightnessVariation: 0.15,
                                           paletteDrift: 0.1, perLightPhase: 0.3, eventTiming: 0.6,
                                           spatialRandomness: 0.05, evolveRate: 0)
    static let organic = Composer2Variation(amount: 0.55, speedVariation: 0.35, brightnessVariation: 0.3,
                                            paletteDrift: 0.3, perLightPhase: 0.6, eventTiming: 0.85,
                                            spatialRandomness: 0.15, evolveRate: 0.03)
    static let evolving = Composer2Variation(amount: 0.75, speedVariation: 0.5, brightnessVariation: 0.35,
                                             paletteDrift: 0.5, perLightPhase: 0.8, eventTiming: 1,
                                             spatialRandomness: 0.2, evolveRate: 0.08)
    static let wild = Composer2Variation(amount: 1, speedVariation: 0.8, brightnessVariation: 0.6,
                                         paletteDrift: 0.8, perLightPhase: 1, eventTiming: 1,
                                         spatialRandomness: 0.4, evolveRate: 0.2)

    enum Preset: String, CaseIterable {
        case exact, subtle, organic, evolving, wild
        var value: Composer2Variation {
            switch self {
            case .exact: return .exact
            case .subtle: return .subtle
            case .organic: return .organic
            case .evolving: return .evolving
            case .wild: return .wild
            }
        }
    }

    /// The preset whose values match, if any.
    var matchingPreset: Preset? {
        Preset.allCases.first { $0.value.withSeed(seed) == self }
    }

    func withSeed(_ newSeed: UInt64?) -> Composer2Variation {
        var copy = self
        copy.seed = newSeed
        return copy
    }

    struct SlotJitter: Equatable {
        /// Added to the colour phase (0…1).
        var phase: Double = 0
        /// Multiplier offset on motion time (−0.5…0.5).
        var speed: Double = 0
        /// Subtracted brightness share (0…0.6).
        var brightness: Double = 0
        /// Added to the axis position (−0.25…0.25).
        var position: Double = 0
    }

    /// Frozen per-light offsets. `evolve` (0…1, from `evolveRate × time`) lets
    /// them wander when evolveRate > 0.
    func slotJitter(slot: Int, seed: UInt64, time: Double = 0) -> SlotJitter {
        let a = Composer2Math.clamp01(amount)
        guard a > 0 else { return SlotJitter() }
        func unit(_ salt: UInt64) -> Double {
            let rate = Composer2Math.clamp01(evolveRate)
            if rate > 0, time.isFinite {
                let s = Composer2Hash.mix(seed, salt)
                return Composer2Noise.value1D(time * rate * 0.5 + Double(slot) * 7.3, seed: s)
            }
            return Composer2Hash.unit(seed, slot, 0, salt: salt)
        }
        return SlotJitter(
            phase: unit(0x7A5E) * Composer2Math.clamp01(perLightPhase) * a,
            speed: (unit(0x5EED) - 0.5) * Composer2Math.clamp01(speedVariation) * a,
            brightness: unit(0xB1F7) * Composer2Math.clamp01(brightnessVariation) * a * 0.6,
            position: (unit(0x9051) - 0.5) * Composer2Math.clamp01(spatialRandomness) * a * 0.5
        )
    }

    /// Slow per-light palette wander in 0…1 phase units.
    func drift(slot: Int, seed: UInt64, time: Double) -> Double {
        let d = Composer2Math.clamp01(paletteDrift) * Composer2Math.clamp01(amount)
        guard d > 0, time.isFinite else { return 0 }
        let n = Composer2Noise.value1D(time * 0.05 + Double(slot) * 3.7, seed: Composer2Hash.mix(seed, 0xD21F))
        return (n - 0.5) * d * 0.5
    }

    /// Share of the event delay range used (1 = full range, 0 = midpoint).
    var effectiveEventTiming: Double {
        Composer2Math.clamp01(eventTiming)
    }
}
