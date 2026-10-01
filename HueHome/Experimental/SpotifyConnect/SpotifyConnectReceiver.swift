// SpotifyConnectReceiver.swift
// ChromaGlow — Experimental/SpotifyConnect (LOCAL-ONLY experiment)
//
// Owns the Rust receiver's lifecycle (Experimental/SpotifyReceiver, pinned
// librespot) and the status the experiment panel shows. Explicit Start/Stop:
// the receiver advertises "ChromaGlow Sync" over Bonjour and Spotify hands it
// credentials through Spotify Connect's zeroconf flow — no username, password
// or token is ever entered, stored or logged here.
//
// Status is POLLED (4 Hz, one long-lived task) — nothing crosses into the
// MainActor per audio buffer. Start/stop are serialized on one task chain;
// the blocking Rust stop runs off the main thread, but the Swift-side PCM gate
// closes synchronously first, so no stale frame reaches analysis after Stop.
//
// Phase 2: while the receiver runs and "Play on this iPhone" is on, the
// decoded music plays through SpotifyPlaybackOutput (speaker, Bluetooth or
// AirPlay), and the lights are delayed to match what is heard — ring depth +
// the route's output latency + the user's light offset.
//
// Storage: librespot streams the *encrypted* compressed file through an
// unlinked-on-drop temp file. That temp folder is purged on every start and
// stop; decoded PCM is never written anywhere.
//
// Compiles only under CHROMAGLOW_EXPERIMENTAL_SPOTIFY (never in Release).

#if CHROMAGLOW_EXPERIMENTAL_SPOTIFY

import ChromaGlowSpotifyFFI
import Foundation
import Network
import Observation
import QuartzCore
import UIKit

@MainActor
@Observable
final class SpotifyConnectReceiver {
    static let shared = SpotifyConnectReceiver()
    static let deviceName = "ChromaGlow Sync"

    enum Phase: Equatable {
        case stopped, starting, waiting, connecting, connected, failed
    }

    enum Playback: Equatable {
        case idle, loading, playing, paused
    }

    /// Whether Spotify is playing on this device right now.
    enum Handoff: Equatable {
        /// Not picked in this session yet.
        case none
        /// Spotify plays here.
        case active
        /// Was playing here, then Spotify moved the music to another device —
        /// typically the phone's own Spotify app reclaiming it after the
        /// iPhone's speaker was changed while Spotify was open.
        case movedAway
    }

    /// Transport commands sent to Spotify Connect (lock screen, Control
    /// Center, the panel).
    enum Command {
        case play, pause, togglePlayPause, next, previous
        /// Transfer playback back to this device after Spotify moved it away.
        case bringHere

        var code: UInt32 {
            switch self {
            case .play: UInt32(CGSpotifyCommandPlay)
            case .pause: UInt32(CGSpotifyCommandPause)
            case .togglePlayPause: UInt32(CGSpotifyCommandPlayPause)
            case .next: UInt32(CGSpotifyCommandNext)
            case .previous: UInt32(CGSpotifyCommandPrevious)
            case .bringHere: UInt32(CGSpotifyCommandBringHere)
            }
        }
    }

    /// How the receiver introduces itself to Spotify. librespot on iOS
    /// otherwise impersonates the Spotify iPhone app — its least-used path;
    /// the desktop speaker identity is what every Raspberry Pi install uses.
    enum Identity: String, CaseIterable, Equatable {
        case desktopSpeaker, iPhoneApp

        var title: String {
            switch self {
            case .desktopSpeaker: "Desktop speaker"
            case .iPhoneApp: "iPhone app"
            }
        }
    }

    /// Everything the panel renders, swapped as one value so a poll that
    /// changes nothing invalidates nothing.
    struct Snapshot: Equatable {
        var phase: Phase = .stopped
        var playback: Playback = .idle
        var title = ""
        var artist = ""
        var remoteClient = ""
        var handoff: Handoff = .none
        /// Track position (s) as of this poll, and the track length (s).
        var position: Double = 0
        var duration: Double = 0
        var message = ""
        var sampleRate = 0
        var channels = 0
        var framesDelivered: UInt64 = 0
        var peak: Float = 0
        var pcmFlowing = false
        var zeroconfPort = 0
        var volumePercent = 0
        var firstPCMMilliseconds = 0
        var hopsAnalyzed: UInt64 = 0
        var chunksDropped: UInt64 = 0
        var presentationDelayMs = 0
        var playbackQueuedMs = 0
        /// The speaker is actually pulling decoded audio (render thread alive).
        var speakerPulling = false
        var underruns: UInt64 = 0
        var analyzerRunning = false
        var analyzerOnSpotify = false
    }

