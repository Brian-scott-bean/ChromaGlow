package com.chromaglow.app.core.session

import com.chromaglow.app.core.hue.capability.CieXy
import com.chromaglow.app.core.identity.ResourceId
import com.chromaglow.app.core.identity.ResourceKey
import com.chromaglow.app.core.identity.ResourceType
import com.chromaglow.app.testing.CoordinatorHarness
import com.chromaglow.app.testing.WireRecord
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.pow

/**
 * D-01: the viewer-side oracle extended to every write that can change a lamp's luminance —
 * grouped_light PUTs land on every member, a scene recall is the worst case (every member to
 * full white), a colour-temperature body means the lamp is white (D65), an effect or timed
 * initiation is the worst case. It shares no code with the ledger or DefaultFlashSafety.
 *
 * PRE-FIX RECORD (coordinator at 1d48c54, run 2026-09-02 before E-01/E-02/E-04/E-05/E-07 landed):
 * six of seven scripts FAILED — room+light interleave 200 ms min gap (E-02), scene/grouped-fall/scene
 * 200 ms (E-01+E-02), CT-mode stale-xy scrub 200 ms (E-04), CT-write-then-scrub 200 ms (E-04),
 * effect initiation on a dark lamp 100 ms (E-07); the scene A/B alternation as first written had no
 * fall between recalls and realized a single onset, so it was rewritten with a fall (below).
 * Only the per-light storm passed. They pass after the fixes.
 */
class ViewerOracleTest {

    object ViewerOracle {
        private const val PERIOD_MS = 340L
        private const val RISE = 0.10
        private const val D65_X = 0.3127
        private const val D65_Y = 0.3290

        private fun dimmingToY(percent: Double): Double {
            if (percent <= 0.0) return 0.0
            val l = (percent / 100.0).coerceIn(0.0, 1.0)
            return ((100.0 * l + 16.0) / 116.0).pow(3).coerceIn(0.0, 1.0)
        }

        private fun chromaFactor(x: Double, y: Double): Double {
            if (y <= 0.0) return 0.0
            val bigX = x / y
            val bigZ = (1 - x - y) / y
            var r = 3.2404542 * bigX - 1.5371385 - 0.4985314 * bigZ
            var g = -0.9692660 * bigX + 1.8760108 + 0.0415560 * bigZ
            var b = 0.0556434 * bigX - 0.2040259 + 1.0572252 * bigZ
            r = maxOf(r, 0.0); g = maxOf(g, 0.0); b = maxOf(b, 0.0)
            val peak = maxOf(r, g, b)
            if (peak <= 0.0) return 0.0
            return 0.2126 * r / peak + 0.7152 * g / peak + 0.0722 * b / peak
        }

        data class Lamp(var on: Boolean, var percent: Double, var x: Double, var y: Double, var whiteMode: Boolean) {
            val luminance: Double get() = if (!on) 0.0 else (if (whiteMode) 1.0 else chromaFactor(x, y)) * dimmingToY(percent)
        }

        class Topology(
            val lamps: Map<ResourceId, Lamp>,
            /** grouped_light id → member lamp ids */
            val groups: Map<ResourceId, List<ResourceId>>,
            /** scene id → member lamp ids of its group */
            val scenes: Map<ResourceId, List<ResourceId>>,
        )

        fun topology(h: CoordinatorHarness): Topology {
            val s = h.store.value
            val lamps = s.lights.values.associate {
                it.key.id to Lamp(it.isOn, it.brightness ?: 100.0, it.color?.x ?: D65_X, it.color?.y ?: D65_Y, whiteMode = it.color == null || it.mirekValid == true)
            }
            val groupsByKey = (s.rooms + s.zones)
            val groups = groupsByKey.values.mapNotNull { g -> g.groupedLight?.let { it.id to g.children.map { c -> c.id } } }.toMap()
            val scenes = s.scenes.values.associate { sc -> sc.key.id to (groupsByKey[sc.group]?.children?.map { it.id } ?: emptyList()) }
            return Topology(lamps, groups, scenes)
        }

