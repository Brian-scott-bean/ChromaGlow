// TempoProviders.swift
// ChromaGlow — Core/Music (music integration R3, revised R7)
//
// The live TempoProvider chain behind TrackTempoResolver. GetSongBPM is
// the sole network provider: its API page explicitly welcomes third-party
// app use (incl. commercial) with one condition — a mandatory attribution
// backlink (More → APP row + store listing; account suspended without it).
// Base URL is api.getsong.co (the docs' api.getsongbpm.com host is a
// legacy name). 3000 req/hr; we do one lookup per track change, cached
// forever.
//
// TIDAL was REMOVED in R7 on verified terms grounds (Developer Terms v3.0):
// catalog metadata may not be stored indefinitely, cross-service
// integration / visual-media sync / content analysis require written
// approval, and the platform is limited to non-commercial apps. Do not
// reintroduce a TIDAL provider without a signed agreement.
//
// Providers take an injectable transport so tests run on fixtures, send
// ONLY track identifiers, and throw on transport trouble so the resolver
// falls through to the on-device estimate. Empty credential = provider
// inactive (init returns nil). Never log URLs/headers (H-03 discipline).

import Foundation

// MARK: - Keys
//
// Keys live OUTSIDE source control: paste them into Config/Secrets.xcconfig
// (git-ignored; template at Config/Secrets.xcconfig.example). The value
// flows Base.xcconfig → GETSONGBPM_API_KEY build setting → Info.plist →
// here; keyless checkouts resolve to "" and the provider stays inactive.
// Register with the ios-app:// App-ID format. Never log a key value.

enum TempoProviderKeys {
    static var getSongBPMKey: String {
        key(named: "GETSONGBPM_API_KEY", in: Bundle.main.infoDictionary)
    }

    /// Missing, non-string, whitespace-only, or unresolved `$(...)`
    /// placeholder values collapse to "" so dependent providers disable
    /// themselves instead of sending a garbage credential.
    static func key(named name: String, in info: [String: Any]?) -> String {
        guard let raw = info?[name] as? String else { return "" }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("$(") ? "" : trimmed
    }
}

/// Shared transport shape — URLSession in production, fixtures in tests.
typealias TempoTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

// MARK: - GetSongBPM

final class GetSongBPMProvider: TempoProvider, @unchecked Sendable {
    let id = "getsongbpm"

    private static let baseURL = "https://api.getsong.co"

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
        var search = URLComponents(string: "\(Self.baseURL)/search/")!
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

        var detail = URLComponents(string: "\(Self.baseURL)/song/")!
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
    /// The production provider chain. Inactive (keyless) providers drop
    /// out here; the on-device TempoEstimator remains the offline floor.
    nonisolated static func liveProviders() -> [TempoProvider] {
        var providers: [TempoProvider] = []
        if let gsb = GetSongBPMProvider() { providers.append(gsb) }
        return providers
    }
}
