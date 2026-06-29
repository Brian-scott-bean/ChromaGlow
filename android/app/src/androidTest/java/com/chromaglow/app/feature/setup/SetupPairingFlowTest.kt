package com.chromaglow.app.feature.setup

import androidx.activity.ComponentActivity
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.chromaglow.app.core.bridge.PairedBridgeRecord
import com.chromaglow.app.core.hue.pairing.transport.HuePairingResult
import com.chromaglow.app.core.hue.pairing.transport.PairingFailureReason
import com.chromaglow.app.core.hue.pairing.workflow.LivePairingWorkflow
import com.chromaglow.app.ui.theme.ChromaGlowTheme
import kotlinx.coroutines.Dispatchers
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch

/**
 * Compose tests for the live-pairing states on Setup. Every test drives a fake-backed view model
 * through the real workflow; none contacts a bridge. Covers selected, pairing (in-flight), paired,
 * link-button retry, recovery, startup restoration, and local forget.
 */
@RunWith(AndroidJUnit4::class)
class SetupPairingFlowTest {

    @get:Rule
    val composeTestRule = createAndroidComposeRule<ComponentActivity>()

    private val bridgeId = "001788FFFE112233"
    private val username = "appkey-xyz"
    private val record = PairedBridgeRecord(bridgeId, "Manual bridge", "192.168.1.100", 443, true)

    private fun harness(
        result: HuePairingResult,
        gate: CountDownLatch? = null,
        store: FakeCredentialStore = FakeCredentialStore(),
        registry: FakeBridgeRegistry = FakeBridgeRegistry(),
    ): SetupViewModel {
        val workflow = LivePairingWorkflow(
            pairingClient = FakeHuePairingClient(result, gate),
            credentialStore = store,
            bridgeRegistry = registry,
            ioDispatcher = Dispatchers.IO,
        )
        return SetupViewModel(workflow, FakeBridgeDiscoveryService())
    }

    private fun render(viewModel: SetupViewModel) {
        composeTestRule.setContent {
            ChromaGlowTheme { SetupRoute(viewModel = viewModel, onEnterDemoMode = {}) }
        }
    }

    private fun selectManualBridge() {
        composeTestRule.onNodeWithText(LABEL_MANUAL).performClick()
        composeTestRule.onNodeWithTag(MANUAL_ENTRY_FIELD_TAG)
            .performTextInput("192.168.1.100")
        composeTestRule.onNodeWithText(LABEL_USE_BRIDGE).performClick()
    }

    private fun waitForText(text: String) {
        composeTestRule.waitUntil(timeoutMillis = 5_000) {
            composeTestRule.onAllNodesWithText(text).fetchSemanticsNodes().isNotEmpty()
        }
    }

    @Test
    fun pairSuccess_showsBridgeConnected_andForget_andPersists() {
        val store = FakeCredentialStore()
        val registry = FakeBridgeRegistry()
        render(harness(HuePairingResult.Success(bridgeId, username), store = store, registry = registry))

        selectManualBridge()
        composeTestRule.onNodeWithText(LABEL_PAIR).performClick()

        waitForText(TITLE_CONNECTED)
        composeTestRule.onNodeWithText(LABEL_FORGET).assertIsDisplayed()
        // Token + non-secret metadata were committed; the UI never showed the token.
        assertEquals(username, store.tokens[bridgeId])
        assertEquals(listOf(record), registry.records)
    }

    @Test
    fun pairInFlight_showsProgress_andSuppressesDuplicatePair() {
        val gate = CountDownLatch(1)
        render(harness(HuePairingResult.Success(bridgeId, username), gate = gate))

        selectManualBridge()
        composeTestRule.onNodeWithText(LABEL_PAIR).performClick()

        // While the attempt is in flight, the progress card shows and the Pair action is gone.
        composeTestRule.waitUntil(timeoutMillis = 5_000) {
            composeTestRule.onAllNodesWithTag(PAIRING_PROGRESS_TAG).fetchSemanticsNodes().isNotEmpty()
        }
        composeTestRule.onNodeWithText(LABEL_PAIRING).assertIsDisplayed()
        composeTestRule.onNodeWithText(LABEL_PAIR).assertDoesNotExist()

        gate.countDown()
        waitForText(TITLE_CONNECTED)
    }

    @Test
    fun pairType101_returnsToSelectedWithRetryMessage() {
        render(harness(HuePairingResult.LinkButtonNotPressed))

        selectManualBridge()
        composeTestRule.onNodeWithText(LABEL_PAIR).performClick()

        waitForText(SetupViewModel.LINK_BUTTON_MESSAGE)
        // Retry is on user tap only: the Pair button is back, no auto-retry.
        composeTestRule.onNodeWithText(LABEL_PAIR).assertIsDisplayed()
        composeTestRule.onNodeWithText(TITLE_CONNECTED).assertDoesNotExist()
    }

    @Test
    fun pairTerminalFailure_showsRecovery_andTryAgainReturnsToSelected() {
        render(harness(HuePairingResult.Failure(PairingFailureReason.TransportError)))

        selectManualBridge()
        composeTestRule.onNodeWithText(LABEL_PAIR).performClick()

        waitForText(LABEL_TRY_AGAIN)
        composeTestRule.onNodeWithText(LABEL_TRY_AGAIN).performClick()

        // Back to the selectable state — Pair is available again, no raw error text.
        composeTestRule.onNodeWithText(LABEL_PAIR).assertIsDisplayed()
        composeTestRule.onNodeWithText(INSTRUCTION_PRESS_BUTTON).assertIsDisplayed()
    }

    @Test
    fun startupRestore_pairedSession_showsConnectedWithoutPairing() {
        val store = FakeCredentialStore().apply { tokens[bridgeId] = username }
        val registry = FakeBridgeRegistry().apply { records.add(record) }
        render(harness(HuePairingResult.LinkButtonNotPressed, store = store, registry = registry))

        waitForText(TITLE_CONNECTED)
        composeTestRule.onNodeWithText(LABEL_FORGET).assertIsDisplayed()
    }

    @Test
    fun forget_returnsToSetup_andClearsLocalState() {
        val store = FakeCredentialStore().apply { tokens[bridgeId] = username }
        val registry = FakeBridgeRegistry().apply { records.add(record) }
        render(harness(HuePairingResult.LinkButtonNotPressed, store = store, registry = registry))

        waitForText(TITLE_CONNECTED)
        composeTestRule.onNodeWithText(LABEL_FORGET).performClick()

        // Returns to Setup entry; local token + metadata are gone.
        waitForText(LABEL_SCAN)
        composeTestRule.onNodeWithText(TITLE_CONNECTED).assertDoesNotExist()
        assertTrue(store.tokens.isEmpty())
        assertTrue(registry.records.isEmpty())
    }
}
