// StudioLookLibraryStore.swift
// CastChroma — Slice 2 look-browser Favorites + Recents (spec §16).
//
// Local-first, following the Scenes tab's precedent (favoriteSceneIDs CSV +
// SceneUsageStore): favorites are a CSV of card ids, recents an ordered CSV
// capped at eight. Card ids are catalog identifiers (no commas), and the
// browser filters both lists against the LIVE catalog at render time, so a
// stale id from an older build simply does not render — dropped safely,
// never crashed on (audit §25).

import Foundation
import Observation

@MainActor
@Observable
final class StudioLookLibraryStore {

    static let shared = StudioLookLibraryStore()

    private static let favoritesKey = "studio.favoriteLookIDs.v1"
    private static let recentsKey = "studio.recentLookIDs.v1"
    private static let recentsCap = 8

    private let defaults: UserDefaults

    private(set) var favoriteLookIDs: [String]
    private(set) var recentLookIDs: [String]

    /// Injectable defaults so tests never touch the real store.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        favoriteLookIDs = Self.load(defaults, key: Self.favoritesKey)
        recentLookIDs = Self.load(defaults, key: Self.recentsKey)
    }

    private static func load(_ defaults: UserDefaults, key: String) -> [String] {
        guard let csv = defaults.string(forKey: key), !csv.isEmpty else { return [] }
        var seen = Set<String>()
        return csv.split(separator: ",").map(String.init).filter { seen.insert($0).inserted }
    }

    private func save(_ ids: [String], key: String) {
        defaults.set(ids.joined(separator: ","), forKey: key)
    }

    // ── Favorites ───────────────────────────────────────────────

    func isFavorite(_ lookID: String) -> Bool {
        favoriteLookIDs.contains(lookID)
    }

    func toggleFavorite(_ lookID: String) {
        if let idx = favoriteLookIDs.firstIndex(of: lookID) {
            favoriteLookIDs.remove(at: idx)
        } else {
            favoriteLookIDs.append(lookID)
        }
        save(favoriteLookIDs, key: Self.favoritesKey)
    }

    // ── Recents ─────────────────────────────────────────────────

    /// A look was applied — it moves to the front, deduplicated, capped.
    func noteApplied(_ lookID: String) {
        var ids = recentLookIDs.filter { $0 != lookID }
        ids.insert(lookID, at: 0)
        if ids.count > Self.recentsCap { ids = Array(ids.prefix(Self.recentsCap)) }
        recentLookIDs = ids
        save(ids, key: Self.recentsKey)
    }
}
