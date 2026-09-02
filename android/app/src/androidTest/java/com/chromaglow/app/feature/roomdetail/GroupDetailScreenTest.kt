package com.chromaglow.app.feature.roomdetail

import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertContentDescriptionContains
import androidx.compose.ui.test.assertHasClickAction
import androidx.compose.ui.test.assertHasNoClickAction
import androidx.compose.ui.test.assertHeightIsAtLeast
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.chromaglow.app.core.identity.ResourceKey
import com.chromaglow.app.core.session.ConnectionState
import com.chromaglow.app.feature.home.GroupCardUi
import com.chromaglow.app.testing.Fixtures
import com.chromaglow.app.ui.components.COLOR_PAD_TAG
import com.chromaglow.app.ui.components.groupHeaderTag
import com.chromaglow.app.ui.components.sectionTag
import androidx.compose.ui.test.performScrollTo
import com.chromaglow.app.core.hue.capability.CieXy
import com.chromaglow.app.ui.components.groupSwitchTag
import com.chromaglow.app.ui.components.lightFaderTag
import com.chromaglow.app.ui.components.lightHeaderTag
import com.chromaglow.app.ui.components.lightSwitchTag
import com.chromaglow.app.ui.theme.ChromaGlowTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class GroupDetailScreenTest {

    @get:Rule
    val rule = createComposeRule()

    private var opened: ResourceKey? = null
    private var backs = 0
    private val groupPowers = mutableListOf<Pair<GroupCardUi, Boolean>>()
    private val lightPowers = mutableListOf<Pair<LightCardUi, Boolean>>()
    private val lightBrightness = mutableListOf<Pair<LightCardUi, Int>>()
    private val groupColours = mutableListOf<CieXy>()
    private val groupMireks = mutableListOf<Int>()

    private fun show(state: GroupDetailUiState) {
        rule.setContent {
            ChromaGlowTheme {
                GroupDetailScreen(
                    state = state,
                    onBack = { backs++ },
                    onOpenLight = { opened = it },
                    onGroupPower = { c, on -> groupPowers += c to on },
                    onGroupBrightness = { _, _ -> },
                    onLightPower = { l, on -> lightPowers += l to on },
                    onLightBrightness = { l, p -> lightBrightness += l to p },
                    onGroupColor = { groupColours += it },
                    onGroupColorTemperature = { groupMireks += it },
                )
            }
        }
    }

    private fun living(connection: ConnectionState = ConnectionState.Connected) =
        GroupDetailUiMapper.map(Fixtures.home(connection), Fixtures.livingRoom, 0L)

    @Test
    fun rendersGroupInstrument_coverage_andLightCards() {
        show(living())
        rule.onNodeWithText("Living Room").assertIsDisplayed()
        rule.onNodeWithTag(GROUP_DETAIL_COVERAGE_TAG).assertIsDisplayed()
        rule.onNodeWithText("1 of 2 lights support colour").assertIsDisplayed()
        rule.onNodeWithText("Ceiling").assertIsDisplayed()
        rule.onNodeWithText("Floor Lamp").assertIsDisplayed()
    }

    @Test
    fun groupHeader_isNotAButtonHere_switchStillWorks() {
        show(living())
        rule.onNodeWithTag(groupHeaderTag(Fixtures.livingRoom.composeKey)).assertHasNoClickAction()
        rule.onNodeWithTag(groupSwitchTag(Fixtures.livingRoom.composeKey)).performClick()
        assertEquals(1, groupPowers.size)
    }

    @Test
    fun lightHeader_is48dpButton_opensExactLight() {
        show(living())
        val header = rule.onNodeWithTag(lightHeaderTag(Fixtures.lampColor.composeKey))
        header.assertHasClickAction()
        header.assertHeightIsAtLeast(48.dp)
        header.assertContentDescriptionContains("supports Colour, Warmth, Effects", substring = true)
        header.performClick()
        assertEquals(Fixtures.lampColor, opened)
    }

    @Test
    fun whiteLight_advertisesNoCapabilities() {
        show(living())
        rule.onNodeWithTag(lightHeaderTag(Fixtures.lampWhite.composeKey))
            .assert(SemanticsMatcher("no 'supports' in description") { node ->
                node.config.getOrNull(SemanticsProperties.ContentDescription)?.none { it.contains("supports") } ?: true
            })
        rule.onNodeWithText("Gradient").assertDoesNotExist()
    }

    @Test
    fun lightControls_forwardExactLight() {
        show(living())
        rule.onNodeWithTag(lightSwitchTag(Fixtures.lampColor.composeKey)).performClick()
        rule.onNodeWithTag(lightFaderTag(Fixtures.lampColor.composeKey)).performSemanticsAction(SemanticsActions.SetProgress) { it(25f) }
        assertEquals(Fixtures.lampColor, lightPowers.single().first.key)
        assertEquals(25, lightBrightness.single().second)
    }

    @Test
    fun offline_disablesLights_andRefusesFaderAction() {
        show(living(ConnectionState.Offline))
        rule.onNodeWithTag(lightSwitchTag(Fixtures.lampColor.composeKey)).assertIsNotEnabled()
        rule.onNodeWithTag(lightFaderTag(Fixtures.lampColor.composeKey))
            .assert(SemanticsMatcher.keyNotDefined(SemanticsActions.SetProgress))
        assertTrue(lightBrightness.isEmpty())
    }

    @Test
    fun missingGroup_showsHonestEmptyState_andBack() {
        show(GroupDetailUiMapper.map(Fixtures.home(), com.chromaglow.app.testing.roomKey("gone"), 0L))
        rule.onNodeWithText("This group is no longer available").assertIsDisplayed()
        rule.onNodeWithTag(GROUP_DETAIL_BACK_TAG).performClick()
        assertEquals(1, backs)
    }

    @Test
    fun groupInstruments_showCaption_andSend() {
        show(living())
        rule.onNodeWithTag(sectionTag(GROUP_COLOR_SECTION_ID)).performScrollTo().assertIsDisplayed()
        rule.onNodeWithTag(groupInstrumentCaptionTag(GROUP_COLOR_SECTION_ID)).assertTextEquals("Applies to 1 of 2 lights")
        rule.onNodeWithText(GROUP_COLOR_FOOTNOTE).assertIsDisplayed()
        rule.onNodeWithTag(COLOR_PAD_TAG).assertIsDisplayed()
        rule.onNodeWithTag(sectionTag(GROUP_WARMTH_SECTION_ID)).performScrollTo()
        rule.onNodeWithTag(GROUP_WARMTH_FADER_TAG).performSemanticsAction(SemanticsActions.SetProgress) { it(300f) }
        assertEquals(listOf(300), groupMireks)
        rule.onNodeWithText(GROUP_WARMTH_FOOTNOTE).assertIsDisplayed()
    }

    @Test
    fun groupInstruments_hiddenWhenNoMemberIsCapable() {
        show(GroupDetailUiMapper.map(Fixtures.home(), Fixtures.bedroom, 0L)) // CT-only member
        rule.onNodeWithTag(sectionTag(GROUP_COLOR_SECTION_ID)).assertDoesNotExist()
        rule.onNodeWithTag(sectionTag(GROUP_WARMTH_SECTION_ID)).performScrollTo().assertIsDisplayed()
        rule.onNodeWithTag(groupInstrumentCaptionTag(GROUP_WARMTH_SECTION_ID)).assertTextEquals("Applies to the 1 light")
    }

    @Test
    fun groupInstruments_refuseInputOffline() {
        show(living(ConnectionState.Offline))
        rule.onNodeWithTag(sectionTag(GROUP_WARMTH_SECTION_ID)).performScrollTo()
        rule.onNodeWithTag(GROUP_WARMTH_FADER_TAG).assert(SemanticsMatcher.keyNotDefined(SemanticsActions.SetProgress))
        assertTrue(groupMireks.isEmpty())
    }
}
