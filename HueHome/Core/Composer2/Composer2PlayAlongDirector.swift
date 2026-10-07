// Composer2PlayAlongDirector.swift
// ChromaGlow — Composer 2 (Play Along P3/P4)
//
// When the play-along version of a look takes over, and when it lets go.
// Turning Play Along on is a request; the room changes only once the clock
// has a beat it trusts, and then ON THE ONE: the look crossfades into its
// play-along self over the last eighth of a bar and lands on the next bar
// line (half bar or beat when the bar is less sure). A dropout coasts — the
// grid keeps running at the last tempo — and after 20 s with no usable beat
// the look glides back to itself. A new song's tempo re-derives the look.
//
// Pure value type, ticked by the time a frame will be SHOWN (hostNow plus
// the render lead) and the clock snapshot — the core reads no clocks.

import Foundation

struct Composer2PlayAlongDirector: Equatable {

    enum Phase: Equatable {
        /// The plain look plays.
        case idle
        /// Crossfading in; full at `landing`.
        case engaging(landing: Double, preroll: Double)
        /// The play-along look plays.
        case engaged
        /// Crossfading out; gone at `landing`.
        case releasing(landing: Double, preroll: Double, from: Double)
    }

    struct Mix: Equatable {
        /// 0 = plain look, 1 = play-along look.
        var weight: Double
        /// The tempo the play-along look is derived at.
        var bpm: Double
    }

    /// The user wants Play Along (the button is on).
    var requested = false
    private(set) var phase: Phase = .idle
    private(set) var bpm: Double = 0
    private var unusableSince: Double?

    /// The clock's phase confidence that counts as a beat to play along to.
    static let usablePhaseConfidence = 0.5
    /// Seconds without a usable beat before the look glides back.
    static let releaseAfter = 20.0
    /// A glide back without a grid to land on.
    static let releaseFade = 2.0
    /// A tempo this far from the derived one (outside double/half) re-derives.
    static let retempoTolerance = 0.03

    var isActive: Bool { phase != .idle }

    static func usable(_ beat: BeatSnapshot, at t: Double) -> Bool {
        t > 0 && beat.bpm > 0 && beat.beatInterval.isFinite && beat.phaseConfidence >= usablePhaseConfidence
    }

    /// Advance to `t` (the moment this frame is shown).
    mutating func update(at t: Double, beat: BeatSnapshot) -> Mix {
        let usable = Self.usable(beat, at: t)
        if usable { unusableSince = nil } else if unusableSince == nil { unusableSince = t }

        switch phase {
        case .idle:
            if requested, usable { engage(at: t, beat: beat) }

        case .engaging(let landing, let preroll):
            if !requested {
                release(at: t, beat: beat, from: Composer2Quantizer.weight(at: t, landing: landing, preroll: preroll))
            } else if t >= landing {
                phase = .engaged
            }

        case .engaged:
            if !requested {
                release(at: t, beat: beat, from: 1)
            } else if let since = unusableSince, t - since >= Self.releaseAfter {
                release(at: t, beat: .none, from: 1)
            } else if usable, abs(beat.bpm / bpm - 1) > Self.retempoTolerance {
                // A new song: re-derive at its tempo (on the next frame).
                bpm = beat.bpm
            }

        case .releasing(let landing, _, _):
            if requested, usable {
                engage(at: t, beat: beat)
            } else if t >= landing {
                phase = .idle
            }
        }
        return Mix(weight: weight(at: t), bpm: bpm)
    }

    private mutating func engage(at t: Double, beat: BeatSnapshot) {
        bpm = beat.bpm
        if let landing = Composer2Quantizer.landing(after: t, beat: beat) {
            phase = .engaging(landing: landing.time, preroll: Composer2Quantizer.preroll(for: beat))
        } else {
            phase = .engaging(landing: t + 0.25, preroll: 0.25)
        }
    }

    private mutating func release(at t: Double, beat: BeatSnapshot, from current: Double) {
        guard current > 0 else {
            phase = .idle
            return
        }
        if Self.usable(beat, at: t), let landing = Composer2Quantizer.landing(after: t, beat: beat) {
            phase = .releasing(landing: landing.time, preroll: Composer2Quantizer.preroll(for: beat), from: current)
        } else {
            phase = .releasing(landing: t + Self.releaseFade, preroll: Self.releaseFade, from: current)
        }
    }

    /// The play-along weight at `t`.
    func weight(at t: Double) -> Double {
        switch phase {
        case .idle: return 0
        case .engaged: return 1
        case .engaging(let landing, let preroll):
            return Composer2Quantizer.weight(at: t, landing: landing, preroll: preroll)
        case .releasing(let landing, let preroll, let from):
            return from * (1 - Composer2Quantizer.weight(at: t, landing: landing, preroll: preroll))
        }
    }

    /// Back to the plain look at once (session stop, look switch).
    mutating func reset() {
        phase = .idle
        bpm = 0
        unusableSince = nil
    }
}
