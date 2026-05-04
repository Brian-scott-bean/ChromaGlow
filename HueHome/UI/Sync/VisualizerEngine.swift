// VisualizerEngine.swift
// CastChroma — Sync Mode / Visualizer Engine
//
// ARCHITECTURE (v2 — zero-accumulation):
//
// The audio callback (real-time thread, ~43fps) performs FFT and writes
// the latest result to a lock-free `pendingData` struct.  No Task is
// created on the audio thread — zero MainActor queue pressure.
//
// A CADisplayLink on MainActor (~60fps) polls `pendingData`, applies
// smoothing, updates @Observable properties, and fires `onUpdate()`
// which triggers sendLightUpdate() in SyncModeEngine.
//
// Benefits:
//   - Audio thread never blocks (no actor hop, no Task creation)
//   - Only the LATEST FFT result is processed (stale buffers discarded)
//   - MainActor queue stays empty — no accumulation, no catch-up
//   - Smooth 60fps visualization with rate-limited light sends

import Foundation
import AVFoundation
import Accelerate
import SwiftUI
import QuartzCore   // CADisplayLink

// MARK: - Raw FFT output (lock-free transfer from audio → main)

/// Holds one frame of FFT output.  Written atomically from the audio
/// thread, read once per display-link tick on MainActor.
struct RawFFTFrame {
    var bars:    [Float] = Array(repeating: 0, count: 20)
    var bass:    Float   = 0
    var mid:     Float   = 0
    var high:    Float   = 0
    var overall: Float   = 0
}

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

    /// Called on MainActor after smoothing is applied (once per display frame).
    /// SyncModeEngine wires this to sendLightUpdate().
    @ObservationIgnored
    var onUpdate: (() -> Void)?

    // MARK: Private — smoothing state
    private var sBars:    [Float] = Array(repeating: 0, count: 20)
    private var sBass:    Float   = 0
    private var sMid:     Float   = 0
    private var sHigh:    Float   = 0
    private var sOverall: Float   = 0

    // MARK: Private — lock-free pending data
    //
    // The audio thread writes here; the display link reads & clears.
    // os_unfair_lock is the lightest possible lock — never contended for
    // more than a few nanoseconds (just a memcpy of ~100 floats).
    @ObservationIgnored
    nonisolated(unsafe) private var _pendingLock = os_unfair_lock()
    @ObservationIgnored
    nonisolated(unsafe) private var _pendingFrame: RawFFTFrame? = nil

    // MARK: Private — display link
    @ObservationIgnored
    private var displayLink: CADisplayLink?
    @ObservationIgnored
    private var displayLinkTarget: DisplayLinkTarget?

    // ── SyncEngine protocol ────────────────────────────────────────

    /// Called from the audio thread (~43fps).
    /// Performs FFT, writes result to pendingFrame. No Task, no actor hop.
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
        vDSP_vmul(Array(UnsafeBufferPointer(start: data, count: fftN)),
                  1, window, 1, &windowed, 1, vDSP_Length(fftN))

        // RMS
        var rms: Float = 0
        vDSP_rmsqv(windowed, 1, &rms, vDSP_Length(fftN))

        let sens = Float(1.0)
        let overall = min(rms * sens * 10.0, 1.0)

        // Pack into split complex
        var realp = [Float](repeating: 0, count: halfN)
        var imagp = [Float](repeating: 0, count: halfN)
        windowed.withUnsafeBufferPointer { wBuf in
            realp.withUnsafeMutableBufferPointer { rBuf in
                imagp.withUnsafeMutableBufferPointer { iBuf in
                    var split = DSPSplitComplex(realp: rBuf.baseAddress!, imagp: iBuf.baseAddress!)
                    wBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cPtr in
                        vDSP_ctoz(cPtr, 2, &split, 1, vDSP_Length(halfN))
                    }
                }
            }
        }

        // FFT
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(FFT_RADIX2)) else { return .idle }
        defer { vDSP_destroy_fftsetup(setup) }

        // Magnitudes
        var mags = [Float](repeating: 0, count: halfN)
        realp.withUnsafeMutableBufferPointer { rBuf in
            imagp.withUnsafeMutableBufferPointer { iBuf in
                var split = DSPSplitComplex(realp: rBuf.baseAddress!, imagp: iBuf.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(halfN))
            }
        }
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

        // ── WRITE to pending frame (lock-free) ─────────────────────
        let frame = RawFFTFrame(bars: bars, bass: bass, mid: mid, high: high, overall: overall)
        os_unfair_lock_lock(&_pendingLock)
        _pendingFrame = frame
        os_unfair_lock_unlock(&_pendingLock)

        // Return value not used by SyncModeEngine (light sends via onUpdate callback)
        return .idle
    }

    nonisolated func reset() {
        // Clear pending data
        os_unfair_lock_lock(&_pendingLock)
        _pendingFrame = nil
        os_unfair_lock_unlock(&_pendingLock)

        Task { @MainActor [weak self] in
            self?.barHeights = Array(repeating: 0, count: 20)
            self?.sBars      = Array(repeating: 0, count: 20)
            self?.bassLevel  = 0; self?.midLevel = 0; self?.highLevel = 0; self?.overallLevel = 0
            self?.sBass      = 0; self?.sMid     = 0; self?.sHigh     = 0; self?.sOverall     = 0
        }
    }

    // MARK: - Display Link (MainActor polling)

    /// Start the display link that drives smoothing + light sends.
    func startDisplayLink() {
        guard displayLink == nil else { return }
        let target = DisplayLinkTarget { [weak self] in
            self?.tick()
        }
        displayLinkTarget = target
        let link = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.handleTick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// Stop the display link.
    func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        displayLinkTarget = nil
    }

    // MARK: - Tick (runs on MainActor at display refresh rate)

    private func tick() {
        // Read & clear pending frame
        os_unfair_lock_lock(&_pendingLock)
        let frame = _pendingFrame
        _pendingFrame = nil
        os_unfair_lock_unlock(&_pendingLock)

        guard let frame else { return }  // No new audio data since last tick

        applySmoothing(
            bars: frame.bars,
            bass: frame.bass,
            mid: frame.mid,
            high: frame.high,
            overall: frame.overall
        )
        onUpdate?()
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

        // Smoothing tuned for responsive light sync:
        // - attack: how fast we rise to a new peak (0.7 = 70% of new value per frame → near-instant)
        // - decay:  how fast we fall when sound drops (0.75 = drops to half in ~7 frames / ~160ms)
        // - snap:   if delta > 30%, skip smoothing entirely → instant response to beats
        let attack: Float = 0.7; let decay: Float = 0.75; let snapThreshold: Float = 0.3

        for i in 0..<20 {
            if abs(adjBars[i] - sBars[i]) > snapThreshold {
                sBars[i] = adjBars[i]  // Snap — big change, no smoothing
            } else {
                sBars[i] = adjBars[i] > sBars[i]
                    ? sBars[i] * (1 - attack) + adjBars[i] * attack
                    : sBars[i] * decay
            }
        }

        func smooth(_ s: inout Float, _ new: Float, _ atk: Float, _ dec: Float) {
            if abs(new - s) > snapThreshold {
                s = new  // Snap
            } else {
                s = new > s ? s * (1 - atk) + new * atk : s * dec
            }
        }
        smooth(&sOverall, adjOverall, 0.7, 0.65)  // Overall: fastest — drives light brightness
        smooth(&sBass,    adjBass,    0.7, 0.70)
        smooth(&sMid,     adjMid,    0.6, 0.72)
        smooth(&sHigh,    adjHigh,   0.7, 0.68)

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

// MARK: - DisplayLinkTarget (prevents retain cycle)

/// CADisplayLink retains its target strongly. This trampoline prevents
/// VisualizerEngine from being retained by the run loop.
private final class DisplayLinkTarget: NSObject {
    let handler: () -> Void
    init(handler: @escaping () -> Void) { self.handler = handler }
    @objc func handleTick() { handler() }
}
