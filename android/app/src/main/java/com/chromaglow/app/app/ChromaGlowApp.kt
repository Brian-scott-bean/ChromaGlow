package com.chromaglow.app.app

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.chromaglow.app.core.identity.ResourceKey
import com.chromaglow.app.core.model.LightDisplayModel
import com.chromaglow.app.core.model.RoomDisplayModel
import com.chromaglow.app.core.model.SceneDisplayModel
import com.chromaglow.app.core.session.HomeCommands
import com.chromaglow.app.core.session.LiveHome
import com.chromaglow.app.data.demo.DemoFixtures
import com.chromaglow.app.feature.dashboard.DashboardPlaceholderScreen
import com.chromaglow.app.feature.home.HomeRoute
import com.chromaglow.app.feature.home.HomeViewModel
import com.chromaglow.app.feature.lightdetail.LightDetailRoute
import com.chromaglow.app.feature.lightdetail.LightDetailViewModel
import com.chromaglow.app.feature.roomdetail.GroupDetailRoute
import com.chromaglow.app.feature.roomdetail.GroupDetailViewModel
import com.chromaglow.app.feature.roomdetail.RoomDetailScreen
import com.chromaglow.app.feature.scenes.LiveScenesRoute
import com.chromaglow.app.feature.scenes.LiveScenesViewModel
import com.chromaglow.app.feature.scenes.ScenesScreen
import com.chromaglow.app.feature.settings.LiveSettingsRoute
import com.chromaglow.app.feature.settings.LiveSettingsViewModel
import com.chromaglow.app.feature.settings.SettingsScreen
import com.chromaglow.app.feature.setup.SetupPlaceholderScreen

private const val APP_VERSION_NAME = "1.0"

/** Destinations that only make sense while an [AppSession.Live] exists. */
private val LIVE_DESTINATIONS = setOf(
    ChromaGlowDestination.Home,
    ChromaGlowDestination.GroupDetail,
    ChromaGlowDestination.LightDetail,
)

/**
 * App shell router (P7). Owns exactly one thing: the current destination. Session ownership lives
 * in [AppShellController] (via the Activity-scoped [AppShellViewModel]); feature screens receive a
 * [LiveHome] + [HomeCommands] through their ViewModels and never see transport or credentials.
 *
 * Routing rules:
 *  - Cold start paints nothing until the shell has classified persisted state, then lands on Home
 *    (healthy paired home) or Setup (unpaired / needs repair / unreadable metadata).
 *  - Setup → Home whenever pairing reaches Paired (fresh pair or restore); no Setup flash.
 *  - Local Forget (Settings or Setup) and "exit to setup" tear the live home down; the router
 *    follows the session back to Setup.
 *  - Demo and Live are exclusive: Scenes/Settings render their live or demo variant by session.
 */
