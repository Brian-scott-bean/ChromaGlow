package com.chromaglow.app.data.demo

import com.chromaglow.app.core.model.LightDisplayModel
import com.chromaglow.app.core.model.RoomDisplayModel
import com.chromaglow.app.core.model.SceneDisplayModel

object DemoFixtures {
    const val DEMO_BRIDGE_ID = "demo-bridge-main"

    val rooms: List<RoomDisplayModel> = listOf(
        RoomDisplayModel(
            id = "demo-room-bedroom",
            name = "Master Bedroom",
            isOn = false,
            brightness = 40,
            lightCount = 4,
            bridgeId = DEMO_BRIDGE_ID,
        ),
        RoomDisplayModel(
            id = "demo-room-kitchen",
            name = "Kitchen",
            isOn = true,
            brightness = 100,
            lightCount = 8,
            bridgeId = DEMO_BRIDGE_ID,
        ),
        RoomDisplayModel(
            id = "demo-room-living",
            name = "Living Room",
            isOn = true,
            brightness = 78,
            lightCount = 5,
            bridgeId = DEMO_BRIDGE_ID,
        ),
        RoomDisplayModel(
            id = "demo-room-office",
            name = "Office",
            isOn = true,
            brightness = 55,
            lightCount = 2,
            bridgeId = DEMO_BRIDGE_ID,
        ),
    ).sortedBy(RoomDisplayModel::name)

    // --- Lane android1-domain-models additions (additive only) ---
    // Per-room demo lights. Keyed/derived from the existing room ids above.
    // Note: brightness must stay in 1..100 even when isOn is false (it is the
    // last/stored level), matching LightDisplayModel's require(...) guards.

