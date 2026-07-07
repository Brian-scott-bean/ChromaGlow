// SceneProvenanceStore.swift
// CastChroma — Round 4 Scenes block.
//
// Local provenance for bridge scenes the Studio Composer exported
// ("Save as Hue dynamic scene"). The bridge has no app-metadata field we
// rely on, so exported scene ids are remembered locally and surfaced as a
// STUDIO badge on the Scenes tab. Stale keys (bridge re-pair, out-of-band
// deletion) simply never match a live scene — harmless by design, no GC.
//
// Key format is byte-identical to GlobalSceneItem.id: "bridgeID:sceneID".

import Foundation

@MainActor
@Observable
final class SceneProvenanceStore {
    static let shared = SceneProvenanceStore()

    private(set) var studioSceneKeys: Set<String> = []

    private let defaults: UserDefaults
    private static let defaultsKey = "castchroma.studioExportedSceneKeys"

    /// `defaults` is injectable for tests only.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        studioSceneKeys = Set(defaults.stringArray(forKey: Self.defaultsKey) ?? [])
    }

    static func key(bridgeID: String, sceneID: String) -> String {
        "\(bridgeID):\(sceneID)"
    }

    func markStudioExported(bridgeID: String, sceneID: String) {
        studioSceneKeys.insert(Self.key(bridgeID: bridgeID, sceneID: sceneID))
        persist()
    }

    func isStudioScene(key: String) -> Bool {
        studioSceneKeys.contains(key)
    }

    func remove(key: String) {
        guard studioSceneKeys.remove(key) != nil else { return }
        persist()
    }

    private func persist() {
        defaults.set(studioSceneKeys.sorted(), forKey: Self.defaultsKey)
    }
}

// MARK: - FavoriteSceneCSV

/// Pure helpers for the shared "favoriteSceneIDs" @AppStorage CSV.
///
/// CONTRACT (RoomDetailView writes, DashboardView reads): comma-joined RAW
/// bridge scene UUIDs — `GlobalSceneItem.bridgeSceneID`, NEVER the composite
/// "bridgeID:sceneID" id. Order-preserving (Dashboard renders pills in
/// stored order; RoomDetail's legacy Set round-trip destroyed it).
enum FavoriteSceneCSV {
    static func ids(from raw: String) -> [String] {
        raw.split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }

    static func contains(_ raw: String, id: String) -> Bool {
        ids(from: raw).contains(id)
    }

    /// Append if absent, remove in place if present — never reorders others.
    static func toggled(_ raw: String, id: String) -> String {
        var list = ids(from: raw)
        if let idx = list.firstIndex(of: id) {
            list.remove(at: idx)
        } else {
            list.append(id)
        }
        return list.joined(separator: ",")
    }

    static func removing(_ raw: String, id: String) -> String {
        ids(from: raw).filter { $0 != id }.joined(separator: ",")
    }
}
