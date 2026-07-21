// ArtworkPaletteTests.swift
// HueHome Pro — Unit Tests
//
// ArtworkPaletteExtractor (music integration R1): gamut-C membership with
// re-clamp stability (SiriColorTable idiom), determinism, population
// ordering, degenerate images, and the demo-artwork integration path.

import XCTest
import CoreGraphics
@testable import HueHome

@MainActor
final class ArtworkPaletteTests: XCTestCase {

    // MARK: - Synthetic images

    /// Solid-color / striped RGBA8 test images, drawn with exact fills.
    private func makeImage(width: Int = 64, height: Int = 64,
                           draw: (CGContext, Int, Int) -> Void) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        draw(ctx, width, height)
        return ctx.makeImage()!
    }

    private func fill(_ ctx: CGContext, rect: CGRect, r: Double, g: Double, b: Double, a: Double = 1) {
        // srgbRed: CGColor(red:...) builds GENERIC RGB and silently shifts
        // the components on conversion — the extractor then sees different
        // sRGB values than the test's expected-xy math uses.
        ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: a))
        ctx.fill(rect)
    }

    // MARK: - Gamut safety

    func testEveryEmittedColorIsInsideGamutC() {
        // Saturated primaries stress the clamp — sRGB blue sits far outside gamut C.
        let image = makeImage { ctx, w, h in
            fill(ctx, rect: CGRect(x: 0, y: 0, width: w, height: h / 3), r: 1, g: 0, b: 0)
            fill(ctx, rect: CGRect(x: 0, y: h / 3, width: w, height: h / 3), r: 0, g: 1, b: 0)
            fill(ctx, rect: CGRect(x: 0, y: 2 * h / 3, width: w, height: h / 3), r: 0, g: 0, b: 1)
        }
        guard let palette = ArtworkPaletteExtractor.extract(from: image) else {
            return XCTFail("saturated image must yield a palette")
        }
        var colors = [palette.color1, palette.color2]
        if let c3 = palette.color3 { colors.append(c3) }
        for color in colors {
            // Re-clamp stability: a clamped point re-clamps to itself (1e-9,
            // the SiriColorTable idiom — never exact equality on the edge).
            let re = HueColorUtils.clampXYToGamut(x: color.x, y: color.y, gamut: .c)
            XCTAssertEqual(re.x, color.x, accuracy: 1e-9)
            XCTAssertEqual(re.y, color.y, accuracy: 1e-9)
        }
    }

    // MARK: - Determinism + clustering

    func testExtractionIsDeterministic() {
        let image = makeImage { ctx, w, h in
            fill(ctx, rect: CGRect(x: 0, y: 0, width: w, height: h / 2), r: 0.9, g: 0.4, b: 0.1)
            fill(ctx, rect: CGRect(x: 0, y: h / 2, width: w, height: h / 2), r: 0.1, g: 0.3, b: 0.8)
        }
        let a = ArtworkPaletteExtractor.extract(from: image)
        let b = ArtworkPaletteExtractor.extract(from: image)
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b, "same image must always yield the same palette")
    }

    func testTwoToneImageYieldsBothHues() {
        let image = makeImage { ctx, w, h in
            fill(ctx, rect: CGRect(x: 0, y: 0, width: w, height: h / 2), r: 0.9, g: 0.2, b: 0.1)
            fill(ctx, rect: CGRect(x: 0, y: h / 2, width: w, height: h / 2), r: 0.1, g: 0.4, b: 0.9)
        }
        guard let palette = ArtworkPaletteExtractor.extract(from: image) else {
            return XCTFail()
        }
        let expectedWarm = HueColorUtils.clampXYToGamut(
            x: HueColorUtils.xyFrom(red: 0.9, green: 0.2, blue: 0.1).x,
            y: HueColorUtils.xyFrom(red: 0.9, green: 0.2, blue: 0.1).y, gamut: .c)
        let expectedCool = HueColorUtils.clampXYToGamut(
            x: HueColorUtils.xyFrom(red: 0.1, green: 0.4, blue: 0.9).x,
            y: HueColorUtils.xyFrom(red: 0.1, green: 0.4, blue: 0.9).y, gamut: .c)
        let got = [palette.color1, palette.color2]
        XCTAssertTrue(
            got.contains { abs($0.x - expectedWarm.x) < 0.02 && abs($0.y - expectedWarm.y) < 0.02 },
            "warm half missing: got \(got), expected \(expectedWarm)")
        XCTAssertTrue(
            got.contains { abs($0.x - expectedCool.x) < 0.02 && abs($0.y - expectedCool.y) < 0.02 },
            "cool half missing: got \(got) c3=\(String(describing: palette.color3)), expected \(expectedCool)")
    }

    func testDominantColorComesFirst() {
        // 75% orange, 25% teal → color1 must be the orange.
        let image = makeImage { ctx, w, h in
            fill(ctx, rect: CGRect(x: 0, y: 0, width: w, height: h), r: 0.95, g: 0.55, b: 0.1)
            fill(ctx, rect: CGRect(x: 0, y: 0, width: w, height: h / 4), r: 0.1, g: 0.7, b: 0.6)
        }
        guard let palette = ArtworkPaletteExtractor.extract(from: image) else {
            return XCTFail()
        }
        let orange = HueColorUtils.xyFrom(red: 0.95, green: 0.55, blue: 0.1)
        XCTAssertEqual(palette.color1.x, orange.x, accuracy: 0.03,
                       "the most common color must lead the palette")
    }

    // MARK: - Degenerate inputs

    func testAllBlackImageReturnsNil() {
        let image = makeImage { ctx, w, h in
            fill(ctx, rect: CGRect(x: 0, y: 0, width: w, height: h), r: 0, g: 0, b: 0)
        }
        XCTAssertNil(ArtworkPaletteExtractor.extract(from: image),
                     "nothing a bulb can show → no palette")
    }

    func testFullyTransparentImageReturnsNil() {
        let image = makeImage { _, _, _ in }   // nothing drawn
        XCTAssertNil(ArtworkPaletteExtractor.extract(from: image))
    }

    func testUniformImageYieldsSolidGradient() {
        let image = makeImage { ctx, w, h in
            fill(ctx, rect: CGRect(x: 0, y: 0, width: w, height: h), r: 0.5, g: 0.2, b: 0.7)
        }
        guard let palette = ArtworkPaletteExtractor.extract(from: image) else {
            return XCTFail()
        }
        XCTAssertEqual(palette.color1, palette.color2,
                       "one distinct color → color2 mirrors color1")
    }

    func testOnePixelImageWorks() {
        let image = makeImage(width: 1, height: 1) { ctx, _, _ in
            fill(ctx, rect: CGRect(x: 0, y: 0, width: 1, height: 1), r: 0.9, g: 0.3, b: 0.2)
        }
        // 1×1 upsamples to 32×32 identical pixels — a valid single-color palette.
        XCTAssertNotNil(ArtworkPaletteExtractor.extract(from: image))
    }

    // MARK: - Demo artwork integration

    func testDemoTrackArtworkProducesPalettes() {
        for track in MockMusicSource.playlist {
            guard let art = MockMusicSource.generatedArtwork(for: track) else {
                return XCTFail("demo artwork must render for \(track.title)")
            }
            XCTAssertNotNil(ArtworkPaletteExtractor.extract(from: art),
                            "demo artwork must yield a palette for \(track.title)")
        }
    }
}
