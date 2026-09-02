package com.chromaglow.app.core.hue.capability

/** Gradient facts a lamp reports. `pointsCapable < 2` is not a gradient lamp. */
data class GradientCapability(
    val pointsCapable: Int,
    val modes: Set<String>,
    val pixelCount: Int?,
) {
    init {
        require(pointsCapable >= 0) { "pointsCapable must be non-negative" }
    }

    val supportsGradient: Boolean get() = pointsCapable >= 2
}

/**
 * The complete per-light capability truth, each axis with its own evidence. Built ONLY from the
 * light resource (and its schema blocks); never from model/product names.
 *
 * `signaling` is decode-only: it is modelled so the truth is recorded, but no user-facing send
 * contract exists for it in this slice (safety-gated).
 */
data class LightCapabilities(
    val color: Capability<Gamut>,
    val colorTemperature: Capability<MirekRange>,
    val effectsV1: Capability<Set<String>>,
    val effectsV2: Capability<Set<String>>,
    val timedEffects: Capability<Set<String>>,
    val gradient: Capability<GradientCapability>,
    val signaling: Capability<Set<String>>,
    val dynamics: Capability<Unit>,
) {
    /** effects_v2 shadows v1 when present; otherwise v1 is the fallback source. */
    val effectValues: Capability<Set<String>>
        get() = if (effectsV2.isInteractive) effectsV2 else effectsV1

    companion object {
        /** The state before the light has ever been read: everything CHECKING. */
        fun unknown(): LightCapabilities = LightCapabilities(
            color = Capability.unknown(),
            colorTemperature = Capability.unknown(),
            effectsV1 = Capability.unknown(),
            effectsV2 = Capability.unknown(),
            timedEffects = Capability.unknown(),
            gradient = Capability.unknown(),
            signaling = Capability.unknown(),
            dynamics = Capability.unknown(),
        )
    }
}
