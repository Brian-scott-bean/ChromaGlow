// SpotifyPlaybackOutput.swift
// ChromaGlow — Experimental/SpotifyConnect (LOCAL-ONLY experiment, Phase 2)
//
// Plays the music the receiver decodes, so "ChromaGlow Sync" is a real
// speaker — on the phone, Bluetooth, or one or MORE AirPlay 2 speakers at
// once. Public API only:
//
//   • AVAudioSession .playback / .default with routeSharingPolicy
//     .longFormAudio — the long-form route that unlocks AirPlay 2 multi-room
//     in the system route picker (WWDC17 509 "Introducing AirPlay 2").
//     Long-form apps are expected to publish Now Playing info and handle
//     remote commands; that lives in SpotifyNowPlaying.swift (other lane).
//   • AVSampleBufferAudioRenderer + AVSampleBufferRenderSynchronizer, fed on
//     one serial queue (SpotifyPlaybackFeeder) with CMSampleBuffers built from
//     PCM pulled out of the Rust receiver's ring (cg_spotify_read_playback).
//
// Light timing comes from the synchronizer's timeline: every frame gets a
// contiguous presentation timestamp, so a chunk the receiver hands to analysis
// with `queued_frames` ahead of it in the ring will play at timeline time
// (nextFrame + queued) / rate — converted to host time through the
// synchronizer's timebase (SpotifyPlaybackClock). Per WWDC17 509 the
// synchronizer's timeline is the one the audio is HEARD on — a local video
// layer on the same synchronizer stays in sync with audio on an AirPlay
// speaker — so no route latency is added on top.
//
// Nothing is written anywhere: the ring, the feeder's scratch / history and
// the renderer's queue are the only places decoded audio exists.
//
// Compiles only under CHROMAGLOW_EXPERIMENTAL_SPOTIFY (never in Release).

#if CHROMAGLOW_EXPERIMENTAL_SPOTIFY

