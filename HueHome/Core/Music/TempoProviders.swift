// TempoProviders.swift
// ChromaGlow — Core/Music (music integration R3)
//
// The live TempoProvider implementations behind TrackTempoResolver:
//   1. TIDAL — catalog `bpm` by ISRC (verified in the live v2 OpenAPI spec,
//      2026-07-21: Tracks_Attributes.bpm float-optional; ISRC filter;
//      THIRD_PARTY self-serve tier; client-credentials auth).
//   2. GetSongBPM — title/artist search fallback (free tier, attribution).
// Both take an injectable transport so tests run on fixtures, both send
// ONLY track identifiers, and both throw on transport trouble so the
// resolver falls through to the next provider / the live estimate.
// An empty credential = provider inactive (init returns nil).

import Foundation

// MARK: - Keys
//
// Paste real credentials here when the accounts exist (Gate A batch).
// These are LOW-SENSITIVITY catalog-lookup keys, not user secrets — but
// move them to an ignored xcconfig before any open-sourcing, and never
// log them (H-03 discipline: providers never os_log URLs or headers).

enum TempoProviderKeys {
    static let tidalClientID = ""
    static let tidalClientSecret = ""
    static let getSongBPMKey = ""
}

/// Shared transport shape — URLSession in production, fixtures in tests.
typealias TempoTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

// MARK: - TIDAL

final class TIDALTempoProvider: TempoProvider, @unchecked Sendable {
    let id = "tidal"

    private let clientID: String
    private let clientSecret: String
    private let transport: TempoTransport
    private let countryCode: String

    /// In-memory token cache (client-credentials). Lock-guarded — provider
    /// calls arrive off-main.
    private let tokenLock = NSLock()
    private var token: String?
    private var tokenExpiry: Date = .distantPast

    /// nil when credentials are absent — the resolver simply never sees it.
    init?(
        clientID: String = TempoProviderKeys.tidalClientID,
        clientSecret: String = TempoProviderKeys.tidalClientSecret,
        countryCode: String = Locale.current.region?.identifier ?? "US",
        transport: @escaping TempoTransport = { try await URLSession.shared.data(for: $0) }
    ) {
        guard !clientID.isEmpty, !clientSecret.isEmpty else { return nil }
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.countryCode = countryCode
        self.transport = transport
    }

    func tempo(for query: TempoQuery) async throws -> Double? {
        // TIDAL is an ISRC join — no ISRC, no lookup (GetSongBPM handles
        // title/artist).
        guard let isrc = query.isrc, !isrc.isEmpty else { return nil }

        var components = URLComponents(string: "https://openapi.tidal.com/v2/tracks")!
        components.queryItems = [
            URLQueryItem(name: "countryCode", value: countryCode),
            URLQueryItem(name: "filter[isrc]", value: isrc),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.api+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await transport(request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw TempoProviderError.badResponse
        }
        let decoded = try JSONDecoder().decode(TIDALTracksResponse.self, from: data)
        // One ISRC can map to several catalog entries; first bpm wins.
        return decoded.data.compactMap(\.attributes.bpm).first.map(Double.init)
    }

    private func accessToken() async throws -> String {
        tokenLock.lock()
        let cached = (token, tokenExpiry)
        tokenLock.unlock()
        if let t = cached.0, cached.1 > Date().addingTimeInterval(30) { return t }

        var request = URLRequest(url: URL(string: "https://auth.tidal.com/v1/oauth2/token")!)
        request.httpMethod = "POST"
        let basic = Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("grant_type=client_credentials".utf8)

        let (data, response) = try await transport(request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw TempoProviderError.authFailed
        }
        let decoded = try JSONDecoder().decode(TIDALTokenResponse.self, from: data)
        tokenLock.lock()
        token = decoded.access_token
        tokenExpiry = Date().addingTimeInterval(decoded.expires_in)
        tokenLock.unlock()
        return decoded.access_token
    }
}

/// JSON:API shapes — internal for fixture-based tests.
struct TIDALTracksResponse: Decodable {
    struct Track: Decodable {
        struct Attributes: Decodable {
            var bpm: Float?
        }
        var attributes: Attributes
    }
    var data: [Track]
}

struct TIDALTokenResponse: Decodable {
    var access_token: String
    var expires_in: TimeInterval
}

// MARK: - GetSongBPM

final class GetSongBPMProvider: TempoProvider, @unchecked Sendable {
    let id = "getsongbpm"

    private let apiKey: String
    private let transport: TempoTransport

    init?(
        apiKey: String = TempoProviderKeys.getSongBPMKey,
        transport: @escaping TempoTransport = { try await URLSession.shared.data(for: $0) }
    ) {
        guard !apiKey.isEmpty else { return nil }
        self.apiKey = apiKey
        self.transport = transport
    }

    func tempo(for query: TempoQuery) async throws -> Double? {
        // Two-step API: search song+artist → song detail carries "tempo".
        var search = URLComponents(string: "https://api.getsongbpm.com/search/")!
        search.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "type", value: "both"),
            URLQueryItem(name: "lookup", value: "song:\(query.title) artist:\(query.artist)"),
        ]
        let (searchData, searchResponse) = try await transport(URLRequest(url: search.url!))
        guard (searchResponse as? HTTPURLResponse)?.statusCode == 200 else {
            throw TempoProviderError.badResponse
        }
        guard let songID = try JSONDecoder()
            .decode(GetSongBPMSearchResponse.self, from: searchData).search?.first?.id
        else { return nil }

        var detail = URLComponents(string: "https://api.getsongbpm.com/song/")!
        detail.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "id", value: songID),
        ]
        let (detailData, detailResponse) = try await transport(URLRequest(url: detail.url!))
        guard (detailResponse as? HTTPURLResponse)?.statusCode == 200 else {
            throw TempoProviderError.badResponse
        }
        let tempoString = try JSONDecoder()
            .decode(GetSongBPMSongResponse.self, from: detailData).song?.tempo
        return tempoString.flatMap(Double.init)
    }
}

struct GetSongBPMSearchResponse: Decodable {
    struct Hit: Decodable { var id: String }
    var search: [Hit]?

    // The API returns `"search": {...error...}` (an object) on no-result —
    // tolerate any non-array shape as "no hits".
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        search = try? container.decodeIfPresent([Hit].self, forKey: .search)
    }
    private enum CodingKeys: String, CodingKey { case search }
}

struct GetSongBPMSongResponse: Decodable {
    struct Song: Decodable { var tempo: String? }
    var song: Song?
}

// MARK: - Errors

enum TempoProviderError: Error, Equatable {
    case authFailed
    case badResponse
}

// MARK: - Assembly

extension TrackTempoResolver {
    /// The production provider chain — order matters (ISRC-exact TIDAL
    /// first, fuzzy title search second). Inactive (keyless) providers
    /// drop out here.
    nonisolated static func liveProviders() -> [TempoProvider] {
        var providers: [TempoProvider] = []
        if let tidal = TIDALTempoProvider() { providers.append(tidal) }
        if let gsb = GetSongBPMProvider() { providers.append(gsb) }
        return providers
    }
}
