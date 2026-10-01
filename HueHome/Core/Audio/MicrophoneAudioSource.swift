// MicrophoneAudioSource.swift
// ChromaGlow — Core/Audio (audio-source boundary)
//
// The shipped microphone capture, moved verbatim out of AudioAnalysisEngine
// when the engine stopped assuming the mic: same permission flow (L-19/L-22),
// same .playAndRecord/.measurement + .mixWithOthers session, same
// format-before-tap guard, same 1024-frame input tap. The tap now hands each
// buffer to AudioPCMSink.deliver(buffer:sampleRate:), which runs the exact
// extract → publish → fan-out sequence the inline tap ran.
//
// Privacy: raw audio never leaves the process and is never persisted.

import AVFoundation
import Foundation
import os

@MainActor
final class MicrophoneAudioSource: AudioAnalysisSource {
    let kind: AudioAnalysisSourceKind = .microphone

    private let log = Logger(subsystem: "com.lightshade.app", category: "AudioEngine")
    private var audioEngine: AVAudioEngine?

    func prepare(stillWanted: @MainActor () -> Bool) async -> Bool {
        // Permission (modern API; L-22 pattern).
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined:
            let granted = await AVAudioApplication.requestRecordPermission()
            // Demand may have been withdrawn while the prompt was up (L-19).
            guard stillWanted() else { return false }
            if !granted {
                log.warning("Mic permission denied (prompt)")
                NotificationCenter.default.post(name: .compositionMicPermissionDenied, object: nil)
                return false
            }
            return true
        case .denied:
            log.warning("Mic permission denied (settings)")
            NotificationCenter.default.post(name: .compositionMicPermissionDenied, object: nil)
            return false
        case .granted:
            return true
        @unknown default:
            return true
        }
    }

    func start(sink: AudioPCMSink) -> Bool {
        let engine = AVAudioEngine()
        let input = engine.inputNode

        do {
            let session = AVAudioSession.sharedInstance()
            // .mixWithOthers: the DJ use case plays music from this phone —
            // capture must never duck or pause it. .measurement: raw input,
            // no system voice processing.
            try session.setCategory(
                .playAndRecord, mode: .measurement,
                options: [.mixWithOthers, .allowBluetoothHFP, .defaultToSpeaker]
            )
            try session.setActive(true, options: [])

            // Read the input format ONLY after the session is active. Before
            // activation — e.g. a background→foreground restart that fires
            // before the hardware route is restored — it comes back as a null
            // 0 Hz / 0 ch format, and installTap() with that throws an
            // *uncatchable* AVFoundation assertion (CreateRecordingTap:
            // IsFormatSampleRateAndChannelCountValid) that terminates the app.
            // Guard, don't crash: bail and let a routeChange / mediaReset (or
            // the next demand toggle) retry once the route is ready.
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                log.warning("Input format not ready (\(format.sampleRate)Hz/\(format.channelCount)ch) — deferring tap; will retry on route change")
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                return false
            }
            let sampleRate = Float(format.sampleRate)

            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                // Audio thread: extract features, publish, fan out. No Tasks,
                // no actor hops, no allocations beyond the extractor's warm-up.
                sink.deliver(buffer: buffer, sampleRate: sampleRate)
            }

            try engine.start()
            audioEngine = engine
            return true
        } catch {
            log.error("Audio analysis engine failed: \(error.localizedDescription)")
            input.removeTap(onBus: 0)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            audioEngine = nil
            NotificationCenter.default.post(name: .compositionMicPermissionDenied, object: nil)
            return false
        }
    }

    func stop() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        Self.deactivateSession()
    }

    /// The engine's stop path always released the session, even when nothing
    /// was running (backgrounding, interruption) — kept exactly so.
    static func deactivateSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            Logger(subsystem: "com.lightshade.app", category: "AudioEngine")
                .debug("Session deactivate: \(error.localizedDescription)")
        }
    }
}
