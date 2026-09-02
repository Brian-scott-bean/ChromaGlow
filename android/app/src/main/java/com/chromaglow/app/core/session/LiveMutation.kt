package com.chromaglow.app.core.session

import com.chromaglow.app.core.hue.capability.CieXy
import com.chromaglow.app.core.identity.ResourceKey

/**
 * The field a mutation touches. Pending-authority fences are keyed by (ResourceKey, FieldGroup)
 * so a pending brightness never suppresses an unrelated colour event, and a pending effect never
 * suppresses an on/off event.
 */
enum class FieldGroup { POWER, DIMMING, COLOR, COLOR_TEMPERATURE, EFFECT, TIMED_EFFECT, GRADIENT, SCENE }

/** Optional effects_v2 parameters. Each is sent only when the lamp's matching capability is Known. */
data class EffectParameters(
    val speed: Double? = null,
    val color: CieXy? = null,
    val mirek: Int? = null,
) {
    init {
        speed?.let { require(it in 0.0..1.0) { "speed must be in [0,1]" } }
    }
}

enum class TimedEffect(val wireName: String) { SUNRISE("sunrise"), SUNSET("sunset") }

/**
 * Every outbound Hue state change the approved slice can request. There is deliberately NO
 * signaling variant: signaling is decode-only in this slice. All variants are bridge-qualified
 * through [target]; the coordinator routes by `target.bridgeId`.
 */
sealed interface LiveMutation {
    val target: ResourceKey
    val field: FieldGroup

    data class SetPower(override val target: ResourceKey, val on: Boolean) : LiveMutation {
        override val field: FieldGroup get() = FieldGroup.POWER
    }

    data class SetBrightness(override val target: ResourceKey, val percent: Int) : LiveMutation {
        init { require(percent in 1..100) { "brightness must be 1..100" } }
        override val field: FieldGroup get() = FieldGroup.DIMMING
    }

    data class SetColor(override val target: ResourceKey, val xy: CieXy) : LiveMutation {
        override val field: FieldGroup get() = FieldGroup.COLOR
    }

    data class SetColorTemperature(override val target: ResourceKey, val mirek: Int) : LiveMutation {
        override val field: FieldGroup get() = FieldGroup.COLOR_TEMPERATURE
    }

    data class SelectEffect(
        override val target: ResourceKey,
        val effect: String,
        val parameters: EffectParameters = EffectParameters(),
    ) : LiveMutation {
        init { require(effect.isNotBlank()) { "effect must not be blank" } }
        override val field: FieldGroup get() = FieldGroup.EFFECT
    }

    data class StopEffect(override val target: ResourceKey) : LiveMutation {
        override val field: FieldGroup get() = FieldGroup.EFFECT
    }

    data class StartTimedEffect(
        override val target: ResourceKey,
        val effect: TimedEffect,
        val durationMillis: Long,
    ) : LiveMutation {
        init { require(durationMillis in 0..MAX_TIMED_EFFECT_MILLIS) { "duration out of bounds" } }
        override val field: FieldGroup get() = FieldGroup.TIMED_EFFECT
    }

    data class CancelTimedEffect(override val target: ResourceKey) : LiveMutation {
        override val field: FieldGroup get() = FieldGroup.TIMED_EFFECT
    }

    data class SetGradient(
        override val target: ResourceKey,
        val points: List<CieXy>,
        val mode: String?,
    ) : LiveMutation {
        init { require(points.size in 1..MAX_GRADIENT_POINTS) { "gradient points out of bounds" } }
        override val field: FieldGroup get() = FieldGroup.GRADIENT
    }

    data class RecallScene(override val target: ResourceKey) : LiveMutation {
        override val field: FieldGroup get() = FieldGroup.SCENE
    }

    companion object {
        /** CLIP v2 timed_effects duration cap: 6 hours. */
        const val MAX_TIMED_EFFECT_MILLIS: Long = 21_600_000L

        /** Shortest timed effect the coordinator accepts: a ramp slower than this is a long transition, not a flash (E-08). */
        const val MIN_TIMED_EFFECT_MILLIS: Long = 60_000L

        /** Protocol point cap; the per-lamp cap is min(points_capable, this). */
        const val MAX_GRADIENT_POINTS: Int = 5
    }
}

/** Why the coordinator refused a mutation before any wire activity. */
enum class RefusalReason {
    CAPABILITY_NOT_KNOWN,
    OFFLINE,
    REVOKED,
    EFFECT_DENIED_BY_SAFETY_REGISTER,
    TARGET_UNKNOWN,
    SESSION_CLOSED,

    /** A timed effect shorter than [LiveMutation.MIN_TIMED_EFFECT_MILLIS]: an instantaneous rise the ledger cannot score (E-08). */
    UNSAFE_DURATION,
}

/** An opaque handle for one accepted mutation; rollback is keyed on it, never on the target alone. */
@JvmInline
value class MutationToken(val value: Long)

/**
 * What the coordinator answers. [Accepted] means the optimistic overlay is applied and the write
 * is queued (latest-wins per field); delivery/rollback surface later through the snapshot.
 */
sealed interface MutationOutcome {
    data class Accepted(val token: MutationToken) : MutationOutcome
    data class Refused(val reason: RefusalReason) : MutationOutcome
}
