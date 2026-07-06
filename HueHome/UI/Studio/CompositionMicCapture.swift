// CompositionMicCapture.swift
// ChromaGlow — Composer mic input for reaction layer (FFT + smoothing).
//
// UnifiedOrchestrator calls syncDemand from composition loops. Posts
// composerMicExclusiveBegan before starting so SyncModeEngine can release
// its AVAudioEngine and avoid dual-session fights.

import AVFoundation
import Accelerate
import Foundation
import os
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Lock-free level store (audio thread writes, render thread reads)

private enum ComposerMicLevels {
    nonisolated(unsafe) static var lock = os_unfair_lock()
    nonisolated(unsafe) static var sOverall: Float = 0
    nonisolated(unsafe) static var sBass: Float = 0
    nonisolated(unsafe) static var sMid: Float = 0
    nonisolated(unsafe) static var sTreble: Float = 0

    /// L-20: cached FFT pipeline. Single-writer contract holds because the
    /// composer-mic exclusivity handshake (`composerMicExclusiveBegan`)
    /// guarantees only one engine's audio tap runs at a time.
    nonisolated(unsafe) static let fft = AudioSpectrumProcessor()

    nonisolated static func reset() {
        os_unfair_lock_lock(&lock)
        sOverall = 0
        sBass = 0
        sMid = 0
        sTreble = 0
        os_unfair_lock_unlock(&lock)
    }

    /// FFT + band splits aligned with VisualizerEngine.process (same scaling).
    /// L-20: runs on the cached AudioSpectrumProcessor — the previous inline
    /// pipeline created/destroyed the FFT setup and reallocated every buffer
    /// on each ~43 Hz callback.
    nonisolated static func analyze(buffer: AVAudioPCMBuffer, sampleRate: Float) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)

        guard let frame = fft.analyze(data: data, frameCount: n, sampleRate: sampleRate) else { return }
        let halfN    = frame.halfN
        let hzPerBin = frame.hzPerBin
        let overallRaw = min(frame.rms * 10.0, 1.0)

        let bassEnd = max(1, Int(200 / hzPerBin))
        let midEnd = max(bassEnd + 1, Int(2000 / hzPerBin))
        let highEnd = min(max(midEnd + 1, Int(16000 / hzPerBin)), halfN)

        let bassRaw = min(fft.average(bins: 1..<min(bassEnd, halfN)) * 30.0, 1.0)
        let midRaw = min(fft.average(bins: min(bassEnd, halfN)..<min(midEnd, halfN)) * 20.0, 1.0)
        let trebleRaw = min(fft.average(bins: min(midEnd, halfN)..<min(highEnd, halfN)) * 40.0, 1.0)

        let snap: Float = 0.3
        let atk: Float = 0.7
        let decO: Float = 0.65
        let decB: Float = 0.70
        let decM: Float = 0.72
        let decT: Float = 0.68

        os_unfair_lock_lock(&lock)

        func smooth(_ s: inout Float, _ new: Float, _ decay: Float) {
            if abs(new - s) > snap {
                s = new
            } else if new > s {
                s = s * (1 - atk) + new * atk
            } else {
                s *= decay
            }
        }

        smooth(&sOverall, overallRaw, decO)
        smooth(&sBass, bassRaw, decB)
        smooth(&sMid, midRaw, decM)
        smooth(&sTreble, trebleRaw, decT)

        os_unfair_lock_unlock(&lock)
    }

    nonisolated static func read(for source: ReactionConfig.Source) -> Float {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        switch source {
        case .micAmplitude:
            return sOverall
        case .micBass:
            return sBass
        case .micMid:
            return sMid
        case .micTreble:
            return sTreble
        case .none, .tapTempo:
            return 0
        case .beat, .onset:
            // Beat/onset drives come from BeatClock/AudioFeatures, not a
            // scalar mic level (mic demand still keeps the engine running
            // so the clock can follow audio).
            return 0
        }
    }
}

// MARK: - Capture session

@MainActor
final class CompositionMicCapture {
    static let shared = CompositionMicCapture()

