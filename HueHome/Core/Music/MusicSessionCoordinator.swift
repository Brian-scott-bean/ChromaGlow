// MusicSessionCoordinator.swift
// ChromaGlow — Core/Music (music integration R1)
//
// Owns the active MusicSource and turns its updates into: a BeatClock
// service drive (position + resolved BPM), an artwork palette, and the
// observable Now Playing state the UI reads. Follows the
// DeepLinkCoordinator pattern (shared singleton, .environment-injected in
// HueHomeApp) — UnifiedOrchestrator is deliberately untouched; render
// loops keep reading BeatClock.snapshot() and never learn about music.

import Foundation
import CoreGraphics
import QuartzCore
import UIKit

@MainActor
@Observable
final class MusicSessionCoordinator {

    static let shared = MusicSessionCoordinator()

    // Observed state — written at track-change cadence only.
    private(set) var nowPlaying: NowPlayingTrack?
    private(set) var activeService: MusicService?
    private(set) var isPlaying = false
    private(set) var tempo: ResolvedTempo?
    private(set) var artworkPalette: PaletteConfig?

    /// Position arrives at poll cadence (~1 Hz); observing it would
    /// invalidate the Studio tab once a second forever (the
    /// CompositionParamBox rule). UI derives elapsed time through
    /// currentPositionEstimate(now:) inside an isTabActive-gated
    /// TimelineView instead.
    @ObservationIgnored private(set) var lastPosition: PlaybackPosition?

    @ObservationIgnored private var source: (any MusicSource)?
    /// Bumped on every track change / deactivation; async tempo + artwork
    /// completions from a previous generation are dropped (the app-wide
    /// generation-counter pattern).
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var tempoTask: Task<Void, Never>?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?

    @ObservationIgnored private let clock: BeatClock
    @ObservationIgnored private let resolver: TrackTempoResolver
    @ObservationIgnored private let fetchArtwork: (URL) async -> CGImage?

    init(
        clock: BeatClock? = nil,
        resolver: TrackTempoResolver? = nil,
        fetchArtwork: ((URL) async -> CGImage?)? = nil
    ) {
        self.clock = clock ?? BeatClock.shared
        self.resolver = resolver ?? TrackTempoResolver(providers: TrackTempoResolver.liveProviders())
        self.fetchArtwork = fetchArtwork ?? { url in
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            return UIImage(data: data)?.cgImage
        }
    }

    var hasSession: Bool { activeService != nil }
    var capabilities: SourceCapabilities { source?.capabilities ?? [] }

    // MARK: - Session lifecycle

    func activate(_ newSource: any MusicSource) async throws {
        deactivate()
        source = newSource
        activeService = newSource.service
        newSource.onUpdate = { [weak self] track, position in
            self?.handleUpdate(track: track, position: position)
        }
        do {
            try await newSource.start()
        } catch {
            deactivate()
            throw error
        }
    }

    func deactivate() {
        generation &+= 1
        tempoTask?.cancel(); tempoTask = nil
        artworkTask?.cancel(); artworkTask = nil
        source?.onUpdate = nil
        source?.stop()
        source = nil
        if nowPlaying != nil { nowPlaying = nil }
        if activeService != nil { activeService = nil }
        if isPlaying { isPlaying = false }
        if tempo != nil { tempo = nil }
        if artworkPalette != nil { artworkPalette = nil }
        lastPosition = nil
        clock.endServiceDrive()
    }

    func transport(_ action: TransportAction) async {
        await source?.transport(action)
    }

    /// Extrapolated position for elapsed-time UI (never observed state).
    func currentPositionEstimate(now: Double = CACurrentMediaTime()) -> PlaybackPosition? {
        guard let p = lastPosition else { return nil }
        guard p.isPlaying else { return p }
        var ms = p.positionMs + Int((now - p.capturedAt) * 1000)
        if let duration = nowPlaying?.durationMs { ms = min(ms, duration) }
        return PlaybackPosition(positionMs: ms, capturedAt: now, isPlaying: true)
    }

    // MARK: - Source updates

    private func handleUpdate(track: NowPlayingTrack?, position: PlaybackPosition?) {
        if track != nowPlaying {
            nowPlaying = track
            generation &+= 1
            startTempoResolve(for: track)
            startArtworkExtraction(for: track)
        }
        lastPosition = position
        let playing = position?.isPlaying ?? false
        if isPlaying != playing { isPlaying = playing }
        if playing {
            driveClockIfReady()
        } else {
            clock.endServiceDrive()
        }
    }

    private func driveClockIfReady() {
        guard let tempo, let position = lastPosition, position.isPlaying else { return }
        clock.driveFromTrack(bpm: tempo.bpm, position: position, confidence: tempo.confidence)
    }

    private func startTempoResolve(for track: NowPlayingTrack?) {
        tempoTask?.cancel()
        if tempo != nil { tempo = nil }   // a stale grid must not drive the new track
        guard let track else { return }
        let gen = generation
        tempoTask = Task { [weak self] in
            guard let self else { return }
            let resolved = await self.resolver.resolve(for: track)
            guard !Task.isCancelled, self.generation == gen else { return }
            self.tempo = resolved
            self.driveClockIfReady()
        }
    }

    private func startArtworkExtraction(for track: NowPlayingTrack?) {
        artworkTask?.cancel()
        if artworkPalette != nil { artworkPalette = nil }
        guard let track else { return }
        let gen = generation
        let currentSource = source
        artworkTask = Task { [weak self] in
            guard let self else { return }
            var image = await currentSource?.artworkImage()
            if image == nil, let url = track.artworkURL {
                image = await self.fetchArtwork(url)
            }
            guard !Task.isCancelled, self.generation == gen, let image else { return }
            self.artworkPalette = ArtworkPaletteExtractor.extract(from: image)
        }
    }
}
