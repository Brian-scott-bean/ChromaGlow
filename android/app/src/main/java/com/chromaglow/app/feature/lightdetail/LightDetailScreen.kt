package com.chromaglow.app.feature.lightdetail

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
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
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import com.chromaglow.app.core.hue.capability.CieXy
import com.chromaglow.app.core.session.TimedEffect
import com.chromaglow.app.ui.components.CheckingPlaceholder
import com.chromaglow.app.ui.components.ChipOption
import com.chromaglow.app.ui.components.ChoiceChipRow
import com.chromaglow.app.ui.components.ColorMath
import com.chromaglow.app.ui.components.ColorPad
import com.chromaglow.app.ui.components.ConnectionStrip
import com.chromaglow.app.ui.components.EmptyState
import com.chromaglow.app.ui.components.FeedbackHost
import com.chromaglow.app.ui.components.MutationFeedbackUi
import com.chromaglow.app.ui.components.GradientSwatchStrip
import com.chromaglow.app.ui.components.LocalReduceMotion
import com.chromaglow.app.ui.components.ModeSegment
import com.chromaglow.app.ui.components.SectionCard
import com.chromaglow.app.ui.components.SegmentOption
import com.chromaglow.app.ui.components.StageFader
import com.chromaglow.app.ui.components.rememberReduceMotion

const val LIGHT_DETAIL_ROOT_TAG: String = "light_detail_root"
const val LIGHT_DETAIL_BACK_TAG: String = "light_detail_back"
const val LIGHT_DETAIL_SWITCH_TAG: String = "light_detail_switch"
const val LIGHT_DETAIL_BRIGHTNESS_TAG: String = "light_detail_brightness"
const val LIGHT_DETAIL_WARMTH_TAG: String = "light_detail_warmth"
const val LIGHT_DETAIL_EFFECT_SPEED_TAG: String = "light_detail_effect_speed"
const val LIGHT_DETAIL_EFFECT_WARMTH_TAG: String = "light_detail_effect_warmth"
const val LIGHT_DETAIL_NOTICE_TAG: String = "light_detail_notice"
const val LIGHT_DETAIL_NOTICE_ACTION_TAG: String = "light_detail_notice_action"
const val LIGHT_DETAIL_TIMED_START_TAG: String = "light_detail_timed_start"
const val LIGHT_DETAIL_TIMED_CANCEL_TAG: String = "light_detail_timed_cancel"
const val LIGHT_DETAIL_GRADIENT_APPLY_TAG: String = "light_detail_gradient_apply"
const val EFFECT_CHIPS_TAG: String = "effect_chips"
const val EFFECT_COLOR_CHIPS_TAG: String = "effect_color_chips"
const val TIMED_CHIPS_TAG: String = "timed_chips"
const val DURATION_CHIPS_TAG: String = "duration_chips"
const val GRADIENT_MODE_CHIPS_TAG: String = "gradient_mode_chips"
const val GRADIENT_COLOR_CHIPS_TAG: String = "gradient_color_chips"
const val UNVERIFIED_FOOTNOTE: String = "Not yet verified on these lights."
const val EFFECT_NONE_ID: String = "none"

/** Callbacks the pure screen needs; the route binds them to the ViewModel. */
data class LightDetailActions(
    val onBack: () -> Unit,
    val onPower: (Boolean) -> Unit,
    val onBrightness: (Int) -> Unit,
    val onMode: (ColorMode) -> Unit,
    val onColor: (CieXy) -> Unit,
    val onMirek: (Int) -> Unit,
    val onEffect: (String?) -> Unit,
    val onEffectSpeed: (Int) -> Unit,
    val onEffectColor: (CieXy) -> Unit,
    val onEffectMirek: (Int) -> Unit,
    val onTimedSelect: (TimedEffect) -> Unit,
    val onTimedDuration: (Int) -> Unit,
    val onTimedStart: () -> Unit,
    val onTimedCancel: () -> Unit,
    val onGradientPoint: (Int) -> Unit,
    val onGradientPointColor: (CieXy) -> Unit,
    val onGradientMode: (String) -> Unit,
    val onGradientApply: () -> Unit,
    val onAcknowledgeNotice: () -> Unit,
)

