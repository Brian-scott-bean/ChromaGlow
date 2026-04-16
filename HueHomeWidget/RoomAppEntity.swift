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
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Room")
    static var defaultQuery = RoomEntityQuery()

    var id:   String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: name))
    }
}

// MARK: - RoomEntityQuery

struct RoomEntityQuery: EntityQuery {

    /// Called when WidgetKit restores a saved configuration from disk.
    func entities(for identifiers: [String]) async throws -> [RoomAppEntity] {
        WidgetDataStore.shared.rooms
            .filter { identifiers.contains($0.id) }
            .map    { RoomAppEntity(id: $0.id, name: $0.name) }
    }

    /// Populates the room picker list the user sees in the widget editor.
    func suggestedEntities() async throws -> [RoomAppEntity] {
        WidgetDataStore.shared.rooms
            .map { RoomAppEntity(id: $0.id, name: $0.name) }
    }

    /// The room shown before the user has made a selection.
    func defaultResult() async -> RoomAppEntity? {
        WidgetDataStore.shared.rooms.first
            .map { RoomAppEntity(id: $0.id, name: $0.name) }
    }
}
