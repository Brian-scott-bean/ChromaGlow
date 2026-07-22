// SpotifySource.swift
// ChromaGlow — Core/Music (music integration R5, DEV-FLAGGED)
//
// Follows what plays in Spotify via Web API polling (3s while active +
// on transport, extrapolated between polls — Spotify pushes no events).
// Gated by FeatureFlags.spotifySource AND a configured SpotifyKeys.clientID;
// in Spotify's dev mode this works only for dashboard-allowlisted accounts.

import Foundation
import QuartzCore
import UIKit

@MainActor
final class SpotifySource: MusicSource {

    let service: MusicService = .spotify
    let capabilities: SourceCapabilities = [.transport, .artwork, .position]
    var onUpdate: ((NowPlayingTrack?, PlaybackPosition?) -> Void)?

    private static let pollSeconds: UInt64 = 3

    private let auth: SpotifyAuthService
    private var client: SpotifyAPIClient?
    private var pollTask: Task<Void, Never>?
    private var isBackgrounded = false
    private var lastKnownPlaying = false
    /// Block-based NC observers are removed by TOKEN — removeObserver(self)
    /// is a no-op for them and leaked one pair per activation (audit R9, F9).
    private var lifecycleObservers: [NSObjectProtocol] = []

    init(auth: SpotifyAuthService = SpotifyAuthService()) {
        self.auth = auth
    }

    func start() async throws {
        guard FeatureFlags.spotifySource, !SpotifyKeys.clientID.isEmpty else {
            throw MusicSourceError.unavailable("spotify-not-configured")
        }
        // Interactive login happens here if never linked — thrown errors
        // (cancelled sheet) surface in the picker.
        do {
            _ = try await auth.validAccessToken(allowInteractive: true)
        } catch SpotifyAuthService.AuthError.exchangeRejected {
            // The stored refresh token is definitively dead (revoked in
            // the user's Spotify account). Without this, picking Spotify
            // failed forever with no recovery path — wipe the dead grant
            // and run the login once. Transport errors deliberately do
            // NOT land here (a blip must not cost the stored link).
            auth.unlink()
            _ = try await auth.validAccessToken(allowInteractive: true)
        }
        let authService = auth   // @MainActor class — implicitly Sendable
        client = SpotifyAPIClient(accessToken: { @Sendable force in
            // Never interactive from a poll: after a mid-session unlink
            // this throws .notLinked and pollOnce keeps the last state —
            // a login sheet must only ever come from the picker's start().
            try await authService.validAccessToken(forceRefresh: force)
        })

        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.setBackgrounded(true) } })
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.setBackgrounded(false) } })

        await pollOnce()
        startPolling()
    }

    func stop() {
        for token in lifecycleObservers { NotificationCenter.default.removeObserver(token) }
        lifecycleObservers.removeAll()
        pollTask?.cancel()
        pollTask = nil
        client = nil
    }

    func transport(_ action: TransportAction) async {
        await client?.transportAction(action, isPlaying: lastKnownPlaying)
        // The write is async on Spotify's side — give it a beat, then truth.
        try? await Task.sleep(nanoseconds: 300_000_000)
        await pollOnce()
    }

    // MARK: - Polling

    private func setBackgrounded(_ backgrounded: Bool) {
        isBackgrounded = backgrounded
        if backgrounded {
            pollTask?.cancel()
            pollTask = nil
        } else {
            Task { await pollOnce() }
            startPolling()
        }
    }

    private func startPolling() {
        guard pollTask == nil, !isBackgrounded else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                // Slow tier keys on PLAYBACK, not backgrounding — background
                // cancels this task entirely, so an isBackgrounded check here
                // could never be true and the paused case polled at full rate
                // forever (1,200 req/h against a silent session).
                let interval = (self?.lastKnownPlaying == true) ? Self.pollSeconds : 10
                try? await Task.sleep(nanoseconds: interval * 1_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.pollOnce()
            }
        }
    }

    private func pollOnce() async {
        guard let client else { return }
        do {
            let now = CACurrentMediaTime()
            if let response = try await client.currentlyPlaying() {
                lastKnownPlaying = response.is_playing
                onUpdate?(response.track(), response.position(capturedAt: now))
            } else {
                // Explicit 204: genuinely nothing playing.
                lastKnownPlaying = false
                onUpdate?(nil, nil)
            }
        } catch SpotifyAuthService.AuthError.exchangeRejected {
            // The grant died mid-session (revoked in Spotify's dashboard).
            // Without this arm the 3s loop re-hit the token endpoint forever
            // — no backoff, silent frozen UI. Stop the loop and clear the
            // bar; recovery is the picker's start() (unlink + relink there).
            pollTask?.cancel()
            pollTask = nil
            lastKnownPlaying = false
            onUpdate?(nil, nil)
        } catch {
            // Transient network/auth hiccup — keep the last state; the next
            // poll tick is the retry.
        }
    }
}
