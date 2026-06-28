package com.chromaglow.app.app

import androidx.activity.ComponentActivity
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsOff
import androidx.compose.ui.test.assertIsOn
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onFirst
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.chromaglow.app.feature.dashboard.DASHBOARD_SCENES_TAG
import com.chromaglow.app.feature.dashboard.DASHBOARD_SETTINGS_TAG
import com.chromaglow.app.feature.dashboard.DEMO_ROOM_SWITCH_TAG
import com.chromaglow.app.feature.dashboard.demoRoomOpenTag
import com.chromaglow.app.feature.roomdetail.ROOM_DETAIL_BACK_TAG
import com.chromaglow.app.feature.roomdetail.roomDetailLightSliderTag
import com.chromaglow.app.feature.roomdetail.roomDetailLightSwitchTag
import com.chromaglow.app.feature.scenes.sceneActiveIndicatorTag
import com.chromaglow.app.feature.scenes.sceneRowTag
import com.chromaglow.app.feature.settings.SETTINGS_BACK_TAG
import com.chromaglow.app.feature.settings.SETTINGS_DEMO_STATUS_TAG
import com.chromaglow.app.feature.settings.SETTINGS_EXIT_DEMO_TAG
import com.chromaglow.app.feature.settings.SETTINGS_VERSION_TAG
import com.chromaglow.app.ui.theme.ChromaGlowTheme
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Full-app navigation E2E: drives the real [ChromaGlowApp] router (Setup -> Dashboard -> the three
 * Wave 1 feature screens and back) and exercises BEHAVIOR on each screen rather than just routing.
 *
 * Beyond exercising each screen, this proves the D-009 correction: demo mutations made on one
 * screen survive leaving and reopening that screen. The router removes inactive destinations from
 * composition, so persistence is only possible because [ChromaGlowApp] owns the in-memory demo
 * room/light/scene state and re-seeds each reopened screen from it.
 *
 * Demo identifiers are the canonical DemoFixtures ids (Living Room = `demo-room-living`; its first
 * light is `demo-light-living-1` at 78% and starts On). They are referenced here as literals so the
 * test asserts the wired data, not a re-read of the fixtures.
 */
@RunWith(AndroidJUnit4::class)
class NavIntegrationE2ETest {

