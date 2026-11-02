// OnsetFrameAnalyzer.swift
// ChromaGlow — Core/Audio (Play Along P1)
//
// The beat tracker's front end: 10 ms analysis frames, each stamped with the
// moment its audio was CAPTURED. The legacy extractor computes one spectrum
// per tap buffer — about 100 ms on a device — which quantised every onset to
// a tenth of a second and let the tempo pass see only ~10 values a second.
// Here each buffer is cut into 10 ms hops over a ring of recent samples, so
// the onset envelope runs at 100 Hz and its timestamps are exact to the
// sample, however late the buffer itself was delivered. The predictive
// BeatClock absorbs the delivery delay; it cannot absorb a wrong timestamp.
//
// Per frame: log-compressed energy in 18 log-spaced bands (30 Hz–16 kHz),
// half-wave-rectified spectral flux (all bands, plus low / mid / high
// groups), the band levels themselves (the bar tracker's chord-change
// cue) and, since build 915, kick / snare / hi-hat hits (DrumLanes).
// Measured against the old pipeline in docs/ios/play-along/beatlab.
//
// THREADING CONTRACT: `process` is owned by exactly one producer thread (the
// source's audio thread). No allocation once warm. Readers copy frames out
// with `snapshot(seconds:)` under the ring's lock, like the extractor's
// onset envelope. Raw audio never leaves this object and is never stored
// beyond the one analysis window it needs.

import Accelerate
import Foundation
import os

/// A window of analysis frames, oldest first. Plain arrays — a value the
/// tracker can work on off the audio thread.
struct OnsetFrames: Sendable, Equatable {
    var times: [Double] = []      // capture time of each frame's centre (CACurrentMediaTime timebase)
    var flux: [Float] = []        // all-band rectified log flux
    var low: [Float] = []         // < 281 Hz (kick, bass)
    var mid: [Float] = []         // 281 Hz – 2.8 kHz
    var high: [Float] = []        // ≥ 2.8 kHz (snare noise, hats)
    var energy: [Float] = []      // mean log band level (silence detection)
    /// Band levels, `bandCount` per frame, row-major.
    var bands: [Float] = []
    /// Each drum's hit strength on the frame it fired (0 elsewhere).
    var kick: [Float] = []
    var snare: [Float] = []
    var hat: [Float] = []
    var bandCount: Int = 0
    var frameRate: Double = 100

    var count: Int { times.count }
    var isEmpty: Bool { times.isEmpty }

    func band(_ frame: Int, _ b: Int) -> Float { bands[frame * bandCount + b] }

    static let empty = OnsetFrames()
}

/// The latest kick, snare and hi-hat (capture times; 0 = none yet).
struct DrumHits: Sendable, Equatable {
    var kickAt: Double = 0
    var kickStrength: Float = 0
    var snareAt: Double = 0
    var snareStrength: Float = 0
    var hatAt: Double = 0
    var hatStrength: Float = 0

    static let none = DrumHits()
}

final class OnsetFrameAnalyzer: @unchecked Sendable {

    /// Band edges in Hz (log-spaced). Groups: bands 0…3 low, 4…11 mid, 12… high.
    static let bandEdgesHz: [Double] = [30, 94, 141, 188, 281, 375, 469, 656, 844, 1125, 1500,
                                        2063, 2813, 3750, 5156, 7031, 9375, 12188, 16000]
    static var bandCount: Int { bandEdgesHz.count - 1 }
    static let lowBands = 0...3
    static let midBands = 4...11
    /// Log compression gain: `log1p(γ·E)`.
    static let gamma: Float = 200
    /// Seconds of frames the ring keeps.
    static let ringSeconds = 12.0

    // ── Configuration (rebuilt when the sample rate changes) ──
    private(set) var sampleRate: Double = 0
    private(set) var hop = 0
    private(set) var window = 0
    private var log2n: vDSP_Length = 0
    private var fftSetup: FFTSetup?
    private var hann: [Float] = []
    private var history: [Float] = []        // ring of the last `window` samples
    private var historyPos = 0
    private var samplesSeen = 0
    private var pendingHop = 0
    private var windowed: [Float] = []
    private var realp: [Float] = []
    private var imagp: [Float] = []
    private var mags: [Float] = []
    private var bandRanges: [Range<Int>] = []
    private var prevLevels: [Float] = []
    private var levels: [Float] = []
    private let lanes: DrumLanes

    init(drumTuning: DrumLaneTuning = .standard) {
        lanes = DrumLanes(bandCount: Self.bandCount, tuning: drumTuning)
    }

    // ── Frame ring (cross-thread: producer writes, readers copy) ──
    private var lock = os_unfair_lock()
    private var capacity = 0
    private var rTimes: [Double] = []
    private var rFlux: [Float] = []
    private var rLow: [Float] = []
    private var rMid: [Float] = []
    private var rHigh: [Float] = []
    private var rEnergy: [Float] = []
    private var rBands: [Float] = []
    private var rKick: [Float] = []
    private var rSnare: [Float] = []
    private var rHat: [Float] = []
    private var drums = DrumHits.none
    private var writeIndex = 0
    private var stored = 0
    private var frameRate: Double = 100
    /// Seconds between sound reaching the microphone and the buffer time
    /// iOS stamps (the session's input latency) — subtracted from every
    /// stamp. Set once a source is running; guarded by the ring lock.
    private var inputLatency: Double = 0

