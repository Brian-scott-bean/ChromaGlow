// Composer2LabAlbumPaletteTests.swift
// HueHome Pro — Unit Tests (Play Along P6)
//
// Song colors: album art → swatches by role (OKLab, chroma-weighted; a
// small vivid accent wins its role; greyscale art becomes tinted whites),
// the transform that paints a look with them without touching its
// structure — every built-in look keeps its stops, positions, whites,
// motion, rhythm and sound — and a new song's colours landing on the one.

import CoreGraphics
import XCTest
@testable import HueHome

final class Composer2LabAlbumPaletteTests: XCTestCase {

    private struct Fill {
        var x0 = 0.0, x1 = 1.0, y0 = 0.0, y1 = 1.0
        var r: Double, g: Double, b: Double
    }

    private func image(_ fills: [Fill], size: Int = 64) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let s = Double(size)
        for f in fills {
            ctx.setFillColor(CGColor(colorSpace: space, components: [f.r, f.g, f.b, 1])!)
            ctx.fill(CGRect(x: f.x0 * s, y: f.y0 * s, width: (f.x1 - f.x0) * s, height: (f.y1 - f.y0) * s))
        }
        return ctx.makeImage()!
    }

    private func xy(_ r: Double, _ g: Double, _ b: Double) -> Composer2XY {
        let p = HueColorUtils.xyFrom(red: r, green: g, blue: b)
        return Composer2XY(x: p.x, y: p.y).clamped(to: .c)
    }

    private func hueDistance(_ a: Composer2XY, _ b: Composer2XY) -> Double {
        let ha = Composer2ColorMath.lab(fromXY: a).hue, hb = Composer2ColorMath.lab(fromXY: b).hue
        var d = abs(ha - hb).truncatingRemainder(dividingBy: 2 * .pi)
        if d > .pi { d = 2 * .pi - d }
        return d * 180 / .pi
    }

    // MARK: - Extraction

    func testASolidCoverIsOneColour() throws {
        let s = try XCTUnwrap(ArtworkPaletteExtractor.swatches(from: image([Fill(r: 0.9, g: 0.2, b: 0.1)])))
        XCTAssertFalse(s.isGreyscale)
        XCTAssertNil(s.accent)
        XCTAssertTrue(s.support.isEmpty)
        let want = xy(0.9, 0.2, 0.1)
        XCTAssertEqual(s.dominant.xy.x, want.x, accuracy: 0.01)
        XCTAssertEqual(s.dominant.xy.y, want.y, accuracy: 0.01)
    }

    func testATwoColourSplitGivesBoth() throws {
        let s = try XCTUnwrap(ArtworkPaletteExtractor.swatches(from: image([
            Fill(x0: 0, x1: 0.6, r: 0.1, g: 0.3, b: 0.9),
            Fill(x0: 0.6, x1: 1, r: 0.95, g: 0.8, b: 0.1),
        ])))
        XCTAssertLessThan(hueDistance(s.dominant.xy, xy(0.1, 0.3, 0.9)), 10, "the larger area is dominant")
        let other = try XCTUnwrap(s.accent ?? s.support.first)
        XCTAssertLessThan(hueDistance(other.xy, xy(0.95, 0.8, 0.1)), 10)
    }

    func testASmallVividAccentWinsItsRole() throws {
        // A dull brown field with a small vivid magenta badge.
        let s = try XCTUnwrap(ArtworkPaletteExtractor.swatches(from: image([
            Fill(r: 0.5, g: 0.44, b: 0.28),
            Fill(x0: 0.72, x1: 0.97, y0: 0.72, y1: 0.97, r: 0.95, g: 0.1, b: 0.8),
        ])))
        XCTAssertLessThan(hueDistance(s.dominant.xy, xy(0.5, 0.44, 0.28)), 12, "the field is the dominant colour")
        let accent = try XCTUnwrap(s.accent, "the badge is the accent")
        XCTAssertLessThan(hueDistance(accent.xy, xy(0.95, 0.1, 0.8)), 12)
    }

    func testGreyscaleArtBecomesTintedWhites() throws {
        let warm = try XCTUnwrap(ArtworkPaletteExtractor.swatches(from: image([
            Fill(x0: 0, x1: 0.5, r: 0.62, g: 0.6, b: 0.55),
            Fill(x0: 0.5, x1: 1, r: 0.3, g: 0.29, b: 0.27),
        ])))
        XCTAssertTrue(warm.isGreyscale)
        XCTAssertGreaterThan(warm.dominant.xy.x, 0.4, "warm greys light the room warm white")
        let cool = try XCTUnwrap(ArtworkPaletteExtractor.swatches(from: image([Fill(r: 0.5, g: 0.53, b: 0.58)])))
        XCTAssertTrue(cool.isGreyscale)
        XCTAssertLessThan(cool.dominant.xy.x, 0.34, "cool greys light it daylight white")
    }

    func testABlackCoverHasNothingToShow() {
        XCTAssertNil(ArtworkPaletteExtractor.swatches(from: image([Fill(r: 0, g: 0, b: 0)])))
    }

    func testExtractionIsDeterministic() {
        let art = image([Fill(x0: 0, x1: 0.5, r: 0.2, g: 0.7, b: 0.5), Fill(x0: 0.5, x1: 1, r: 0.8, g: 0.3, b: 0.6)])
        XCTAssertEqual(ArtworkPaletteExtractor.swatches(from: art), ArtworkPaletteExtractor.swatches(from: art))
    }

    // MARK: - The transform

    private let swatches = ArtworkSwatches(
        dominant: .init(xy: Composer2XY(x: 0.17, y: 0.07), chroma: 0.3, share: 0.6),
        accent: .init(xy: Composer2XY(x: 0.6, y: 0.35), chroma: 0.25, share: 0.1),
        support: [.init(xy: Composer2XY(x: 0.2, y: 0.6), chroma: 0.2, share: 0.3)],
        isGreyscale: false)

    func testPaintingKeepsEveryLooksStructure() {
        let painted = Set([swatches.dominant.xy, swatches.accent!.xy, swatches.support[0].xy].map { $0.clamped(to: .c) })
        for look in Composer2PresetLibrary.all {
            let out = Composer2AlbumPalette.apply(look, swatches: swatches)
            XCTAssertEqual(out.id, look.id)
            XCTAssertEqual(out.layers.map(\.id), look.layers.map(\.id), look.name)
            for (a, b) in zip(look.layers, out.layers) {
                XCTAssertEqual(a.motion, b.motion, look.name)
                XCTAssertEqual(a.rhythm, b.rhythm, look.name)
                XCTAssertEqual(a.audio, b.audio, look.name)
                XCTAssertEqual(a.mask, b.mask, look.name)
                XCTAssertEqual(a.color.stops.count, b.color.stops.count, "\(look.name): stop count")
                XCTAssertEqual(a.color.stops.map(\.position), b.color.stops.map(\.position), look.name)
                XCTAssertEqual(a.color.saturation, b.color.saturation)
                XCTAssertEqual(a.color.warmth, b.color.warmth)
                XCTAssertEqual(a.color.distribution, b.color.distribution)
                XCTAssertEqual(a.color.interpolation, b.color.interpolation)
                for (sa, sb) in zip(a.color.stops, b.color.stops) {
                    if Composer2AlbumPalette.isWhite(sa.xy) {
                        XCTAssertEqual(sa, sb, "\(look.name): whites stay white")
                    } else {
                        XCTAssertTrue(painted.contains(sb.xy), "\(look.name): painted from the art")
                    }
                }
            }
        }
    }

    func testTheBaseWearsTheDominantAndFlashesTheAccent() {
        var base = Composer2Layer.blank(name: "Base")
        base.color = Composer2ColorSource(stops: [Composer2PaletteStop(x: 0.64, y: 0.33)])
        var storm = Composer2Layer.blank(name: "Storm")
        storm.events = Composer2EventSpec(timing: .fixed, interval: 4, probability: 1, burstMin: 1, burstMax: 1,
                                          durationMin: 0.1, durationMax: 0.1, shape: .flash)
        storm.events?.color = Composer2XY(x: 0.3, y: 0.6)
        let look = Composer2Composition(name: "Two", createdAt: Date(timeIntervalSince1970: 0), layers: [base, storm])
        let out = Composer2AlbumPalette.apply(look, swatches: swatches)
        XCTAssertEqual(out.layers[0].color.stops[0].xy, swatches.dominant.xy.clamped(to: .c))
        XCTAssertEqual(out.layers[1].events?.color, swatches.accent!.xy)
    }

    func testTheHueOrderOfTheStopsIsKept() {
        // Authored red → green → blue round the wheel; painted, the stop that
        // was first round the wheel gets the art's first-round colour.
        var layer = Composer2Layer.blank(name: "Wheel")
        layer.color = Composer2ColorSource(stops: [Composer2PaletteStop(x: 0.64, y: 0.33),
                                                   Composer2PaletteStop(x: 0.3, y: 0.6),
                                                   Composer2PaletteStop(x: 0.15, y: 0.06)])
        let look = Composer2Composition(name: "Wheel", createdAt: Date(timeIntervalSince1970: 0), layers: [layer])
        let out = Composer2AlbumPalette.apply(look, swatches: swatches)
        func rank(_ stops: [Composer2PaletteStop]) -> [Int] {
            let hues = stops.map { Composer2ColorMath.lab(fromXY: $0.xy).hue }
            return hues.indices.sorted { hues[$0] < hues[$1] }
        }
        XCTAssertEqual(rank(out.layers[0].color.stops), rank(look.layers[0].color.stops))
    }

    // MARK: - On the one

    func testANewSongsColoursLandOnTheOne() {
        var layer = Composer2Layer.blank(name: "Solid")
        layer.color = Composer2ColorSource(stops: [Composer2PaletteStop(x: 0.64, y: 0.33)], distribution: .uniform)
        layer.motion = Composer2Motion(kind: .static)
        let output = Composer2LiveOutput(composition: Composer2Composition(
            name: "Solid", createdAt: Date(timeIntervalSince1970: 0), layers: [layer]))
        output.setPreviewGeometry(.linear(count: 1))
        let beat = BeatSnapshot(bpm: 120, beatEpoch: 1000, beatsPerBar: 4, phaseConfidence: 0.9, barConfidence: 0.9)
        func x(at host: Double) -> Double {
            output.evaluate(time: host - 1000, beat: beat, hostNow: host).first!.x
        }
        XCTAssertGreaterThan(x(at: 1000.2), 0.5)
        output.songSwatches = swatches
        XCTAssertGreaterThan(x(at: 1000.5), 0.5, "the room keeps its colours until the one")
        XCTAssertGreaterThan(x(at: 1001.6), 0.5)
        XCTAssertLessThan(x(at: 1002.0), 0.25, "the song's colours on the one")
        output.songSwatches = nil
        XCTAssertLessThan(x(at: 1002.5), 0.25)
        XCTAssertGreaterThan(x(at: 1004.0), 0.5, "and back to the look's own on the next one")
    }
}
