// SceneQRRenderer.swift
// ChromaGlow — scene sharing
//
// Renders a share URL as a QR code. CIQRCodeGenerator produces a tiny image
// (one pixel per module), so it is scaled up with nearest-neighbour — bilinear
// smoothing would blur the module edges and cost scanners their reads — and
// composited onto an opaque white canvas with a spec-sized quiet zone.
//
// Correction level M (~15% recoverable) is the sweet spot: L packs more data
// but dies on a fingerprint or a screen glare, and Q/H shrink capacity for
// robustness a phone-to-phone scan does not need. A typical preset encodes to
// ~600B — a version-18 symbol, 95x95 including the generator's own quiet zone.
// Dense, but an easy read.
//
// A QR has a hard capacity ceiling. Past it CIQRCodeGenerator simply produces
// nothing, and a renderer that swallowed that would leave the share sheet
// showing a blank square. So `render` returns a typed failure the UI can
// explain — and the link still works, which is the point of `Failure.tooLarge`.

import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

enum SceneQRRenderer {

    enum Failure: LocalizedError, Equatable {
        /// The payload exceeds what a level-M QR can hold. The share link is
        /// still valid — only the QR could not be drawn.
        case tooLarge(byteCount: Int)
        case renderFailed

        var errorDescription: String? {
            switch self {
            case .tooLarge:
                return "This scene is too detailed to fit in a QR code. Share the link instead — it still carries the whole scene."
            case .renderFailed:
                return "Couldn't draw the QR code."
            }
        }
    }

    /// Byte-mode capacity of a version-40 QR at correction level M.
    /// Past this the generator yields no image at all.
    static let byteCapacityLevelM = 2331

    /// A level-M QR this full is a version ~35+ symbol: readable, but it wants a
    /// steady hand and a clean screen. Worth telling the user about.
    static let comfortableByteCount = 1200

    /// Extra modules of white margin drawn around the symbol. CIQRCodeGenerator
    /// supplies 3 of its own (a v1 symbol is 21 modules; its output extent is
    /// 27), and ISO 18004 asks for 4. Drawing our own margin gets us past the
    /// minimum and, because the canvas is filled white first, guarantees the
    /// exported image stays opaque no matter what the generator does with its
    /// alpha channel — a QR shared into Messages or Mail is composited onto
    /// their background, and a transparent one disappears against a dark theme.
    static let quietZoneModules = 4

    static func render(_ url: URL, scale: CGFloat = 12) throws -> UIImage {
        guard let payload = url.absoluteString.data(using: .utf8) else {
            throw Failure.renderFailed
        }
        guard payload.count <= byteCapacityLevelM else {
            throw Failure.tooLarge(byteCount: payload.count)
        }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = payload
        filter.correctionLevel = "M"

        guard let output = filter.outputImage else {
            // The generator refuses payloads it cannot encode rather than
            // erroring, so a nil here at this size means capacity after all.
            throw Failure.tooLarge(byteCount: payload.count)
        }

        // The generator emits one pixel per module.
        let context = CIContext()
        guard let symbol = context.createCGImage(output, from: output.extent) else {
            throw Failure.renderFailed
        }

        let modules = output.extent.width
        let pixelsPerModule = max(1, scale)
        let margin = CGFloat(quietZoneModules) * pixelsPerModule
        let side = modules * pixelsPerModule + margin * 2
        let canvas = CGRect(x: 0, y: 0, width: side, height: side)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1        // `side` is already in pixels
        format.opaque = true    // scanners want an opaque light background

        return UIGraphicsImageRenderer(size: canvas.size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(canvas)
            // Nearest-neighbour: a module must stay a hard-edged square. Drawn
            // via UIImage (not CGContext.draw) so it is not vertically mirrored
            // into an unscannable code.
            ctx.cgContext.interpolationQuality = .none
            UIImage(cgImage: symbol).draw(in: canvas.insetBy(dx: margin, dy: margin))
        }
    }

    /// True when the payload will fit but sits in the "hold still" zone.
    static func isDense(_ url: URL) -> Bool {
        let count = url.absoluteString.utf8.count
        return count > comfortableByteCount && count <= byteCapacityLevelM
    }
}
