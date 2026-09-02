package com.chromaglow.app.feature.scenes

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import com.chromaglow.app.ui.components.ConnectionStrip
import com.chromaglow.app.ui.components.EmptyState
import com.chromaglow.app.ui.components.LocalReduceMotion
import com.chromaglow.app.ui.components.PulseCard
import com.chromaglow.app.ui.components.rememberReduceMotion

const val LIVE_SCENES_LIST_TAG: String = "live_scenes_list"
const val LIVE_SCENES_BACK_TAG: String = "live_scenes_back"

fun liveSceneRowTag(composeKey: String): String = "live_scene_$composeKey"
fun liveSceneBridgeHeaderTag(bridgeLabel: String): String = "live_scenes_bridge_$bridgeLabel"

@Composable
fun LiveScenesRoute(
    viewModel: LiveScenesViewModel,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val state by viewModel.uiState.collectAsState()
    CompositionLocalProvider(LocalReduceMotion provides rememberReduceMotion()) {
        LiveScenesScreen(state = state, onBack = onBack, onActivate = viewModel::activate, onRefresh = viewModel::refresh, modifier = modifier)
    }
}

/**
 * Sections by bridge, then by group. Each row is a Button with `selected` = active and a spoken
 * activation state; rows on an offline/revoked bridge are disabled with the reason. No speed or
 * authoring controls: dynamic scenes carry a glyph only.
 */
@Composable
fun LiveScenesScreen(
    state: LiveScenesUiState,
    onBack: () -> Unit,
    onActivate: (SceneRowUi) -> Unit,
    onRefresh: () -> Unit,
    modifier: Modifier = Modifier,
) {
    LazyColumn(
        modifier = modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .testTag(LIVE_SCENES_LIST_TAG),
        contentPadding = PaddingValues(horizontal = 20.dp, vertical = 16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        item(key = "header") {
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = onBack, modifier = Modifier.testTag(LIVE_SCENES_BACK_TAG)) { Text("Back") }
                Text(
                    text = "Scenes",
                    style = MaterialTheme.typography.headlineLarge,
                    color = MaterialTheme.colorScheme.onBackground,
                    modifier = Modifier
                        .weight(1f)
                        .semantics { heading() },
                )
                TextButton(onClick = onRefresh) { Text("Refresh") }
            }
        }
        if (state.strip.isNotEmpty()) item(key = "strip") { ConnectionStrip(rows = state.strip) }
        when (state.phase) {
            ScenesPhase.NO_BRIDGES -> item(key = "none") {
                EmptyState(title = "No bridge connected", body = "Pair a Hue bridge from Settings to see its scenes.")
            }
            ScenesPhase.LOADING -> items(count = 4, key = { "pulse_$it" }) { PulseCard() }
            ScenesPhase.EMPTY -> item(key = "empty") {
                EmptyState(
                    title = "No scenes yet",
                    body = "Scenes you create in the Hue app appear here.",
                    actionLabel = "Refresh",
                    onAction = onRefresh,
                )
            }
            ScenesPhase.CONTENT -> state.sections.forEach { bridge ->
                if (state.sections.size > 1) {
                    item(key = "bridge_${bridge.bridgeId.value}") {
                        Text(
                            text = bridge.bridgeLabel,
                            style = MaterialTheme.typography.titleLarge,
                            color = MaterialTheme.colorScheme.onBackground,
                            modifier = Modifier
                                .padding(top = 8.dp)
                                .testTag(liveSceneBridgeHeaderTag(bridge.bridgeLabel))
                                .semantics { heading() },
                        )
                    }
                }
                bridge.groups.forEach { group ->
                    item(key = "group_${bridge.bridgeId.value}_${group.groupKey?.composeKey ?: "other"}") {
                        Text(
                            text = group.groupName,
                            style = MaterialTheme.typography.titleMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier
                                .padding(top = 6.dp)
                                .semantics { heading() },
                        )
                    }
                    items(group.scenes, key = { it.composeKey }) { row -> LiveSceneRow(row = row, onActivate = { onActivate(row) }) }
                }
            }
        }
    }
}

@Composable
private fun LiveSceneRow(row: SceneRowUi, onActivate: () -> Unit) {
    val isActive = row.activation == SceneActivation.ACTIVE
    val stateText = when (row.activation) {
        SceneActivation.ACTIVE -> "Active"
        SceneActivation.ACTIVATING -> "Activating…"
        SceneActivation.FAILED -> "Didn't activate"
        SceneActivation.IDLE -> ""
    }
    Surface(
        onClick = onActivate,
        enabled = row.enabled && row.activation != SceneActivation.ACTIVATING,
        modifier = Modifier
            .fillMaxWidth()
            .defaultMinSize(minHeight = 56.dp)
            .testTag(liveSceneRowTag(row.composeKey))
            .semantics {
                role = Role.Button
                selected = isActive
                contentDescription = buildString {
                    append(row.name)
                    if (row.isDynamic) append(", dynamic scene")
                }
                stateDescription = when {
                    !row.enabled -> row.disabledReason ?: "Unavailable"
                    stateText.isNotEmpty() -> stateText
                    else -> "Not active"
                }
                if (row.activation != SceneActivation.IDLE) liveRegion = LiveRegionMode.Polite
            },
        shape = RoundedCornerShape(16.dp),
        color = if (isActive) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surface,
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = row.name,
                    style = MaterialTheme.typography.titleMedium,
                    color = if (row.enabled) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant,
                )
                val sub = listOfNotNull(
                    if (row.isDynamic) "Dynamic" else null,
                    if (!row.enabled) row.disabledReason else null,
                ).joinToString(" · ")
                if (sub.isNotEmpty()) {
                    Text(text = sub, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            if (stateText.isNotEmpty()) {
                Text(
                    text = stateText,
                    style = MaterialTheme.typography.labelLarge,
                    color = when (row.activation) {
                        SceneActivation.FAILED -> MaterialTheme.colorScheme.error
                        SceneActivation.ACTIVE -> MaterialTheme.colorScheme.onPrimaryContainer
                        else -> MaterialTheme.colorScheme.onSurfaceVariant
                    },
                )
            }
        }
    }
}
