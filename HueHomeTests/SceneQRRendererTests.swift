// SceneQRRendererTests.swift
// ChromaGlow — scene sharing
//
// The codec tests prove a URL round-trips. These prove the *pixels* do: encode a
// preset, draw the QR, then decode it back out of the bitmap. Without this, a
// change that quietly pushed a payload past QR capacity — or produced a
// transparent, mirrored, or blurred symbol — would still pass every other test.
//
// The oracle is CIDetector, not Vision. The app scans with VisionKit's
// DataScannerViewController, but Vision needs a neural inference context that
// does not exist in the Simulator ("Could not create inference context"), so it
// cannot decode anything here. CIDetector is a pure CoreImage QR decoder, runs
// in the Simulator, and reads the same bitmaps a camera would.

import XCTest
import CoreImage
import UIKit
@testable import HueHome

final class SceneQRRendererTests: XCTestCase {

    private var samplePreset: CompositionPreset {
        CompositionStore.builtInPresets.first { $0.name == "Northern Lights" }
            ?? CompositionStore.builtInPresets[0]
    }

    private lazy var detector = CIDetector(
        ofType: CIDetectorTypeQRCode,
        context: CIContext(),
        options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
    )

    /// Decode a rendered QR straight out of its pixels.
    private func scan(_ image: UIImage) throws -> String? {
        let cgImage = try XCTUnwrap(image.cgImage)
        let features = detector?.features(in: CIImage(cgImage: cgImage))
        return (features as? [CIQRCodeFeature])?.first?.messageString
    }

    // MARK: - End to end

    func testRenderedQRScansBackIntoTheSameScene() throws {
        let preset = samplePreset
        let url = try ScenePayloadCodec.encode(preset)
        let image = try SceneQRRenderer.render(url)

        let scanned = try XCTUnwrap(try scan(image), "the rendered QR could not be decoded")
        XCTAssertEqual(scanned, url.absoluteString)

        let recovered = try ScenePayloadCodec.decode(try XCTUnwrap(URL(string: scanned)))
        XCTAssertEqual(recovered, SharedScene(preset: preset))
    }

    /// The catalog is what users will actually share, so every one of them must
    /// survive the full encode → draw → scan → decode loop.
    func testEveryBuiltInSurvivesTheFullPixelRoundTrip() throws {
        for preset in CompositionStore.builtInPresets {
            let url = try ScenePayloadCodec.encode(preset)
            let image = try SceneQRRenderer.render(url)
            let scanned = try XCTUnwrap(try scan(image), "\(preset.name): unreadable QR")
            let recovered = try ScenePayloadCodec.decode(try XCTUnwrap(URL(string: scanned)))
            XCTAssertEqual(recovered, SharedScene(preset: preset), preset.name)
        }
    }

    // MARK: - Image properties a scanner depends on

    /// The behavioural form of "the QR is opaque". A transparent symbol vanishes
    /// into whatever background the receiving app composites it onto, so draw it
    /// on black and demand it still scans. Asserting on `CGImageAlphaInfo` would
    /// not catch this — UIGraphicsImageRenderer reports `premultipliedFirst`
    /// even for a fully opaque buffer.
    func testRenderedQRStillScansWhenCompositedOnBlack() throws {
        let url = try ScenePayloadCodec.encode(samplePreset)
        let qr = try SceneQRRenderer.render(url, scale: 8)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let onBlack = UIGraphicsImageRenderer(size: qr.size, format: format).image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: qr.size))
            qr.draw(at: .zero)
        }

        XCTAssertEqual(try scan(onBlack), url.absoluteString,
                       "QR is transparent — it disappears on a dark background")
    }

    /// The corner sits inside the quiet zone and must be white, not the code.
    func testQuietZoneIsWhite() throws {
        let url = try ScenePayloadCodec.encode(samplePreset)
        let cgImage = try XCTUnwrap(try SceneQRRenderer.render(url, scale: 8).cgImage)

        let pixels = try XCTUnwrap(cgImage.dataProvider?.data) as Data
        let bytesPerPixel = cgImage.bitsPerPixel / 8
        let corner = (0..<bytesPerPixel).map { pixels[$0] }
        // All-0xFF is white and opaque whatever the channel order happens to be.
        XCTAssertTrue(corner.allSatisfy { $0 == 0xFF }, "quiet zone is not white: \(corner)")
    }

    // MARK: - Capacity

    /// Past capacity the renderer must say so, not hand back a blank square.
    /// The link still works, which is why this is a typed failure and not a trap.
    func testOversizedPayloadReportsTooLargeRatherThanRenderingNothing() {
        let padding = String(repeating: "A", count: SceneQRRenderer.byteCapacityLevelM + 1)
        let url = URL(string: "lightshade://share?d=\(padding)")!

        XCTAssertThrowsError(try SceneQRRenderer.render(url)) { error in
            guard case SceneQRRenderer.Failure.tooLarge(let bytes) = error else {
                return XCTFail("expected .tooLarge, got \(error)")
            }
            XCTAssertGreaterThan(bytes, SceneQRRenderer.byteCapacityLevelM)
        }
    }

    func testDensityFlagTracksTheComfortBudget() throws {
        let small = try ScenePayloadCodec.encode(samplePreset)
        XCTAssertFalse(SceneQRRenderer.isDense(small), "a built-in should scan easily")

        let padding = String(repeating: "A", count: SceneQRRenderer.comfortableByteCount + 100)
        let dense = URL(string: "lightshade://share?d=\(padding)")!
        XCTAssertTrue(SceneQRRenderer.isDense(dense))
    }

    func testRenderIsUpscaledForScannability() throws {
        let url = try ScenePayloadCodec.encode(samplePreset)
        let image = try SceneQRRenderer.render(url, scale: 10)
        // A real preset is a ~95-module symbol, so 10x is comfortably past 200pt.
        XCTAssertGreaterThan(image.size.width, 200)
        XCTAssertEqual(image.size.width, image.size.height, accuracy: 1)
    }
}
