package com.chromaglow.app.feature.setup

import androidx.activity.ComponentActivity
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.chromaglow.app.core.hue.discovery.ManualBridgeEndpointParser
import com.chromaglow.app.ui.theme.ChromaGlowTheme
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SetupManualEntryTest {

    @get:Rule
    val composeTestRule = createAndroidComposeRule<ComponentActivity>()

    private fun setContent() {
        composeTestRule.setContent {
            ChromaGlowTheme {
                SetupPlaceholderScreen(onEnterDemoMode = {})
            }
        }
    }

    @Test
    fun manualEntryAction_isVisible() {
        setContent()

        composeTestRule.onNodeWithText("Enter IP Manually").assertIsDisplayed()
    }

    @Test
    fun validIpv4Submission_rendersInertSelectedCard() {
        setContent()

        composeTestRule.onNodeWithText("Enter IP Manually").performClick()
        composeTestRule.onNodeWithTag(MANUAL_ENTRY_FIELD_TAG).performTextInput("192.168.1.100")
        composeTestRule.onNodeWithText("Use This Bridge").performClick()

        composeTestRule.onNodeWithText("Selected bridge").assertIsDisplayed()
        composeTestRule.onNodeWithText("192.168.1.100:443").assertIsDisplayed()
        composeTestRule.onNodeWithText("Pairing will be added in a later step.").assertIsDisplayed()
    }

    @Test
    fun invalidSubmission_rendersInlineErrorAndNoSelectedCard() {
        setContent()

        composeTestRule.onNodeWithText("Enter IP Manually").performClick()
        composeTestRule.onNodeWithTag(MANUAL_ENTRY_FIELD_TAG).performTextInput("256.1.1.1")
        composeTestRule.onNodeWithText("Use This Bridge").performClick()

        composeTestRule.onNodeWithText(ManualBridgeEndpointParser.ERROR_INVALID).assertIsDisplayed()
        composeTestRule.onNodeWithText("Selected bridge").assertDoesNotExist()
    }

    @Test
    fun scanAgainAfterManualSelection_clearsSelectionAndReturnsToScanning() {
        setContent()

        composeTestRule.onNodeWithText("Enter IP Manually").performClick()
        composeTestRule.onNodeWithTag(MANUAL_ENTRY_FIELD_TAG).performTextInput("192.168.1.100")
        composeTestRule.onNodeWithText("Use This Bridge").performClick()
        composeTestRule.onNodeWithText("192.168.1.100:443").assertIsDisplayed()

        composeTestRule.onNodeWithText("Scan Again").performClick()

        composeTestRule.onNodeWithText("192.168.1.100:443").assertDoesNotExist()
        composeTestRule.onNodeWithText("Selected bridge").assertDoesNotExist()
        composeTestRule.onNodeWithText("Searching…").assertIsDisplayed()
    }
}
