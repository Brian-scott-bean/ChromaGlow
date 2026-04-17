// RoomDisplayItem.swift
// HueHome Pro
//
// Value-type display model for a single Hue room/zone.
// Created when DashboardViewModel.swift was removed and the type was extracted
// so it can be imported by UnifiedOrchestrator, DashboardView, and RoomDetailViewModel.

import Foundation

// MARK: - RoomDisplayItem

struct RoomDisplayItem: Identifiable, Hashable {
    let id:             String
    let name:           String
    let archetype:      String?

    // Mutable state — updated optimistically on toggle / brightness change
    var isOn:           Bool
    var brightness:     Double   // 1–100 (Bridge rejects 0; use on=false to turn off)

    let groupedLightID: String?
    var lightCount:     Int

    /// Which bridge owns this room — nil only for legacy paths. Set by UnifiedOrchestrator.
    var bridgeID:       String?

    /// Raw child resource refs — used by RoomDetailViewModel to match individual lights.
    /// Contains entries with rtype \"light\" (newer firmware) or \"device\" (older firmware).
    let childResourceRefs: [(rid: String, rtype: String)]

    static func == (lhs: RoomDisplayItem, rhs: RoomDisplayItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
