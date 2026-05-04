// WatchWidgetStore.swift
// LightShadeWatch — Minimal App Group reader for the watch widget extension.
// Mirrors WidgetDataStore but lives in the watch target (separate process).
// Reads room snapshots written by the main iOS app via group.com.huehome.pro.

import Foundation

// Shared room model — must match WidgetRoomSnapshot in WidgetDataStore.swift
struct WatchRoomSnapshot: Codable, Identifiable {
    let id:             String
    let name:           String
    let archetype:      String?
    var isOn:           Bool
    var brightness:     Double
    let lightCount:     Int
    let groupedLightId: String?
}

final class WatchWidgetStore {
    static let shared = WatchWidgetStore()
    private init() {}

    private let suiteName = "group.com.huehome.pro"
    private var ud: UserDefaults? { UserDefaults(suiteName: suiteName) }

    var rooms: [WatchRoomSnapshot] {
        guard let data = ud?.data(forKey: "hue_widget_rooms_v1"),
              let decoded = try? JSONDecoder().decode([WatchRoomSnapshot].self, from: data)
        else { return [] }
        return decoded
    }

    var isPaired:   Bool    { !(ud?.string(forKey: "hue_widget_bridge_ip")?.isEmpty ?? true) }
    var bridgeIP:   String? { ud?.string(forKey: "hue_widget_bridge_ip") }
    var token:      String? { ud?.string(forKey: "hue_widget_token") }
    var lastUpdated: Date?  { ud?.object(forKey: "hue_widget_updated_at") as? Date }

    var onCount: Int { rooms.filter(\.isOn).count }
    var total:   Int { rooms.count }
}
