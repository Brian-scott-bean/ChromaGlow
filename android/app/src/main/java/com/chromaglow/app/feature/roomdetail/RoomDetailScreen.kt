package com.chromaglow.app.feature.roomdetail

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.chromaglow.app.core.model.LightDisplayModel
import com.chromaglow.app.core.model.RoomDisplayModel
import kotlin.math.roundToInt

/** Test tag for the back affordance in the room header. */
const val ROOM_DETAIL_BACK_TAG: String = "room_detail_back"

/** Test tag applied to each per-light row container (one per light). */
const val ROOM_DETAIL_LIGHT_ROW_TAG: String = "room_detail_light_row"

/** Per-light on/off [Switch] tag, unique per light id for robust targeting. */
fun roomDetailLightSwitchTag(lightId: String): String = "room_detail_light_switch_$lightId"

/** Per-light brightness [Slider] tag, unique per light id for robust targeting. */
fun roomDetailLightSliderTag(lightId: String): String = "room_detail_light_slider_$lightId"

/**
 * Stateless per-light row: name + status line, an on/off [Switch], and a brightness [Slider].
 * Hoists interaction out via [onToggle] / [onBrightnessChange]; both default to no-ops.
 *
 * The status line is formatted exactly as "<On|Off> · <brightness>%". The slider is clamped to
 * 1..100 (LightDisplayModel requires brightness in 1..100; 0 would crash).
 */
@Composable
fun RoomDetailLightRow(
    light: LightDisplayModel,
    modifier: Modifier = Modifier,
    onToggle: (Boolean) -> Unit = {},
    onBrightnessChange: (Int) -> Unit = {},
) {
    val statusLine = buildString {
        append(if (light.isOn) "On" else "Off")
        append(" · ")
        append(light.brightness)
        append("%")
    }

    Surface(
        modifier = modifier
            .fillMaxWidth()
            .alpha(if (light.isOn) 1f else 0.72f)
            .testTag(ROOM_DETAIL_LIGHT_ROW_TAG),
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
                        text = light.name,
                        style = MaterialTheme.typography.titleMedium,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                    Text(
                        text = statusLine,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Switch(
                    checked = light.isOn,
                    onCheckedChange = onToggle,
                    modifier = Modifier.testTag(roomDetailLightSwitchTag(light.id)),
                )
            }
            Slider(
                value = light.brightness.toFloat(),
                onValueChange = { value ->
                    onBrightnessChange(value.roundToInt().coerceIn(1, 100))
                },
                valueRange = 1f..100f,
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag(roomDetailLightSliderTag(light.id)),
            )
        }
    }
}

/**
 * Room detail screen: a header for [room] plus one [RoomDetailLightRow] per entry in [lights].
 *
 * Per the Demo-mode architecture rule (D-008) this composable receives its model collections
 * through parameters and never reads DemoFixtures. The supplied [lights] seed an in-memory
 * Compose list so per-light toggle/brightness edits re-render the affected row; each edit also
 * forwards the light's routing identity ([LightDisplayModel.bridgeId], [LightDisplayModel.id])
 * and the new value through [onLightToggle] / [onLightBrightnessChange].
 */
@Composable
fun RoomDetailScreen(
    room: RoomDisplayModel,
    lights: List<LightDisplayModel>,
    onLightToggle: (String, String, Boolean) -> Unit = { _, _, _ -> },
    onLightBrightnessChange: (String, String, Int) -> Unit = { _, _, _ -> },
    onBack: () -> Unit = {},
    modifier: Modifier = Modifier,
) {
    // Seed in-memory Compose state from the supplied lights. Re-seeds if a new list arrives.
    val lightState = remember(lights) {
        mutableStateListOf<LightDisplayModel>().apply { addAll(lights) }
    }

    val headerLine = buildString {
        append(if (room.isOn) "On" else "Off")
        append(" · ")
        append(room.brightness)
        append("% · ")
        append(room.lightCount)
        append(" lights")
    }

    Column(
        modifier = modifier
            .fillMaxSize()
            .padding(24.dp)
            .verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            TextButton(
                onClick = onBack,
                modifier = Modifier.testTag(ROOM_DETAIL_BACK_TAG),
            ) {
                Text(text = "Back")
            }
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = room.name,
                    style = MaterialTheme.typography.headlineSmall,
                    color = MaterialTheme.colorScheme.onBackground,
                )
                Text(
                    text = headerLine,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }

        lightState.forEach { light ->
            RoomDetailLightRow(
                light = light,
                onToggle = { isOn ->
                    val index = lightState.indexOfFirst { it.id == light.id }
                    if (index >= 0) {
                        lightState[index] = lightState[index].copy(isOn = isOn)
                    }
                    onLightToggle(light.bridgeId, light.id, isOn)
                },
                onBrightnessChange = { brightness ->
                    val coerced = brightness.coerceIn(1, 100)
                    val index = lightState.indexOfFirst { it.id == light.id }
                    if (index >= 0) {
                        lightState[index] = lightState[index].copy(brightness = coerced)
                    }
                    onLightBrightnessChange(light.bridgeId, light.id, coerced)
                },
            )
        }
    }
}
