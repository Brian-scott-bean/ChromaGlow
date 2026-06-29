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
import com.chromaglow.app.core.hue.pairing.transport.HuePairingResult
import com.chromaglow.app.core.hue.pairing.transport.PairingFailureReason
import com.chromaglow.app.core.hue.pairing.workflow.LivePairingWorkflow
import com.chromaglow.app.ui.theme.ChromaGlowTheme
import kotlinx.coroutines.Dispatchers
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Compose tests for the manual-entry path on the live-pairing Setup screen. Updated from the old
 * inert-card semantics: a valid manual submission now selects the bridge into the live Selected
 * pairing card (press-button instruction + Pair action), not an inert "added later" placeholder.
 * Uses a fake-backed view model and never contacts a real bridge.
 */
@RunWith(AndroidJUnit4::class)
class SetupManualEntryTest {

    @get:Rule
    val composeTestRule = createAndroidComposeRule<ComponentActivity>()

    private fun setContent() {
        val workflow = LivePairingWorkflow(
            pairingClient = FakeHuePairingClient(
                HuePairingResult.Failure(PairingFailureReason.TransportError),
            ),
            credentialStore = FakeCredentialStore(),
            bridgeRegistry = FakeBridgeRegistry(),
            ioDispatcher = Dispatchers.IO,
        )
        val viewModel = SetupViewModel(workflow, FakeBridgeDiscoveryService())
        composeTestRule.setContent {
            ChromaGlowTheme {
                SetupRoute(viewModel = viewModel, onEnterDemoMode = {})
            }
        }
    }

    @Test
    fun manualEntryAction_isVisible() {
        setContent()

        composeTestRule.onNodeWithText(LABEL_MANUAL).assertIsDisplayed()
    }

    @Test
    fun validIpv4Submission_selectsBridgeIntoPairCard() {
        setContent()

        composeTestRule.onNodeWithText(LABEL_MANUAL).performClick()
        composeTestRule.onNodeWithTag(MANUAL_ENTRY_FIELD_TAG).performTextInput("192.168.1.100")
        composeTestRule.onNodeWithText(LABEL_USE_BRIDGE).performClick()

        composeTestRule.onNodeWithText("192.168.1.100:443").assertIsDisplayed()
        composeTestRule.onNodeWithText(INSTRUCTION_PRESS_BUTTON).assertIsDisplayed()
        composeTestRule.onNodeWithText(LABEL_PAIR).assertIsDisplayed()
    }

    @Test
    fun invalidSubmission_rendersInlineErrorAndNoPairCard() {
        setContent()

        composeTestRule.onNodeWithText(LABEL_MANUAL).performClick()
        composeTestRule.onNodeWithTag(MANUAL_ENTRY_FIELD_TAG).performTextInput("256.1.1.1")
        composeTestRule.onNodeWithText(LABEL_USE_BRIDGE).performClick()

        composeTestRule.onNodeWithText(ManualBridgeEndpointParser.ERROR_INVALID).assertIsDisplayed()
        composeTestRule.onNodeWithText(LABEL_PAIR).assertDoesNotExist()
    }

    @Test
    fun scanAgainAfterManualSelection_clearsSelection() {
        setContent()

        composeTestRule.onNodeWithText(LABEL_MANUAL).performClick()
        composeTestRule.onNodeWithTag(MANUAL_ENTRY_FIELD_TAG).performTextInput("192.168.1.100")
        composeTestRule.onNodeWithText(LABEL_USE_BRIDGE).performClick()
        composeTestRule.onNodeWithText("192.168.1.100:443").assertIsDisplayed()

        composeTestRule.onNodeWithText(LABEL_SCAN_AGAIN).performClick()

        composeTestRule.onNodeWithText("192.168.1.100:443").assertDoesNotExist()
        composeTestRule.onNodeWithText(LABEL_PAIR).assertDoesNotExist()
        composeTestRule.onNodeWithText("Searching…").assertIsDisplayed()
    }
}
