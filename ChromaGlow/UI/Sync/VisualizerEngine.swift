// VisualizerEngine.swift
// ChromaGlow — Sync Mode / Visualizer Engine
//
// ARCHITECTURE (v2 — zero-accumulation):
//
// Audio callback (real-time thread, ~43fps):
//   - Performs FFT using vDSP
//   - Writes latest result to lock-free pendingFrame (os_unfair_lock)
//   - Creates ZERO Tasks — no MainActor queue pressure
//
// CADisplayLink (MainActor, ~60fps):
//   - Polls pendingFrame, processes only the LATEST frame
//   - Applies smoothing → updates @Observable properties
//   - Fires onUpdate() callback → SyncModeEngine.sendLightUpdate()
//
// Result: real-time light response, zero accumulation, instant stop.

import Foundation
import AVFoundation
import Accelerate
import SwiftUI
import QuartzCore
import os

// MARK: - Raw FFT Frame (lock-free audio→main transfer)

struct RawFFTFrame {
    var bars:    [Float] = Array(repeating: 0, count: 20)
    var bass:    Float = 0
    var mid:     Float = 0
    var high:    Float = 0
    var overall: Float = 0
}

// MARK: - VisualizerEngine

@Observable
@MainActor
final class VisualizerEngine: SyncEngine {

    // MARK: Published (UI-visible)
    var barHeights:   [Float] = Array(repeating: 0, count: 20)
    var bassLevel:    Float = 0
    var midLevel:     Float = 0
    var highLevel:    Float = 0
    var overallLevel: Float = 0

    // MARK: Settings
    var colorMode: VisualizerColorMode = .reactive
    var sensitivity: Double = 1.0

    /// Called on MainActor after smoothing. SyncModeEngine wires this to sendLightUpdate().
    @ObservationIgnored var onUpdate: (() -> Void)?

    // MARK: Private — smoothing state
    private var sBars:    [Float] = Array(repeating: 0, count: 20)
    private var sBass:    Float = 0
    private var sMid:     Float = 0
    private var sHigh:    Float = 0
    private var sOverall: Float = 0

    // MARK: Private — lock-free pending data
    @ObservationIgnored nonisolated(unsafe) private var _lock = os_unfair_lock()
    @ObservationIgnored nonisolated(unsafe) private var _pending: RawFFTFrame? = nil

    // MARK: Private — display link
    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var linkTarget: DisplayLinkTarget?

    // MARK: Private — diagnostics
    private let log = Logger(subsystem: "com.lightshade.app", category: "SyncViz")
    /// Throttle diagnostic logs to ~1/sec on the audio thread
    @ObservationIgnored nonisolated(unsafe) private var _logCounter: Int = 0
    /// Throttle diagnostic logs to ~1/sec on MainActor
    private var _tickLogCounter: Int = 0

    // ── SyncEngine protocol ────────────────────────────────────

    /// Audio thread: FFT → write to pendingFrame. No Task, no actor hop.
    nonisolated func process(buffer: AVAudioPCMBuffer, sampleRate: Float) -> SyncEngineOutput {
        guard let data = buffer.floatChannelData?[0] else { return .idle }
        let n = Int(buffer.frameLength)
        guard n >= 64 else { return .idle }

        let fftN  = 1 << Int(log2(Float(n)))
        let halfN = fftN / 2
        let log2n = vDSP_Length(log2(Float(fftN)))

        // Hann window
        var windowed = [Float](repeating: 0, count: fftN)
        var window   = [Float](repeating: 0, count: fftN)
        vDSP_hann_window(&window, vDSP_Length(fftN), Int32(vDSP_HANN_NORM))
        vDSP_vmul(Array(UnsafeBufferPointer(start: data, count: fftN)),
                  1, window, 1, &windowed, 1, vDSP_Length(fftN))

        // RMS
        var rms: Float = 0
        vDSP_rmsqv(windowed, 1, &rms, vDSP_Length(fftN))
        let overall = min(rms * 10.0, 1.0)

        // DIAGNOSTIC: log ~1/sec (buffer arrives ~43/sec, so every 43 buffers)
        _logCounter += 1
        if _logCounter >= 43 {
            _logCounter = 0
            let log = Logger(subsystem: "com.lightshade.app", category: "SyncViz")
            log.info("SYNC AUDIO: n=\(n) fftN=\(fftN) rms=\(rms, format: .fixed(precision: 4)) overall=\(overall, format: .fixed(precision: 3))")
        }

        // Split complex (safe pointer handling)
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

        // FFT + magnitudes
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(FFT_RADIX2)) else { return .idle }
        defer { vDSP_destroy_fftsetup(setup) }

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
        let bassEnd = max(1, Int(200 / hzPerBin))
        let midEnd  = max(bassEnd + 1, Int(2000 / hzPerBin))
        let highEnd = min(max(midEnd + 1, Int(16000 / hzPerBin)), halfN)

