// SpotifyPCMSource.swift
// ChromaGlow — Experimental/SpotifyConnect (LOCAL-ONLY experiment)
//
// The Spotify Connect receiver as an AudioAnalysisSource. Decoded PCM arrives
// through the Rust receiver's C callback on librespot's player thread; the
// router below downmixes and re-blocks it (InterleavedPCMHopper) and hands
// each hop to the engine's AudioPCMSink — the same sink the microphone feeds.
//
// Real-time rules: one NSLock per chunk (~23 ms), no MainActor hop, no Task,
// no allocation once warm. Two gates drop stale audio instantly:
//   • receiver generation — set to 0 the moment the receiver is stopped;
//   • the sink's activation generation — invalidated by the engine on stop /
//     source switch before this source's stop() even runs.
//
// Compiles only under CHROMAGLOW_EXPERIMENTAL_SPOTIFY (never in Release).

#if CHROMAGLOW_EXPERIMENTAL_SPOTIFY

import AVFoundation
import Foundation
import QuartzCore

@MainActor
final class SpotifyPCMSource: AudioAnalysisSource {
    let kind: AudioAnalysisSourceKind = .spotifyConnect
    /// Never reported: the receiver's own lifecycle (and its playback
    /// output's route changes) can't stop analysis behind the engine's back.
    var onSystemStop: (@MainActor () async -> Void)?
    private var started = false

    /// Live while the gate is open — a paused or disconnected receiver is a
    /// quiet source, not a dead one (the router publishes silence for it).
    var isLive: Bool { started }

    /// No permission: the receiver's lifecycle is explicit (Start/Stop in the
    /// experiment panel) and independent of analysis demand.
    func prepare(stillWanted: @MainActor () -> Bool) async -> Bool { true }

    func start(sink: AudioPCMSink) -> Bool {
        SpotifyPCMRouter.shared.openGate(sink)
        started = true
        return true
    }

    /// The session belongs to the playback output (SpotifyPlaybackOutput),
    /// never to analysis, so there is nothing to deactivate here.
    func stop(deactivatingSession: Bool) {
        started = false
        SpotifyPCMRouter.shared.closeGate()
    }
}

/// Routing table between the receiver thread and analysis. Thread-safe by one
/// NSLock; the hopper inside it is only ever driven under that lock.
final class SpotifyPCMRouter: @unchecked Sendable {
    static let shared = SpotifyPCMRouter()

    struct Diagnostics: Equatable {
        var hopsAnalyzed: UInt64 = 0
        var chunksDropped: UInt64 = 0
        var presentationDelay: Double = 0
        var lastHopAt: Double = 0
        var gateOpen = false
    }

    private let lock = NSLock()
    private var receiverGeneration: UInt64 = 0
    private var sink: AudioPCMSink?
    private let hopper = InterleavedPCMHopper(hopFrames: 1024)
    private var userOffset: Double = 0
    private var outputLatency: Double = 0
    /// The playback output's timeline while music plays on the phone; when
    /// set, it alone decides when a chunk is heard (see route()).
    private var playbackClock: SpotifyPlaybackClock?
    private var smoothedDelay: Double = 0
    private var hasDelay = false
    private var diagnostics = Diagnostics()

    // MARK: Control (main thread)

    /// The receiver generation whose callbacks are accepted (0 = none).
    func setReceiverGeneration(_ generation: UInt64) {
        lock.lock()
        receiverGeneration = generation
        hopper.reset()
        hasDelay = false
        let sink = self.sink
        lock.unlock()
        if generation == 0 { sink?.publishSilence() }
    }

    func openGate(_ sink: AudioPCMSink) {
        lock.lock()
        self.sink = sink
        hopper.reset()
        diagnostics.gateOpen = true
        lock.unlock()
    }

    func closeGate() {
        lock.lock()
        sink = nil
        hopper.reset()
        diagnostics.gateOpen = false
        lock.unlock()
    }

    /// Lighting offset relative to what is heard (seconds; negative = lights
    /// lead, to absorb the bridge's own latency). Total delay clamps at 0.
    func setUserOffset(_ seconds: Double) {
        lock.lock()
        userOffset = seconds
        lock.unlock()
    }

    /// Output latency of the playback route — 0 while nothing is playing, so
    /// analysis-only listening isn't delayed. Ignored while a playback clock
    /// is set (the renderer's timeline already includes the route).
    func setOutputLatency(_ seconds: Double) {
        lock.lock()
        outputLatency = max(0, seconds)
        lock.unlock()
    }

    /// The playback output's clock (nil = not playing on the phone).
    func setPlaybackClock(_ clock: SpotifyPlaybackClock?) {
        lock.lock()
        playbackClock = clock
        hasDelay = false
        lock.unlock()
    }

    func snapshot() -> Diagnostics {
        lock.lock()
        defer { lock.unlock() }
        return diagnostics
    }

    /// The playback output flushed (Spotify paused): drop the light hops
    /// still waiting for audio that will now never be heard. Any thread.
    func dropScheduledLights() {
        lock.lock()
        let sink = self.sink
        hopper.reset()
        lock.unlock()
        sink?.publishSilence()
    }

    /// Paused / stalled stream: once no hop has arrived for `after` seconds
    /// beyond the current presentation delay, publish silence so the lights
    /// settle instead of freezing on the last loud frame. Main-thread poller.
    func silenceIfStalled(now: Double, after: Double = 0.35) {
        lock.lock()
        let sink = self.sink
        let last = diagnostics.lastHopAt
        let stale = sink != nil && last > 0 && now - last > after + smoothedDelay
        if stale { diagnostics.lastHopAt = 0 }
        lock.unlock()
        if stale { sink?.publishSilence() }
    }

    // MARK: Hot path (receiver thread)

    func route(
        generation: UInt64,
        samples: UnsafePointer<Float>,
        frames: UInt32,
        channels: UInt32,
        sampleRate: UInt32,
        queuedFrames: UInt32
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard generation != 0, generation == receiverGeneration, let sink, sink.isCurrent else {
            diagnostics.chunksDropped &+= 1
            return
        }
        let rate = Double(sampleRate)
        let now = CACurrentMediaTime()
        if let heard = playbackClock?.presentationHostTime(queuedFrames: queuedFrames, now: now) {
            // Playing on the phone: this chunk is heard when the renderer's
            // timeline reaches it (the timeline already includes the route —
            // AirPlay too). Exact per chunk, so no smoothing.
            smoothedDelay = max(0, heard - now + userOffset)
            hasDelay = true
        } else {
            // Analysis-only (Phase 1): nothing queued, no route.
            let playoutDelay = Double(queuedFrames) / rate + outputLatency
            let target = max(0, playoutDelay + userOffset)
            if !hasDelay || abs(target - smoothedDelay) > 0.25 {
                smoothedDelay = target   // mode change / slider move: jump
                hasDelay = true
            } else {
                smoothedDelay += (target - smoothedDelay) * 0.05   // queue jitter: glide
            }
        }
        let presentation = now + smoothedDelay
        var hops: UInt64 = 0
        hopper.push(samples, frames: Int(frames), channels: Int(channels), sampleRate: rate) { mono, count, buffer in
            sink.deliver(
                mono: mono,
                frameCount: count,
                sampleRate: Float(rate),
                presentationTime: presentation,
                buffer: buffer
            )
            hops += 1
        }
        diagnostics.hopsAnalyzed &+= hops
        diagnostics.presentationDelay = smoothedDelay
        diagnostics.lastHopAt = now
    }
}

#endif
