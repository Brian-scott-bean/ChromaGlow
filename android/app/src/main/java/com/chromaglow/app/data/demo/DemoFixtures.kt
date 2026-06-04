package com.chromaglow.app.data.demo

import com.chromaglow.app.core.model.RoomDisplayModel

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
}
