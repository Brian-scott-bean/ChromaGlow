// AmbientEngine.swift
// ChromaGlow — Ambient Floor Breather
//
// Passive mode: detects whether someone is present in the room by tracking
// a long-window RMS average, then breathes lights slowly with a sine wave.
//
// Presence detected  → smooth sine pulse (configurable speed + depth)
// Silence / no one   → lights fade to a dim floor level
//
// No spikes, no reactivity — this is the calm, always-on ambient mode.

import Foundation
import AVFoundation
import Accelerate
import SwiftUI
import os

// MARK: - Pulse Speed

enum AmbientPulseSpeed: String, CaseIterable, Identifiable {
    case slow   = "Slow"
    case medium = "Medium"
    case fast   = "Fast"

    var id: String { rawValue }

    /// Sine wave period in seconds
    var period: Double {
        switch self {
        case .slow:   return 6.0
        case .medium: return 3.5
        case .fast:   return 2.0
        }
    }
}

// MARK: - Ambient Color Mode

enum AmbientColorMode: String, CaseIterable, Identifiable {
    case warm    = "Warm"
    case cool    = "Cool"
    case neutral = "Neutral"

    var id: String { rawValue }

    var accentColor: Color {
        switch self {
        case .warm:    return Color(hue: 0.08, saturation: 0.9, brightness: 0.95)
        case .cool:    return Color(hue: 0.60, saturation: 0.85, brightness: 0.95)
        case .neutral: return .white
        }
    }

    /// CIE xy for Hue lights
    var xy: (Double, Double)? {
        switch self {
        case .warm:    return nil   // use mirek 400 (warm white)
        case .cool:    return nil   // use mirek 200 (cool white)
        case .neutral: return nil   // use mirek 300 (neutral)
        }
    }

    /// Mirek color temperature
    var mirek: Int {
        switch self {
        case .warm:    return 400
        case .cool:    return 200
        case .neutral: return 300
        }
    }
}

// MARK: - AmbientEngine

@Observable
@MainActor
final class AmbientEngine: SyncEngine {

    // MARK: Settings
    var baseBrightness: Double  = 30.0   // 10–80%
    var pulseDepth:     Double  = 20.0   // ±brightness swing
    var pulseSpeed:     AmbientPulseSpeed = .medium
    var colorMode:      AmbientColorMode  = .warm
    var presenceThreshold: Double = 0.015 // RMS floor for presence detection

    // MARK: Published state (UI)
    var presenceDetected: Bool  = false
    var currentBrightness: Double = 0
    var breathPhase: Double = 0     // 0–1, drives the UI breath ring

    // MARK: Private — audio thread
    @ObservationIgnored nonisolated(unsafe) private var _lock       = os_unfair_lock()
    @ObservationIgnored nonisolated(unsafe) private var _pendingRMS: Float = -1

    // MARK: Private — main thread
    private var smoothedRMS:  Double = 0
    private var phaseOffset:  Double = 0          // cumulative sine phase (radians)
    private var lastTickTime: Date   = .distantPast
    private var presenceFade: Double = 0          // 0→1 fade-in on presence, 1→0 fade-out

    private let log = Logger(subsystem: "com.huehome.pro", category: "Ambient")

    // MARK: - SyncEngine Protocol

    nonisolated func process(buffer: AVAudioPCMBuffer, sampleRate: Float) -> SyncEngineOutput {
        guard let data = buffer.floatChannelData?[0] else { return .idle }
        let n = Int(buffer.frameLength)
        guard n >= 64 else { return .idle }

        var frameData = Array(UnsafeBufferPointer(start: data, count: n))
        var rms: Float = 0
        vDSP_rmsqv(&frameData, 1, &rms, vDSP_Length(n))

        os_unfair_lock_lock(&_lock)
        _pendingRMS = rms
        os_unfair_lock_unlock(&_lock)

        return .idle
    }

    nonisolated func reset() {
        os_unfair_lock_lock(&_lock)
        _pendingRMS = -1
        os_unfair_lock_unlock(&_lock)
        Task { @MainActor [weak self] in
            self?.smoothedRMS    = 0
            self?.presenceFade   = 0
            self?.presenceDetected = false
            self?.currentBrightness = 0
            self?.breathPhase    = 0
            self?.phaseOffset    = 0
            self?.lastTickTime   = .distantPast
        }
    }

    // MARK: - Tick (called from SyncModeEngine at send cadence ~500ms)

    /// Advances the breath phase and returns the target brightness for this tick.
    /// Returns nil if lights should be left alone (no change needed).
    func tick() -> Double? {
        os_unfair_lock_lock(&_lock)
        let rms = _pendingRMS
        _pendingRMS = -1
        os_unfair_lock_unlock(&_lock)

        let now = Date()
        let dt = lastTickTime == .distantPast ? 0.5 : now.timeIntervalSince(lastTickTime)
        lastTickTime = now

        // Update smoothed RMS (slow EMA ~2s window)
        if rms >= 0 {
            smoothedRMS = smoothedRMS * 0.92 + Double(rms) * 0.08
        }

        // Presence detection
        let isPresent = smoothedRMS > presenceThreshold
        presenceDetected = isPresent

        // Fade presence in/out smoothly (~1s transition)
        if isPresent {
            presenceFade = min(1.0, presenceFade + dt * 1.0)
        } else {
            presenceFade = max(0.0, presenceFade - dt * 0.5)
        }

        // Advance sine phase
        phaseOffset += dt * (2.0 * .pi) / pulseSpeed.period
        let sine = sin(phaseOffset)  // -1 to +1

        // Target brightness:
        // presence → base ± pulseDepth * presenceFade
        // silence  → dim floor (baseBrightness * 0.2)
        let silenceFloor = baseBrightness * 0.2
        let pulseBri = baseBrightness + (sine * pulseDepth * presenceFade)
        let targetBri = pulseBri * presenceFade + silenceFloor * (1.0 - presenceFade)
        let clampedBri = max(0, min(100, targetBri))

        currentBrightness = clampedBri
        breathPhase = (sine + 1.0) / 2.0   // normalize to 0–1 for UI ring

        log.info("AMBIENT: rms=\(self.smoothedRMS, format: .fixed(precision: 4)) present=\(isPresent) fade=\(self.presenceFade, format: .fixed(precision: 2)) bri=\(clampedBri, format: .fixed(precision: 1))")

        return clampedBri
    }
}