    func setInputLatency(_ seconds: Double) {
        os_unfair_lock_lock(&lock)
        inputLatency = seconds.isFinite ? min(max(seconds, 0), 0.5) : 0
        os_unfair_lock_unlock(&lock)
    }

    deinit {
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    /// (Re)configure for a sample rate: 10 ms hop, a power-of-two window of
    /// at least two hops (1024 at 44.1/48 kHz, 512 at 16/24 kHz).
    private func configure(sampleRate fs: Double) {
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
        sampleRate = fs
        hop = max(1, Int((fs * 0.01).rounded()))
        var w = 64
        while w < hop * 2 { w <<= 1 }
        window = w
        log2n = vDSP_Length(log2(Double(w)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(FFT_RADIX2))
        hann = [Float](repeating: 0, count: w)
        vDSP_hann_window(&hann, vDSP_Length(w), Int32(vDSP_HANN_NORM))
        history = [Float](repeating: 0, count: w)
        historyPos = 0
        samplesSeen = 0
        pendingHop = 0
        windowed = [Float](repeating: 0, count: w)
        realp = [Float](repeating: 0, count: w / 2)
        imagp = [Float](repeating: 0, count: w / 2)
        mags = [Float](repeating: 0, count: w / 2)
        let hzPerBin = fs / Double(w)
        // Clamp below Nyquist: at 16/24 kHz (a Bluetooth headset route) the
        // top bands lie past the last bin, and a range ending AT w/2 would
        // read one magnitude beyond the buffer.
        let lastBin = w / 2 - 1
        let edges = Self.bandEdgesHz.map { max(1, min(lastBin, Int(($0 / hzPerBin).rounded()))) }
        bandRanges = (0..<(edges.count - 1)).map { b in edges[b]..<max(edges[b] + 1, edges[b + 1]) }
        prevLevels = [Float](repeating: 0, count: Self.bandCount)
        levels = [Float](repeating: 0, count: Self.bandCount)
        lanes.reset()

        frameRate = fs / Double(hop)
        let cap = Int(Self.ringSeconds * frameRate) + 1
        os_unfair_lock_lock(&lock)
        capacity = cap
        rTimes = [Double](repeating: 0, count: cap)
        rFlux = [Float](repeating: 0, count: cap)
        rLow = [Float](repeating: 0, count: cap)
        rMid = [Float](repeating: 0, count: cap)
        rHigh = [Float](repeating: 0, count: cap)
        rEnergy = [Float](repeating: 0, count: cap)
        rBands = [Float](repeating: 0, count: cap * Self.bandCount)
        rKick = [Float](repeating: 0, count: cap)
        rSnare = [Float](repeating: 0, count: cap)
        rHat = [Float](repeating: 0, count: cap)
        drums = .none
        writeIndex = 0
        stored = 0
        os_unfair_lock_unlock(&lock)
    }

    /// Analyze one buffer whose FIRST sample was stamped `bufferStart`
    /// (seconds, CACurrentMediaTime timebase). The input latency set with
    /// `setInputLatency` is subtracted here.
    func process(_ data: UnsafePointer<Float>, frameCount: Int, sampleRate fs: Double, bufferStart: Double) {
        guard frameCount > 0, fs > 0, bufferStart.isFinite else { return }
        if fs != sampleRate || fftSetup == nil { configure(sampleRate: fs) }
        guard fftSetup != nil else { return }
        os_unfair_lock_lock(&lock)
        let bufferStart = bufferStart - inputLatency
        os_unfair_lock_unlock(&lock)
        let w = window
        for i in 0..<frameCount {
            history[historyPos] = data[i]
            historyPos += 1
            if historyPos == w { historyPos = 0 }
            samplesSeen += 1
            pendingHop += 1
            if pendingHop == hop {
                pendingHop = 0
                if samplesSeen >= w {
                    // The window holds samples i−w+1 … i; its centre is i + ½ − w/2.
                    let centre = bufferStart + (Double(i) + 0.5 - Double(w) / 2) / fs
                    analyzeFrame(centreTime: centre)
                }
            }
        }
    }

    private func analyzeFrame(centreTime: Double) {
        guard let setup = fftSetup else { return }
        let w = window
        let half = w / 2
        // Unroll the ring (oldest first) straight into the windowed buffer.
        history.withUnsafeBufferPointer { h in
            hann.withUnsafeBufferPointer { win in
                windowed.withUnsafeMutableBufferPointer { out in
                    let tail = w - historyPos
                    vDSP_vmul(h.baseAddress! + historyPos, 1, win.baseAddress!, 1, out.baseAddress!, 1, vDSP_Length(tail))
                    if historyPos > 0 {
                        vDSP_vmul(h.baseAddress!, 1, win.baseAddress! + tail, 1, out.baseAddress! + tail, 1,
                                  vDSP_Length(historyPos))
                    }
                }
            }
        }
        windowed.withUnsafeBufferPointer { wBuf in
            realp.withUnsafeMutableBufferPointer { rBuf in
                imagp.withUnsafeMutableBufferPointer { iBuf in
                    var split = DSPSplitComplex(realp: rBuf.baseAddress!, imagp: iBuf.baseAddress!)
                    wBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { c in
                        vDSP_ctoz(c, 2, &split, 1, vDSP_Length(half))
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    mags.withUnsafeMutableBufferPointer { m in
                        vDSP_zvabs(&split, 1, m.baseAddress!, 1, vDSP_Length(half))
                        var scale = Float(2.0 / Double(w))
                        vDSP_vsmul(m.baseAddress!, 1, &scale, m.baseAddress!, 1, vDSP_Length(half))
                    }
                }
            }
        }

        var flux: Float = 0, low: Float = 0, mid: Float = 0, high: Float = 0, energy: Float = 0
        for b in 0..<Self.bandCount {
            let r = bandRanges[b]
            var s: Float = 0
            mags.withUnsafeBufferPointer { m in
                vDSP_sve(m.baseAddress! + r.lowerBound, 1, &s, vDSP_Length(r.count))
            }
            let level = log1pf(Self.gamma * s)
            levels[b] = level
            energy += level
            let rise = max(0, level - prevLevels[b])
            prevLevels[b] = level
            flux += rise
            if Self.lowBands.contains(b) { low += rise }
            else if Self.midBands.contains(b) { mid += rise }
            else { high += rise }
        }
        energy /= Float(Self.bandCount)
        let hit = levels.withUnsafeBufferPointer { lanes.process(levels: $0, time: centreTime, frameRate: frameRate) }

        os_unfair_lock_lock(&lock)
        let k = writeIndex
        rTimes[k] = centreTime
        rFlux[k] = flux
        rLow[k] = low
        rMid[k] = mid
        rHigh[k] = high
        rEnergy[k] = energy
        let base = k * Self.bandCount
        for b in 0..<Self.bandCount { rBands[base + b] = levels[b] }
        rKick[k] = 0
        rSnare[k] = 0
        rHat[k] = hit.hat
        // A held or confirmed hit keeps its onset time (DrumLanes may publish
        // it a frame or more on): it is marked on the frame it started.
        if hit.kick > 0 {
            drums.kickAt = lanes.lastKickTime; drums.kickStrength = hit.kick
            rKick[slot(back: centreTime - lanes.lastKickTime, from: k)] = hit.kick
        }
        if hit.snare > 0 {
            drums.snareAt = lanes.lastSnareTime; drums.snareStrength = hit.snare
            rSnare[slot(back: centreTime - lanes.lastSnareTime, from: k)] = hit.snare
        }
        if hit.hat > 0 { drums.hatAt = centreTime; drums.hatStrength = hit.hat }
        writeIndex = (k + 1) % capacity
        stored = min(stored + 1, capacity)
        os_unfair_lock_unlock(&lock)
    }

    /// The ring slot `seconds` before slot `k` (at most what the ring holds).
    private func slot(back seconds: Double, from k: Int) -> Int {
        let frames = min(max(0, Int((seconds * frameRate).rounded())), stored, capacity - 1)
        return (k - frames + capacity) % capacity
    }

    /// The last `seconds` of frames (oldest first). Safe from any thread.
    func snapshot(seconds: Double = OnsetFrameAnalyzer.ringSeconds) -> OnsetFrames {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard stored > 0, capacity > 0 else { return .empty }
        let wanted = min(stored, max(1, Int(seconds * frameRate)))
        var out = OnsetFrames()
        out.frameRate = frameRate
        out.bandCount = Self.bandCount
        out.times.reserveCapacity(wanted)
        out.flux.reserveCapacity(wanted)
        out.low.reserveCapacity(wanted)
        out.mid.reserveCapacity(wanted)
        out.high.reserveCapacity(wanted)
        out.energy.reserveCapacity(wanted)
        out.bands.reserveCapacity(wanted * Self.bandCount)
        out.kick.reserveCapacity(wanted)
        out.snare.reserveCapacity(wanted)
        out.hat.reserveCapacity(wanted)
        let start = (writeIndex - wanted + capacity) % capacity
        for j in 0..<wanted {
            let k = (start + j) % capacity
            out.times.append(rTimes[k])
            out.flux.append(rFlux[k])
            out.low.append(rLow[k])
            out.mid.append(rMid[k])
            out.high.append(rHigh[k])
            out.energy.append(rEnergy[k])
            let base = k * Self.bandCount
            for b in 0..<Self.bandCount { out.bands.append(rBands[base + b]) }
            out.kick.append(rKick[k])
            out.snare.append(rSnare[k])
            out.hat.append(rHat[k])
        }
        return out
    }

    /// The latest kick, snare and hi-hat. Safe from any thread.
    func drumHits() -> DrumHits {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return drums
    }
}
