package com.chromaglow.app.feature.lightdetail

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.chromaglow.app.core.hue.capability.CieXy
import com.chromaglow.app.core.identity.ResourceKey
import com.chromaglow.app.core.session.EffectParameters
import com.chromaglow.app.core.session.HomeCommands
import com.chromaglow.app.core.session.LiveHome
import com.chromaglow.app.core.session.TimedEffect
import com.chromaglow.app.core.session.safety.DefaultEffectSafetyRegister
import com.chromaglow.app.core.session.safety.EffectSafetyRegister
import com.chromaglow.app.ui.components.ColorMath
import com.chromaglow.app.ui.components.MutationFeedbackController
import com.chromaglow.app.ui.components.MutationFeedbackUi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update

/**
 * Light detail presentation. Every outbound intent is checked against the CURRENT mapped state
 * before it is forwarded: a section that is not [SectionUi.Ready], or a screen whose connection
 * disables controls, never produces a command. Values are clamped to the lamp's own truth
 * (gamut, mirek schema, points_capable) here, and the coordinator re-validates.
 */
class LightDetailViewModel(
    private val liveHome: LiveHome,
    private val commands: HomeCommands,
    val lightKey: ResourceKey,
    private val register: EffectSafetyRegister = DefaultEffectSafetyRegister,
    /** Durable store injected by the shell; the in-memory default keeps un-wired callers honest. */
    private val noticeStore: NoticeAcknowledgementStore = InMemoryNoticeAcknowledgementStore(),
    private val clock: () -> Long = { System.currentTimeMillis() },
) : ViewModel() {

    private val edits = MutableStateFlow(LightEdits(noticeAcknowledged = noticeStore.isAcknowledged()))

    val uiState: StateFlow<LightDetailUiState> = combine(liveHome.home, edits, liveHome.bridgeNames) { home, e, names ->
        LightDetailUiMapper.map(home, lightKey, e, register, clock(), names)
    }.stateIn(
        scope = viewModelScope,
        started = SharingStarted.WhileSubscribed(5_000),
        initialValue = LightDetailUiMapper.map(liveHome.home.value, lightKey, edits.value, register, clock(), liveHome.bridgeNames.value),
    )

    private val feedbackController = MutationFeedbackController(
        scope = viewModelScope,
        events = liveHome.mutationEvents,
        isRelevant = { it.target == lightKey },
        nameOf = { key -> liveHome.home.value.bridges[key.bridgeId]?.lights?.get(key)?.name },
    )

    val feedback: StateFlow<MutationFeedbackUi?> = feedbackController.feedback

    fun dismissFeedback(shown: MutationFeedbackUi) = feedbackController.dismiss(shown)

    /**
     * The state as of RIGHT NOW, computed from the sources rather than read from [uiState]:
     * a `stateIn` flow only recomputes while collected, so a guard that read `uiState.value`
     * straight after an edit could act on a stale mapping.
     */
    private fun current(): LightDetailUiState =
        LightDetailUiMapper.map(liveHome.home.value, lightKey, edits.value, register, clock(), liveHome.bridgeNames.value)

    private inline fun whenLive(block: (LightDetailUiState, com.chromaglow.app.core.identity.TargetRef.Live) -> Unit) {
        val s = current()
        val target = s.target ?: return
        if (!s.controlsEnabled) return
        block(s, target)
    }

    fun setPower(on: Boolean) = whenLive { _, t -> commands.setLightPower(t, on) }

    fun setBrightness(percent: Int) = whenLive { _, t -> commands.setLightBrightness(t, percent.coerceIn(1, 100)) }

    fun selectMode(mode: ColorMode) {
        if (current().mode == null) return
        edits.update { it.copy(modeOverride = mode) }
    }

    fun setColor(xy: CieXy) = whenLive { s, t ->
        val ready = s.color as? SectionUi.Ready ?: return@whenLive
        commands.setLightColor(t, ColorMath.clampToGamut(xy, ready.value.gamut))
        edits.update { it.copy(modeOverride = if (s.mode != null) ColorMode.COLOR else it.modeOverride) }
    }

    fun setMirek(mirek: Int) = whenLive { s, t ->
        val ready = s.warmth as? SectionUi.Ready ?: return@whenLive
        commands.setLightColorTemperature(t, ready.value.range.clamp(mirek))
        edits.update { it.copy(modeOverride = if (s.mode != null) ColorMode.WARMTH else it.modeOverride) }
    }

    /** [effectId] null or "no_effect" stops; anything else must be an offered (non-denied) chip. */
    fun selectEffect(effectId: String?) = whenLive { s, t ->
        val ready = s.effects as? SectionUi.Ready ?: return@whenLive
        if (effectId == null || effectId == LightDetailUiMapper.NO_EFFECT) {
            commands.stopEffect(t)
            return@whenLive
        }
        if (effectId !in ready.value.options || register.isDenied(effectId)) return@whenLive
        commands.selectEffect(t, effectId, parameters(ready.value))
    }

    fun setEffectSpeed(percent: Int) {
        edits.update { it.copy(effectSpeedPercent = percent.coerceIn(0, 100)) }
        resendActiveEffect()
    }

    fun setEffectColor(xy: CieXy) {
        val ready = current().effects as? SectionUi.Ready ?: return
        val gamut = (ready.value.colorParam as? SectionUi.Ready)?.value?.gamut ?: return
        edits.update { it.copy(effectColor = ColorMath.clampToGamut(xy, gamut)) }
        resendActiveEffect()
    }

    fun setEffectMirek(mirek: Int) {
        val ready = current().effects as? SectionUi.Ready ?: return
        val range = (ready.value.warmthParam as? SectionUi.Ready)?.value?.range ?: return
        edits.update { it.copy(effectMirek = range.clamp(mirek)) }
        resendActiveEffect()
    }

    private fun resendActiveEffect() = whenLive { s, t ->
        val ready = s.effects as? SectionUi.Ready ?: return@whenLive
        val active = ready.value.active ?: return@whenLive
        if (register.isDenied(active) || active !in ready.value.options) return@whenLive
        commands.selectEffect(t, active, parameters(ready.value))
    }

    private fun parameters(ui: EffectsUi): EffectParameters = EffectParameters(
        speed = if (ui.speedAvailable) ui.speedPercent / 100.0 else null,
        color = if (ui.colorParam is SectionUi.Ready) ui.paramColor else null,
        mirek = if (ui.warmthParam is SectionUi.Ready) ui.paramMirek else null,
    )

    fun selectTimed(effect: TimedEffect) {
        edits.update { it.copy(timedSelection = effect) }
    }

    fun setTimedDuration(minutes: Int) {
        if (minutes !in LightDetailUiMapper.DURATION_CHOICES_MINUTES) return
        edits.update { it.copy(timedDurationMinutes = minutes) }
    }

    fun startTimed() = whenLive { s, t ->
        val ready = s.timed as? SectionUi.Ready ?: return@whenLive
        val effect = ready.value.selected
        if (effect !in ready.value.options) return@whenLive
        commands.startTimedEffect(t, effect, ready.value.durationMinutes * 60_000L)
    }

    fun cancelTimed() = whenLive { s, t ->
        if (s.timed !is SectionUi.Ready) return@whenLive
        commands.cancelTimedEffect(t)
    }

    fun selectGradientPoint(index: Int) {
        val ready = current().gradient as? SectionUi.Ready ?: return
        edits.update { it.copy(gradientIndex = index.coerceIn(0, ready.value.points.lastIndex)) }
    }

    fun setGradientPointColor(xy: CieXy) {
        val ready = current().gradient as? SectionUi.Ready ?: return
        val g = ready.value
        val clamped = g.gamut?.let { ColorMath.clampToGamut(xy, it) } ?: xy
        val draft = g.points.toMutableList().also { it[g.selectedIndex] = clamped }
        edits.update { it.copy(gradientDraft = draft) }
    }

    fun selectGradientMode(mode: String) {
        val ready = current().gradient as? SectionUi.Ready ?: return
        if (mode !in ready.value.modes) return
        edits.update { it.copy(gradientMode = mode) }
    }

    fun applyGradient() = whenLive { s, t ->
        val ready = s.gradient as? SectionUi.Ready ?: return@whenLive
        val g = ready.value
        commands.setGradient(t, g.points.take(g.maxPoints), g.selectedMode)
        edits.update { it.copy(gradientDraft = null) }
    }

    fun acknowledgeNotice() {
        noticeStore.acknowledge()
        edits.update { it.copy(noticeAcknowledged = true) }
    }
}
