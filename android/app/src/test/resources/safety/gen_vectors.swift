// GENERATED SCRATCH — iOS FlashSafety math extracted VERBATIM from HueHome/Core/Audio/BeatBinding.swift
// main @ d38b133, file sha256 prefix 1a09de6de5af703d, lines 203-262 (constants) and 275-347 (functions).
import Foundation
enum FlashSafety {
    static let onsetRiseThreshold = 0.10  // re-declared below verbatim if present in range
        static let onsetComparisonTolerance = 1e-9


        static let onsetColorDelta = 0.02

        static let redFlashLuminanceDelta = 0.02

        static let saturatedRedFraction = 0.8
        static func dimmingLuminance(_ brightness: Double) -> Double {
            guard brightness.isFinite, brightness > 0 else { return 0 }
            let l = min(max(brightness, 0), 1)
            let v = (100.0 * l + 16.0) / 116.0
            return min(1, max(0, v * v * v))
        }

        static func inverseDimmingLuminance(_ luminance: Double) -> Double {
            guard luminance.isFinite, luminance > 0 else { return 0 }
            let y = min(max(luminance, 0), 1)
            let bri = (116.0 * cbrt(y) - 16.0) / 100.0
            return min(1, max(0, bri))
        }

        static func linearRGB(x: Double, y: Double) -> (r: Double, g: Double, b: Double) {
            guard x.isFinite, y.isFinite, y > 0 else { return (0, 0, 0) }
            let bigX = x / y
            let bigZ = (1.0 - x - y) / y
            var r =  3.2404542 * bigX - 1.5371385 - 0.4985314 * bigZ
            var g = -0.9692660 * bigX + 1.8760108 + 0.0415560 * bigZ
            var b =  0.0556434 * bigX - 0.2040259 + 1.0572252 * bigZ
            r = max(r, 0); g = max(g, 0); b = max(b, 0)
            let peak = max(r, max(g, b))
            guard peak > 0, peak.isFinite else { return (0, 0, 0) }
            return (r / peak, g / peak, b / peak)
        }

        static func chromaticityLuminanceFactor(x: Double, y: Double) -> Double {
            let c = linearRGB(x: x, y: y)
            return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
        }

        static func redDriveFraction(x: Double, y: Double) -> Double {
            let c = linearRGB(x: x, y: y)
            let sum = c.r + c.g + c.b
            guard sum > 0 else { return 0 }
            return c.r / sum
        }

    // WireFrame.relativeLuminance / isSaturatedRed and the two candidacy rules, transcribed from
    // BeatBinding.swift `WireFrame` (relativeLuminance, isSaturatedRed) and `OnsetGate`
    // (isOnsetCandidate / isColdOnsetCandidate) with the gate state passed as parameters.
    struct WireFrame { let x: Double; let y: Double; let brightness: Double
        init(x: Double, y: Double, brightness: Double) {
            self.x = x.isFinite ? x : 0.3127; self.y = y.isFinite ? y : 0.3290
            self.brightness = brightness.isFinite ? min(max(brightness, 0), 1) : 0
        }
        func chromaDistance(to other: WireFrame) -> Double { let dx = x - other.x, dy = y - other.y; return (dx*dx + dy*dy).squareRoot() }
        var relativeLuminance: Double { FlashSafety.chromaticityLuminanceFactor(x: x, y: y) * FlashSafety.dimmingLuminance(brightness) }
        var isSaturatedRed: Bool { FlashSafety.redDriveFraction(x: x, y: y) >= FlashSafety.saturatedRedFraction - FlashSafety.onsetComparisonTolerance }
    }
    static func isOnsetCandidate(last: WireFrame, trough: Double, frame: WireFrame) -> Bool {
        let tol = onsetComparisonTolerance
        let luminance = frame.relativeLuminance
        if luminance - trough >= onsetRiseThreshold - tol { return true }
        guard frame.chromaDistance(to: last) > onsetColorDelta, frame.isSaturatedRed || last.isSaturatedRed else { return false }
        return abs(luminance - last.relativeLuminance) >= redFlashLuminanceDelta - tol
    }
    static func isColdOnsetCandidate(frame: WireFrame) -> Bool {
        frame.relativeLuminance >= onsetRiseThreshold - onsetComparisonTolerance
    }
}
// ── generator ──
let palette: [(Double, Double)] = [(0.6400,0.3300),(0.1500,0.0600),(0.1700,0.7000),(0.3200,0.1500),(0.4500,0.4100),(0.5400,0.2300),(0.1600,0.2300),(0.5600,0.4000),
  (0.1548,0.1220),(0.3127,0.3290),(0.3,0.3),(0.6915,0.3083),(0.1532,0.0475),(0.704,0.296),(0.2151,0.7106),(0.138,0.08),(0.675,0.322),(0.409,0.518),(0.167,0.04),(0.5,0.4),(0.2,0.4)]
