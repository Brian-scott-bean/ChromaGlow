// SelectRoomIntent.swift
// HueHome Pro — Epic 5.2 / Customizable Widget
//
// WidgetConfigurationIntent that powers the "Edit Widget" sheet.
// The user picks one room (or leaves it nil = "All Rooms" summary).
// Requires iOS 17+ / WidgetKit's AppIntentConfiguration.

import AppIntents
import WidgetKit

struct SelectRoomIntent: WidgetConfigurationIntent {

    static var title: LocalizedStringResource       = "Select Room"
    static var description = IntentDescription("Choose which room to display in the widget. Leave blank to show all rooms.")

    /// The room to focus on. Nil = show all rooms (summary mode).
    @Parameter(title: "Room", optionsProvider: RoomOptionsProvider())
    var room: RoomAppEntity?

    init() {}
    init(room: RoomAppEntity?) { self.room = room }
}

// MARK: - Options Provider

struct RoomOptionsProvider: DynamicOptionsProvider {
    func results() async throws -> [RoomAppEntity] {
        WidgetDataStore.shared.rooms
            .map { RoomAppEntity(id: $0.id, name: $0.name) }
    }
}
