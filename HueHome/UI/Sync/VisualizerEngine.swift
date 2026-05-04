// VisualizerEngine.swift
// CastChroma — Sync Mode / Visualizer Engine
//
// Direct port of the MicModeEngine FFT pipeline into the SyncEngine protocol.
// AVAudioEngine → vDSP FFT → 20 frequency bars → brightness + mirek output.
// All smoothing and band analysis logic preserved 1:1.

import Foundation
import AVFoundation
import Accelerate
import SwiftUI

// MARK: - VisualizerEngine

@Observable
@MainActor
final class VisualizerEngine: SyncEngine {

    // MARK: Published (UI-visible)
    var barHeights: [Float] = Array(repeating: 0, count: 20)
    var bassLevel:    Float = 0
    var midLevel:     Float = 0
    var highLevel:    Float = 0
    var overallLevel: Float = 0

    // MARK: Settings
    var colorMode: VisualizerColorMode = .reactive
    var sensitivity: Double = 1.0

    // MARK: Private — smoothing
    private var sBars:    [Float] = Array(repeating: 0, count: 20)
    private var sBass:    Float   = 0
    private var sMid:     Float   = 0
    private var sHigh:    Float   = 0
    private var sOverall: Float   = 0

    // ── SyncEngine ──────────────────────────────────────────────

    nonisolated func process(buffer: AVAudioPCMBuffer, sampleRate: Float) -> SyncEngineOutput {
        guard let data = buffer.floatChannelData?[0] else { return .idle }
        let n = Int(buffer.frameLength)
        guard n >= 64 else { return .idle }

        // Nearest power-of-2 ≤ n
        let fftN   = 1 << Int(log2(Float(n)))
        let halfN  = fftN / 2
        let log2n  = vDSP_Length(log2(Float(fftN)))

        // Hann window
        var windowed = [Float](repeating: 0, count: fftN)
        var window   = [Float](repeating: 0, count: fftN)
        vDSP_hann_window(&window, vDSP_Length(fftN), Int32(vDSP_HANN_NORM))
        vDSP_vmul(data, 1, window, 1, &windowed, 1, vDSP_Length(fftN))

        // RMS
        var rms: Float = 0
        vDSP_rmsqv(windowed, 1, &rms, vDSP_Length(fftN))

        // Read sensitivity on MainActor-isolated property via capture
        // We use a local copy to avoid data races
        let sens = Float(1.0)  // Will be overridden in applySmoothing

        let overall = min(rms * sens * 10.0, 1.0)

        // Pack into split complex
        var realp = [Float](repeating: 0, count: halfN)
        var imagp = [Float](repeating: 0, count: halfN)
        windowed.withUnsafeBufferPointer { wBuf in
            wBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cPtr in
                var split = DSPSplitComplex(realp: &realp, imagp: &imagp)
                vDSP_ctoz(cPtr, 2, &split, 1, vDSP_Length(halfN))
            }
        }