@Composable
fun LightDetailRoute(
    viewModel: LightDetailViewModel,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val state by viewModel.uiState.collectAsState()
    val feedback by viewModel.feedback.collectAsState()
    CompositionLocalProvider(LocalReduceMotion provides rememberReduceMotion()) {
        LightDetailScreen(
            state = state,
            actions = LightDetailActions(
                onBack = onBack,
                onPower = viewModel::setPower,
                onBrightness = viewModel::setBrightness,
                onMode = viewModel::selectMode,
                onColor = viewModel::setColor,
                onMirek = viewModel::setMirek,
                onEffect = viewModel::selectEffect,
                onEffectSpeed = viewModel::setEffectSpeed,
                onEffectColor = viewModel::setEffectColor,
                onEffectMirek = viewModel::setEffectMirek,
                onTimedSelect = viewModel::selectTimed,
                onTimedDuration = viewModel::setTimedDuration,
                onTimedStart = viewModel::startTimed,
                onTimedCancel = viewModel::cancelTimed,
                onGradientPoint = viewModel::selectGradientPoint,
                onGradientPointColor = viewModel::setGradientPointColor,
                onGradientMode = viewModel::selectGradientMode,
                onGradientApply = viewModel::applyGradient,
                onAcknowledgeNotice = viewModel::acknowledgeNotice,
            ),
            feedback = feedback,
            onFeedbackShown = viewModel::dismissFeedback,
            modifier = modifier,
        )
    }
}

/**
 * Progressive disclosure by evidence. Order: power + brightness → Colour/Warmth (one segment when
 * both are Known) → Effects → Timed → Gradient. Hidden sections render nothing; Checking sections
 * render a quiet non-interactive placeholder; Ready sections render the semantic control and, while
 * hardware-unverified, the footnote. The root scrolls.
 */
