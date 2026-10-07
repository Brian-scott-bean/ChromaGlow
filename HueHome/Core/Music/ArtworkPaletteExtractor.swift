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

    private static func samplePixels(from image: CGImage, size: Int = ArtworkPaletteExtractor.sampleSize) -> [RGB] {
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

    // MARK: - v2: swatches by role (Play Along P6, song colors)

    /// OKLab (Björn Ottosson), from sRGB.
    private struct Lab {
        var l: Double
        var a: Double
        var b: Double

        var chroma: Double { (a * a + b * b).squareRoot() }
        var hue: Double { atan2(b, a) }

        func distanceSquared(to o: Lab) -> Double {
            let dl = l - o.l, da = a - o.a, db = b - o.b
            return dl * dl + da * da + db * db
        }
    }

    private struct SwatchCluster {
        var lab: Lab
        var rgb: RGB
        var weight: Double
        var index: Int
    }

    private static let swatchSampleSize = 48
    private static let swatchClusters = 6
    private static let swatchIterations = 10
    /// Clusters closer than this (ΔE in OKLab) are one colour.
    private static let swatchMergeDistance = 0.06
    /// Below this OKLab chroma a colour is a grey.
    private static let swatchMinChroma = 0.04
    /// A colour must hold this share of the weighted art to count.
    private static let swatchMinShare = 0.02
    /// The accent sits at least this far round the hue wheel from the dominant.
    private static let accentMinHueGap = Double.pi / 6
    /// Tinted whites for greyscale art: ~2700 K / ~4000 K, ~6500 K / ~8000 K.
    private static let warmWhites = (Composer2XY(x: 0.4578, y: 0.4101), Composer2XY(x: 0.3805, y: 0.3768))
    private static let coolWhites = (Composer2XY(x: 0.3127, y: 0.3290), Composer2XY(x: 0.2952, y: 0.3115))

    /// Album art → swatches by role for song colors. k-means in OKLab over a
    /// 48×48 thumbnail with every pixel weighted by 0.2 + its chroma (vivid
    /// colour counts for more than grey) and deterministic farthest-first
    /// seeds, so a small vivid patch gets a cluster of its own; clusters
    /// closer than ΔE 0.06 merge. The dominant is the heaviest colourful
    /// cluster, the accent the one that stands out most (chroma × √share) at
    /// least 30° of hue away, the rest support. Near-greyscale art becomes
    /// tinted whites — warm or cool as its mean b* leans — never grey light.
    /// Pure and deterministic; nil when the art has nothing a light can show.
    static func swatches(from image: CGImage, gamut: HueColorUtils.Gamut = .c) -> ArtworkSwatches? {
        let pixels = samplePixels(from: image, size: swatchSampleSize)
        guard pixels.count >= minUsablePixels else { return nil }
        let labs = pixels.map(oklab)
        let weights = labs.map { 0.2 + $0.chroma }
        let total = weights.reduce(0, +)
        guard total > 0 else { return nil }

        let clusters = mergeSwatchClusters(weightedKMeans(labs: labs, rgbs: pixels, weights: weights,
                                                          k: min(swatchClusters, pixels.count)))
        let colourful = clusters
            .filter { $0.lab.chroma >= swatchMinChroma && $0.weight / total >= swatchMinShare }
            .sorted { $0.weight > $1.weight }

        guard let dominant = colourful.first else {
            var meanB = 0.0
            for (lab, w) in zip(labs, weights) { meanB += lab.b * w }
            let whites = meanB / total >= 0 ? warmWhites : coolWhites
            return ArtworkSwatches(dominant: .init(xy: whites.0.clamped(to: gamut), chroma: 0, share: 1),
                                   accent: nil,
                                   support: [.init(xy: whites.1.clamped(to: gamut), chroma: 0, share: 0)],
                                   isGreyscale: true)
        }

        func swatch(_ c: SwatchCluster) -> ArtworkSwatches.Swatch {
            let xy = HueColorUtils.xyFrom(red: c.rgb.r, green: c.rgb.g, blue: c.rgb.b)
            let clamped = HueColorUtils.clampXYToGamut(x: xy.x, y: xy.y, gamut: gamut)
            return .init(xy: Composer2XY(x: clamped.x, y: clamped.y), chroma: c.lab.chroma, share: c.weight / total)
        }
        func standsOut(_ c: SwatchCluster) -> Double { c.lab.chroma * (c.weight / total).squareRoot() }

        let rest = colourful.dropFirst()
        let accent = rest
            .filter { hueGap($0.lab.hue, dominant.lab.hue) >= accentMinHueGap }
            .max { standsOut($0) < standsOut($1) }
        let support = rest.filter { $0.index != accent?.index }
        return ArtworkSwatches(dominant: swatch(dominant), accent: accent.map(swatch),
                               support: support.map(swatch), isGreyscale: false)
    }

    private static func oklab(_ c: RGB) -> Lab {
        func linear(_ v: Double) -> Double {
            let u = min(1, max(0, v))
            return u <= 0.04045 ? u / 12.92 : pow((u + 0.055) / 1.055, 2.4)
        }
        let r = linear(c.r), g = linear(c.g), b = linear(c.b)
        let l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
        let m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
        let s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
        let l_ = cbrt(l), m_ = cbrt(m), s_ = cbrt(s)
        return Lab(l: 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
                   a: 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
                   b: 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_)
    }

    private static func hueGap(_ a: Double, _ b: Double) -> Double {
        var d = abs(a - b).truncatingRemainder(dividingBy: 2 * Double.pi)
        if d > Double.pi { d = 2 * Double.pi - d }
        return d
    }

    private static func weightedKMeans(labs: [Lab], rgbs: [RGB], weights: [Double], k: Int) -> [SwatchCluster] {
        guard !labs.isEmpty, k > 0 else { return [] }
        // Farthest-first seeds: the heaviest (most vivid) pixel, then each
        // pixel heaviest × farthest from the seeds so far. Ties keep the
        // earliest pixel — no randomness, the same art gives the same seeds.
        var first = 0
        for i in labs.indices where weights[i] > weights[first] { first = i }
        var centroids = [labs[first]]
        var nearest = [Double](repeating: .greatestFiniteMagnitude, count: labs.count)
        while centroids.count < k {
            let newest = centroids[centroids.count - 1]
            var best = -1
            var bestScore = 1e-9
            for i in labs.indices {
                nearest[i] = min(nearest[i], labs[i].distanceSquared(to: newest))
                let score = weights[i] * nearest[i]
                if score > bestScore { bestScore = score; best = i }
            }
            guard best >= 0 else { break }
            centroids.append(labs[best])
        }

        var assignment = [Int](repeating: 0, count: labs.count)
        for _ in 0..<swatchIterations {
            for i in labs.indices {
                var best = 0
                var bestDistance = Double.greatestFiniteMagnitude
                for (c, centroid) in centroids.enumerated() {
                    let d = labs[i].distanceSquared(to: centroid)
                    if d < bestDistance { bestDistance = d; best = c }
                }
                assignment[i] = best
            }
            var sums = [Lab](repeating: Lab(l: 0, a: 0, b: 0), count: centroids.count)
            var mass = [Double](repeating: 0, count: centroids.count)
            for i in labs.indices {
                let c = assignment[i], w = weights[i]
                sums[c].l += labs[i].l * w
                sums[c].a += labs[i].a * w
                sums[c].b += labs[i].b * w
                mass[c] += w
            }
            for c in centroids.indices where mass[c] > 0 {
                centroids[c] = Lab(l: sums[c].l / mass[c], a: sums[c].a / mass[c], b: sums[c].b / mass[c])
            }
        }

        // The light's colour is the cluster's weighted mean art colour.
        var rgbSums = [RGB](repeating: RGB(r: 0, g: 0, b: 0), count: centroids.count)
        var mass = [Double](repeating: 0, count: centroids.count)
        for i in labs.indices {
            let c = assignment[i], w = weights[i]
            rgbSums[c].r += rgbs[i].r * w
            rgbSums[c].g += rgbs[i].g * w
            rgbSums[c].b += rgbs[i].b * w
            mass[c] += w
        }
        return centroids.indices.compactMap { c -> SwatchCluster? in
            guard mass[c] > 0 else { return nil }
            return SwatchCluster(lab: centroids[c],
                                 rgb: RGB(r: rgbSums[c].r / mass[c], g: rgbSums[c].g / mass[c], b: rgbSums[c].b / mass[c]),
                                 weight: mass[c], index: c)
        }
    }

    private static func mergeSwatchClusters(_ clusters: [SwatchCluster]) -> [SwatchCluster] {
        var result: [SwatchCluster] = []
        for cluster in clusters.sorted(by: { $0.weight > $1.weight }) {
            if let i = result.firstIndex(where: {
                $0.lab.distanceSquared(to: cluster.lab) < swatchMergeDistance * swatchMergeDistance
            }) {
                let a = result[i], w = a.weight + cluster.weight
                result[i].lab = Lab(l: (a.lab.l * a.weight + cluster.lab.l * cluster.weight) / w,
                                    a: (a.lab.a * a.weight + cluster.lab.a * cluster.weight) / w,
                                    b: (a.lab.b * a.weight + cluster.lab.b * cluster.weight) / w)
                result[i].rgb = RGB(r: (a.rgb.r * a.weight + cluster.rgb.r * cluster.weight) / w,
                                    g: (a.rgb.g * a.weight + cluster.rgb.g * cluster.weight) / w,
                                    b: (a.rgb.b * a.weight + cluster.rgb.b * cluster.weight) / w)
                result[i].weight = w
            } else {
                result.append(cluster)
            }
        }
        for i in result.indices { result[i].index = i }
        return result
    }
}
