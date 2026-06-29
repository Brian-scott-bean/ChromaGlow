package com.chromaglow.app.feature.dashboard

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.chromaglow.app.core.model.RoomDisplayModel
import kotlin.math.roundToInt

/** Test tag for the per-room on/off [Switch]. */
const val DEMO_ROOM_SWITCH_TAG: String = "demo_room_switch"

/** Test tag for the per-room brightness [Slider]. */
const val DEMO_ROOM_BRIGHTNESS_SLIDER_TAG: String = "demo_room_brightness_slider"

/** Prefix for the per-room "open room detail" affordance test tag. */
const val DEMO_ROOM_OPEN_TAG_PREFIX: String = "demo_room_open_"

/** Stable test tag for the open-room affordance of the room with [roomId]. */
fun demoRoomOpenTag(roomId: String): String = DEMO_ROOM_OPEN_TAG_PREFIX + roomId

/**
 * Stateless room row. Hoists on/off and brightness control out via [onToggle] and
 * [onBrightnessChange]. Both callbacks default to no-ops so existing call sites that only
 * pass [room] keep compiling.
 *
 * The room name [Text] and the status-line [Text] (formatted exactly as
 * "<On|Off> · <brightness>% · <lightCount> lights") are preserved unchanged for backward
 * compatibility with existing connected tests; the [Switch] and [Slider] are additive UI.
 *
 * The room-name [Text] is a DISCRETE tap target (its own [Modifier.testTag] via
 * [demoRoomOpenTag]) that hoists "open room detail" out via [onOpenRoom] (default no-op). The
 * row itself is intentionally NOT clickable so the [Switch]/[Slider] keep their own hit targets.
 */
@Composable
fun DemoRoomRow(
    room: RoomDisplayModel,
    modifier: Modifier = Modifier,
    onToggle: (Boolean) -> Unit = {},
    onBrightnessChange: (Int) -> Unit = {},
    onOpenRoom: () -> Unit = {},
) {
    val statusLine = buildString {
        append(if (room.isOn) "On" else "Off")
        append(" · ")
        append(room.brightness)
        append("% · ")
        append(room.lightCount)
        append(" lights")
    }

    Surface(
        modifier = modifier
            .fillMaxWidth()
            .alpha(if (room.isOn) 1f else 0.72f),
        shape = RoundedCornerShape(16.dp),
        color = MaterialTheme.colorScheme.surface,
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = room.name,
                        style = MaterialTheme.typography.titleMedium,
                        color = MaterialTheme.colorScheme.onSurface,
                        modifier = Modifier
                            .testTag(demoRoomOpenTag(room.id))
                            .clickable(onClick = onOpenRoom),
                    )
                    Text(
                        text = statusLine,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Switch(
                    checked = room.isOn,
                    onCheckedChange = onToggle,
                    modifier = Modifier.testTag(DEMO_ROOM_SWITCH_TAG),
                )
            }
            Slider(
                value = room.brightness.toFloat(),
                onValueChange = { value ->
                    onBrightnessChange(value.roundToInt().coerceIn(1, 100))
                },
                valueRange = 1f..100f,
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag(DEMO_ROOM_BRIGHTNESS_SLIDER_TAG),
            )
        }
    }
}