    private let log = Logger(subsystem: "com.lightshade.app", category: "ComposerMic")

    private var desiredActive = false
    private var engineRunning = false
    private var audioEngine: AVAudioEngine?

    private var ncObservers: [NSObjectProtocol] = []

    private init() {
        #if canImport(UIKit)
        ncObservers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { await self?.handleAppBackground() }
            }
        )
        ncObservers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { await self?.handleAppForeground() }
            }
        )
        #endif
        ncObservers.append(
            NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                Task { await self?.handleInterruption(note) }
            }
        )
    }

    deinit {
        for o in ncObservers {
            NotificationCenter.default.removeObserver(o)
        }
    }

    /// Latest-wins: orchestrator calls each scheduler tick / entertainment frame with aggregate demand.
    func syncDemand(_ wantsMic: Bool) async {
        if wantsMic == desiredActive {
            if wantsMic && !engineRunning { await startEngineIfNeeded() }
            return
        }
        desiredActive = wantsMic
        if wantsMic {
            NotificationCenter.default.post(name: .composerMicExclusiveBegan, object: nil)
            // Brief yield so SyncModeEngine can tear down its AVAudioEngine (~single-digit ms)
            // before we configure playAndRecord. Shorter than legacy 60ms — parallel bridge work
            // (gamut fetch, entertainment handshake) covers remaining settle time.
            try? await Task.sleep(for: .milliseconds(35))
            await startEngineIfNeeded()
        } else {
            stopEngine()
        }
    }

    /// Normalized 0…1 level for mic reaction sources (thread-safe read).
    nonisolated static func reactionAudioLevel(for reaction: ReactionConfig) -> Float {
        guard reaction.requiresMic else { return 0 }
        return ComposerMicLevels.read(for: reaction.source)
    }

    private func handleAppBackground() async {
        guard desiredActive else { return }
        stopEngine()
    }

    private func handleAppForeground() async {
        guard desiredActive else { return }
        await startEngineIfNeeded()
    }

    private func handleInterruption(_ note: Notification) async {
        guard let info = note.userInfo,
              let typeVal = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeVal)
        else { return }
        switch type {
        case .began:
            stopEngine()
        case .ended:
            if desiredActive {
                await startEngineIfNeeded()
            }
        @unknown default:
            break
        }
    }

    private func startEngineIfNeeded() async {
        guard desiredActive else { return }
        guard !engineRunning else { return }

#if os(iOS)
        // L-22: AVAudioApplication permission API — AVAudioSession.recordPermission
        // is deprecated in iOS 17. Same pattern as SyncModeEngine.
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined:
            let granted = await AVAudioApplication.requestRecordPermission()
            if !granted {
                log.warning("Composition mic permission denied (user)")
                NotificationCenter.default.post(name: .compositionMicPermissionDenied, object: nil)
                return
            }
            // L-19: demand may have dropped (composition stopped) while the
            // system prompt was up — starting anyway leaves the mic live with
            // the orange indicator on and no consumer.
            guard desiredActive, !engineRunning else { return }
        case .denied:
            log.warning("Composition mic permission denied (settings)")
            NotificationCenter.default.post(name: .compositionMicPermissionDenied, object: nil)
            return
        case .granted:
            break
        @unknown default:
            break
        }
#endif

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let bufferSize: AVAudioFrameCount = 1024

        input.installTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, _ in
            ComposerMicLevels.analyze(buffer: buffer, sampleRate: Float(format.sampleRate))
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true, options: [])
            try engine.start()
            audioEngine = engine
            engineRunning = true
            log.info("Composition mic engine started")
        } catch {
            log.error("Composition mic engine failed: \(error.localizedDescription)")
            input.removeTap(onBus: 0)
            audioEngine = nil
            NotificationCenter.default.post(name: .compositionMicPermissionDenied, object: nil)
        }
    }

    private func stopEngine() {
        engineRunning = false
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            log.debug("Session deactivate: \(error.localizedDescription)")
        }
        ComposerMicLevels.reset()
    }
}
