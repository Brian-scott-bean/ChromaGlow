package com.chromaglow.app.feature.scenes

import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertHeightIsAtLeast
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertIsNotSelected
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.chromaglow.app.core.session.ConnectionState
import com.chromaglow.app.testing.BRIDGE_A
import com.chromaglow.app.testing.BRIDGE_B
import com.chromaglow.app.testing.Fixtures
import com.chromaglow.app.testing.homeOf
import com.chromaglow.app.testing.roomKey
import com.chromaglow.app.testing.scene
import com.chromaglow.app.testing.sceneKey
import com.chromaglow.app.testing.snapshot
import com.chromaglow.app.ui.theme.ChromaGlowTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LiveScenesScreenTest {

    @get:Rule
    val rule = createComposeRule()

    private val activated = mutableListOf<SceneRowUi>()

    private fun show(state: LiveScenesUiState) {
        rule.setContent {
            ChromaGlowTheme { LiveScenesScreen(state = state, onBack = {}, onActivate = { activated += it }, onRefresh = {}) }
        }
    }

    private fun fixtures(connection: ConnectionState = ConnectionState.Connected, pending: Set<com.chromaglow.app.core.identity.ResourceKey> = emptySet(), failed: Set<com.chromaglow.app.core.identity.ResourceKey> = emptySet()) =
        LiveScenesUiMapper.map(Fixtures.home(connection), pending, failed, 0L)

    @Test
    fun rendersGroupsAndRows_activeSelected_othersNot() {
        show(fixtures())
        rule.onNodeWithText("Living Room").assertIsDisplayed()
        rule.onNodeWithText("Bedroom").assertIsDisplayed()
        val relax = rule.onNodeWithTag(liveSceneRowTag(Fixtures.sceneRelax.composeKey))
        relax.assertIsSelected()
        relax.assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "Active"))
        relax.assertHeightIsAtLeast(48.dp)
        rule.onNodeWithTag(liveSceneRowTag(Fixtures.sceneBright.composeKey)).assertIsNotSelected()
        rule.onNodeWithText("Dynamic").assertIsDisplayed()
    }

    @Test
    fun tapRow_forwardsExactScene() {
        show(fixtures())
        rule.onNodeWithTag(liveSceneRowTag(Fixtures.sceneBright.composeKey)).performClick()
        assertEquals(Fixtures.sceneBright, activated.single().key)
    }

    @Test
    fun activatingRow_isSpokenAndNotClickable() {
        show(fixtures(pending = setOf(Fixtures.sceneBright)))
        val row = rule.onNodeWithTag(liveSceneRowTag(Fixtures.sceneBright.composeKey))
        row.assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "Activating…"))
        row.assertIsNotEnabled()
        row.assert(SemanticsMatcher.keyIsDefined(SemanticsProperties.LiveRegion))
    }

    @Test
    fun failedRow_saysSo_inWords() {
        show(fixtures(failed = setOf(Fixtures.sceneBright)))
        rule.onNodeWithText("Didn't activate").assertIsDisplayed()
    }

    @Test
    fun offline_rowsDisabled_withReason_tapDoesNothing() {
        show(fixtures(ConnectionState.Offline))
        val row = rule.onNodeWithTag(liveSceneRowTag(Fixtures.sceneBright.composeKey))
        row.assertIsNotEnabled()
        row.performClick()
        rule.waitForIdle()
        assertTrue(activated.isEmpty())
    }

    @Test
    fun twoBridges_showBridgeHeadings() {
        val a = snapshot(bridge = BRIDGE_A, scenes = listOf(scene(sceneKey("s", BRIDGE_A), "Relax", roomKey("r", BRIDGE_A))))
        val b = snapshot(bridge = BRIDGE_B, scenes = listOf(scene(sceneKey("s", BRIDGE_B), "Relax", roomKey("r", BRIDGE_B))))
        show(LiveScenesUiMapper.map(homeOf(a to ConnectionState.Connected, b to ConnectionState.Connected), emptySet(), emptySet(), 0L))
        rule.onNodeWithTag(liveSceneBridgeHeaderTag("Bridge …0001")).assertIsDisplayed()
        rule.onNodeWithTag(liveSceneBridgeHeaderTag("Bridge …0002")).assertIsDisplayed()
    }

    @Test
    fun empty_showsHonestEmptyState() {
        show(LiveScenesUiMapper.map(homeOf(snapshot(generation = 1) to ConnectionState.Connected), emptySet(), emptySet(), 0L))
        rule.onNodeWithText("No scenes yet").assertIsDisplayed()
    }
}