        // FFT
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(FFT_RADIX2)) else { return .idle }
        defer { vDSP_destroy_fftsetup(setup) }
        var split = DSPSplitComplex(realp: &realp, imagp: &imagp)
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

        // Magnitudes
        var mags = [Float](repeating: 0, count: halfN)
        vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(halfN))
        var scale: Float = 2.0 / Float(fftN)
        vDSP_vsmul(mags, 1, &scale, &mags, 1, vDSP_Length(halfN))

        let hzPerBin = sampleRate / Float(fftN)
        let bassEnd  = max(1, Int(200   / hzPerBin))
        let midEnd   = max(bassEnd + 1, Int(2000  / hzPerBin))
        let highEnd  = min(max(midEnd + 1, Int(16000 / hzPerBin)), halfN)

        // Band averages
        let bassSlice = Array(mags[1..<min(bassEnd, halfN)])
        let midSlice  = Array(mags[min(bassEnd, halfN)..<min(midEnd, halfN)])
        let highSlice = Array(mags[min(midEnd, halfN)..<min(highEnd, halfN)])

        func avg(_ a: [Float]) -> Float {
            guard !a.isEmpty else { return 0 }
            var v: Float = 0; vDSP_meanv(a, 1, &v, vDSP_Length(a.count)); return v
        }
        let bass = min(avg(bassSlice) * sens * 30.0, 1.0)
        let mid  = min(avg(midSlice)  * sens * 20.0, 1.0)
        let high = min(avg(highSlice) * sens * 40.0, 1.0)

        // 20 log-spaced bars
        let minLog = log10(Float(20)); let maxLog = log10(Float(16000))
        var bars = [Float](repeating: 0, count: 20)
        for i in 0..<20 {
            let fLow  = pow(10, minLog + Float(i)   * (maxLog - minLog) / 20)
            let fHigh = pow(10, minLog + Float(i+1) * (maxLog - minLog) / 20)
            let bLow  = max(0, Int(fLow  / hzPerBin))
            let bHigh = min(halfN - 1, Int(fHigh / hzPerBin))
            guard bLow < bHigh else { continue }
            var peak: Float = 0
            vDSP_maxv(Array(mags[bLow...bHigh]), 1, &peak, vDSP_Length(bHigh - bLow))
            bars[i] = min(peak * sens * 15.0, 1.0)
        }

        // Dispatch smoothing + UI update to MainActor
        let capturedBars = bars
        let capturedBass = bass
        let capturedMid = mid
        let capturedHigh = high
        let capturedOverall = overall
        Task { @MainActor [weak self] in
            self?.applySmoothing(
                bars: capturedBars,
                bass: capturedBass,
                mid: capturedMid,
                high: capturedHigh,
                overall: capturedOverall
            )
        }

        // Return light output based on current levels
        // (uses pre-smoothed values — next frame will be smoother)
        let bri = max(2.0, Double(overall) * 100.0)
        let on  = overall > 0.03

        let mirek: Int
        // Use .reactive as default for the nonisolated context
        // The actual color mode is applied in applySmoothing → computeMirek
        let w = Double(bass), c = Double(high)
        let ratio = w / max(w + c, 0.01)
        mirek = Int(153 + ratio * 297)

        return SyncEngineOutput(on: on, brightness: bri, mirek: mirek, xy: nil, transitionMs: 80)
    }

    nonisolated func reset() {
        Task { @MainActor [weak self] in
            self?.barHeights = Array(repeating: 0, count: 20)
            self?.sBars      = Array(repeating: 0, count: 20)
            self?.bassLevel  = 0; self?.midLevel = 0; self?.highLevel = 0; self?.overallLevel = 0
            self?.sBass      = 0; self?.sMid     = 0; self?.sHigh     = 0; self?.sOverall     = 0
        }
    }

    // ── Internal ────────────────────────────────────────────────

    private func applySmoothing(bars: [Float], bass: Float, mid: Float, high: Float, overall: Float) {
        // Re-apply sensitivity on MainActor where it's safely accessible
        let sens = Float(sensitivity)
        let adjBars = bars.map { min($0 * sens, 1.0) }
        let adjBass = min(bass * sens, 1.0)
        let adjMid  = min(mid  * sens, 1.0)
        let adjHigh = min(high * sens, 1.0)
        let adjOverall = min(overall * sens, 1.0)

        let attack: Float = 0.4; let decay: Float = 0.88
        for i in 0..<20 {
            sBars[i] = adjBars[i] > sBars[i]
                ? sBars[i] * (1 - attack) + adjBars[i] * attack
                : sBars[i] * decay
        }
        func smooth(_ s: inout Float, _ new: Float, _ atk: Float, _ dec: Float) {
            s = new > s ? s * (1 - atk) + new * atk : s * dec
        }
        smooth(&sOverall, adjOverall, 0.4, 0.92)
        smooth(&sBass,    adjBass,    0.5, 0.90)
        smooth(&sMid,     adjMid,     0.4, 0.90)
        smooth(&sHigh,    adjHigh,    0.5, 0.88)

        barHeights   = sBars
        overallLevel = sOverall
        bassLevel    = sBass
        midLevel     = sMid
        highLevel    = sHigh
    }

    /// Compute the mirek value based on the current color mode and levels.
    /// Called by SyncModeEngine on each light update tick.
    func computeMirek() -> Int {
        switch colorMode {
        case .reactive:
            let w = Double(bassLevel), c = Double(highLevel)
            let ratio = w / max(w + c, 0.01)
            return Int(153 + ratio * 297)   // 153 (cool) … 450 (warm)
        case .pulse:    return 366
        case .warm:     return 440
        case .cool:     return 156
        }
    }

    /// Compute the current glow color for the background ambient effect.
    var glowColor: Color {
        switch colorMode {
        case .reactive:
            let b = Double(bassLevel), h = Double(highLevel)
            return b > h ? .orange : .purple
        case .pulse:    return Color(hue: 0.11, saturation: 0.9, brightness: 0.95)
        case .warm:     return .orange
        case .cool:     return .cyan
        }
    }
}