    @get:Rule
    val composeTestRule = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun fullDemoNavigation_exercisesEachScreenAndReturns() {
        composeTestRule.setContent {
            ChromaGlowTheme {
                ChromaGlowApp()
            }
        }

        // --- Setup -> Dashboard ---
        composeTestRule.onNodeWithText("Enter Demo Mode").assertIsDisplayed()
        composeTestRule.onNodeWithText("Enter Demo Mode").performClick()
        composeTestRule.onNodeWithText("Demo Dashboard").assertIsDisplayed()
        composeTestRule.onNodeWithText("Living Room").assertIsDisplayed()

        // --- Dashboard -> RoomDetail (open Living Room via its discrete open affordance) ---
        composeTestRule.onNodeWithTag(demoRoomOpenTag("demo-room-living")).performClick()
        composeTestRule.onNodeWithText("Sofa Lamp").assertIsDisplayed()

        // Toggle the first light off and assert the row's status line reflects it.
        val livingLightSwitch = composeTestRule.onNodeWithTag(roomDetailLightSwitchTag("demo-light-living-1"))
        livingLightSwitch.assertIsOn() // Living Room demo lights start on.
        livingLightSwitch.performClick()
        livingLightSwitch.assertIsOff()
        composeTestRule.onNodeWithText("Off · 78%").assertIsDisplayed()

        // Change its brightness and assert the same row reflects the new value.
        composeTestRule.onNodeWithTag(roomDetailLightSliderTag("demo-light-living-1"))
            .performSemanticsAction(SemanticsActions.SetProgress) { setProgress -> setProgress(30f) }
        composeTestRule.onNodeWithText("Off · 30%").assertIsDisplayed()

        // --- RoomDetail -> Dashboard ---
        composeTestRule.onNodeWithTag(ROOM_DETAIL_BACK_TAG).performClick()
        composeTestRule.onNodeWithText("Demo Dashboard").assertIsDisplayed()

        // --- PERSISTENCE (D-009): reopen the SAME room; the light edit must survive navigation ---
        // The router removed RoomDetail from composition on Back, so the changed light is only still
        // Off/30% if the app shell owns the light state and re-seeds the reopened screen from it.
        composeTestRule.onNodeWithTag(demoRoomOpenTag("demo-room-living")).performClick()
        composeTestRule.onNodeWithText("Sofa Lamp").assertIsDisplayed()
        composeTestRule.onNodeWithTag(roomDetailLightSwitchTag("demo-light-living-1")).assertIsOff()
        composeTestRule.onNodeWithText("Off · 30%").assertIsDisplayed()
        composeTestRule.onNodeWithTag(ROOM_DETAIL_BACK_TAG).performClick()
        composeTestRule.onNodeWithText("Demo Dashboard").assertIsDisplayed()

        // --- Dashboard -> Scenes (activate an inactive scene; assert exclusive activation) ---
        composeTestRule.onNodeWithTag(DASHBOARD_SCENES_TAG).performClick()
        composeTestRule.onNodeWithText("Energize").assertIsDisplayed()

        // Relax ships active; Energize is inactive. The active indicator is a merged descendant of
        // the clickable Surface, so it is only independently addressable in the unmerged tree.
        composeTestRule.onNodeWithTag(sceneActiveIndicatorTag("demo-scene-relax"), useUnmergedTree = true)
            .assertIsDisplayed()
        composeTestRule.onNodeWithTag(sceneActiveIndicatorTag("demo-scene-energize"), useUnmergedTree = true)
            .assertDoesNotExist()

        composeTestRule.onNodeWithTag(sceneRowTag("demo-scene-energize")).performClick()

        // Exclusive activation: indicator moves to Energize and the previous Relax indicator clears.
        composeTestRule.onNodeWithTag(sceneActiveIndicatorTag("demo-scene-energize"), useUnmergedTree = true)
            .assertIsDisplayed()
        composeTestRule.onNodeWithTag(sceneActiveIndicatorTag("demo-scene-relax"), useUnmergedTree = true)
            .assertDoesNotExist()

        // --- Scenes -> Dashboard ---
        composeTestRule.onNodeWithText("Back").performClick()
        composeTestRule.onNodeWithText("Demo Dashboard").assertIsDisplayed()

        // --- PERSISTENCE (D-009): reopen Scenes; the activation must survive navigation ---
        // Scenes left composition on Back, so Energize is only still active (and the previously
        // active Relax inactive) because the app shell owns the scene state across navigation.
        composeTestRule.onNodeWithTag(DASHBOARD_SCENES_TAG).performClick()
        composeTestRule.onNodeWithText("Energize").assertIsDisplayed()
        composeTestRule.onNodeWithTag(sceneActiveIndicatorTag("demo-scene-energize"), useUnmergedTree = true)
            .assertIsDisplayed()
        composeTestRule.onNodeWithTag(sceneActiveIndicatorTag("demo-scene-relax"), useUnmergedTree = true)
            .assertDoesNotExist()
        composeTestRule.onNodeWithText("Back").performClick()
        composeTestRule.onNodeWithText("Demo Dashboard").assertIsDisplayed()

        // --- Dashboard -> Settings (assert demo-mode + version are shown) ---
        composeTestRule.onNodeWithTag(DASHBOARD_SETTINGS_TAG).performClick()
        composeTestRule.onNodeWithTag(SETTINGS_DEMO_STATUS_TAG).assertTextEquals("Demo Mode")
        composeTestRule.onNodeWithTag(SETTINGS_VERSION_TAG).assertTextEquals("1.0")

        // --- Settings -> Dashboard ---
        composeTestRule.onNodeWithTag(SETTINGS_BACK_TAG).performClick()
        composeTestRule.onNodeWithText("Demo Dashboard").assertIsDisplayed()

        // --- Reopen Settings -> Exit Demo Mode -> back at Setup ---
        composeTestRule.onNodeWithTag(DASHBOARD_SETTINGS_TAG).performClick()
        composeTestRule.onNodeWithTag(SETTINGS_EXIT_DEMO_TAG).performClick()
        composeTestRule.onNodeWithText("Scan for Bridge").assertIsDisplayed()
        composeTestRule.onNodeWithText("Enter Demo Mode").assertIsDisplayed()
    }

    /**
     * A dashboard room toggle is owned by [ChromaGlowApp], so it must survive navigating to another
     * screen and reopening the dashboard. Rooms render sorted by name, so the first row is the
     * Kitchen (ships On at 100% with 8 lights); toggling it off and returning from Settings must
     * still show it off.
     */
    @Test
    fun dashboardRoomToggle_survivesReopeningDashboard() {
        composeTestRule.setContent {
            ChromaGlowTheme {
                ChromaGlowApp()
            }
        }

        composeTestRule.onNodeWithText("Enter Demo Mode").performClick()
        composeTestRule.onNodeWithText("Demo Dashboard").assertIsDisplayed()

        // Kitchen ships On · 100% · 8 lights and is the first (top) row.
        composeTestRule.onNodeWithText("On · 100% · 8 lights").assertIsDisplayed()
        composeTestRule.onAllNodesWithTag(DEMO_ROOM_SWITCH_TAG).onFirst().performClick()
        composeTestRule.onNodeWithText("Off · 100% · 8 lights").assertIsDisplayed()

        // Navigate to Settings and back; the dashboard left composition in between.
        composeTestRule.onNodeWithTag(DASHBOARD_SETTINGS_TAG).performClick()
        composeTestRule.onNodeWithTag(SETTINGS_DEMO_STATUS_TAG).assertTextEquals("Demo Mode")
        composeTestRule.onNodeWithTag(SETTINGS_BACK_TAG).performClick()

        // The toggle persisted because the app shell owns the room state across navigation.
        composeTestRule.onNodeWithText("Demo Dashboard").assertIsDisplayed()
        composeTestRule.onNodeWithText("Off · 100% · 8 lights").assertIsDisplayed()
    }
}
