package com.chromaglow.app.core.hue.rest

import com.chromaglow.app.core.hue.capability.CieXy
import com.chromaglow.app.core.hue.capability.MirekRange
import com.chromaglow.app.core.session.LiveMutation
import com.chromaglow.app.core.session.TimedEffect
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.reflect.full.memberFunctions

/**
 * Golden bodies — exact JSON strings, key order included. The effects_v2 / timed_effects /
 * gradient goldens are the iOS `HueCapabilityFoundationTests` shapes ported verbatim.
 */
class ClipBodiesTest {

    private fun s(body: ClipWriteBody): String = body.json.toString()

    @Test
    fun power_golden() {
        assertEquals("""{"on":{"on":true}}""", s(ClipBodies.power(true)))
        assertEquals("""{"on":{"on":false}}""", s(ClipBodies.power(false)))
    }

    @Test
    fun brightness_golden_floorOne_capHundred_allowZeroOnlyOnRequest() {
        assertEquals("""{"dimming":{"brightness":75}}""", s(ClipBodies.brightness(75)))
        assertEquals("""{"dimming":{"brightness":1}}""", s(ClipBodies.brightness(0)))
        assertEquals("""{"dimming":{"brightness":1}}""", s(ClipBodies.brightness(-5)))
        assertEquals("""{"dimming":{"brightness":100}}""", s(ClipBodies.brightness(150)))
        assertEquals("""{"dimming":{"brightness":0}}""", s(ClipBodies.brightness(0, allowZero = true)))
    }

    @Test
    fun powerAndBrightness_isOneAtomicBody() {
        assertEquals("""{"on":{"on":true},"dimming":{"brightness":75}}""", s(ClipBodies.powerAndBrightness(true, 75)))
    }

    @Test
    fun color_golden() {
        assertEquals("""{"color":{"xy":{"x":0.32,"y":0.31}}}""", s(ClipBodies.color(CieXy(0.32, 0.31))))
    }

    @Test
    fun colorTemperature_clampsToLampSchemaWhenKnown_elseProtocolBound() {
        assertEquals("""{"color_temperature":{"mirek":366}}""", s(ClipBodies.colorTemperature(366)))
        assertEquals("""{"color_temperature":{"mirek":500}}""", s(ClipBodies.colorTemperature(9000)))
        assertEquals("""{"color_temperature":{"mirek":153}}""", s(ClipBodies.colorTemperature(1)))
        assertEquals("""{"color_temperature":{"mirek":450}}""", s(ClipBodies.colorTemperature(500, MirekRange(200, 450))))
        assertEquals("""{"color_temperature":{"mirek":200}}""", s(ClipBodies.colorTemperature(153, MirekRange(200, 450))))
    }

    @Test
    fun effectV1_golden_andNoEffect() {
        assertEquals("""{"effects":{"effect":"candle"}}""", s(ClipBodies.effectV1("candle")))
        assertEquals("""{"effects":{"effect":"no_effect"}}""", s(ClipBodies.stopEffect(viaV2 = false)))
    }

    // iOS testEffectsV2BodyFullParameters
    @Test
    fun effectsV2_fullParameters_golden() {
        val body = ClipBodies.effectV2("cosmos", speed = 0.7, color = CieXy(0.2, 0.4), mirek = 300)
        assertEquals(
            """{"effects_v2":{"action":{"effect":"cosmos","parameters":{"speed":0.7,"color":{"xy":{"x":0.2,"y":0.4}},"color_temperature":{"mirek":300}}}}}""",
            s(body),
        )
    }

    // iOS testEffectsV2BodyBareEffectOmitsParameters
    @Test
    fun effectsV2_bareEffect_omitsParameters() {
        assertEquals("""{"effects_v2":{"action":{"effect":"no_effect"}}}""", s(ClipBodies.effectV2("no_effect")))
        assertEquals("""{"effects_v2":{"action":{"effect":"no_effect"}}}""", s(ClipBodies.stopEffect(viaV2 = true)))
    }

