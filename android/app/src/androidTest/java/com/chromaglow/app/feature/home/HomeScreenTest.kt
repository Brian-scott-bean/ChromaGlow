package com.chromaglow.app.feature.home

import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertContentDescriptionContains
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertHasClickAction
import androidx.compose.ui.test.assertHeightIsAtLeast
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertIsOff
import androidx.compose.ui.test.assertIsOn
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onFirst
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeRight
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.chromaglow.app.core.identity.ResourceKey
import com.chromaglow.app.core.session.BridgeSnapshot
import com.chromaglow.app.core.session.ConnectionState
import com.chromaglow.app.core.session.GroupKind
import com.chromaglow.app.testing.BRIDGE_A
import com.chromaglow.app.testing.Fixtures
import com.chromaglow.app.testing.homeOf
import com.chromaglow.app.testing.snapshot
import com.chromaglow.app.ui.components.CONNECTION_STRIP_TAG
import com.chromaglow.app.ui.components.EMPTY_STATE_TAG
import com.chromaglow.app.ui.components.FEEDBACK_HOST_TAG
import com.chromaglow.app.ui.components.FeedbackKind
import com.chromaglow.app.ui.components.MutationFeedbackUi
import com.chromaglow.app.ui.components.LocalReduceMotion
import com.chromaglow.app.ui.components.PULSE_CARD_TAG
import com.chromaglow.app.ui.components.groupFaderTag
import com.chromaglow.app.ui.components.groupHeaderTag
import com.chromaglow.app.ui.components.groupSwitchTag
import com.chromaglow.app.ui.theme.ChromaGlowTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class HomeScreenTest {

    @get:Rule
    val rule = createComposeRule()

    private var opened: Pair<ResourceKey, GroupKind>? = null
    private val powers = mutableListOf<Pair<GroupCardUi, Boolean>>()
    private val brightness = mutableListOf<Pair<GroupCardUi, Int>>()
    private var refreshes = 0

    private fun show(state: HomeUiState, reduceMotion: Boolean = false) {
        rule.setContent {
            ChromaGlowTheme {
                CompositionLocalProvider(LocalReduceMotion provides reduceMotion) {
                    HomeScreen(
                        state = state,
                        onOpenGroup = { key, kind -> opened = key to kind },
                        onOpenScenes = {},
                        onOpenSettings = {},
                        onRefresh = { refreshes++ },
                        onGroupPower = { card, on -> powers += card to on },
                        onGroupBrightness = { card, pct -> brightness += card to pct },
                    )
                }
            }
        }
    }

    private val living = Fixtures.livingRoom.composeKey

    @Test
    fun loading_showsPlaceholdersOnly_noCardsNoDemoRooms() {
        show(HomeUiMapper.map(homeOf(BridgeSnapshot.empty(BRIDGE_A) to ConnectionState.Connecting), 0L))
        rule.onAllNodesWithTag(PULSE_CARD_TAG).assertCountEquals(3)
        rule.onNodeWithText("Living Room").assertDoesNotExist()
        rule.onNodeWithText("Bedroom").assertDoesNotExist()
        rule.onNodeWithTag(CONNECTION_STRIP_TAG).assertContentDescriptionContains("Connecting", substring = true)
    }

    @Test
    fun loading_underReduceMotion_stillRendersPlaceholders() {
        show(HomeUiMapper.map(homeOf(BridgeSnapshot.empty(BRIDGE_A) to ConnectionState.Connecting), 0L), reduceMotion = true)
        rule.onAllNodesWithTag(PULSE_CARD_TAG).assertCountEquals(3)
    }

    @Test
    fun empty_showsEmptyState_withRefresh() {
        show(HomeUiMapper.map(homeOf(snapshot(generation = 2) to ConnectionState.Connected), 0L))
        rule.onNodeWithTag(EMPTY_STATE_TAG).assertIsDisplayed()
        rule.onNodeWithText("Refresh").performClick()
        assertEquals(1, refreshes)
    }

    @Test
    fun content_rendersRoomsThenZones_withHeadings() {
        show(HomeUiMapper.map(Fixtures.home(), 0L))
        rule.onNodeWithTag(HOME_ROOMS_HEADER_TAG).assertIsDisplayed()
        rule.onNodeWithText("Bedroom").assertIsDisplayed()
        rule.onNodeWithText("Living Room").assertIsDisplayed()
        rule.onNodeWithTag(HOME_ZONES_HEADER_TAG).assertIsDisplayed()
        rule.onNodeWithText("Upstairs").assertIsDisplayed()
        rule.onNodeWithText("ZONE").assertIsDisplayed()
    }

    @Test
    fun header_isA48dpButton_thatOpensExactGroup() {
        show(HomeUiMapper.map(Fixtures.home(), 0L))
        val header = rule.onNodeWithTag(groupHeaderTag(living))
        header.assertHasClickAction()
        header.assertHeightIsAtLeast(48.dp)
        header.assertContentDescriptionContains("Living Room", substring = true)
        header.performClick()
        assertEquals(Fixtures.livingRoom to GroupKind.ROOM, opened)
    }

    @Test
    fun switch_carriesStateDescription_andForwardsExactCard() {
        show(HomeUiMapper.map(Fixtures.home(), 0L))
        val switch = rule.onNodeWithTag(groupSwitchTag(living))
        switch.assertIsOn()
        switch.assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "On"))
        switch.assertContentDescriptionContains("Living Room power", substring = true)
        switch.performClick()
        assertEquals(1, powers.size)
        assertEquals(Fixtures.livingRoom, powers.single().first.groupKey)
        assertEquals(false, powers.single().second)
    }

    @Test
    fun fader_exposesRangeInfo_andSetProgressCommitsOnce() {
        show(HomeUiMapper.map(Fixtures.home(), 0L))
        val fader = rule.onNodeWithTag(groupFaderTag(living))
        fader.assertContentDescriptionContains("Living Room brightness", substring = true)
        fader.assert(
            SemanticsMatcher.expectValue(
                SemanticsProperties.ProgressBarRangeInfo,
                ProgressBarRangeInfo(72f, 1f..100f, 98),
            ),
        )
        fader.assertHeightIsAtLeast(48.dp)
        fader.performSemanticsAction(SemanticsActions.SetProgress) { it(30f) }
        assertEquals(listOf(30), brightness.map { it.second })
        assertEquals(Fixtures.livingRoom, brightness.single().first.groupKey)
    }

    @Test
    fun fader_dragCommitsExactlyOnce_onRelease() {
        show(HomeUiMapper.map(Fixtures.home(), 0L))
        rule.onNodeWithTag(groupFaderTag(living)).performTouchInput { swipeRight() }
        rule.waitForIdle()
        assertEquals(1, brightness.size)
        assertTrue(brightness.single().second in 1..100)
    }

    @Test
    fun offline_disablesSwitch_refusesFaderGestures_explainsWhy() {
        show(HomeUiMapper.map(Fixtures.home(ConnectionState.Offline), 0L))
        rule.onNodeWithTag(groupSwitchTag(living)).assertIsNotEnabled()
        val fader = rule.onNodeWithTag(groupFaderTag(living))
        fader.assert(SemanticsMatcher.keyIsDefined(SemanticsProperties.Disabled))
        fader.assert(SemanticsMatcher.keyNotDefined(SemanticsActions.SetProgress))
        fader.performTouchInput { swipeRight() }
        rule.onNodeWithTag(groupSwitchTag(living)).performClick()
        rule.waitForIdle()
        assertTrue(brightness.isEmpty())
        assertTrue(powers.isEmpty())
        rule.onAllNodesWithText("Bridge offline. Controls resume when it reconnects.").onFirst().assertIsDisplayed()
        rule.onNodeWithTag(CONNECTION_STRIP_TAG).assertContentDescriptionContains("Offline", substring = true)
    }

    @Test
    fun stale_keepsControlsEnabled_andSaysSo() {
        show(HomeUiMapper.map(Fixtures.home(ConnectionState.Stale(0L)), 5 * 60_000L))
        rule.onNodeWithTag(groupSwitchTag(living)).assertIsEnabled()
        rule.onNodeWithTag(groupFaderTag(living)).assert(SemanticsMatcher.keyIsDefined(SemanticsActions.SetProgress))
        rule.onNodeWithText("Stale for 5 min").assertIsDisplayed()
    }

    @Test
    fun revoked_disablesAndPointsToSettings() {
        show(HomeUiMapper.map(Fixtures.home(ConnectionState.Revoked), 0L))
        rule.onNodeWithTag(groupSwitchTag(living)).assertIsNotEnabled()
        rule.onNodeWithText("Access removed").assertIsDisplayed()
        assertNull(opened)
    }

    @Test
    fun connectionStrip_isPoliteLiveRegion() {
        show(HomeUiMapper.map(Fixtures.home(), 0L))
        rule.onNodeWithTag(CONNECTION_STRIP_TAG).assert(SemanticsMatcher.keyIsDefined(SemanticsProperties.LiveRegion))
    }

    @Test
    fun offRoom_keepsSwitchFullyEnabled_notDimmedAway() {
        show(HomeUiMapper.map(Fixtures.home(), 0L))
        val bed = rule.onNodeWithTag(groupSwitchTag(Fixtures.bedroom.composeKey))
        bed.assertIsOff()
        bed.assertIsEnabled()
    }

    @Test
    fun feedback_isShownAsSnackbar_inALiveRegion_andReportedShown() {
        var shown: MutationFeedbackUi? = null
        val f = MutationFeedbackUi(1, FeedbackKind.FAILED_REVERTED, "Living Room brightness couldn't be changed. Reverted.", Fixtures.livingGrouped)
        rule.setContent {
            ChromaGlowTheme {
                HomeScreen(
                    state = HomeUiMapper.map(Fixtures.home(), 0L),
                    onOpenGroup = { _, _ -> }, onOpenScenes = {}, onOpenSettings = {}, onRefresh = {},
                    onGroupPower = { _, _ -> }, onGroupBrightness = { _, _ -> },
                    feedback = f,
                    onFeedbackShown = { shown = it },
                )
            }
        }
        rule.onNodeWithTag(FEEDBACK_HOST_TAG).assert(SemanticsMatcher.keyIsDefined(SemanticsProperties.LiveRegion))
        rule.onNodeWithText(f.message).assertIsDisplayed()
        rule.mainClock.advanceTimeBy(6_000)
        rule.waitForIdle()
        assertEquals(f, shown)
    }
}
