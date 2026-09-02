package com.chromaglow.app.core.session

import com.chromaglow.app.core.hue.capability.CieXy
import com.chromaglow.app.core.identity.BridgeId
import com.chromaglow.app.core.identity.TargetRef

/**
 * The UI-facing command contract. Implemented once by the demo shell (in-memory) and once by the
 * live layer (routing to MutationCoordinator via LiveHome). Feature screens and ViewModels depend
 * on this and on snapshots ONLY — never on transport types. Every target is a [TargetRef], never a
 * bare resource id. Commands are fire-and-forget; outcomes surface through state.
 */
interface HomeCommands {
    fun setGroupPower(target: TargetRef, on: Boolean)

    fun setGroupBrightness(target: TargetRef, percent: Int)

    fun setLightPower(target: TargetRef, on: Boolean)

    fun setLightBrightness(target: TargetRef, percent: Int)

    fun setLightColor(target: TargetRef, xy: CieXy)

    fun setLightColorTemperature(target: TargetRef, mirek: Int)

    fun selectEffect(target: TargetRef, effect: String, parameters: EffectParameters)

    fun stopEffect(target: TargetRef)

    fun startTimedEffect(target: TargetRef, effect: TimedEffect, durationMillis: Long)

    fun cancelTimedEffect(target: TargetRef)

    fun setGradient(target: TargetRef, points: List<CieXy>, mode: String?)

    fun activateScene(target: TargetRef)

    fun refresh(reason: RefreshReason)
}

/** Shell-boundary commands (owned by the app shell, not by feature screens). */
interface SessionShellCommands {
    /** Local-only Forget: tears down the session, then deletes token and record. */
    fun forgetBridge(bridgeId: BridgeId)

    fun exitToSetup()
}

enum class RefreshReason { SESSION_START, FOREGROUND, POST_MUTATION, STREAM_RECONNECTED, USER_PULL }
