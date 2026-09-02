package com.chromaglow.app.core.session.safety

import com.chromaglow.app.core.hue.capability.CieXy
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Replays the iOS-exported vectors (see src/test/resources/safety/README.md) against the port. */
class FlashSafetyEquivalenceTest {

    private val vectors: JsonObject by lazy {
        Json.parseToJsonElement(javaClass.classLoader!!.getResource("safety/flash_safety_vectors.json")!!.readText()).jsonObject
    }

    private fun JsonObject.num(name: String): Double =
        this[name]!!.let { if (it is JsonNull) Double.NaN else it.jsonPrimitive.double }

    @Test
    fun constants_matchTheIosConstants() {
        val c = vectors["constants"]!!.jsonObject
        assertEquals(FlashSafetyConstants.ONSET_RISE_THRESHOLD, c.num("onsetRiseThreshold"), 0.0)
        assertEquals(FlashSafetyConstants.RED_STEP_LUMINANCE_DELTA, c.num("redFlashLuminanceDelta"), 0.0)
        assertEquals(0.8, c.num("saturatedRedFraction"), 0.0)
    }

    @Test
    fun luminance_redFraction_chromaFactor_andSaturatedRed_agreeToOneEMinusTwelve() {
        val rows = vectors["luminance"]!!.jsonArray
        assertTrue(rows.size >= 400)
        for (row in rows) {
            val r = row.jsonObject
            val x = r.num("x"); val y = r.num("y"); val b = r.num("brightness")
            val label = "xy=($x,$y) b=$b"
            assertEquals(label, r.num("relativeLuminance"), DefaultFlashSafety.relativeLuminance(x, y, b), 1e-12)
            // Degenerate xy resolves to D65 inside the frame on iOS; the exported redFraction/
            // chromaFactor were computed on the resolved frame, so resolve the same way here.
            val fx = if (x.isFinite()) x else 0.3127
            val fy = if (y.isFinite()) y else 0.3290
            assertEquals(label, r.num("redFraction"), DefaultFlashSafety.redDriveFraction(fx, fy), 1e-12)
            assertEquals(label, r.num("chromaFactor"), DefaultFlashSafety.chromaticityLuminanceFactor(fx, fy), 1e-12)
            assertEquals(label, r["isSaturatedRed"]!!.jsonPrimitive.boolean, DefaultFlashSafety.isSaturatedRed(fx, fy))
            if (x.isFinite() && y.isFinite() && x in 0.0..1.0 && y in 0.0..1.0) {
                val frame = DefaultFlashSafety.frameFor(if (b.isFinite()) b * 100.0 else Double.NaN, true, CieXy(x, y))
                assertEquals(label, r.num("relativeLuminance"), frame.relativeLuminance, 1e-12)
            }
        }
    }

    @Test
    fun onsetVerdicts_agreeExactly_whereTheFrameCanExpressTheInput_andAreOnlyMoreConservativeElsewhere() {
        val rows = vectors["onsets"]!!.jsonArray
        var exact = 0
        var conservativeOnly = 0
        for (row in rows) {
            val r = row.jsonObject
            val expected = r["isOnset"]!!.jsonPrimitive.boolean
            val next = r["next"]!!.jsonArray.map { it.jsonPrimitive.double }
            val nextFrame = DefaultFlashSafety.frameFor(next[2] * 100.0, true, CieXy(next[0], next[1]))
            val lastRaw = r["last"]!!
            if (lastRaw is JsonNull) {
                assertEquals("cold $next", expected, DefaultFlashSafety.isOnset(null, 0.0, nextFrame))
                exact++
                continue
            }
            val last = lastRaw.jsonArray.map { it.jsonPrimitive.double }
            val lastFrame = DefaultFlashSafety.frameFor(last[2] * 100.0, true, CieXy(last[0], last[1]))
            val trough = r.num("trough")
            val actual = DefaultFlashSafety.isOnset(lastFrame, trough, nextFrame)
            val chromaStep = r["chromaStep"]!!.jsonPrimitive.boolean
            val eitherRed = r["eitherRed"]!!.jsonPrimitive.boolean
            if (chromaStep || !eitherRed) {
                assertEquals("last=$last trough=$trough next=$next", expected, actual)
                exact++
            } else {
                // red↔red without a chromaticity step: the frame carries no xy, so the port may
                // over-approximate the step; it must never admit what iOS holds.
                assertTrue("port admitted a frame iOS held: last=$last next=$next", !expected || actual)
                conservativeOnly++
            }
        }
        assertTrue(exact > 1_000)
        assertTrue(conservativeOnly < exact / 5)
    }

    @Test
    fun pinnedIosValues_holdOnThePort() {
        assertEquals(0.0, DefaultFlashSafety.dimmingLuminance(0.0), 0.0)
        assertEquals(1.0, DefaultFlashSafety.dimmingLuminance(1.0), 1e-12)
        assertEquals(0.1842, DefaultFlashSafety.dimmingLuminance(0.5), 0.0005)
        assertEquals(0.7630, DefaultFlashSafety.dimmingLuminance(0.9), 0.0005)
        assertEquals(1.000, DefaultFlashSafety.chromaticityLuminanceFactor(0.3127, 0.3290), 0.002)
        assertEquals(0.2126, DefaultFlashSafety.chromaticityLuminanceFactor(0.64, 0.33), 0.002)
        assertEquals(0.0722, DefaultFlashSafety.chromaticityLuminanceFactor(0.15, 0.06), 0.002)
        assertEquals(0.1763, DefaultFlashSafety.chromaticityLuminanceFactor(0.1548, 0.1220), 0.002)
        assertEquals(0.0, DefaultFlashSafety.chromaticityLuminanceFactor(0.3, 0.0), 0.0)
        assertEquals(0.0, DefaultFlashSafety.chromaticityLuminanceFactor(Double.NaN, Double.NaN), 0.0)
        assertTrue(DefaultFlashSafety.isSaturatedRed(0.64, 0.33))
        assertFalse(DefaultFlashSafety.isSaturatedRed(0.32, 0.15))
        // 0.901 → 1.000 dimming is a 0.235 luminance flash; blue 0.90 → white 0.85 is a 0.60 rise.
        val low = DefaultFlashSafety.frameFor(90.1, true, CieXy(0.3127, 0.3290))
        val high = DefaultFlashSafety.frameFor(100.0, true, CieXy(0.3127, 0.3290))
        assertEquals(0.2348, high.relativeLuminance - low.relativeLuminance, 0.002)
        assertTrue(DefaultFlashSafety.isOnset(low, low.relativeLuminance, high))
        val blue = DefaultFlashSafety.frameFor(90.0, true, CieXy(0.15, 0.06))
        val white = DefaultFlashSafety.frameFor(85.0, true, CieXy(0.3127, 0.3290))
        assertTrue(DefaultFlashSafety.isOnset(blue, blue.relativeLuminance, white))
        assertFalse("white → blue is a fall", DefaultFlashSafety.isOnset(white, white.relativeLuminance, blue))
        // off is off; a missing chromaticity is judged as white (the conservative direction).
        assertEquals(0.0, DefaultFlashSafety.frameFor(100.0, false, null).relativeLuminance, 0.0)
        assertEquals(high.relativeLuminance, DefaultFlashSafety.frameFor(100.0, true, null).relativeLuminance, 1e-12)
    }
}
