// SceneUsageStore.swift
// ChromaGlow — Scenes overhaul Phase 2
//
// Local activation history per bridge scene: how often and how recently a
// scene was recalled. Feeds the Scenes tab's "Recently Used" / "Most Used"
// sorts (and, later, the vacation presence-mimic replay — roadmap R3.2).
//
// Keys are RAW bridge scene UUIDs (bridgeSceneID) — the same identity the
// favorites CSV uses, so a scene keeps its history across the composite
// "bridgeID:sceneID" surfaces. Stale entries from deleted scenes never
// match a live scene and age out via the entry cap — harmless by design.

import Foundation

@MainActor
@Observable
final class SceneUsageStore {
    static let shared = SceneUsageStore()

    struct Usage: Codable, Equatable {
        var count: Int
        var lastUsedAt: Date
    }

    private(set) var usageBySceneID: [String: Usage] = [:]

    private let defaults: UserDefaults
    private static let defaultsKey = "castchroma.sceneUsage"
    /// Cap keeps the blob tiny even after years of use; when exceeded, the
    /// least-recently-used entries are dropped.
    private static let maxEntries = 500

    /// `defaults` is injectable for tests only.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: Usage].self, from: data) {
            usageBySceneID = decoded
        }
    }

    /// Record one activation of a scene (by raw bridge scene UUID).
    func recordActivation(bridgeSceneID: String, at date: Date = Date()) {
        var usage = usageBySceneID[bridgeSceneID] ?? Usage(count: 0, lastUsedAt: date)
        usage.count += 1
        usage.lastUsedAt = date
        usageBySceneID[bridgeSceneID] = usage
        pruneIfNeeded()
        persist()
    }

    func lastUsed(bridgeSceneID: String) -> Date? {
        usageBySceneID[bridgeSceneID]?.lastUsedAt
    }

    func useCount(bridgeSceneID: String) -> Int {
        usageBySceneID[bridgeSceneID]?.count ?? 0
    }

    /// Carry usage history across a scene-id change (a move mints a new
    /// bridge scene UUID). On collision keep the larger count and the most
    /// recent date. No-op when `from` has no entry.
    func transfer(from oldID: String, to newID: String) {
        guard oldID != newID,
              let moved = usageBySceneID.removeValue(forKey: oldID) else { return }
        if let existing = usageBySceneID[newID] {
            usageBySceneID[newID] = Usage(
                count: max(existing.count, moved.count),
                lastUsedAt: max(existing.lastUsedAt, moved.lastUsedAt)
            )
        } else {
            usageBySceneID[newID] = moved
        }
        persist()
    }

    /// Drop a deleted scene's history immediately (delete-alert hygiene —
    /// stale entries would age out via the cap anyway, but there's no reason
    /// to keep them once the scene is knowingly gone).
    func remove(bridgeSceneID: String) {
        guard usageBySceneID.removeValue(forKey: bridgeSceneID) != nil else { return }
        persist()
    }

    private func pruneIfNeeded() {
        guard usageBySceneID.count > Self.maxEntries else { return }
        let keep = usageBySceneID
            .sorted { $0.value.lastUsedAt > $1.value.lastUsedAt }
            .prefix(Self.maxEntries)
        usageBySceneID = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(usageBySceneID) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
