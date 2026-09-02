package com.chromaglow.app.feature.lightdetail

import com.chromaglow.app.core.hue.capability.Capability
import com.chromaglow.app.core.hue.capability.CieXy
import com.chromaglow.app.core.hue.capability.GamutSource
import com.chromaglow.app.core.hue.capability.MirekRange
import com.chromaglow.app.core.session.ConnectionState
import com.chromaglow.app.core.session.LightState
import com.chromaglow.app.core.session.TimedEffect
import com.chromaglow.app.core.session.safety.DefaultEffectSafetyRegister
import com.chromaglow.app.core.session.safety.EffectSafetyRegister
import com.chromaglow.app.feature.testing.Caps
import com.chromaglow.app.feature.testing.Fixtures
import com.chromaglow.app.feature.testing.homeOf
import com.chromaglow.app.feature.testing.light
import com.chromaglow.app.feature.testing.snapshot
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LightDetailUiMapperTest {

    private fun map(
        l: LightState,
        edits: LightEdits = LightEdits(),
        register: EffectSafetyRegister = DefaultEffectSafetyRegister,
        connection: ConnectionState = ConnectionState.Connected,
    ): LightDetailUiState = LightDetailUiMapper.map(
        homeOf(snapshot(lights = listOf(l)) to connection), l.key, edits, register, 0L,
    )

    @Test
    fun whiteOnly_hidesColourWarmthEffectsTimedGradient_keepsPowerBrightness() {
        val s = map(light("w", "Ceiling", capabilities = Caps.white()))
        assertTrue(s.found)
        assertEquals(72, s.brightness)
        assertNull(s.mode)
        assertEquals(SectionUi.Hidden, s.color)
        assertEquals(SectionUi.Hidden, s.warmth)
        assertEquals(SectionUi.Hidden, s.effects)
        assertEquals(SectionUi.Hidden, s.timed)
        assertEquals(SectionUi.Hidden, s.gradient)
        assertFalse(s.showPhotosensitivityNotice)
    }

    @Test
    fun unknownCapabilities_areChecking_neverHiddenNeverReady() {
        val s = map(light("u", "Mystery", capabilities = Caps.unknown()))
        assertEquals(SectionUi.Checking, s.color)
        assertEquals(SectionUi.Checking, s.warmth)
        assertEquals(SectionUi.Checking, s.effects)
        assertEquals(SectionUi.Checking, s.timed)
        assertEquals(SectionUi.Checking, s.gradient)
        assertNull(s.mode)
    }

    @Test
    fun ctWithoutSchema_isChecking_notAFabricatedRange() {
        val s = map(light("c", "Lamp", capabilities = Caps.ctWithoutSchema()))
        assertEquals(SectionUi.Checking, s.warmth)
        assertEquals(SectionUi.Hidden, s.color)
    }

    @Test
    fun ctOnly_exposesTheLampsOwnRange_andCurrentMirekOnlyWhenValid() {
        val valid = map(light("c", "Lamp", mirek = 300, mirekValid = true, capabilities = Caps.ctOnly(MirekRange(200, 454))))
        val w = (valid.warmth as SectionUi.Ready).value
        assertEquals(MirekRange(200, 454), w.range)
        assertEquals(300, w.currentMirek)
        assertNull(valid.mode)

        val stale = map(light("c", "Lamp", mirek = 300, mirekValid = false, capabilities = Caps.ctOnly()))
        assertNull((stale.warmth as SectionUi.Ready).value.currentMirek)
    }

    @Test
    fun colourAndCt_yieldModeSegment_followingBridgeModeTruth() {
        val inCt = map(light("c", "Lamp", mirek = 366, mirekValid = true, capabilities = Caps.color()))
        assertEquals(ColorMode.WARMTH, inCt.mode)
        val inColour = map(light("c", "Lamp", color = CieXy(0.4, 0.4), mirek = null, mirekValid = false, capabilities = Caps.color()))
        assertEquals(ColorMode.COLOR, inColour.mode)
        val overridden = map(light("c", "Lamp", mirek = 366, mirekValid = true, capabilities = Caps.color()), LightEdits(modeOverride = ColorMode.COLOR))
        assertEquals(ColorMode.COLOR, overridden.mode)
    }

    @Test
    fun gamutUnknown_colourIsChecking_whileWarmthStaysReady_noSegment() {
        val s = map(light("c", "Lamp", capabilities = Caps.colorGamutUnknown()))
        assertEquals(SectionUi.Checking, s.color)
        assertTrue(s.warmth is SectionUi.Ready)
        assertNull(s.mode)
    }

    @Test
    fun gamutSource_isCarriedThroughForHonestCopy() {
        val s = map(light("c", "Lamp", capabilities = Caps.color()))
        assertEquals(GamutSource.SPEC_DERIVED, (s.color as SectionUi.Ready).value.gamut.source)
    }

    @Test
    fun effects_v2ShadowsV1_optionsSorted_noEffectNeverAChip_speedAvailableOnV2() {
        val s = map(light("c", "Lamp", capabilities = Caps.color(effects = setOf("sparkle", "no_effect", "candle"))))
        val e = (s.effects as SectionUi.Ready).value
        assertEquals(listOf("candle", "sparkle"), e.options)
        assertTrue(e.speedAvailable)
        assertTrue(s.showPhotosensitivityNotice)
        assertTrue(e.colorParam is SectionUi.Ready)
        assertTrue(e.warmthParam is SectionUi.Ready)
    }

    @Test
    fun effects_v1OnlyLamp_hasChipsButNoSpeedNoParams() {
        val caps = Caps.color().copy(effectsV2 = Capability.absent())
        val s = map(light("c", "Lamp", capabilities = caps))
        val e = (s.effects as SectionUi.Ready).value
        assertEquals(listOf("candle"), e.options)
        assertFalse(e.speedAvailable)
        assertEquals(SectionUi.Hidden, e.colorParam)
        assertEquals(SectionUi.Hidden, e.warmthParam)
    }

    @Test
    fun deniedEffect_isRemovedFromChips_andNeverShownAsActive() {
        val register = object : EffectSafetyRegister { override val denied = setOf("sparkle") }
        val s = map(light("c", "Lamp", activeEffect = "sparkle", capabilities = Caps.color()), register = register)
        val e = (s.effects as SectionUi.Ready).value
        assertEquals(listOf("candle", "fire"), e.options)
        assertNull(e.active)
    }

    @Test
    fun effectsListEmptyAfterDeny_hidesSection() {
        val register = object : EffectSafetyRegister { override val denied = setOf("candle") }
        val s = map(light("c", "Lamp", capabilities = Caps.color(effects = setOf("candle"))), register = register)
        assertEquals(SectionUi.Hidden, s.effects)
        assertFalse(s.showPhotosensitivityNotice)
    }

    @Test
    fun activeEffect_isReflected_noEffectMeansNone() {
        assertEquals("fire", ((map(light("c", "Lamp", activeEffect = "fire", capabilities = Caps.color())).effects as SectionUi.Ready).value.active))
        assertNull(((map(light("c", "Lamp", activeEffect = "no_effect", capabilities = Caps.color())).effects as SectionUi.Ready).value.active))
    }

    @Test
    fun noticeAcknowledged_hidesNotice() {
        val s = map(light("c", "Lamp", capabilities = Caps.color()), LightEdits(noticeAcknowledged = true))
        assertFalse(s.showPhotosensitivityNotice)
    }

    @Test
    fun timed_onlySunriseSunsetAreOffered_activeReflected_defaultsSane() {
        val s = map(light("c", "Lamp", activeTimedEffect = "sunset", capabilities = Caps.color(timed = setOf("sunrise", "sunset", "mystery"))))
        val t = (s.timed as SectionUi.Ready).value
        assertEquals(listOf(TimedEffect.SUNRISE, TimedEffect.SUNSET), t.options)
        assertEquals(TimedEffect.SUNSET, t.active)
        assertEquals(TimedEffect.SUNRISE, t.selected)
        assertEquals(30, t.durationMinutes)
        assertEquals(listOf(15, 30, 60), t.durationChoices)
    }

    @Test
    fun timed_knownButEmpty_isHidden() {
        val s = map(light("c", "Lamp", capabilities = Caps.color(timed = emptySet())))
        assertEquals(SectionUi.Hidden, s.timed)
    }

    @Test
    fun gradient_capIsMinOfPointsCapableAndProtocol_pointsPadded_modesFromLamp() {
        val s = map(light("g", "Strip", gradientPoints = listOf(CieXy(0.2, 0.2)), capabilities = Caps.gradient(pointsCapable = 7)))
        val g = (s.gradient as SectionUi.Ready).value
        assertEquals(5, g.maxPoints)
        assertEquals(5, g.points.size)
        assertTrue(g.points.all { it == CieXy(0.2, 0.2) })
        assertEquals(listOf("interpolated_palette", "random_pixelated"), g.modes)
        assertEquals("interpolated_palette", g.selectedMode)
        assertFalse(g.dirty)

        val three = map(light("g", "Strip", capabilities = Caps.gradient(pointsCapable = 3)))
        assertEquals(3, (three.gradient as SectionUi.Ready).value.maxPoints)
    }

    @Test
    fun gradient_pointsCapableBelowTwo_isHidden_notAFakeEditor() {
        val s = map(light("g", "Bulb", capabilities = Caps.gradient(pointsCapable = 1)))
        assertEquals(SectionUi.Hidden, s.gradient)
    }

    @Test
    fun gradientDraft_marksDirty_andIndexClamped() {
        val draft = listOf(CieXy(0.1, 0.1), CieXy(0.2, 0.2), CieXy(0.3, 0.3), CieXy(0.4, 0.4), CieXy(0.5, 0.5))
        val s = map(light("g", "Strip", capabilities = Caps.gradient()), LightEdits(gradientDraft = draft, gradientIndex = 99))
        val g = (s.gradient as SectionUi.Ready).value
        assertTrue(g.dirty)
        assertEquals(4, g.selectedIndex)
    }

    @Test
    fun missingLight_isNotFound_withStrip() {
        val s = LightDetailUiMapper.map(Fixtures.home(), com.chromaglow.app.feature.testing.lightKey("nope"), LightEdits(), DefaultEffectSafetyRegister, 0L)
        assertFalse(s.found)
        assertEquals(1, s.strip.size)
    }

    @Test
    fun offline_disablesEverything_sectionsStillHonest() {
        val s = map(light("c", "Lamp", capabilities = Caps.color()), connection = ConnectionState.Offline)
        assertFalse(s.controlsEnabled)
        assertTrue(s.color is SectionUi.Ready) // evidence unchanged; interaction is what's refused
        assertTrue(s.disabledReason!!.contains("offline"))
    }
}
