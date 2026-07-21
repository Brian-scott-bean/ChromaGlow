// TrackTempoResolver.swift
// ChromaGlow — Core/Music (music integration R1)
//
// Resolves a track's BPM: source hint → persistent cache → lookup
// providers (TIDAL/GetSongBPM land in R3) → the live on-device estimate.
// Provider lookups send ONLY a track identifier (ISRC / catalog ID /
// title+artist) — never anything about the user — and are gated by the
// user-facing tempo-lookup toggle. A song's tempo doesn't change, so
// provider results cache forever (bounded, oldest-out).

import Foundation

// MARK: - Query + result types

struct TempoQuery: Equatable, Sendable {
    var isrc: String?
    var appleMusicID: String?
    var title: String
    var artist: String

    init(track: NowPlayingTrack) {
        isrc = track.isrc
        appleMusicID = track.appleMusicID
        title = track.title
        artist = track.artist
    }

    /// Stable cache key from the strongest identifier available.
    var cacheKey: String {
        if let isrc, !isrc.isEmpty { return "isrc:\(isrc)" }
        if let appleMusicID, !appleMusicID.isEmpty { return "am:\(appleMusicID)" }
        return "meta:\(artist.lowercased())|\(title.lowercased())"
    }
}

protocol TempoProvider: Sendable {
    var id: String { get }
    /// nil = provider reachable but has no tempo for this track.
    /// Throwing (network trouble) falls through to the next provider.
    func tempo(for query: TempoQuery) async throws -> Double?
}

struct ResolvedTempo: Equatable, Sendable {
    enum Origin: Equatable, Sendable {
        case hint
        case provider(String)
        case cached(String)
        case liveEstimate
    }
    var bpm: Double
    var confidence: Double
    var origin: Origin
}

// MARK: - TrackTempoResolver

@MainActor
final class TrackTempoResolver {

    /// UserDefaults key for the user-facing lookup toggle (Settings, R2).
    /// Absent = enabled.
    static let lookupEnabledKey = "music.tempoLookupEnabled"

    /// Sane musical range — anything outside is garbage data, not a tempo.
    static let bpmRange = 20.0...300.0

    private struct CacheEntry: Codable, Equatable {
        var bpm: Double
        var providerID: String
        var storedAt: Date
    }
    private struct CacheFile: Codable {
        var entries: [String: CacheEntry] = [:]
    }

    private static let maxCacheEntries = 500

    private let providers: [TempoProvider]
    private let fileURL: URL
    private let defaults: UserDefaults
    private let liveEstimate: @Sendable () -> (bpm: Double, confidence: Double)
    private let now: () -> Date
    private var cache: CacheFile?

    nonisolated static var defaultCacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tempo-cache.json")
    }

    init(
        providers: [TempoProvider] = [],
        fileURL: URL = TrackTempoResolver.defaultCacheURL,
        defaults: UserDefaults = .standard,
        liveEstimate: @escaping @Sendable () -> (bpm: Double, confidence: Double) = {
            let f = AudioAnalysisEngine.latestFeatures()
            return (f.bpm, f.bpmConfidence)
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.providers = providers
        self.fileURL = fileURL
        self.defaults = defaults
        self.liveEstimate = liveEstimate
        self.now = now
    }

    var lookupEnabled: Bool {
        defaults.object(forKey: Self.lookupEnabledKey) as? Bool ?? true
    }

    /// Number of cached provider results (test hook).
    var cachedTempoCount: Int { loadCache().entries.count }

    /// nil = no tempo known from any source (no hint, no lookup result, and
    /// the on-device estimator hears nothing).
    func resolve(for track: NowPlayingTrack) async -> ResolvedTempo? {
        if let hint = track.tempoHint, Self.bpmRange.contains(hint) {
            return ResolvedTempo(bpm: hint, confidence: 1.0, origin: .hint)
        }

        let query = TempoQuery(track: track)
        if let entry = loadCache().entries[query.cacheKey] {
            return ResolvedTempo(bpm: entry.bpm, confidence: 1.0, origin: .cached(entry.providerID))
        }

        if lookupEnabled {
            for provider in providers {
                guard let bpm = try? await provider.tempo(for: query),
                      Self.bpmRange.contains(bpm) else { continue }
                store(bpm: bpm, providerID: provider.id, key: query.cacheKey)
                return ResolvedTempo(bpm: bpm, confidence: 1.0, origin: .provider(provider.id))
            }
        }

        let live = liveEstimate()
        guard live.bpm > 0 else { return nil }
        return ResolvedTempo(bpm: live.bpm, confidence: live.confidence, origin: .liveEstimate)
    }

    // MARK: - Persistence (CompositionStore idiom: tolerant decode, .atomic)

    private func loadCache() -> CacheFile {
        if let cache { return cache }
        let loaded: CacheFile
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(CacheFile.self, from: data) {
            loaded = decoded
        } else {
            loaded = CacheFile()   // missing or corrupt → start clean, never throw
        }
        cache = loaded
        return loaded
    }

    private func store(bpm: Double, providerID: String, key: String) {
        var file = loadCache()
        file.entries[key] = CacheEntry(bpm: bpm, providerID: providerID, storedAt: now())
        while file.entries.count > Self.maxCacheEntries {
            guard let oldest = file.entries.min(by: { $0.value.storedAt < $1.value.storedAt }) else { break }
            file.entries.removeValue(forKey: oldest.key)
        }
        cache = file
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // .atomic ONLY — never pair with .withoutOverwriting (M-13 crash class).
        try? data.write(to: fileURL, options: [.atomic])
    }
}