        private fun applyBody(lamp: Lamp, body: JsonObject) {
            (body["on"] as? JsonObject)?.let { (it["on"] as? JsonPrimitive)?.booleanOrNull?.let { on -> lamp.on = on } }
            (body["dimming"] as? JsonObject)?.let { (it["brightness"] as? JsonPrimitive)?.doubleOrNull?.let { p -> lamp.percent = p } }
            ((body["color"] as? JsonObject)?.get("xy") as? JsonObject)?.let { xy ->
                lamp.x = (xy["x"] as JsonPrimitive).doubleOrNull ?: lamp.x
                lamp.y = (xy["y"] as JsonPrimitive).doubleOrNull ?: lamp.y
                lamp.whiteMode = false
            }
            if (body.containsKey("color_temperature")) lamp.whiteMode = true
            if (body.containsKey("effects") || body.containsKey("effects_v2") || body.containsKey("timed_effects")) {
                val stopping = body.toString().contains("no_effect") && !body.containsKey("timed_effects")
                if (!stopping) { lamp.on = true; lamp.percent = 100.0; lamp.whiteMode = true } // worst case
            }
            (body["gradient"] as? JsonObject)?.let { lamp.whiteMode = true } // worst case for a strip
        }

        /** Onset times on the wire, judged per lamp against its trough since its last onset. */
        fun onsets(wire: List<WireRecord>, topology: Topology): List<Long> {
            val lamps = topology.lamps.mapValues { it.value.copy() }
            val trough = lamps.mapValues { it.value.luminance }.toMutableMap()
            val onsets = mutableListOf<Long>()
            for (w in wire.filter { it.method == "PUT" && it.body != null }) {
                val affected: List<ResourceId> = when (w.type) {
                    ResourceType.LIGHT -> listOfNotNull(w.id).filter { it in lamps }
                    ResourceType.GROUPED_LIGHT -> topology.groups[w.id!!] ?: emptyList()
                    ResourceType.SCENE -> topology.scenes[w.id!!] ?: emptyList()
                    else -> emptyList()
                }
                var onsetHere = false
                for (id in affected) {
                    val lamp = lamps.getValue(id)
                    if (w.type == ResourceType.SCENE) { lamp.on = true; lamp.percent = 100.0; lamp.whiteMode = true } else applyBody(lamp, w.body!!)
                    val lum = lamp.luminance
                    val t = trough.getValue(id)
                    if (lum - t >= RISE - 1e-9) { onsetHere = true; trough[id] = lum } else trough[id] = minOf(t, lum)
                }
                if (onsetHere) onsets += w.atMillis!!
            }
            return onsets
        }

        fun minGap(onsets: List<Long>): Long? = onsets.zipWithNext { a, b -> b - a }.minOrNull()
        fun violates(onsets: List<Long>): Boolean = (minGap(onsets) ?: Long.MAX_VALUE) < PERIOD_MS
    }

    private suspend fun TestScope.run(h: CoordinatorHarness, steps: Int, stepMillis: Long, step: suspend (Int) -> Unit): List<Long> {
        val topo = ViewerOracle.topology(h)
        repeat(steps) { i -> step(i); advanceTimeBy(stepMillis) }
        advanceTimeBy(30_000); advanceUntilIdle()
        return ViewerOracle.onsets(h.transport.wire, topo)
    }

    private fun assertSafe(name: String, onsets: List<Long>) {
        assertTrue("$name: the script must realize onsets (${onsets.size})", onsets.size >= 2)
        assertTrue("$name: min gap ${ViewerOracle.minGap(onsets)} ms < 340", !ViewerOracle.violates(onsets))
    }

    @Test
    fun roomSliderAndLightSlider_interleaved_neverRealizeTwoOnsetsInsideThePeriod() = runTest {
        val h = CoordinatorHarness(this)
        h.store.update { s -> s.copy(lights = s.lights.mapValues { it.value.copy(isOn = true, brightness = 1.0) }, groupedLights = s.groupedLights.mapValues { it.value.copy(brightness = 1.0) }) }
        val onsets = run(h, 40, 100) { i -> if (i % 2 == 0) h.coordinator.submit(LiveMutation.SetBrightness(h.colorLamp, 100)) else h.coordinator.submit(LiveMutation.SetBrightness(h.room, 1)) }
        assertSafe("room+light", onsets)
    }