    private(set) var snapshot = Snapshot()
    /// What the shared analyzer publishes right now (bass/mid/high/overall).
    private(set) var levels = AudioFeatures.silent
    /// Wants the receiver running (Start pressed, Stop not yet).
    private(set) var isEnabled = false
    /// Identity used for the next start (a change restarts a running receiver).
    private(set) var identity: Identity = .desktopSpeaker
    /// The newest receiver log lines (sanitised in Rust), for the live tail.
    private(set) var logTail: [String] = []

    /// Phase 2: the received music plays here (speaker / Bluetooth / AirPlay).
    let output = SpotifyPlaybackOutput()
    /// Play the music on this iPhone while the receiver runs (off = Phase 1's
    /// silent, analysis-only listening).
    private(set) var playsOnPhone: Bool
    /// Light offset relative to what is heard, ms (negative = lights earlier).
    private(set) var lightOffsetMs: Int
    static let lightOffsetRange = -500...3000

    nonisolated static let playsOnPhoneKey = "spotifyExperiment.playsOnPhone"
    nonisolated static let lightOffsetKey = "spotifyExperiment.lightOffsetMs"

    let librespotRevision = String(cString: cg_spotify_librespot_revision())

    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var lifecycle: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var lastFrames: UInt64 = 0
    @ObservationIgnored private var lastConsoleAt: Double = 0
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var networkWasSatisfied = true
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var backgroundGrace: UIBackgroundTaskIdentifier = .invalid

