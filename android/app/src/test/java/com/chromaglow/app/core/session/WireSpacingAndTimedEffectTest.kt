package com.chromaglow.app.core.session

import com.chromaglow.app.core.hue.capability.CieXy
import com.chromaglow.app.core.identity.ResourceId
import com.chromaglow.app.core.session.safety.DefaultRiseLedger
import com.chromaglow.app.testing.AlwaysEmitLedger
import com.chromaglow.app.testing.CoordinatorHarness
import com.chromaglow.app.testing.SpyLedger
import com.chromaglow.app.testing.WireRecord
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.pow

/**
 * The viewer-side oracle: an INDEPENDENT transcription of the WCAG rule applied to the recorded
 * wire (bodies + virtual timestamps). It shares no code with DefaultFlashSafety or the ledger.
 * A breach control (a ledger that always emits) proves the oracle can fail.
 */
class WireSpacingAndTimedEffectTest {

    private object ViewerOracle {
        private const val PERIOD_MS = 340L
        private const val RISE = 0.10

        // Separate transcription: L* cube and the sRGB luminance row, written independently.
        private fun dimmingToY(percent: Double): Double {
            if (percent <= 0.0) return 0.0
            val l = (percent / 100.0).coerceIn(0.0, 1.0)
            return ((100.0 * l + 16.0) / 116.0).pow(3).coerceIn(0.0, 1.0)
        }

        private fun chromaFactor(x: Double, y: Double): Double {
            if (y <= 0.0) return 0.0
            val X = x / y
            val Z = (1 - x - y) / y
            var r = 3.2404542 * X - 1.5371385 - 0.4985314 * Z
            var g = -0.9692660 * X + 1.8760108 + 0.0415560 * Z
            var b = 0.0556434 * X - 0.2040259 + 1.0572252 * Z
            r = maxOf(r, 0.0); g = maxOf(g, 0.0); b = maxOf(b, 0.0)
            val peak = maxOf(r, g, b)
            if (peak <= 0.0) return 0.0
            return 0.2126 * r / peak + 0.7152 * g / peak + 0.0722 * b / peak
        }

        data class Lamp(var on: Boolean, var percent: Double, var x: Double, var y: Double) {
            val luminance get() = if (on) chromaFactor(x, y) * dimmingToY(percent) else 0.0
        }

        /** Returns the onset times found on the wire and the minimum gap between them. */
        fun onsets(wire: List<WireRecord>, initial: Map<ResourceId, Lamp>): List<Long> {
            val lamps = initial.mapValues { it.value.copy() }.toMutableMap()
            val trough = lamps.mapValues { it.value.luminance }.toMutableMap()
            val onsets = mutableListOf<Long>()
            for (w in wire.filter { it.method == "PUT" && it.body != null }) {
                val lamp = lamps[w.id!!] ?: continue
                val body = w.body!!
                (body["on"] as? JsonObject)?.let { (it["on"] as? JsonPrimitive)?.booleanOrNull?.let { on -> lamp.on = on } }
                (body["dimming"] as? JsonObject)?.let { (it["brightness"] as? JsonPrimitive)?.doubleOrNull?.let { p -> lamp.percent = p } }
                ((body["color"] as? JsonObject)?.get("xy") as? JsonObject)?.let { xy ->
                    lamp.x = (xy["x"] as JsonPrimitive).doubleOrNull ?: lamp.x
                    lamp.y = (xy["y"] as JsonPrimitive).doubleOrNull ?: lamp.y
                }
                val lum = lamp.luminance
                val t = trough.getValue(w.id)
                if (lum - t >= RISE - 1e-9) {
                    onsets += w.atMillis!!
                    trough[w.id] = lum
                } else {
                    trough[w.id] = minOf(t, lum)
                }
            }
            return onsets
        }

        fun minGap(onsets: List<Long>): Long? = onsets.zipWithNext { a, b -> b - a }.minOrNull()

        fun violates(onsets: List<Long>): Boolean = (minGap(onsets) ?: Long.MAX_VALUE) < PERIOD_MS

        fun initial(h: CoordinatorHarness): Map<ResourceId, Lamp> = h.store.value.lights.values.associate {
            it.key.id to Lamp(it.isOn, it.brightness ?: 100.0, it.color?.x ?: 0.3127, it.color?.y ?: 0.3290)
        }
    }

