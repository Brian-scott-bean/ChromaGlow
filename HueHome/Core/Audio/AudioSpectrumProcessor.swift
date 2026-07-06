// AudioSpectrumProcessor.swift
// ChromaGlow — Core/Audio
//
// Cached-FFT spectrum analysis for the real-time audio taps (audit L-20/L-21).
// The previous inline pipelines created and destroyed a vDSP FFT setup,
// recomputed the Hann window, and allocated ~6 arrays on EVERY ~43 Hz audio
// callback. This class builds the setup/window/scratch buffers once per FFT
// size and reuses them.
//
// THREADING CONTRACT: an instance must be owned and driven by exactly one
// audio-tap thread at a time (VisualizerEngine owns one; AudioFeatureExtractor
// owns another — both are fed from the single AudioAnalysisEngine tap).
// No locking on the hot path by design.
//
// `magnitudes` exposes the raw spectrum so a richer feature extractor
// (onset/beat detection for the DJ-mode work) can consume the same FFT
// without re-running it.

import Accelerate
import Foundation

final class AudioSpectrumProcessor: @unchecked Sendable {

    /// Per-buffer analysis summary. Band content is read separately via
    /// `average(bins:)` / `peak(bins:)` against the reused magnitude buffer.
    struct Frame {
        let rms: Float
        let fftN: Int
        let halfN: Int
        let hzPerBin: Float
    }

    // Cached state — rebuilt only when the FFT size changes.
    private var fftSetup: FFTSetup?
    private var log2n: vDSP_Length = 0
    private var fftN = 0
    private var halfN = 0
    private var window: [Float] = []
    private var windowed: [Float] = []
    private var realp: [Float] = []
    private var imagp: [Float] = []

    /// Magnitude spectrum of the most recent `analyze()` call
    /// (halfN bins, scaled 2/fftN). Valid until the next `analyze()`.
    private(set) var magnitudes: [Float] = []

    deinit {
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    /// (Re)builds setup + window + scratch when the FFT size changes.
    private func prepare(fftN newN: Int) -> Bool {
        if newN == fftN, fftSetup != nil { return true }
        if let fftSetup {
            vDSP_destroy_fftsetup(fftSetup)
            self.fftSetup = nil
        }
        let newLog2n = vDSP_Length(log2(Float(newN)))
        guard let setup = vDSP_create_fftsetup(newLog2n, FFTRadix(FFT_RADIX2)) else { return false }
        fftSetup   = setup
        log2n      = newLog2n
        fftN       = newN
        halfN      = newN / 2
        window     = [Float](repeating: 0, count: newN)
        vDSP_hann_window(&window, vDSP_Length(newN), Int32(vDSP_HANN_NORM))
        windowed   = [Float](repeating: 0, count: newN)
        realp      = [Float](repeating: 0, count: halfN)
        imagp      = [Float](repeating: 0, count: halfN)
        magnitudes = [Float](repeating: 0, count: halfN)
        return true
    }

    /// Hann window → RMS → real FFT → magnitude spectrum, all into reused
    /// buffers. Returns nil for sub-64-frame buffers or FFT setup failure.
    func analyze(data: UnsafePointer<Float>, frameCount: Int, sampleRate: Float) -> Frame? {
        guard frameCount >= 64 else { return nil }
        let n = 1 << Int(log2(Float(frameCount)))   // largest power of two ≤ frameCount
        guard prepare(fftN: n), let setup = fftSetup else { return nil }

        vDSP_vmul(data, 1, window, 1, &windowed, 1, vDSP_Length(n))

        var rms: Float = 0
        vDSP_rmsqv(windowed, 1, &rms, vDSP_Length(n))

        let halfN = self.halfN
        let log2n = self.log2n
        windowed.withUnsafeBufferPointer { wBuf in
            realp.withUnsafeMutableBufferPointer { rBuf in
                imagp.withUnsafeMutableBufferPointer { iBuf in
                    var split = DSPSplitComplex(realp: rBuf.baseAddress!, imagp: iBuf.baseAddress!)
                    wBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cPtr in
                        vDSP_ctoz(cPtr, 2, &split, 1, vDSP_Length(halfN))
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    magnitudes.withUnsafeMutableBufferPointer { mBuf in
                        vDSP_zvabs(&split, 1, mBuf.baseAddress!, 1, vDSP_Length(halfN))
                        var scale: Float = 2.0 / Float(n)
                        vDSP_vsmul(mBuf.baseAddress!, 1, &scale, mBuf.baseAddress!, 1, vDSP_Length(halfN))
                    }
                }
            }
        }

        return Frame(rms: rms, fftN: n, halfN: halfN, hzPerBin: sampleRate / Float(n))
    }

    /// Mean magnitude over a half-open bin range (callers keep their existing
    /// bin arithmetic so band values stay identical). Empty/invalid → 0.
    func average(bins: Range<Int>) -> Float {
        let lo = max(0, bins.lowerBound)
        let hi = min(magnitudes.count, bins.upperBound)
        guard lo < hi else { return 0 }
        var v: Float = 0
        magnitudes.withUnsafeBufferPointer { mBuf in
            vDSP_meanv(mBuf.baseAddress! + lo, 1, &v, vDSP_Length(hi - lo))
        }
        return v
    }

    /// Peak magnitude over an inclusive bin range. The count is inclusive —
    /// this fixes L-21, where a `bHigh - bLow` count silently excluded each
    /// bar's top FFT bin.
    func peak(bins: ClosedRange<Int>) -> Float {
        let lo = max(0, bins.lowerBound)
        let hi = min(magnitudes.count - 1, bins.upperBound)
        guard lo <= hi else { return 0 }
        var v: Float = 0
        magnitudes.withUnsafeBufferPointer { mBuf in
            vDSP_maxv(mBuf.baseAddress! + lo, 1, &v, vDSP_Length(hi - lo + 1))
        }
        return v
    }
}
