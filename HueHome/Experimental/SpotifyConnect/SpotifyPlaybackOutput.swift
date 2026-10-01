// SpotifyPlaybackOutput.swift
// ChromaGlow — Experimental/SpotifyConnect (LOCAL-ONLY experiment, Phase 2)
//
// Plays the music the receiver decodes, so "ChromaGlow Sync" is a real
// speaker: AVAudioEngine + one AVAudioSourceNode whose render block pulls
// interleaved stereo from the Rust receiver's bounded ring
// (cg_spotify_read_playback) and deinterleaves it into the engine's buffers.
// Where it is heard is ordinary iOS routing — the phone speaker, Bluetooth,
// or an AirPlay speaker picked with the system route picker. Public API only.
//
// Lighting stays in step with what is HEARD: the router delays every analysis
// hop by the ring depth at push time plus this route's output latency
// (outputLatency + ioBufferDuration, re-read on every route change — AirPlay
// is seconds, Bluetooth ~150-250 ms), and the user's light offset on top.
//
// Real-time rules in the render block: no locks, no allocation, no Swift
// runtime calls, no main-actor hop — one C call into a lock-free ring, a
// copy out of a scratch buffer allocated once per engine.
//
// Nothing is written anywhere: the ring and the scratch buffer are the only
// places decoded audio exists.
//
// Compiles only under CHROMAGLOW_EXPERIMENTAL_SPOTIFY (never in Release).

#if CHROMAGLOW_EXPERIMENTAL_SPOTIFY

import AVFoundation
import ChromaGlowSpotifyFFI
import Foundation
import Observation

@MainActor
@Observable
final class SpotifyPlaybackOutput {
    enum State: Equatable {
        case off
        case playing
        /// A call, Siri or another app's audio took the session.
        case interrupted
        case failed(String)
    }

    /// The receiver's fixed output format (librespot decodes 44.1 kHz stereo).
    nonisolated static let sampleRate: Double = 44_100
    /// Ring depth the receiver keeps ahead of the render thread — headroom
    /// for player-thread scheduling, paid for by delaying the lights as much.
    nonisolated static let targetQueueSeconds: Double = 0.3

    private(set) var state: State = .off
    /// Where the music is heard ("iPhone Speaker", an AirPlay speaker…).
    private(set) var routeName = ""
    private(set) var routeIsAirPlay = false
    /// outputLatency + ioBufferDuration of the current route (seconds).
    private(set) var routeLatency: Double = 0