@Composable
fun ChromaGlowApp() {
    val context = LocalContext.current.applicationContext
    val shellViewModel: AppShellViewModel = viewModel(factory = AppShellViewModel.factory(context))
    val controller = shellViewModel.controller
    val session by controller.session.collectAsState()
    val startup by controller.startup.collectAsState()

    var destination by remember { mutableStateOf(ChromaGlowDestination.Booting) }
    var selectedGroupKey by remember { mutableStateOf<ResourceKey?>(null) }
    var selectedLightKey by remember { mutableStateOf<ResourceKey?>(null) }
    // The demo room whose detail screen is open. Set just before routing to RoomDetail.
    var selectedRoomId by remember { mutableStateOf<String?>(null) }

    // App-owned, in-memory demo state (D-009): seeded from immutable DemoFixtures on enterDemo(),
    // cleared on exitDemo(). In-memory only: no persistence, networking, pairing, or credentials.
    val rooms = remember { mutableStateListOf<RoomDisplayModel>() }
    val lights = remember { mutableStateListOf<LightDisplayModel>() }
    val scenes = remember { mutableStateListOf<SceneDisplayModel>() }

    // Foreground/background fan-out to the live home (refresh-then-reconnect / stream cancel).
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner, controller) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_START -> controller.onForeground()
                Lifecycle.Event.ON_STOP -> controller.onBackground()
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    // Cold-start landing: leave Booting exactly once, where the shell's classification says.
    LaunchedEffect(startup) {
        if (destination == ChromaGlowDestination.Booting) {
            destination = when (startup) {
                AppShellController.Startup.Pending -> ChromaGlowDestination.Booting
                AppShellController.Startup.Live -> ChromaGlowDestination.Home
                AppShellController.Startup.Setup -> ChromaGlowDestination.Setup
            }
        }
    }

    // A live destination with no live session (Forget, exit-to-setup) returns to Setup, and a
    // live session appearing while on Setup (fresh pair / restore) lands on Home.
    val live = session as? AppSession.Live
    LaunchedEffect(live, destination) {
        if (live != null && destination == ChromaGlowDestination.Setup) {
            destination = ChromaGlowDestination.Home
        }
        if (live == null && destination in LIVE_DESTINATIONS) {
            selectedGroupKey = null
            selectedLightKey = null
            destination = ChromaGlowDestination.Setup
        }
        if (live == null && session !is AppSession.Demo &&
            (destination == ChromaGlowDestination.Scenes || destination == ChromaGlowDestination.Settings)
        ) {
            destination = ChromaGlowDestination.Setup
        }
    }

    fun enterDemo() {
        rooms.apply { clear(); addAll(DemoFixtures.rooms) }
        lights.apply { clear(); addAll(DemoFixtures.lights) }
        scenes.apply { clear(); addAll(DemoFixtures.scenes) }
        controller.enterDemo()
        destination = ChromaGlowDestination.Dashboard
    }

    fun exitDemo() {
        controller.exitDemo()
        selectedRoomId = null
        rooms.clear()
        lights.clear()
        scenes.clear()
        destination = ChromaGlowDestination.Setup
    }

    val homeRoot = if (live != null) ChromaGlowDestination.Home else ChromaGlowDestination.Dashboard
    BackHandler(
        enabled = destination in setOf(
            ChromaGlowDestination.GroupDetail,
            ChromaGlowDestination.LightDetail,
            ChromaGlowDestination.RoomDetail,
            ChromaGlowDestination.Scenes,
            ChromaGlowDestination.Settings,
        ),
    ) {
        destination = when (destination) {
            ChromaGlowDestination.LightDetail -> ChromaGlowDestination.GroupDetail
            else -> homeRoot
        }
    }

    when (destination) {
        ChromaGlowDestination.Booting -> Box(Modifier.fillMaxSize())

        ChromaGlowDestination.Setup -> SetupPlaceholderScreen(
            onEnterDemoMode = { enterDemo() },
            onPaired = { controller.enterLiveFromSetup() },
        )

        ChromaGlowDestination.Home -> LiveOnly(live, controller.commands) { home, commands ->
            HomeRoute(
                viewModel = liveViewModel(home, "home") { HomeViewModel(home, commands) },
                onOpenGroup = { key, _ ->
                    selectedGroupKey = key
                    destination = ChromaGlowDestination.GroupDetail
                },
                onOpenScenes = { destination = ChromaGlowDestination.Scenes },
                onOpenSettings = { destination = ChromaGlowDestination.Settings },
            )
        }

        ChromaGlowDestination.GroupDetail -> LiveOnly(live, controller.commands) { home, commands ->
            val groupKey = selectedGroupKey
            if (groupKey == null) {
                LaunchedEffect(Unit) { destination = ChromaGlowDestination.Home }
            } else {
                GroupDetailRoute(
                    viewModel = liveViewModel(home, "group:${groupKey.composeKey}") {
                        GroupDetailViewModel(home, commands, groupKey)
                    },
                    onBack = { destination = ChromaGlowDestination.Home },
                    onOpenLight = { key ->
                        selectedLightKey = key
                        destination = ChromaGlowDestination.LightDetail
                    },
                )
            }
        }

        ChromaGlowDestination.LightDetail -> LiveOnly(live, controller.commands) { home, commands ->
            val lightKey = selectedLightKey
            if (lightKey == null) {
                LaunchedEffect(Unit) { destination = ChromaGlowDestination.GroupDetail }
            } else {
                LightDetailRoute(
                    viewModel = liveViewModel(home, "light:${lightKey.composeKey}") {
                        LightDetailViewModel(home, commands, lightKey)
                    },
                    onBack = { destination = ChromaGlowDestination.GroupDetail },
                )
            }
        }

        ChromaGlowDestination.Dashboard -> DashboardPlaceholderScreen(
            demoSession = (session as? AppSession.Demo)?.session,
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
                if (index >= 0) rooms[index] = rooms[index].copy(isOn = isOn)
            },
            onRoomBrightnessChange = { _, roomId, brightness ->
                val index = rooms.indexOfFirst { it.id == roomId }
                if (index >= 0) rooms[index] = rooms[index].copy(brightness = brightness.coerceIn(1, 100))
            },
        )

        ChromaGlowDestination.RoomDetail -> {
            // Demo only: reached from Dashboard with a selected room. The shell owns the in-memory
            // demo state, so edits here persist across navigation within one demo session.
            requireNotNull(session as? AppSession.Demo) { "Demo session required" }
            val roomId = requireNotNull(selectedRoomId) { "Room selection required" }
            val room = rooms.first { it.id == roomId }
            RoomDetailScreen(
                room = room,
                lights = lights.filter { it.roomId == roomId },
                onLightToggle = { _, lightId, isOn ->
                    val index = lights.indexOfFirst { it.id == lightId }
                    if (index >= 0) lights[index] = lights[index].copy(isOn = isOn)
                },
                onLightBrightnessChange = { _, lightId, brightness ->
                    val index = lights.indexOfFirst { it.id == lightId }
                    if (index >= 0) lights[index] = lights[index].copy(brightness = brightness.coerceIn(1, 100))
                },
                onBack = { destination = ChromaGlowDestination.Dashboard },
            )
        }

        ChromaGlowDestination.Scenes -> if (live != null) {
            LiveOnly(live, controller.commands) { home, commands ->
                LiveScenesRoute(
                    viewModel = liveViewModel(home, "scenes") { LiveScenesViewModel(home, commands) },
                    onBack = { destination = ChromaGlowDestination.Home },
                )
            }
        } else {
            ScenesScreen(
                scenes = scenes,
                roomNames = rooms.associate { it.id to it.name },
                onActivateScene = { _, sceneId ->
                    // Demo: exclusive activation on the app-owned scenes.
                    for (index in scenes.indices) {
                        val current = scenes[index]
                        scenes[index] = current.copy(isActive = current.id == sceneId)
                    }
                },
                onBack = { destination = ChromaGlowDestination.Dashboard },
            )
        }

        ChromaGlowDestination.Settings -> if (live != null) {
            LiveSettingsRoute(
                viewModel = liveViewModel(live.home, "settings") {
                    LiveSettingsViewModel(live.home, controller, APP_VERSION_NAME)
                },
                onBack = { destination = ChromaGlowDestination.Home },
            )
        } else {
            SettingsScreen(
                isDemoMode = true,
                appVersion = APP_VERSION_NAME,
                onExitDemo = { exitDemo() },
                onBack = { destination = ChromaGlowDestination.Dashboard },
            )
        }
    }
}

/** Renders [content] only while a live session and its commands exist; otherwise paints nothing
 *  (the router's session effect is already redirecting to Setup). */
@Composable
private fun LiveOnly(
    live: AppSession.Live?,
    commands: HomeCommands?,
    content: @Composable (LiveHome, HomeCommands) -> Unit,
) {
    if (live != null && commands != null) content(live.home, commands) else Box(Modifier.fillMaxSize())
}

/**
 * A feature ViewModel keyed to the current live home instance, so a fresh live session after a
 * Forget/re-pair never reuses a ViewModel bound to a closed home.
 */
@Composable
private inline fun <reified VM : androidx.lifecycle.ViewModel> liveViewModel(
    home: LiveHome,
    key: String,
    crossinline create: () -> VM,
): VM = viewModel(
    key = "$key@${System.identityHashCode(home)}",
    factory = viewModelFactory { initializer { create() } },
)
