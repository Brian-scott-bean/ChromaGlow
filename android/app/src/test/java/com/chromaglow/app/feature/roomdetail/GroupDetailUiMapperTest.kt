package com.chromaglow.app.feature.roomdetail

import com.chromaglow.app.core.identity.TargetRef
import com.chromaglow.app.core.session.ConnectionState
import com.chromaglow.app.core.session.GroupKind
import com.chromaglow.app.feature.testing.BRIDGE_A
import com.chromaglow.app.feature.testing.Caps
import com.chromaglow.app.feature.testing.Fixtures
import com.chromaglow.app.feature.testing.group
import com.chromaglow.app.feature.testing.grouped
import com.chromaglow.app.feature.testing.groupedKey
import com.chromaglow.app.feature.testing.homeOf
import com.chromaglow.app.feature.testing.key
import com.chromaglow.app.feature.testing.light
import com.chromaglow.app.feature.testing.roomKey
import com.chromaglow.app.feature.testing.snapshot
import com.chromaglow.app.core.identity.ResourceType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class GroupDetailUiMapperTest {

    @Test
    fun livingRoom_mapsGroupInstrumentAndMembers_sortedByName() {
        val state = GroupDetailUiMapper.map(Fixtures.home(), Fixtures.livingRoom, 0L)
        assertTrue(state.found)
        assertEquals("Living Room", state.group!!.name)
        assertEquals(GroupKind.ROOM, state.group!!.kind)
        assertEquals(TargetRef.Live(Fixtures.livingGrouped), state.group!!.target)
        assertEquals(listOf("Ceiling", "Floor Lamp"), state.lights.map { it.name })
        assertEquals(2, state.group!!.lightCount)
    }

    @Test
    fun zone_mapsAsZone_withItsOwnMembers() {
        val state = GroupDetailUiMapper.map(Fixtures.home(), Fixtures.upstairs, 0L)
        assertEquals(GroupKind.ZONE, state.group!!.kind)
        assertEquals(listOf("Floor Lamp", "Reading Light"), state.lights.map { it.name })
    }

    @Test
    fun unknownGroup_isNotFound_andRendersNothingFromDemo() {
        val state = GroupDetailUiMapper.map(Fixtures.home(), roomKey("missing"), 0L)
        assertFalse(state.found)
        assertNull(state.group)
        assertTrue(state.lights.isEmpty())
        assertEquals(1, state.strip.size)
    }

    @Test
    fun glyphs_onlyForKnownCapabilities() {
        val state = GroupDetailUiMapper.map(Fixtures.home(), Fixtures.livingRoom, 0L)
        val ceiling = state.lights.first { it.name == "Ceiling" }
        val floor = state.lights.first { it.name == "Floor Lamp" }
        assertTrue(ceiling.knownGlyphs.isEmpty()) // white-only: nothing advertised
        assertEquals(listOf("Colour", "Warmth", "Effects"), floor.knownGlyphs)
    }

    @Test
    fun unknownCapabilities_produceNoGlyphs_andNoCoverageClaim() {
        val l = light("u", "Mystery", capabilities = Caps.unknown())
        assertTrue(GroupDetailUiMapper.glyphs(l).isEmpty())
        assertTrue(GroupDetailUiMapper.coverageLines(listOf(l)).isEmpty())
    }

    @Test
    fun coverageLines_countKnownOnly() {
        val state = GroupDetailUiMapper.map(Fixtures.home(), Fixtures.livingRoom, 0L)
        assertEquals(
            listOf("1 of 2 lights support colour", "1 of 2 lights support warmth", "1 of 2 lights support effects"),
            state.coverage,
        )
        val bed = GroupDetailUiMapper.map(Fixtures.home(), Fixtures.bedroom, 0L)
        assertEquals(listOf("This light supports warmth"), bed.coverage)
    }

    @Test
    fun membershipViaOwnerDevice_isCounted() {
        val device = key(BRIDGE_A, ResourceType.DEVICE, "dev-1")
        val room = group(roomKey("r"), "Study", children = listOf(device), groupedLight = groupedKey("g"))
        val owned = light("l1", "Desk", owner = device)
        val home = homeOf(
            snapshot(rooms = listOf(room), groupedLights = listOf(grouped(groupedKey("g"))), lights = listOf(owned)) to ConnectionState.Connected,
        )
        val state = GroupDetailUiMapper.map(home, roomKey("r"), 0L)
        assertEquals(listOf("Desk"), state.lights.map { it.name })
        assertEquals(1, state.group!!.lightCount)
    }

    @Test
    fun offline_disablesGroupAndEveryLight_withReason() {
        val state = GroupDetailUiMapper.map(Fixtures.home(ConnectionState.Offline), Fixtures.livingRoom, 0L)
        assertFalse(state.group!!.controlsEnabled)
        assertTrue(state.lights.all { !it.controlsEnabled && !it.disabledReason.isNullOrBlank() })
    }

    @Test
    fun lightCard_carriesTruthNotPaint_mirekOnlyWhenValid() {
        val state = GroupDetailUiMapper.map(Fixtures.home(), Fixtures.livingRoom, 0L)
        val floor = state.lights.first { it.name == "Floor Lamp" }
        assertNull(floor.mirek) // mirekValid == false in fixtures
        assertEquals(0.45, floor.colorXy!!.x, 1e-9)
        assertEquals("On · 72%", floor.statusLine)
        val bed = GroupDetailUiMapper.map(Fixtures.home(), Fixtures.bedroom, 0L)
        assertEquals(366, bed.lights.single().mirek)
    }
}
