package com.chromaglow.app.feature.home

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.chromaglow.app.core.identity.ResourceKey
import com.chromaglow.app.core.session.GroupKind
import com.chromaglow.app.ui.components.ConnectionStrip
import com.chromaglow.app.ui.components.FeedbackHost
import com.chromaglow.app.ui.components.MutationFeedbackUi
import com.chromaglow.app.ui.components.EmptyState
import com.chromaglow.app.ui.components.GroupCard
import com.chromaglow.app.ui.components.LocalReduceMotion
import com.chromaglow.app.ui.components.PulseCard
import com.chromaglow.app.ui.components.rememberReduceMotion

const val HOME_LIST_TAG: String = "home_list"
const val HOME_SCENES_TAG: String = "home_scenes"
const val HOME_SETTINGS_TAG: String = "home_settings"
const val HOME_REFRESH_TAG: String = "home_refresh"
const val HOME_ROOMS_HEADER_TAG: String = "home_rooms_header"
const val HOME_ZONES_HEADER_TAG: String = "home_zones_header"

/** Route-level entry: wires the ViewModel; the shell (Adam) supplies navigation callbacks. */
@Composable
fun HomeRoute(
    viewModel: HomeViewModel,
    onOpenGroup: (ResourceKey, GroupKind) -> Unit,
    onOpenScenes: () -> Unit,
    onOpenSettings: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val state by viewModel.uiState.collectAsState()
    CompositionLocalProvider(LocalReduceMotion provides rememberReduceMotion()) {
        HomeScreen(
            state = state,
            onOpenGroup = onOpenGroup,
            onOpenScenes = onOpenScenes,
            onOpenSettings = onOpenSettings,
            onRefresh = viewModel::refresh,
            onGroupPower = viewModel::setGroupPower,
            onGroupBrightness = viewModel::setGroupBrightness,
            modifier = modifier,
        )
    }
}

/**
 * Pure Home screen. Rooms then Zones, one [GroupCard] each; a [ConnectionStrip] above; honest
 * loading (placeholders only when no snapshot exists), an empty state, and no demo fallback.
 * The root is a single LazyColumn so the whole page scrolls at any font scale.
 */
@Composable
fun HomeScreen(
    state: HomeUiState,
    onOpenGroup: (ResourceKey, GroupKind) -> Unit,
    onOpenScenes: () -> Unit,
    onOpenSettings: () -> Unit,
    onRefresh: () -> Unit,
    onGroupPower: (GroupCardUi, Boolean) -> Unit,
    onGroupBrightness: (GroupCardUi, Int) -> Unit,
    modifier: Modifier = Modifier,
    feedback: MutationFeedbackUi? = null,
    onFeedbackShown: (MutationFeedbackUi) -> Unit = {},
) {
    FeedbackHost(feedback = feedback, onShown = onFeedbackShown, modifier = modifier) {
    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .testTag(HOME_LIST_TAG),
        contentPadding = PaddingValues(horizontal = 20.dp, vertical = 16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item(key = "title") {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = "ChromaGlow",
                    style = MaterialTheme.typography.headlineLarge,
                    color = MaterialTheme.colorScheme.onBackground,
                    modifier = Modifier
                        .weight(1f)
                        .semantics { heading() },
                )
                TextButton(onClick = onOpenScenes, modifier = Modifier.testTag(HOME_SCENES_TAG)) {
                    Text(text = "Scenes")
                }
                TextButton(onClick = onOpenSettings, modifier = Modifier.testTag(HOME_SETTINGS_TAG)) {
                    Text(text = "Settings")
                }
            }
        }
        if (state.strip.isNotEmpty()) {
            item(key = "strip") { ConnectionStrip(rows = state.strip) }
        }
        when (state.phase) {
            HomePhase.NO_BRIDGES -> item(key = "none") {
                EmptyState(
                    title = "No bridge connected",
                    body = "Pair a Hue bridge from Settings to control your lights.",
                    actionLabel = "Open Settings",
                    onAction = onOpenSettings,
                )
            }
            HomePhase.LOADING -> {
                items(count = 3, key = { "pulse_$it" }) { PulseCard() }
            }
            HomePhase.EMPTY -> item(key = "empty") {
                EmptyState(
                    title = "No rooms yet",
                    body = "This bridge has no rooms or zones. Create some in the Hue app, then refresh.",
                    actionLabel = "Refresh",
                    onAction = onRefresh,
                )
            }
            HomePhase.CONTENT -> {
                if (state.rooms.isNotEmpty()) {
                    item(key = "rooms_header") { SectionHeader("Rooms", HOME_ROOMS_HEADER_TAG) }
                    items(state.rooms, key = { "room_${it.composeKey}" }) { card ->
                        GroupCardItem(card, onOpenGroup, onGroupPower, onGroupBrightness)
                    }
                }
                if (state.zones.isNotEmpty()) {
                    item(key = "zones_header") { SectionHeader("Zones", HOME_ZONES_HEADER_TAG) }
                    items(state.zones, key = { "zone_${it.composeKey}" }) { card ->
                        GroupCardItem(card, onOpenGroup, onGroupPower, onGroupBrightness, badge = "ZONE")
                    }
                }
                item(key = "refresh") {
                    TextButton(
                        onClick = onRefresh,
                        modifier = Modifier
                            .fillMaxWidth()
                            .testTag(HOME_REFRESH_TAG),
                    ) { Text(text = "Refresh") }
                }
            }
        }
    }
    }
}

@Composable
private fun SectionHeader(title: String, tag: String) {
    Text(
        text = title,
        style = MaterialTheme.typography.titleLarge,
        color = MaterialTheme.colorScheme.onBackground,
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 8.dp)
            .testTag(tag)
            .semantics { heading() },
    )
}

@Composable
private fun GroupCardItem(
    card: GroupCardUi,
    onOpenGroup: (ResourceKey, GroupKind) -> Unit,
    onGroupPower: (GroupCardUi, Boolean) -> Unit,
    onGroupBrightness: (GroupCardUi, Int) -> Unit,
    badge: String? = null,
) {
    GroupCard(
        composeKey = card.composeKey,
        name = card.name,
        subtitle = card.subtitle,
        isOn = card.isOn,
        brightness = card.brightness,
        controlsEnabled = card.controlsEnabled,
        disabledReason = card.disabledReason,
        onOpen = { onOpenGroup(card.groupKey, card.kind) },
        onPower = { onGroupPower(card, it) },
        onBrightnessPreview = {},
        onBrightnessCommit = { onGroupBrightness(card, it) },
        badge = badge,
    )
}