import AVFoundation
import ChromaGlowSpotifyFFI
import CoreMedia
import Foundation
import Observation
import QuartzCore

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

    /// The receiver's output format (librespot decodes 44.1 kHz stereo); the
    /// live rate is read from the receiver's status when the output starts.
    nonisolated static let sampleRate: Double = 44_100
    /// Depth of the Rust ring (decoder → feeder hand-off). It no longer sets
    /// the light delay — the renderer's timeline does — so it only has to
    /// cover a few feeder ticks plus decoder bursts; anything deeper just
    /// delays a Spotify skip/seek by as much.
    nonisolated static let targetQueueSeconds: Double = 0.25

    private(set) var state: State = .off
    /// Where the music is heard ("iPhone Speaker", an AirPlay speaker…).
    private(set) var routeName = ""
    private(set) var routeIsAirPlay = false
    /// outputLatency + ioBufferDuration the session reports for the current
    /// route (seconds) — display only now: the lights follow the renderer's
    /// timeline, which already accounts for the route.
    private(set) var routeLatency: Double = 0

    /// Called after every state / route change (the receiver refreshes the
    /// router's latency and its status from here).
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    @ObservationIgnored private var feeder: SpotifyPlaybackFeeder?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
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
        guard feeder == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            // .playback + long-form: music that keeps playing with the screen
            // locked, routable to AirPlay 2 (several speakers) and Bluetooth.
            // Long-form allows no category options (no mixing) — this IS the
            // music player while the receiver is on.
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
            try session.setActive(true, options: [])
            let rate = Self.receiverSampleRate()
            let feeder = try SpotifyPlaybackFeeder(sampleRate: rate)
            let feederID = ObjectIdentifier(feeder)
            feeder.onFailure = { [weak self] message in
                Task { @MainActor in self?.feederFailed(feederID, message: message) }
            }
            // A pause flushes the music; light hops already scheduled for it
            // must not flash on after the silence.
            feeder.onPauseFlush = { SpotifyPCMRouter.shared.dropScheduledLights() }
            // Enable the ring before the feeder's first pull, so the receiver
            // sees a live consumer from the start.
            cg_spotify_set_playback(true, UInt32(Self.targetQueueSeconds * rate))
            feeder.start(airPlay: Self.currentRouteIsAirPlay())
            self.feeder = feeder
            SpotifyPCMRouter.shared.setPlaybackClock(feeder.clock)
            state = .playing
            print("[SpotifyPCM] playback output started (long-form, \(Int(rate)) Hz)")
        } catch {
            teardownFeeder()
            state = .failed(error.localizedDescription)
            print("[SpotifyPCM] playback output failed: \(error.localizedDescription)")
        }
        refreshRoute()
    }

    /// Stop playing; the receiver falls back to analysis-only pacing. Audio
    /// stops synchronously (renderer flushed, timeline stopped, feeder idle).
    func stop() {
        wanted = false
        guard feeder != nil || state != .off else { return }
        teardownFeeder()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        state = .off
        refreshRoute()
        print("[SpotifyPCM] playback output stopped")
    }

    /// Re-read the route (cheap; the receiver calls it once a second because
    /// AirPlay settles late). Also tells the feeder which buffering to use.
    func refreshRoute() {
        let session = AVAudioSession.sharedInstance()
        let output = session.currentRoute.outputs.first
        let name = output?.portName ?? ""
        let airPlay = Self.currentRouteIsAirPlay()
        let latency = state == .playing ? max(0, session.outputLatency + session.ioBufferDuration) : 0
        if name != routeName { routeName = name }
        if airPlay != routeIsAirPlay { routeIsAirPlay = airPlay }
        if abs(latency - routeLatency) > 0.0005 { routeLatency = latency }
        feeder?.setAirPlay(airPlay)
        onChange?()
    }

    /// Feeder counters (diagnostics / tests); nil while not playing.
    func feedSnapshot() -> SpotifyPlaybackFeeder.Snapshot? {
        feeder?.snapshot()
    }

    // MARK: - System events

    private func interruption(_ type: AVAudioSession.InterruptionType?, shouldResume: Bool) {
        guard wanted, let type else { return }
        switch type {
        case .began:
            // The system has already silenced us; drop the queued audio.
            teardownFeeder()
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

    /// Media services reset or a failed renderer: start over with fresh
    /// renderer / synchronizer objects. Route changes (AirPlay, Bluetooth) need
    /// no rebuild — the renderer follows the route itself and re-requests what
    /// it flushed (see SpotifyPlaybackFeeder.refill).
    private func rebuild(reason: String) {
        guard wanted else { return }
        print("[SpotifyPCM] playback output rebuilding (\(reason))")
        teardownFeeder()
        start()
    }

    private func feederFailed(_ id: ObjectIdentifier, message: String) {
        guard let feeder, ObjectIdentifier(feeder) == id else { return }
        print("[SpotifyPCM] renderer failed: \(message)")
        rebuild(reason: "renderer failed")
    }

    private func teardownFeeder() {
        // Lights stop following a timeline that is about to disappear.
        SpotifyPCMRouter.shared.setPlaybackClock(nil)
        feeder?.stop()
        feeder = nil
        // Disabling playback clears the ring: stale audio never plays later.
        cg_spotify_set_playback(false, 0)
    }

    private static func currentRouteIsAirPlay() -> Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .airPlay }
    }

    private static func receiverSampleRate() -> Double {
        var status = CGSpotifyStatus()
        if cg_spotify_status(&status), status.sample_rate >= 8_000 {
            return Double(status.sample_rate)
        }
        return sampleRate
    }
}

// MARK: - Clock (shared with the analysis router)

/// Maps "a chunk the receiver just queued" to the host time it will be heard.
/// Read on librespot's player thread (router), written on the feeder queue.
final class SpotifyPlaybackClock: @unchecked Sendable {
    let sampleRate: Double
    private let timebase: CMTimebase?
    private let lock = NSLock()
    private var active = true
    /// Timeline frame the next frame pulled from the ring will play at.
    private var nextFrame: Int64 = 0
    /// While the timeline is stopped (before the first audio / after a stall
    /// or pause) audio will start `pendingStartDelay` after it arrives.
    private var pendingStartDelay: Double
    /// A start the feeder has scheduled: timeline `frame` at host `host`.
    private var scheduled: (frame: Int64, host: Double)?