@Composable
fun LightDetailScreen(
    state: LightDetailUiState,
    actions: LightDetailActions,
    modifier: Modifier = Modifier,
    feedback: MutationFeedbackUi? = null,
    onFeedbackShown: (MutationFeedbackUi) -> Unit = {},
) {
    val enabled = state.controlsEnabled
    val footnote = if (state.hardwareUnverified) UNVERIFIED_FOOTNOTE else null
    FeedbackHost(feedback = feedback, onShown = onFeedbackShown, modifier = modifier) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp, vertical = 16.dp)
            .testTag(LIGHT_DETAIL_ROOT_TAG),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = actions.onBack, modifier = Modifier.testTag(LIGHT_DETAIL_BACK_TAG)) { Text("Back") }
            Text(
                text = state.name,
                style = MaterialTheme.typography.headlineSmall,
                color = MaterialTheme.colorScheme.onBackground,
                modifier = Modifier
                    .weight(1f)
                    .semantics { heading() },
            )
        }
        if (state.strip.isNotEmpty()) ConnectionStrip(rows = state.strip)
        if (!state.found) {
            EmptyState(
                title = "This light is no longer available",
                body = "It may have been removed on the bridge. Go back and refresh.",
                actionLabel = "Back",
                onAction = actions.onBack,
            )
            return@Column
        }

        SectionCard(id = "power", title = "Power & brightness") {
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = if (state.isOn) "On" else "Off",
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.weight(1f),
                )
                Switch(
                    checked = state.isOn,
                    onCheckedChange = if (enabled) actions.onPower else null,
                    enabled = enabled,
                    modifier = Modifier
                        .testTag(LIGHT_DETAIL_SWITCH_TAG)
                        .semantics {
                            contentDescription = "${state.name} power"
                            stateDescription = when {
                                !enabled -> state.disabledReason ?: "Unavailable"
                                state.isOn -> "On"
                                else -> "Off"
                            }
                        },
                )
            }
            StageFader(
                value = state.brightness ?: 1,
                onPreview = {},
                onCommit = actions.onBrightness,
                label = "${state.name} brightness",
                enabled = enabled && state.brightness != null,
                disabledReason = if (!enabled) state.disabledReason else "Brightness not reported",
                modifier = Modifier.testTag(LIGHT_DETAIL_BRIGHTNESS_TAG),
            )
            if (!enabled && state.disabledReason != null) {
                Text(
                    text = state.disabledReason,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
                )
            }
        }

        // Colour / Warmth
        val mode = state.mode
        if (mode != null) {
            SectionCard(id = "colormode", title = "Colour & warmth", footnote = footnote) {
                ModeSegment(
                    options = ColorMode.entries.map { SegmentOption(it.id, it.label) },
                    selectedId = mode.id,
                    onSelect = { id -> ColorMode.entries.firstOrNull { it.id == id }?.let(actions.onMode) },
                    enabled = enabled,
                )
                when (mode) {
                    ColorMode.COLOR -> (state.color as? SectionUi.Ready)?.value?.let { c ->
                        ColorPad(gamut = c.gamut, current = c.current, label = "${state.name} colour", onPreview = {}, onCommit = actions.onColor, enabled = enabled)
                    }
                    ColorMode.WARMTH -> (state.warmth as? SectionUi.Ready)?.value?.let { w ->
                        WarmthFader(name = state.name, ui = w, enabled = enabled, onCommit = actions.onMirek, tag = LIGHT_DETAIL_WARMTH_TAG)
                    }
                }
            }
        } else {
            when (val c = state.color) {
                is SectionUi.Ready -> SectionCard(id = "color", title = "Colour", footnote = footnote) {
                    ColorPad(gamut = c.value.gamut, current = c.value.current, label = "${state.name} colour", onPreview = {}, onCommit = actions.onColor, enabled = enabled)
                }
                SectionUi.Checking -> CheckingPlaceholder(id = "color", title = "Colour")
                SectionUi.Hidden -> Unit
            }
            when (val w = state.warmth) {
                is SectionUi.Ready -> SectionCard(id = "warmth", title = "Warmth", footnote = footnote) {
                    WarmthFader(name = state.name, ui = w.value, enabled = enabled, onCommit = actions.onMirek, tag = LIGHT_DETAIL_WARMTH_TAG)
                }
                SectionUi.Checking -> CheckingPlaceholder(
                    id = "warmth",
                    title = "Warmth",
                    detail = "Checking this light's colour-temperature range…",
                )
                SectionUi.Hidden -> Unit
            }
        }

        // Effects
        when (val e = state.effects) {
            is SectionUi.Ready -> {
                if (state.showPhotosensitivityNotice) {
                    NoticeCard(onAcknowledge = actions.onAcknowledgeNotice)
                }
                SectionCard(id = "effects", title = "Effects", footnote = footnote) {
                    val ui = e.value
                    ChoiceChipRow(
                        options = listOf(ChipOption(EFFECT_NONE_ID, "None")) + ui.options.map { ChipOption(it, it.replaceFirstChar(Char::uppercase)) },
                        selectedId = ui.active ?: EFFECT_NONE_ID,
                        onSelect = { id -> actions.onEffect(if (id == EFFECT_NONE_ID) null else id) },
                        enabled = enabled,
                        rowTag = EFFECT_CHIPS_TAG,
                    )
                    if (ui.speedAvailable) {
                        StageFader(
                            value = ui.speedPercent,
                            onPreview = {},
                            onCommit = actions.onEffectSpeed,
                            label = "Effect speed",
                            range = 0..100,
                            enabled = enabled,
                            modifier = Modifier.testTag(LIGHT_DETAIL_EFFECT_SPEED_TAG),
                        )
                    }
                    (ui.colorParam as? SectionUi.Ready)?.value?.let { c ->
                        Text("Effect colour", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        ChoiceChipRow(
                            options = ColorMath.NAMED.map { ChipOption(it.name, it.name, ColorMath.toDisplayColor(it.xy)) },
                            selectedId = ui.paramColor?.let { p -> ColorMath.NAMED.firstOrNull { ColorMath.clampToGamut(it.xy, c.gamut) == p }?.name },
                            onSelect = { id -> actions.onEffectColor(ColorMath.NAMED.first { it.name == id }.xy) },
                            enabled = enabled,
                            rowTag = EFFECT_COLOR_CHIPS_TAG,
                        )
                    }
                    (ui.warmthParam as? SectionUi.Ready)?.value?.let { w ->
                        WarmthFader(
                            name = "Effect",
                            ui = WarmthUi(w.range, ui.paramMirek ?: w.currentMirek),
                            enabled = enabled,
                            onCommit = actions.onEffectMirek,
                            tag = LIGHT_DETAIL_EFFECT_WARMTH_TAG,
                        )
                    }
                }
            }
            SectionUi.Checking -> CheckingPlaceholder(id = "effects", title = "Effects")
            SectionUi.Hidden -> Unit
        }

        // Timed effects
        when (val t = state.timed) {
            is SectionUi.Ready -> SectionCard(id = "timed", title = "Timed", footnote = footnote) {
                val ui = t.value
                if (ui.active != null) {
                    Text(
                        text = "${ui.active.wireName.replaceFirstChar(Char::uppercase)} is running",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurface,
                        modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
                    )
                    OutlinedButton(
                        onClick = actions.onTimedCancel,
                        enabled = enabled,
                        modifier = Modifier
                            .fillMaxWidth()
                            .testTag(LIGHT_DETAIL_TIMED_CANCEL_TAG),
                    ) { Text("Cancel") }
                } else {
                    ChoiceChipRow(
                        options = ui.options.map { ChipOption(it.wireName, it.wireName.replaceFirstChar(Char::uppercase)) },
                        selectedId = ui.selected.wireName,
                        onSelect = { id -> TimedEffect.entries.firstOrNull { it.wireName == id }?.let(actions.onTimedSelect) },
                        enabled = enabled,
                        rowTag = TIMED_CHIPS_TAG,
                    )
                    ChoiceChipRow(
                        options = ui.durationChoices.map { ChipOption(it.toString(), "$it min") },
                        selectedId = ui.durationMinutes.toString(),
                        onSelect = { id -> id.toIntOrNull()?.let(actions.onTimedDuration) },
                        enabled = enabled,
                        rowTag = DURATION_CHIPS_TAG,
                    )
                    Button(
                        onClick = actions.onTimedStart,
                        enabled = enabled,
                        modifier = Modifier
                            .fillMaxWidth()
                            .testTag(LIGHT_DETAIL_TIMED_START_TAG),
                    ) { Text("Start ${ui.selected.wireName} over ${ui.durationMinutes} min") }
                }
            }
            SectionUi.Checking -> CheckingPlaceholder(id = "timed", title = "Timed")
            SectionUi.Hidden -> Unit
        }

        // Gradient
        when (val g = state.gradient) {
            is SectionUi.Ready -> SectionCard(id = "gradient", title = "Gradient", footnote = footnote) {
                val ui = g.value
                Text(
                    text = "${ui.maxPoints} colour points",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                GradientSwatchStrip(points = ui.points, selectedIndex = ui.selectedIndex, onSelect = actions.onGradientPoint, enabled = enabled)
                ChoiceChipRow(
                    options = ColorMath.NAMED.map { ChipOption(it.name, it.name, ColorMath.toDisplayColor(it.xy)) },
                    selectedId = null,
                    onSelect = { id -> actions.onGradientPointColor(ColorMath.NAMED.first { it.name == id }.xy) },
                    enabled = enabled,
                    rowTag = GRADIENT_COLOR_CHIPS_TAG,
                )
                if (ui.modes.isNotEmpty()) {
                    ChoiceChipRow(
                        options = ui.modes.map { ChipOption(it, it.replace('_', ' ').replaceFirstChar(Char::uppercase)) },
                        selectedId = ui.selectedMode,
                        onSelect = actions.onGradientMode,
                        enabled = enabled,
                        rowTag = GRADIENT_MODE_CHIPS_TAG,
                    )
                }
                Button(
                    onClick = actions.onGradientApply,
                    enabled = enabled && ui.dirty,
                    modifier = Modifier
                        .fillMaxWidth()
                        .testTag(LIGHT_DETAIL_GRADIENT_APPLY_TAG),
                ) { Text("Apply gradient") }
            }
            SectionUi.Checking -> CheckingPlaceholder(id = "gradient", title = "Gradient")
            SectionUi.Hidden -> Unit
        }
    }
    }
}

