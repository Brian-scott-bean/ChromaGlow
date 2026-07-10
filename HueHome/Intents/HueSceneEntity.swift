// HueSceneEntity.swift
// ChromaGlow — Siri Shortcuts
//
// App-target AppEntity for a Hue scene — a deliberate twin of the widget's
// SceneAppEntity (same twin pattern as HueGroupEntity/RoomAppEntity: the
// widget file lives in the synchronized HueHomeWidget/ folder, so dual-
// targeting it would need pbxproj exception-set surgery). Scene names
// repeat across rooms ("Relax" in three rooms) — the owning group's name
// is the subtitle Siri disambiguates with.

import AppIntents

// MARK: - HueSceneEntity

struct HueSceneEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Scene")
    static var defaultQuery = HueSceneEntityQuery()

    /// The real Hue scene UUID — also the recall target.
    var id: String
    var name: String
    /// Bridge that owns the scene; recall must route to it.
    var bridgeID: String
    /// Room/zone the scene belongs to (drives the disambiguation subtitle).
    var ownerGroupID: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: LocalizedStringResource(stringLiteral: name),
            subtitle: LocalizedStringResource(stringLiteral: ownerGroupName)
        )
    }

    private var ownerGroupName: String {
        WidgetDataStore.shared.groups.first { $0.id == ownerGroupID }?.name ?? "Scene"
    }

    init(snapshot: WidgetSceneSnapshot) {
        self.id           = snapshot.id
        self.name         = snapshot.name
        self.bridgeID     = snapshot.bridgeID
        self.ownerGroupID = snapshot.ownerGroupID
    }
}

// MARK: - HueSceneEntityQuery

struct HueSceneEntityQuery: EntityStringQuery {

    func entities(for identifiers: [String]) async throws -> [HueSceneEntity] {
        WidgetDataStore.shared.scenes
            .filter { identifiers.contains($0.id) }
            .map(HueSceneEntity.init(snapshot:))
    }

    func entities(matching string: String) async throws -> [HueSceneEntity] {
        WidgetDataStore.shared.scenes
            .filter { HueGroupEntityQuery.matches(name: $0.name, query: string) }
            .map(HueSceneEntity.init(snapshot:))
    }

    func suggestedEntities() async throws -> [HueSceneEntity] {
        WidgetDataStore.shared.scenes.map(HueSceneEntity.init(snapshot:))
    }

    func defaultResult() async -> HueSceneEntity? {
        WidgetDataStore.shared.scenes.first.map(HueSceneEntity.init(snapshot:))
    }
}
