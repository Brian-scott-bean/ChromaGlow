package com.chromaglow.app.feature.lightdetail

import com.chromaglow.app.core.hue.capability.Capability
import com.chromaglow.app.core.hue.capability.CieXy
import com.chromaglow.app.core.hue.capability.Evidence
import com.chromaglow.app.core.identity.ResourceKey
import com.chromaglow.app.core.session.ConnectionState
import com.chromaglow.app.core.session.HomeSnapshot
import com.chromaglow.app.core.session.LightState
import com.chromaglow.app.core.session.LiveMutation
import com.chromaglow.app.core.session.TimedEffect
import com.chromaglow.app.core.session.safety.EffectSafetyRegister
import com.chromaglow.app.feature.home.HomeUiMapper
import kotlin.math.roundToInt

/**
 * Pure snapshot + edits → Light detail UI. Every section obeys the evidence rule through
 * [section]; deny-listed effects are removed before they can render; gradient point count is
 * min(points_capable, protocol cap) and never a constant.
 */
object LightDetailUiMapper {

    const val NO_EFFECT: String = "no_effect"
    val DURATION_CHOICES_MINUTES: List<Int> = listOf(15, 30, 60)
    private val DEFAULT_POINT = CieXy(0.4578, 0.4101)

    fun map(
        home: HomeSnapshot,
        lightKey: ResourceKey,
        edits: LightEdits,
        register: EffectSafetyRegister,
        nowMillis: Long,
    ): LightDetailUiState {
        val connection = home.connections[lightKey.bridgeId] ?: ConnectionState.Connecting
        val strip = listOf(HomeUiMapper.connectionRow(lightKey.bridgeId, connection, nowMillis, home.bridges.size > 1))
        val light = home.bridges[lightKey.bridgeId]?.lights?.get(lightKey)
            ?: return LightDetailUiState.missing(strip)
        val (enabled, reason) = HomeUiMapper.interaction(connection)
        val caps = light.capabilities

        val color = section(caps.color) { ColorUi(it, light.color) }
        val warmth = section(caps.colorTemperature) { WarmthUi(it, if (light.mirekValid == true) light.mirek else null) }
        val mode = if (color is SectionUi.Ready && warmth is SectionUi.Ready) {
            edits.modeOverride ?: if (light.mirekValid == true && light.mirek != null) ColorMode.WARMTH else ColorMode.COLOR
        } else {
            null
        }

        val effects = effectsSection(light, edits, register, color, warmth)
        val timed = section(caps.timedEffects) { values ->
            val options = TimedEffect.entries.filter { it.wireName in values }
            TimedUi(
                options = options,
                active = TimedEffect.entries.firstOrNull { it.wireName == light.activeTimedEffect },
                selected = edits.timedSelection?.takeIf { it in options } ?: options.firstOrNull() ?: TimedEffect.SUNRISE,
                durationMinutes = edits.timedDurationMinutes,
                durationChoices = DURATION_CHOICES_MINUTES,
            )
        }.let { if (it is SectionUi.Ready && it.value.options.isEmpty()) SectionUi.Hidden else it }

        val gradient = section(caps.gradient) { g ->
            if (!g.supportsGradient) return@section null
            val max = minOf(g.pointsCapable, LiveMutation.MAX_GRADIENT_POINTS)
            val base = edits.gradientDraft ?: light.gradientPoints
            val points = padPoints(base, max)
            GradientUi(
                points = points,
                selectedIndex = edits.gradientIndex.coerceIn(0, points.lastIndex),
                maxPoints = max,
                modes = g.modes.sorted(),
                selectedMode = edits.gradientMode?.takeIf { it in g.modes } ?: g.modes.sorted().firstOrNull(),
                gamut = caps.color.value,
                dirty = edits.gradientDraft != null && edits.gradientDraft != light.gradientPoints,
            )
        }

        return LightDetailUiState(
            found = true,
            key = light.key,
            name = light.name,
            isOn = light.isOn,
            brightness = light.brightness?.roundToInt()?.coerceIn(1, 100),
            controlsEnabled = enabled,
            disabledReason = if (enabled) null else reason,
            mode = mode,
            color = color,
            warmth = warmth,
            effects = effects,
            timed = timed,
            gradient = gradient,
            showPhotosensitivityNotice = effects is SectionUi.Ready && !edits.noticeAcknowledged,
            hardwareUnverified = true,
            strip = strip,
        )
    }

    private fun effectsSection(
        light: LightState,
        edits: LightEdits,
        register: EffectSafetyRegister,
        color: SectionUi<ColorUi>,
        warmth: SectionUi<WarmthUi>,
    ): SectionUi<EffectsUi> {
        val caps = light.capabilities
        return section(caps.effectValues) { values ->
            val options = values.filter { it != NO_EFFECT && !register.isDenied(it) }.sorted()
            if (options.isEmpty()) return@section null
            val v2 = caps.effectsV2.isInteractive
            val active = light.activeEffect?.takeIf { it != NO_EFFECT && !register.isDenied(it) }
            EffectsUi(
                options = options,
                active = active,
                speedAvailable = v2,
                speedPercent = edits.effectSpeedPercent.coerceIn(0, 100),
                colorParam = if (v2) color else SectionUi.Hidden,
                warmthParam = if (v2) warmth else SectionUi.Hidden,
                paramColor = edits.effectColor,
                paramMirek = edits.effectMirek,
            )
        }
    }

    /**
     * KNOWN → Ready (or Hidden when [build] declines, e.g. an empty list or points_capable < 2);
     * UNKNOWN/UNREADABLE → Checking; ABSENT/UNSUPPORTED → Hidden.
     */
    fun <T, R> section(capability: Capability<T>, build: (T) -> R?): SectionUi<R> = when (capability.evidence) {
        Evidence.KNOWN -> build(capability.value!!)?.let { SectionUi.Ready(it) } ?: SectionUi.Hidden
        Evidence.UNKNOWN, Evidence.UNREADABLE -> SectionUi.Checking
        Evidence.ABSENT, Evidence.UNSUPPORTED -> SectionUi.Hidden
    }

    fun padPoints(base: List<CieXy>, max: Int): List<CieXy> {
        val trimmed = base.take(max)
        if (trimmed.size >= max) return trimmed
        val filler = trimmed.lastOrNull() ?: DEFAULT_POINT
        return trimmed + List(max - trimmed.size) { filler }
    }
}
