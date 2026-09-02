package com.chromaglow.app.feature.lightdetail

import com.chromaglow.app.core.hue.capability.CieXy
import com.chromaglow.app.core.hue.capability.Gamut
import com.chromaglow.app.core.hue.capability.MirekRange
import com.chromaglow.app.core.identity.ResourceKey
import com.chromaglow.app.core.identity.TargetRef
import com.chromaglow.app.core.session.TimedEffect
import com.chromaglow.app.ui.components.ConnectionRowUi

/**
 * How one capability section renders. Exactly the frozen evidence rule:
 * KNOWN → [Ready]; UNKNOWN/UNREADABLE → [Checking] (non-interactive, never "unsupported");
 * ABSENT/UNSUPPORTED → [Hidden] (nothing rendered, no fake control).
 */
sealed interface SectionUi<out T> {
    data object Hidden : SectionUi<Nothing>
    data object Checking : SectionUi<Nothing>
    data class Ready<T>(val value: T) : SectionUi<T>
}

enum class ColorMode(val id: String, val label: String) {
    COLOR("color", "Colour"),
    WARMTH("warmth", "Warmth"),
}

data class ColorUi(val gamut: Gamut, val current: CieXy?)

data class WarmthUi(val range: MirekRange, val currentMirek: Int?)

data class EffectsUi(
    /** Effect ids offered as chips (deny-listed ids already removed). Never includes "no_effect". */
    val options: List<String>,
    /** The active effect id, or null when none is running. */
    val active: String?,
    val speedAvailable: Boolean,
    /** 0..100 preview of the speed parameter (only meaningful when [speedAvailable]). */
    val speedPercent: Int,
    val colorParam: SectionUi<ColorUi>,
    val warmthParam: SectionUi<WarmthUi>,
    val paramColor: CieXy?,
    val paramMirek: Int?,
)

data class TimedUi(
    val options: List<TimedEffect>,
    val active: TimedEffect?,
    val selected: TimedEffect,
    val durationMinutes: Int,
    val durationChoices: List<Int>,
)

data class GradientUi(
    val points: List<CieXy>,
    val selectedIndex: Int,
    val maxPoints: Int,
    val modes: List<String>,
    val selectedMode: String?,
    val gamut: Gamut?,
    val dirty: Boolean,
)

data class LightDetailUiState(
    val found: Boolean,
    val key: ResourceKey?,
    val name: String,
    val isOn: Boolean,
    val brightness: Int?,
    val controlsEnabled: Boolean,
    val disabledReason: String?,
    /** Non-null only when BOTH colour and warmth are KNOWN; then one segment switches them. */
    val mode: ColorMode?,
    val color: SectionUi<ColorUi>,
    val warmth: SectionUi<WarmthUi>,
    val effects: SectionUi<EffectsUi>,
    val timed: SectionUi<TimedUi>,
    val gradient: SectionUi<GradientUi>,
    val showPhotosensitivityNotice: Boolean,
    val hardwareUnverified: Boolean,
    val strip: List<ConnectionRowUi>,
) {
    val target: TargetRef.Live? get() = key?.let { TargetRef.Live(it) }

    companion object {
        fun missing(strip: List<ConnectionRowUi>): LightDetailUiState = LightDetailUiState(
            found = false, key = null, name = "Light", isOn = false, brightness = null,
            controlsEnabled = false, disabledReason = null, mode = null,
            color = SectionUi.Hidden, warmth = SectionUi.Hidden, effects = SectionUi.Hidden,
            timed = SectionUi.Hidden, gradient = SectionUi.Hidden,
            showPhotosensitivityNotice = false, hardwareUnverified = false, strip = strip,
        )
    }
}

/** Local, unsent edit drafts the ViewModel layers over the snapshot. */
data class LightEdits(
    val modeOverride: ColorMode? = null,
    val effectSpeedPercent: Int = 50,
    val effectColor: CieXy? = null,
    val effectMirek: Int? = null,
    val timedSelection: TimedEffect? = null,
    val timedDurationMinutes: Int = 30,
    val gradientDraft: List<CieXy>? = null,
    val gradientIndex: Int = 0,
    val gradientMode: String? = null,
    val noticeAcknowledged: Boolean = false,
)
