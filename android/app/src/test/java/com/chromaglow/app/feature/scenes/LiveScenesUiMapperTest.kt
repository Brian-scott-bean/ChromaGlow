package com.chromaglow.app.feature.scenes

import com.chromaglow.app.core.session.BridgeSnapshot
import com.chromaglow.app.core.session.ConnectionState
import com.chromaglow.app.core.session.HomeSnapshot
import com.chromaglow.app.feature.testing.BRIDGE_A
import com.chromaglow.app.feature.testing.BRIDGE_B
import com.chromaglow.app.feature.testing.Fixtures
import com.chromaglow.app.feature.testing.homeOf
import com.chromaglow.app.feature.testing.roomKey
import com.chromaglow.app.feature.testing.scene
import com.chromaglow.app.feature.testing.sceneKey
import com.chromaglow.app.feature.testing.snapshot
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LiveScenesUiMapperTest {

    private fun map(home: HomeSnapshot, pending: Set<com.chromaglow.app.core.identity.ResourceKey> = emptySet(), failed: Set<com.chromaglow.app.core.identity.ResourceKey> = emptySet()) =
        LiveScenesUiMapper.map(home, pending, failed, 0L)

    @Test
    fun phases() {
        assertEquals(ScenesPhase.NO_BRIDGES, map(HomeSnapshot(emptyMap(), emptyMap())).phase)
        assertEquals(ScenesPhase.LOADING, map(homeOf(BridgeSnapshot.empty(BRIDGE_A) to ConnectionState.Connecting)).phase)
        assertEquals(ScenesPhase.EMPTY, map(homeOf(snapshot(generation = 1) to ConnectionState.Connected)).phase)
        assertEquals(ScenesPhase.CONTENT, map(Fixtures.home()).phase)
    }

    @Test
    fun sectionsByBridgeThenGroup_sortedByName_groupNamesResolved() {
        val state = map(Fixtures.home())
        val bridge = state.sections.single()
        assertEquals("Bridge", bridge.bridgeLabel)
        assertEquals(listOf("Bedroom", "Living Room"), bridge.groups.map { it.groupName })
        assertEquals(listOf("Bright", "Relax"), bridge.groups[1].scenes.map { it.name })
        assertEquals(listOf("Nightlight"), bridge.groups[0].scenes.map { it.name })
        assertTrue(bridge.groups[0].scenes.single().isDynamic)
    }

    @Test
    fun activation_isPerScene_notGloballyExclusive() {
        val a = snapshot(
            rooms = listOf(Fixtures.bridgeA().rooms.values.first { it.name == "Living Room" }, Fixtures.bridgeA().rooms.values.first { it.name == "Bedroom" }),
            scenes = listOf(
                scene(sceneKey("s1"), "Relax", Fixtures.livingRoom, isActive = true),
                scene(sceneKey("s2"), "Sleep", Fixtures.bedroom, isActive = true),
            ),
        )
        val state = map(homeOf(a to ConnectionState.Connected))
        val all = state.sections.single().groups.flatMap { it.scenes }
        assertEquals(2, all.count { it.activation == SceneActivation.ACTIVE })
    }

    @Test
    fun pendingAndFailed_layerOverIdle_butNeverOverBridgeActive() {
        val state = map(Fixtures.home(), pending = setOf(Fixtures.sceneBright, Fixtures.sceneRelax), failed = setOf(Fixtures.sceneBed))
        val rows = state.sections.single().groups.flatMap { it.scenes }.associateBy { it.name }
        assertEquals(SceneActivation.ACTIVATING, rows.getValue("Bright").activation)
        assertEquals(SceneActivation.ACTIVE, rows.getValue("Relax").activation) // bridge truth wins
        assertEquals(SceneActivation.FAILED, rows.getValue("Nightlight").activation)
    }

    @Test
    fun unknownGroup_fallsBackToOther() {
        val s = snapshot(scenes = listOf(scene(sceneKey("x"), "Orphan", roomKey("gone"))))
        val state = map(homeOf(s to ConnectionState.Connected))
        assertEquals("Other", state.sections.single().groups.single().groupName)
    }

    @Test
    fun offline_disablesRowsWithReason_stillListsThem() {
        val state = map(Fixtures.home(ConnectionState.Offline))
        val rows = state.sections.single().groups.flatMap { it.scenes }
        assertEquals(3, rows.size)
        assertTrue(rows.all { !it.enabled && !it.disabledReason.isNullOrBlank() })
    }

    @Test
    fun twoBridges_sameSceneId_twoRows_labelsDisambiguate() {
        val a = snapshot(bridge = BRIDGE_A, scenes = listOf(scene(sceneKey("same", BRIDGE_A), "Relax", roomKey("r", BRIDGE_A))))
        val b = snapshot(bridge = BRIDGE_B, scenes = listOf(scene(sceneKey("same", BRIDGE_B), "Relax", roomKey("r", BRIDGE_B))))
        val state = map(homeOf(a to ConnectionState.Connected, b to ConnectionState.Connected))
        assertEquals(listOf("Bridge …0001", "Bridge …0002"), state.sections.map { it.bridgeLabel })
        val keys = state.sections.flatMap { it.groups }.flatMap { it.scenes }.map { it.composeKey }
        assertEquals(2, keys.toSet().size)
        assertFalse(keys[0] == keys[1])
    }
}
