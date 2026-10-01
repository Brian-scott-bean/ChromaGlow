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
// (the shipped capture, moved verbatim) or, in local experimental builds
// only, the Spotify Connect PCM source. Everything below the source (feature
// extraction, tempo, publishing, every render loop) is shared.
//
// Responsibilities:
//  • Demand refcounting: consumers declare interest (.composerReaction,
//    .syncMode, .performance); the engine runs while any demand is active.
//  • Source lifecycle: prepare (mic permission) → start → stop, plus
//    interruption + background recovery.
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
    }

    private let log = Logger(subsystem: "com.lightshade.app", category: "AudioEngine")

    private var demands: Set<AudioDemand> = []
    private var engineRunning = false
    private var tempoTask: Task<Void, Never>?

    /// Which source feeds analysis. Microphone unless an experimental build
    /// selects otherwise; not persisted — every launch starts on the mic.
    private(set) var sourceKind: AudioAnalysisSourceKind = .microphone
    private var activeSource: (any AudioAnalysisSource)?
    private let makeSource: @MainActor (AudioAnalysisSourceKind) -> any AudioAnalysisSource
    // nonisolated(unsafe): written only in init (before the singleton is
    // published), read only in deinit — same pattern as SyncModeEngine's
    // lifecycleObservers. The nonisolated deinit may not touch main-actor state.
    nonisolated(unsafe) private var ncObservers: [NSObjectProtocol] = []
    /// The center the lifecycle observers live on (.default in the app;
    /// tests pass a private one so they never fire the host app's observers).
    nonisolated private let notificationCenter: NotificationCenter

    /// Estimator + the current activation's extractor are touched per the
    /// single-writer contracts documented on each type (source thread / tempo
    /// task). A fresh extractor per activation replaces reset(): an outgoing
    /// source's in-flight callback can never share state with its successor.
    private var activeExtractor: AudioFeatureExtractor?
    /// Generation of the activation this instance started (0 = none).
    private var activeGeneration: UInt64 = 0
    private let tempoEstimator = TempoEstimator()

    // ── Published features (audio thread writes, anyone reads) ──
    nonisolated private static let featuresLock = NSLock()
    nonisolated(unsafe) private static var _latest = AudioFeatures.silent
    nonisolated(unsafe) private static var _tempoBPM: Double = 0
    nonisolated(unsafe) private static var _tempoConfidence: Double = 0
    /// The live activation (0 = none). Process-wide so every engine instance
    /// (the shared one, test instances) gates on one truth.
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
    /// invalidated — checked under the same lock stopEngine() takes, so a
    /// late hop can never overwrite the .silent a stop published. A hop
    /// stamped in the future waits in the delay line until it is heard.
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

    /// Open a new activation; returns its generation.
    nonisolated private static func beginActivation() -> UInt64 {
        featuresLock.lock()
        defer { featuresLock.unlock() }
        _nextActivation += 1
        _activation = _nextActivation
        _delayed.removeAll()
        return _activation
    }

    /// Invalidate `generation` (if still live) and publish silence.
    nonisolated private static func endActivation(_ generation: UInt64) {
        featuresLock.lock()
        defer { featuresLock.unlock() }
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

    /// Designated init — internal so tests can inject fake sources and a
    /// private notification center. Only `shared` should drive real audio.
    init(
        makeSource: @escaping @MainActor (AudioAnalysisSourceKind) -> any AudioAnalysisSource,
        notificationCenter: NotificationCenter = .default
    ) {
        self.makeSource = makeSource
        self.notificationCenter = notificationCenter
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
        // format. Acts only while a demand is held and the engine isn't running
        // — a route change on a healthy engine is left alone.
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
                    guard let self, self.hasActiveDemand, !self.engineRunning else { return }
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
                if self.hasActiveDemand { await self.startEngineIfNeeded() }
            }
        })
    }

    deinit {
        for o in ncObservers { notificationCenter.removeObserver(o) }
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

    /// True while the selected source is delivering into analysis.
    var isRunning: Bool { engineRunning }

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
        guard source.start(sink: sink) else {
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

    private func stopEngine() {
        tempoTask?.cancel()
        tempoTask = nil
        engineRunning = false
        // Invalidate first: from here on, a late callback from the outgoing
        // source is dropped at the sink and can't overwrite the silence.
        Self.endActivation(activeGeneration)
        activeGeneration = 0
        if let source = activeSource {
            source.stop()
        } else if sourceKind == .microphone {
            MicrophoneAudioSource.deactivateSession()
        }
        activeSource = nil
        activeExtractor = nil
        Self.publishTempo(bpm: 0, confidence: 0)
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
