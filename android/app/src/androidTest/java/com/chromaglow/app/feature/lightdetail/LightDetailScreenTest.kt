package com.chromaglow.app.feature.lightdetail

import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertHasNoClickAction
import androidx.compose.ui.test.assertHeightIsAtLeast
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.filter
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onChildren
import androidx.compose.ui.test.onFirst
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeRight
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.chromaglow.app.core.hue.capability.CieXy
import com.chromaglow.app.core.hue.capability.MirekRange
import com.chromaglow.app.core.session.ConnectionState
import com.chromaglow.app.core.session.LightState
import com.chromaglow.app.core.session.TimedEffect
import com.chromaglow.app.core.session.safety.DefaultEffectSafetyRegister
import com.chromaglow.app.core.session.safety.EffectSafetyRegister
import com.chromaglow.app.testing.Caps
import com.chromaglow.app.testing.homeOf
import com.chromaglow.app.testing.light
import com.chromaglow.app.testing.snapshot
import com.chromaglow.app.ui.components.COLOR_PAD_TAG
import com.chromaglow.app.ui.components.MODE_SEGMENT_TAG
import com.chromaglow.app.ui.components.checkingTag
import com.chromaglow.app.ui.components.chipTag
import com.chromaglow.app.ui.components.modeSegmentTag
import com.chromaglow.app.ui.components.sectionTag
import com.chromaglow.app.ui.theme.ChromaGlowTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LightDetailScreenTest {

    @get:Rule
    val rule = createComposeRule()

    private val effects = mutableListOf<String?>()
    private val colours = mutableListOf<CieXy>()
    private val mireks = mutableListOf<Int>()
    private val timedStarts = mutableListOf<Unit>()
    private val timedSelections = mutableListOf<TimedEffect>()
    private var acknowledged = 0
    private var gradientApplies = 0

    private fun actions() = LightDetailActions(
        onBack = {}, onPower = {}, onBrightness = {}, onMode = {},
        onColor = { colours += it }, onMirek = { mireks += it },
        onEffect = { effects += it }, onEffectSpeed = {}, onEffectColor = {}, onEffectMirek = {},
        onTimedSelect = { timedSelections += it }, onTimedDuration = {}, onTimedStart = { timedStarts += Unit }, onTimedCancel = {},
        onGradientPoint = {}, onGradientPointColor = {}, onGradientMode = {}, onGradientApply = { gradientApplies++ },
        onAcknowledgeNotice = { acknowledged++ },
    )

    private fun state(
        l: LightState,
        edits: LightEdits = LightEdits(noticeAcknowledged = true),
        register: EffectSafetyRegister = DefaultEffectSafetyRegister,
        connection: ConnectionState = ConnectionState.Connected,
    ) = LightDetailUiMapper.map(homeOf(snapshot(lights = listOf(l)) to connection), l.key, edits, register, 0L)

    private fun show(s: LightDetailUiState) {
        rule.setContent { ChromaGlowTheme { LightDetailScreen(state = s, actions = actions()) } }
    }

    @Test
    fun whiteOnly_showsOnlyPowerAndBrightness_noFakeControls() {
        show(state(light("w", "Ceiling", capabilities = Caps.white())))
        rule.onNodeWithTag(sectionTag("power")).assertIsDisplayed()
        rule.onNodeWithTag(sectionTag("color")).assertDoesNotExist()
        rule.onNodeWithTag(sectionTag("colormode")).assertDoesNotExist()
        rule.onNodeWithTag(sectionTag("warmth")).assertDoesNotExist()
        rule.onNodeWithTag(sectionTag("effects")).assertDoesNotExist()
        rule.onNodeWithTag(sectionTag("timed")).assertDoesNotExist()
        rule.onNodeWithTag(sectionTag("gradient")).assertDoesNotExist()
        rule.onNodeWithText("Unsupported", substring = true).assertDoesNotExist()
    }

    @Test
    fun unknown_rendersCheckingPlaceholders_thatAreNotInteractive_andNeverSayUnsupported() {
        show(state(light("u", "Mystery", capabilities = Caps.unknown())))
        listOf("color", "warmth", "effects", "timed", "gradient").forEach { id ->
            val node = rule.onNodeWithTag(checkingTag(id))
            node.performScrollTo()
            node.assertIsDisplayed()
            node.assertHasNoClickAction()
            node.assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "Checking"))
            node.assert(SemanticsMatcher.keyNotDefined(SemanticsActions.SetProgress))
        }
        rule.onNodeWithText("Unsupported", substring = true).assertDoesNotExist()
        rule.onNodeWithText("can't", substring = true).assertDoesNotExist()
    }

    @Test
    fun ctWithoutSchema_isCheckingWarmth_noFader() {
        show(state(light("c", "Lamp", capabilities = Caps.ctWithoutSchema())))
        rule.onNodeWithTag(checkingTag("warmth")).assertIsDisplayed()
        rule.onNodeWithTag(LIGHT_DETAIL_WARMTH_TAG).assertDoesNotExist()
    }

    @Test
    fun ctOnly_warmthFader_spansTheLampsRange_inKelvin() {
        show(state(light("c", "Lamp", mirek = 250, mirekValid = true, capabilities = Caps.ctOnly(MirekRange(200, 400)))))
        rule.onNodeWithTag(MODE_SEGMENT_TAG).assertDoesNotExist()
        val fader = rule.onNodeWithTag(LIGHT_DETAIL_WARMTH_TAG)
        fader.assertIsDisplayed()
        fader.assert(SemanticsMatcher("range 200..400") { n ->
            n.config.getOrNull(SemanticsProperties.ProgressBarRangeInfo)?.range == 200f..400f
        })
        rule.onNodeWithText("5000 K").assertIsDisplayed() // 1e6/200
        rule.onNodeWithText("2500 K").assertIsDisplayed() // 1e6/400
        fader.performSemanticsAction(SemanticsActions.SetProgress) { it(300f) }
        assertEquals(listOf(300), mireks)
    }

    @Test
    fun colourAndCt_showSegment_defaultingToBridgeMode() {
        show(state(light("c", "Lamp", mirek = 366, mirekValid = true, capabilities = Caps.color())))
        rule.onNodeWithTag(MODE_SEGMENT_TAG).assertIsDisplayed()
        rule.onNodeWithTag(modeSegmentTag("warmth")).assertIsSelected()
        rule.onNodeWithTag(LIGHT_DETAIL_WARMTH_TAG).assertIsDisplayed()
        rule.onNodeWithTag(COLOR_PAD_TAG).assertDoesNotExist()
    }

    @Test
    fun colourMode_showsGamutPad_andNamedChipsCommitColour() {
        show(state(light("c", "Lamp", color = CieXy(0.4, 0.4), mirekValid = false, capabilities = Caps.color())))
        rule.onNodeWithTag(COLOR_PAD_TAG).assertIsDisplayed()
        val chip = rule.onNodeWithTag(chipTag("chips", "Red"))
        chip.performScrollTo()
        chip.assertHeightIsAtLeast(48.dp)
        chip.performClick()
        assertEquals(1, colours.size)
        rule.onNodeWithText("derived from this light's gamut type", substring = true).assertIsDisplayed()
    }

    @Test
    fun effects_chipsFromLampList_noneSelectedWhenIdle_activeSelected_footnotePresent() {
        show(state(light("c", "Lamp", activeEffect = "fire", capabilities = Caps.color())))
        rule.onNodeWithTag(sectionTag("effects")).performScrollTo()
        rule.onNodeWithTag(chipTag(EFFECT_CHIPS_TAG, "fire")).assertIsSelected()
        rule.onNodeWithTag(chipTag(EFFECT_CHIPS_TAG, "candle")).performClick()
        rule.onNodeWithTag(chipTag(EFFECT_CHIPS_TAG, EFFECT_NONE_ID)).performClick()
        assertEquals(listOf("candle", null), effects)
        rule.onNodeWithTag(chipTag(EFFECT_CHIPS_TAG, "prism")).assertDoesNotExist()
        rule.onAllNodesWithTag(sectionTag("effects")).onFirst().performScrollTo()
        rule.onNodeWithText(UNVERIFIED_FOOTNOTE).assertIsDisplayed()
    }

    @Test
    fun deniedEffect_hasNoChip() {
        val register = object : EffectSafetyRegister { override val denied = setOf("sparkle") }
        show(state(light("c", "Lamp", capabilities = Caps.color()), register = register))
        rule.onNodeWithTag(sectionTag("effects")).performScrollTo()
        rule.onNodeWithTag(chipTag(EFFECT_CHIPS_TAG, "sparkle")).assertDoesNotExist()
        rule.onNodeWithTag(chipTag(EFFECT_CHIPS_TAG, "candle")).assertIsDisplayed()
    }

    @Test
    fun photosensitivityNotice_showsOnce_untilAcknowledged() {
        show(state(light("c", "Lamp", capabilities = Caps.color()), edits = LightEdits(noticeAcknowledged = false)))
        rule.onNodeWithTag(LIGHT_DETAIL_NOTICE_TAG).performScrollTo().assertIsDisplayed()
        rule.onNodeWithTag(LIGHT_DETAIL_NOTICE_ACTION_TAG).performClick()
        assertEquals(1, acknowledged)
    }

    @Test
    fun timed_offersSunriseSunset_durationChips_andStart() {
        show(state(light("c", "Lamp", capabilities = Caps.color())))
        rule.onNodeWithTag(sectionTag("timed")).performScrollTo()
        rule.onNodeWithTag(chipTag(TIMED_CHIPS_TAG, "sunset")).performClick()
        assertEquals(listOf(TimedEffect.SUNSET), timedSelections)
        rule.onNodeWithTag(chipTag(DURATION_CHIPS_TAG, "30")).assertIsSelected()
        rule.onNodeWithTag(LIGHT_DETAIL_TIMED_START_TAG).performClick()
        assertEquals(1, timedStarts.size)
        rule.onNodeWithTag(LIGHT_DETAIL_TIMED_CANCEL_TAG).assertDoesNotExist()
    }

    @Test
    fun timed_runningShowsCancelOnly() {
        show(state(light("c", "Lamp", activeTimedEffect = "sunrise", capabilities = Caps.color())))
        rule.onNodeWithTag(sectionTag("timed")).performScrollTo()
        rule.onNodeWithText("Sunrise is running").assertIsDisplayed()
        rule.onNodeWithTag(LIGHT_DETAIL_TIMED_CANCEL_TAG).assertIsDisplayed()
        rule.onNodeWithTag(LIGHT_DETAIL_TIMED_START_TAG).assertDoesNotExist()
    }

    @Test
    fun gradient_exactPointCount_fromLamp_applyDisabledUntilDirty() {
        show(state(light("g", "Strip", capabilities = Caps.gradient(pointsCapable = 3))))
        rule.onNodeWithTag(sectionTag("gradient")).performScrollTo()
        rule.onNodeWithText("3 colour points").assertIsDisplayed()
        rule.onAllNodesWithTag(com.chromaglow.app.ui.components.GRADIENT_STRIP_TAG).onFirst()
            .onChildren().filter(hasClickAction()).assertCountEquals(3)
        rule.onNodeWithTag(chipTag(GRADIENT_MODE_CHIPS_TAG, "interpolated_palette")).assertIsSelected()
        rule.onNodeWithTag(LIGHT_DETAIL_GRADIENT_APPLY_TAG).assertIsNotEnabled()
    }

    @Test
    fun nonGradientLamp_hasNoGradientEditor() {
        show(state(light("c", "Lamp", capabilities = Caps.color())))
        rule.onNodeWithTag(sectionTag("gradient")).assertDoesNotExist()
        rule.onNodeWithTag(checkingTag("gradient")).assertDoesNotExist()
    }

    @Test
    fun offline_everyControlRefusesInput() {
        show(state(light("c", "Lamp", mirek = 366, mirekValid = true, capabilities = Caps.color()), connection = ConnectionState.Offline))
        rule.onNodeWithTag(LIGHT_DETAIL_SWITCH_TAG).assertIsNotEnabled()
        rule.onNodeWithTag(LIGHT_DETAIL_BRIGHTNESS_TAG).assert(SemanticsMatcher.keyNotDefined(SemanticsActions.SetProgress))
        rule.onNodeWithTag(LIGHT_DETAIL_BRIGHTNESS_TAG).performTouchInput { swipeRight() }
        rule.onNodeWithTag(sectionTag("effects")).performScrollTo()
        rule.onNodeWithTag(chipTag(EFFECT_CHIPS_TAG, "candle")).performClick()
        rule.waitForIdle()
        assertTrue(effects.isEmpty())
        assertTrue(mireks.isEmpty())
    }

    @Test
    fun rootScrolls_toReachTheLastSection() {
        show(state(light("g", "Strip", capabilities = Caps.gradient())))
        rule.onNodeWithTag(sectionTag("gradient")).performScrollTo().assertIsDisplayed()
    }
}
