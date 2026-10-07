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
    /// The playing track's album art as light, by role — song colors (Play
    /// Along P6). Never from Spotify, whose terms forbid deriving from cover
    /// art; gone with the track (Apple 4.5.2(ii): art only with its playback).
    private(set) var artworkSwatches: ArtworkSwatches?
    /// This song on these speakers was learned before: the beat grid came
    /// straight from the song memory ("Remembered"). Track cadence only.
    private(set) var beatRemembered = false

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
    @ObservationIgnored private let songMemory: SongMemory
    /// The phone's output route fingerprint (the song memory's key).
    @ObservationIgnored private let route: () -> String
    @ObservationIgnored private let hostNow: () -> Double

    init(
        clock: BeatClock? = nil,
        resolver: TrackTempoResolver? = nil,
        fetchArtwork: ((URL) async -> CGImage?)? = nil,
        songMemory: SongMemory? = nil,
        route: (() -> String)? = nil,
        hostNow: (() -> Double)? = nil
    ) {
        self.clock = clock ?? BeatClock.shared
        self.resolver = resolver ?? TrackTempoResolver(providers: TrackTempoResolver.liveProviders())
        self.fetchArtwork = fetchArtwork ?? { url in
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            return UIImage(data: data)?.cgImage
        }
        self.songMemory = songMemory ?? SongMemory.shared
        self.route = route ?? { SongMemory.cachedRoute() }
        self.hostNow = hostNow ?? { CACurrentMediaTime() }
    }

    var hasSession: Bool { activeService != nil }
    var capabilities: SourceCapabilities { source?.capabilities ?? [] }

    // MARK: - Session lifecycle

    func activate(_ newSource: any MusicSource) async throws {
        deactivate()
        SongMemory.primeRouteCache()
        source = newSource
        activeService = newSource.service
        newSource.onUpdate = { [weak self] track, position in
            self?.handleUpdate(track: track, position: position)
        }
        do {
            try await newSource.start()
        } catch {
            // start() can suspend for a long time (auth prompt, login
            // sheet) — by the time it throws, a newer activation may own
            // the coordinator. Tearing THAT down was the audit-R9 race:
            // only deactivate if this source is still the active one.
            if source === newSource {
                deactivate()
            } else {
                newSource.onUpdate = nil
                newSource.stop()
            }
            throw error
        }
        if source !== newSource {
            // Superseded while start() was suspended: the newer session
            // owns the coordinator. deactivate() already stopped this
            // instance once; stop again defensively (sources are
            // idempotent) in case start() re-installed anything after.
            newSource.onUpdate = nil
            newSource.stop()
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
        if artworkSwatches != nil { artworkSwatches = nil }
        if beatRemembered { beatRemembered = false }
        lastPosition = nil
        clock.endServiceDrive(trackChanged: true)
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
        // A live estimate is the microphone's own guess handed back. Driving
        // the clock with it as a SERVICE tempo froze that guess for the whole
        // track (the service hold outranks every later mic estimate) and made
        // `.beat` looks release the mic as "service-driven". Only metadata
        // tempos may take the hold; on a live estimate the clock stays on
        // audio-follow and keeps listening.
        guard tempo.origin != .liveEstimate else { return }
        let now = hostNow()
        // Play Along P5: where this song's beats fall on these speakers, if
        // it was learned before — then the grid is right from the first drive.
        let key = nowPlaying.map { SongMemory.key(for: TempoQuery(track: $0), route: route()) }
        let remembered = key.flatMap { songMemory.recall($0, bpm: tempo.bpm) }
        // The clock takes a remembered grid only while it has no offset for
        // this track yet; "Remembered" means the grid came from it.
        let fromMemory = remembered != nil && clock.serviceBeatOffset == nil
        clock.driveFromTrack(bpm: tempo.bpm, position: position, confidence: tempo.confidence,
                             beatOffset: remembered?.offset, barKnown: remembered?.barKnown ?? false, now: now)
        if fromMemory, !beatRemembered { beatRemembered = true }
        // ...and learn it, while the microphone confirms where they fall.
        if let key, let offset = clock.confirmedServiceOffset(now: now) {
            songMemory.observe(key, bpm: tempo.bpm, barOffset: offset, beatsPerBar: clock.beatsPerBar,
                               phaseConfidence: clock.phaseConfidence, barConfidence: clock.barConfidence, at: now)
        }
    }

    private func startTempoResolve(for track: NowPlayingTrack?) {
        tempoTask?.cancel()
        if tempo != nil { tempo = nil }   // a stale grid must not drive the new track
        if beatRemembered { beatRemembered = false }
        // ...and the CLOCK must not keep it either: without this, a track
        // change whose tempo never resolves left the old track's grid
        // driving indefinitely — and the stale hold suppressed the very
        // mic demand whose ingest self-heal could have cleared it (audit
        // R9, F1). driveClockIfReady re-enters the drive when the new
        // tempo lands; until then the look runs at the last tempo on
        // audio-follow, exactly like a pause. The track CHANGED, so the old
        // track's learned beat offset and named downbeat go with it.
        clock.endServiceDrive(trackChanged: true)
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
        if artworkSwatches != nil { artworkSwatches = nil }
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
            if track.service != .spotify {
                self.artworkSwatches = ArtworkPaletteExtractor.swatches(from: image)
            }
        }
    }
}
