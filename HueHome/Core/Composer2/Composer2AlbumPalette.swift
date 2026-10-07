// Composer2AlbumPalette.swift
// ChromaGlow — Composer 2 (Play Along P6: Song colors)
//
// The song's album art paints the look. Every layer keeps its stop count,
// its stop positions and its own hue ORDER — only which colours sit at
// those stops changes, re-assigned from the art's swatches by role: the
// base layer takes the dominant colour, then the support colours; accent
// layers and event flashes take the accent. Near-white stops stay white, so
// a mirror ball and lightning keep their character. Saturation, warmth,
// distribution and interpolation are untouched: the look still moves the
// way it was authored, in the song's colours.
//
// Pure. Cover art is used only while its track plays (Apple 4.5.2(ii)):
// the swatches live on the music session and go with the track.

import Foundation

/// Album art as light, by role (`ArtworkPaletteExtractor.swatches`).
struct ArtworkSwatches: Equatable, Sendable {
    struct Swatch: Equatable, Sendable {
        var xy: Composer2XY
        /// OKLab chroma of the art's colour (0 = grey).
        var chroma: Double
        /// Share of the art's weighted pixels, 0…1.
        var share: Double
    }

    /// The largest colourful area.
    var dominant: Swatch
    /// The colour that stands out — at least 30° of hue from the dominant.
    var accent: Swatch?
    /// The rest, heaviest first.
    var support: [Swatch]
    /// Near-greyscale art: the swatches are tinted whites.
    var isGreyscale: Bool
}

enum Composer2AlbumPalette {

    /// Stops greyer than this (OKLab chroma) are whites and stay as authored.
    static let whiteChroma = 0.04

    static func apply(_ look: Composer2Composition, swatches: ArtworkSwatches) -> Composer2Composition {
        var out = look
        let base = [swatches.dominant] + swatches.support + (swatches.accent.map { [$0] } ?? [])
        let accent = (swatches.accent.map { [$0] } ?? []) + [swatches.dominant] + swatches.support
        let baseIndex = look.layers.firstIndex { $0.contributes && $0.events == nil } ?? 0
        var extraBases = 0
        for i in out.layers.indices {
            let layer = out.layers[i]
            let role: [ArtworkSwatches.Swatch]
            if i == baseIndex {
                role = base
            } else if layer.events == nil && !isAccent(layer) {
                // Another layer that carries the room: start further round
                // the art so the two do not wear the same colours.
                extraBases += 1
                role = Array(base[(extraBases % base.count)...] + base[..<(extraBases % base.count)])
            } else {
                role = accent
            }
            out.layers[i].color.stops = repaint(layer.color.stops, with: role.map(\.xy))
            if var events = out.layers[i].events {
                let flash = (swatches.accent ?? swatches.dominant).xy
                if let color = events.color, !isWhite(color) { events.color = flash }
                if !events.colors.isEmpty {
                    let painted = repaint(events.colors.map { Composer2PaletteStop($0) }, with: accent.map(\.xy))
                    events.colors = painted.map(\.xy)
                }
                out.layers[i].events = events
            }
        }
        return out
    }

    /// A layer that decorates rather than carries the room: masked to some
    /// lights, or added on top.
    private static func isAccent(_ layer: Composer2Layer) -> Bool {
        layer.mask != .wholeRoom || layer.blend != .replace
    }

    static func isWhite(_ xy: Composer2XY) -> Bool {
        Composer2ColorMath.lab(fromXY: xy).chroma < whiteChroma
    }

    /// Chromatic stops take `colors` (priority order) so that the stops'
    /// hue ranking is kept: the stop that was "first round the wheel" gets
    /// the chosen colour that is first round the wheel. More stops than
    /// colours cycle through them.
    static func repaint(_ stops: [Composer2PaletteStop], with colors: [Composer2XY]) -> [Composer2PaletteStop] {
        guard !colors.isEmpty else { return stops }
        let chromatic = stops.indices.filter { !isWhite(stops[$0].xy) }
        guard !chromatic.isEmpty else { return stops }
        let chosen = Array(colors.prefix(chromatic.count))
            .sorted { hue($0) < hue($1) }
        let ranked = chromatic.sorted { a, b in
            let ha = hue(stops[a].xy), hb = hue(stops[b].xy)
            return ha == hb ? a < b : ha < hb
        }
        var out = stops
        for (rank, index) in ranked.enumerated() {
            out[index] = Composer2PaletteStop(chosen[rank % chosen.count].clamped(to: .c), position: stops[index].position)
        }
        return out
    }

    private static func hue(_ xy: Composer2XY) -> Double {
        Composer2ColorMath.lab(fromXY: xy).hue
    }

    /// Stop by stop, `a`'s colours toward `b`'s (OKLab, the short way round
    /// the hue wheel) — a song's colours arriving over the last eighth of a
    /// bar. Everything else is `b`'s; layers whose stops no longer match
    /// (an edit mid-change) simply take `b`'s.
    static func blend(_ a: Composer2Composition, _ b: Composer2Composition, t: Double) -> Composer2Composition {
        let u = Composer2Math.clamp01(t.isFinite ? t : 1)
        if u >= 1 { return b }
        guard a.layers.count == b.layers.count else { return b }
        var out = b
        for i in out.layers.indices {
            let from = a.layers[i].color.stops, to = b.layers[i].color.stops
            if from.count == to.count {
                out.layers[i].color.stops = zip(from, to).map { s, e in
                    Composer2PaletteStop(mixed(s.xy, e.xy, u), position: e.position)
                }
            }
            if let fe = a.layers[i].events, var te = out.layers[i].events {
                if let fc = fe.color, let tc = te.color { te.color = mixed(fc, tc, u) }
                if fe.colors.count == te.colors.count {
                    te.colors = zip(fe.colors, te.colors).map { mixed($0, $1, u) }
                }
                out.layers[i].events = te
            }
        }
        return out
    }

    private static func mixed(_ a: Composer2XY, _ b: Composer2XY, _ t: Double) -> Composer2XY {
        if t <= 0 { return a }
        if t >= 1 { return b }
        return Composer2ColorMath.xy(fromLab: Composer2ColorMath.mixHueArc(Composer2ColorMath.lab(fromXY: a),
                                                                           Composer2ColorMath.lab(fromXY: b), t: t))
    }
}
