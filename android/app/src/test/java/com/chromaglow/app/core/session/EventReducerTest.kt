package com.chromaglow.app.core.session

import com.chromaglow.app.core.hue.capability.Capability
import com.chromaglow.app.core.hue.capability.CieXy
import com.chromaglow.app.core.hue.capability.Evidence
import com.chromaglow.app.core.hue.capability.LightCapabilities
import com.chromaglow.app.core.hue.capability.MirekRange
import com.chromaglow.app.core.identity.BridgeId
import com.chromaglow.app.core.identity.ResourceId
import com.chromaglow.app.core.identity.ResourceKey
import com.chromaglow.app.core.identity.ResourceType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class EventReducerTest {

    private val bridgeA = BridgeId("001788FFFE112233")
    private val bridgeB = BridgeId("AABBCCDDEEFF0011")
    private fun key(b: BridgeId, t: ResourceType, id: String) = ResourceKey(b, t, ResourceId(id))

    private fun snapshot(bridge: BridgeId): BridgeSnapshot {
        val l1 = key(bridge, ResourceType.LIGHT, "l1")
        val l2 = key(bridge, ResourceType.LIGHT, "l2")
        val room = key(bridge, ResourceType.ROOM, "r1")
        val gl = key(bridge, ResourceType.GROUPED_LIGHT, "g1")
        val s1 = key(bridge, ResourceType.SCENE, "s1")
        val s2 = key(bridge, ResourceType.SCENE, "s2")
        val caps = LightCapabilities.unknown().copy(colorTemperature = Capability.known(MirekRange(153, 454)))
        fun light(k: ResourceKey) = LightState(k, "Lamp", true, 50.0, CieXy(0.3, 0.3), 300, true, null, null, emptyList(), null, caps)
        return BridgeSnapshot(
            bridge, 1, Freshness.Fresh(1),
            rooms = mapOf(room to GroupState(room, GroupKind.ROOM, "Living", null, listOf(l1, l2), gl)),
            zones = emptyMap(),
            groupedLights = mapOf(gl to GroupedLightState(gl, true, 50.0)),
            lights = mapOf(l1 to light(l1), l2 to light(l2)),
            scenes = mapOf(s1 to SceneState(s1, "Relax", room, isActive = false, isDynamic = false), s2 to SceneState(s2, "Energize", room, isActive = true, isDynamic = false)),
        )
    }

    private fun update(vararg items: String) = """[{"creationtime":"2026-09-02T10:00:00Z","id":"e1","type":"update","data":[${items.joinToString(",")}]}]"""
    private val authority = PendingAuthority()
    private val now = 1_000L

    @Test
    fun lightUpdate_appliesOnAndBrightness() {
        val s = snapshot(bridgeA)
        val out = EventReducer.reduce(s, update("""{"id":"l1","type":"light","on":{"on":false},"dimming":{"brightness":12.5}}"""), authority, now)
        val l = out.lights.getValue(key(bridgeA, ResourceType.LIGHT, "l1"))
        assertFalse(l.isOn)
        assertEquals(12.5, l.brightness!!, 0.0)
        assertEquals("other lamps untouched", s.lights.getValue(key(bridgeA, ResourceType.LIGHT, "l2")), out.lights.getValue(key(bridgeA, ResourceType.LIGHT, "l2")))
    }

    @Test
    fun pendingBrightness_suppressesOnlyBrightness_colourStillLands() {
        val s = snapshot(bridgeA)
        val l1 = key(bridgeA, ResourceType.LIGHT, "l1")
        authority.claim(l1, FieldGroup.DIMMING, MutationToken(1), now + 1_000, prior = s)
        val out = EventReducer.reduce(s, update("""{"id":"l1","type":"light","dimming":{"brightness":5},"color":{"xy":{"x":0.2,"y":0.4}}}"""), authority, now)
        val l = out.lights.getValue(l1)
        assertEquals(50.0, l.brightness!!, 0.0)
        assertEquals(CieXy(0.2, 0.4), l.color)
    }

    @Test
    fun pendingEffect_doesNotSuppressOnOff() {
        val s = snapshot(bridgeA)
        val l1 = key(bridgeA, ResourceType.LIGHT, "l1")
        authority.claim(l1, FieldGroup.EFFECT, MutationToken(1), now + 1_000, prior = s)
        val out = EventReducer.reduce(s, update("""{"id":"l1","type":"light","on":{"on":false},"effects_v2":{"status":{"effect":"candle"}}}"""), authority, now)
        val l = out.lights.getValue(l1)
        assertFalse(l.isOn)
        assertNull("the pending effect field is fenced", l.activeEffect)
        // Once the fence expires the same event lands.
        val later = EventReducer.reduce(s, update("""{"id":"l1","type":"light","effects_v2":{"status":{"effect":"candle"}}}"""), authority, now + 5_000)
        assertEquals("candle", later.lights.getValue(l1).activeEffect)
    }

    @Test
    fun colourEvent_nullsTheMirekValue_butKeepsTheSchemaCapability() {
        val s = snapshot(bridgeA)
        val l1 = key(bridgeA, ResourceType.LIGHT, "l1")
        val out = EventReducer.reduce(s, update("""{"id":"l1","type":"light","color":{"xy":{"x":0.64,"y":0.33}}}"""), authority, now)
        val l = out.lights.getValue(l1)
        assertEquals(CieXy(0.64, 0.33), l.color)
        assertNull(l.mirek)
        assertEquals(false, l.mirekValid)
        assertEquals(Evidence.KNOWN, l.capabilities.colorTemperature.evidence)
        assertEquals(MirekRange(153, 454), l.capabilities.colorTemperature.value)
        val ct = EventReducer.reduce(out, update("""{"id":"l1","type":"light","color_temperature":{"mirek":400,"mirek_valid":true}}"""), authority, now)
        assertEquals(400, ct.lights.getValue(l1).mirek)
        assertEquals(true, ct.lights.getValue(l1).mirekValid)
    }

    @Test
    fun sceneActive_clearsSiblingsInTheSameGroup_andInactiveClearsOnlyItself() {
        val s = snapshot(bridgeA)
        val s1 = key(bridgeA, ResourceType.SCENE, "s1")
        val s2 = key(bridgeA, ResourceType.SCENE, "s2")
        val out = EventReducer.reduce(s, update("""{"id":"s1","type":"scene","status":{"active":"dynamic_palette"}}"""), authority, now)
        assertTrue(out.scenes.getValue(s1).isActive && out.scenes.getValue(s1).isDynamic)
        assertFalse(out.scenes.getValue(s2).isActive)
        val off = EventReducer.reduce(out, update("""{"id":"s1","type":"scene","status":{"active":"inactive"}}"""), authority, now)
        assertFalse(off.scenes.getValue(s1).isActive)
        assertFalse(off.scenes.getValue(s2).isActive)
        // A pending recall keeps the optimistic state.
        authority.claim(s2, FieldGroup.SCENE, MutationToken(1), now + 1_000, prior = s)
        val fenced = EventReducer.reduce(s, update("""{"id":"s2","type":"scene","status":{"active":"inactive"}}"""), authority, now)
        assertTrue(fenced.scenes.getValue(s2).isActive)
    }

    @Test
    fun groupedLightAndGroupName_updates() {
        val s = snapshot(bridgeA)
        val out = EventReducer.reduce(s, update("""{"id":"g1","type":"grouped_light","on":{"on":false},"dimming":{"brightness":20}}""", """{"id":"r1","type":"room","metadata":{"name":"Lounge"}}"""), authority, now)
        val g = out.groupedLights.getValue(key(bridgeA, ResourceType.GROUPED_LIGHT, "g1"))
        assertFalse(g.isOn)
        assertEquals(20.0, g.brightness!!, 0.0)
        assertEquals("Lounge", out.rooms.getValue(key(bridgeA, ResourceType.ROOM, "r1")).name)
    }

    @Test
    fun deleteEvent_removesTheResource_andItsMembership() {
        val s = snapshot(bridgeA)
        val payload = """[{"type":"delete","data":[{"id":"l2","type":"light"},{"id":"s1","type":"scene"}]}]"""
        val out = EventReducer.reduce(s, payload, authority, now)
        assertFalse(out.lights.containsKey(key(bridgeA, ResourceType.LIGHT, "l2")))
        assertEquals(listOf(key(bridgeA, ResourceType.LIGHT, "l1")), out.rooms.values.single().children)
        assertFalse(out.scenes.containsKey(key(bridgeA, ResourceType.SCENE, "s1")))
    }

    @Test
    fun malformedPayloads_areSkipped_neverThrow_andLeaveTheSnapshotIdentical() {
        val s = snapshot(bridgeA)
        for (bad in listOf("not json", "{}", "[1,2]", """[{"type":"update"}]""", """[{"type":"update","data":[1,{"type":"light"},{"id":"","type":"light"},{"id":"l1","type":"light","on":"nope","dimming":{"brightness":"5"}}]}]""", """[{"type":"update","data":[{"id":"l1","type":"light","color":{"xy":{"x":2,"y":2}}}]}]""")) {
            assertSame(bad, s, EventReducer.reduce(s, bad, authority, now))
        }
    }

    @Test
    fun sensorControllerAndDeviceFamilies_areNoOps() {
        val s = snapshot(bridgeA)
        val families = listOf("button", "relative_rotary", "motion", "light_level", "temperature", "device_power", "device", "zigbee_connectivity", "entertainment_configuration", "bridge", "behavior_instance", "geofence_client")
        for (type in families) {
            val payload = update("""{"id":"l1","type":"$type","on":{"on":false},"button":{"button_report":{"event":"short_release"}}}""")
            assertSame(type, s, EventReducer.reduce(s, payload, authority, now))
        }
        assertSame(s, EventReducer.reduce(s, """[{"type":"add","data":[{"id":"l9","type":"light","on":{"on":true}}]}]""", authority, now))
    }

    @Test
    fun d07_aClaimOnBridgeAsLamp_neverFencesTheSameRidOnBridgeB() {
        val b = snapshot(bridgeB)
        val fence = PendingAuthority()
        fence.claim(key(bridgeA, ResourceType.LIGHT, "l1"), FieldGroup.POWER, MutationToken(9), now + 1_000, prior = snapshot(bridgeA))
        val out = EventReducer.reduce(b, update("""{"id":"l1","type":"light","on":{"on":false}}"""), fence, now)
        assertFalse("bridge B's event lands despite A's claim on the same rid", out.lights.getValue(key(bridgeB, ResourceType.LIGHT, "l1")).isOn)
    }

    @Test
    fun crossBridgeIsolation_anEventForBridgeAsIdsNeverTouchesBridgeB() {
        val a = snapshot(bridgeA)
        val b = snapshot(bridgeB).copy(lights = emptyMap(), rooms = emptyMap(), scenes = emptyMap(), groupedLights = emptyMap())
        val payload = update("""{"id":"l1","type":"light","on":{"on":false}}""")
        val outA = EventReducer.reduce(a, payload, authority, now)
        assertFalse(outA.lights.getValue(key(bridgeA, ResourceType.LIGHT, "l1")).isOn)
        assertSame("bridge B has no such key: nothing to reduce", b, EventReducer.reduce(b, payload, authority, now))
        assertTrue(outA.lights.keys.all { it.bridgeId == bridgeA })
    }

    @Test
    fun timedEffectAndGradientStatus_land_underTheirOwnFields() {
        val s = snapshot(bridgeA)
        val l1 = key(bridgeA, ResourceType.LIGHT, "l1")
        val out = EventReducer.reduce(s, update("""{"id":"l1","type":"light","timed_effects":{"status":"sunrise"},"gradient":{"points":[{"color":{"xy":{"x":0.1,"y":0.2}}},{"color":{"xy":{"x":0.3,"y":0.4}}}]}}"""), authority, now)
        assertEquals("sunrise", out.lights.getValue(l1).activeTimedEffect)
        assertEquals(listOf(CieXy(0.1, 0.2), CieXy(0.3, 0.4)), out.lights.getValue(l1).gradientPoints)
        val done = EventReducer.reduce(out, update("""{"id":"l1","type":"light","timed_effects":{"status":"no_effect"},"effects":{"status":"no_effect"}}"""), authority, now)
        assertNull(done.lights.getValue(l1).activeTimedEffect)
        assertNull(done.lights.getValue(l1).activeEffect)
    }
}
