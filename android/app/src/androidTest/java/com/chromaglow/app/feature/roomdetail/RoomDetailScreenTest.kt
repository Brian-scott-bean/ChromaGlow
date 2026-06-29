package com.chromaglow.app.feature.roomdetail

import androidx.activity.ComponentActivity
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsOff
import androidx.compose.ui.test.assertIsOn
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.chromaglow.app.core.model.LightDisplayModel
import com.chromaglow.app.core.model.RoomDisplayModel
import com.chromaglow.app.data.demo.DemoFixtures
import com.chromaglow.app.ui.theme.ChromaGlowTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class RoomDetailScreenTest {

    @get:Rule
    val composeTestRule = createAndroidComposeRule<ComponentActivity>()

    // Demo data is supplied to the screen from the test only (D-008: the source never reads
    // DemoFixtures). Living Room has lightCount 5 with 5 backing lights.
    private val room: RoomDisplayModel =
        DemoFixtures.rooms.first { it.id == "demo-room-living" }
    private val lights: List<LightDisplayModel> =
        DemoFixtures.lightsByRoom[room.id] ?: emptyList()

    // The first (top, always-displayed) light drives interaction assertions.
    private val firstLight: LightDisplayModel = lights.first()

    private data class ToggleEvent(val bridgeId: String, val lightId: String, val isOn: Boolean)
    private data class BrightnessEvent(val bridgeId: String, val lightId: String, val brightness: Int)

    private var lastToggle: ToggleEvent? = null
    private var lastBrightness: BrightnessEvent? = null
    private var backCount: Int = 0

    private fun setScreen() {
        composeTestRule.setContent {
            ChromaGlowTheme {
                RoomDetailScreen(
                    room = room,
                    lights = lights,
                    onLightToggle = { bridgeId, lightId, isOn ->
                        lastToggle = ToggleEvent(bridgeId, lightId, isOn)
                    },
                    onLightBrightnessChange = { bridgeId, lightId, brightness ->
                        lastBrightness = BrightnessEvent(bridgeId, lightId, brightness)
                    },
                    onBack = { backCount++ },
                )
            }
        }
    }

    @Test
    fun rendersExactlyOneRowPerLight() {
        setScreen()

        composeTestRule.onNodeWithText(room.name).assertIsDisplayed()
        composeTestRule
            .onAllNodesWithTag(ROOM_DETAIL_LIGHT_ROW_TAG, useUnmergedTree = true)
            .assertCountEquals(room.lightCount)
    }

    @Test
    fun togglingLight_flipsIsOnInUi_andForwardsIdentity() {
        setScreen()

        val switch = composeTestRule.onNodeWithTag(roomDetailLightSwitchTag(firstLight.id))
        switch.assertIsOn() // demo Living Room lights start on

        switch.performClick()

        switch.assertIsOff()
        // Row status line reflects the flipped state (firstLight brightness is unique among rows).
        composeTestRule.onNodeWithText("Off · ${firstLight.brightness}%").assertIsDisplayed()

        // Callback carries the selected light's bridgeId + id and the new state.
        assertEquals(firstLight.bridgeId, lastToggle?.bridgeId)
        assertEquals(firstLight.id, lastToggle?.lightId)
        assertEquals(false, lastToggle?.isOn)
    }

    @Test
    fun draggingSlider_updatesBrightnessWithinRange_andReflectsInRow() {
        setScreen()

        composeTestRule.onNodeWithTag(roomDetailLightSliderTag(firstLight.id))
            .performSemanticsAction(SemanticsActions.SetProgress) { setProgress -> setProgress(30f) }

        // Reflected in the row status line.
        composeTestRule.onNodeWithText("On · 30%").assertIsDisplayed()

        // Callback carries identity + an in-range brightness.
        assertEquals(firstLight.bridgeId, lastBrightness?.bridgeId)
        assertEquals(firstLight.id, lastBrightness?.lightId)
        assertEquals(30, lastBrightness?.brightness)
        val value = lastBrightness?.brightness ?: -1
        assertTrue("brightness must stay in 1..100 but was $value", value in 1..100)
    }

    @Test
    fun sliderToMinimum_clampsBrightnessToOne() {
        setScreen()

        composeTestRule.onNodeWithTag(roomDetailLightSliderTag(firstLight.id))
            .performSemanticsAction(SemanticsActions.SetProgress) { setProgress -> setProgress(1f) }

        // Lowest valid brightness is 1 (LightDisplayModel requires brightness in 1..100).
        composeTestRule.onNodeWithText("On · 1%").assertIsDisplayed()
        assertEquals(1, lastBrightness?.brightness)
    }

    @Test
    fun backButton_firesOnBack() {
        setScreen()

        assertNull(lastToggle)
        assertEquals(0, backCount)

        composeTestRule.onNodeWithTag(ROOM_DETAIL_BACK_TAG).performClick()

        assertEquals(1, backCount)
    }
}