    private init() {
        let defaults = UserDefaults.standard
        playsOnPhone = defaults.object(forKey: Self.playsOnPhoneKey) as? Bool ?? true
        lightOffsetMs = Self.clampOffset(defaults.integer(forKey: Self.lightOffsetKey))
        SpotifyPCMRouter.shared.setUserOffset(Double(lightOffsetMs) / 1000)
        output.onChange = { [weak self] in self?.applyOutputLatency() }
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.endBackgroundGrace()
                self?.recoverIfNeeded(reason: "foreground")
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.beginBackgroundGrace() }
        })
    }

    /// Picking "ChromaGlow Sync" usually means switching to the Spotify app,
    /// which backgrounds ChromaGlow. With playback on, the running audio
    /// output keeps the app alive (background audio mode, experimental config
    /// only); without it, ask iOS for the standard short grace period (public
    /// API, ~30 s) to finish the zeroconf hand-off and login.
    private func beginBackgroundGrace() {
        guard isEnabled, backgroundGrace == .invalid else { return }
        backgroundGrace = UIApplication.shared.beginBackgroundTask(withName: "Spotify Connect hand-off") { [weak self] in
            Task { @MainActor in self?.endBackgroundGrace() }
        }
        // backgroundTimeRemaining is DBL_MAX mid-transition — never Int() it raw.
        let remaining = min(UIApplication.shared.backgroundTimeRemaining, 999)
        print("[SpotifyPCM] background grace started (remaining ≈ \(Int(remaining)) s)")
    }

    private func endBackgroundGrace() {
        guard backgroundGrace != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundGrace)
        backgroundGrace = .invalid
    }

    // MARK: - Lifecycle

    func start() {
        guard !isEnabled else { return }
        isEnabled = true
        update { $0.phase = .starting; $0.message = "Starting the receiver…" }
        // Started from a tap, in the foreground: the session can activate
        // now, and the running output keeps the hand-off alive in background.
        if playsOnPhone { output.start() }
        SpotifyNowPlaying.shared.activate(receiver: self)
        let name = Self.deviceName
        let previous = lifecycle
        lifecycle = Task { @MainActor in
            await previous?.value
            guard self.isEnabled else { return }
            let directory = Self.resetStreamDirectory()
            cg_spotify_set_persona(self.identity == .desktopSpeaker)
            let generation = await Task.detached(priority: .userInitiated) {
                Self.startReceiver(name: name, temporaryDirectory: directory.path)
            }.value
            guard self.isEnabled else {
                // Stop landed while starting: the queued stop tears this down.
                return
            }
            self.generation = generation
            SpotifyPCMRouter.shared.setReceiverGeneration(generation)
            if generation == 0 {
                self.update { $0.phase = .failed; $0.message = "The receiver refused to start." }
                self.isEnabled = false
                self.output.stop()
                SpotifyNowPlaying.shared.deactivate()
                return
            }
            self.lastFrames = 0
            self.startPolling()
            self.startPathMonitor()
        }
    }

    func stop() {
        guard isEnabled else { return }
        isEnabled = false
        // Instant invalidation: the gate closes before Rust is even asked.
        SpotifyPCMRouter.shared.setReceiverGeneration(0)
        output.stop()
        SpotifyNowPlaying.shared.deactivate()
        update { $0.message = "Stopping…" }
        let previous = lifecycle
        lifecycle = Task { @MainActor in
            await previous?.value
            await Task.detached(priority: .userInitiated) { cg_spotify_stop() }.value
            Self.purgeStreamDirectory()
            self.pollOnce()
            self.stopPolling()
            self.stopPathMonitor()
            self.generation = 0
            self.levels = .silent
            self.update {
                $0 = Snapshot()
                $0.message = "Receiver stopped."
            }
        }
    }

    /// Send a transport command to Spotify. False when there is no Connect
    /// session (nothing picked this device yet) — the command is dropped.
    @discardableResult
    func send(_ command: Command) -> Bool {
        guard isEnabled else { return false }
        return cg_spotify_command(command.code)
    }

    /// Turn on-phone playback on/off; a running receiver switches live.
    func setPlaysOnPhone(_ on: Bool) {
        guard on != playsOnPhone else { return }
        playsOnPhone = on
        UserDefaults.standard.set(on, forKey: Self.playsOnPhoneKey)
        guard isEnabled else { return }
        if on { output.start() } else { output.stop() }
    }

    /// Move the lights relative to the music (ms; negative = earlier).
    func setLightOffset(milliseconds: Int) {
        let clamped = Self.clampOffset(milliseconds)
        guard clamped != lightOffsetMs else { return }
        lightOffsetMs = clamped
        UserDefaults.standard.set(clamped, forKey: Self.lightOffsetKey)
        SpotifyPCMRouter.shared.setUserOffset(Double(clamped) / 1000)
    }

    nonisolated static func clampOffset(_ ms: Int) -> Int {
        min(max(ms, lightOffsetRange.lowerBound), lightOffsetRange.upperBound)
    }

    /// The router delays lights by the route latency only while music plays.
    private func applyOutputLatency() {
        SpotifyPCMRouter.shared.setOutputLatency(output.state == .playing ? output.routeLatency : 0)
    }

    /// Switch identity; a running receiver restarts so Spotify sees the new one.
    func setIdentity(_ next: Identity) {
        guard next != identity else { return }
        identity = next
        guard isEnabled else { return }
        stop()
        start()
    }

    /// A sanitised diagnostics report: build, identity, the current status
    /// snapshot and the receiver's recent log (account names, credential
    /// blobs and tokens are redacted in Rust before they reach the buffer).
    func diagnosticsReport() -> String {
        let info = Bundle.main.infoDictionary
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let s = snapshot
        var lines = [
            "ChromaGlow Spotify experiment diagnostics",
            "build \(build) · \(librespotRevision) · identity \(identity.rawValue)",
            "phase=\(s.phase) playback=\(s.playback) port=\(s.zeroconfPort) frames=\(s.framesDelivered) hops=\(s.hopsAnalyzed) play→PCM=\(s.firstPCMMilliseconds)ms",
            "output=\(output.state) pulling=\(s.speakerPulling) route=\(output.routeName) airplay=\(output.routeIsAirPlay) latency=\(Int(output.routeLatency * 1000))ms queue=\(s.playbackQueuedMs)ms underruns=\(s.underruns) lightDelay=\(s.presentationDelayMs)ms offset=\(lightOffsetMs)ms",
            "handoff=\(s.handoff) position=\(Int(s.position))/\(Int(s.duration))s",
            "message: \(s.message)",
            "---- receiver log ----",
        ]
        lines.append(Self.copyLog())
        return lines.joined(separator: "\n")
    }

    nonisolated static func copyLog(capacity: Int = 64 * 1024) -> String {
        var buffer = [CChar](repeating: 0, count: capacity)
        let count = buffer.withUnsafeMutableBufferPointer { cg_spotify_copy_log($0.baseAddress, capacity) }
        return String(decoding: buffer.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Restart a receiver that died underneath us (Wi-Fi change, suspension).
    private func recoverIfNeeded(reason: String) {
        guard isEnabled, snapshot.phase == .failed || snapshot.phase == .stopped else { return }
        print("[SpotifyPCM] restarting receiver after \(reason)")
        isEnabled = false
        let previous = lifecycle
        lifecycle = Task { @MainActor in
            await previous?.value
            await Task.detached(priority: .userInitiated) { cg_spotify_stop() }.value
        }
        start()
    }

    /// Device-test hook (experimental builds only): launching with
    /// `-ChromaGlowSpotifyAutoStart` selects the Spotify source, starts the
    /// receiver and holds an analysis demand, so the console's 1 Hz
    /// `[SpotifyPCM]` line proves discovery → PCM → analyzer without touching
    /// the UI:
    ///   xcrun devicectl device process launch --console --terminate-existing \
    ///     --device <id> com.huehome.pro -ChromaGlowSpotifyAutoStart
    static func autoStartIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard arguments.contains("-ChromaGlowSpotifyAutoStart") else { return }
        print("[SpotifyPCM] auto-start requested by launch argument")
        Task { @MainActor in
            await AudioAnalysisEngine.shared.selectSource(.spotifyConnect)
            await AudioAnalysisEngine.shared.setDemand(.syncMode, active: true)
            shared.start()
        }
    }

    /// Await any in-flight start/stop (tests, teardown ordering).
    func settle() async {
        await lifecycle?.value
    }

    // MARK: - FFI (nonisolated: runs on a detached task)

    nonisolated private static func startReceiver(name: String, temporaryDirectory: String) -> UInt64 {
        name.withCString { cName in
            temporaryDirectory.withCString { cDir in
                cg_spotify_start(cName, cDir) { generation, samples, frames, channels, sampleRate, queued in
                    // librespot's player thread — real-time path, no captures.
                    guard let samples else { return }
                    SpotifyPCMRouter.shared.route(
                        generation: generation,
                        samples: samples,
                        frames: frames,
                        channels: channels,
                        sampleRate: sampleRate,
                        queuedFrames: queued
                    )
                }
            }
        }
    }

    // MARK: - Temp storage (encrypted stream buffer only)

    nonisolated static var streamDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ChromaGlowSpotifyStream", isDirectory: true)
    }

    @discardableResult
    nonisolated static func resetStreamDirectory() -> URL {
        purgeStreamDirectory()
        let url = streamDirectory
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    nonisolated static func purgeStreamDirectory() {
        try? FileManager.default.removeItem(at: streamDirectory)
    }

    // MARK: - Polling

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.pollOnce()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollOnce() {
        var status = CGSpotifyStatus()
        guard cg_spotify_status(&status), status.generation == generation, generation != 0 else { return }
        let now = CACurrentMediaTime()
        SpotifyPCMRouter.shared.silenceIfStalled(now: now)
        let router = SpotifyPCMRouter.shared.snapshot()
        let engine = AudioAnalysisEngine.shared
        let flowing = status.frames_delivered > lastFrames
        lastFrames = status.frames_delivered

        var next = snapshot
        next.phase = Self.phase(status.state)
        next.playback = Self.playback(status.playback)
        next.title = Self.string(status.title)
        next.artist = Self.string(status.artist)
        next.remoteClient = Self.string(status.remote_client)
        next.handoff = Self.handoff(status.handoff)
        next.duration = Double(status.duration_ms) / 1000
        next.position = Self.position(
            reportedMs: status.position_ms, ageMs: status.position_age_ms,
            durationMs: status.duration_ms, playing: next.playback == .playing)
        next.message = Self.string(status.message)
        next.sampleRate = Int(status.sample_rate)
        next.channels = Int(status.channels)
        next.framesDelivered = status.frames_delivered
        next.peak = status.last_peak
        next.pcmFlowing = flowing
        next.zeroconfPort = Int(status.zeroconf_port)
        next.volumePercent = Int((Double(status.volume) / 65535 * 100).rounded())
        next.firstPCMMilliseconds = Int(status.first_pcm_ms)
        next.hopsAnalyzed = router.hopsAnalyzed
        next.chunksDropped = router.chunksDropped
        next.presentationDelayMs = Int((router.presentationDelay * 1000).rounded())
        next.playbackQueuedMs = Int((Double(status.playback_queued_frames) / SpotifyPlaybackOutput.sampleRate * 1000).rounded())
        next.underruns = status.underruns
        next.speakerPulling = cg_spotify_playback_live()
        next.analyzerRunning = engine.isRunning
        next.analyzerOnSpotify = engine.sourceKind == .spotifyConnect
        if next != snapshot { snapshot = next }
        SpotifyNowPlaying.shared.update(next)
        levels = AudioAnalysisEngine.latestFeatures()
        let tail = Array(Self.copyLog(capacity: 4096).split(separator: "\n").suffix(8).map(String.init))
        if tail != logTail { logTail = tail }

        if now - lastConsoleAt >= 1 {
            lastConsoleAt = now
            // AirPlay reports its real latency only once the route settles.
            output.refreshRoute()
            logDiagnostics(next)
        }
    }

    private func logDiagnostics(_ s: Snapshot) {
        let f = levels
        print(String(
            format: "[SpotifyPCM] state=%@ playback=%@ fmt=%dHz/%dch frames=%llu flowing=%@ peak=%.3f hops=%llu dropped=%llu delay=%dms firstPCM=%dms | out=%@ pull=%@ route=%@ lat=%dms queue=%dms under=%llu | analyzer=%@/%@ level=%.2f bass=%.2f mid=%.2f treble=%.2f raw=%.2f onset=%.2f bpm=%.0f",
            "\(s.phase)", "\(s.playback)", s.sampleRate, s.channels, s.framesDelivered,
            s.pcmFlowing ? "yes" : "no", s.peak, s.hopsAnalyzed, s.chunksDropped,
            s.presentationDelayMs, s.firstPCMMilliseconds,
            "\(output.state)", s.speakerPulling ? "live" : "no", output.routeName, Int(output.routeLatency * 1000), s.playbackQueuedMs, s.underruns,
            s.analyzerRunning ? "running" : "idle", s.analyzerOnSpotify ? "spotify" : "mic",
            f.level, f.bass, f.mid, f.treble, f.rawOverall, f.onsetStrength, f.bpm
        ))
    }

    private func update(_ mutate: (inout Snapshot) -> Void) {
        var next = snapshot
        mutate(&next)
        if next != snapshot { snapshot = next }
    }

    // MARK: - Network changes

    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(satisfied: satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "com.lightshade.app.spotify-path"))
        pathMonitor = monitor
    }

    private func stopPathMonitor() {
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    private func networkChanged(satisfied: Bool) {
        defer { networkWasSatisfied = satisfied }
        guard satisfied != networkWasSatisfied else { return }
        print("[SpotifyPCM] network \(satisfied ? "back" : "lost") (phase=\(snapshot.phase))")
        if satisfied { recoverIfNeeded(reason: "network change") }
    }

    // MARK: - C status decoding

    private static func phase(_ raw: UInt32) -> Phase {
        switch Int(raw) {
        case Int(CGSpotifyStateStopped): .stopped
        case Int(CGSpotifyStateStarting): .starting
        case Int(CGSpotifyStateWaiting): .waiting
        case Int(CGSpotifyStateConnecting): .connecting
        case Int(CGSpotifyStateConnected): .connected
        default: .failed
        }
    }

    private static func playback(_ raw: UInt32) -> Playback {
        switch Int(raw) {
        case Int(CGSpotifyPlaybackLoading): .loading
        case Int(CGSpotifyPlaybackPlaying): .playing
        case Int(CGSpotifyPlaybackPaused): .paused
        default: .idle
        }
    }

    private static func handoff(_ raw: UInt32) -> Handoff {
        switch Int(raw) {
        case Int(CGSpotifyHandoffActive): .active
        case Int(CGSpotifyHandoffMovedAway): .movedAway
        default: .none
        }
    }

    /// Current track position: the last reported one, advanced by its age
    /// while playing, clamped to the track.
    nonisolated static func position(reportedMs: UInt32, ageMs: UInt32, durationMs: UInt32, playing: Bool) -> Double {
        var ms = Double(reportedMs) + (playing ? Double(ageMs) : 0)
        if durationMs > 0 { ms = min(ms, Double(durationMs)) }
        return ms / 1000
    }

    /// Decode a fixed C char array (imported as a tuple), bounded by its size.
    static func string<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}

#endif