    init(sampleRate: Double, timebase: CMTimebase?, pendingStartDelay: Double) {
        self.sampleRate = sampleRate
        self.timebase = timebase
        self.pendingStartDelay = pendingStartDelay
    }

    // Feeder side.

    func setNextFrame(_ frame: Int64) {
        lock.lock(); nextFrame = frame; lock.unlock()
    }

    func setPending(startDelay: Double) {
        lock.lock(); pendingStartDelay = startDelay; scheduled = nil; lock.unlock()
    }

    func setScheduledStart(frame: Int64, host: Double) {
        lock.lock(); scheduled = (frame, host); lock.unlock()
    }

    func deactivate() {
        lock.lock(); active = false; lock.unlock()
    }

    // Router side (player thread).

    /// Host time (CACurrentMediaTime base) at which the chunk with `queued`
    /// frames ahead of it in the ring will be heard; nil when not playing.
    func presentationHostTime(queuedFrames: UInt32, now: Double) -> Double? {
        lock.lock()
        let active = self.active
        let frame = nextFrame + Int64(queuedFrames)
        let pending = pendingStartDelay
        let scheduled = self.scheduled
        lock.unlock()
        guard active else { return nil }
        var timelineNow = 0.0
        var rate = 0.0
        if let timebase {
            let t = CMTimebaseGetTime(timebase).seconds
            timelineNow = t.isFinite ? t : 0
            rate = CMTimebaseGetRate(timebase)
        }
        return Self.hostTime(
            framePTS: Double(frame) / sampleRate,
            timelineNow: timelineNow, timelineRate: rate, hostNow: now,
            scheduledStart: scheduled.map { (pts: Double($0.frame) / sampleRate, host: $0.host) },
            pendingStartDelay: pending
        )
    }

    /// Pure: when timeline time `framePTS` is heard, in host seconds.
    ///  • timeline running: now + (pts − timelineNow) / rate;
    ///  • stopped with a scheduled start (pts₀ at host h₀): h₀ + (pts − pts₀);
    ///  • stopped, nothing scheduled: it starts `pendingStartDelay` after the
    ///    audio arrives — now + delay + (pts − timelineNow).
    static func hostTime(
        framePTS: Double,
        timelineNow: Double,
        timelineRate: Double,
        hostNow: Double,
        scheduledStart: (pts: Double, host: Double)?,
        pendingStartDelay: Double
    ) -> Double {
        if timelineRate > 0 {
            return hostNow + (framePTS - timelineNow) / timelineRate
        }
        if let scheduledStart {
            return scheduledStart.host + (framePTS - scheduledStart.pts)
        }
        return hostNow + pendingStartDelay + max(0, framePTS - timelineNow)
    }
}

// MARK: - Feeder

/// Pull/pace policy, pure so it can be unit-tested.
enum SpotifyFeedPolicy {
    /// Frames per CMSampleBuffer (≈ 93 ms at 44.1 kHz).
    static let chunkFrames = 4096
    /// The Rust receiver counts its consumer dead after 300 ms without a pull
    /// (and then stops queueing for playback) — pull at least this often.
    static let keepAliveInterval = 0.1
    /// Timeline running with less than this enqueued and nothing in the ring:
    /// park the timeline instead of letting it run past the audio.
    static let stallGuard = 0.03

    struct Tuning: Equatable, Sendable {
        /// Most audio kept enqueued ahead of the timeline. Bounds how late a
        /// Spotify skip / seek is heard (pause flushes, so it's instant).
        var lookahead: Double
        /// After the first audio arrives, the timeline starts this much later
        /// — the renderer's (and an AirPlay group's) preroll.
        var startDelay: Double

        static let local = Tuning(lookahead: 1.0, startDelay: 0.2)
        /// AirPlay 2 buffers on the speaker and asks for much more; give it
        /// a deeper queue and preroll, still bounded (skip latency).
        static let airPlay = Tuning(lookahead: 3.0, startDelay: 1.0)
    }

