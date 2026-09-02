package com.chromaglow.app.core.identity

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class IdentityContractTest {

    private val bridgeA = BridgeId("001788FFFE112233")
    private val bridgeB = BridgeId("AABBCCDDEEFF0011")
    private val sharedRid = ResourceId("6d0f9d3a-0b1e-4c7d-9c2a-1f2e3d4c5b6a")

    // 1. ResourceKey differs for identical resource UUIDs on different bridges.
    @Test
    fun resourceKey_sameRidOnTwoBridges_areDistinctKeys() {
        val onA = ResourceKey(bridgeA, ResourceType.LIGHT, sharedRid)
        val onB = ResourceKey(bridgeB, ResourceType.LIGHT, sharedRid)

        assertNotEquals(onA, onB)
        assertNotEquals(onA.composeKey, onB.composeKey)
        assertNotEquals(onA.hashCode() to onA, onB.hashCode() to onB)
        val map = mapOf(onA to "A", onB to "B")
        assertEquals(2, map.size)
    }

    @Test
    fun resourceKey_sameRidDifferentType_areDistinctKeys() {
        val light = ResourceKey(bridgeA, ResourceType.LIGHT, sharedRid)
        val grouped = ResourceKey(bridgeA, ResourceType.GROUPED_LIGHT, sharedRid)
        assertNotEquals(light, grouped)
    }

    // 3. BridgeId physical validation remains canonical uppercase 16-hex.
    @Test
    fun bridgeId_acceptsOnlyCanonicalUppercaseHex() {
        assertEquals("001788FFFE112233", BridgeId("001788FFFE112233").value)
        assertThrows(IllegalArgumentException::class.java) { BridgeId("001788fffe112233") }
        assertThrows(IllegalArgumentException::class.java) { BridgeId("001788FFFE11223") }
        assertThrows(IllegalArgumentException::class.java) { BridgeId("001788FFFE1122334") }
        assertThrows(IllegalArgumentException::class.java) { BridgeId("demo-bridge-main") }
        assertThrows(IllegalArgumentException::class.java) { BridgeId("") }
        assertNull(BridgeId.parseOrNull("001788fffe112233"))
        assertNull(BridgeId.parseOrNull("550e8400-e29b-41d4-a716-446655440000"))
        assertEquals(bridgeA, BridgeId.parseOrNull("001788FFFE112233"))
    }

    @Test
    fun bridgeId_regexMatchesRegistryAndAliasContracts() {
        assertEquals("^[0-9A-F]{16}$", BridgeId.CANONICAL.pattern)
    }

    // 2. Demo identity cannot accidentally become a live BridgeId.
    @Test
    fun demoTargetId_refusesAnythingShapedLikeAPhysicalBridgeId() {
        assertThrows(IllegalArgumentException::class.java) { DemoTargetId("001788FFFE112233", "room-1") }
        val demo = DemoTargetId("demo-bridge-main", "room-1")
        assertNull(BridgeId.parseOrNull(demo.demoBridge))
    }

    @Test
    fun targetRef_liveAndDemo_areDisjointVariants() {
        val live: TargetRef = TargetRef.Live(ResourceKey(bridgeA, ResourceType.ROOM, sharedRid))
        val demo: TargetRef = TargetRef.Demo(DemoTargetId("demo-bridge-main", sharedRid.value))
        assertNotEquals(live, demo)
        assertTrue(live is TargetRef.Live && demo is TargetRef.Demo)
    }

    @Test
    fun resourceId_rejectsBlankAndWhitespace() {
        assertThrows(IllegalArgumentException::class.java) { ResourceId(" ") }
        assertThrows(IllegalArgumentException::class.java) { ResourceId("a b") }
    }

    @Test
    fun resourceType_wireNamesRoundTrip_andUnknownIsNull() {
        for (type in ResourceType.entries) assertEquals(type, ResourceType.fromWireName(type.wireName))
        assertNull(ResourceType.fromWireName("button"))
        assertNull(ResourceType.fromWireName("motion"))
    }
}
