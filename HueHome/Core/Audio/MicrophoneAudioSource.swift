// MicrophoneAudioSource.swift
// ChromaGlow — Core/Audio (audio-source boundary)
//
// The shipped microphone capture, moved out of AudioAnalysisEngine when the
// engine stopped assuming the mic: same permission flow (L-19/L-22), same
// .playAndRecord/.measurement + .mixWithOthers session, same format-before-
// capture guard, same hardware-reconfiguration watch.
//
// Low-latency capture (chunk 2): an `installTap` block arrives in ~100 ms
// buffers whatever size it asks for, so analysis saw the room ten times a
// second. The session now asks for ~5 ms I/O cycles and an AVAudioSinkNode
// receives every one on the real-time I/O thread, which only copies the
// samples into a MicrophoneHopRelay; the relay's thread delivers 1024-frame
// hops (~21 ms) into AudioPCMSink.deliver(hop:…), which runs the same
// extract → publish → fan-out sequence the tap ran.
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
    /// Hands captured audio from the I/O thread to analysis (one per start).
    private var relay: MicrophoneHopRelay?

    /// The I/O cycle the session asks for. A request, not a promise: iOS
    /// rounds it to what the hardware and the current route allow, and may
    /// keep a longer cycle another app's audio already set. The relay
    /// re-blocks whatever size arrives, so a longer cycle costs latency only.
    static let preferredIOBufferDuration: TimeInterval = 0.005
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
            // Small I/O cycles, asked for before activation (where the
            // request takes effect). Failing to get them is not a failure to
            // capture — only a longer wait per hop.
            try? session.setPreferredIOBufferDuration(Self.preferredIOBufferDuration)
            try session.setActive(true, options: [])
            // Play Along: stamp onset frames when the sound reached the mic,
            // not when iOS time-stamped the buffer (read while the session is
            // configured here, not as a separate main-thread session call).
            sink.onsets?.setInputLatency(session.inputLatency)

            // Read the input format ONLY after the session is active. Before
            // activation — e.g. a background→foreground restart that fires
            // before the hardware route is restored — it comes back as a null
            // 0 Hz / 0 ch format, and capturing with that throws an
            // *uncatchable* AVFoundation assertion (CreateRecordingTap:
            // IsFormatSampleRateAndChannelCountValid) that terminates the app.
            // Guard, don't crash: bail and let a routeChange / mediaReset (or
            // the next demand toggle) retry once the route is ready.
            let format = input.outputFormat(forBus: 0)
            guard Self.isUsable(format) else {
                log.warning("Input format not ready (\(format.sampleRate)Hz/\(format.channelCount)ch) — deferring capture; will retry on route change")
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                return false
            }

            if !UserDefaults.standard.bool(forKey: Self.legacyTapDefaultsKey) {
                do {
                    relay = try startSinkCapture(engine: engine, format: format, sink: sink)
                    audioEngine = engine
                    observeConfigurationChange(of: engine)
                    return true
                } catch {
                    // Never worse than before: the tap still captures, only
                    // in ~100 ms buffers.
                    log.error("Low-latency capture failed (\(error.localizedDescription)) — falling back to the tap")
                    engine.stop()
                }
            }
            let tapEngine = AVAudioEngine()
            try startTapCapture(engine: tapEngine, sink: sink)
            audioEngine = tapEngine
            observeConfigurationChange(of: tapEngine)
            return true
        } catch {
            log.error("Audio analysis engine failed: \(error.localizedDescription)")
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            audioEngine = nil
            relay = nil
            // Permission is GRANTED on this path (the denials returned in
            // prepare): this is the session, the route or the engine failing
            // to start. Posting `.compositionMicPermissionDenied` here told
            // the user to "enable access in Settings" for a switch that was
            // already on.
            NotificationCenter.default.post(name: .compositionMicCaptureFailed, object: nil)
            return false
        }
    }

    /// The old ~100 ms tap, for side-by-side checks on a device:
    /// `defaults write com.huehome.pro audio.legacyMicTap -bool YES`. Read when
    /// capture starts. Also the fallback when the sink cannot start.
    static let legacyTapDefaultsKey = "audio.legacyMicTap"

    private static func isUsable(_ format: AVAudioFormat) -> Bool {
        format.sampleRate > 0 && format.channelCount > 0 && format.commonFormat == .pcmFormatFloat32
    }

    /// Low-latency capture: input → AVAudioSinkNode → relay → analysis.
    /// Returns the started relay; on a throw nothing is left running.
    private func startSinkCapture(engine: AVAudioEngine, format: AVAudioFormat,
                                  sink: AudioPCMSink) throws -> MicrophoneHopRelay {
        let sampleRate = format.sampleRate
        // Channel 0: the first buffer of a deinterleaved format, or every
        // `channelCount`-th sample of an interleaved one.
        let stride = format.isInterleaved ? Int(format.channelCount) : 1
        let relay = MicrophoneHopRelay(sampleRate: sampleRate) { hop, count, captureStart, arrival, buffer in
            // Relay thread: extract features, publish, fan out.
            sink.deliver(hop: hop, frameCount: count, sampleRate: Float(sampleRate),
                         captureStart: captureStart, arrival: arrival, buffer: buffer)
        }
        // Real-time I/O thread: copy channel 0 and return. No analysis, no
        // lock beyond the relay's copy, no allocation, no Tasks.
        let receiver = AVAudioSinkNode { timestamp, frameCount, inputData in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            guard let first = buffers.first, let data = first.mData, frameCount > 0 else { return noErr }
            let stamp = timestamp.pointee
            let captured = stamp.mFlags.contains(.hostTimeValid)
                ? AVAudioTime.seconds(forHostTime: stamp.mHostTime)
                : CACurrentMediaTime() - Double(frameCount) / sampleRate
            relay.write(data.assumingMemoryBound(to: Float.self), count: Int(frameCount),
                        stride: stride, hostTime: captured)
            return noErr
        }
        engine.attach(receiver)
        // A sink node does no format conversion: it takes the input's own.
        engine.connect(engine.inputNode, to: receiver, format: format)
        relay.start()
        do {
            try engine.start()
        } catch {
            relay.stop()
            throw error
        }
        return relay
    }

    /// The pre-chunk-2 capture: a 1024-frame tap request that iOS serves in
    /// ~100 ms buffers, delivered through `deliver(buffer:sampleRate:when:)`.
    private func startTapCapture(engine: AVAudioEngine, sink: AudioPCMSink) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard Self.isUsable(format) else { throw MicrophoneCaptureError.inputFormatNotReady }
        let sampleRate = Float(format.sampleRate)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, when in
            // Audio thread: extract features, publish, fan out. No Tasks,
            // no actor hops, no allocations beyond the extractor's warm-up.
            sink.deliver(buffer: buffer, sampleRate: sampleRate, when: when)
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    func stop(deactivatingSession: Bool) {
        if let configurationChangeObserver {
            NotificationCenter.default.removeObserver(configurationChangeObserver)
            self.configurationChangeObserver = nil
        }
        audioEngine?.inputNode.removeTap(onBus: 0)   // the tap path's, if any
        audioEngine?.stop()
        audioEngine = nil
        // After the engine: no more writes can arrive once it has stopped.
        relay?.stop()
        relay = nil
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

private enum MicrophoneCaptureError: Error {
    case inputFormatNotReady
}
