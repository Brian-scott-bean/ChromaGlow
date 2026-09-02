package com.chromaglow.app.core.session

import com.chromaglow.app.core.hue.capability.CieXy
import com.chromaglow.app.core.identity.ResourceKey
import com.chromaglow.app.core.identity.TargetRef
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

/**
 * The live implementation of the UI-facing [HomeCommands]: every command becomes exactly one
 * [LiveMutation] routed through [LiveHome.submit] (and therefore through the bridge's
 * MutationCoordinator). Demo targets are not this layer's concern and are ignored. Commands are
 * fire-and-forget; the outcome is reported to [onOutcome] for diagnostics/snackbars.
 */
class LiveHomeCommands(
    private val home: LiveHome,
    private val scope: CoroutineScope,
    private val onOutcome: (LiveMutation, MutationOutcome) -> Unit = { _, _ -> },
) : HomeCommands {

    private fun dispatch(target: TargetRef, build: (ResourceKey) -> LiveMutation?) {
        val key = (target as? TargetRef.Live)?.key ?: return
        val mutation = build(key) ?: return
        scope.launch { onOutcome(mutation, home.submit(mutation)) }
    }

    override fun setGroupPower(target: TargetRef, on: Boolean) = dispatch(target) { LiveMutation.SetPower(it, on) }

    override fun setGroupBrightness(target: TargetRef, percent: Int) = dispatch(target) { LiveMutation.SetBrightness(it, percent.coerceIn(1, 100)) }

    override fun setLightPower(target: TargetRef, on: Boolean) = dispatch(target) { LiveMutation.SetPower(it, on) }

    override fun setLightBrightness(target: TargetRef, percent: Int) = dispatch(target) { LiveMutation.SetBrightness(it, percent.coerceIn(1, 100)) }

    override fun setLightColor(target: TargetRef, xy: CieXy) = dispatch(target) { LiveMutation.SetColor(it, xy) }

    override fun setLightColorTemperature(target: TargetRef, mirek: Int) = dispatch(target) { LiveMutation.SetColorTemperature(it, mirek) }

    override fun selectEffect(target: TargetRef, effect: String, parameters: EffectParameters) =
        dispatch(target) { key -> effect.takeIf { it.isNotBlank() }?.let { LiveMutation.SelectEffect(key, it, parameters) } }

    override fun stopEffect(target: TargetRef) = dispatch(target) { LiveMutation.StopEffect(it) }

    override fun startTimedEffect(target: TargetRef, effect: TimedEffect, durationMillis: Long) =
        dispatch(target) { LiveMutation.StartTimedEffect(it, effect, durationMillis.coerceIn(LiveMutation.MIN_TIMED_EFFECT_MILLIS, LiveMutation.MAX_TIMED_EFFECT_MILLIS)) }

    override fun cancelTimedEffect(target: TargetRef) = dispatch(target) { LiveMutation.CancelTimedEffect(it) }

    override fun setGradient(target: TargetRef, points: List<CieXy>, mode: String?) =
        dispatch(target) { key -> points.take(LiveMutation.MAX_GRADIENT_POINTS).takeIf { it.isNotEmpty() }?.let { LiveMutation.SetGradient(key, it, mode) } }

    override fun activateScene(target: TargetRef) = dispatch(target) { LiveMutation.RecallScene(it) }

    override fun refresh(reason: RefreshReason) = home.requestRefresh(reason)
}
