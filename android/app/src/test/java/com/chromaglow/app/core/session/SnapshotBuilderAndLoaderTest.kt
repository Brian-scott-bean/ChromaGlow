package com.chromaglow.app.core.session

import com.chromaglow.app.core.hue.capability.CieXy
import com.chromaglow.app.core.hue.capability.Evidence
import com.chromaglow.app.core.hue.rest.ClipDocument
import com.chromaglow.app.core.hue.rest.ClipError
import com.chromaglow.app.core.identity.BridgeId
import com.chromaglow.app.core.identity.ResourceId
import com.chromaglow.app.core.identity.ResourceKey
import com.chromaglow.app.core.identity.ResourceType
import com.chromaglow.app.testing.FakeHueClipTransport
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SnapshotBuilderAndLoaderTest {

    private val bridgeA = BridgeId("001788FFFE112233")
    private val bridgeB = BridgeId("AABBCCDDEEFF0011")
    private fun key(b: BridgeId, t: ResourceType, id: String) = ResourceKey(b, t, ResourceId(id))

    private fun doc(vararg elements: String): ClipDocument =
        ClipDocument(Json.parseToJsonElement("[${elements.joinToString(",")}]").jsonArray.map { it.jsonObject })

    private val lightA = """{"id":"la","type":"light","owner":{"rid":"dev-1","rtype":"device"},"metadata":{"name":"A"},"on":{"on":true},"dimming":{"brightness":60},
        "color":{"xy":{"x":0.3,"y":0.3},"gamut_type":"C"},"color_temperature":{"mirek":300,"mirek_valid":true,"mirek_schema":{"mirek_minimum":153,"mirek_maximum":500}},
        "effects_v2":{"action":{"effect_values":["candle"]},"status":{"effect":"candle"}},"timed_effects":{"effect_values":["sunrise"],"status":"sunrise"},
        "gradient":{"points":[{"color":{"xy":{"x":0.1,"y":0.2}}},{"color":{"xy":{"x":2,"y":2}}}],"points_capable":5}}"""
    private val lightB = """{"id":"lb","type":"light","owner":{"rid":"dev-1","rtype":"device"},"metadata":{"name":"B"},"on":{"on":false},"effects":{"status":"no_effect","effect_values":["candle"]}}"""
    private val lightC = """{"id":"lc","type":"light","owner":{"rid":"dev-2","rtype":"device"},"metadata":{"name":"C"},"on":{"on":true}}"""
    private val room = """{"id":"r1","type":"room","metadata":{"name":"Living","archetype":"living_room"},"children":[{"rid":"dev-1","rtype":"device"},{"rid":"dev-unknown","rtype":"device"},{"rid":"x","rtype":"button"}],"services":[{"rid":"g1","rtype":"grouped_light"}]}"""
    private val roomNoGrouped = """{"id":"r2","type":"room","metadata":{"name":"Hall"},"children":[{"rid":"dev-2","rtype":"device"}],"services":[{"rid":"g-missing","rtype":"grouped_light"}]}"""
    private val zone = """{"id":"z1","type":"zone","metadata":{"name":"Up"},"children":[{"rid":"la","rtype":"light"},{"rid":"lc","rtype":"light"},{"rid":"ghost","rtype":"light"}],"services":[{"rid":"g2","rtype":"grouped_light"}]}"""
    private val grouped = """{"id":"g1","type":"grouped_light","on":{"on":true},"dimming":{"brightness":55}}"""
    private val grouped2 = """{"id":"g2","type":"grouped_light","on":{"on":false}}"""
    private val scene = """{"id":"s1","type":"scene","metadata":{"name":"Relax"},"group":{"rid":"r1","rtype":"room"},"status":{"active":"static"}}"""
    private val sceneZone = """{"id":"s2","type":"scene","metadata":{"name":"Energize"},"group":{"rid":"z1","rtype":"zone"},"speed":0.5,"status":{"active":"dynamic_palette"}}"""
    private val sceneBadGroup = """{"id":"s3","type":"scene","metadata":{"name":"?"},"group":{"rid":"q","rtype":"bridge_home"}}"""

    private fun collections() = ClipCollections(
        rooms = doc(room, roomNoGrouped), zones = doc(zone), groupedLights = doc(grouped, grouped2),
        lights = doc(lightA, lightB, lightC), scenes = doc(scene, sceneZone, sceneBadGroup),
    )

    @Test
    fun build_stampsEveryKeyWithTheBridge_andResolvesMembership() {
        val snap = SnapshotBuilder.build(bridgeA, 3, collections())

        assertEquals(Freshness.Fresh(3), snap.freshness)
        assertTrue(snap.lights.keys.all { it.bridgeId == bridgeA })
        val living = snap.rooms.getValue(key(bridgeA, ResourceType.ROOM, "r1"))
        assertEquals(listOf(key(bridgeA, ResourceType.LIGHT, "la"), key(bridgeA, ResourceType.LIGHT, "lb")), living.children)
        assertEquals(key(bridgeA, ResourceType.GROUPED_LIGHT, "g1"), living.groupedLight)
        assertEquals("living_room", living.archetype)
        val hall = snap.rooms.getValue(key(bridgeA, ResourceType.ROOM, "r2"))
        assertEquals(listOf(key(bridgeA, ResourceType.LIGHT, "lc")), hall.children)
        assertNull("a grouped_light service that is not in the collection is not linked", hall.groupedLight)
        val up = snap.zones.getValue(key(bridgeA, ResourceType.ZONE, "z1"))
        assertEquals(listOf(key(bridgeA, ResourceType.LIGHT, "la"), key(bridgeA, ResourceType.LIGHT, "lc")), up.children)
        assertEquals(GroupKind.ZONE, up.kind)
    }

    @Test
    fun build_lightState_mapsFields_andNoEffectIsNull() {
        val snap = SnapshotBuilder.build(bridgeA, 1, collections())
        val a = snap.lights.getValue(key(bridgeA, ResourceType.LIGHT, "la"))
        assertEquals("A", a.name)
        assertTrue(a.isOn)
        assertEquals(60.0, a.brightness!!, 0.0)
        assertEquals(CieXy(0.3, 0.3), a.color)
        assertEquals(300, a.mirek)
        assertEquals(true, a.mirekValid)
        assertEquals("candle", a.activeEffect)
        assertEquals("sunrise", a.activeTimedEffect)
        assertEquals(listOf(CieXy(0.1, 0.2)), a.gradientPoints)
        assertEquals(key(bridgeA, ResourceType.DEVICE, "dev-1"), a.owner)
        assertEquals(Evidence.KNOWN, a.capabilities.colorTemperature.evidence)
        val b = snap.lights.getValue(key(bridgeA, ResourceType.LIGHT, "lb"))
        assertNull(b.activeEffect)
        assertNull(b.brightness)
        assertEquals(Evidence.ABSENT, b.capabilities.color.evidence)
    }

    @Test
    fun build_groupedLightsAndScenes() {
        val snap = SnapshotBuilder.build(bridgeA, 1, collections())
        assertEquals(GroupedLightState(key(bridgeA, ResourceType.GROUPED_LIGHT, "g1"), true, 55.0), snap.groupedLights.getValue(key(bridgeA, ResourceType.GROUPED_LIGHT, "g1")))
        val relax = snap.scenes.getValue(key(bridgeA, ResourceType.SCENE, "s1"))
        assertEquals(key(bridgeA, ResourceType.ROOM, "r1"), relax.group)
        assertTrue(relax.isActive)
        val energize = snap.scenes.getValue(key(bridgeA, ResourceType.SCENE, "s2"))
        assertEquals(key(bridgeA, ResourceType.ZONE, "z1"), energize.group)
        assertTrue(energize.isDynamic && energize.isActive)
        assertFalse(snap.scenes.containsKey(key(bridgeA, ResourceType.SCENE, "s3")))
    }

    @Test
    fun build_sameWireOnTwoBridges_producesDisjointSnapshots_thatMergeWithoutCollision() {
        val a = SnapshotBuilder.build(bridgeA, 1, collections())
        val b = SnapshotBuilder.build(bridgeB, 1, collections())
        val home = HomeSnapshot(mapOf(bridgeA to a, bridgeB to b), mapOf(bridgeA to ConnectionState.Connected, bridgeB to ConnectionState.Offline))
        val allLights = home.bridges.values.flatMap { it.lights.keys }
        assertEquals(6, allLights.toSet().size)
        assertEquals(ConnectionState.Offline, home.connections[bridgeB])
    }

    // --- loader -------------------------------------------------------------------------------

    @Test
    fun loader_fetchesTheFiveCollections_andBuildsAnAcceptedSnapshot() = runTest {
        val fake = FakeHueClipTransport(bridgeA)
        fake.collection(ResourceType.LIGHT, """{"data":[$lightA]}""")
        fake.collection(ResourceType.ROOM, """{"data":[$room]}""")
        fake.collection(ResourceType.GROUPED_LIGHT, """{"data":[$grouped]}""")
        val loader = BridgeLoader(fake)

        val outcome = loader.load() as LoadOutcome.Loaded

        assertEquals(setOf(ResourceType.ROOM, ResourceType.ZONE, ResourceType.GROUPED_LIGHT, ResourceType.LIGHT, ResourceType.SCENE), fake.wire.map { it.type }.toSet())
        assertEquals(5, fake.getCount)
        assertEquals(1L, outcome.snapshot.generation)
        assertEquals(1, outcome.snapshot.lights.size)
        assertEquals(1L, loader.acceptedGeneration)
    }

    @Test
    fun loader_unauthorizedDominatesOtherFailures() = runTest {
        val fake = FakeHueClipTransport(bridgeA)
        fake.fail(ResourceType.ROOM, ClipError.Timeout(false))
        fake.fail(ResourceType.SCENE, ClipError.Unauthorized(403))
        assertEquals(LoadOutcome.Unauthorized(403), BridgeLoader(fake).load())
    }

    @Test
    fun loader_anyOtherFailure_isFailed_andNothingIsAccepted() = runTest {
        val fake = FakeHueClipTransport(bridgeA)
        fake.fail(ResourceType.LIGHT, ClipError.Transport())
        val loader = BridgeLoader(fake)
        assertEquals(LoadOutcome.Failed(ClipError.Transport()), loader.load())
        assertEquals(0L, loader.acceptedGeneration)
    }

    @Test
    fun loader_staleResult_isRejected_andNewerIsAccepted() = runTest {
        val loader = BridgeLoader(FakeHueClipTransport(bridgeA))
        val gen1 = loader.mint()
        val gen2 = loader.mint()
        assertFalse("a result from a superseded generation must never land", loader.accept(BridgeSnapshot.empty(bridgeA).copy(generation = gen1)))
        assertTrue(loader.accept(BridgeSnapshot.empty(bridgeA).copy(generation = gen2)))
        assertFalse("the same generation cannot be accepted twice", loader.accept(BridgeSnapshot.empty(bridgeA).copy(generation = gen2)))
        assertEquals(gen2, loader.acceptedGeneration)
    }

    @Test
    fun loader_sequentialLoads_acceptInOrder() = runTest {
        val loader = BridgeLoader(FakeHueClipTransport(bridgeA))
        val first = loader.load() as LoadOutcome.Loaded
        val second = loader.load() as LoadOutcome.Loaded
        assertEquals(1L, first.snapshot.generation)
        assertEquals(2L, second.snapshot.generation)
    }
}