    /**
     * A hostile script across three lamps: a fast phase (a new full-scale value every 20 ms, which
     * latest-wins mostly collapses) and a 200 ms phase (each step lands, and 200 ms is inside the
     * 340 ms period, so only the ledger can keep the realized onsets apart).
     */
    private suspend fun TestScope.flashStorm(h: CoordinatorHarness) {
        val lamps = listOf(h.colorLamp, h.ctLamp, h.whiteLamp)
        repeat(60) { i ->
            h.coordinator.submit(LiveMutation.SetBrightness(lamps[i % lamps.size], if (i % 2 == 0) 100 else 1))
            advanceTimeBy(20)
        }
        repeat(30) { i ->
            h.coordinator.submit(LiveMutation.SetBrightness(lamps[i % lamps.size], if (i % 2 == 0) 100 else 1))
            advanceTimeBy(200)
        }
    }

    private fun CoordinatorHarness.startDim(): Map<ResourceId, ViewerOracle.Lamp> {
        store.update { s -> s.copy(lights = s.lights.mapValues { it.value.copy(isOn = true, brightness = 1.0) }) }
        return ViewerOracle.initial(this)
    }

    @Test
    fun theProductionLedger_neverRealizesTwoOnsetsCloserThanThePeriod_onAHostileScript() = runTest {
        val h = CoordinatorHarness(this)
        val dim = h.startDim()
        flashStorm(h)
        advanceTimeBy(30_000)
        advanceUntilIdle()
        val onsets = ViewerOracle.onsets(h.transport.wire, dim)
        assertTrue("the script must produce onsets for the oracle to judge (${onsets.size})", onsets.size >= 3)
        assertTrue("min gap ${ViewerOracle.minGap(onsets)} ms", !ViewerOracle.violates(onsets))
        assertTrue(h.transport.putCount >= 2)
    }

    @Test
    fun breachControl_aLedgerWithNoSafety_isCaughtByTheOracle() = runTest {
        val h = CoordinatorHarness(this, ledgerFactory = { AlwaysEmitLedger() })
        val dim = h.startDim()
        flashStorm(h)
        advanceTimeBy(30_000)
        advanceUntilIdle()
        val onsets = ViewerOracle.onsets(h.transport.wire, dim)
        assertTrue("with only 100 ms pacing the oracle must see a violation", ViewerOracle.violates(onsets))
    }

    @Test
    fun timedEffect_isExactlyOnePut_withTheGoldenBody_noAppFrames_andTheLedgerSeesOneWrite() = runTest {
        val spy = SpyLedger(DefaultRiseLedger(com.chromaglow.app.core.identity.BridgeId("001788FFFE112233")))
        val h = CoordinatorHarness(this, ledgerFactory = { spy })
        val outcome = h.coordinator.submit(LiveMutation.StartTimedEffect(h.colorLamp, TimedEffect.SUNRISE, 900_000L))
        assertTrue(outcome is MutationOutcome.Accepted)
        advanceTimeBy(60_000)
        advanceUntilIdle()
        val puts = h.transport.puts()
        assertEquals(1, puts.size)
        assertEquals("""{"timed_effects":{"effect":"sunrise","duration":900000},"effects":{"effect":"no_effect"}}""", puts.single().body.toString())
        assertEquals(1, spy.admits)
        assertEquals("sunrise", h.light(h.colorLamp).activeTimedEffect)
        // Cancel is one more PUT, nothing in between.
        h.coordinator.submit(LiveMutation.CancelTimedEffect(h.colorLamp))
        advanceUntilIdle()
        assertEquals(2, h.transport.puts().size)
        assertEquals("""{"timed_effects":{"effect":"no_effect"}}""", h.transport.puts()[1].body.toString())
    }

    @Test
    fun gradientEdit_passesThroughTheLedgerLikeAnyStaticWrite() = runTest {
        val h = CoordinatorHarness(this)
        h.store.update { s -> s.copy(lights = s.lights.mapValues { it.value.copy(isOn = false) }) }
        h.coordinator.submit(LiveMutation.SetPower(h.stripLamp, true))
        h.coordinator.submit(LiveMutation.SetGradient(h.stripLamp, listOf(CieXy(0.64, 0.33), CieXy(0.17, 0.7)), "interpolated_palette"))
        h.coordinator.submit(LiveMutation.SetPower(h.colorLamp, true))
        advanceUntilIdle()
        val puts = h.transport.puts()
        assertEquals(3, puts.size)
        // The power-on rise on the second lamp waits the whole period behind the first rise.
        assertTrue(puts.last().atMillis!! - puts.first().atMillis!! >= 340)
    }
}
