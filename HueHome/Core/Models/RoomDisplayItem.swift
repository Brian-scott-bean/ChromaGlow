// RoomDisplayItem.swift
// CastChroma
//
// Value-type display model for a single Hue room or zone.
// Shared by DashboardView (room grid + zone section), RoomDetailView, and
// UnifiedOrchestrator. The Kind field distinguishes rooms from zones;
// all existing call sites that don't specify kind default to .room.

import Foundation

// MARK: - RoomDisplayItem

struct RoomDisplayItem: Identifiable, Hashable {

    // ── What this item represents ────────────────────────────────────────────
    enum Kind: String, Codable {
        case room
        case zone
    }
    /// Defaults to .room so all existing initialisers require no changes.
    var kind: Kind = .room

    let id:             String
    var name:           String
    var archetype:      String?

    // Mutable state — updated optimistically on toggle / brightness change
    var isOn:           Bool
    var brightness:     Double   // 1–100 (Bridge rejects 0; use on=false to turn off)

    let groupedLightID: String?
    var lightCount:     Int

    /// Which bridge owns this room/zone — nil only for legacy paths.
    var bridgeID:       String?

    /// Raw child resource refs — used by RoomDetailViewModel to match individual lights.
    /// Rooms:  rtype "device" (older firmware) or "light" (newer firmware)
    /// Zones:  always rtype "light" (direct light UUID refs)
    let childResourceRefs: [(rid: String, rtype: String)]

    // ── Dominant color (trailing defaults — all existing call sites omit these) ─
    var dominantColorX: Double? = nil
    var dominantColorY: Double? = nil
    var dominantMirek:  Int?    = nil

    // Memberwise Equatable: compares ALL fields so SwiftUI detects changes
    // to isOn, brightness, dominantColorX/Y, etc. ID-only == was preventing
    // onChange handlers in RoomCard from ever firing.
    static func == (lhs: RoomDisplayItem, rhs: RoomDisplayItem) -> Bool {
        lhs.id == rhs.id &&
        lhs.kind == rhs.kind &&
        lhs.name == rhs.name &&
        lhs.archetype == rhs.archetype &&
        lhs.isOn == rhs.isOn &&
        lhs.brightness == rhs.brightness &&
        lhs.groupedLightID == rhs.groupedLightID &&
        lhs.lightCount == rhs.lightCount &&
        lhs.bridgeID == rhs.bridgeID &&
        lhs.dominantColorX == rhs.dominantColorX &&
        lhs.dominantColorY == rhs.dominantColorY &&
        lhs.dominantMirek == rhs.dominantMirek
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(isOn)
        hasher.combine(brightness)
        hasher.combine(dominantColorX)
        hasher.combine(dominantColorY)
        hasher.combine(dominantMirek)
    }
}
