package com.chromaglow.app.feature.dashboard

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.chromaglow.app.core.model.RoomDisplayModel
import com.chromaglow.app.data.demo.DemoModeSession

/** Test tag for the dashboard "Scenes" navigation [Button]. */
const val DASHBOARD_SCENES_TAG: String = "dashboard_scenes"

/** Test tag for the dashboard "Settings" navigation [Button]. */
const val DASHBOARD_SETTINGS_TAG: String = "dashboard_settings"

/**
 * Demo dashboard. Renders one [DemoRoomRow] per entry in [rooms] and hoists every per-room edit
 * out via [onRoomToggle] / [onRoomBrightnessChange] (each carries the room's `bridgeId` and `id`).
 *
 * Per D-009 the screen is stateless over its room list: the app shell ([ChromaGlowApp]) owns the
 * in-memory demo room state and passes it in through [rooms] so edits survive leaving and reopening
 * the dashboard. [rooms] defaults to the supplied session's rooms purely for backward compatibility
 * with callers that do not hoist state. The existing public params keep their defaults; the
 * [Switch]/[Slider] and the exact status-line text live in [DemoRoomRow] and are unchanged.
 */
@Composable
fun DashboardPlaceholderScreen(
    demoSession: DemoModeSession?,
    onBackToSetup: () -> Unit,
    onOpenRoom: (String) -> Unit = {},
    onOpenScenes: () -> Unit = {},
    onOpenSettings: () -> Unit = {},
    modifier: Modifier = Modifier,
    rooms: List<RoomDisplayModel> = demoSession?.rooms ?: emptyList(),
    onRoomToggle: (String, String, Boolean) -> Unit = { _, _, _ -> },
    onRoomBrightnessChange: (String, String, Int) -> Unit = { _, _, _ -> },
) {
    val session = requireNotNull(demoSession) { "Demo session required" }
    require(session.isDemoMode)

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            text = "ChromaGlow",
            style = MaterialTheme.typography.headlineLarge,
            color = MaterialTheme.colorScheme.onBackground,
        )
        Text(
            text = "Demo Dashboard",
            style = MaterialTheme.typography.titleLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        LazyColumn(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            items(rooms, key = { it.id }) { room ->
                DemoRoomRow(
                    room = room,
                    onToggle = { isOn -> onRoomToggle(room.bridgeId, room.id, isOn) },
                    onBrightnessChange = { brightness ->
                        onRoomBrightnessChange(room.bridgeId, room.id, brightness)
                    },
                    onOpenRoom = { onOpenRoom(room.id) },
                )
            }
        }
        Button(
            onClick = onOpenScenes,
            modifier = Modifier
                .fillMaxWidth()
                .testTag(DASHBOARD_SCENES_TAG),
        ) {
            Text(text = "Scenes")
        }
        Button(
            onClick = onOpenSettings,
            modifier = Modifier
                .fillMaxWidth()
                .testTag(DASHBOARD_SETTINGS_TAG),
        ) {
            Text(text = "Settings")
        }
        OutlinedButton(onClick = onBackToSetup) {
            Text(text = "Back to Setup")
        }
    }
}
