// SpotifyNowPlaying.swift
// ChromaGlow — Experimental/SpotifyConnect (LOCAL-ONLY experiment)
//
// Lock screen / Control Center for the Spotify receiver: the track, its
// progress, and play / pause / next / previous, sent to Spotify Connect.
//
// Why it exists: once Spotify has handed playback to "ChromaGlow Sync", the
// phone's own Spotify app no longer needs to be open — and while it IS open
// it takes the music back whenever the iPhone's speaker changes (device round,
// build 903). With these controls the Spotify app can be closed after the
// hand-off and the speaker picked in ChromaGlow.
//
// Public MediaPlayer API only. Updated from the receiver's 4 Hz poll, and only
// when something a viewer would notice changed.
//
// Compiles only under CHROMAGLOW_EXPERIMENTAL_SPOTIFY (never in Release).

#if CHROMAGLOW_EXPERIMENTAL_SPOTIFY

import Foundation
import MediaPlayer
import QuartzCore

@MainActor
final class SpotifyNowPlaying {
    static let shared = SpotifyNowPlaying()

    private weak var receiver: SpotifyConnectReceiver?
    private var targets: [(MPRemoteCommand, Any)] = []
    private var published: Sample?

    /// What was last handed to MPNowPlayingInfoCenter.
    struct Sample: Equatable {
        var title: String
        var artist: String
        var duration: Double
        var playing: Bool
        var position: Double
        var publishedAt: Double
    }

    private init() {}

    /// Take over the remote commands while the receiver runs.
    func activate(receiver: SpotifyConnectReceiver) {
        self.receiver = receiver
        guard targets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        bind(center.playCommand) { $0.resumeOrBringHere() }
        bind(center.pauseCommand) { $0.send(.pause) }
        bind(center.togglePlayPauseCommand) { r in
            if r.snapshot.playback == .playing { r.send(.pause) } else { r.resumeOrBringHere() }
        }
        bind(center.nextTrackCommand) { $0.send(.next) }
        bind(center.previousTrackCommand) { $0.send(.previous) }
    }

    func deactivate() {
        for (command, target) in targets {
            command.removeTarget(target)
            command.isEnabled = false
        }
        targets = []
        published = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    func update(_ s: SpotifyConnectReceiver.Snapshot) {
        guard !targets.isEmpty else { return }
        guard s.phase == .connected, s.handoff == .active, !s.title.isEmpty else {
            if published != nil {
                published = nil
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
                MPNowPlayingInfoCenter.default().playbackState = .stopped
            }
            return
        }
        let now = CACurrentMediaTime()
        let next = Sample(title: s.title, artist: s.artist, duration: s.duration,
                             playing: s.playback == .playing, position: s.position,
                             publishedAt: now)
        if let last = published, !Self.needsPublish(last: last, next: next) { return }
        published = next
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: next.title,
            MPMediaItemPropertyArtist: next.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: next.position,
            MPNowPlayingInfoPropertyPlaybackRate: next.playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if next.duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = next.duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = next.playing ? .playing : .paused
    }

    /// Republish on a track / play-state change, or when the position drifts
    /// from what the lock screen extrapolates (a seek) — not on every poll.
    nonisolated static func needsPublish(last: Sample, next: Sample) -> Bool {
        if last.title != next.title || last.artist != next.artist
            || last.duration != next.duration || last.playing != next.playing {
            return true
        }
        let expected = last.position + (last.playing ? next.publishedAt - last.publishedAt : 0)
        return abs(expected - next.position) > 1.5
    }

    private func bind(_ command: MPRemoteCommand, _ action: @escaping @MainActor (SpotifyConnectReceiver) -> Void) {
        command.isEnabled = true
        let target = command.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let receiver = self?.receiver, receiver.isEnabled else { return .noSuchContent }
                action(receiver)
                return .success
            }
        }
        targets.append((command, target))
    }
}

extension SpotifyConnectReceiver {
    /// Play — or, if Spotify moved the music elsewhere, bring it back here.
    func resumeOrBringHere() {
        send(snapshot.handoff == .movedAway ? .bringHere : .play)
    }
}

#endif
