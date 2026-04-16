// DemoDataProvider.swift
// HueHome Pro — Demo Mode
//
// Realistic mock data for app exploration without a physical Bridge.
// Two bridges (Main Home + Guest Suite), seven rooms total.
// All controls work — state changes are held in memory only.

import Foundation

enum DemoDataProvider {

    // MARK: - Mock Bridge IDs

    static let bridgeMainID  = "demo-bridge-main"
    static let bridgeGuestID = "demo-bridge-guest"

    // MARK: - Mock Rooms

    /// 7 rooms across 2 bridges with varied states and archetypes.
    static var rooms: [RoomDisplayItem] = [

        // ── Bridge 1: Main Home ────────────────────────────────────────
        RoomDisplayItem(
            id: "demo-room-living",
            name: "Living Room",
            archetype: "living_room",
            isOn: true,
            brightness: 78,
            groupedLightID: "demo-gl-living",
            lightCount: 5,
            bridgeID: bridgeMainID,
            childResourceRefs: []
        ),
        RoomDisplayItem(
            id: "demo-room-kitchen",
            name: "Kitchen",
            archetype: "kitchen",
            isOn: true,
            brightness: 100,
            groupedLightID: "demo-gl-kitchen",
            lightCount: 8,
            bridgeID: bridgeMainID,
            childResourceRefs: []
        ),
        RoomDisplayItem(
            id: "demo-room-bedroom",
            name: "Master Bedroom",
            archetype: "bedroom",
            isOn: false,
            brightness: 40,
            groupedLightID: "demo-gl-bedroom",
            lightCount: 4,
            bridgeID: bridgeMainID,
            childResourceRefs: []
        ),
        RoomDisplayItem(
            id: "demo-room-office",
            name: "Office",
            archetype: "office",
            isOn: true,
            brightness: 55,
            groupedLightID: "demo-gl-office",
            lightCount: 2,
            bridgeID: bridgeMainID,
            childResourceRefs: []
        ),
        RoomDisplayItem(
            id: "demo-room-bathroom",
            name: "Bathroom",
            archetype: "bathroom",
            isOn: false,
            brightness: 85,
            groupedLightID: "demo-gl-bathroom",
            lightCount: 3,
            bridgeID: bridgeMainID,
            childResourceRefs: []
        ),

        // ── Bridge 2: Guest Suite ──────────────────────────────────────
        RoomDisplayItem(
            id: "demo-room-guest",
            name: "Guest Bedroom",
            archetype: "bedroom",
            isOn: false,
            brightness: 60,
            groupedLightID: "demo-gl-guest",
            lightCount: 2,
            bridgeID: bridgeGuestID,
            childResourceRefs: []
        ),
        RoomDisplayItem(
            id: "demo-room-patio",
            name: "Patio",
            archetype: "terrace",
            isOn: true,
            brightness: 90,
            groupedLightID: "demo-gl-patio",
            lightCount: 6,
            bridgeID: bridgeGuestID,
            childResourceRefs: []
        ),
    ]

    // MARK: - Mock Bridge Records (for BridgeManagerView display)

    static func bridgeRecords() -> [BridgeRecord] {
        let main = BridgeRecord(
            id: bridgeMainID,
            name: "Main Home",
            host: "192.168.1.100",
            sortOrder: 0
        )
        main.locationLabel  = "Living Area"
        main.accentHex      = "#FFC107"
        main.deviceCount    = 22

        let guest = BridgeRecord(
            id: bridgeGuestID,
            name: "Guest Suite",
            host: "192.168.1.101",
            sortOrder: 1
        )
        guest.locationLabel = "Back House"
        guest.accentHex     = "#64B5F6"
        guest.deviceCount   = 8

        return [main, guest]
    }

    // MARK: - Mock Connection Statuses

    static var connectionStatuses: [String: BridgeConnectionStatus] {
        [
            bridgeMainID:  .connected,
            bridgeGuestID: .connected,
        ]
    }
}
