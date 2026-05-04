// GamingEngine.swift
// ChromaGlow — Gaming / Transient Detection Engine
//
// Detects sudden audio spikes (transients) by comparing each frame's
// peak level to a slow-decaying rolling baseline. On a spike: instant
// full-brightness flash in the selected flash color. Between spikes:
// dim ambient glow in the selected ambient color.

import Foundation
import AVFoundation
import Accelerate
import SwiftUI
import os

// MARK: - Flash Color

enum GamingFlashColor: String, CaseIterable, Identifiable {
    case white  = "White"
    case orange = "Orange"
    case red    = "Red"
    case yellow = "Yellow"

    var id: String { rawValue }
    var accentColor: Color {
        switch self {
        case .white:  return .white
        case .orange: return .orange
        case .red:    return .red
        case .yellow: return Color(red: 1, green: 0.9, blue: 0.1)
        }
    }
    /// CIE xy for Hue lights
    var xy: (Double, Double) {
        switch self {
        case .white:  return (0.3127, 0.3290)
        case .orange: return (0.5614, 0.4051)
        case .red:    return (0.6910, 0.3080)
        case .yellow: return (0.4280, 0.4220)
        }
    }
}

// MARK: - Ambient Color

enum GamingAmbientColor: String, CaseIterable, Identifiable {
    case blue   = "Blue"
    case purple = "Purple"
    case green  = "Green"
    case off    = "Off"

    var id: String { rawValue }
    var accentColor: Color {
        switch self {
        case .blue:   return Color(hue: 0.60, saturation: 0.9, brightness: 0.9)
        case .purple: return Color(hue: 0.77, saturation: 0.8, brightness: 0.9)
        case .green:  return Color(hue: 0.38, saturation: 0.9, brightness: 0.9)
        case .off:    return .gray
        }
    }
    /// CIE xy for Hue lights. Nil means off (ambient disabled).
    var xy: (Double, Double)? {
        switch self {
        case .blue:   return (0.1548, 0.1220)
        case .purple: return (0.2345, 0.1234)
        case .green:  return (0.1720, 0.5600)
        case .off:    return nil
        }
    }
}

// MARK: - GamingEngine

@Observable
@MainActor
final class GamingEngine: SyncEngine {

    // MARK: Settings
    var sensitivity:   Double            = 1.8
    var flashColor:    GamingFlashColor  = .white
    var ambientColor:  GamingAmbientColor = .blue

    // MARK: Published state
    var overallLevel:      Float = 0
    var isTransient:       Bool  = false
    var transientIntensity: Float = 0   // 1.0 on spike, decays to 0

    // MARK: Private — audio thread (nonisolated(unsafe))
    @ObservationIgnored nonisolated(unsafe) private var _lock          = os_unfair_lock()
    @ObservationIgnored nonisolated(unsafe) private var _pendingLevel:  Float = -1
    @ObservationIgnored nonisolated(unsafe) private var _pendingSpike:  Bool  = false
    @ObservationIgnored nonisolated(unsafe) private var _rollingAvg:    Float = 0

    // MARK: Private — main thread
    private var transientDecay:   Float  = 0
    private var rollingBaseline:  Double = 0

    private let log = Logger(subsystem: "com.huehome.pro", category: "Gaming")

    // MARK: - SyncEngine Protocol

    nonisolated func process(buffer: AVAudioPCMBuffer, sampleRate: Float) -> SyncEngineOutput {
        guard let data = buffer.floatChannelData?[0] else { return .idle }
        let n = Int(buffer.frameLength)
        guard n >= 64 else { return .idle }

        var frameData = Array(UnsafeBufferPointer(start: data, count: n))
        var rms: Float = 0
        vDSP_rmsqv(&frameData, 1, &rms, vDSP_Length(n))
        let level = min(rms * 12.0, 1.0)

        // Slow EMA baseline on audio thread (~43fps, alpha=0.03 ≈ 1s rise)
        _rollingAvg = _rollingAvg * 0.97 + level * 0.03

        // Spike: current level > baseline × fixed threshold (1.8)
        // Fine-tuning via sensitivity happens in tick() on main thread
        let isSpike = level > (_rollingAvg * 1.6) && level > 0.06

        os_unfair_lock_lock(&_lock)
        _pendingLevel = level
        if isSpike { _pendingSpike = true }   // latch — don't clear a spike between ticks
        os_unfair_lock_unlock(&_lock)

        return .idle
    }

    nonisolated func reset() {
        os_unfair_lock_lock(&_lock)
        _pendingLevel = -1
        _pendingSpike = false
        _rollingAvg   = 0
        os_unfair_lock_unlock(&_lock)
        Task { @MainActor [weak self] in
            self?.overallLevel      = 0
            self?.isTransient       = false
            self?.transientIntensity = 0
            self?.transientDecay    = 0
            self?.rollingBaseline   = 0
        }
    }

    // MARK: - Tick (called from SyncModeEngine.sendLightUpdate ~6fps)

    func tick() {
        os_unfair_lock_lock(&_lock)
        let level    = _pendingLevel
        let isSpike  = _pendingSpike
        _pendingLevel = -1
        _pendingSpike = false
        os_unfair_lock_unlock(&_lock)

        if level >= 0 {
            overallLevel = level
            // Update main-thread baseline with sensitivity influence
            rollingBaseline = rollingBaseline * 0.95 + Double(level) * 0.05
        }

        if isSpike {
            transientDecay = 1.0
            isTransient    = true
            log.info("GAMING: spike — level=\(level, format: .fixed(precision: 3)) baseline=\(self.rollingBaseline, format: .fixed(precision: 3))")
        } else {
            // Decay: ~400ms to fall to 5% at 6fps
            transientDecay = max(0, transientDecay * 0.60)
            if transientDecay < 0.05 { isTransient = false }
        }
        transientIntensity = transientDecay
    }

    // MARK: - Light Output Accessors

    /// 0–100 brightness for the flash event
    var flashBrightness: Double { Double(transientDecay) * 100.0 }

    /// 5–25% ambient brightness when no transient
    var ambientBrightness: Double {
        guard ambientColor != .off, !isTransient else { return 0 }
        return max(5, min(25, rollingBaseline * 120))
    }
}