    @Test
    fun sceneAAndSceneB_alternating_neverRealizeTwoOnsetsInsideThePeriod() = runTest {
        val h = CoordinatorHarness(this)
        // Scene A, then a light-level fall, then scene B, then a fall … every recall is a rise for the room.
        val onsets = run(h, 60, 100) { i -> when (i % 4) { 0 -> h.coordinator.submit(LiveMutation.RecallScene(h.scene)); 2 -> h.coordinator.submit(LiveMutation.RecallScene(h.scene2)); else -> h.coordinator.submit(LiveMutation.SetBrightness(h.colorLamp, 1)) } }
        assertSafe("scene A/B", onsets)
    }

    @Test
    fun scene_groupedFall_scene_neverRealizesTwoOnsetsInsideThePeriod() = runTest {
        val h = CoordinatorHarness(this)
        val onsets = run(h, 45, 100) { i -> when (i % 3) { 0 -> h.coordinator.submit(LiveMutation.RecallScene(h.scene)); 1 -> h.coordinator.submit(LiveMutation.SetBrightness(h.room, 1)); else -> h.coordinator.submit(LiveMutation.RecallScene(h.scene)) } }
        assertSafe("scene/fall/scene", onsets)
    }

    @Test
    fun ctModeLampWithStaleSaturatedXy_brightnessScrub_neverRealizesTwoOnsetsInsideThePeriod() = runTest {
        val h = CoordinatorHarness(this)
        val onsets = run(h, 40, 100) { i -> h.coordinator.submit(LiveMutation.SetBrightness(h.ctModeLamp, if (i % 2 == 0) 100 else 1)) }
        assertSafe("CT-mode scrub", onsets)
    }

    @Test
    fun ctWriteThenScrub_onAColourLamp_neverRealizesTwoOnsetsInsideThePeriod() = runTest {
        val h = CoordinatorHarness(this)
        h.store.update { s -> s.copy(lights = s.lights + (h.colorLamp to s.lights.getValue(h.colorLamp).copy(color = CieXy(0.15, 0.06), mirekValid = false))) }
        h.coordinator.submit(LiveMutation.SetColorTemperature(h.colorLamp, 300))
        advanceTimeBy(500)
        val onsets = run(h, 40, 100) { i -> h.coordinator.submit(LiveMutation.SetBrightness(h.colorLamp, if (i % 2 == 0) 100 else 1)) }
        assertSafe("CT then scrub", onsets)
    }

    @Test
    fun effectInitiationOnADarkLamp_isARiseForTheOracle_andIsPaced() = runTest {
        val h = CoordinatorHarness(this)
        h.store.update { s -> s.copy(lights = s.lights.mapValues { it.value.copy(isOn = false) }) }
        val onsets = run(h, 30, 100) { i -> when (i % 3) { 0 -> h.coordinator.submit(LiveMutation.SelectEffect(h.colorLamp, "candle")); 1 -> h.coordinator.submit(LiveMutation.SetPower(h.colorLamp, false)); else -> h.coordinator.submit(LiveMutation.SelectEffect(h.ctLamp, "candle")) } }
        assertSafe("effect initiation", onsets)
    }

    /** The per-light storm from the original suite, kept as the baseline that already passed. */
    @Test
    fun perLightStorm_stillSafe() = runTest {
        val h = CoordinatorHarness(this)
        h.store.update { s -> s.copy(lights = s.lights.mapValues { it.value.copy(isOn = true, brightness = 1.0) }) }
        val lamps = listOf(h.colorLamp, h.ctLamp, h.whiteLamp)
        val onsets = run(h, 30, 200) { i -> h.coordinator.submit(LiveMutation.SetBrightness(lamps[i % 3], if (i % 2 == 0) 100 else 1)) }
        assertSafe("per-light", onsets)
        assertTrue(ResourceKey(h.bridge, ResourceType.LIGHT, ResourceId("x")).composeKey.isNotEmpty())
    }
}
