package com.chromaglow.app.data.demo

import com.chromaglow.app.core.model.RoomDisplayModel

data class DemoModeSession(
    val isDemoMode: Boolean,
    val rooms: List<RoomDisplayModel>,
)

object DemoModeBoundary {
    fun enterDemoMode(): DemoModeSession =
        DemoModeSession(
            isDemoMode = true,
            rooms = DemoFixtures.rooms,
        )
}
