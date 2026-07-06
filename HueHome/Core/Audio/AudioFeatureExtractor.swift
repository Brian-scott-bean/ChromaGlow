// AudioFeatureExtractor.swift
// ChromaGlow — Core/Audio (DJ upgrade Phase 2)
//
// Pure DSP feature extraction over AudioSpectrumProcessor: per-hop RMS +
// band energies (legacy-scaled AND AGC-normalized), bass-weighted spectral-
// flux onset detection with an adaptive median+MAD threshold, and a ~6 s
// onset-envelope ring buffer that TempoEstimator consumes for BPM tracking.
//
// THREADING CONTRACT: `process()` is owned by exactly one audio-tap thread
// (same contract as AudioSpectrumProcessor). The onset ring buffer is the
// one cross-thread surface — `onsetEnvelopeSnapshot()` copies it out under
// a lock so the ~2 Hz tempo pass on a utility queue never races the tap.
//
// No AVFoundation dependency: operates on raw Float pointers + sampleRate,
// so every path is unit-testable with synthetic signals.

import Accelerate
import Foundation
import os

// MARK: - AudioFeatures

/// One analysis hop's worth of audio features. Published by
/// AudioAnalysisEngine; consumed by render loops and the Sync tab.
struct AudioFeatures: Sendable, Equatable {
    // AGC-normalized 0–1 (loudness-invariant — use these for reactions).
    var level:  Float = 0
    var bass:   Float = 0
    var mid:    Float = 0
    var treble: Float = 0

    // Legacy-scaled values (VisualizerEngine parity: RMS×10, bands ×30/×20/×40,
    // clamped to 1) — keep the Sync tab's visual behavior unchanged.
    var rawOverall: Float = 0
    var rawBass:    Float = 0
    var rawMid:     Float = 0
    var rawTreble:  Float = 0

    // Onset / beat.
    var onsetStrength: Float = 0    // this hop, normalized vs recent peak
    var isOnset: Bool = false       // adaptive threshold crossed this hop
    var lastOnsetAt: Double = 0     // host time (CACurrentMediaTime timebase)

    // Tempo (stamped by AudioAnalysisEngine from TempoEstimator, ~2 Hz).
    var bpm: Double = 0             // 0 = unknown
    var bpmConfidence: Double = 0   // 0–1

    var timestamp: Double = 0       // host time of this hop

    static let silent = AudioFeatures()
}

// MARK: - AudioFeatureExtractor

final class AudioFeatureExtractor: @unchecked Sendable {

    // ── Tunables ────────────────────────────────────────────────
    /// Noise floor: below this RMS (~−55 dBFS) normalized outputs gate to 0.
    private static let noiseFloorRMS: Float = 0.0018
    /// AGC reference never decays below this, so silence isn't amplified.
    private static let agcRefFloor: Float = 0.02
    /// Onset debounce — two onsets can't be closer than this (seconds).
    private static let onsetRefractory: Double = 0.06
    /// Ring capacity: 256 hops ≈ 6 s at ~43 Hz.
    private static let ringCapacity = 256
    /// Adaptive-threshold window: ~1 s of hops.
    private static let thresholdWindow = 43

    // ── AGC tracker ─────────────────────────────────────────────
    /// Reference-level follower: rises fast when the signal gets louder
    /// (τ≈0.5 s), falls slowly in quiet (τ≈4 s) — so the *gain* drops fast
    /// and recovers slowly, mapping the recent loud level to ~0.8.
    private struct AGCTracker {
        var ref: Float = AudioFeatureExtractor.agcRefFloor

        mutating func normalize(_ value: Float, dt: Float) -> Float {
            if value > ref {
                let alpha = 1 - exp(-dt / 0.5)
                ref += (value - ref) * alpha
            } else {
                let alpha = 1 - exp(-dt / 4.0)
                ref += (value - ref) * alpha
            }
            ref = max(ref, AudioFeatureExtractor.agcRefFloor)
            return min(1.0, (value / ref) * 0.8)
        }

