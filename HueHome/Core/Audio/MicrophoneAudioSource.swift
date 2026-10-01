// MicrophoneAudioSource.swift
// ChromaGlow — Core/Audio (audio-source boundary)
//
// The shipped microphone capture, moved out of AudioAnalysisEngine when the
// engine stopped assuming the mic: same permission flow (L-19/L-22), same
// .playAndRecord/.measurement + .mixWithOthers session, same
// format-before-tap guard, same 1024-frame input tap, same hardware-
// reconfiguration watch. The tap now hands each buffer to
// AudioPCMSink.deliver(buffer:sampleRate:when:), which runs the exact
// extract → publish → fan-out sequence the inline tap ran.
//
// Privacy: raw audio never leaves the process and is never persisted.

import AVFoundation
import Foundation
import os

@MainActor
final class MicrophoneAudioSource: AudioAnalysisSource {
    let kind: AudioAnalysisSourceKind = .microphone
    var onSystemStop: (@MainActor () async -> Void)?

    private let log = Logger(subsystem: "com.lightshade.app", category: "AudioEngine")
    private var audioEngine: AVAudioEngine?
    /// The `.AVAudioEngineConfigurationChange` observer for THIS source's
    /// engine only — registered after its `start()`, removed by `stop`.
    private var configurationChangeObserver: NSObjectProtocol?

    /// We started an engine AND it is still running (a configuration change
    /// stops and uninitializes it behind our back).
    var isLive: Bool { audioEngine?.isRunning == true }

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
            //
            // .allowBluetoothA2DP, NOT .allowBluetoothHFP: HFP is the call
            // profile — enabling it moves input to the headset mic and drops
            // whatever the phone is playing to call-quality mono on the
            // Bluetooth output, which is exactly the ducking-by-another-name
            // .mixWithOthers promises never to do. A2DP keeps music at full
            // quality on the headphones while the built-in mic listens to the
            // room. (The option was .allowBluetooth, renamed HFP by the SDK —
            // no record anywhere chose headset-mic input deliberately.)
            try session.setCategory(
                .playAndRecord, mode: .measurement,
                options: [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker]
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

            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, when in
                // Audio thread: extract features, publish, fan out. No Tasks,
                // no actor hops, no allocations beyond the extractor's warm-up.
                sink.deliver(buffer: buffer, sampleRate: sampleRate, when: when)
            }

            try engine.start()
            audioEngine = engine
            observeConfigurationChange(of: engine)
            return true
        } catch {
            log.error("Audio analysis engine failed: \(error.localizedDescription)")
            input.removeTap(onBus: 0)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            audioEngine = nil
            // Permission is GRANTED on this path (the denials returned in
            // prepare): this is the session, the route or the engine failing
            // to start. Posting `.compositionMicPermissionDenied` here told
            // the user to "enable access in Settings" for a switch that was
            // already on.
            NotificationCenter.default.post(name: .compositionMicCaptureFailed, object: nil)
            return false
        }
    }

    func stop(deactivatingSession: Bool) {
        if let configurationChangeObserver {
            NotificationCenter.default.removeObserver(configurationChangeObserver)
            self.configurationChangeObserver = nil
        }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        if deactivatingSession { Self.deactivateSession() }
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

    // MARK: - Hardware reconfiguration

    /// iOS posts `.AVAudioEngineConfigurationChange` when the I/O hardware's
    /// channel count or sample rate changes (a Bluetooth route coming or
    /// going, a sample-rate switch) — and it has already STOPPED and
    /// uninitialized the engine by then. Nothing else says so: the route
    /// change handler saw a running engine and left the dead one alone,
    /// `latestFeatures()` kept serving the last hop's levels, and
    /// `setDemand(true)` reported capture that was not happening.
    ///
    /// Scoped to THIS engine (`object:`), and re-checked by identity on the
    /// main actor, so a notification that arrives after a rebuild cannot tear
    /// down its successor (the engine re-checks the source's identity too).
    private func observeConfigurationChange(of engine: AVAudioEngine) {
        if let configurationChangeObserver {
            NotificationCenter.default.removeObserver(configurationChangeObserver)
        }
        let engineID = ObjectIdentifier(engine)
        configurationChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let current = self.audioEngine,
                      ObjectIdentifier(current) == engineID else { return }
                await self.onSystemStop?()
            }
        }
    }
}
