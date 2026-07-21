// ArtworkPaletteExtractor.swift
// ChromaGlow — Core/Music (music integration R1)
//
// Album artwork → a gamut-C-clamped Composer palette. Pure and
// deterministic: fixed-seed k-means over a 32×32 thumbnail (no CoreImage,
// no randomness — same image always yields the same palette), centroids
// ordered by pixel population, colors converted through the one shared
// RGB→xy path in HueColorUtils and clamped to gamut C exactly like every
// other palette source (SiriColorTable precedent).

import Foundation
import CoreGraphics

enum ArtworkPaletteExtractor {

    private struct RGB {
        var r: Double
        var g: Double
        var b: Double

        var luminance: Double { 0.299 * r + 0.587 * g + 0.114 * b }

        func distanceSquared(to other: RGB) -> Double {
            let dr = r - other.r, dg = g - other.g, db = b - other.b
            return dr * dr + dg * dg + db * db
        }
    }

    private static let sampleSize = 32
    private static let kMeansIterations = 8
    /// Pixels darker than this contribute nothing a bulb can show.
    private static let minBrightness = 0.12
    /// Centroids closer than this (RGB distance) merge into one color.
    private static let mergeDistance = 0.08
    private static let minUsablePixels = 8

    /// nil when the artwork has nothing a light can express (all black /
    /// transparent / empty).
    static func extract(
        from image: CGImage,
        colorCount: Int = 3,
        gamut: HueColorUtils.Gamut = .c
    ) -> PaletteConfig? {
        let pixels = samplePixels(from: image)
        guard pixels.count >= minUsablePixels else { return nil }

        let clusters = kMeans(pixels: pixels, k: max(1, min(colorCount, pixels.count)))
        let merged = mergeClose(clusters)
        guard !merged.isEmpty else { return nil }

        let colors = merged.map { cluster -> CodableColor in
            let xy = HueColorUtils.xyFrom(red: cluster.centroid.r,
                                          green: cluster.centroid.g,
                                          blue: cluster.centroid.b)
            let clamped = HueColorUtils.clampXYToGamut(x: xy.x, y: xy.y, gamut: gamut)
            return CodableColor(x: clamped.x, y: clamped.y)
        }

        return PaletteConfig(
            mode: .gradient,
            color1: colors[0],
            color2: colors.count > 1 ? colors[1] : colors[0],
            color3: colors.count > 2 ? colors[2] : nil
        )
    }

    // MARK: - Sampling

    private static func samplePixels(from image: CGImage) -> [RGB] {
        let size = sampleSize
        // Explicit sRGB: artwork arrives in P3/other spaces; drawing here
        // converts it to the space HueColorUtils.linearise() assumes.
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: size, height: size, bitsPerComponent: 8,
                  bytesPerRow: size * 4, space: srgb,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return [] }
        // Nearest-neighbor: every sample is an ACTUAL artwork pixel;
        // interpolation would blend colors across edges and bias centroids
        // toward phantom in-between colors.
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let data = ctx.data else { return [] }

        let buffer = data.bindMemory(to: UInt8.self, capacity: size * size * 4)
        var pixels: [RGB] = []
        pixels.reserveCapacity(size * size)
        for i in 0..<(size * size) {
            let a = Double(buffer[i * 4 + 3]) / 255.0
            guard a >= 0.5 else { continue }
            // Un-premultiply so partially transparent edges keep their hue.
            let rgb = RGB(r: Double(buffer[i * 4]) / 255.0 / a,
                          g: Double(buffer[i * 4 + 1]) / 255.0 / a,
                          b: Double(buffer[i * 4 + 2]) / 255.0 / a)
            guard max(rgb.r, rgb.g, rgb.b) >= minBrightness else { continue }
            pixels.append(rgb)
        }
        return pixels
    }

    // MARK: - Fixed-seed k-means

    private struct Cluster {
        var centroid: RGB
        var population: Int
    }

    private static func kMeans(pixels: [RGB], k: Int) -> [Cluster] {
        // Deterministic seeds: luminance-sorted quantiles spread the initial
        // centroids across the image's tonal range.
        let sorted = pixels.sorted { $0.luminance < $1.luminance }
        var centroids: [RGB] = (0..<k).map { i in
            sorted[min(sorted.count - 1, (2 * i + 1) * sorted.count / (2 * k))]
        }

        var assignments = [Int](repeating: 0, count: pixels.count)
        for _ in 0..<kMeansIterations {
            for (p, pixel) in pixels.enumerated() {
                var best = 0
                var bestDist = Double.greatestFiniteMagnitude
                for (c, centroid) in centroids.enumerated() {
                    let d = pixel.distanceSquared(to: centroid)
                    if d < bestDist { bestDist = d; best = c }
                }
                assignments[p] = best
            }
            var sums = [RGB](repeating: RGB(r: 0, g: 0, b: 0), count: k)
            var counts = [Int](repeating: 0, count: k)
            for (p, pixel) in pixels.enumerated() {
                let c = assignments[p]
                sums[c].r += pixel.r; sums[c].g += pixel.g; sums[c].b += pixel.b
                counts[c] += 1
            }
            for c in 0..<k where counts[c] > 0 {
                centroids[c] = RGB(r: sums[c].r / Double(counts[c]),
                                   g: sums[c].g / Double(counts[c]),
                                   b: sums[c].b / Double(counts[c]))
            }
        }

        var counts = [Int](repeating: 0, count: k)
        for a in assignments { counts[a] += 1 }
        return zip(centroids, counts)
            .filter { $0.1 > 0 }
            .map { Cluster(centroid: $0.0, population: $0.1) }
            .sorted { $0.population > $1.population }
    }

    private static func mergeClose(_ clusters: [Cluster]) -> [Cluster] {
        var result: [Cluster] = []
        for cluster in clusters {
            if let i = result.firstIndex(where: {
                $0.centroid.distanceSquared(to: cluster.centroid) < mergeDistance * mergeDistance
            }) {
                result[i].population += cluster.population
            } else {
                result.append(cluster)
            }
        }
        return result.sorted { $0.population > $1.population }
    }
}
