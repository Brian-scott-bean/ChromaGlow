package com.chromaglow.app.data.demo

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DemoFixturesLightsScenesTest {
    @Test
    fun lights_existForEveryRoomId() {
        val roomIds = DemoFixtures.rooms.map { it.id }.toSet()
        roomIds.forEach { roomId ->
            val roomLights = DemoFixtures.lights.filter { it.roomId == roomId }
            assertTrue(
                "expected at least one demo light for room $roomId",
                roomLights.isNotEmpty(),
            )
        }
    }

    @Test
    fun lightsByRoom_coversEveryRoomId() {
        val roomIds = DemoFixtures.rooms.map { it.id }.toSet()
        roomIds.forEach { roomId ->
            val grouped = DemoFixtures.lightsByRoom[roomId]
            assertNotNull("expected lightsByRoom entry for $roomId", grouped)
            assertTrue(grouped!!.isNotEmpty())
        }
    }

    @Test
    fun lightsByRoom_matchesFlatLightsList() {
        assertEquals(
            DemoFixtures.lights.groupBy { it.roomId },
            DemoFixtures.lightsByRoom,
        )
    }

    @Test
    fun lights_referenceOnlyExistingRoomIds() {
        val roomIds = DemoFixtures.rooms.map { it.id }.toSet()
        DemoFixtures.lights.forEach { light ->
            assertTrue(
                "light ${light.id} references unknown room ${light.roomId}",
                light.roomId in roomIds,
            )
        }
    }

    @Test
    fun lights_brightnessInValidRange() {
        DemoFixtures.lights.forEach { light ->
            assertTrue(light.brightness in 1..100)
        }
    }

    @Test
    fun lights_idsAreUnique() {
        val ids = DemoFixtures.lights.map { it.id }
        assertEquals(ids.size, ids.toSet().size)
    }

    @Test
    fun lights_allUseDemoBridgeId() {
        DemoFixtures.lights.forEach { light ->
            assertEquals(DemoFixtures.DEMO_BRIDGE_ID, light.bridgeId)
        }
    }

    @Test
    fun scenes_hasAtLeastThree() {
        assertTrue(DemoFixtures.scenes.size >= 3)
    }

    @Test
    fun scenes_idsAreUnique() {
        val ids = DemoFixtures.scenes.map { it.id }
        assertEquals(ids.size, ids.toSet().size)
    }

    @Test
    fun scenes_brightnessInValidRange() {
        DemoFixtures.scenes.forEach { scene ->
            assertTrue(scene.brightness in 1..100)
        }
    }

    @Test
    fun scenes_referenceOnlyExistingRoomIds() {
        val roomIds = DemoFixtures.rooms.map { it.id }.toSet()
        DemoFixtures.scenes.forEach { scene ->
            assertTrue(
                "scene ${scene.id} references unknown room ${scene.roomId}",
                scene.roomId in roomIds,
            )
        }
    }

    @Test
    fun rooms_remainUnchanged() {
        // Guard the hard compatibility constraint: lane additions must not
        // mutate the existing room fixtures the integration test relies on.
        assertEquals(4, DemoFixtures.rooms.size)
        assertEquals(
            listOf("Kitchen", "Living Room", "Master Bedroom", "Office"),
            DemoFixtures.rooms.map { it.name },
        )
        assertEquals("demo-bridge-main", DemoFixtures.DEMO_BRIDGE_ID)
    }
}