    // iOS testEffectsV2BodyClampsSpeedAndMirek
    @Test
    fun effectsV2_clampsSpeedAndMirek() {
        assertEquals(
            """{"effects_v2":{"action":{"effect":"candle","parameters":{"speed":1.0,"color_temperature":{"mirek":500}}}}}""",
            s(ClipBodies.effectV2("candle", speed = 1.7, mirek = 9000)),
        )
        assertEquals(
            """{"effects_v2":{"action":{"effect":"candle","parameters":{"speed":0.0,"color_temperature":{"mirek":454}}}}}""",
            s(ClipBodies.effectV2("candle", speed = -1.0, mirek = 9000, mirekRange = MirekRange(153, 454))),
        )
    }

    @Test
    fun effectsV2_onlyProvidedParameterKeysAreEmitted() {
        assertEquals("""{"effects_v2":{"action":{"effect":"prism","parameters":{"speed":0.5}}}}""", s(ClipBodies.effectV2("prism", speed = 0.5)))
        assertEquals("""{"effects_v2":{"action":{"effect":"prism","parameters":{"color":{"xy":{"x":0.5,"y":0.4}}}}}}""", s(ClipBodies.effectV2("prism", color = CieXy(0.5, 0.4))))
        assertThrows(IllegalArgumentException::class.java) { ClipBodies.effectV2(" ") }
    }

    // iOS testTimedEffectsBodySunriseWithDuration + testTimedEffectsBodyClearsFirmwareEffectInSamePut
    @Test
    fun timedEffects_golden_clearsFirmwareEffectInTheSamePut() {
        assertEquals(
            """{"timed_effects":{"effect":"sunrise","duration":900000},"effects":{"effect":"no_effect"}}""",
            s(ClipBodies.timedEffect(ClipBodies.TIMED_SUNRISE, 900_000L)),
        )
        assertEquals(
            """{"timed_effects":{"effect":"sunset","duration":60000}}""",
            s(ClipBodies.timedEffect(TimedEffect.SUNSET.wireName, 60_000L, clearFirmwareEffect = false)),
        )
    }

    // iOS testTimedEffectsBodyClampsToSixHours
    @Test
    fun timedEffects_clampsToSixHours_andToTheSixtySecondFloor() {
        assertEquals(
            """{"timed_effects":{"effect":"sunset","duration":21600000},"effects":{"effect":"no_effect"}}""",
            s(ClipBodies.timedEffect("sunset", 99_999_999L)),
        )
        // E-08: a 0 s "sunset" would be an instantaneous full-scale step; the body floors at 60 s.
        assertEquals(
            """{"timed_effects":{"effect":"sunset","duration":60000},"effects":{"effect":"no_effect"}}""",
            s(ClipBodies.timedEffect("sunset", -1L)),
        )
        assertEquals(LiveMutation.MIN_TIMED_EFFECT_MILLIS, ClipBodies.MIN_TIMED_EFFECT_MILLIS)
    }

    @Test
    fun timedEffects_cancel_golden() {
        assertEquals("""{"timed_effects":{"effect":"no_effect"}}""", s(ClipBodies.cancelTimedEffect()))
    }

    // iOS testGradientBodyThreePoints
    @Test
    fun gradient_threePoints_golden() {
        val body = ClipBodies.gradient(listOf(CieXy(0.64, 0.33), CieXy(0.17, 0.70), CieXy(0.15, 0.06)), pointsCapable = 5)
        assertEquals(
            """{"gradient":{"points":[{"color":{"xy":{"x":0.64,"y":0.33}}},{"color":{"xy":{"x":0.17,"y":0.7}}},{"color":{"xy":{"x":0.15,"y":0.06}}}]}}""",
            s(body),
        )
    }

    // iOS testGradientBodyPadsSinglePointToTwo
    @Test
    fun gradient_singlePoint_isPaddedToTwo() {
        assertEquals(
            """{"gradient":{"points":[{"color":{"xy":{"x":0.3,"y":0.3}}},{"color":{"xy":{"x":0.3,"y":0.3}}}]}}""",
            s(ClipBodies.gradient(listOf(CieXy(0.3, 0.3)), pointsCapable = 5)),
        )
    }

