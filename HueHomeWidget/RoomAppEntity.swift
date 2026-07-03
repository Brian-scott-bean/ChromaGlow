// RoomAppEntity.swift
// HueHome Pro — Epic 5.2 / Customizable Widget
//
// AppEntity that represents a Hue room in WidgetKit's configuration UI.
// WidgetKit calls suggestedEntities() to populate the room picker when
// the user long-presses the widget and taps "Edit Widget".
//
// Data source: WidgetDataStore (App Group UserDefaults) — no network call.

import AppIntents
import WidgetKit

// MARK: - RoomAppEntity

struct RoomAppEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Room or Zone")
    static var defaultQuery = RoomEntityQuery()

    var id:     String
    var name:   String
    var isZone: Bool = false

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: LocalizedStringResource(stringLiteral: name),
            subtitle: isZone ? "Zone" : "Room"
        )
    }

    init(id: String, name: String, isZone: Bool = false) {
        self.id = id
        self.name = name
        self.isZone = isZone
    }

    init(_ snapshot: WidgetRoomSnapshot) {
        self.id = snapshot.id
        self.name = snapshot.name
        self.isZone = snapshot.isZone
    }
}

// MARK: - RoomEntityQuery

struct RoomEntityQuery: EntityQuery {

    /// Called when WidgetKit restores a saved configuration from disk.
    func entities(for identifiers: [String]) async throws -> [RoomAppEntity] {
        WidgetDataStore.shared.groups
            .filter { identifiers.contains($0.id) }
            .map    { RoomAppEntity($0) }
    }

    /// Populates the room/zone picker list the user sees in the widget editor.
    func suggestedEntities() async throws -> [RoomAppEntity] {
        WidgetDataStore.shared.groups.map { RoomAppEntity($0) }
    }

    /// The group shown before the user has made a selection.
    func defaultResult() async -> RoomAppEntity? {
        WidgetDataStore.shared.groups.first.map { RoomAppEntity($0) }
    }
}
