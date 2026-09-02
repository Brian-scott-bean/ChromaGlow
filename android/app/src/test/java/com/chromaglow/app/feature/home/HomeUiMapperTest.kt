package com.chromaglow.app.feature.home

import com.chromaglow.app.core.identity.TargetRef
import com.chromaglow.app.core.session.BridgeSnapshot
import com.chromaglow.app.core.session.ConnectionState
import com.chromaglow.app.core.session.Freshness
import com.chromaglow.app.core.session.GroupKind
import com.chromaglow.app.core.session.HomeSnapshot
import com.chromaglow.app.core.session.SessionErrorReason
import com.chromaglow.app.core.session.StaleReason
import com.chromaglow.app.feature.testing.BRIDGE_A
import com.chromaglow.app.feature.testing.BRIDGE_B
import com.chromaglow.app.feature.testing.Fixtures
import com.chromaglow.app.feature.testing.group
import com.chromaglow.app.feature.testing.grouped
import com.chromaglow.app.feature.testing.groupedKey
import com.chromaglow.app.feature.testing.homeOf
import com.chromaglow.app.feature.testing.roomKey
import com.chromaglow.app.feature.testing.snapshot
import com.chromaglow.app.ui.components.ConnectionTone
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HomeUiMapperTest {

    private val now = 10_000_000L

    @Test
    fun noBridges_yieldsNoBridgesPhase() {
        val state = HomeUiMapper.map(HomeSnapshot(emptyMap(), emptyMap()), now)
        assertEquals(HomePhase.NO_BRIDGES, state.phase)
        assertTrue(state.strip.isEmpty())
    }

    @Test
    fun connectingWithoutAnySnapshotData_isLoading_notDemoFallback() {
        val state = HomeUiMapper.map(homeOf(BridgeSnapshot.empty(BRIDGE_A) to ConnectionState.Connecting), now)
        assertEquals(HomePhase.LOADING, state.phase)
        assertTrue(state.rooms.isEmpty())
        assertTrue(state.zones.isEmpty())
    }

    @Test
    fun connectedWithNoGroups_isEmpty() {
        val state = HomeUiMapper.map(homeOf(snapshot(generation = 3) to ConnectionState.Connected), now)
        assertEquals(HomePhase.EMPTY, state.phase)
    }

    @Test
    fun offlineWithNoDataEver_isEmpty_neverLoadingForever() {
        val state = HomeUiMapper.map(homeOf(BridgeSnapshot.empty(BRIDGE_A) to ConnectionState.Offline), now)
        assertEquals(HomePhase.EMPTY, state.phase)
        assertEquals("Offline", state.strip.single().statusText)
    }

    @Test
    fun fixtures_mapRoomsThenZones_sortedByName_withGroupedLightTruth() {
        val state = HomeUiMapper.map(Fixtures.home(), now)
        assertEquals(HomePhase.CONTENT, state.phase)
        assertEquals(listOf("Bedroom", "Living Room"), state.rooms.map { it.name })
        assertEquals(listOf("Upstairs"), state.zones.map { it.name })

        val living = state.rooms.first { it.name == "Living Room" }
        assertEquals(GroupKind.ROOM, living.kind)
        assertTrue(living.isOn)
        assertEquals(72, living.brightness)
        assertEquals(2, living.lightCount)
        assertEquals(TargetRef.Live(Fixtures.livingGrouped), living.target)
        assertEquals("On · 72% · 2 lights", living.subtitle)

        val bed = state.rooms.first { it.name == "Bedroom" }
        assertFalse(bed.isOn)
        assertEquals(40, bed.brightness)
        assertEquals("Off · 40% · 1 light", bed.subtitle)

        assertEquals(GroupKind.ZONE, state.zones.single().kind)
    }

    @Test
    fun connectedAndStale_keepControlsEnabled() {
        val connected = HomeUiMapper.map(Fixtures.home(ConnectionState.Connected), now)
        val stale = HomeUiMapper.map(Fixtures.home(ConnectionState.Stale(now - 120_000)), now)
        assertTrue(connected.rooms.all { it.controlsEnabled })
        assertTrue(stale.rooms.all { it.controlsEnabled })
        assertNull(stale.rooms.first().disabledReason)
        val row = stale.strip.single()
        assertEquals("Stale for 2 min", row.statusText)
        assertEquals(ConnectionTone.STALE, row.tone)
    }

    @Test
    fun offlineRevokedError_disableControlsWithSpokenReason() {
        listOf(
            ConnectionState.Offline,
            ConnectionState.Revoked,
            ConnectionState.Error(SessionErrorReason.UNREACHABLE),
        ).forEach { connection ->
            val state = HomeUiMapper.map(Fixtures.home(connection), now)
            assertEquals(HomePhase.CONTENT, state.phase) // data is still shown
            assertTrue("$connection", state.rooms.all { !it.controlsEnabled })
            assertTrue("$connection", state.rooms.all { !it.disabledReason.isNullOrBlank() })
            assertEquals(ConnectionTone.BLOCKED, state.strip.single().tone)
        }
    }

    @Test
    fun groupWithoutGroupedLight_hasNoTargetAndIsDisabledWithReason() {
        val room = group(roomKey("r"), "Attic", children = emptyList(), groupedLight = null)
        val state = HomeUiMapper.map(homeOf(snapshot(rooms = listOf(room)) to ConnectionState.Connected), now)
        val card = state.rooms.single()
        assertNull(card.target)
        assertFalse(card.controlsEnabled)
        assertEquals(0, card.lightCount)
        assertTrue(card.disabledReason!!.contains("no grouped light"))
    }

    @Test
    fun brightnessNull_isNullNotZero() {
        val room = group(roomKey("r"), "Hall", children = emptyList(), groupedLight = groupedKey("g"))
        val gl = grouped(groupedKey("g"), isOn = true, brightness = null)
        val state = HomeUiMapper.map(
            homeOf(snapshot(rooms = listOf(room), groupedLights = listOf(gl)) to ConnectionState.Connected),
            now,
        )
        assertNull(state.rooms.single().brightness)
        assertEquals("On · 0 lights", state.rooms.single().subtitle)
    }

    @Test
    fun twoBridges_sameRoomId_yieldTwoDistinctCards_labelsDisambiguate() {
        val a = snapshot(
            bridge = BRIDGE_A,
            rooms = listOf(group(roomKey("same", BRIDGE_A), "Kitchen", emptyList(), groupedKey("g", BRIDGE_A))),
            groupedLights = listOf(grouped(groupedKey("g", BRIDGE_A), isOn = true, brightness = 10.0)),
        )
        val b = snapshot(
            bridge = BRIDGE_B,
            rooms = listOf(group(roomKey("same", BRIDGE_B), "Kitchen", emptyList(), groupedKey("g", BRIDGE_B))),
            groupedLights = listOf(grouped(groupedKey("g", BRIDGE_B), isOn = false, brightness = 90.0)),
        )
        val state = HomeUiMapper.map(homeOf(a to ConnectionState.Connected, b to ConnectionState.Offline), now)
        assertEquals(2, state.rooms.size)
        assertEquals(2, state.rooms.map { it.composeKey }.toSet().size)
        val onA = state.rooms.first { it.bridgeId == BRIDGE_A }
        val onB = state.rooms.first { it.bridgeId == BRIDGE_B }
        assertTrue(onA.controlsEnabled)
        assertFalse(onB.controlsEnabled)
        assertEquals(listOf("Bridge …0001", "Bridge …0002"), state.strip.map { it.bridgeLabel })
    }

    @Test
    fun singleBridge_labelIsPlainBridge_neverTheFullId() {
        val state = HomeUiMapper.map(Fixtures.home(), now)
        assertEquals("Bridge", state.strip.single().bridgeLabel)
        assertFalse(state.strip.single().statusText.contains(BRIDGE_A.value))
    }

    @Test
    fun staleFromCache_snapshotStillRendersAsContent() {
        val cached = Fixtures.bridgeA().copy(freshness = Freshness.Stale(0, StaleReason.FROM_CACHE))
        val state = HomeUiMapper.map(homeOf(cached to ConnectionState.Connecting), now)
        assertEquals(HomePhase.CONTENT, state.phase)
        assertTrue(state.rooms.all { it.controlsEnabled })
        assertEquals("Connecting", state.strip.single().statusText)
    }

    @Test
    fun staleFor_formats() {
        assertEquals("for under a minute", HomeUiMapper.staleFor(30_000))
        assertEquals("for 5 min", HomeUiMapper.staleFor(5 * 60_000))
        assertEquals("for 2 h", HomeUiMapper.staleFor(125 * 60_000))
    }
}
