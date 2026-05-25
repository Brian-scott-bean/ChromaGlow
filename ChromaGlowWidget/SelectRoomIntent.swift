// SelectRoomIntent.swift
// ChromaGlow — Epic 5.2 / Customizable Widget
//
// WidgetConfigurationIntent that powers the "Edit Widget" sheet.
// The user picks one room (or leaves it nil = "All Rooms" summary).
// Requires iOS 17+ / WidgetKit's AppIntentConfiguration.

import AppIntents
import WidgetKit

struct SelectRoomIntent: WidgetConfigurationIntent {

    static var title: LocalizedStringResource       = "ChromaGlow Widget"
    static var description = IntentDescription("Choose which room to display, and whether to show quick preset buttons.")

    /// The room to focus on. Nil = show all rooms (summary mode).
    @Parameter(title: "Room", optionsProvider: RoomOptionsProvider())
    var room: RoomAppEntity?

    /// When true the medium/large widget shows Energize · Read · Relax · Sleep preset chips.
    @Parameter(title: "Show Preset Shortcuts", default: true)
    var showPresets: Bool

    init() { showPresets = true }
    init(room: RoomAppEntity?, showPresets: Bool = true) {
        self.room        = room
        self.showPresets = showPresets
    }
}

// MARK: - Options Provider

struct RoomOptionsProvider: DynamicOptionsProvider {
    func results() async throws -> [RoomAppEntity] {
        WidgetDataStore.shared.rooms
            .map { RoomAppEntity(id: $0.id, name: $0.name) }
    }
}
