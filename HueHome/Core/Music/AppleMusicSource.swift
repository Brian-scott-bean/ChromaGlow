// AppleMusicSource.swift
// ChromaGlow — Core/Music (music integration R3)
//
// Apple Music via MusicKit's SystemMusicPlayer: mirrors and controls
// whatever the user plays in the Music app — ChromaGlow owns nothing,
// needs no background-audio mode, and playback survives the app dying.
// Track identity (incl. ISRC for the tempo sidecar) + a 1 Hz playbackTime
// poll feed the coordinator; MusicKit gives NO audio buffers and NO BPM
// (design doc §2.1) — that's what the mic engine and TempoProviders are for.
//
// Consuming MusicKit's ObservableObjects via Combine is allowed (the
// AGENTS rule bans AUTHORING new ObservableObject patterns).

import Foundation
import MusicKit
import Combine
import QuartzCore
import UIKit

// MARK: - Pure mapping seam (testable without MusicKit values)

struct AppleMusicEntrySnapshot: Equatable {
    var title: String
    var artistName: String
    var isrc: String?
    var appleMusicID: String?
    var durationSeconds: TimeInterval?
    var artworkURL: URL?

    func track() -> NowPlayingTrack {
        NowPlayingTrack(
            service: .appleMusic,
            title: title,
            artist: artistName,
            isrc: isrc,
            appleMusicID: appleMusicID,
            durationMs: durationSeconds.map { Int(($0 * 1000).rounded()) },
            artworkURL: artworkURL
        )
    }

    /// Poll cadence truth table: poll only while actually playing in the
    /// foreground — position can't move otherwise, and Gate-B QA pins the
    /// battery expectation to this.
    static func shouldPoll(isPlaying: Bool, isBackgrounded: Bool) -> Bool {
        isPlaying && !isBackgrounded
    }
}

// MARK: - AppleMusicSource

@MainActor
final class AppleMusicSource: MusicSource {

    let service: MusicService = .appleMusic
    let capabilities: SourceCapabilities = [.transport, .artwork, .position]
    var onUpdate: ((NowPlayingTrack?, PlaybackPosition?) -> Void)?

    private let player = SystemMusicPlayer.shared
    private var sinks: Set<AnyCancellable> = []
    private var pollTask: Task<Void, Never>?
    private var isBackgrounded = false
    private var lastTrack: NowPlayingTrack?
    /// Block-based NC observers are removed by TOKEN — removeObserver(self)
    /// is a no-op for them and leaked one pair per activation (audit R9,
    /// F9; correct pattern precedent: AudioAnalysisEngine.ncObservers).
    private var lifecycleObservers: [NSObjectProtocol] = []

    func start() async throws {
        var status = MusicAuthorization.currentStatus
        if status == .notDetermined {
            status = await MusicAuthorization.request()
        }
        guard status == .authorized else {
            throw MusicSourceError.authorizationDenied
        }

        player.state.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &sinks)
        player.queue.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &sinks)

        // Foreground discipline (AudioAnalysisEngine's observer pattern).
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.setBackgrounded(true) }
        })
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.setBackgrounded(false) }
        })

        refresh()
    }

    func stop() {
        sinks.removeAll()
        for token in lifecycleObservers { NotificationCenter.default.removeObserver(token) }
        lifecycleObservers.removeAll()
        pollTask?.cancel()
        pollTask = nil
        lastTrack = nil
    }

    func transport(_ action: TransportAction) async {
        do {
            switch action {
            case .play:
                try await player.play()
            case .pause:
                player.pause()
            case .togglePlayPause:
                if player.state.playbackStatus == .playing {
                    player.pause()
                } else {
                    try await player.play()
                }
            case .nextTrack:
                try await player.skipToNextEntry()
            case .previousTrack:
                try await player.skipToPreviousEntry()
            }
        } catch {
            // Transport can fail (nothing queued, no subscription for the
            // item). The player state sink reports the truth either way.
        }
        refresh()
    }

    // MARK: - State → coordinator

    private func setBackgrounded(_ backgrounded: Bool) {
        isBackgrounded = backgrounded
        refresh()
    }

    private func refresh() {
        let snapshot = Self.snapshot(of: player.queue.currentEntry)
        let track = snapshot?.track()
        let isPlaying = player.state.playbackStatus == .playing
        lastTrack = track

        let position: PlaybackPosition? = track == nil ? nil : PlaybackPosition(
            positionMs: Int((player.playbackTime * 1000).rounded()),
            capturedAt: CACurrentMediaTime(),
            isPlaying: isPlaying
        )
        onUpdate?(track, position)
        configurePolling(isPlaying: isPlaying)
    }

    private func configurePolling(isPlaying: Bool) {
        let shouldPoll = AppleMusicEntrySnapshot.shouldPoll(
            isPlaying: isPlaying, isBackgrounded: isBackgrounded)
        if shouldPoll, pollTask == nil {
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.emitPositionTick()
                }
            }
        } else if !shouldPoll {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    private func emitPositionTick() {
        guard let track = lastTrack else { return }
        onUpdate?(track, PlaybackPosition(
            positionMs: Int((player.playbackTime * 1000).rounded()),
            capturedAt: CACurrentMediaTime(),
            isPlaying: player.state.playbackStatus == .playing
        ))
    }

    /// MusicKit values → the pure snapshot. The only lines that touch
    /// MusicKit types; everything after is testable.
    private static func snapshot(of entry: MusicPlayer.Queue.Entry?) -> AppleMusicEntrySnapshot? {
        guard let entry else { return nil }
        if case .song(let song) = entry.item {
            return AppleMusicEntrySnapshot(
                title: song.title,
                artistName: song.artistName,
                isrc: song.isrc,
                appleMusicID: song.id.rawValue,
                durationSeconds: song.duration,
                artworkURL: song.artwork?.url(width: 600, height: 600)
            )
        }
        // Non-song entries (videos etc.): show what we know, sync less.
        return AppleMusicEntrySnapshot(
            title: entry.title,
            artistName: entry.subtitle ?? "",
            isrc: nil,
            appleMusicID: nil,
            durationSeconds: nil,
            artworkURL: entry.artwork?.url(width: 600, height: 600)
        )
    }
}
