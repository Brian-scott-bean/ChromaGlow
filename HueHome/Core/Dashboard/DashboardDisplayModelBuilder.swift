// DashboardDisplayModelBuilder.swift
// ChromaGlow
//
// Pure display-model composition helpers for dashboard room lists.

import Foundation

enum DashboardDisplayModelBuilder {
    static func makeRooms(
        from roomsByBridge: [String: [RoomDisplayItem]]
    ) -> [RoomDisplayItem] {
        var seen = Set<String>()
        return roomsByBridge.values
            .flatMap { $0 }
            .sorted {
                $0.name.localizedCompare($1.name) == .orderedAscending
            }
            .filter { seen.insert($0.id).inserted }
    }

    static func makeZones(
        from zonesByBridge: [String: [RoomDisplayItem]]
    ) -> [RoomDisplayItem] {
        var seen = Set<String>()
        return zonesByBridge.values
            .flatMap { $0 }
            .sorted {
                $0.name.localizedCompare($1.name) == .orderedAscending
            }
            .filter { seen.insert($0.id).inserted }
    }
}