    val lights: List<LightDisplayModel> = listOf(
        // Master Bedroom (room is off)
        LightDisplayModel(
            id = "demo-light-bedroom-1",
            name = "Bedside Lamp",
            isOn = false,
            brightness = 40,
            roomId = "demo-room-bedroom",
            bridgeId = DEMO_BRIDGE_ID,
        ),
        LightDisplayModel(
            id = "demo-light-bedroom-2",
            name = "Bedroom Ceiling",
            isOn = false,
            brightness = 35,
            roomId = "demo-room-bedroom",
            bridgeId = DEMO_BRIDGE_ID,
        ),
        LightDisplayModel(
            id = "demo-light-bedroom-3",
            name = "Reading Light",
            isOn = false,
            brightness = 30,
            roomId = "demo-room-bedroom",
            bridgeId = DEMO_BRIDGE_ID,
        ),
        LightDisplayModel(
            id = "demo-light-bedroom-4",
            name = "Wardrobe Spot",
            isOn = false,
            brightness = 25,
            roomId = "demo-room-bedroom",
            bridgeId = DEMO_BRIDGE_ID,
        ),
        // Kitchen
        LightDisplayModel(
            id = "demo-light-kitchen-1",
            name = "Counter Spots",
            isOn = true,
            brightness = 100,
            roomId = "demo-room-kitchen",
            bridgeId = DEMO_BRIDGE_ID,
        ),
        LightDisplayModel(
            id = "demo-light-kitchen-2",
            name = "Island Pendants",
            isOn = true,
            brightness = 90,
            roomId = "demo-room-kitchen",
            bridgeId = DEMO_BRIDGE_ID,
        ),
        LightDisplayModel(
            id = "demo-light-kitchen-3",
            name = "Under Cabinet",
            isOn = true,
            brightness = 80,
            roomId = "demo-room-kitchen",
            bridgeId = DEMO_BRIDGE_ID,
        ),
        LightDisplayModel(
            id = "demo-light-kitchen-4",
            name = "Sink Light",
            isOn = true,
            brightness = 85,
            roomId = "demo-room-kitchen",
            bridgeId = DEMO_BRIDGE_ID,
        ),
        LightDisplayModel(
            id = "demo-light-kitchen-5",
            name = "Pantry Light",
            isOn = true,
            brightness = 70,
            roomId = "demo-room-kitchen",
            bridgeId = DEMO_BRIDGE_ID,
        ),
        LightDisplayModel(
            id = "demo-light-kitchen-6",
            name = "Breakfast Nook",
            isOn = true,
            brightness = 75,
            roomId = "demo-room-kitchen",
            bridgeId = DEMO_BRIDGE_ID,
        ),
        LightDisplayModel(
            id = "demo-light-kitchen-7",
            name = "Toe Kick",
            isOn = true,
            brightness = 60,
            roomId = "demo-room-kitchen",
            bridgeId = DEMO_BRIDGE_ID,
        ),
        LightDisplayModel(
            id = "demo-light-kitchen-8",
            name = "Ceiling Downlight",
            isOn = true,
            brightness = 95,
            roomId = "demo-room-kitchen",
            bridgeId = DEMO_BRIDGE_ID,
        ),
        // Living Room
        LightDisplayModel(
            id = "demo-light-living-1",
            name = "Sofa Lamp",
            isOn = true,
            brightness = 78,
            roomId = "demo-room-living",
            bridgeId = DEMO_BRIDGE_ID,
        ),
        LightDisplayModel(
            id = "demo-light-living-2",
            name = "TV Backlight",
            isOn = true,
            brightness = 60,
            roomId = "demo-room-living",
            bridgeId = DEMO_BRIDGE_ID,
        ),
        LightDisplayModel(
            id = "demo-light-living-3",
            name = "Floor Lamp",
            isOn = true,
            brightness = 70,
            roomId = "demo-room-living",
            bridgeId = DEMO_BRIDGE_ID,
        ),
        LightDisplayModel(
            id = "demo-light-living-4",
            name = "Accent Strip",
            isOn = true,
            brightness = 50,
            roomId = "demo-room-living",
            bridgeId = DEMO_BRIDGE_ID,
        ),
        LightDisplayModel(
            id = "demo-light-living-5",
            name = "Reading Nook",
            isOn = true,
            brightness = 65,
            roomId = "demo-room-living",
            bridgeId = DEMO_BRIDGE_ID,
        ),
        // Office
        LightDisplayModel(
            id = "demo-light-office-1",
            name = "Desk Lamp",
            isOn = true,
            brightness = 55,
            roomId = "demo-room-office",
            bridgeId = DEMO_BRIDGE_ID,
        ),
        LightDisplayModel(
            id = "demo-light-office-2",
            name = "Shelf Strip",
            isOn = true,
            brightness = 45,
            roomId = "demo-room-office",
            bridgeId = DEMO_BRIDGE_ID,
        ),
    )

    // Lights grouped by their owning room id, preserving declaration order.
    val lightsByRoom: Map<String, List<LightDisplayModel>> =
        lights.groupBy(LightDisplayModel::roomId)

    // Demo scenes (at least 3). Each references an existing demo room id and carries
    // explicit bridge-routing identity via bridgeId (= DEMO_BRIDGE_ID for the demo bridge).
    val scenes: List<SceneDisplayModel> = listOf(
        SceneDisplayModel(
            id = "demo-scene-relax",
            name = "Relax",
            roomId = "demo-room-living",
            brightness = 30,
            bridgeId = DEMO_BRIDGE_ID,
            isActive = true,
        ),
        SceneDisplayModel(
            id = "demo-scene-energize",
            name = "Energize",
            roomId = "demo-room-kitchen",
            brightness = 100,
            bridgeId = DEMO_BRIDGE_ID,
        ),
        SceneDisplayModel(
            id = "demo-scene-focus",
            name = "Focus",
            roomId = "demo-room-office",
            brightness = 80,
            bridgeId = DEMO_BRIDGE_ID,
        ),
        SceneDisplayModel(
            id = "demo-scene-nightlight",
            name = "Nightlight",
            roomId = "demo-room-bedroom",
            brightness = 10,
            bridgeId = DEMO_BRIDGE_ID,
        ),
    )
}
