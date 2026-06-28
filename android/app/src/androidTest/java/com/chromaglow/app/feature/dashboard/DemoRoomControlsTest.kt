package com.chromaglow.app.feature.dashboard

import androidx.activity.ComponentActivity
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.chromaglow.app.core.model.RoomDisplayModel
import com.chromaglow.app.ui.theme.ChromaGlowTheme
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class DemoRoomControlsTest {

    @get:Rule
    val composeTestRule = createAndroidComposeRule<ComponentActivity>()

    private fun setHarness(initial: RoomDisplayModel) {
        composeTestRule.setContent {
            ChromaGlowTheme {
                // Hoisted-state harness: onToggle/onBrightnessChange mutate the remembered
                // room so the row re-renders, mirroring DashboardPlaceholderScreen.
                var room by remember { mutableStateOf(initial) }
                DemoRoomRow(
                    room = room,
                    onToggle = { isOn -> room = room.copy(isOn = isOn) },
                    onBrightnessChange = { brightness ->
                        room = room.copy(brightness = brightness.coerceIn(1, 100))
                    },
                )
            }
        }
    }

    private fun room(
        isOn: Boolean = true,
        brightness: Int = 78,
        lightCount: Int = 5,
    ): RoomDisplayModel = RoomDisplayModel(
        id = "room-1",
        name = "Test Room",
        isOn = isOn,
        brightness = brightness,
        lightCount = lightCount,
        bridgeId = "bridge-1",
    )

    @Test
    fun togglingSwitch_flipsIsOnInStatusLine() {
        setHarness(room(isOn = true, brightness = 78, lightCount = 5))

        composeTestRule.onNodeWithText("On · 78% · 5 lights").assertIsDisplayed()

        composeTestRule.onNodeWithTag(DEMO_ROOM_SWITCH_TAG).performClick()

        composeTestRule.onNodeWithText("Off · 78% · 5 lights").assertIsDisplayed()

        // Toggle back to confirm the hoisted state round-trips.
        composeTestRule.onNodeWithTag(DEMO_ROOM_SWITCH_TAG).performClick()

        composeTestRule.onNodeWithText("On · 78% · 5 lights").assertIsDisplayed()
    }

    @Test
    fun draggingSlider_updatesBrightnessWithinRange() {
        setHarness(room(isOn = true, brightness = 78, lightCount = 5))

        composeTestRule.onNodeWithText("On · 78% · 5 lights").assertIsDisplayed()

        // Set the brightness slider to a concrete in-range value via its semantics action.
        composeTestRule.onNodeWithTag(DEMO_ROOM_BRIGHTNESS_SLIDER_TAG)
            .performSemanticsAction(SemanticsActions.SetProgress) { setProgress -> setProgress(30f) }

        composeTestRule.onNodeWithText("On · 30% · 5 lights").assertIsDisplayed()
    }

    @Test
    fun sliderToMinimum_clampsBrightnessToOne() {
        setHarness(room(isOn = true, brightness = 78, lightCount = 5))

        composeTestRule.onNodeWithTag(DEMO_ROOM_BRIGHTNESS_SLIDER_TAG)
            .performSemanticsAction(SemanticsActions.SetProgress) { setProgress -> setProgress(1f) }

        // Lowest valid brightness is 1 (RoomDisplayModel requires brightness in 1..100).
        composeTestRule.onNodeWithText("On · 1% · 5 lights").assertIsDisplayed()
    }
}