    // iOS testGradientBodyCapsAtFivePoints, plus the per-lamp points_capable cap
    @Test
    fun gradient_capsAtMinOfPointsCapableAndFive() {
        val seven = (0 until 7).map { CieXy(it / 10.0, 0.3) }
        fun count(body: ClipWriteBody) = body.json["gradient"]!!.toString().split("\"color\"").size - 1
        assertEquals(5, count(ClipBodies.gradient(seven, pointsCapable = 5)))
        assertEquals(5, count(ClipBodies.gradient(seven, pointsCapable = 9)))
        assertEquals(3, count(ClipBodies.gradient(seven, pointsCapable = 3)))
        assertEquals(2, count(ClipBodies.gradient(seven, pointsCapable = 1)))
    }

    // iOS testGradientBodyWithFrameExtras
    @Test
    fun gradient_withModeAndFrameExtras_golden() {
        val body = ClipBodies.gradient(
            listOf(CieXy(0.2, 0.3), CieXy(0.4, 0.5)), pointsCapable = 5,
            mode = "interpolated_palette", on = true, brightnessPercent = 60, transitionMillis = 200L,
        )
        assertEquals(
            """{"gradient":{"points":[{"color":{"xy":{"x":0.2,"y":0.3}}},{"color":{"xy":{"x":0.4,"y":0.5}}}],"mode":"interpolated_palette"},"on":{"on":true},"dimming":{"brightness":60},"dynamics":{"duration":200}}""",
            s(body),
        )
        assertThrows(IllegalArgumentException::class.java) { ClipBodies.gradient(emptyList(), 5) }
    }

    @Test
    fun sceneRecall_golden_andDynamicPaletteIsModelOnly() {
        assertEquals("""{"recall":{"action":"active"}}""", s(ClipBodies.sceneRecall()))
        assertEquals("""{"recall":{"action":"dynamic_palette","duration":5000}}""", s(ClipBodies.dynamicPaletteRecall(5000L)))
        assertEquals("""{"recall":{"action":"dynamic_palette"}}""", s(ClipBodies.dynamicPaletteRecall()))
    }

    @Test
    fun transition_golden() {
        assertEquals("""{"dynamics":{"duration":400}}""", s(ClipBodies.transition(400L)))
        assertEquals("""{"dynamics":{"duration":0}}""", s(ClipBodies.transition(-3L)))
        assertEquals(
            """{"color":{"xy":{"x":0.3,"y":0.3}},"dynamics":{"duration":400}}""",
            s(ClipBodies.combine(ClipBodies.color(CieXy(0.3, 0.3)), ClipBodies.transition(400L))),
        )
    }

    @Test
    fun combine_neverAllowsColourAndColourTemperatureInOneBody() {
        assertThrows(IllegalArgumentException::class.java) {
            ClipBodies.combine(ClipBodies.color(CieXy(0.3, 0.3)), ClipBodies.colorTemperature(300))
        }
    }

    @Test
    fun noSignalingBodyExists_andCombineRefusesOne() {
        val names = ClipBodies::class.memberFunctions.map { it.name.lowercase() }
        assertFalse(names.any { it.contains("signal") })
        val smuggled = ClipWriteBody(kotlinx.serialization.json.buildJsonObject {
            put("signaling", kotlinx.serialization.json.buildJsonObject { put("signal", kotlinx.serialization.json.JsonPrimitive("on_off")) })
        })
        assertThrows(IllegalArgumentException::class.java) { ClipBodies.combine(smuggled) }
    }

    @Test
    fun constants_matchTheFrozenMutationContract() {
        assertEquals(LiveMutation.MAX_TIMED_EFFECT_MILLIS, ClipBodies.MAX_TIMED_EFFECT_MILLIS)
        assertEquals(LiveMutation.MAX_GRADIENT_POINTS, ClipBodies.MAX_GRADIENT_POINTS)
        assertEquals(TimedEffect.SUNRISE.wireName, ClipBodies.TIMED_SUNRISE)
        assertEquals(TimedEffect.SUNSET.wireName, ClipBodies.TIMED_SUNSET)
    }

    @Test
    fun isStateWrite_classifiesLightLevelStateBodies() {
        assertTrue(ClipBodies.isStateWrite(ClipBodies.power(true)))
        assertTrue(ClipBodies.isStateWrite(ClipBodies.gradient(listOf(CieXy(0.3, 0.3)), 5)))
        assertFalse(ClipBodies.isStateWrite(ClipBodies.sceneRecall()))
        assertFalse(ClipBodies.isStateWrite(ClipBodies.effectV2("candle")))
    }
}
