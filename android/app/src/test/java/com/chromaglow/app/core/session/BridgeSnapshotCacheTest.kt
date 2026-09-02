package com.chromaglow.app.core.session

import com.chromaglow.app.core.hue.capability.Capability
import com.chromaglow.app.core.hue.capability.CieXy
import com.chromaglow.app.core.hue.capability.Gamut
import com.chromaglow.app.core.hue.capability.GradientCapability
import com.chromaglow.app.core.hue.capability.LightCapabilities
import com.chromaglow.app.core.hue.capability.MirekRange
import com.chromaglow.app.core.identity.BridgeId
import com.chromaglow.app.core.identity.ResourceId
import com.chromaglow.app.core.identity.ResourceKey
import com.chromaglow.app.core.identity.ResourceType
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

class BridgeSnapshotCacheTest {

    private val bridgeA = BridgeId("001788FFFE112233")
    private val bridgeB = BridgeId("AABBCCDDEEFF0011")
    private val io = UnconfinedTestDispatcher()
    private val dir: File = Files.createTempDirectory("snapshot-cache").toFile()

    @After
    fun tearDown() {
        dir.deleteRecursively()
    }

    private fun key(b: BridgeId, t: ResourceType, id: String) = ResourceKey(b, t, ResourceId(id))

    private fun richSnapshot(bridge: BridgeId, generation: Long = 7, lightIds: List<String> = listOf("l1", "l2")): BridgeSnapshot {
        val caps = LightCapabilities(
            color = Capability.known(Gamut.fromBridge(CieXy(0.69, 0.31), CieXy(0.17, 0.7), CieXy(0.15, 0.05))),
            colorTemperature = Capability.known(MirekRange(153, 454)),
            effectsV1 = Capability.absent(),
            effectsV2 = Capability.known(setOf("candle", "prism")),
            timedEffects = Capability.unreadable(),
            gradient = Capability.known(GradientCapability(5, setOf("interpolated_palette"), 7)),
            signaling = Capability.unsupported(),
            dynamics = Capability.known(Unit),
        )
        val lights = lightIds.associate { id ->
            val k = key(bridge, ResourceType.LIGHT, id)
            k to LightState(
                key = k, name = "Lamp $id", isOn = true, brightness = 42.5, color = CieXy(0.3, 0.3), mirek = 300,
                mirekValid = true, activeEffect = "candle", activeTimedEffect = null, gradientPoints = listOf(CieXy(0.1, 0.2)),
                owner = key(bridge, ResourceType.DEVICE, "d-$id"), capabilities = if (id == "l1") caps else LightCapabilities.unknown(),
            )
        }
        val room = key(bridge, ResourceType.ROOM, "r1")
        val gl = key(bridge, ResourceType.GROUPED_LIGHT, "g1")
        return BridgeSnapshot(
            bridgeId = bridge, generation = generation, freshness = Freshness.Fresh(generation),
            rooms = mapOf(room to GroupState(room, GroupKind.ROOM, "Living", "living_room", lights.keys.toList(), gl)),
            zones = emptyMap(),
            groupedLights = mapOf(gl to GroupedLightState(gl, true, 40.0)),
            lights = lights,
            scenes = mapOf(key(bridge, ResourceType.SCENE, "s1") to SceneState(key(bridge, ResourceType.SCENE, "s1"), "Relax", room, isActive = true, isDynamic = false)),
        )
    }

    private fun cache(bridge: BridgeId) = FileBridgeSnapshotCache(bridge, dir, io)

    @Test
    fun emptyDirectory_isMiss() = runTest(io) {
        assertEquals(CacheReadResult.Miss, cache(bridgeA).read())
    }

    @Test
    fun roundTrip_preservesEveryField_andPaintsStaleFromCache() = runTest(io) {
        val original = richSnapshot(bridgeA)
        assertEquals(CacheWriteResult.Written, cache(bridgeA).write(original))

        val hit = cache(bridgeA).read() as CacheReadResult.Hit
        assertEquals(Freshness.Stale(7, StaleReason.FROM_CACHE), hit.snapshot.freshness)
        assertEquals(original.copy(freshness = hit.snapshot.freshness), hit.snapshot)
    }

