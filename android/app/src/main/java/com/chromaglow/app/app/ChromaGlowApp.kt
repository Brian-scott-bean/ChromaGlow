package com.chromaglow.app.app

import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import com.chromaglow.app.core.model.LightDisplayModel
import com.chromaglow.app.core.model.RoomDisplayModel
import com.chromaglow.app.core.model.SceneDisplayModel
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

    // App-owned, in-memory demo state (D-009). The when-router below removes inactive
    // destinations from composition, so any remember{} state held inside a feature screen is
    // discarded when the user leaves and recreated from immutable DemoFixtures on return. Hoisting
    // the mutable room/light/scene collections into the app shell — the single Wave 2 wiring point
    // that owns DemoFixtures — lets demo edits persist across navigation WITHIN one demo session.
    // In-memory only: no disk persistence, networking, REST, pairing, or credential behavior. These
    // lists are seeded from DemoFixtures on enterDemo() and cleared on exitDemo() (every
    // demoSession = null / return-to-Setup transition, including Settings "Exit Demo Mode").
    val rooms = remember { mutableStateListOf<RoomDisplayModel>() }
    val lights = remember { mutableStateListOf<LightDisplayModel>() }
    val scenes = remember { mutableStateListOf<SceneDisplayModel>() }

    fun enterDemo() {
        rooms.apply { clear(); addAll(DemoFixtures.rooms) }
        lights.apply { clear(); addAll(DemoFixtures.lights) }
        scenes.apply { clear(); addAll(DemoFixtures.scenes) }
        demoSession = DemoModeBoundary.enterDemoMode()
        destination = ChromaGlowDestination.Dashboard
    }

    fun exitDemo() {
        demoSession = null
        selectedRoomId = null
        rooms.clear()
        lights.clear()
        scenes.clear()
        destination = ChromaGlowDestination.Setup
    }

    when (destination) {
        ChromaGlowDestination.Setup -> SetupPlaceholderScreen(
            onEnterDemoMode = { enterDemo() },
        )

        ChromaGlowDestination.Dashboard -> DashboardPlaceholderScreen(
            demoSession = demoSession,
            onBackToSetup = { exitDemo() },
            onOpenRoom = { roomId ->
                selectedRoomId = roomId
                destination = ChromaGlowDestination.RoomDetail
            },
            onOpenScenes = { destination = ChromaGlowDestination.Scenes },
            onOpenSettings = { destination = ChromaGlowDestination.Settings },
            rooms = rooms,
            onRoomToggle = { _, roomId, isOn ->
                val index = rooms.indexOfFirst { it.id == roomId }
                if (index >= 0) {
                    rooms[index] = rooms[index].copy(isOn = isOn)
                }
            },
            onRoomBrightnessChange = { _, roomId, brightness ->
                val index = rooms.indexOfFirst { it.id == roomId }
                if (index >= 0) {
                    rooms[index] = rooms[index].copy(brightness = brightness.coerceIn(1, 100))
                }
            },
        )

        ChromaGlowDestination.RoomDetail -> {
            // Reached only from Dashboard, which requires a non-null demo session and a selected
            // room. The app shell owns the in-memory demo state, so it passes the app-owned room and
            // its per-room light sublist; consuming the (bridgeId, lightId, value) callbacks updates
            // the matching app-owned light so reopening the same room shows the changed light.
            requireNotNull(demoSession) { "Demo session required" }
            val roomId = requireNotNull(selectedRoomId) { "Room selection required" }
            val room = rooms.first { it.id == roomId }
            RoomDetailScreen(
                room = room,
                lights = lights.filter { it.roomId == roomId },
                onLightToggle = { _, lightId, isOn ->
                    val index = lights.indexOfFirst { it.id == lightId }
                    if (index >= 0) {
                        lights[index] = lights[index].copy(isOn = isOn)
                    }
                },
                onLightBrightnessChange = { _, lightId, brightness ->
                    val index = lights.indexOfFirst { it.id == lightId }
                    if (index >= 0) {
                        lights[index] = lights[index].copy(brightness = brightness.coerceIn(1, 100))
                    }
                },
                onBack = { destination = ChromaGlowDestination.Dashboard },
            )
        }

        ChromaGlowDestination.Scenes -> ScenesScreen(
            scenes = scenes,
            roomNames = rooms.associate { it.id to it.name },
            onActivateScene = { _, sceneId ->
                // Exclusive activation on the app-owned scenes so the active scene survives leaving
                // and reopening Scenes: the tapped scene becomes active, every other scene clears.
                for (index in scenes.indices) {
                    val current = scenes[index]
                    scenes[index] = current.copy(isActive = current.id == sceneId)
                }
            },
            onBack = { destination = ChromaGlowDestination.Dashboard },
        )

        ChromaGlowDestination.Settings -> SettingsScreen(
            isDemoMode = true,
            appVersion = "1.0",
            onExitDemo = { exitDemo() },
            onBack = { destination = ChromaGlowDestination.Dashboard },
        )
    }
}
