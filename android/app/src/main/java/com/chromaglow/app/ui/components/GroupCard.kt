package com.chromaglow.app.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
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

fun groupCardTag(composeKey: String): String = "group_card_$composeKey"
fun groupHeaderTag(composeKey: String): String = "group_header_$composeKey"
fun groupSwitchTag(composeKey: String): String = "group_switch_$composeKey"
fun groupFaderTag(composeKey: String): String = "group_fader_$composeKey"

/**
 * One room or zone as a single instrument. The header row is the open-detail target (≥ 48 dp,
 * `Role.Button`, spoken as "Open <name>"), the Switch carries its own on/off state description,
 * and the fader names the target it controls. When [controlsEnabled] is false the Switch is
 * disabled and the fader refuses gestures; [disabledReason] explains why in words.
 *
 * Off state dims tokens individually (fill, text) — never the whole card — so contrast holds.
 */
@Composable
fun GroupCard(
    composeKey: String,
    name: String,
    subtitle: String,
    isOn: Boolean,
    brightness: Int?,
    controlsEnabled: Boolean,
    disabledReason: String?,
    onOpen: () -> Unit,
    onPower: (Boolean) -> Unit,
    onBrightnessPreview: (Int) -> Unit,
    onBrightnessCommit: (Int) -> Unit,
    modifier: Modifier = Modifier,
    badge: String? = null,
    swatch: Color? = null,
) {
    Surface(
        modifier = modifier
            .fillMaxWidth()
            .testTag(groupCardTag(composeKey)),
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
                        .testTag(groupHeaderTag(composeKey))
                        .clickable(
                            onClickLabel = "Open $name",
                            role = Role.Button,
                            onClick = onOpen,
                        )
                        .semantics(mergeDescendants = true) {
                            contentDescription = buildString {
                                append(name)
                                if (badge != null) append(", $badge")
                                append(", ")
                                append(if (isOn) "on" else "off")
                                append(", ")
                                append(subtitle)
                            }
                        },
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Box(
                        modifier = Modifier
                            .size(14.dp)
                            .background(
                                color = when {
                                    !isOn -> MaterialTheme.colorScheme.outline
                                    swatch != null -> swatch
                                    else -> MaterialTheme.colorScheme.primary
                                },
                                shape = CircleShape,
                            )
                            .border(1.dp, MaterialTheme.colorScheme.outline, CircleShape),
                    )
                    Column(modifier = Modifier.weight(1f)) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            Text(
                                text = name,
                                style = MaterialTheme.typography.titleMedium,
                                color = MaterialTheme.colorScheme.onSurface,
                            )
                            if (badge != null) {
                                Text(
                                    text = badge,
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier
                                        .border(1.dp, MaterialTheme.colorScheme.outline, RoundedCornerShape(6.dp))
                                        .padding(horizontal = 6.dp, vertical = 2.dp),
                                )
                            }
                        }
                        Text(
                            text = subtitle,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
                Switch(
                    checked = isOn,
                    onCheckedChange = if (controlsEnabled) onPower else null,
                    enabled = controlsEnabled,
                    modifier = Modifier
                        .testTag(groupSwitchTag(composeKey))
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
                onPreview = onBrightnessPreview,
                onCommit = onBrightnessCommit,
                label = "$name brightness",
                enabled = controlsEnabled && brightness != null,
                disabledReason = when {
                    !controlsEnabled -> disabledReason
                    brightness == null -> "Brightness not reported"
                    else -> null
                },
                fillColor = if (isOn) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.testTag(groupFaderTag(composeKey)),
            )
            if (!controlsEnabled && disabledReason != null) {
                Text(
                    text = disabledReason,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 4.dp),
                )
            }
        }
    }
}
