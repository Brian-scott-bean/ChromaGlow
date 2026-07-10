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
    let bridgeID:       String? = nil

    // bridgeID is deliberately excluded from decoding: it stays nil on the
    // watch even though the phone's WidgetRoomSnapshot writer encodes it —
    // no watch reader exists. (Making it `var` per the compiler fix-it would
    // silently start decoding real bridge IDs.)
    private enum CodingKeys: String, CodingKey {
        case id, name, archetype, isOn, brightness, lightCount, groupedLightId
    }
}

/// Shared scene model — field-compatible with WidgetSceneSnapshot (phone) and
/// WatchScene (watch app), which both serialize to hue_widget_scenes_v1.
/// The watch app mirrors the phone's WCSession scene push into the watch-side
/// App Group under the same key, so the complication reads it locally.
struct WatchSceneSnapshot: Codable, Identifiable {
    let id:           String  // real Hue scene UUID
    let name:         String
    let ownerGroupID: String  // matches WatchRoomSnapshot.id of the owning room/zone
    let bridgeID:     String
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

    var zones: [WatchRoomSnapshot] {
        guard let data = ud?.data(forKey: "hue_widget_zones_v1"),
              let decoded = try? JSONDecoder().decode([WatchRoomSnapshot].self, from: data)
        else { return [] }
        return decoded
    }

    /// Rooms followed by zones — for the pin-a-group picker and lookups.
    var groups: [WatchRoomSnapshot] { rooms + zones }

    var scenes: [WatchSceneSnapshot] {
        guard let data = ud?.data(forKey: "hue_widget_scenes_v1"),
              let decoded = try? JSONDecoder().decode([WatchSceneSnapshot].self, from: data)
        else { return [] }
        return decoded
    }

    /// Scenes belonging to a specific room/zone.
    func scenes(forGroup groupID: String) -> [WatchSceneSnapshot] {
        scenes.filter { $0.ownerGroupID == groupID }
    }

    // The complication is display-only: it never talks to the bridge, so it
    // holds no credentials (M-02/D-018 removed the App Group token mirror).
    var isPaired:   Bool {
        !rooms.isEmpty || !(ud?.string(forKey: "hue_widget_bridge_ip")?.isEmpty ?? true)
    }
    var bridgeIP:   String? { ud?.string(forKey: "hue_widget_bridge_ip") }
    var lastUpdated: Date?  { ud?.object(forKey: "hue_widget_updated_at") as? Date }

    var onCount: Int { rooms.filter(\.isOn).count }
    var total:   Int { rooms.count }
}