    /// How many frames to pull from the ring now. Prefers whole chunks;
    /// takes a partial one when the renderer is running low or the receiver
    /// needs a pull to keep counting us as its consumer.
    static func framesToPull(
        available: Int, roomFrames: Int, lowWater: Bool, keepAliveDue: Bool, chunk: Int = chunkFrames
    ) -> Int {
        let n = min(available, max(0, roomFrames), chunk)
        if n >= chunk || (n > 0 && (lowWater || keepAliveDue)) { return n }
        // Lookahead full but the receiver needs a pull: take a little over.
        if keepAliveDue, available > 0 { return min(available, chunk) }
        return 0
    }

    /// Park the timeline: it runs, almost nothing is left enqueued, and the
    /// ring has nothing to add (a stall or the end of the stream).
    static func shouldStall(running: Bool, bufferedSeconds: Double, available: Int) -> Bool {
        running && available == 0 && bufferedSeconds < stallGuard
    }
}

/// Decoded audio already enqueued, kept so a renderer auto-flush (route
/// change) can be re-enqueued from the flush time. Memory only, bounded.
struct SpotifyPCMHistory {
    let capacityFrames: Int
    private var samples: [Float]
    /// Frames [start, end) of the timeline are held.
    private(set) var start: Int64 = 0
    private(set) var end: Int64 = 0

    init(capacityFrames: Int) {
        self.capacityFrames = max(1, capacityFrames)
        samples = [Float](repeating: 0, count: self.capacityFrames * 2)
    }

    /// Forget everything; the next append starts at `frame`.
    mutating func reset(at frame: Int64) {
        start = frame
        end = frame
    }

    /// Append `count` interleaved stereo frames at timeline frame `frame`
    /// (contiguous with `end`; a gap resets).
    mutating func append(_ src: UnsafePointer<Float>, count: Int, at frame: Int64) {
        if frame != end { reset(at: frame) }
        let capacity = Int64(capacityFrames)
        samples.withUnsafeMutableBufferPointer { dst in
            for i in 0..<count {
                let slot = Int((frame + Int64(i)) % capacity) * 2
                dst[slot] = src[2 * i]
                dst[slot + 1] = src[2 * i + 1]
            }
        }
        end = frame + Int64(count)
        start = max(start, end - capacity)
    }

    /// Copy up to `count` frames from `frame` into `out`; returns frames copied.
    func read(from frame: Int64, count: Int, into out: UnsafeMutablePointer<Float>) -> Int {
        guard frame >= start, frame < end else { return 0 }
        let n = Int(min(Int64(count), end - frame))
        let capacity = Int64(capacityFrames)
        samples.withUnsafeBufferPointer { src in
            for i in 0..<n {
                let slot = Int((frame + Int64(i)) % capacity) * 2
                out[2 * i] = src[slot]
                out[2 * i + 1] = src[slot + 1]
            }
        }
        return n
    }
}

/// Owns the renderer + synchronizer and feeds them from the Rust ring on one
/// serial queue. Every mutable field is confined to `queue`; the main actor
/// talks to it only through start / stop / setAirPlay / snapshot.
final class SpotifyPlaybackFeeder: @unchecked Sendable {
    /// Where PCM comes from — the Rust receiver, or a test double.
    struct Source: Sendable {
        /// Frames waiting in the ring, and whether Spotify is paused/idle;
        /// nil when the receiver has no status.
        var status: @Sendable () -> (queued: Int, paused: Bool)?
        /// Pull up to `frames` interleaved stereo frames; returns frames read.
        var read: @Sendable (UnsafeMutablePointer<Float>, Int) -> Int

        static let receiver = Source(
            status: {
                var status = CGSpotifyStatus()
                guard cg_spotify_status(&status) else { return nil }
                let p = Int(status.playback)
                let paused = p == Int(CGSpotifyPlaybackPaused) || p == Int(CGSpotifyPlaybackIdle)
                return (Int(status.playback_queued_frames), paused)
            },
            read: { out, frames in Int(cg_spotify_read_playback(out, UInt32(frames))) }
        )
    }