var out = "{\n  \"source\": \"HueHome/Core/Audio/BeatBinding.swift BeatMath.FlashSafety\",\n  \"constants\": {\"onsetRiseThreshold\": \(FlashSafety.onsetRiseThreshold), \"redFlashLuminanceDelta\": \(FlashSafety.redFlashLuminanceDelta), \"onsetColorDelta\": \(FlashSafety.onsetColorDelta), \"saturatedRedFraction\": \(FlashSafety.saturatedRedFraction), \"tolerance\": \(FlashSafety.onsetComparisonTolerance)},\n"
out += "  \"luminance\": [\n"
var rows: [String] = []
for (x, y) in palette { for step in 0...20 { let b = Double(step) / 20.0; let f = FlashSafety.WireFrame(x: x, y: y, brightness: b)
  rows.append("    {\"x\": \(x), \"y\": \(y), \"brightness\": \(b), \"relativeLuminance\": \(f.relativeLuminance), \"redFraction\": \(FlashSafety.redDriveFraction(x: x, y: y)), \"chromaFactor\": \(FlashSafety.chromaticityLuminanceFactor(x: x, y: y)), \"isSaturatedRed\": \(f.isSaturatedRed)}") } }
// degenerate inputs
for (x, y, b) in [(0.3, 0.0, 0.5), (Double.nan, Double.nan, 0.5), (0.3127, 0.3290, Double.nan), (0.3127, 0.3290, -1.0), (0.3127, 0.3290, 7.0), (0.3127, 0.3290, 0.901), (0.3127, 0.3290, 1.0)] { let f = FlashSafety.WireFrame(x: x, y: y, brightness: b)
  rows.append("    {\"x\": \(x.isNaN ? "null" : String(x)), \"y\": \(y.isNaN ? "null" : String(y)), \"brightness\": \(b.isNaN ? "null" : String(b)), \"relativeLuminance\": \(f.relativeLuminance), \"redFraction\": \(FlashSafety.redDriveFraction(x: f.x, y: f.y)), \"chromaFactor\": \(FlashSafety.chromaticityLuminanceFactor(x: f.x, y: f.y)), \"isSaturatedRed\": \(f.isSaturatedRed)}") }
out += rows.joined(separator: ",\n") + "\n  ],\n  \"onsets\": [\n"
var orows: [String] = []
let frames: [(Double, Double, Double)] = [(0.3127,0.3290,0.0),(0.3127,0.3290,0.05),(0.3127,0.3290,0.2),(0.3127,0.3290,0.35),(0.3127,0.3290,0.47),(0.3127,0.3290,0.85),(0.3127,0.3290,0.901),(0.3127,0.3290,1.0),
  (0.64,0.33,0.0),(0.64,0.33,0.3),(0.64,0.33,0.5),(0.64,0.33,0.9),(0.64,0.33,1.0),(0.15,0.06,0.9),(0.15,0.06,1.0),(0.17,0.7,0.5),(0.32,0.15,0.5),(0.1548,0.1220,0.05),(0.3,0.3,0.2),(0.3,0.3,0.35),(0.3,0.3,1.0),(0.65,0.33,0.5),(0.66,0.33,0.62)]
for a in frames { for b in frames {
  let last = FlashSafety.WireFrame(x: a.0, y: a.1, brightness: a.2); let next = FlashSafety.WireFrame(x: b.0, y: b.1, brightness: b.2)
  for trough in [last.relativeLuminance, min(last.relativeLuminance, 0.02), 0.0] {
    orows.append("    {\"last\": [\(a.0), \(a.1), \(a.2)], \"trough\": \(trough), \"next\": [\(b.0), \(b.1), \(b.2)], \"isOnset\": \(FlashSafety.isOnsetCandidate(last: last, trough: trough, frame: next)), \"chromaStep\": \(next.chromaDistance(to: last) > FlashSafety.onsetColorDelta), \"eitherRed\": \(next.isSaturatedRed || last.isSaturatedRed)}") } } }
for b in frames { let next = FlashSafety.WireFrame(x: b.0, y: b.1, brightness: b.2)
  orows.append("    {\"last\": null, \"trough\": 0.0, \"next\": [\(b.0), \(b.1), \(b.2)], \"isOnset\": \(FlashSafety.isColdOnsetCandidate(frame: next)), \"chromaStep\": false, \"eitherRed\": \(next.isSaturatedRed)}") }
out += orows.joined(separator: ",\n") + "\n  ]\n}\n"
print(out)
