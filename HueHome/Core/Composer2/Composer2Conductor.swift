// Composer2Conductor.swift
// ChromaGlow — Core/Composer2 ("it knows what's coming", step 3: build 922)
//
// Play Along → Follow the song: when the song tracker stages a drop (build
// 921, SongEnergy), the Conductor shapes the build the way a lighting
// designer would:
//  • punches every 4 beats in the build's first third, every 2 in the
//    middle, every beat in the last — counted so one lands ON the drop
//    (the quantizer's "land at time T"), whole-room, a little stronger as it
//    climbs;
//  • half a beat before the drop, the room dims — ONLY when the drop is
//    staged with confidence ≥ 0.9 (a wrong blackout is worse than a missed
//    one; research doc §5). A dim is a fall, never a flash; the return at
//    the drop is one rise, which the flash shaper and the wire gate still
//    judge like any other;
//  • the drop's first bar punches on every beat, stronger.
// With no staged drop (or below 0.5), nothing changes. Pure and
// deterministic: the cue is a function of the song structure, the clock's
// grid and the shown time. It runs before the flash shaper, which, with Dim
// Flashing Lights and the wire gate, stays the authority.

import Foundation

struct Composer2ConductorCue: Equatable {
    enum Phase: Int, Equatable {
        case off, early, middle, late, preDrop, drop
    }

    var phase: Phase = .off
    /// Multiplier on Play Along's beat-punch intensity.
    var punchScale: Double = 1
    /// Beat punches every this many beats, counted from `beatAnchor`.
    var beatEvery: Int = 1
    var beatAnchor: Int = 0
    /// Multiplier on the whole room's brightness (1 = none).
    var dim: Double = 1

    static let off = Composer2ConductorCue()

    /// What the derived look depends on (the dim is applied per frame).
    var lookKey: [Int] { [phase == .preDrop ? Phase.late.rawValue : phase.rawValue, beatEvery, beatAnchor,
                          Int((punchScale * 100).rounded())] }
}

enum Composer2Conductor {
    /// A staged drop at least this sure shapes the build.
    static let minConfidence = 0.5
    /// …and at least this sure dims the room before it.
    static let dimConfidence = 0.9
    /// How far the room dims (a multiplier on brightness), over the last half beat.
    static let dimFloor = 0.35
    static let dimBeats = 0.5

    /// The cue at shown-time `t`.
    static func cue(_ song: SongStructure, beat: BeatSnapshot, at t: Double) -> Composer2ConductorCue {
        guard song.hasSong, beat.bpm > 0, beat.beatInterval.isFinite, beat.beatInterval > 0, t.isFinite else { return .off }
        let e = song.energy
        let barSeconds = beat.beatInterval * Double(max(1, beat.beatsPerBar))
        // The drop's first bar: every beat, stronger.
        if e.lastDropAt > 0, t >= e.lastDropAt, t < e.lastDropAt + barSeconds,
           let landing = Composer2Quantizer.landing(at: e.lastDropAt, beat: beat) {
            return Composer2ConductorCue(phase: .drop, punchScale: 1.3, beatEvery: 1,
                                         beatAnchor: beat.beatIndex(at: landing + beat.beatInterval / 4))
        }
        guard e.state == .build, e.dropAt > 0, e.dropConfidence >= minConfidence,
              let drop = Composer2Quantizer.landing(at: e.dropAt, beat: beat) else { return .off }
        let anchor = beat.beatIndex(at: drop + beat.beatInterval / 4)
        if t >= drop {
            // The staged moment: the punch lands on the one; no dim after it.
            return Composer2ConductorCue(phase: .drop, punchScale: 1.3, beatEvery: 1, beatAnchor: anchor)
        }
        let progress = e.buildProgress(at: t)
        var cue: Composer2ConductorCue
        if progress < 1.0 / 3 {
            cue = Composer2ConductorCue(phase: .early, punchScale: 0.8, beatEvery: 4, beatAnchor: anchor)
        } else if progress < 2.0 / 3 {
            cue = Composer2ConductorCue(phase: .middle, punchScale: 0.95, beatEvery: 2, beatAnchor: anchor)
        } else {
            cue = Composer2ConductorCue(phase: .late, punchScale: 1.1, beatEvery: 1, beatAnchor: anchor)
        }
        let dimStart = drop - dimBeats * beat.beatInterval
        if e.dropConfidence >= dimConfidence, t >= dimStart {
            cue.phase = .preDrop
            let into = Composer2Math.clamp01((t - dimStart) / (dimBeats * beat.beatInterval))
            cue.dim = 1 - (1 - dimFloor) * into
        }
        return cue
    }

    /// Play Along's derived look as the cue shapes it: its beat punches
    /// counted every `beatEvery` beats from the anchor, whole-room, scaled.
    /// Drum, band and authored sound layers are left as they are.
    static func apply(_ cue: Composer2ConductorCue, to look: Composer2Composition) -> Composer2Composition {
        guard cue.phase != .off else { return look }
        var out = look
        for i in out.layers.indices where out.layers[i].audio.source == .beat && out.layers[i].audio.isActive {
            var m = out.layers[i].audio
            m.intensity = Composer2Math.clamp01(m.intensity * cue.punchScale)
            m.beatEvery = max(1, cue.beatEvery)
            m.beatAnchor = cue.beatAnchor
            m.travel = .together
            out.layers[i].audio = m
        }
        return out
    }
}
