package com.chromaglow.app.feature.roomdetail

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
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
import com.chromaglow.app.core.hue.capability.CieXy
import com.chromaglow.app.core.hue.capability.Gamut
import com.chromaglow.app.core.hue.capability.GamutType
import com.chromaglow.app.core.hue.capability.MirekRange
import com.chromaglow.app.core.identity.ResourceKey
import com.chromaglow.app.core.session.GroupKind
import com.chromaglow.app.feature.home.GroupCardUi
import com.chromaglow.app.ui.components.ColorMath
import com.chromaglow.app.ui.components.ColorPad
import com.chromaglow.app.ui.components.ConnectionStrip
import com.chromaglow.app.ui.components.FeedbackHost
import com.chromaglow.app.ui.components.MutationFeedbackUi
import com.chromaglow.app.ui.components.EmptyState
import com.chromaglow.app.ui.components.GroupCard
import com.chromaglow.app.ui.components.LightCard
import com.chromaglow.app.ui.components.LocalReduceMotion
import com.chromaglow.app.ui.components.SectionCard
import com.chromaglow.app.ui.components.StageFader
import com.chromaglow.app.ui.components.rememberReduceMotion

fun groupInstrumentCaptionTag(sectionId: String): String = "${sectionId}_caption"

const val GROUP_DETAIL_LIST_TAG: String = "group_detail_list"
const val GROUP_DETAIL_BACK_TAG: String = "group_detail_back"
const val GROUP_DETAIL_COVERAGE_TAG: String = "group_detail_coverage"

@Composable
fun GroupDetailRoute(
    viewModel: GroupDetailViewModel,
    onBack: () -> Unit,
    onOpenLight: (ResourceKey) -> Unit,
    modifier: Modifier = Modifier,
) {
    val state by viewModel.uiState.collectAsState()
    CompositionLocalProvider(LocalReduceMotion provides rememberReduceMotion()) {
        GroupDetailScreen(
            state = state,
            onBack = onBack,
            onOpenLight = onOpenLight,
            onGroupPower = viewModel::setGroupPower,
            onGroupBrightness = viewModel::setGroupBrightness,
            onLightPower = viewModel::setLightPower,
            onLightBrightness = viewModel::setLightBrightness,
            onGroupColor = viewModel::setGroupColor,
            onGroupColorTemperature = viewModel::setGroupColorTemperature,
            modifier = modifier,
        )
    }
}

const val GROUP_COLOR_SECTION_ID: String = "group_color"
const val GROUP_WARMTH_SECTION_ID: String = "group_warmth"
const val GROUP_WARMTH_FADER_TAG: String = "group_warmth_fader"
const val GROUP_COLOR_FOOTNOTE: String =
    "Shown in a standard colour range. Each light is limited to the colours it can actually show."
const val GROUP_WARMTH_FOOTNOTE: String =
    "Group range. Each light stays within its own colour-temperature limits."

/**
 * Live Room/Zone detail: the group instrument (same card as Home, header not clickable), honest
 * coverage lines, then one [LightCard] per member. Root is one LazyColumn so it scrolls at 200 %.
 */
