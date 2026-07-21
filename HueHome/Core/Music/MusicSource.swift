// MusicSource.swift
// ChromaGlow — Core/Music (music integration R1)
//
// The metadata layer of the music integration (see
// docs/ios/music-integration-design-2026-07.md §3–§4): a MusicSource knows
// WHAT is playing and WHERE in the track playback is; it never touches
// audio. The signal layer (AudioAnalysisEngine + BeatClock) remains the
// only consumer of sound. Sources push updates; MusicSessionCoordinator
// owns the active source and drives BeatClock.

import Foundation
import CoreGraphics

// MARK: - Models

enum MusicService: String, Codable, CaseIterable, Sendable {
    case appleMusic
    case shazamDetected
    case spotify
    case demo
}

struct NowPlayingTrack: Equatable, Sendable {
    var service: MusicService
    var title: String
    var artist: String
    var isrc: String? = nil
    var appleMusicID: String? = nil
    var durationMs: Int? = nil
    var artworkURL: URL? = nil
    /// Tempo known directly by the source (demo tracks, future catalog
    /// hints). Skips the tempo resolver entirely when present.
    var tempoHint: Double? = nil
}

/// One position sample. `capturedAt` is in the CACurrentMediaTime timebase —
/// the same clock BeatClock and the render loops use — so consumers
/// extrapolate: position now = positionMs/1000 + (now − capturedAt).
struct PlaybackPosition: Equatable, Sendable {
    var positionMs: Int
    var capturedAt: Double
    var isPlaying: Bool
}

enum TransportAction: Sendable {
    case play, pause, togglePlayPause, nextTrack, previousTrack
}

struct SourceCapabilities: OptionSet, Sendable {
    let rawValue: Int
    static let transport = SourceCapabilities(rawValue: 1 << 0)
    static let artwork   = SourceCapabilities(rawValue: 1 << 1)
    static let position  = SourceCapabilities(rawValue: 1 << 2)
}

enum MusicSourceError: Error, Equatable {
    case authorizationDenied
    case subscriptionRequired
    case unavailable(String)
}

// MARK: - MusicSource

@MainActor
protocol MusicSource: AnyObject {
    var service: MusicService { get }
    var capabilities: SourceCapabilities { get }
    /// Fired on track / position / play-state changes. A nil track means
    /// nothing is playing. Position arrives at poll cadence (~1 Hz).
    var onUpdate: ((NowPlayingTrack?, PlaybackPosition?) -> Void)? { get set }
    func start() async throws
    func stop()
    /// No-op for actions outside `capabilities`.
    func transport(_ action: TransportAction) async
    /// Artwork pixels the source can supply without a network fetch (demo
    /// art is generated in-process). Sources that only have a URL return
    /// nil; the coordinator then fetches `artworkURL` itself.
    func artworkImage() async -> CGImage?
}

extension MusicSource {
    func artworkImage() async -> CGImage? { nil }
}
