// AudioAnalysisEngine.swift
// ChromaGlow — Core/Audio (DJ upgrade Phase 2)
//
// The ONE owner of the app's AVAudioSession + AVAudioEngine + input tap.
// Replaces CompositionMicCapture and SyncModeEngine's private engine — the
// two used different session categories and coordinated through a timed
// notification handshake; unifying capture removes that race entirely.
//
// Responsibilities:
//  • Demand refcounting: consumers declare interest (.composerReaction,
//    .syncMode, .performance); the engine runs while any demand is active.
//  • Permission (AVAudioApplication), interruption + background recovery.
//  • Per-buffer feature extraction (AudioFeatureExtractor) published to a
//    lock-guarded static store — render loops call latestFeatures() from
//    any thread.
//  • Raw-buffer fan-out taps so the Sync tab's Visualizer/Gaming/Ambient
//    engines keep their own processing unchanged.
//  • A ~2 Hz tempo pass (TempoEstimator on a utility task) that feeds
//    BeatClock.shared and stamps bpm into the published features.
//
// Privacy: raw audio never leaves the process and is never persisted —
// only derived scalars (levels, onset times, BPM) exist beyond the tap.

import AVFoundation
import Foundation
import QuartzCore
import UIKit
import os

@MainActor
final class AudioAnalysisEngine {
    static let shared = AudioAnalysisEngine()

    /// Who currently needs audio. The engine runs while this set is non-empty.
    enum AudioDemand: Hashable {
        case composerReaction
        case syncMode
        case performance
        case shazamID   // ShazamSource's continuous song identification
        case composer2Preview   // Composer 2 lab: on-screen preview of an audio-reactive layer
    }

    private let log = Logger(subsystem: "com.lightshade.app", category: "AudioEngine")

    private var demands: Set<AudioDemand> = []
    private var engineRunning = false
    private var audioEngine: AVAudioEngine?
    /// The `.AVAudioEngineConfigurationChange` observer for the CURRENT
    /// engine only — registered after its `start()`, removed by `stopEngine`.
    private var configurationChangeObserver: NSObjectProtocol?

    /// Capture is actually flowing: we started an engine AND it is still
    /// running. A hardware configuration change (AirPods connecting, a
    /// sample-rate change) stops and uninitializes the engine behind our
    /// back, so `engineRunning` alone can claim a capture that is dead.
    private var isCaptureLive: Bool {
        engineRunning && audioEngine?.isRunning == true
    }
    private var tempoTask: Task<Void, Never>?
    // nonisolated(unsafe): written only in init (before the singleton is
    // published), read only in deinit — same pattern as SyncModeEngine's
    // lifecycleObservers. The nonisolated deinit may not touch main-actor state.
    nonisolated(unsafe) private var ncObservers: [NSObjectProtocol] = []

    /// Extractor + estimator are touched per the single-writer contracts
    /// documented on each type (tap thread / tempo task respectively).
    private let extractor = AudioFeatureExtractor()
    private let tempoEstimator = TempoEstimator()

    // ── Published features (audio thread writes, anyone reads) ──
    nonisolated private static let featuresLock = NSLock()
    nonisolated(unsafe) private static var _latest = AudioFeatures.silent
    nonisolated(unsafe) private static var _tempoBPM: Double = 0
    nonisolated(unsafe) private static var _tempoConfidence: Double = 0

    /// Current audio features merged with the latest tempo estimate.
    /// Safe from any thread; returns .silent when capture is off.
    nonisolated static func latestFeatures() -> AudioFeatures {
        featuresLock.lock()
        defer { featuresLock.unlock() }
        var f = _latest
        f.bpm = _tempoBPM
        f.bpmConfidence = _tempoConfidence
        return f
    }

    nonisolated private static func publish(_ features: AudioFeatures) {
        featuresLock.lock()
        _latest = features
        featuresLock.unlock()
    }

    nonisolated private static func publishTempo(bpm: Double, confidence: Double) {
        featuresLock.lock()
        _tempoBPM = bpm
        _tempoConfidence = confidence
        featuresLock.unlock()
    }

