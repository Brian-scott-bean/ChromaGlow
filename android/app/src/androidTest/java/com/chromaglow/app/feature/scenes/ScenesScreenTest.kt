package com.chromaglow.app.feature.scenes

import androidx.activity.ComponentActivity
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.chromaglow.app.data.demo.DemoFixtures
import com.chromaglow.app.ui.theme.ChromaGlowTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ScenesScreenTest {

    @get:Rule
    val composeTestRule = createAndroidComposeRule<ComponentActivity>()

    // Only the androidTest reads DemoFixtures (D-008); the screen takes its data via parameters.
    private val demoScenes = DemoFixtures.scenes
    private val roomNames: Map<String, String> = DemoFixtures.rooms.associate { it.id to it.name }

    @Test
    fun rendersAllDemoScenes_withRoomLabels_andRelaxActiveOnLaunch() {
        composeTestRule.setContent {
            ChromaGlowTheme {
                ScenesScreen(scenes = demoScenes, roomNames = roomNames)
            }
        }

        // Every demo scene name renders, alongside its resolved room label.
        demoScenes.forEach { scene ->
            composeTestRule.onNodeWithText(scene.name).assertIsDisplayed()
            composeTestRule.onNodeWithText(roomNames.getValue(scene.roomId)).assertIsDisplayed()
        }

        // Relax ships isActive = true; exactly that scene shows the active indicator.
        // The indicator Text is a merged descendant of the clickable Surface (which sets
        // MergeDescendants = true), so it is only an independently displayed node in the
        // unmerged semantics tree; query it there for both presence and absence checks.
        composeTestRule.onNodeWithTag(sceneActiveIndicatorTag("demo-scene-relax"), useUnmergedTree = true)
            .assertIsDisplayed()
        composeTestRule.onNodeWithTag(sceneActiveIndicatorTag("demo-scene-energize"), useUnmergedTree = true)
            .assertDoesNotExist()
        composeTestRule.onNodeWithTag(sceneActiveIndicatorTag("demo-scene-focus"), useUnmergedTree = true)
            .assertDoesNotExist()
        composeTestRule.onNodeWithTag(sceneActiveIndicatorTag("demo-scene-nightlight"), useUnmergedTree = true)
            .assertDoesNotExist()
    }

    @Test
    fun activatingInactiveScene_movesIndicator_clearsPrevious_andReportsBridgeAndId() {
        var lastBridgeId: String? = null
        var lastSceneId: String? = null
        var activationCount = 0

        composeTestRule.setContent {
            ChromaGlowTheme {
                ScenesScreen(
                    scenes = demoScenes,
                    roomNames = roomNames,
                    onActivateScene = { bridgeId, sceneId ->
                        lastBridgeId = bridgeId
                        lastSceneId = sceneId
                        activationCount++
                    },
                )
            }
        }

        // Precondition: Relax active, Energize inactive. The active indicator is a merged
        // descendant of the clickable Surface, so query it in the unmerged tree.
        composeTestRule.onNodeWithTag(sceneActiveIndicatorTag("demo-scene-relax"), useUnmergedTree = true)
            .assertIsDisplayed()
        composeTestRule.onNodeWithTag(sceneActiveIndicatorTag("demo-scene-energize"), useUnmergedTree = true)
            .assertDoesNotExist()

        // Activate the currently-inactive Energize scene.
        composeTestRule.onNodeWithTag(sceneRowTag("demo-scene-energize")).performClick()

        // Indicator moves to Energize and the previously-active Relax indicator is cleared.
        composeTestRule.onNodeWithTag(sceneActiveIndicatorTag("demo-scene-energize"), useUnmergedTree = true)
            .assertIsDisplayed()
        composeTestRule.onNodeWithTag(sceneActiveIndicatorTag("demo-scene-relax"), useUnmergedTree = true)
            .assertDoesNotExist()

        // Callback reports the selected scene's bridgeId and id (bridgeId is not rendered).
        composeTestRule.runOnIdle {
            assertEquals(1, activationCount)
            assertEquals(DemoFixtures.DEMO_BRIDGE_ID, lastBridgeId)
            assertEquals("demo-scene-energize", lastSceneId)
        }
    }

    @Test
    fun activatingAnotherInactiveScene_isExclusive() {
        var lastSceneId: String? = null

        composeTestRule.setContent {
            ChromaGlowTheme {
                ScenesScreen(
                    scenes = demoScenes,
                    roomNames = roomNames,
                    onActivateScene = { _, sceneId -> lastSceneId = sceneId },
                )
            }
        }

        // Activate Focus (inactive on launch); only Focus ends up active.
        composeTestRule.onNodeWithTag(sceneRowTag("demo-scene-focus")).performClick()

        // The active indicator is a merged descendant of the clickable Surface; query the
        // unmerged tree so the displayed indicator is independently addressable.
        composeTestRule.onNodeWithTag(sceneActiveIndicatorTag("demo-scene-focus"), useUnmergedTree = true)
            .assertIsDisplayed()
        composeTestRule.onNodeWithTag(sceneActiveIndicatorTag("demo-scene-relax"), useUnmergedTree = true)
            .assertDoesNotExist()
        composeTestRule.onNodeWithTag(sceneActiveIndicatorTag("demo-scene-energize"), useUnmergedTree = true)
            .assertDoesNotExist()
        composeTestRule.onNodeWithTag(sceneActiveIndicatorTag("demo-scene-nightlight"), useUnmergedTree = true)
            .assertDoesNotExist()

        composeTestRule.runOnIdle {
            assertEquals("demo-scene-focus", lastSceneId)
        }
    }

    @Test
    fun backButton_invokesOnBack() {
        var backCount = 0

        composeTestRule.setContent {
            ChromaGlowTheme {
                ScenesScreen(scenes = demoScenes, onBack = { backCount++ })
            }
        }

        composeTestRule.onNodeWithText("Back").performClick()

        composeTestRule.runOnIdle { assertEquals(1, backCount) }
    }
}
