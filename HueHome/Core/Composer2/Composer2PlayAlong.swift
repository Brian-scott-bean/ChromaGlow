// Composer2PlayAlong.swift
// ChromaGlow — Composer 2 (Play Along P3)
//
// One button that makes ANY look play along with the music. Not a new kind
// of look and nothing stored: a pure transform applied while the look plays,
// re-derived when the song's tempo changes, gone when Play Along is off. The
// 49 built-in looks and every saved look stay exactly as authored.
//
// What it does, per feel (docs/ios/play-along/README.md §5.6):
//  • Every feel locks cycles to musical lengths (powers of two beats): the
//    rhythm's breathing/pulsing and the motion's travel land on bars. Glide
//    only locks a cycle a musical length already fits within ±20 %, so a
//    look's own pace survives; Groove and Hit lock every cycle up to 16 bars.
//    Longer cycles (ambient drift) stay free — not felt as tempo.
//  • Glide: the base layer swells gently with loudness.
//  • Groove: layers punch softly on each beat and step their palette once a
//    bar.
//  • Hit: stronger punches, palette steps every two beats, and events (fairy
//    lights, lightning, fireworks) fire on predicted beats or downbeats at
//    the look's own average rate — on the beat instead of after it.
//  • A layer that already listens (Beat Drop, Club Pulse) keeps its sound
//    settings; only its cycles lock.
//  • Hits (Roll · Chase · Together): every punch — Groove's and Hit's, and
//    a listening look's own — lands where the user chose: rolling across the
//    room, stepping light to light, or the whole room at once. A punch whose
//    look already chose how it moves keeps that.
//  • Calm looks are never re-timed — "six breaths a minute" stays six — they
//    only breathe a little with the music's loudness. Slow looks clamp to
//    Glide.
//
// Pure and deterministic: (look, feel, tempo) → look. The flash floors
// (engine period doubling, Composer2FlashShaper, the bridge's onset ledger)
// stay authoritative over everything this produces.

import Foundation

enum Composer2PlayAlong {

    enum Feel: String, CaseIterable, Codable, Identifiable {
        case glide, groove, hit
        var id: String { rawValue }

        var title: String {
            switch self {
            case .glide: return "Glide"
            case .groove: return "Groove"
            case .hit: return "Hit"
            }
        }

        var subtitle: String {
            switch self {
            case .glide: return "Moves in time and breathes with the music"
            case .groove: return "A soft pulse on every beat, a new color each bar"
            case .hit: return "Every beat lands — sparkles and strikes on the one"
            }
        }
    }

    /// Cycles longer than this many beats stay free (16 bars of 4/4).
    static let longestLockedBeats = 64.0
    /// Glide re-times a cycle only within this share of its authored length.
    static let glideTolerance = 0.2
    /// A look whose every cycle is at least this slow, with no events, plays
    /// Glide whatever feel is chosen.
    static let slowCycleSeconds = 8.0

    /// The derived look. `bpm` is the tempo when Play Along engaged (or the
    /// song changed); `category` lets Calm looks keep their own pace.
    static func apply(_ look: Composer2Composition, feel requested: Feel, bpm: Double,
                      category: Composer2LookCategory? = nil,
                      hits: Composer2AudioModulation.Travel = .together,
                      band: Bool = false) -> Composer2Composition {
        guard bpm.isFinite, bpm >= 20, bpm <= 300 else { return look }
        let calm = category == .calm
        let feel = calm || isSlow(look) ? .glide : requested
        let beat = 60 / bpm
        var out = look
        let baseIndex = out.layers.firstIndex { $0.contributes && $0.blend == .replace }
            ?? out.layers.firstIndex { $0.contributes }

        for i in out.layers.indices where out.layers[i].contributes {
            var layer = out.layers[i]
            let isBase = i == baseIndex
            let authoredSound = layer.audio.isActive

            if !calm {
                lockRhythm(&layer.rhythm, feel: feel, bpm: bpm)
                lockMotion(&layer.motion, feel: feel, bpm: bpm)
            }

            if !authoredSound {
                if calm || feel == .glide {
                    if isBase { layer.audio = swell(intensity: calm ? 0.12 : 0.18) }
                } else if layer.events == nil {
                    layer.audio = punch(feel: feel, base: isBase, layer: layer, beat: beat)
                }
            }

            if feel == .hit, !calm, var events = layer.events {
                syncEvents(&events, beat: beat)
                layer.events = events
            }
            if hits != .together, layer.audio.travel == nil {
                layer.audio.travel = hits
                // Only punches that can move carry it (a swell stays as is).
                if !layer.audio.travels { layer.audio.travel = nil }
            }
            out.layers[i] = layer
        }
        // The room is the band (build 918): with Groove or Hit chosen — even
        // for a slow look (the drums are what was asked for); Calm looks keep
        // breathing, and Glide adds no punches of its own.
        if band, !calm, requested != .glide,
           let split = Composer2Band.split(out, authored: look, baseIndex: baseIndex, beat: beat) {
            return split
        }
        return out
    }

    // MARK: - Musical lengths

