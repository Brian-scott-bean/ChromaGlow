// AppIntent.swift — LightShadeWatch
// Replaces the template "favorite emoji" intent with a room-selection intent
// matching the iOS widget's SelectRoomIntent pattern.

import WidgetKit
import AppIntents

// MARK: - Watch Room Entity

struct WatchRoomEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Room")
    static var defaultQuery = WatchRoomEntityQuery()

    var id:   String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: name))
    }
}

struct WatchRoomEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [WatchRoomEntity] {
        WatchWidgetStore.shared.rooms
            .filter { identifiers.contains($0.id) }
            .map    { WatchRoomEntity(id: $0.id, name: $0.name) }
    }
    func suggestedEntities() async throws -> [WatchRoomEntity] {
        WatchWidgetStore.shared.rooms.map { WatchRoomEntity(id: $0.id, name: $0.name) }
    }
    func defaultResult() async -> WatchRoomEntity? {
        WatchWidgetStore.shared.rooms.first.map { WatchRoomEntity(id: $0.id, name: $0.name) }
    }
}

// MARK: - Configuration Intent

struct WatchConfigIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource       = "LightShade Watch"
    static var description = IntentDescription("Pin a room or show all lights at a glance.")

    @Parameter(title: "Room", optionsProvider: WatchRoomOptionsProvider())
    var room: WatchRoomEntity?   // nil = all-rooms summary

    init() {}
    init(room: WatchRoomEntity?) { self.room = room }
}

struct WatchRoomOptionsProvider: DynamicOptionsProvider {
    func results() async throws -> [WatchRoomEntity] {
        WatchWidgetStore.shared.rooms.map { WatchRoomEntity(id: $0.id, name: $0.name) }
    }
}
