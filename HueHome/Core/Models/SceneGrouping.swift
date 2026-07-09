// SceneGrouping.swift
// ChromaGlow — Scenes overhaul Phase 1
//
// Pure sectioning/sorting logic for the Scenes tab. No SwiftUI, no
// orchestrator — everything takes plain values so it's fully unit-testable.
//
// Also owns the room/zone name index. The old ScenesTabView lookup searched
// allRooms only, so scenes attached to ZONES displayed as "Other" — the
// index here must always be built from rooms + zones.

import Foundation
import CoreTransferable
import UniformTypeIdentifiers

// MARK: - SceneDragPayload

/// What a dragged scene card carries: the composite GlobalSceneItem id
/// ("bridgeID:sceneID"). Dropping on a room section/chip re-resolves it
/// against orchestrator.globalScenes and opens CopySceneSheet pre-targeted
/// — never a blind copy.
struct SceneDragPayload: Codable, Transferable {
    let sceneID: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .sceneRef)
    }
}

extension UTType {
    /// Exported custom type for scene drags (declared in Info.plist).
    static let sceneRef = UTType(exportedAs: "com.lightshade.scene-ref")
}

enum SceneGrouping {

    // ── Sort modes ────────────────────────────────────────

    /// How the Scenes tab orders its content. Raw values are persisted in
    /// @AppStorage — do not rename cases.
    enum SortMode: String, CaseIterable, Identifiable {
        case byRoom       = "byRoom"        // grouped sections (default)
        case alphabetical = "alphabetical"  // flat A–Z
        case recent       = "recent"        // flat, last-activated first
        case mostUsed     = "mostUsed"      // flat, activation count desc
        var id: String { rawValue }

        var label: String {
            switch self {
            case .byRoom:       return "Group by Room"
            case .alphabetical: return "All Scenes A–Z"
            case .recent:       return "Recently Used"
            case .mostUsed:     return "Most Used"
            }
        }

        var icon: String {
            switch self {
            case .byRoom:       return "square.grid.2x2"
            case .alphabetical: return "textformat.abc"
            case .recent:       return "clock"
            case .mostUsed:     return "flame"
            }
        }

        /// Grouped mode renders room sections; flat modes render one grid
        /// (and bring the room filter chips back).
        var isGrouped: Bool { self == .byRoom }
    }

    // ── Room index (rooms + zones) ────────────────────────

    struct RoomInfo: Equatable {
        let name: String
        let archetype: String?
    }

    /// Build the scene-group lookup from BOTH rooms and zones — a scene's
    /// `roomID` is its owning group rid, which can be either rtype.
    static func roomIndex(groups: [RoomDisplayItem]) -> [String: RoomInfo] {
        var index: [String: RoomInfo] = [:]
        for g in groups {
            index[g.id] = RoomInfo(name: g.name, archetype: g.archetype)
        }
        return index
    }

    static func roomName(for scene: GlobalSceneItem, index: [String: RoomInfo]) -> String {
        index[scene.roomID]?.name ?? "Other"
    }

    static func roomArchetype(for scene: GlobalSceneItem, index: [String: RoomInfo]) -> String? {
        index[scene.roomID]?.archetype
    }

    // ── Sections (grouped mode) ───────────────────────────

    /// Section id for scenes whose owning group no longer resolves
    /// (deleted room, bridge briefly missing).
    static let otherSectionID = "scenegrouping.other"

    struct SceneSection: Identifiable, Equatable {
        let id: String              // group rid, or `otherSectionID`
        let title: String
        let archetype: String?
        var scenes: [GlobalSceneItem]
        var activeCount: Int { scenes.filter { $0.isActive }.count }
    }

    /// One section per room/zone that has scenes, alphabetical by group
    /// name; scene order inside a section is preserved from the input
    /// (the orchestrator already sorts active-first then A–Z). Orphaned
    /// scenes merge into a trailing "Other" section.
    static func sections(
        scenes: [GlobalSceneItem],
        index: [String: RoomInfo]
    ) -> [SceneSection] {
        var known: [String: [GlobalSceneItem]] = [:]
        var orphans: [GlobalSceneItem] = []
        for scene in scenes {
            if index[scene.roomID] != nil {
                known[scene.roomID, default: []].append(scene)
            } else {
                orphans.append(scene)
            }
        }
        var result: [SceneSection] = known.map { roomID, roomScenes in
            let info = index[roomID]!
            return SceneSection(
                id: roomID,
                title: info.name,
                archetype: info.archetype,
                scenes: roomScenes
            )
        }
        .sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        if !orphans.isEmpty {
            result.append(SceneSection(
                id: otherSectionID, title: "Other", archetype: nil, scenes: orphans
            ))
        }
        return result
    }

    // ── Favorites shelf ───────────────────────────────────

    /// Favorites in the CSV's stored order (the order the user starred them).
    /// The CSV holds RAW bridge scene UUIDs — the shared contract with
    /// RoomDetail and the Dashboard pills.
    static func favorites(
        scenes: [GlobalSceneItem],
        favoriteIDsCSV: String
    ) -> [GlobalSceneItem] {
        FavoriteSceneCSV.ids(from: favoriteIDsCSV).compactMap { fid in
            scenes.first { $0.bridgeSceneID == fid }
        }
    }

    // ── Flat sorts ────────────────────────────────────────

    /// Order scenes for a flat (non-grouped) mode. `lastUsed`/`useCount`
    /// come from SceneUsageStore; unknown scenes sort by name so the list
    /// stays stable before any usage exists.
    static func flatSorted(
        scenes: [GlobalSceneItem],
        mode: SortMode,
        lastUsed: (GlobalSceneItem) -> Date? = { _ in nil },
        useCount: (GlobalSceneItem) -> Int = { _ in 0 }
    ) -> [GlobalSceneItem] {
        switch mode {
        case .byRoom, .alphabetical:
            return scenes.sorted {
                $0.name.localizedCompare($1.name) == .orderedAscending
            }
        case .recent:
            return scenes.sorted {
                let a = lastUsed($0), b = lastUsed($1)
                switch (a, b) {
                case let (x?, y?) where x != y: return x > y
                case (_?, nil): return true
                case (nil, _?): return false
                default:
                    return $0.name.localizedCompare($1.name) == .orderedAscending
                }
            }
        case .mostUsed:
            return scenes.sorted {
                let a = useCount($0), b = useCount($1)
                if a != b { return a > b }
                return $0.name.localizedCompare($1.name) == .orderedAscending
            }
        }
    }
}
