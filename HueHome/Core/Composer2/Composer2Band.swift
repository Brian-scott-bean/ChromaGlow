// Composer2Band.swift
// ChromaGlow — Core/Composer2 ("the room is the band", step 4: build 918)
//
// Play Along → The room is the band: the look's base layer is split across
// the room's heights (Composer2LightRoles), the way a lighting designer
// splits a stage:
//  • low lights (floor lamps)  — punch on the KICK, and glow while a BASS
//    LINE plays (build 919: rising and falling over about a second — never
//    a flash);
//  • middle lights (eye height) — the look itself, swelling gently with the
//    music (a held wash);
//  • high lights (ceiling)     — punch on the SNARE, plus a hi-hat shimmer
//    kept under the size a flash is counted from (never a flash on every hat).
// Accent layers keep their own cycles (locked to the bars) but don't punch
// on the beat as well; events keep the feel's timing.
//
// One shared budget: every band drum punch — kick and snare, whichever
// lights they land on — claims the room's flash budget, and two are never
// closer than the flash gate's own minimum (0.34 s, so never more than 3 a
// second). The engine thins the drums musically instead of the gate cutting
// frames. A kick wins a tie with a snare. Dim Flashing Lights, the flash
// shaper and the wire gate stay the authority after this.
//
// Pure and deterministic, like Composer2PlayAlong.

import Foundation

enum Composer2Band {
    /// The room-wide gap between two band drum flashes (the onset ledger's).
    static let minGap = BeatMath.FlashSafety.minOnsetLedgerPeriod
    /// A hi-hat adds at most this — under the 0.10 rise a flash counts from.
    static let hatShimmer = 0.08
    /// The bass line's glow on the low lights (build 919): at most this much
    /// light, eased in and out (smoothing τ 0.25 s on top of the lane's own
    /// ~1 s), so even a bass line starting from nothing rises ~0.02 per frame.
    static let bassGlow = 0.25
    static let kickIntensity = 0.7
    static let snareIntensity = 0.6

    /// The look split across low / middle / high, or nil when its base layer
    /// can't be (it has its own mask, events or sound): the feel's look
    /// plays as it is. `played` = the look after the feel; `authored` = as
    /// saved (to tell which layers listened already).
    static func split(_ played: Composer2Composition, authored: Composer2Composition, baseIndex: Int?,
                      beat: Double) -> Composer2Composition? {
        guard let bi = baseIndex, bi < played.layers.count, bi < authored.layers.count else { return nil }
        let base = played.layers[bi]
        let original = authored.layers[bi]
        guard original.mask.kind == .wholeRoom, original.events == nil, !original.audio.isActive,
              base.contributes else { return nil }
        let tau = Composer2Math.clamp(0.3 * beat, 0.08, 0.5)
        let decay = (tau - 0.08) / 0.52

        var middle = base
        middle.mask = .role([.middle])
        middle.audio = Composer2PlayAlong.swell(intensity: 0.18)

        var low = base
        low.id = layerID(base.id, salt: 1)
        low.name = base.name + " · kick"
        low.mask = .role([.low])
        low.audio = drum(.kick, intensity: kickIntensity, decay: decay, layer: base)

        var high = base
        high.id = layerID(base.id, salt: 2)
        high.name = base.name + " · snare"
        high.mask = .role([.high])
        high.audio = drum(.snare, intensity: snareIntensity, decay: decay, layer: base)

        // The shimmer: only what a hat adds, on top of the high lights.
        var hats = base
        hats.id = layerID(base.id, salt: 3)
        hats.name = base.name + " · hi-hat"
        hats.mask = .role([.high])
        hats.blend = .addLighten
        hats.rhythm = Composer2Rhythm(shape: .steady, maxBrightness: 0)
        hats.audio = Composer2AudioModulation(source: .hat, brightnessMode: .punch, sensitivity: 0.7, threshold: 0.1,
                                              smoothing: 0, intensity: hatShimmer, targets: [.brightness],
                                              punchDecay: 0)

        // The bass line: a slow glow on the low lights while one plays.
        var bassLine = base
        bassLine.id = layerID(base.id, salt: 4)
        bassLine.name = base.name + " · bass line"
        bassLine.mask = .role([.low])
        bassLine.blend = .addLighten
        bassLine.rhythm = Composer2Rhythm(shape: .steady, maxBrightness: 0)
        bassLine.audio = Composer2AudioModulation(source: .bassLine, brightnessMode: .punch, sensitivity: 0.7,
                                                  threshold: 0.1, smoothing: 0.5, intensity: bassGlow,
                                                  targets: [.brightness])

        var out = played
        for i in out.layers.indices where i != bi && out.layers[i].events == nil && !authored.layers[i].audio.isActive {
            // An accent's own cycles stay locked to the bars; the drums are the
            // band's punches now.
            out.layers[i].audio = authored.layers[i].audio
        }
        out.layers.replaceSubrange(bi...bi, with: [middle, low, high, hats, bassLine])
        return out
    }