    @Test
    fun perBridgeIsolation_anotherBridgesFileIsNeverAHit() = runTest(io) {
        cache(bridgeA).write(richSnapshot(bridgeA))
        assertEquals(CacheReadResult.Miss, cache(bridgeB).read())
        // A snapshot for bridge A copied under B's file name is refused, not adopted.
        val aFile = dir.listFiles()!!.single { it.name.endsWith(".json") }
        aFile.copyTo(File(dir, aFile.name.replace(bridgeA.value, bridgeB.value)))
        assertTrue(cache(bridgeB).read() is CacheReadResult.Discarded)
        assertTrue(cache(bridgeA).read() is CacheReadResult.Hit)
    }

    @Test
    fun writeForAnotherBridge_isRefused() = runTest(io) {
        assertTrue(cache(bridgeA).write(richSnapshot(bridgeB)) is CacheWriteResult.Failed)
        assertEquals(CacheReadResult.Miss, cache(bridgeA).read())
    }

    @Test
    fun unknownFormatVersion_isDiscarded_nonfatal() = runTest(io) {
        cache(bridgeA).write(richSnapshot(bridgeA))
        val file = dir.listFiles()!!.single { it.name.endsWith(".json") }
        file.writeText(file.readText().replace("\"format_version\":1", "\"format_version\":99"))
        val result = cache(bridgeA).read()
        assertTrue(result is CacheReadResult.Discarded)
        assertTrue((result as CacheReadResult.Discarded).reason.contains("format_version"))
    }

    @Test
    fun corruptBytes_areDiscarded_nonfatal() = runTest(io) {
        cache(bridgeA).write(richSnapshot(bridgeA))
        val file = dir.listFiles()!!.single { it.name.endsWith(".json") }
        file.writeBytes(byteArrayOf(0, 1, 2, 3, 123, 34))
        assertTrue(cache(bridgeA).read() is CacheReadResult.Discarded)
        file.writeText("""{"format_version":1,"bridge_id":"001788FFFE112233","generation":1,"rooms":"nope"}""")
        assertTrue(cache(bridgeA).read() is CacheReadResult.Discarded)
        file.writeText("[]")
        assertTrue(cache(bridgeA).read() is CacheReadResult.Discarded)
    }

    @Test
    fun atomicWrite_leavesNoTempFile_andAuthoritativeReloadDropsAbsentResources() = runTest(io) {
        cache(bridgeA).write(richSnapshot(bridgeA, generation = 1, lightIds = listOf("l1", "l2")))
        cache(bridgeA).write(richSnapshot(bridgeA, generation = 2, lightIds = listOf("l1")))
        assertTrue(dir.listFiles()!!.none { it.name.endsWith(".tmp") })
        assertEquals(1, dir.listFiles()!!.size)
        val hit = cache(bridgeA).read() as CacheReadResult.Hit
        assertEquals(setOf(key(bridgeA, ResourceType.LIGHT, "l1")), hit.snapshot.lights.keys)
        assertEquals(2L, hit.snapshot.generation)
    }

    @Test
    fun clear_removesTheFile_andIsIdempotent() = runTest(io) {
        cache(bridgeA).write(richSnapshot(bridgeA))
        cache(bridgeA).clear()
        cache(bridgeA).clear()
        assertEquals(CacheReadResult.Miss, cache(bridgeA).read())
    }

    @Test
    fun bytesOnDisk_containNoSecretShapedContent() = runTest(io) {
        cache(bridgeA).write(richSnapshot(bridgeA))
        val text = dir.listFiles()!!.single { it.name.endsWith(".json") }.readText().lowercase()
        for (forbidden in listOf("username", "token", "clientkey", "hue-application-key", "secret", "password")) {
            assertFalse("cache bytes contain '$forbidden'", text.contains(forbidden))
        }
        assertTrue(text.contains("\"format_version\":1"))
        assertTrue(text.contains("\"bridge_id\":\"001788ffFE112233\"".lowercase()))
    }

    @Test
    fun missingDirectory_isCreatedOnWrite() = runTest(io) {
        val nested = File(dir, "a/b/c")
        val c = FileBridgeSnapshotCache(bridgeA, nested, io)
        assertEquals(CacheWriteResult.Written, c.write(richSnapshot(bridgeA)))
        assertTrue(c.read() is CacheReadResult.Hit)
    }
}
