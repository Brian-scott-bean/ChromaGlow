package com.chromaglow.app.ui.components

import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp

fun lightCardTag(composeKey: String): String = "light_card_$composeKey"
fun lightHeaderTag(composeKey: String): String = "light_header_$composeKey"
fun lightSwitchTag(composeKey: String): String = "light_switch_$composeKey"
fun lightFaderTag(composeKey: String): String = "light_fader_$composeKey"

/**
 * Compact per-light instrument for Room/Zone detail: name, a swatch of the current colour or
 * warmth, glyph labels for capabilities that are KNOWN (never for Unknown/Absent), a Switch, and
 * a brightness fader. Header (≥ 48 dp) opens Light detail.
 */
@Composable
fun LightCard(
    composeKey: String,
    name: String,
    statusLine: String,
    isOn: Boolean,
    brightness: Int?,
    swatch: Color?,
    knownGlyphs: List<String>,
    controlsEnabled: Boolean,
    disabledReason: String?,
    onOpen: () -> Unit,
    onPower: (Boolean) -> Unit,
    onBrightnessCommit: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        modifier = modifier
            .fillMaxWidth()
            .testTag(lightCardTag(composeKey)),
        shape = RoundedCornerShape(16.dp),
        color = MaterialTheme.colorScheme.surface,
    ) {
        Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Row(
                    modifier = Modifier
                        .weight(1f)
                        .defaultMinSize(minHeight = 48.dp)
                        .testTag(lightHeaderTag(composeKey))
                        .clickable(onClickLabel = "Open $name", role = Role.Button, onClick = onOpen)
                        .semantics(mergeDescendants = true) {
                            contentDescription = buildString {
                                append(name)
                                append(", ")
                                append(if (isOn) "on" else "off")
                                append(", ")
                                append(statusLine)
                                if (knownGlyphs.isNotEmpty()) append(", supports ${knownGlyphs.joinToString(", ")}")
                            }
                        },
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    ColorDot(color = if (isOn) swatch else null, modifier = Modifier.size(14.dp))
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = name,
                            style = MaterialTheme.typography.titleMedium,
                            color = MaterialTheme.colorScheme.onSurface,
                        )
                        Text(
                            text = statusLine,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        if (knownGlyphs.isNotEmpty()) {
                            Row(horizontalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.padding(top = 4.dp)) {
                                knownGlyphs.forEach { glyph ->
                                    Text(
                                        text = glyph,
                                        style = MaterialTheme.typography.labelSmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        modifier = Modifier
                                            .border(1.dp, MaterialTheme.colorScheme.outline, RoundedCornerShape(6.dp))
                                            .padding(horizontal = 6.dp, vertical = 2.dp),
                                    )
                                }
                            }
                        }
                    }
                }
                Switch(
                    checked = isOn,
                    onCheckedChange = if (controlsEnabled) onPower else null,
                    enabled = controlsEnabled,
                    modifier = Modifier
                        .testTag(lightSwitchTag(composeKey))
                        .semantics {
                            contentDescription = "$name power"
                            stateDescription = when {
                                !controlsEnabled -> disabledReason ?: "Unavailable"
                                isOn -> "On"
                                else -> "Off"
                            }
                        },
                )
            }
            StageFader(
                value = brightness ?: 1,
                onPreview = {},
                onCommit = onBrightnessCommit,
                label = "$name brightness",
                enabled = controlsEnabled && brightness != null,
                disabledReason = when {
                    !controlsEnabled -> disabledReason
                    brightness == null -> "Brightness not reported"
                    else -> null
                },
                fillColor = if (isOn) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.testTag(lightFaderTag(composeKey)),
            )
        }
    }
}
