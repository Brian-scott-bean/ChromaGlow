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
        // Negative cache: tracks a provider definitively had no tempo for.
        // Optional so cache files written before this field decode cleanly.
        var misses: [String: Date]?
    }

    private static let maxCacheEntries = 500
    /// A definitive "no tempo" is retried after a week, not on every track
    /// change forever — a BPM-unknown song used to re-query GetSongBPM each
    /// time it came on (audit R9 follow-up).
    static let missTTL: TimeInterval = 7 * 24 * 3600
    private static let maxMissEntries = 300
    /// HTTP 429 parks the provider for this long (quota resets hourly).
    static let rateLimitCooldown: TimeInterval = 30 * 60

    private let providers: [TempoProvider]
    private let fileURL: URL
    private let defaults: UserDefaults
    private let liveEstimate: @Sendable () -> (bpm: Double, confidence: Double)
    private let now: () -> Date
    private var cache: CacheFile?
    /// In-memory only — a 429 cooldown should not survive relaunch.
    private var providerCooldowns: [String: Date] = [:]

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

    /// Number of negative-cache entries (test hook).
    var cachedMissCount: Int { loadCache().misses?.count ?? 0 }

    /// nil = no tempo known from any source (no hint, no lookup result, and
    /// the on-device estimator hears nothing).
    func resolve(for track: NowPlayingTrack) async -> ResolvedTempo? {
        if let hint = track.tempoHint, Self.bpmRange.contains(hint) {
            return ResolvedTempo(bpm: hint, confidence: 1.0, origin: .hint)
        }

        let query = TempoQuery(track: track)
        if let entry = loadCache().entries[query.cacheKey] {
            // Re-validate on read — a legacy/hand-edited cache file must not
            // serve a BPM that BeatClock will silently reject every drive.
            if Self.bpmRange.contains(entry.bpm) {
                return ResolvedTempo(bpm: entry.bpm, confidence: 1.0, origin: .cached(entry.providerID))
            }
            removeEntry(key: query.cacheKey)
        }

        if lookupEnabled, !missCooldownActive(for: query.cacheKey) {
            var sawDefinitiveMiss = false
            for provider in providers {
                if let until = providerCooldowns[provider.id], now() < until { continue }
                do {
                    if let bpm = try await provider.tempo(for: query) {
                        guard Self.bpmRange.contains(bpm) else {
                            sawDefinitiveMiss = true
                            continue
                        }
                        store(bpm: bpm, providerID: provider.id, key: query.cacheKey)
                        return ResolvedTempo(bpm: bpm, confidence: 1.0, origin: .provider(provider.id))
                    }
                    // Provider reachable, no data — a real negative signal.
                    sawDefinitiveMiss = true
                } catch TempoProviderError.rateLimited {
                    providerCooldowns[provider.id] = now().addingTimeInterval(Self.rateLimitCooldown)
                } catch {
                    // Transport trouble — no negative signal; retry next track.
                }
            }
            if sawDefinitiveMiss { storeMiss(key: query.cacheKey) }
        }

        let live = liveEstimate()
        guard Self.bpmRange.contains(live.bpm) else { return nil }
        return ResolvedTempo(bpm: live.bpm, confidence: live.confidence, origin: .liveEstimate)
    }

    /// True while a fresh negative-cache entry says "don't ask again yet";
    /// expired entries are dropped so the next resolve retries.
    private func missCooldownActive(for key: String) -> Bool {
        guard let missedAt = loadCache().misses?[key] else { return false }
        if now().timeIntervalSince(missedAt) < Self.missTTL { return true }
        var file = loadCache()
        file.misses?.removeValue(forKey: key)
        persist(file)
        return false
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
        file.misses?.removeValue(forKey: key)   // a hit supersedes any old miss
        while file.entries.count > Self.maxCacheEntries {
            guard let oldest = file.entries.min(by: { $0.value.storedAt < $1.value.storedAt }) else { break }
            file.entries.removeValue(forKey: oldest.key)
        }
        persist(file)
    }

    private func storeMiss(key: String) {
        var file = loadCache()
        var misses = file.misses ?? [:]
        misses[key] = now()
        while misses.count > Self.maxMissEntries {
            guard let oldest = misses.min(by: { $0.value < $1.value }) else { break }
            misses.removeValue(forKey: oldest.key)
        }
        file.misses = misses
        persist(file)
    }

    private func removeEntry(key: String) {
        var file = loadCache()
        file.entries.removeValue(forKey: key)
        persist(file)
    }

    private func persist(_ file: CacheFile) {
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
