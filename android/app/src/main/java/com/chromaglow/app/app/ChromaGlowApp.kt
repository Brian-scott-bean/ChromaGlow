package com.chromaglow.app.app

import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import com.chromaglow.app.data.demo.DemoFixtures
import com.chromaglow.app.data.demo.DemoModeBoundary
import com.chromaglow.app.data.demo.DemoModeSession
import com.chromaglow.app.feature.dashboard.DashboardPlaceholderScreen
import com.chromaglow.app.feature.roomdetail.RoomDetailScreen
import com.chromaglow.app.feature.scenes.ScenesScreen
import com.chromaglow.app.feature.settings.SettingsScreen
import com.chromaglow.app.feature.setup.SetupPlaceholderScreen

@Composable
fun ChromaGlowApp() {
    var destination by remember { mutableStateOf(ChromaGlowDestination.Setup) }
    var demoSession by remember { mutableStateOf<DemoModeSession?>(null) }
    // The room whose detail screen is open. Set just before routing to RoomDetail.
    var selectedRoomId by remember { mutableStateOf<String?>(null) }

    when (destination) {
        ChromaGlowDestination.Setup -> SetupPlaceholderScreen(
            onEnterDemoMode = {
                demoSession = DemoModeBoundary.enterDemoMode()
                destination = ChromaGlowDestination.Dashboard
            },
        )

        ChromaGlowDestination.Dashboard -> DashboardPlaceholderScreen(
            demoSession = demoSession,
            onBackToSetup = {
                demoSession = null
                destination = ChromaGlowDestination.Setup
            },
            onOpenRoom = { roomId ->
                selectedRoomId = roomId
                destination = ChromaGlowDestination.RoomDetail
            },
            onOpenScenes = { destination = ChromaGlowDestination.Scenes },
            onOpenSettings = { destination = ChromaGlowDestination.Settings },
        )

        ChromaGlowDestination.RoomDetail -> {
            // Reached only from Dashboard, which requires a non-null demo session and a
            // selected room. The app shell is the Wave 2 wiring point, so it (and only it)
            // reads DemoFixtures for the per-room light list.
            val session = requireNotNull(demoSession) { "Demo session required" }
            val room = session.rooms.first { it.id == selectedRoomId }
            RoomDetailScreen(
                room = room,
                lights = DemoFixtures.lightsByRoom[selectedRoomId] ?: emptyList(),
                onBack = { destination = ChromaGlowDestination.Dashboard },
            )
        }

        ChromaGlowDestination.Scenes -> ScenesScreen(
            scenes = DemoFixtures.scenes,
            roomNames = DemoFixtures.rooms.associate { it.id to it.name },
            onBack = { destination = ChromaGlowDestination.Dashboard },
        )

        ChromaGlowDestination.Settings -> SettingsScreen(
            isDemoMode = true,
            appVersion = "1.0",
            onExitDemo = {
                demoSession = null
                destination = ChromaGlowDestination.Setup
            },
            onBack = { destination = ChromaGlowDestination.Dashboard },
        )
    }
}