    /// Called after every state / route change (the receiver refreshes the
    /// router's latency and its status from here).
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var configurationObserver: NSObjectProtocol?
    @ObservationIgnored private var wanted = false

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let info = note.userInfo
            let type = (info?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let options = (info?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            Task { @MainActor in self?.interruption(type, shouldResume: options.contains(.shouldResume)) }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshRoute() }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuild(reason: "media services reset") }
        })
    }

    // MARK: - Control

    /// Start playing whatever the receiver decodes. Idempotent.
    func start() {
        wanted = true
        guard engine == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            // .playback: music that keeps playing with the screen locked or
            // the silent switch on, routable to AirPlay and Bluetooth. Not
            // mixable — this IS the music player while the receiver is on.
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true, options: [])
            let engine = try Self.makeEngine()
            try engine.start()
            self.engine = engine
            observeConfigurationChange(of: engine)
            cg_spotify_set_playback(true, UInt32(Self.targetQueueSeconds * Self.sampleRate))
            state = .playing
            print("[SpotifyPCM] playback output started")
        } catch {
            teardownEngine()
            state = .failed(error.localizedDescription)
            print("[SpotifyPCM] playback output failed: \(error.localizedDescription)")
        }
        refreshRoute()
    }

    /// Stop playing; the receiver falls back to analysis-only pacing.
    func stop() {
        wanted = false
        guard engine != nil || state != .off else { return }
        teardownEngine()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        state = .off
        refreshRoute()
        print("[SpotifyPCM] playback output stopped")
    }

    /// Re-read the route's latency (cheap; the receiver calls it once a second
    /// because AirPlay reports its real latency only after it settles).
    func refreshRoute() {
        let session = AVAudioSession.sharedInstance()
        let output = session.currentRoute.outputs.first
        let name = output?.portName ?? ""
        let airPlay = output?.portType == .airPlay
        let latency = state == .playing ? max(0, session.outputLatency + session.ioBufferDuration) : 0
        if name != routeName { routeName = name }
        if airPlay != routeIsAirPlay { routeIsAirPlay = airPlay }
        if abs(latency - routeLatency) > 0.0005 { routeLatency = latency }
        onChange?()
    }

    // MARK: - System events

    private func interruption(_ type: AVAudioSession.InterruptionType?, shouldResume: Bool) {
        guard wanted, let type else { return }
        switch type {
        case .began:
            // The system has already stopped the engine.
            teardownEngine()
            state = .interrupted
            refreshRoute()
        case .ended:
            // Resume only when iOS says so (a call ended); otherwise the user
            // resumes from the panel — never take the session back unasked.
            if shouldResume { rebuild(reason: "interruption ended") }
        @unknown default:
            break
        }
    }

    /// Resume after an interruption that didn't ask to resume (panel button).
    func resume() {
        guard wanted else { return }
        rebuild(reason: "resume")
    }

    /// The engine stopped itself (new route hardware: AirPlay, Bluetooth,
    /// headphones change the sample rate / channel count) or media services
    /// reset: build a fresh engine on the new hardware format.
    private func rebuild(reason: String) {
        guard wanted else { return }
        print("[SpotifyPCM] playback output rebuilding (\(reason))")
        teardownEngine()
        start()
    }

    /// iOS posts this when the output hardware's format changes — after it has
    /// STOPPED the engine. Scoped to this engine and identity-checked so a
    /// late notification can't tear down its successor.
    private func observeConfigurationChange(of engine: AVAudioEngine) {
        let engineID = ObjectIdentifier(engine)
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let current = self.engine, ObjectIdentifier(current) == engineID else { return }
                self.rebuild(reason: "output configuration changed")
            }
        }
    }

    private func teardownEngine() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        // Disabling playback clears the ring: stale audio never plays later.
        cg_spotify_set_playback(false, 0)
        engine?.stop()
        engine = nil
    }

    // MARK: - Engine (nonisolated: the render block must not inherit the main actor)

    nonisolated private static func makeEngine() throws -> AVAudioEngine {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw NSError(domain: "SpotifyPlaybackOutput", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No 44.1 kHz stereo format"])
        }
        let scratch = PlaybackScratch()
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList -> OSStatus in
            scratch.render(frameCount: Int(frameCount), into: bufferList)
            return noErr
        }
        let engine = AVAudioEngine()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        return engine
    }
}

/// Interleaved scratch the render block pulls into, allocated once per engine
/// and freed only when the engine (which owns the render block) is gone.
final class PlaybackScratch: @unchecked Sendable {
    /// Largest pull handled in one C call; bigger render requests loop.
    static let capacityFrames = 4096

    private let interleaved: UnsafeMutablePointer<Float>

    init() {
        interleaved = .allocate(capacity: Self.capacityFrames * 2)
        interleaved.initialize(repeating: 0, count: Self.capacityFrames * 2)
    }

    deinit {
        interleaved.deallocate()
    }

    /// Render thread. Pull from the receiver's ring (which zero-fills what it
    /// doesn't have) and deinterleave into the engine's L/R buffers.
    func render(frameCount: Int, into bufferList: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        guard buffers.count >= 2,
              let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
              let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return }
        var done = 0
        while done < frameCount {
            let n = min(frameCount - done, Self.capacityFrames)
            _ = cg_spotify_read_playback(interleaved, UInt32(n))
            for i in 0..<n {
                left[done + i] = interleaved[2 * i]
                right[done + i] = interleaved[2 * i + 1]
            }
            done += n
        }
    }
}

#endif
