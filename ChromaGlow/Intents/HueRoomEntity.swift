// HueRoomEntity.swift
// ChromaGlow — Siri Shortcuts
//
// AppEntity representing a Hue room.
// Data source: WidgetDataStore (App Group) — no network call, no main app needed.
// Used by ToggleRoomIntent and SetBrightnessIntent parameter resolution.

import AppIntents

// MARK: - HueRoomEntity

struct HueRoomEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Room")
    static var defaultQuery = HueRoomEntityQuery()

    var id:             String
    var name:           String
    var groupedLightId: String?
    var bridgeID:       String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: name))
    }
}

// MARK: - HueRoomEntityQuery

struct HueRoomEntityQuery: EntityQuery {

    func entities(for identifiers: [String]) async throws -> [HueRoomEntity] {
        WidgetDataStore.shared.rooms
            .filter { identifiers.contains($0.id) }
            .map {
                HueRoomEntity(
                    id: $0.id,
                    name: $0.name,
                    groupedLightId: $0.groupedLightId,
                    bridgeID: $0.bridgeID
                )
            }
    }

    func suggestedEntities() async throws -> [HueRoomEntity] {
        WidgetDataStore.shared.rooms
            .map {
                HueRoomEntity(
                    id: $0.id,
                    name: $0.name,
                    groupedLightId: $0.groupedLightId,
                    bridgeID: $0.bridgeID
                )
            }
    }

    func defaultResult() async -> HueRoomEntity? {
        WidgetDataStore.shared.rooms.first
            .map {
                HueRoomEntity(
                    id: $0.id,
                    name: $0.name,
                    groupedLightId: $0.groupedLightId,
                    bridgeID: $0.bridgeID
                )
            }
    }
}