    struct Snapshot: Equatable {
        var feeding = false
        var running = false
        var nextFrame: Int64 = 0
        var timelineSeconds: Double = 0
        var timelineRate: Float = 0
        var bufferedSeconds: Double = 0
        var framesEnqueued: Int64 = 0
        var stalls = 0
        var pauseFlushes = 0
        var autoFlushRefills = 0
        var tuning = SpotifyFeedPolicy.Tuning.local
    }

    let renderer = AVSampleBufferAudioRenderer()
    let synchronizer = AVSampleBufferRenderSynchronizer()
    let clock: SpotifyPlaybackClock
    let sampleRate: Double
    /// Called once (on the feeder queue) when the renderer fails.
    var onFailure: (@Sendable (String) -> Void)?
    /// Called (on the feeder queue) after a Spotify pause flushed the audio.
    var onPauseFlush: (@Sendable () -> Void)?

    private let queue = DispatchQueue(label: "com.huehome.spotify-exp.feeder", qos: .userInitiated)
    private let source: Source
    private let format: CMAudioFormatDescription
    private let timescale: CMTimeScale
    private let scratch: UnsafeMutablePointer<Float>
    private var history: SpotifyPCMHistory
    private var timer: DispatchSourceTimer?
    private var flushObserver: NSObjectProtocol?
    private var feeding = false
    private var running = false
    private var nextFrame: Int64 = 0
    private var lastPull: Double = 0
    private var hasAudioSinceFlush = false
    private var awaitingRenderer = false
    private var failureReported = false
    private var tuning = SpotifyFeedPolicy.Tuning.local
    private var counters = Snapshot()

