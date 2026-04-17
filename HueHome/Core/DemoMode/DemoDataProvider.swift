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

    // MARK: - Mock Lights (per room)

    static func lights(for roomID: String) -> [LightDisplayItem] {
        switch roomID {
        case "demo-room-living":
            return [
                LightDisplayItem(id: "dl-lv-1", name: "Floor Lamp",    archetype: "floor_lantern",    isOn: true,  brightness: 78,  colorX: 0.45, colorY: 0.41, colorTempMirek: 370, mirekMin: 153, mirekMax: 500),
                LightDisplayItem(id: "dl-lv-2", name: "Sofa Lamp",     archetype: "table_shade",      isOn: true,  brightness: 55,  colorX: 0.48, colorY: 0.40, colorTempMirek: 400, mirekMin: 153, mirekMax: 500),
                LightDisplayItem(id: "dl-lv-3", name: "TV Backlight",  archetype: "hue_lightstrip",   isOn: true,  brightness: 90,  colorX: 0.16, colorY: 0.10, colorTempMirek: nil, mirekMin: 153, mirekMax: 500),
                LightDisplayItem(id: "dl-lv-4", name: "Ceiling 1",     archetype: "sultan_bulb",      isOn: false, brightness: 100, colorX: nil,  colorY: nil,  colorTempMirek: 300, mirekMin: 153, mirekMax: 500),
                LightDisplayItem(id: "dl-lv-5", name: "Ceiling 2",     archetype: "sultan_bulb",      isOn: false, brightness: 100, colorX: nil,  colorY: nil,  colorTempMirek: 300, mirekMin: 153, mirekMax: 500),
            ]
        case "demo-room-kitchen":
            return [
                LightDisplayItem(id: "dl-kt-1", name: "Counter Strip", archetype: "hue_lightstrip",   isOn: true,  brightness: 100, colorX: nil,  colorY: nil,  colorTempMirek: 233, mirekMin: 153, mirekMax: 500),
                LightDisplayItem(id: "dl-kt-2", name: "Island Light",  archetype: "pendant_round",    isOn: true,  brightness: 100, colorX: nil,  colorY: nil,  colorTempMirek: 200, mirekMin: 153, mirekMax: 500),
                LightDisplayItem(id: "dl-kt-3", name: "Spot 1",        archetype: "sultan_bulb",      isOn: true,  brightness: 90,  colorX: nil,  colorY: nil,  colorTempMirek: 220, mirekMin: 153, mirekMax: 500),
                LightDisplayItem(id: "dl-kt-4", name: "Spot 2",        archetype: "sultan_bulb",      isOn: true,  brightness: 90,  colorX: nil,  colorY: nil,  colorTempMirek: 220, mirekMin: 153, mirekMax: 500),
            ]
        case "demo-room-bedroom":
            return [
                LightDisplayItem(id: "dl-bd-1", name: "Bedside Left",  archetype: "table_shade",      isOn: false, brightness: 30,  colorX: 0.55, colorY: 0.40, colorTempMirek: 450, mirekMin: 153, mirekMax: 500),
                LightDisplayItem(id: "dl-bd-2", name: "Bedside Right", archetype: "table_shade",      isOn: false, brightness: 30,  colorX: 0.55, colorY: 0.40, colorTempMirek: 450, mirekMin: 153, mirekMax: 500),
                LightDisplayItem(id: "dl-bd-3", name: "Overhead",      archetype: "sultan_bulb",      isOn: false, brightness: 80,  colorX: nil,  colorY: nil,  colorTempMirek: 300, mirekMin: 153, mirekMax: 500),
                LightDisplayItem(id: "dl-bd-4", name: "Closet",        archetype: "single_bulb",      isOn: false, brightness: 100, colorX: nil,  colorY: nil,  colorTempMirek: nil, mirekMin: 153, mirekMax: 500),
            ]
        case "demo-room-office":
            return [
                LightDisplayItem(id: "dl-of-1", name: "Desk Lamp",     archetype: "table_shade",      isOn: true,  brightness: 55,  colorX: nil,  colorY: nil,  colorTempMirek: 200, mirekMin: 153, mirekMax: 500),
                LightDisplayItem(id: "dl-of-2", name: "Monitor Light", archetype: "hue_lightstrip",   isOn: true,  brightness: 40,  colorX: nil,  colorY: nil,  colorTempMirek: 167, mirekMin: 153, mirekMax: 500),
            ]
        case "demo-room-patio":
            return [
                LightDisplayItem(id: "dl-pt-1", name: "String Lights", archetype: "hue_lightstrip",   isOn: true,  brightness: 90,  colorX: 0.48, colorY: 0.41, colorTempMirek: nil, mirekMin: 153, mirekMax: 500),
                LightDisplayItem(id: "dl-pt-2", name: "Post Light 1",  archetype: "floor_lantern",    isOn: true,  brightness: 85,  colorX: nil,  colorY: nil,  colorTempMirek: 370, mirekMin: 153, mirekMax: 500),
                LightDisplayItem(id: "dl-pt-3", name: "Post Light 2",  archetype: "floor_lantern",    isOn: true,  brightness: 85,  colorX: nil,  colorY: nil,  colorTempMirek: 370, mirekMin: 153, mirekMax: 500),
            ]
        default:
            return [
                LightDisplayItem(id: "dl-gen-1", name: "Main Light",   archetype: "sultan_bulb",      isOn: false, brightness: 100, colorX: nil,  colorY: nil,  colorTempMirek: 300, mirekMin: 153, mirekMax: 500),
            ]
        }
    }

    // MARK: - Mock Scenes (per room)

    static func scenes(for roomID: String) -> [SceneDisplayItem] {
        switch roomID {
        case "demo-room-living":
            return [
                SceneDisplayItem(id: "ds-lv-1", name: "Relax",      isActive: false),
                SceneDisplayItem(id: "ds-lv-2", name: "Energize",   isActive: false),
                SceneDisplayItem(id: "ds-lv-3", name: "Movie Night",isActive: true),
                SceneDisplayItem(id: "ds-lv-4", name: "Sunset",     isActive: false),
            ]
        case "demo-room-kitchen":
            return [
                SceneDisplayItem(id: "ds-kt-1", name: "Bright",     isActive: true),
                SceneDisplayItem(id: "ds-kt-2", name: "Cooking",    isActive: false),
                SceneDisplayItem(id: "ds-kt-3", name: "Dimmed",     isActive: false),
            ]
        case "demo-room-bedroom":
            return [
                SceneDisplayItem(id: "ds-bd-1", name: "Sleep",      isActive: false),
                SceneDisplayItem(id: "ds-bd-2", name: "Wake Up",    isActive: false),
                SceneDisplayItem(id: "ds-bd-3", name: "Read",       isActive: false),
            ]
        case "demo-room-office":
            return [
                SceneDisplayItem(id: "ds-of-1", name: "Focus",      isActive: true),
                SceneDisplayItem(id: "ds-of-2", name: "Relax",      isActive: false),
            ]
        default:
            return [
                SceneDisplayItem(id: "ds-gen-1", name: "Default",   isActive: false),
            ]
        }
    }

    // MARK: - Mock Connection Statuses

    static var connectionStatuses: [String: BridgeConnectionStatus] {
        [
            bridgeMainID:  .connected,
            bridgeGuestID: .connected,
        ]
    }

    // MARK: - Global Scenes (for ScenesTabView)
    //
    // Mirrors the per-room scene data as GlobalSceneItems so the Scenes tab
    // works in demo mode. Room IDs match DemoDataProvider.rooms.

    static var globalScenes: [GlobalSceneItem] {
        let b = bridgeMainID
        let g = bridgeGuestID
        return [
            // Living Room
            GlobalSceneItem(id: "\(b):ds-lv-1", bridgeSceneID: "ds-lv-1", name: "Relax",       roomID: "demo-room-living",   bridgeID: b, isActive: false),
            GlobalSceneItem(id: "\(b):ds-lv-2", bridgeSceneID: "ds-lv-2", name: "Energize",    roomID: "demo-room-living",   bridgeID: b, isActive: false),
            GlobalSceneItem(id: "\(b):ds-lv-3", bridgeSceneID: "ds-lv-3", name: "Movie Night", roomID: "demo-room-living",   bridgeID: b, isActive: true),
            GlobalSceneItem(id: "\(b):ds-lv-4", bridgeSceneID: "ds-lv-4", name: "Sunset",      roomID: "demo-room-living",   bridgeID: b, isActive: false),
            GlobalSceneItem(id: "\(b):ds-lv-5", bridgeSceneID: "ds-lv-5", name: "Romance",     roomID: "demo-room-living",   bridgeID: b, isActive: false),
            // Kitchen
            GlobalSceneItem(id: "\(b):ds-kt-1", bridgeSceneID: "ds-kt-1", name: "Bright",      roomID: "demo-room-kitchen",  bridgeID: b, isActive: true),
            GlobalSceneItem(id: "\(b):ds-kt-2", bridgeSceneID: "ds-kt-2", name: "Cooking",     roomID: "demo-room-kitchen",  bridgeID: b, isActive: false),
            GlobalSceneItem(id: "\(b):ds-kt-3", bridgeSceneID: "ds-kt-3", name: "Dimmed",      roomID: "demo-room-kitchen",  bridgeID: b, isActive: false),
            // Bedroom
            GlobalSceneItem(id: "\(b):ds-bd-1", bridgeSceneID: "ds-bd-1", name: "Sleep",       roomID: "demo-room-bedroom",  bridgeID: b, isActive: false),
            GlobalSceneItem(id: "\(b):ds-bd-2", bridgeSceneID: "ds-bd-2", name: "Wake Up",     roomID: "demo-room-bedroom",  bridgeID: b, isActive: false),
            GlobalSceneItem(id: "\(b):ds-bd-3", bridgeSceneID: "ds-bd-3", name: "Read",        roomID: "demo-room-bedroom",  bridgeID: b, isActive: false),
            GlobalSceneItem(id: "\(b):ds-bd-4", bridgeSceneID: "ds-bd-4", name: "Night Light", roomID: "demo-room-bedroom",  bridgeID: b, isActive: false),
            // Office
            GlobalSceneItem(id: "\(b):ds-of-1", bridgeSceneID: "ds-of-1", name: "Focus",       roomID: "demo-room-office",   bridgeID: b, isActive: true),
            GlobalSceneItem(id: "\(b):ds-of-2", bridgeSceneID: "ds-of-2", name: "Relax",       roomID: "demo-room-office",   bridgeID: b, isActive: false),
            // Patio (Guest Bridge)
            GlobalSceneItem(id: "\(g):ds-pt-1", bridgeSceneID: "ds-pt-1", name: "Warm Glow",   roomID: "demo-room-patio",    bridgeID: g, isActive: true),
            GlobalSceneItem(id: "\(g):ds-pt-2", bridgeSceneID: "ds-pt-2", name: "Party",       roomID: "demo-room-patio",    bridgeID: g, isActive: false),
            GlobalSceneItem(id: "\(g):ds-pt-3", bridgeSceneID: "ds-pt-3", name: "Galaxy",      roomID: "demo-room-patio",    bridgeID: g, isActive: false),
        ].sorted {
            if $0.isActive != $1.isActive { return $0.isActive }
            return $0.name.localizedCompare($1.name) == .orderedAscending
        }
    }
}