    // ── Raw-buffer fan-out (Sync engines) ──
    nonisolated private static let tapsLock = NSLock()
    nonisolated(unsafe) private static var bufferTaps: [String: @Sendable (AVAudioPCMBuffer, Float) -> Void] = [:]

    /// Register a raw-buffer consumer (runs on the audio thread — the
    /// handler must be as cheap as an engine `process()` call).
    nonisolated static func addBufferTap(id: String, _ handler: @escaping @Sendable (AVAudioPCMBuffer, Float) -> Void) {
        tapsLock.lock()
        bufferTaps[id] = handler
        tapsLock.unlock()
    }

    nonisolated static func removeBufferTap(id: String) {
        tapsLock.lock()
        bufferTaps.removeValue(forKey: id)
        tapsLock.unlock()
    }

    // MARK: - Init / lifecycle observers

    private init() {
        ncObservers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stopEngine() }
        })
        ncObservers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.startEngineIfNeeded() }
        })
        ncObservers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let info = note.userInfo,
                  let typeVal = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeVal) else { return }
            Task { @MainActor in
                switch type {
                case .began: self?.stopEngine()
                case .ended: await self?.startEngineIfNeeded()
                @unknown default: break
                }
            }
        })

        // A route change (Bluetooth/headphone hand-off, or the input route
        // coming back after a foreground restart) is the natural "input is
        // ready now" signal: recover capture that deferred on a 0 Hz / 0 ch
        // format. Acts only while a demand is held and capture isn't live — a
        // route change on a healthy engine is left alone, but one whose engine
        // the system stopped (see `isCaptureLive`) is rebuilt.
        ncObservers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let reasonVal = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonVal) else { return }
            switch reason {
            case .newDeviceAvailable, .oldDeviceUnavailable, .categoryChange,
                 .routeConfigurationChange, .override:
                Task { @MainActor in
                    guard let self, self.hasActiveDemand, !self.isCaptureLive else { return }
                    await self.startEngineIfNeeded()
                }
            default:
                break
            }
        })

        // Media services reset: the engine + session are torn down by the
        // system, so rebuild from scratch if anything still needs audio.
        ncObservers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.stopEngine()
                if self.hasActiveDemand { await self.startEngineIfNeeded() }
            }
        })
    }

    deinit {
        for o in ncObservers { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: - Demand

    /// Declare or withdraw a consumer's interest. Returns true when capture
    /// is running (or came up) — false means permission was denied or the
    /// engine failed to start, so callers can surface their own UI.
    @discardableResult
    func setDemand(_ demand: AudioDemand, active: Bool) async -> Bool {
        if active { demands.insert(demand) } else { demands.remove(demand) }
        if demands.isEmpty {
            stopEngine()
            return false
        }
        return await startEngineIfNeeded()
    }

    /// True while any consumer holds a demand (engine may still be paused
    /// by an interruption/backgrounding — it restarts automatically).
    var hasActiveDemand: Bool { !demands.isEmpty }

    // MARK: - Engine

    @discardableResult
    private func startEngineIfNeeded() async -> Bool {
        guard !demands.isEmpty else { return false }
        // An engine the system stopped under us (configuration change) is
        // not capture: tear it down and rebuild rather than report `true`
        // for a tap that will never fire again.
        if engineRunning, !isCaptureLive {
            log.info("Audio engine found stopped — rebuilding capture")
            stopEngine(deactivatingSession: false)
        }
        guard !engineRunning else { return true }

        // Permission (modern API; L-22 pattern).
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined:
            let granted = await AVAudioApplication.requestRecordPermission()
            // Demand may have been withdrawn while the prompt was up (L-19).
            guard !demands.isEmpty else { return false }
            if !granted {
                log.warning("Mic permission denied (prompt)")
                NotificationCenter.default.post(name: .compositionMicPermissionDenied, object: nil)
                return false
            }
        case .denied:
            log.warning("Mic permission denied (settings)")
            NotificationCenter.default.post(name: .compositionMicPermissionDenied, object: nil)
            return false
        case .granted:
            break
        @unknown default:
            break
        }
        guard !engineRunning else { return true }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let extractor = self.extractor

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
                if let data = buffer.floatChannelData?[0] {
                    let hostTime = CACurrentMediaTime()
                    if let features = extractor.process(
                        data: data,
                        frameCount: Int(buffer.frameLength),
                        sampleRate: sampleRate,
                        hostTime: hostTime
                    ) {
                        AudioAnalysisEngine.publish(features)
                    }
                }
                AudioAnalysisEngine.tapsLock.lock()
                let taps = AudioAnalysisEngine.bufferTaps
                AudioAnalysisEngine.tapsLock.unlock()
                for handler in taps.values { handler(buffer, sampleRate) }
            }

            try engine.start()
            audioEngine = engine
            engineRunning = true
            observeConfigurationChange(of: engine)
            startTempoTask()
            log.info("Audio analysis engine started (demands: \(self.demands.count))")
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

    /// `deactivatingSession: false` is for a REBUILD only: the session is
    /// about to be re-activated, and bouncing it would tell other audio to
    /// resume and re-trigger the very route churn that caused the rebuild.
    private func stopEngine(deactivatingSession: Bool = true) {
        tempoTask?.cancel()
        tempoTask = nil
        if let configurationChangeObserver {
            NotificationCenter.default.removeObserver(configurationChangeObserver)
            self.configurationChangeObserver = nil
        }
        engineRunning = false
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        if deactivatingSession {
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                log.debug("Session deactivate: \(error.localizedDescription)")
            }
        }
        extractor.reset()
        Self.publish(.silent)
        Self.publishTempo(bpm: 0, confidence: 0)
    }

    // MARK: - Hardware reconfiguration

    /// iOS posts `.AVAudioEngineConfigurationChange` when the I/O hardware's
    /// channel count or sample rate changes (a Bluetooth route coming or
    /// going, a sample-rate switch) — and it has already STOPPED and
    /// uninitialized the engine by then. Nothing else says so: the route
    /// change handler saw `engineRunning == true` and left the dead engine
    /// alone, `latestFeatures()` kept serving the last hop's levels, and
    /// `setDemand(true)` reported capture that was not happening.
    ///
    /// Scoped to THIS engine (`object:`), and re-checked by identity on the
    /// main actor, so a notification that arrives after a rebuild cannot tear
    /// down its successor.
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
                await self.rebuildAfterConfigurationChange()
            }
        }
    }

    /// Tear the stopped engine down (which publishes `.silent`, so render
    /// loops stop reacting to a frozen last hop) and, if anyone still needs
    /// audio, bring capture back up on the new hardware format.
    private func rebuildAfterConfigurationChange() async {
        log.info("Audio engine configuration changed — rebuilding capture")
        let rebuild = hasActiveDemand
        stopEngine(deactivatingSession: !rebuild)
        guard rebuild else { return }
        await startEngineIfNeeded()
    }

    // MARK: - Tempo pass (~2 Hz)

    private func startTempoTask() {
        tempoTask?.cancel()
        let previous = tempoTask
        let extractor = self.extractor
        let estimator = self.tempoEstimator
        tempoTask = Task { @MainActor [weak self] in
            // Drain the predecessor before reset(): cancel can't reach its
            // in-flight detached update(), and TempoEstimator is single-
            // writer — resetting under a live update both loses the reset
            // and races the hysteresis state.
            await previous?.value
            estimator.reset()
            while !Task.isCancelled, self?.engineRunning == true {
                let snapshot = extractor.onsetEnvelopeSnapshot()
                if !snapshot.envelope.isEmpty {
                    let estimate = await Task.detached(priority: .utility) {
                        estimator.update(onsetEnvelope: snapshot.envelope, hopRate: snapshot.hopRate)
                    }.value
                    // stopEngine() may have landed while we were suspended on
                    // the detached estimate — publishing now would overwrite
                    // its zeroed tempo with a stale one that then haunts
                    // latestFeatures() through the whole off period.
                    guard !Task.isCancelled, self?.engineRunning == true else { break }
                    if let estimate {
                        Self.publishTempo(bpm: estimate.bpm, confidence: estimate.confidence)
                        BeatClock.shared.ingest(estimate: estimate, endTime: snapshot.endTime)
                    }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }
}