    init(sampleRate: Double, source: Source = .receiver) throws {
        self.sampleRate = sampleRate
        self.source = source
        timescale = CMTimeScale(sampleRate.rounded())
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0
        )
        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description
        )
        guard status == noErr, let description else {
            throw NSError(domain: "SpotifyPlaybackOutput", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "No \(Int(sampleRate)) Hz stereo format"])
        }
        format = description
        scratch = .allocate(capacity: SpotifyFeedPolicy.chunkFrames * 2)
        scratch.initialize(repeating: 0, count: SpotifyFeedPolicy.chunkFrames * 2)
        history = SpotifyPCMHistory(
            capacityFrames: Int((SpotifyFeedPolicy.Tuning.airPlay.lookahead + 1) * sampleRate))
        // We decide when the timeline starts (a scheduled host time): AirPlay's
        // "sufficient data" threshold can exceed what a live stream will ever
        // have queued, which would never start.
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        synchronizer.addRenderer(renderer)
        clock = SpotifyPlaybackClock(sampleRate: sampleRate, timebase: synchronizer.timebase,
                                     pendingStartDelay: SpotifyFeedPolicy.Tuning.local.startDelay)
    }

    deinit {
        scratch.deallocate()
    }

    // MARK: Control (main actor)

    func start(airPlay: Bool) {
        queue.sync {
            guard timer == nil else { return }
            tuning = airPlay ? .airPlay : .local
            clock.setPending(startDelay: tuning.startDelay)
            feeding = true
            lastPull = 0
            flushObserver = NotificationCenter.default.addObserver(
                forName: .AVSampleBufferAudioRendererWasFlushedAutomatically, object: renderer, queue: nil
            ) { [weak self] note in
                let flushTime = (note.userInfo?[AVSampleBufferAudioRendererFlushTimeKey] as? NSValue)?.timeValue
                guard let feeder = self else { return }
                feeder.queue.async { [weak feeder] in feeder?.refill(from: flushTime) }
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(3))
            timer.setEventHandler { [weak self] in self?.pump() }
            self.timer = timer
            timer.resume()
        }
    }

    /// Synchronous: when this returns nothing is queued, the timeline is
    /// stopped and no timer / request block is left.
    func stop() {
        queue.sync {
            feeding = false
            timer?.cancel()
            timer = nil
            if let flushObserver { NotificationCenter.default.removeObserver(flushObserver) }
            flushObserver = nil
            renderer.stopRequestingMediaData()
            awaitingRenderer = false
            synchronizer.rate = 0
            renderer.flush()
            running = false
            clock.deactivate()
        }
    }

    func setAirPlay(_ airPlay: Bool) {
        queue.async { [self] in
            let next: SpotifyFeedPolicy.Tuning = airPlay ? .airPlay : .local
            guard next != tuning else { return }
            tuning = next
            if !running { clock.setPending(startDelay: next.startDelay) }
        }
    }

    func snapshot() -> Snapshot {
        queue.sync {
            var s = counters
            s.feeding = feeding && timer != nil
            s.running = running
            s.nextFrame = nextFrame
            s.timelineSeconds = synchronizer.currentTime().seconds
            s.timelineRate = synchronizer.rate
            s.bufferedSeconds = bufferedSeconds()
            s.tuning = tuning
            return s
        }
    }

    // MARK: Feeding (queue)

    private func bufferedSeconds() -> Double {
        let t = synchronizer.currentTime().seconds
        return Double(nextFrame) / sampleRate - (t.isFinite ? t : 0)
    }

    private func pump() {
        guard feeding else { return }
        if renderer.status == .failed {
            if !failureReported {
                failureReported = true
                onFailure?(renderer.error?.localizedDescription ?? "audio renderer failed")
            }
            return
        }
        let now = CACurrentMediaTime()
        let keepAliveDue = now - lastPull >= SpotifyFeedPolicy.keepAliveInterval
        let status = source.status()

        if status?.paused == true {
            // Spotify paused / stopped: what is queued must not keep playing.
            if hasAudioSinceFlush { flushForPause() }
            // Keep the receiver counting us as its consumer; whatever a stale
            // pull returns is pre-pause audio and is dropped.
            if keepAliveDue {
                lastPull = now
                _ = source.read(scratch, 1)
            }
            return
        }

        var available = status?.queued ?? 0
        if SpotifyFeedPolicy.shouldStall(running: running, bufferedSeconds: bufferedSeconds(), available: available) {
            stall()
        }

        var pulled = false
        while feeding {
            let buffered = bufferedSeconds()
            let room = Int(((tuning.lookahead - buffered) * sampleRate).rounded(.down))
            let n = SpotifyFeedPolicy.framesToPull(
                available: available, roomFrames: room,
                lowWater: buffered < tuning.lookahead * 0.5,
                keepAliveDue: !pulled && keepAliveDue
            )
            if n == 0 { break }
            if !renderer.isReadyForMoreMediaData {
                awaitRenderer()
                break
            }
            let got = pull(n)
            pulled = true
            available = max(0, available - got)
            if got < n { break }
        }
        // Nothing to take, but the receiver must keep seeing a consumer.
        if !pulled, keepAliveDue {
            pull(1)
        }
    }

    /// Pull up to `frames` from the ring and enqueue them at the timeline's
    /// next frame. Returns frames pulled.
    @discardableResult
    private func pull(_ frames: Int) -> Int {
        lastPull = CACurrentMediaTime()
        let got = min(frames, source.read(scratch, frames))
        guard got > 0 else { return 0 }
        let frame = nextFrame
        nextFrame += Int64(got)
        // Published right after the pop: a chunk the receiver queues from now
        // on maps to nextFrame + its queued_frames.
        clock.setNextFrame(nextFrame)
        if !running { startTimeline(firstFrame: frame) }
        history.append(scratch, count: got, at: frame)
        enqueue(scratch, frames: got, at: frame)
        hasAudioSinceFlush = true
        return got
    }

    private func enqueue(_ src: UnsafePointer<Float>, frames: Int, at frame: Int64) {
        guard let buffer = makeSampleBuffer(src, frames: frames, at: frame) else { return }
        renderer.enqueue(buffer)
        counters.framesEnqueued += Int64(frames)
    }

    /// One CMSampleBuffer of interleaved float32 stereo at timeline `frame`.
    func makeSampleBuffer(_ src: UnsafePointer<Float>, frames: Int, at frame: Int64) -> CMSampleBuffer? {
        let bytes = frames * 8
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        ) == kCMBlockBufferNoErr, let block,
            CMBlockBufferReplaceDataBytes(with: src, blockBuffer: block, offsetIntoDestination: 0,
                                          dataLength: bytes) == kCMBlockBufferNoErr
        else { return nil }
        var sample: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: frames, presentationTimeStamp: CMTime(value: frame, timescale: timescale),
            packetDescriptions: nil, sampleBufferOut: &sample
        )
        return status == noErr ? sample : nil
    }

    private func frame(of time: CMTime, fallback: Int64) -> Int64 {
        time.isNumeric ? Int64((time.seconds * sampleRate).rounded()) : fallback
    }

    /// First audio after a start / stall / pause: schedule the timeline to
    /// start `startDelay` from now at the frame it is parked on, so the clock
    /// knows exactly when every queued frame will be heard.
    private func startTimeline(firstFrame: Int64) {
        let startHost = CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()),
                                  CMTime(seconds: tuning.startDelay, preferredTimescale: 1_000_000_000))
        let parked = min(frame(of: synchronizer.currentTime(), fallback: firstFrame), firstFrame)
        clock.setScheduledStart(frame: parked, host: startHost.seconds)
        synchronizer.setRate(1, time: CMTime(value: parked, timescale: timescale), atHostTime: startHost)
        running = true
    }

    /// The ring ran dry while the timeline ran: park the timeline (no silence
    /// is ever enqueued) and restart it when audio returns.
    private func stall() {
        synchronizer.rate = 0
        running = false
        let parked = frame(of: synchronizer.currentTime(), fallback: nextFrame)
        if parked > nextFrame {
            // The timeline outran the audio: continue from where it stopped.
            nextFrame = parked
            clock.setNextFrame(nextFrame)
            history.reset(at: nextFrame)
        }
        clock.setPending(startDelay: tuning.startDelay)
        counters.stalls += 1
        print("[SpotifyPCM] playback stalled — timeline parked at \(String(format: "%.2f", Double(parked) / sampleRate)) s")
    }

    /// Spotify paused / stopped: drop what's queued so the music stops now,
    /// and park the timeline (the receiver clears its ring itself).
    private func flushForPause() {
        synchronizer.rate = 0
        renderer.flush()
        running = false
        hasAudioSinceFlush = false
        nextFrame = frame(of: synchronizer.currentTime(), fallback: nextFrame)
        clock.setNextFrame(nextFrame)
        history.reset(at: nextFrame)
        clock.setPending(startDelay: tuning.startDelay)
        counters.pauseFlushes += 1
        onPauseFlush?()
        print("[SpotifyPCM] Spotify paused — playback flushed")
    }

    /// The renderer is full: let it call back when it wants more.
    private func awaitRenderer() {
        guard !awaitingRenderer else { return }
        awaitingRenderer = true
        renderer.requestMediaDataWhenReady(on: queue) { [weak self] in
            guard let self else { return }
            self.renderer.stopRequestingMediaData()
            self.awaitingRenderer = false
            self.pump()
        }
    }

    /// The renderer flushed itself (route / output change): re-enqueue what
    /// it dropped from our history so nothing is skipped and the timeline —
    /// and so the lights — stay where they were.
    private func refill(from flushTime: CMTime?) {
        guard feeding else { return }
        var frame = history.start
        if let flushTime, flushTime.isNumeric {
            frame = max(frame, self.frame(of: flushTime, fallback: frame))
        }
        counters.autoFlushRefills += 1
        while frame < history.end {
            let n = history.read(from: frame, count: SpotifyFeedPolicy.chunkFrames, into: scratch)
            if n == 0 { break }
            enqueue(scratch, frames: n, at: frame)
            frame += Int64(n)
        }
        print("[SpotifyPCM] renderer flushed by the system — re-enqueued from history")
    }
}

#endif
