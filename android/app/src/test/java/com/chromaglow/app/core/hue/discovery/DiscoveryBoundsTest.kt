package com.chromaglow.app.core.hue.discovery

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DiscoveryBoundsTest {

    @Test
    fun canTrack_admitsBelowCap_andRefusesAtCap() {
        assertTrue(DiscoveryBounds.canTrack(trackedCount = 0, alreadyTracked = false))
        assertTrue(DiscoveryBounds.canTrack(trackedCount = DiscoveryBounds.MAX_TRACKED_SERVICES - 1, alreadyTracked = false))
        assertFalse(DiscoveryBounds.canTrack(trackedCount = DiscoveryBounds.MAX_TRACKED_SERVICES, alreadyTracked = false))
        assertFalse(DiscoveryBounds.canTrack(trackedCount = 10_000, alreadyTracked = false))
    }

    @Test
    fun canTrack_alwaysAdmitsAnAlreadyTrackedService() {
        // Updates for a known service must not be starved by a flood of strangers.
        assertTrue(DiscoveryBounds.canTrack(trackedCount = DiscoveryBounds.MAX_TRACKED_SERVICES, alreadyTracked = true))
        assertTrue(DiscoveryBounds.canTrack(trackedCount = 10_000, alreadyTracked = true))
    }

    @Test
    fun canQueue_isBoundedByTheSameCap() {
        assertTrue(DiscoveryBounds.canQueue(0))
        assertTrue(DiscoveryBounds.canQueue(DiscoveryBounds.MAX_TRACKED_SERVICES - 1))
        assertFalse(DiscoveryBounds.canQueue(DiscoveryBounds.MAX_TRACKED_SERVICES))
    }

    @Test
    fun boundedChoices_truncatesPreservingOrder_andPassesSmallListsThrough() {
        val flood = (1..100).map { BridgeEndpoint(name = "Bridge $it", host = "10.0.0.$it", port = 443) }

        val bounded = DiscoveryBounds.boundedChoices(flood)

        assertEquals(DiscoveryBounds.MAX_TRACKED_SERVICES, bounded.size)
        assertEquals(flood.take(DiscoveryBounds.MAX_TRACKED_SERVICES), bounded)

        val few = flood.take(3)
        assertEquals(few, DiscoveryBounds.boundedChoices(few))
    }

    @Test
    fun cap_isAGenerousHomeSizedConstant() {
        // Pinned so a future edit cannot silently make the cap tiny or effectively unbounded.
        assertEquals(32, DiscoveryBounds.MAX_TRACKED_SERVICES)
    }
}
