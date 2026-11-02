// Composer2Quantizer.swift
// ChromaGlow — Composer 2 (Play Along P4)
//
// "On the One": where the next musical boundary falls on the shared beat
// grid. A change asked for now lands on the next bar line when the clock is
// sure where bars start; on the next half bar (beat 1 or 3) when it only
// half knows; on the next beat when it knows the beat but not the bar. The
// wait is never longer than one bar. Pure — every time is handed in (the
// Composer 2 core reads no clocks).

import Foundation

enum Composer2Quantizer {

    enum Grid: Equatable {
        case bar, halfBar, beat
    }

    /// Bar confidence needed to land on bar lines / half bars.
    static let barConfidenceForBar = 0.5
    static let barConfidenceForHalfBar = 0.25
    /// Phase confidence below which there is no grid to land on.
    static let minPhaseConfidence = 0.3

    /// The grid a change can land on with what the clock knows now (nil: no
    /// usable beat — change at once).
    static func grid(for beat: BeatSnapshot) -> Grid? {
        guard beat.bpm > 0, beat.beatInterval.isFinite, beat.phaseConfidence >= minPhaseConfidence else { return nil }
        if beat.barConfidence >= barConfidenceForBar { return .bar }
        if beat.barConfidence >= barConfidenceForHalfBar, beat.beatsPerBar % 2 == 0 { return .halfBar }
        return .beat
    }

    /// Beats per landing unit on `grid`.
    static func unitBeats(_ grid: Grid, beatsPerBar: Int) -> Double {
        switch grid {
        case .bar: return Double(max(1, beatsPerBar))
        case .halfBar: return Double(max(1, beatsPerBar)) / 2
        case .beat: return 1
        }
    }

    /// The first boundary on `grid` strictly after `t`.
    static func nextBoundary(after t: Double, beat: BeatSnapshot, grid: Grid) -> Double? {
        guard beat.bpm > 0, t.isFinite else { return nil }
        let unit = unitBeats(grid, beatsPerBar: beat.beatsPerBar) * beat.beatInterval
        guard unit.isFinite, unit > 0 else { return nil }
        let k = floor((t - beat.beatEpoch) / unit + 1e-9) + 1
        return beat.beatEpoch + k * unit
    }

    /// Crossfade length that ends on a boundary: an eighth of a bar, at most
    /// a quarter second.
    static func preroll(for beat: BeatSnapshot) -> Double {
        guard beat.bpm > 0 else { return 0.25 }
        return min(0.25, beat.beatInterval * Double(max(1, beat.beatsPerBar)) / 8)
    }

    /// Where a change asked for at `t` lands: the first boundary with room for
    /// the preroll before it. nil = no usable grid (change at once).
    static func landing(after t: Double, beat: BeatSnapshot) -> (time: Double, grid: Grid)? {
        guard let grid = grid(for: beat),
              let first = nextBoundary(after: t, beat: beat, grid: grid) else { return nil }
        let preroll = preroll(for: beat)
        if first - t >= preroll { return (first, grid) }
        guard let next = nextBoundary(after: first, beat: beat, grid: grid) else { return nil }
        return (next, grid)
    }

    /// "Land at time T" (build 922): the beat line of the clock's grid
    /// nearest `t` — a staged drop, measured on the tracker's pass, played on
    /// the grid the frames are rendered with. nil = no usable grid.
    static func landing(at t: Double, beat: BeatSnapshot) -> Double? {
        guard t.isFinite, t > 0, grid(for: beat) != nil else { return nil }
        let k = ((t - beat.beatEpoch) / beat.beatInterval).rounded()
        return beat.beatEpoch + k * beat.beatInterval
    }

    /// 0 → 1 crossfade weight at `t` for a change landing at `landing`.
    static func weight(at t: Double, landing: Double, preroll: Double) -> Double {
        guard preroll > 0 else { return t >= landing ? 1 : 0 }
        return Composer2Math.smoothstep(Composer2Math.clamp01((t - (landing - preroll)) / preroll))
    }
}