        // Band averages
        func avg(_ a: [Float]) -> Float {
            guard !a.isEmpty else { return 0 }
            var v: Float = 0; vDSP_meanv(a, 1, &v, vDSP_Length(a.count)); return v
        }
        let bass = min(avg(Array(mags[1..<min(bassEnd, halfN)])) * 30.0, 1.0)
        let mid  = min(avg(Array(mags[min(bassEnd, halfN)..<min(midEnd, halfN)])) * 20.0, 1.0)
        let high = min(avg(Array(mags[min(midEnd, halfN)..<min(highEnd, halfN)])) * 40.0, 1.0)

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
            bars[i] = min(peak * 15.0, 1.0)
        }

        // Write to pending (lock-free)
        let frame = RawFFTFrame(bars: bars, bass: bass, mid: mid, high: high, overall: overall)
        os_unfair_lock_lock(&_lock)
        _pending = frame
        os_unfair_lock_unlock(&_lock)

        return .idle
    }

    nonisolated func reset() {
        os_unfair_lock_lock(&_lock)
        _pending = nil
        os_unfair_lock_unlock(&_lock)
        Task { @MainActor [weak self] in
            self?.barHeights = Array(repeating: 0, count: 20)
            self?.sBars      = Array(repeating: 0, count: 20)
            self?.bassLevel  = 0; self?.midLevel = 0; self?.highLevel = 0; self?.overallLevel = 0
            self?.sBass      = 0; self?.sMid     = 0; self?.sHigh     = 0; self?.sOverall     = 0
        }
    }

    // MARK: - Display Link

    func startDisplayLink() {
        guard displayLink == nil else { return }
        let target = DisplayLinkTarget { [weak self] in self?.tick() }
        linkTarget = target
        let link = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.fire))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        linkTarget = nil
    }

    // MARK: - Tick (MainActor, ~60fps)

    private func tick() {
        os_unfair_lock_lock(&_lock)
        let frame = _pending
        _pending = nil
        os_unfair_lock_unlock(&_lock)
        guard let frame else { return }

        applySmoothing(bars: frame.bars, bass: frame.bass, mid: frame.mid,
                       high: frame.high, overall: frame.overall)

        // DIAGNOSTIC: log smoothed levels ~1/sec (display link fires ~60/sec)
        _tickLogCounter += 1
        if _tickLogCounter >= 60 {
            _tickLogCounter = 0
            log.info("SYNC LEVELS: raw=\(frame.overall, format: .fixed(precision: 3)) smoothed=\(self.overallLevel, format: .fixed(precision: 3)) bass=\(self.bassLevel, format: .fixed(precision: 3)) onUpdate=\(self.onUpdate != nil)")
        }

        onUpdate?()
    }

    // MARK: - Smoothing

    private func applySmoothing(bars: [Float], bass: Float, mid: Float, high: Float, overall: Float) {
        let sens = Float(sensitivity)
        let adjBars = bars.map { min($0 * sens, 1.0) }
        let adjBass = min(bass * sens, 1.0)
        let adjMid  = min(mid  * sens, 1.0)
        let adjHigh = min(high * sens, 1.0)
        let adjOverall = min(overall * sens, 1.0)

        let attack: Float = 0.7; let decay: Float = 0.75; let snap: Float = 0.3

        for i in 0..<20 {
            if abs(adjBars[i] - sBars[i]) > snap {
                sBars[i] = adjBars[i]
            } else {
                sBars[i] = adjBars[i] > sBars[i]
                    ? sBars[i] * (1 - attack) + adjBars[i] * attack
                    : sBars[i] * decay
            }
        }

        func smooth(_ s: inout Float, _ new: Float, _ atk: Float, _ dec: Float) {
            if abs(new - s) > snap { s = new }
            else { s = new > s ? s * (1 - atk) + new * atk : s * dec }
        }
        smooth(&sOverall, adjOverall, 0.7, 0.65)
        smooth(&sBass,    adjBass,    0.7, 0.70)
        smooth(&sMid,     adjMid,    0.6, 0.72)
        smooth(&sHigh,    adjHigh,   0.7, 0.68)

        barHeights   = sBars
        overallLevel = sOverall
        bassLevel    = sBass
        midLevel     = sMid
        highLevel    = sHigh
    }

    // MARK: - Color

    func computeMirek() -> Int {
        switch colorMode {
        case .reactive:
            let w = Double(bassLevel), c = Double(highLevel)
            return Int(153 + w / max(w + c, 0.01) * 297)
        case .pulse: return 366
        case .warm:  return 440
        case .cool:  return 156
        }
    }

    var glowColor: Color {
        switch colorMode {
        case .reactive: return Double(bassLevel) > Double(highLevel) ? .orange : .purple
        case .pulse:    return Color(hue: 0.11, saturation: 0.9, brightness: 0.95)
        case .warm:     return .orange
        case .cool:     return .cyan
        }
    }
}

// MARK: - DisplayLinkTarget (prevent retain cycle)

private final class DisplayLinkTarget: NSObject {
    let handler: () -> Void
    init(handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}
