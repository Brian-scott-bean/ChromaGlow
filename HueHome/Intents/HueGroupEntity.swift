// HueGroupEntity.swift
// ChromaGlow — Siri Shortcuts
//
// AppEntity representing a Hue room OR zone ("group" in CLIP v2 terms).
// Data source: WidgetDataStore (App Group snapshot) — no network call, no
// configured orchestrator needed, so it resolves in a background intent
// launch. The Room/Zone subtitle is Siri's disambiguator when a room and a
// zone share a name.

import AppIntents

// MARK: - HueGroupEntity

struct HueGroupEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { TypeDisplayRepresentation(name: "Room or Zone") }
    static var defaultQuery: HueGroupEntityQuery { HueGroupEntityQuery() }

    var id:             String
    var name:           String
    var isZone:         Bool
    var groupedLightId: String?
    var bridgeID:       String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: isZone ? "Zone" : "Room"
        )
    }

    init(snapshot: WidgetRoomSnapshot) {
        self.id             = snapshot.id
        self.name           = snapshot.name
        self.isZone         = snapshot.isZone
        self.groupedLightId = snapshot.groupedLightId
        self.bridgeID       = snapshot.bridgeID
    }
}

// MARK: - HueGroupEntityQuery

struct HueGroupEntityQuery: EntityStringQuery {

    func entities(for identifiers: [String]) async throws -> [HueGroupEntity] {
        WidgetDataStore.shared.groups
            .filter { identifiers.contains($0.id) }
            .map(HueGroupEntity.init(snapshot:))
    }

    func entities(matching string: String) async throws -> [HueGroupEntity] {
        WidgetDataStore.shared.groups
            .filter { Self.matches(name: $0.name, query: string) }
            .map(HueGroupEntity.init(snapshot:))
    }

    func suggestedEntities() async throws -> [HueGroupEntity] {
        WidgetDataStore.shared.groups.map(HueGroupEntity.init(snapshot:))
    }

    /// Deliberately NO default. The system fills an unspoken parameter from
    /// this: returning the first room meant "Make my lights red" coloured
    /// whichever room sorted first instead of Siri asking, and the preset
    /// intent's OPTIONAL scope (nil = whole home) could arrive as that room.
    func defaultResult() async -> HueGroupEntity? { nil }

    /// Spoken-name matching: exact beats everything, then containment —
    /// both case- and diacritic-insensitive ("cafe" finds "Café"). Pure.
    static func matches(name: String, query: String) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if name.compare(query, options: options) == .orderedSame { return true }
        return name.range(of: query, options: options) != nil
    }
}
