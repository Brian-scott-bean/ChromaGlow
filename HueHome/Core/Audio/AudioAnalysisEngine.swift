// AudioAnalysisEngine.swift
// ChromaGlow — Core/Audio (DJ upgrade Phase 2)
//
// The ONE owner of audio analysis. Replaced CompositionMicCapture and
// SyncModeEngine's private engine — the two used different session
// categories and coordinated through a timed notification handshake;
// unifying capture removed that race entirely.
//
// Audio-source boundary (2026-10): the engine no longer assumes the mic. It
// pulls PCM from the selected AudioAnalysisSource — MicrophoneAudioSource
// (the shipped capture, moved out of this file) or, in local experimental
// builds only, the Spotify Connect PCM source. Everything below the source
// (feature extraction, tempo, publishing, every render loop) is shared.
//
// Responsibilities:
//  • Demand refcounting: consumers declare interest (.composerReaction,
//    .syncMode, .performance); the engine runs while any demand is active.
//  • Source lifecycle: prepare (mic permission) → start → stop, plus
//    interruption, background, route-change and hardware-reconfiguration
//    recovery.
//  • Per-buffer feature extraction (AudioFeatureExtractor) published to a
//    lock-guarded static store — render loops call latestFeatures() from
//    any thread. Each activation gets a generation; a stop or source switch
//    invalidates it under the same lock, so stale callbacks are dropped.
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

    /// Capture is actually flowing: we started a source AND it is still
    /// delivering. A hardware configuration change (AirPods connecting, a
    /// sample-rate change) stops and uninitializes the mic's AVAudioEngine
    /// behind our back, so `engineRunning` alone can claim a capture that is
    /// dead.
    private var isCaptureLive: Bool {
        engineRunning && activeSource?.isLive == true
    }
    private var tempoTask: Task<Void, Never>?

    /// Which source feeds analysis. Microphone unless an experimental build
    /// selects otherwise; not persisted — every launch starts on the mic.
    private(set) var sourceKind: AudioAnalysisSourceKind = .microphone
    private var activeSource: (any AudioAnalysisSource)?
    private let makeSource: @MainActor (AudioAnalysisSourceKind) -> any AudioAnalysisSource
    /// Whether the app is in the background (injectable for tests).
    private let isInBackground: @MainActor () -> Bool
    // nonisolated(unsafe): written only in init (before the singleton is
    // published), read only in deinit — same pattern as SyncModeEngine's
    // lifecycleObservers. The nonisolated deinit may not touch main-actor state.
    nonisolated(unsafe) private var ncObservers: [NSObjectProtocol] = []
    /// The center the lifecycle observers live on (.default in the app;
    /// tests pass a private one so they never fire the host app's observers).
    nonisolated private let notificationCenter: NotificationCenter

    /// Estimator + the current activation's extractor are touched per the
    /// single-writer contracts documented on each type (source thread / tempo
    /// task respectively).
    ///
    /// The extractor is REPLACED on every activation rather than reset.
    /// Neither `removeTap` nor `stop()` promises that a callback already in
    /// flight has returned, so a reset could run on the main actor while that
    /// callback was inside `process()` — and a fast stop → start put the old
    /// source's last buffer and the new source's first on one extractor from
    /// two threads, against its one-writer contract. A fresh instance per
    /// activation gives each source its own extractor: a straggler finishes on
    /// the one it started with, which nothing reads.
    private var activeExtractor: AudioFeatureExtractor?
    /// Generation of the activation this instance started (0 = none).
    private var activeGeneration: UInt64 = 0
    private let tempoEstimator = TempoEstimator()

    // ── Published features (audio thread writes, anyone reads) ──
    nonisolated private static let featuresLock = NSLock()
    nonisolated(unsafe) private static var _latest = AudioFeatures.silent
    nonisolated(unsafe) private static var _tempoBPM: Double = 0
    nonisolated(unsafe) private static var _tempoConfidence: Double = 0
    /// The live activation (0 = none) — the capture session allowed to
    /// publish. Process-wide so every engine instance (the shared one, test
    /// instances) gates on one truth: a straggling callback of a STOPPED
    /// source could otherwise publish after the stop went silent, and its
    /// stale levels would haunt `latestFeatures()` for the whole off period.
    nonisolated(unsafe) private static var _activation: UInt64 = 0
    nonisolated(unsafe) private static var _nextActivation: UInt64 = 0
    /// Hops whose presentation time is still in the future (sources whose
    /// audio plays out later). Always empty for the microphone.
    nonisolated(unsafe) private static var _delayed = AnalysisFeatureDelayLine()

    /// Current audio features merged with the latest tempo estimate.
    /// Safe from any thread; returns .silent when capture is off.
    nonisolated static func latestFeatures() -> AudioFeatures {
        featuresLock.lock()
        defer { featuresLock.unlock() }
        if !_delayed.isEmpty, let due = _delayed.popDue(now: CACurrentMediaTime()) {
            _latest = due
        }
        var f = _latest
        f.bpm = _tempoBPM
        f.bpmConfidence = _tempoConfidence
        return f
    }

    nonisolated static func isCurrentActivation(_ generation: UInt64) -> Bool {
        featuresLock.lock()
        defer { featuresLock.unlock() }
        return generation != 0 && generation == _activation
    }

    /// Publish one hop for `generation`. Dropped if that activation has been
    /// invalidated — checked under the same lock the stop takes, so a late
    /// hop can never overwrite the .silent a stop published. A hop stamped in
    /// the future waits in the delay line until it is heard.
    nonisolated static func publish(_ features: AudioFeatures, generation: UInt64) {
        featuresLock.lock()
        defer { featuresLock.unlock() }
        guard generation != 0, generation == _activation else { return }
        if features.timestamp > CACurrentMediaTime() + 0.001 {
            _delayed.append(features)
        } else {
            _latest = features
        }
    }

    /// Drop anything pending for `generation` and publish silence, keeping
    /// the activation live (the source paused rather than stopped).
    nonisolated static func publishSilence(generation: UInt64) {
        featuresLock.lock()
        defer { featuresLock.unlock() }
        guard generation != 0, generation == _activation else { return }
        _delayed.removeAll()
        _latest = .silent
    }

    /// Open a new activation for a source about to start; returns its generation.
    nonisolated private static func beginActivation() -> UInt64 {
        featuresLock.lock()
        defer { featuresLock.unlock() }
        _nextActivation &+= 1
        _activation = _nextActivation
        _delayed.removeAll()
        return _activation
    }

    /// Close `generation` (if still live) and go silent in ONE critical
    /// section, so no callback of the stopped source can land after the
    /// silence. The tempo is zeroed either way.
    nonisolated private static func endActivation(_ generation: UInt64) {
        featuresLock.lock()
        defer { featuresLock.unlock() }
        _tempoBPM = 0
        _tempoConfidence = 0
        guard generation != 0, generation == _activation else { return }
        _activation = 0
        _delayed.removeAll()
        _latest = .silent
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

    nonisolated static func fanOut(_ buffer: AVAudioPCMBuffer, sampleRate: Float) {
        tapsLock.lock()
        let taps = bufferTaps
        tapsLock.unlock()
        for handler in taps.values { handler(buffer, sampleRate) }
    }

    // MARK: - Init / lifecycle observers

    private convenience init() {
        self.init(makeSource: AudioAnalysisEngine.defaultSource)
    }

    /// The production source factory. The experimental case exists only in
    /// CHROMAGLOW_EXPERIMENTAL_SPOTIFY builds.
    static func defaultSource(_ kind: AudioAnalysisSourceKind) -> any AudioAnalysisSource {
        switch kind {
        case .microphone:
            return MicrophoneAudioSource()
        #if CHROMAGLOW_EXPERIMENTAL_SPOTIFY
        case .spotifyConnect:
            return SpotifyPCMSource()
        #endif
        }
    }

    /// Designated init — internal so tests can inject fake sources, a
    /// private notification center and the app state. Only `shared` should
    /// drive real audio.
    init(
        makeSource: @escaping @MainActor (AudioAnalysisSourceKind) -> any AudioAnalysisSource,
        notificationCenter: NotificationCenter = .default,
        isInBackground: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .background }
    ) {
        self.makeSource = makeSource
        self.notificationCenter = notificationCenter
        self.isInBackground = isInBackground
        ncObservers.append(notificationCenter.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stopEngine() }
        })
        ncObservers.append(notificationCenter.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.startEngineIfNeeded() }
        })
        ncObservers.append(notificationCenter.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let info = note.userInfo,
                  let typeVal = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeVal) else { return }
            Task { @MainActor in
                guard let self else { return }
                switch type {
                case .began: self.stopEngine()
                case .ended:
                    if self.mayRecoverCaptureAutomatically { await self.startEngineIfNeeded() }
                @unknown default: break
                }
            }
        })

        // A route change (Bluetooth/headphone hand-off, or the input route
        // coming back after a foreground restart) is the natural "input is
        // ready now" signal: recover capture that deferred on a 0 Hz / 0 ch
        // format. Acts only while a demand is held and capture isn't live — a
        // route change on a healthy source is left alone, but one the system
        // stopped (see `isCaptureLive`) is rebuilt.
        ncObservers.append(notificationCenter.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let reasonVal = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonVal) else { return }
            switch reason {
            case .newDeviceAvailable, .oldDeviceUnavailable, .categoryChange,
                 .routeConfigurationChange, .override:
                Task { @MainActor in
                    guard let self, self.hasActiveDemand, !self.isCaptureLive,
                          self.mayRecoverCaptureAutomatically else { return }
                    await self.startEngineIfNeeded()
                }
            default:
                break
            }
        })

        // Media services reset: the engine + session are torn down by the
        // system, so rebuild from scratch if anything still needs audio.
        ncObservers.append(notificationCenter.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.stopEngine()
                if self.hasActiveDemand, self.mayRecoverCaptureAutomatically {
                    await self.startEngineIfNeeded()
                }
            }
        })
    }

    deinit {
        for o in ncObservers { notificationCenter.removeObserver(o) }
    }

    // MARK: - Demand

    /// Declare or withdraw a consumer's interest. Returns true when capture
    /// is running (or came up) — false means permission was denied or the
    /// source failed to start, so callers can surface their own UI.
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

    /// True while the selected source is delivering into analysis.
    var isRunning: Bool { engineRunning }

    /// May an AUTOMATIC recovery (interruption ended, route change, media
    /// services reset, engine reconfiguration) start capture now?
    /// Not while the app is in the background: `didEnterBackground` stopped
    /// capture on purpose, a background start either records with the app
    /// out of sight or fails to activate the session (and the failure used
    /// to surface as "enable access in Settings" on return). The foreground
    /// transition restarts capture itself, so nothing is lost by waiting.
    private var mayRecoverCaptureAutomatically: Bool {
        !isInBackground()
    }

    // MARK: - Source selection

    /// Switch where analyzed audio comes from. The current source is stopped
    /// first (its activation invalidated before its stop() runs), then the new
    /// source starts if anything still holds a demand. Returns whether the
    /// new source is running.
    @discardableResult
    func selectSource(_ kind: AudioAnalysisSourceKind) async -> Bool {
        guard kind != sourceKind else { return engineRunning }
        stopEngine()
        sourceKind = kind
        guard hasActiveDemand else { return false }
        return await startEngineIfNeeded()
    }

    // MARK: - Engine

    @discardableResult
    private func startEngineIfNeeded() async -> Bool {
        guard !demands.isEmpty else { return false }
        // A source the system stopped under us (configuration change) is not
        // capture: tear it down and rebuild rather than report `true` for a
        // tap that will never fire again.
        if engineRunning, !isCaptureLive {
            log.info("Audio source found stopped — rebuilding capture")
            stopEngine(deactivatingSession: false)
        }
        guard !engineRunning else { return true }

        let kind = sourceKind
        let source = makeSource(kind)
        // Permission / preflight. Demand may have been withdrawn (L-19) or the
        // source switched while a prompt was up — re-check after it.
        guard await source.prepare(stillWanted: { [unowned self] in
            !self.demands.isEmpty && kind == self.sourceKind
        }) else { return false }
        guard !demands.isEmpty, kind == sourceKind else { return false }
        guard !engineRunning else { return true }

        let extractor = AudioFeatureExtractor()
        let generation = Self.beginActivation()
        let sink = AudioPCMSink(generation: generation, extractor: extractor)
        // Hardware reconfiguration: the source reports it stopped on its own.
        // Identity-checked, so a report that lands after a rebuild cannot
        // tear down its successor.
        source.onSystemStop = { [weak self, weak source] in
            guard let self, let source, self.activeSource === source else { return }
            await self.rebuildAfterConfigurationChange()
        }
        guard source.start(sink: sink) else {
            source.onSystemStop = nil
            Self.endActivation(generation)
            return false
        }
        activeSource = source
        activeExtractor = extractor
        activeGeneration = generation
        engineRunning = true
        startTempoTask()
        log.info("Audio analysis engine started (source: \(kind.rawValue), demands: \(self.demands.count))")
        return true
    }

    /// `deactivatingSession: false` is for a REBUILD only: the session is
    /// about to be re-activated, and bouncing it would tell other audio to
    /// resume and re-trigger the very route churn that caused the rebuild.
    private func stopEngine(deactivatingSession: Bool = true) {
        // Cancel, but KEEP the handle: the next `startTempoTask` must await
        // this task before it resets the estimator (see there). Clearing it
        // here meant `previous` was always nil after a stop, so the drain
        // never ran on exactly the stop → start path it exists for.
        tempoTask?.cancel()
        engineRunning = false
        // Invalidate first: from here on, a late callback from the outgoing
        // source is dropped at the sink and can't overwrite the silence.
        Self.endActivation(activeGeneration)
        activeGeneration = 0
        if let source = activeSource {
            source.onSystemStop = nil
            source.stop(deactivatingSession: deactivatingSession)
        } else if sourceKind == .microphone, deactivatingSession {
            // The mic's stop path always released the session, even when
            // nothing was running (backgrounding, interruption) — kept so.
            MicrophoneAudioSource.deactivateSession()
        }
        activeSource = nil
        // No `extractor.reset()`: the next activation builds a fresh
        // extractor, so nothing here touches one a callback may be using.
        activeExtractor = nil
    }

    // MARK: - Hardware reconfiguration

    /// Tear the stopped source down (which publishes `.silent`, so render
    /// loops stop reacting to a frozen last hop) and, if anyone still needs
    /// audio, bring capture back up on the new hardware format.
    private func rebuildAfterConfigurationChange() async {
        log.info("Audio engine configuration changed — rebuilding capture")
        let rebuild = hasActiveDemand && mayRecoverCaptureAutomatically
        stopEngine(deactivatingSession: !rebuild)
        guard rebuild else { return }
        await startEngineIfNeeded()
    }

    // MARK: - Tempo pass (~2 Hz)

    private func startTempoTask() {
        tempoTask?.cancel()
        let previous = tempoTask
        guard let extractor = activeExtractor else { return }
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

extension Notification.Name {
    /// Microphone capture could not START although permission is granted —
    /// the session, the input route or the engine failed. Distinct from
    /// `.compositionMicPermissionDenied`, which is posted ONLY for a real
    /// permission denial and whose observers send the user to Settings.
    static let compositionMicCaptureFailed = Notification.Name("compositionMicCaptureFailed")
}