        mutating func reset() { ref = AudioFeatureExtractor.agcRefFloor }
    }

    // ── State (audio-tap thread only, except the locked ring) ──
    private let spectrum = AudioSpectrumProcessor()
    private var agcLevel  = AGCTracker()
    private var agcBass   = AGCTracker()
    private var agcMid    = AGCTracker()
    private var agcTreble = AGCTracker()

    private var prevMagnitudes: [Float] = []
    private var fluxHistory: [Float] = []          // trailing window for threshold
    private var thresholdScratch: [Float] = []     // preallocated sort buffer
    private var recentFluxPeak: Float = 0.001      // for onsetStrength normalization
    private var lastOnsetAt: Double = 0
    private var lastHopTime: Double = 0

    // Onset-envelope ring (cross-thread: tap writes, tempo pass reads).
    private var ringLock = os_unfair_lock()
    private var ring = [Float](repeating: 0, count: AudioFeatureExtractor.ringCapacity)
    private var ringWriteIndex = 0
    private var ringCount = 0
    private var ringHopRate: Double = 43.0
    private var ringEndTime: Double = 0

    // MARK: - Process one hop

    /// Analyze one audio buffer. `hostTime` is the capture time in the
    /// CACurrentMediaTime timebase (injectable for tests).
    /// Returns nil for sub-64-frame buffers.
    func process(
        data: UnsafePointer<Float>,
        frameCount: Int,
        sampleRate: Float,
        hostTime: Double
    ) -> AudioFeatures? {
        guard let frame = spectrum.analyze(data: data, frameCount: frameCount, sampleRate: sampleRate) else {
            return nil
        }
        let halfN    = frame.halfN
        let hzPerBin = frame.hzPerBin
        let dt = Float(lastHopTime > 0 ? max(0.001, hostTime - lastHopTime) : Double(frame.fftN) / Double(sampleRate))
        lastHopTime = hostTime

        var features = AudioFeatures()
        features.timestamp = hostTime

        // ── Bands (same bin arithmetic + scaling as VisualizerEngine) ──
        let bassEnd = max(1, Int(200 / hzPerBin))
        let midEnd  = max(bassEnd + 1, Int(2000 / hzPerBin))
        let highEnd = min(max(midEnd + 1, Int(16000 / hzPerBin)), halfN)

        let bassAvg   = spectrum.average(bins: 1..<min(bassEnd, halfN))
        let midAvg    = spectrum.average(bins: min(bassEnd, halfN)..<min(midEnd, halfN))
        let trebleAvg = spectrum.average(bins: min(midEnd, halfN)..<min(highEnd, halfN))

        features.rawOverall = min(frame.rms * 10.0, 1.0)
        features.rawBass    = min(bassAvg   * 30.0, 1.0)
        features.rawMid     = min(midAvg    * 20.0, 1.0)
        features.rawTreble  = min(trebleAvg * 40.0, 1.0)

        // ── AGC-normalized (gated below the noise floor) ──
        if frame.rms < Self.noiseFloorRMS {
            features.level = 0; features.bass = 0; features.mid = 0; features.treble = 0
        } else {
            features.level  = agcLevel.normalize(frame.rms, dt: dt)
            features.bass   = agcBass.normalize(bassAvg,    dt: dt)
            features.mid    = agcMid.normalize(midAvg,      dt: dt)
            features.treble = agcTreble.normalize(trebleAvg, dt: dt)
        }

        // ── Bass-weighted spectral flux ──
        var flux: Float = 0
        let mags = spectrum.magnitudes
        if prevMagnitudes.count == halfN {
            let weightEnd = min(Int(500 / hzPerBin), halfN)
            for i in 1..<halfN {
                let rise = mags[i] - prevMagnitudes[i]
                if rise > 0 {
                    flux += i < weightEnd ? rise * 2.0 : rise
                }
            }
        } else {
            prevMagnitudes = [Float](repeating: 0, count: halfN)
        }
        for i in 0..<halfN { prevMagnitudes[i] = mags[i] }

        // Gate flux in silence so the ring holds true zeros between songs.
        if frame.rms < Self.noiseFloorRMS { flux = 0 }

        // ── Adaptive threshold: median + 1.5×MAD over trailing ~1 s ──
        var isOnset = false
        if fluxHistory.count >= 8 {
            let m = median(of: fluxHistory)
            let mad = medianAbsoluteDeviation(of: fluxHistory, median: m)
            let threshold = m + 1.5 * mad + 0.0005
            if flux > threshold,
               hostTime - lastOnsetAt >= Self.onsetRefractory {
                isOnset = true
                lastOnsetAt = hostTime
            }
        }
        fluxHistory.append(flux)
        if fluxHistory.count > Self.thresholdWindow { fluxHistory.removeFirst() }

        // onsetStrength: flux normalized by a slowly-decaying recent peak.
        recentFluxPeak = max(flux, recentFluxPeak * (1 - dt / 3.0))
        recentFluxPeak = max(recentFluxPeak, 0.001)
        features.onsetStrength = min(1.0, flux / recentFluxPeak)
        features.isOnset = isOnset
        features.lastOnsetAt = lastOnsetAt

        // ── Append to the tempo ring ──
        os_unfair_lock_lock(&ringLock)
        ring[ringWriteIndex] = flux
        ringWriteIndex = (ringWriteIndex + 1) % Self.ringCapacity
        ringCount = min(ringCount + 1, Self.ringCapacity)
        ringHopRate = Double(sampleRate) / Double(frame.fftN)
        ringEndTime = hostTime
        os_unfair_lock_unlock(&ringLock)

        return features
    }

