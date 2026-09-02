package com.chromaglow.app.core.session.safety

import com.chromaglow.app.core.hue.capability.CieXy
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * Faithful port of the established iOS `BeatMath.FlashSafety` luminance semantics
 * (HueHome/Core/Audio/BeatBinding.swift). Every function is pure and total.
 *
 *  - Hue `brightness` is a perceptual L*-like dimming level, not luminance:
 *    `Y = ((100·bri + 16) / 116)³`, clamped to [0,1], and EXACTLY 0 at dimming 0 ("off is off").
 *  - Chromaticity contributes a luminance factor: xy → XYZ (Y=1) → linear sRGB, negatives
 *    clipped, normalised so the peak channel is 1, then `0.2126 R + 0.7152 G + 0.0722 B`.
 *    D65 white ≈ 1.0, saturated blue ≈ 0.0722, saturated red ≈ 0.2126.
 *  - A frame's relative luminance is `chromaFactor × dimmingLuminance`.
 *  - Saturated red: ≥ 80 % of the linear drive is in the red channel.
 *  - Onset rule 1: a rise of ≥ 0.10 relative luminance above the trough since the last onset.
 *  - Onset rule 2 (WCAG red flash): a chromaticity step to or from saturated red with a
 *    luminance change of ≥ 0.02 in either direction.
 *
 * The frozen [LuminanceFrame] carries no chromaticity, so rule 2's "chromaticity step" test is
 * approximated conservatively: any pair where either side is saturated red is treated as a
 * chromaticity step (a red↔non-red pair always is; red↔red is over-approximated, which only
 * adds holds, never removes one). Equivalence to iOS is proven against exported vectors for
 * every case the frame can express.
 */
object DefaultFlashSafety : FlashSafety {

    private const val TOLERANCE = 1e-9
    private const val SATURATED_RED_FRACTION = 0.8
    private const val D65_X = 0.3127
    private const val D65_Y = 0.3290

    /** CIE L* → Y cube approximation; 0 when off; total. */
    fun dimmingLuminance(brightness: Double): Double {
        if (!brightness.isFinite() || brightness <= 0.0) return 0.0
        val l = min(max(brightness, 0.0), 1.0)
        val v = (100.0 * l + 16.0) / 116.0
        return min(1.0, max(0.0, v * v * v))
    }

    /** Linear RGB drive normalised to peak 1 (all zero for a degenerate chromaticity). */
    fun linearRgb(x: Double, y: Double): DoubleArray {
        if (!x.isFinite() || !y.isFinite() || y <= 0.0) return doubleArrayOf(0.0, 0.0, 0.0)
        val bigX = x / y
        val bigZ = (1.0 - x - y) / y
        var r = 3.2404542 * bigX - 1.5371385 - 0.4985314 * bigZ
        var g = -0.9692660 * bigX + 1.8760108 + 0.0415560 * bigZ
        var b = 0.0556434 * bigX - 0.2040259 + 1.0572252 * bigZ
        r = max(r, 0.0); g = max(g, 0.0); b = max(b, 0.0)
        val peak = max(r, max(g, b))
        if (peak <= 0.0 || !peak.isFinite()) return doubleArrayOf(0.0, 0.0, 0.0)
        return doubleArrayOf(r / peak, g / peak, b / peak)
    }

    fun chromaticityLuminanceFactor(x: Double, y: Double): Double {
        val c = linearRgb(x, y)
        return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
    }

    fun redDriveFraction(x: Double, y: Double): Double {
        val c = linearRgb(x, y)
        val sum = c[0] + c[1] + c[2]
        return if (sum > 0.0) c[0] / sum else 0.0
    }

    fun isSaturatedRed(x: Double, y: Double): Boolean =
        redDriveFraction(x, y) >= SATURATED_RED_FRACTION - TOLERANCE

    /** Relative luminance of a wire frame given as (xy, dimming 0…1); the iOS `WireFrame.relativeLuminance`. */
    fun relativeLuminance(x: Double, y: Double, brightness: Double): Double {
        val fx = if (x.isFinite()) x else D65_X
        val fy = if (y.isFinite()) y else D65_Y
        return chromaticityLuminanceFactor(fx, fy) * dimmingLuminance(brightness)
    }

    /** CIE xy Euclidean distance (the iOS palette-step measure; exposed for the oracle tests). */
    fun chromaDistance(ax: Double, ay: Double, bx: Double, by: Double): Double {
        val dx = ax - bx
        val dy = ay - by
        return sqrt(dx * dx + dy * dy)
    }

    override fun frameFor(brightnessPercent: Double?, isOn: Boolean, xy: CieXy?): LuminanceFrame {
        if (!isOn) return LuminanceFrame(0.0, isSaturatedRed = xy?.let { isSaturatedRed(it.x, it.y) } ?: false)
        val dimming = (brightnessPercent ?: 100.0).let { if (it.isFinite()) it / 100.0 else 0.0 }
        // No chromaticity (white-only or CT-mode lamp) is treated as D65 white: the maximum
        // luminance factor, i.e. the conservative direction.
        val x = xy?.x ?: D65_X
        val y = xy?.y ?: D65_Y
        return LuminanceFrame(
            relativeLuminance = min(1.0, max(0.0, relativeLuminance(x, y, dimming))),
            isSaturatedRed = isSaturatedRed(x, y),
        )
    }

    override fun isOnset(previous: LuminanceFrame?, troughSinceLastOnset: Double, next: LuminanceFrame): Boolean {
        val luminance = next.relativeLuminance
        if (previous == null) {
            // Cold: the unknown prior wire reads as black, so an absolute luminance at or above
            // the threshold is a rise out of black (iOS `isColdOnsetCandidate`, first branch).
            return luminance >= FlashSafetyConstants.ONSET_RISE_THRESHOLD - TOLERANCE
        }
        if (luminance - troughSinceLastOnset >= FlashSafetyConstants.ONSET_RISE_THRESHOLD - TOLERANCE) return true
        if (!(next.isSaturatedRed || previous.isSaturatedRed)) return false
        return abs(luminance - previous.relativeLuminance) >= FlashSafetyConstants.RED_STEP_LUMINANCE_DELTA - TOLERANCE
    }
}