@Composable
fun GroupDetailScreen(
    state: GroupDetailUiState,
    onBack: () -> Unit,
    onOpenLight: (ResourceKey) -> Unit,
    onGroupPower: (GroupCardUi, Boolean) -> Unit,
    onGroupBrightness: (GroupCardUi, Int) -> Unit,
    onLightPower: (LightCardUi, Boolean) -> Unit,
    onLightBrightness: (LightCardUi, Int) -> Unit,
    modifier: Modifier = Modifier,
    feedback: MutationFeedbackUi? = null,
    onFeedbackShown: (MutationFeedbackUi) -> Unit = {},
    onGroupColor: (CieXy) -> Unit = {},
    onGroupColorTemperature: (Int) -> Unit = {},
) {
    FeedbackHost(feedback = feedback, onShown = onFeedbackShown, modifier = modifier) {
    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .testTag(GROUP_DETAIL_LIST_TAG),
        contentPadding = PaddingValues(horizontal = 20.dp, vertical = 16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item(key = "header") {
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = onBack, modifier = Modifier.testTag(GROUP_DETAIL_BACK_TAG)) { Text(text = "Back") }
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = state.group?.name ?: "Group",
                        style = MaterialTheme.typography.headlineSmall,
                        color = MaterialTheme.colorScheme.onBackground,
                        modifier = Modifier.semantics { heading() },
                    )
                    state.group?.let {
                        Text(
                            text = if (it.kind == GroupKind.ZONE) "Zone" else "Room",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }
        }
        if (state.strip.isNotEmpty()) item(key = "strip") { ConnectionStrip(rows = state.strip) }
        val group = state.group
        if (!state.found || group == null) {
            item(key = "missing") {
                EmptyState(
                    title = "This group is no longer available",
                    body = "It may have been removed on the bridge. Go back to Home to refresh.",
                    actionLabel = "Back",
                    onAction = onBack,
                )
            }
            return@LazyColumn
        }
        item(key = "instrument") {
            GroupCard(
                composeKey = group.composeKey,
                name = group.name,
                subtitle = group.subtitle,
                isOn = group.isOn,
                brightness = group.brightness,
                controlsEnabled = group.controlsEnabled,
                disabledReason = group.disabledReason,
                onOpen = null,
                onPower = { onGroupPower(group, it) },
                onBrightnessPreview = {},
                onBrightnessCommit = { onGroupBrightness(group, it) },
                badge = if (group.kind == GroupKind.ZONE) "ZONE" else null,
            )
        }
        state.groupColor?.let { instrument ->
            item(key = "group_color") {
                SectionCard(id = GROUP_COLOR_SECTION_ID, title = "Colour", footnote = GROUP_COLOR_FOOTNOTE) {
                    Text(
                        text = instrument.caption,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.testTag(groupInstrumentCaptionTag(GROUP_COLOR_SECTION_ID)),
                    )
                    ColorPad(
                        gamut = Gamut.specDerived(GamutType.C),
                        current = null,
                        label = "${group.name} colour",
                        onPreview = {},
                        onCommit = onGroupColor,
                        enabled = group.controlsEnabled,
                        footnote = "",
                    )
                }
            }
        }
        state.groupWarmth?.let { instrument ->
            item(key = "group_warmth") {
                SectionCard(id = GROUP_WARMTH_SECTION_ID, title = "Warmth", footnote = GROUP_WARMTH_FOOTNOTE) {
                    Text(
                        text = instrument.caption,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.testTag(groupInstrumentCaptionTag(GROUP_WARMTH_SECTION_ID)),
                    )
                    StageFader(
                        value = (MirekRange.PROTOCOL_MINIMUM + MirekRange.PROTOCOL_MAXIMUM) / 2,
                        onPreview = {},
                        onCommit = onGroupColorTemperature,
                        label = "${group.name} warmth",
                        range = MirekRange.PROTOCOL_MINIMUM..MirekRange.PROTOCOL_MAXIMUM,
                        enabled = group.controlsEnabled,
                        disabledReason = group.disabledReason,
                        readout = ColorMath::mirekToKelvinLabel,
                        modifier = Modifier.testTag(GROUP_WARMTH_FADER_TAG),
                    )
                }
            }
        }
        if (state.coverage.isNotEmpty()) {
            item(key = "coverage") {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .testTag(GROUP_DETAIL_COVERAGE_TAG),
                    verticalArrangement = Arrangement.spacedBy(2.dp),
                ) {
                    state.coverage.forEach { line ->
                        Text(
                            text = line,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }
        }
        item(key = "lights_header") {
            Text(
                text = "Lights",
                style = MaterialTheme.typography.titleLarge,
                color = MaterialTheme.colorScheme.onBackground,
                modifier = Modifier.semantics { heading() },
            )
        }
        if (state.lights.isEmpty()) {
            item(key = "no_lights") {
                EmptyState(title = "No lights in this group", body = "Add lights to it in the Hue app, then refresh.")
            }
        }
        items(state.lights, key = { it.composeKey }) { light ->
            LightCard(
                composeKey = light.composeKey,
                name = light.name,
                statusLine = light.statusLine,
                isOn = light.isOn,
                brightness = light.brightness,
                swatch = when {
                    light.mirek != null -> ColorMath.mirekToDisplayColor(light.mirek)
                    light.colorXy != null -> ColorMath.toDisplayColor(light.colorXy)
                    else -> null
                },
                knownGlyphs = light.knownGlyphs,
                controlsEnabled = light.controlsEnabled,
                disabledReason = light.disabledReason,
                onOpen = { onOpenLight(light.key) },
                onPower = { onLightPower(light, it) },
                onBrightnessCommit = { onLightBrightness(light, it) },
            )
        }
    }
    }
}
