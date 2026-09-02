package com.chromaglow.app.feature.settings

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.chromaglow.app.core.identity.BridgeId
import com.chromaglow.app.core.session.ConnectionState
import com.chromaglow.app.testing.BRIDGE_A
import com.chromaglow.app.testing.Fixtures
import com.chromaglow.app.ui.theme.ChromaGlowTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LiveSettingsScreenTest {

    @get:Rule
    val rule = createComposeRule()

    private val requested = mutableListOf<BridgeId>()
    private var confirms = 0
    private var cancels = 0

    private fun show(confirming: BridgeId? = null, connection: ConnectionState = ConnectionState.Connected) {
        rule.setContent {
            ChromaGlowTheme {
                LiveSettingsScreen(
                    state = LiveSettingsUiMapper.map(Fixtures.home(connection), "1.0", confirming, 0L),
                    onBack = {},
                    onRequestForget = { requested += it },
                    onConfirmForget = { confirms++ },
                    onCancelForget = { cancels++ },
                )
            }
        }
    }

    @Test
    fun rendersMode_bridgeRowWithIdAndStatus_version_andLocalOnlyNote() {
        show(connection = ConnectionState.Stale(0L))
        rule.onNodeWithTag(LIVE_SETTINGS_MODE_TAG).assertTextEquals("Live Mode")
        rule.onNodeWithTag(LIVE_SETTINGS_VERSION_TAG).assertTextEquals("1.0")
        rule.onNodeWithTag(liveSettingsBridgeTag(BRIDGE_A)).assertIsDisplayed()
        rule.onNodeWithText(BRIDGE_A.value).assertIsDisplayed()
        rule.onNodeWithText("Stale for under a minute").assertIsDisplayed()
        rule.onNodeWithText(FORGET_LOCAL_ONLY_NOTE).assertIsDisplayed()
        rule.onNodeWithText("Pair another", substring = true).assertDoesNotExist()
    }

    @Test
    fun forgetButton_requestsConfirmation_notForget() {
        show()
        rule.onNodeWithTag(liveSettingsForgetTag(BRIDGE_A)).performClick()
        assertEquals(listOf(BRIDGE_A), requested)
        assertEquals(0, confirms)
    }

    @Test
    fun dialog_statesLocalOnly_confirmAndCancelRoute() {
        show(confirming = BRIDGE_A)
        rule.onNodeWithTag(LIVE_SETTINGS_FORGET_DIALOG_TAG).assertIsDisplayed()
        rule.onNodeWithText(FORGET_LOCAL_ONLY_NOTE, substring = true).assertIsDisplayed()
        rule.onNodeWithText("Revoke", substring = true).assertDoesNotExist()
        rule.onNodeWithTag(LIVE_SETTINGS_FORGET_CANCEL_TAG).performClick()
        assertEquals(1, cancels)
        rule.onNodeWithTag(LIVE_SETTINGS_FORGET_CONFIRM_TAG).performClick()
        assertEquals(1, confirms)
    }
}