@Composable
private fun WarmthFader(name: String, ui: WarmthUi, enabled: Boolean, onCommit: (Int) -> Unit, tag: String) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        StageFader(
            value = ui.currentMirek?.let(ui.range::clamp) ?: ui.range.clamp((ui.range.minimum + ui.range.maximum) / 2),
            onPreview = {},
            onCommit = onCommit,
            label = "$name warmth",
            range = ui.range.minimum..ui.range.maximum,
            enabled = enabled,
            readout = ColorMath::mirekToKelvinLabel,
            fillColor = ColorMath.mirekToDisplayColor(ui.currentMirek ?: ui.range.minimum),
            modifier = Modifier.testTag(tag),
        )
        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text(ColorMath.mirekToKelvinLabel(ui.range.minimum), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(ColorMath.mirekToKelvinLabel(ui.range.maximum), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun NoticeCard(onAcknowledge: () -> Unit) {
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(LIGHT_DETAIL_NOTICE_TAG)
            .semantics { liveRegion = LiveRegionMode.Polite },
        shape = RoundedCornerShape(16.dp),
        color = MaterialTheme.colorScheme.primaryContainer,
    ) {
        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(PhotosensitivityNotice.TITLE, style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onPrimaryContainer)
            Text(PhotosensitivityNotice.BODY, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurface)
            TextButton(onClick = onAcknowledge, modifier = Modifier.testTag(LIGHT_DETAIL_NOTICE_ACTION_TAG)) {
                Text(PhotosensitivityNotice.ACTION)
            }
        }
    }
}