    /// Copy the onset envelope (oldest → newest) for the tempo pass.
    /// Safe to call from any thread.
    func onsetEnvelopeSnapshot() -> (envelope: [Float], hopRate: Double, endTime: Double) {
        os_unfair_lock_lock(&ringLock)
        defer { os_unfair_lock_unlock(&ringLock) }
        guard ringCount > 0 else { return ([], ringHopRate, 0) }
        var out = [Float](repeating: 0, count: ringCount)
        let start = (ringWriteIndex - ringCount + Self.ringCapacity) % Self.ringCapacity
        for i in 0..<ringCount {
            out[i] = ring[(start + i) % Self.ringCapacity]
        }
        return (out, ringHopRate, ringEndTime)
    }

    func reset() {
        agcLevel.reset(); agcBass.reset(); agcMid.reset(); agcTreble.reset()
        prevMagnitudes = []
        fluxHistory = []
        recentFluxPeak = 0.001
        lastOnsetAt = 0
        lastHopTime = 0
        os_unfair_lock_lock(&ringLock)
        ringWriteIndex = 0
        ringCount = 0
        ringEndTime = 0
        os_unfair_lock_unlock(&ringLock)
    }

    // MARK: - Small stats helpers (preallocated scratch, no per-hop alloc
    // once warm — thresholdScratch grows to the window size and stays)

    private func median(of values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        if thresholdScratch.count != values.count {
            thresholdScratch = values
        } else {
            for i in 0..<values.count { thresholdScratch[i] = values[i] }
        }
        thresholdScratch.sort()
        return thresholdScratch[thresholdScratch.count / 2]
    }

    private func medianAbsoluteDeviation(of values: [Float], median m: Float) -> Float {
        guard !values.isEmpty else { return 0 }
        if thresholdScratch.count != values.count {
            thresholdScratch = values
        }
        for i in 0..<values.count { thresholdScratch[i] = abs(values[i] - m) }
        thresholdScratch.sort()
        return thresholdScratch[thresholdScratch.count / 2]
    }
}
