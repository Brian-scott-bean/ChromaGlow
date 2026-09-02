package com.chromaglow.app.core.session.safety

import com.chromaglow.app.core.hue.capability.CieXy

/**
 * The established ChromaGlow realized-output semantics, frozen as constants for the Android port.
 * These mirror `BeatMath.FlashSafety` on iOS and are pinned by test; the port must prove
 * equivalence against exported iOS vectors rather than assume it.
 */
object FlashSafetyConstants {
    /** Minimum realized onset-to-onset spacing on one bridge: 17 × 20 ms. */
    const val MIN_ONSET_PERIOD_MILLIS: Long = 340L

    /** A rise of at least this much relative luminance above the trough since the last onset. */
    const val ONSET_RISE_THRESHOLD: Double = 0.10

    /** A saturated-red chroma step counts as an onset at this much smaller luminance delta. */
    const val RED_STEP_LUMINANCE_DELTA: Double = 0.02

    /** Derived ceiling the invariant enforces (informational). */
    const val MAX_FLASH_HZ: Double = 3.0
}

/** What one delivered write would put on the lamp, in the units the onset rule reasons about. */
data class LuminanceFrame(
    val relativeLuminance: Double,
    val isSaturatedRed: Boolean,
) {
    init {
        require(relativeLuminance in 0.0..1.0) { "relative luminance must be in [0,1]" }
    }
}

/**
 * The luminance model seam. The implementation (P5) must reproduce the established L* → Y
 * treatment of dimming, the chromaticity luminance contribution, the ≥0.10 rise rule and the
 * saturated-red special case; an independent viewer-side oracle in tests shares no code with it.
 */
interface FlashSafety {
    fun frameFor(brightnessPercent: Double?, isOn: Boolean, xy: CieXy?): LuminanceFrame

    fun isOnset(previous: LuminanceFrame?, troughSinceLastOnset: Double, next: LuminanceFrame): Boolean
}