    /// The nearest power-of-two count of beats to `seconds` (log-nearest).
    static func beatsFor(seconds: Double, bpm: Double) -> Double {
        let raw = seconds * bpm / 60
        guard raw.isFinite, raw > 0 else { return 1 }
        return Swift.max(1, pow(2, log2(raw).rounded()))
    }

    /// The locked beat count for a cycle of `seconds`, or nil to leave it free.
    static func lockedBeats(seconds: Double, feel: Feel, bpm: Double) -> Double? {
        let raw = seconds * bpm / 60
        guard raw.isFinite, raw > 0, raw <= longestLockedBeats * 1.0001 else { return nil }
        let beats = Swift.min(longestLockedBeats, beatsFor(seconds: seconds, bpm: bpm))
        if feel == .glide {
            let ratio = beats * 60 / bpm / seconds
            guard abs(ratio - 1) <= glideTolerance else { return nil }
        }
        return beats
    }

    private static let lockableShapes: Set<Composer2Rhythm.Shape> = [.breathe, .swell, .pulse, .heartbeat, .burst]

    private static func lockRhythm(_ rhythm: inout Composer2Rhythm, feel: Feel, bpm: Double) {
        guard rhythm.quantizeBeats <= 0, lockableShapes.contains(rhythm.shape),
              let beats = lockedBeats(seconds: rhythm.sanitizedPeriod, feel: feel, bpm: bpm) else { return }
        rhythm.quantizeBeats = beats
    }

    private static func lockMotion(_ motion: inout Composer2Motion, feel: Feel, bpm: Double) {
        guard motion.quantizeBeats <= 0, motion.kind != .static else { return }
        if motion.kind == .march {
            // One light step per musical length: a beat when the authored
            // step is near a beat, two when it is near two, and so on.
            guard let perStep = lockedBeats(seconds: motion.stepSeconds, feel: feel, bpm: bpm) else { return }
            motion.quantizeBeats = perStep * Double(motion.patternLength)
        } else if let beats = lockedBeats(seconds: motion.sanitizedPeriod, feel: feel, bpm: bpm) {
            motion.quantizeBeats = beats
        }
    }

    /// Every cycle at least `slowCycleSeconds` and no events: a slow look.
    static func isSlow(_ look: Composer2Composition) -> Bool {
        let layers = look.layers.filter(\.contributes)
        guard !layers.isEmpty else { return false }
        for layer in layers {
            if layer.events != nil { return false }
            if lockableShapes.contains(layer.rhythm.shape), layer.rhythm.sanitizedPeriod < slowCycleSeconds { return false }
            if layer.motion.kind != .static, layer.motion.sanitizedPeriod < slowCycleSeconds { return false }
        }
        return true
    }

    // MARK: - Sound

    /// A gentle brightness swell with the music's loudness (adds light, never
    /// dims the look in quiet passages).
    static func swell(intensity: Double) -> Composer2AudioModulation {
        Composer2AudioModulation(source: .amplitude, brightnessMode: .punch, sensitivity: 0.6,
                                 threshold: 0.12, smoothing: 0.9, intensity: intensity,
                                 targets: [.brightness])
    }

    /// A punch on every predicted beat, decaying over about a third of a
    /// beat, with a palette step every bar (Groove) or every two beats (Hit).
    static func punch(feel: Feel, base: Bool, layer: Composer2Layer, beat: Double) -> Composer2AudioModulation {
        let intensity: Double
        switch feel {
        case .glide: intensity = 0
        case .groove: intensity = base ? 0.3 : 0.45
        case .hit: intensity = base ? 0.6 : 0.7
        }
        // punchDecayTau = 0.08 + punchDecay × 0.52 seconds.
        let tau = Composer2Math.clamp(0.35 * beat, 0.08, 0.6)
        let stops = layer.color.sanitizedStops.count
        var targets: Set<Composer2AudioModulation.Target> = [.brightness]
        if stops >= 2, layer.color.distribution != .brightness { targets.insert(.palettePosition) }
        return Composer2AudioModulation(source: .beat, brightnessMode: .punch, sensitivity: 0.7, threshold: 0.1,
                                        smoothing: 0, intensity: intensity, targets: targets,
                                        quantizeBeats: feel == .hit ? 2 : 4,
                                        paletteStep: stops >= 2 ? 1 / Double(stops) : 0,
                                        punchDecay: (tau - 0.08) / 0.52)
    }

    // MARK: - Events on the beat

    /// Opportunities move from a random schedule onto the beat grid —
    /// twinkles on beats, flashes and glows every two, strikes and fireworks
    /// on the one — with the chance scaled so the look keeps its own average
    /// rate.
    static func syncEvents(_ events: inout Composer2EventSpec, beat: Double) {
        let every: Double
        switch events.shape {
        case .twinkle: every = 1
        case .flash, .glow: every = 2
        case .lightning, .firework: every = 4
        }
        let authoredGap = Swift.max(0.05, events.meanDelay)
        let gridGap = every * beat
        events.beatSync = every
        events.probability = Composer2Math.clamp01(events.probability * gridGap / authoredGap)
        // The random schedule steps aside; the grid brings the opportunities.
        events.timing = .fixed
        events.interval = 3600
    }
}
