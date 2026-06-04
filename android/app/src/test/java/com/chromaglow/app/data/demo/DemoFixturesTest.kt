package com.chromaglow.app.data.demo

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DemoFixturesTest {
    @Test
    fun rooms_hasFourDeterministicEntries() {
        assertEquals(4, DemoFixtures.rooms.size)
    }

    @Test
    fun rooms_idsAreUnique() {
        val ids = DemoFixtures.rooms.map { it.id }
        assertEquals(ids.size, ids.toSet().size)
    }

    @Test
    fun rooms_sortedAlphabeticallyByName() {
        val names = DemoFixtures.rooms.map { it.name }
        assertEquals(names.sorted(), names)
    }

    @Test
    fun rooms_hasOnAndOffStates() {
        assertTrue(DemoFixtures.rooms.any { it.isOn })
        assertTrue(DemoFixtures.rooms.any { !it.isOn })
    }

    @Test
    fun rooms_brightnessInValidRange() {
        DemoFixtures.rooms.forEach { room ->
            assertTrue(room.brightness in 1..100)
        }
    }

    @Test
    fun rooms_lightCountNonNegative() {
        DemoFixtures.rooms.forEach { room ->
            assertTrue(room.lightCount >= 0)
        }
    }

    @Test
    fun rooms_allUseDemoBridgeId() {
        DemoFixtures.rooms.forEach { room ->
            assertEquals(DemoFixtures.DEMO_BRIDGE_ID, room.bridgeId)
        }
    }
}
