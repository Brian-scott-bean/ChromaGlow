package com.chromaglow.app.feature.settings

import androidx.activity.ComponentActivity
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.chromaglow.app.ui.theme.ChromaGlowTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SettingsScreenTest {

    @get:Rule
    val composeTestRule = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun rendersDemoModeIndicatorAndVersionString() {
        composeTestRule.setContent {
            ChromaGlowTheme {
                SettingsScreen(isDemoMode = true, appVersion = "1.0")
            }
        }

        composeTestRule.onNodeWithTag(SETTINGS_DEMO_STATUS_TAG).assertTextEquals("Demo Mode")
        composeTestRule.onNodeWithTag(SETTINGS_VERSION_TAG).assertTextEquals("1.0")
        composeTestRule.onNodeWithText("Exit Demo Mode").assertIsDisplayed()
    }

    @Test
    fun exitDemoControl_invokesOnExitDemo() {
        // Hoisted-state harness: capture the callback firing into a remembered counter so we
        // both assert the invocation and prove the screen re-renders against new state.
        var exitCount = 0
        composeTestRule.setContent {
            ChromaGlowTheme {
                var demoMode by remember { mutableStateOf(true) }
                SettingsScreen(
                    isDemoMode = demoMode,
                    appVersion = "1.0",
                    onExitDemo = {
                        exitCount++
                        demoMode = false
                    },
                )
            }
        }

        composeTestRule.onNodeWithTag(SETTINGS_EXIT_DEMO_TAG).performClick()

        assertEquals(1, exitCount)
        // Flipping out of demo mode hides the exit action and flips the status indicator.
        composeTestRule.onNodeWithTag(SETTINGS_EXIT_DEMO_TAG).assertDoesNotExist()
        composeTestRule.onNodeWithTag(SETTINGS_DEMO_STATUS_TAG).assertTextEquals("Live Mode")
    }

    @Test
    fun backControl_invokesOnBack() {
        var backCount = 0
        composeTestRule.setContent {
            ChromaGlowTheme {
                SettingsScreen(
                    isDemoMode = true,
                    appVersion = "1.0",
                    onBack = { backCount++ },
                )
            }
        }

        composeTestRule.onNodeWithTag(SETTINGS_BACK_TAG).performClick()

        assertEquals(1, backCount)
    }
}
