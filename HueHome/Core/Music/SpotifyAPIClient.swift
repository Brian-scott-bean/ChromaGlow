// SpotifyAPIClient.swift
// ChromaGlow — Core/Music (music integration R5, DEV-FLAGGED)
//
// Thin Web API client: currently-playing + transport. Position is polled
// (progress_ms) and extrapolated client-side — Spotify streams no events
// and no audio to third parties. 401 → one token refresh via the auth
// closure; 429/Retry-After → surface as throw (the source's next poll
// tick is the retry). Never logs anything (H-03).

import Foundation
import QuartzCore

// MARK: - Decode + mapping seams (tested)

struct SpotifyCurrentlyPlayingResponse: Decodable, Equatable {
    struct Item: Decodable, Equatable {
        struct Artist: Decodable, Equatable { var name: String }
        struct Album: Decodable, Equatable {
            struct Image: Decodable, Equatable {
                var url: String
                var width: Int?
            }
            var images: [Image]
        }
        struct ExternalIDs: Decodable, Equatable { var isrc: String? }
        var id: String?
        var name: String
        var duration_ms: Int?
        var artists: [Artist]
        var album: Album?
        var external_ids: ExternalIDs?
    }
    var progress_ms: Int?
    var is_playing: Bool
    var item: Item?

    /// nil when Spotify reports no track (ads, podcasts without item, idle).
    func track() -> NowPlayingTrack? {
        guard let item else { return nil }
        // Prefer ~600px art (the bar renders 36pt; 600 matches Apple Music).
        let artwork = item.album?.images
            .sorted { abs(($0.width ?? 0) - 600) < abs(($1.width ?? 0) - 600) }
            .first?.url
        return NowPlayingTrack(
            service: .spotify,
            title: item.name,
            artist: item.artists.map(\.name).joined(separator: ", "),
            isrc: item.external_ids?.isrc,
            durationMs: item.duration_ms,
            artworkURL: artwork.flatMap(URL.init(string:))
        )
    }

    func position(capturedAt: Double) -> PlaybackPosition? {
        guard item != nil, let progress = progress_ms else { return nil }
        return PlaybackPosition(positionMs: progress, capturedAt: capturedAt,
                                isPlaying: is_playing)
    }
}

// MARK: - Client

final class SpotifyAPIClient: @unchecked Sendable {

    enum ClientError: Error { case http(Int), unauthorized }

    private let transport: TempoTransport
    /// Supplies a valid access token. The Bool is forceRefresh: true on
    /// the one 401 retry — the local expiry clock said "valid" but Spotify
    /// disagreed, so re-serving the cached token would just 401 again.
    private let accessToken: @Sendable (Bool) async throws -> String

    init(
        accessToken: @escaping @Sendable (Bool) async throws -> String,
        transport: @escaping TempoTransport = { try await URLSession.shared.data(for: $0) }
    ) {
        self.accessToken = accessToken
        self.transport = transport
    }

    /// nil = nothing playing (HTTP 204).
    func currentlyPlaying() async throws -> SpotifyCurrentlyPlayingResponse? {
        let data = try await call("GET", "me/player/currently-playing")
        guard let data, !data.isEmpty else { return nil }
        return try JSONDecoder().decode(SpotifyCurrentlyPlayingResponse.self, from: data)
    }

    func transportAction(_ action: TransportAction, isPlaying: Bool) async {
        // Premium-only writes: a 403 means free account — stay silent, the
        // next poll shows the truth either way.
        switch action {
        case .play: _ = try? await call("PUT", "me/player/play")
        case .pause: _ = try? await call("PUT", "me/player/pause")
        case .togglePlayPause:
            _ = try? await call("PUT", isPlaying ? "me/player/pause" : "me/player/play")
        case .nextTrack: _ = try? await call("POST", "me/player/next")
        case .previousTrack: _ = try? await call("POST", "me/player/previous")
        }
    }

    private func call(_ method: String, _ path: String, retriedAuth: Bool = false) async throws -> Data? {
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/\(path)")!)
        request.httpMethod = method
        request.setValue("Bearer \(try await accessToken(retriedAuth))", forHTTPHeaderField: "Authorization")

        let (data, response) = try await transport(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: return data
        case 204: return nil
        case 401 where !retriedAuth:
            // Token revoked/expired server-side — retry exactly once with
            // a FORCED refresh (retriedAuth becomes the closure's flag).
            return try await call(method, path, retriedAuth: true)
        case 401: throw ClientError.unauthorized
        default: throw ClientError.http(status)
        }
    }
}
