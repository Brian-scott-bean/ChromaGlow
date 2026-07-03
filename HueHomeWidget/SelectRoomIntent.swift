// SelectRoomIntent.swift
// HueHome Pro — Epic 5.2 / Customizable Widget
//
// WidgetConfigurationIntent that powers the "Edit Widget" sheet.
// The user picks one room (or leaves it nil = "All Rooms" summary).
// Requires iOS 17+ / WidgetKit's AppIntentConfiguration.

import AppIntents
import WidgetKit

struct SelectRoomIntent: WidgetConfigurationIntent {

    static var title: LocalizedStringResource       = "CastChroma Widget"
    static var description = IntentDescription("Choose which room or zone to display, and whether to show quick preset and scene buttons.")

    /// The room or zone to focus on. Nil = show all groups (summary mode).
    @Parameter(title: "Room or Zone", optionsProvider: RoomOptionsProvider())
    var room: RoomAppEntity?

    /// When true the medium/large widget shows Energize · Read · Relax · Sleep preset chips.
    @Parameter(title: "Show Preset Shortcuts", default: true)
    var showPresets: Bool

    /// When true the medium/large widget shows the pinned group's scene chips.
    @Parameter(title: "Show Scene Shortcuts", default: true)
    var showScenes: Bool

    init() { showPresets = true; showScenes = true }
    init(room: RoomAppEntity?, showPresets: Bool = true, showScenes: Bool = true) {
        self.room        = room
        self.showPresets = showPresets
        self.showScenes  = showScenes
    }
}

// MARK: - Options Provider

struct RoomOptionsProvider: DynamicOptionsProvider {
    func results() async throws -> [RoomAppEntity] {
        WidgetDataStore.shared.groups.map { RoomAppEntity($0) }
    }
}
