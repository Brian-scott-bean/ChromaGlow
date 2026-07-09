// SceneAppEntity.swift
// HueHome Pro — Control Center / Lock Screen scene control
//
// AppEntity that represents a saved Hue scene in the control-configuration UI.
// The user picks one when adding the scene control; tapping the control recalls it.
//
// Data source: WidgetDataStore (App Group UserDefaults) — no network call.
// Mirrors RoomAppEntity.swift.

import AppIntents
import WidgetKit

// MARK: - SceneAppEntity

struct SceneAppEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Scene")
    static var defaultQuery = SceneEntityQuery()

    /// The real Hue scene UUID — also the recall target.
    var id: String
    var name: String
    /// Bridge that owns the scene; recall must route to it.
    var bridgeID: String
    /// Room/zone the scene belongs to, so the tap can mark it on optimistically.
    var ownerGroupID: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: LocalizedStringResource(stringLiteral: name),
            subtitle: LocalizedStringResource(stringLiteral: roomName)
        )
    }

    /// Scene names repeat across rooms ("Relax" in three rooms), so the picker
    /// subtitles each with its owning group.
    private var roomName: String {
        WidgetDataStore.shared.groups.first { $0.id == ownerGroupID }?.name ?? "Scene"
    }

    init(id: String, name: String, bridgeID: String, ownerGroupID: String) {
        self.id = id
        self.name = name
        self.bridgeID = bridgeID
        self.ownerGroupID = ownerGroupID
    }

    init(_ snapshot: WidgetSceneSnapshot) {
        self.id = snapshot.id
        self.name = snapshot.name
        self.bridgeID = snapshot.bridgeID
        self.ownerGroupID = snapshot.ownerGroupID
    }
}

// MARK: - SceneEntityQuery

struct SceneEntityQuery: EntityQuery {

    /// Called when the system restores a saved control configuration from disk.
    func entities(for identifiers: [String]) async throws -> [SceneAppEntity] {
        WidgetDataStore.shared.scenes
            .filter { identifiers.contains($0.id) }
            .map    { SceneAppEntity($0) }
    }

    /// Populates the scene picker shown while configuring the control.
    func suggestedEntities() async throws -> [SceneAppEntity] {
        WidgetDataStore.shared.scenes.map { SceneAppEntity($0) }
    }

    /// The scene offered before the user has chosen one.
    func defaultResult() async -> SceneAppEntity? {
        WidgetDataStore.shared.scenes.first.map { SceneAppEntity($0) }
    }
}