    private static func drum(_ source: Composer2AudioModulation.Source, intensity: Double, decay: Double,
                             layer: Composer2Layer) -> Composer2AudioModulation {
        let stops = layer.color.sanitizedStops.count
        var targets: Set<Composer2AudioModulation.Target> = [.brightness]
        if stops >= 2, layer.color.distribution != .brightness { targets.insert(.palettePosition) }
        var m = Composer2AudioModulation(source: source, brightnessMode: .punch, sensitivity: 0.7, threshold: 0.1,
                                         smoothing: 0, intensity: intensity, targets: targets,
                                         paletteStep: stops >= 2 ? 1 / Double(stops) : 0, punchDecay: decay)
        m.sharesFlashBudget = true
        return m
    }

    /// A stable id for a split copy of `base` (the engine keeps per-layer
    /// state by id; the same look always splits into the same ids).
    static func layerID(_ base: UUID, salt: UInt64) -> UUID {
        let a = Composer2Hash.mix(Composer2Hash.seed(from: base), 0xBA4D_0000 &+ salt)
        let b = Composer2Hash.mix(a, 0x5EED_BA4D &+ salt)
        func bytes(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: v >> (8 * UInt64($0))) } }
        var u = bytes(a) + bytes(b)
        u[6] = (u[6] & 0x0F) | 0x40   // version 4 layout, deterministic content
        u[8] = (u[8] & 0x3F) | 0x80
        return UUID(uuid: (u[0], u[1], u[2], u[3], u[4], u[5], u[6], u[7],
                           u[8], u[9], u[10], u[11], u[12], u[13], u[14], u[15]))
    }

    // MARK: - The shared budget

    /// Admit a band drum flash at `time` (its hit time), or not: never
    /// within `minGap` of the last one admitted. Keeps the last two seconds.
    static func admit(_ time: Double, ledger: inout [Double]) -> Bool {
        guard time.isFinite else { return false }
        if let last = ledger.last, time < last + minGap { return false }
        ledger.append(time)
        if let first = ledger.first, time - first > 2 { ledger.removeAll { time - $0 > 2 } }
        return true
    }

    /// `audio` as one band layer sees it: its drum is only the admitted hit
    /// (heard, nothing predicted on top).
    static func features(_ audio: AudioFeatures, admitted: (time: Double, strength: Float),
                         source: Composer2AudioModulation.Source) -> AudioFeatures {
        var f = audio
        f.groove = .none
        switch source {
        case .kick: f.lastKickAt = admitted.time; f.kickStrength = admitted.strength
        case .snare: f.lastSnareAt = admitted.time; f.snareStrength = admitted.strength
        case .hat: f.lastHatAt = admitted.time; f.hatStrength = admitted.strength
        default: break
        }
        return f
    }
}
