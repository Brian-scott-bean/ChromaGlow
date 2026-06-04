package com.chromaglow.app.app

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.chromaglow.app.ui.theme.ChromaGlowTheme
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ChromaGlowAppTest {
    @get:Rule
    val composeTestRule = createAndroidComposeRule<androidx.activity.ComponentActivity>()

    @Test
    fun setupAndDashboardPlaceholderNavigation_smoke() {
        composeTestRule.setContent {
            ChromaGlowTheme {
                ChromaGlowApp()
            }
        }

        composeTestRule.onNodeWithText("ChromaGlow").assertIsDisplayed()
        composeTestRule.onNodeWithText("Enter Demo Mode").assertIsDisplayed()

        composeTestRule.onNodeWithText("Enter Demo Mode").performClick()

        composeTestRule.onNodeWithText("Demo Dashboard").assertIsDisplayed()
        composeTestRule.onNodeWithText("Back to Setup").assertIsDisplayed()
    }
}
