package com.chromaglow.app.core.hue.capability

import com.chromaglow.app.core.hue.rest.wire.ClipResourceCodec
import com.chromaglow.app.core.identity.BridgeId
import com.chromaglow.app.core.identity.ResourceId
import com.chromaglow.app.core.identity.ResourceKey
import com.chromaglow.app.core.identity.ResourceType
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The evidence matrix, gamut provenance, v2-shadows-v1, all-or-nothing, and the §11 routing classes. */
class CapabilityResolverTest {

    private val bridge = BridgeId("001788FFFE112233")
    private fun key(id: String) = ResourceKey(bridge, ResourceType.LIGHT, ResourceId(id))

    private fun caps(json: String): LightCapabilities =
        CapabilityResolver.resolve(ClipResourceCodec.light(Json.parseToJsonElement(json).jsonObject)!!)

    private val white = """{"id":"w","type":"light","on":{"on":true},"dimming":{"brightness":50}}"""
    private val ctWithSchema = """{"id":"ct","type":"light","color_temperature":{"mirek":300,"mirek_schema":{"mirek_minimum":153,"mirek_maximum":454}}}"""
    private val ctNoSchema = """{"id":"ct2","type":"light","color_temperature":{"mirek":300,"mirek_valid":true}}"""
    private val ctBadSchema = """{"id":"ct3","type":"light","color_temperature":{"mirek_schema":{"mirek_minimum":10,"mirek_maximum":9000}}}"""
    private val colourBridgeGamut = """{"id":"c1","type":"light","color":{"xy":{"x":0.3,"y":0.3},"gamut":{"red":{"x":0.69,"y":0.31},"green":{"x":0.17,"y":0.7},"blue":{"x":0.15,"y":0.05}},"gamut_type":"C"}}"""
    private val colourTypeOnly = """{"id":"c2","type":"light","color":{"xy":{"x":0.3,"y":0.3},"gamut_type":"B"}}"""
    private val colourNoGamut = """{"id":"c3","type":"light","color":{"xy":{"x":0.3,"y":0.3}}}"""
    private val colourBadTriangle = """{"id":"c4","type":"light","color":{"gamut":{"red":{"x":1.5,"y":0.3},"green":{"x":0.17,"y":0.7},"blue":{"x":0.15,"y":0.05}},"gamut_type":"A"}}"""
    private val v1Only = """{"id":"e1","type":"light","effects":{"effect_values":["no_effect","candle"]}}"""
    private val v2AndV1 = """{"id":"e2","type":"light","effects":{"effect_values":["candle"]},"effects_v2":{"action":{"effect_values":["candle","prism","cosmos"]}}}"""
    private val v2Empty = """{"id":"e3","type":"light","effects":{"effect_values":["candle"]},"effects_v2":{"action":{"effect_values":[]}}}"""
    private val timed = """{"id":"t","type":"light","timed_effects":{"effect_values":["no_effect","sunrise","sunset"]}}"""
    private val strip = """{"id":"g","type":"light","gradient":{"points_capable":5,"mode_values":["interpolated_palette","random_pixelated"],"pixel_count":7}}"""
    private val notStrip = """{"id":"g1","type":"light","gradient":{"points_capable":1}}"""
    private val gradientNoCount = """{"id":"g2","type":"light","gradient":{"mode":"interpolated_palette"}}"""
    private val signalling = """{"id":"s","type":"light","signaling":{"signal_values":["no_signal","on_off"]}}"""

    // --- evidence matrix ------------------------------------------------------------------------

    @Test
    fun neverFetched_isUnknownOnEveryAxis() {
        val u = LightCapabilities.unknown()
        for (c in listOf(u.color, u.colorTemperature, u.effectsV1, u.effectsV2, u.timedEffects, u.gradient, u.signaling, u.dynamics)) {
            assertEquals(Evidence.UNKNOWN, c.evidence)
            assertTrue(c.isChecking)
        }
    }

    @Test
    fun whiteOnlyLamp_hasEveryOptionalBlockAbsent_neverUnknown() {
        val c = caps(white)
        for (axis in listOf(c.color, c.colorTemperature, c.effectsV1, c.effectsV2, c.timedEffects, c.gradient, c.signaling, c.dynamics)) {
            assertEquals(Evidence.ABSENT, axis.evidence)
            assertTrue(axis.isHidden)
        }
    }

    @Test
    fun colorTemperature_withSchema_isKnownWithTheLampsOwnRange() {
        val c = caps(ctWithSchema)
        assertEquals(Capability.known(MirekRange(153, 454)), c.colorTemperature)
        assertTrue(c.colorTemperature.isInteractive)
    }

    @Test
    fun colorTemperature_withoutSchema_isUnreadable_neverFabricated() {
        val c = caps(ctNoSchema)
        assertEquals(Evidence.UNREADABLE, c.colorTemperature.evidence)
        assertFalse(c.colorTemperature.isInteractive)
        assertTrue(c.colorTemperature.isChecking)
        assertEquals(null, c.colorTemperature.value)
    }

    @Test
    fun colorTemperature_withOutOfProtocolSchema_isUnreadable() {
        assertEquals(Evidence.UNREADABLE, caps(ctBadSchema).colorTemperature.evidence)
    }

    @Test
    fun colorTemperature_presentButGarbage_isUnreadable_notAbsent() {
        assertEquals(Evidence.UNREADABLE, caps("""{"id":"x","type":"light","color_temperature":"?"}""").colorTemperature.evidence)
    }

    @Test
    fun gamut_bridgeTriangle_wins_overGamutType() {
        val c = caps(colourBridgeGamut)
        assertEquals(GamutSource.BRIDGE, c.color.value!!.source)
        assertEquals(CieXy(0.69, 0.31), c.color.value!!.red)
    }

    @Test
    fun gamut_typeOnly_isSpecDerived() {
        val c = caps(colourTypeOnly)
        assertEquals(Capability.known(Gamut.specDerived(GamutType.B)), c.color)
    }

    @Test
    fun gamut_neitherTriangleNorType_isUnknown_soTheColourPadChecks() {
        val c = caps(colourNoGamut)
        assertEquals(Evidence.UNKNOWN, c.color.evidence)
        assertTrue(c.color.isChecking)
    }

    @Test
    fun gamut_invalidTriangle_fallsBackToGamutType() {
        assertEquals(Capability.known(Gamut.specDerived(GamutType.A)), caps(colourBadTriangle).color)
    }

    @Test
    fun effects_v2NonEmpty_shadowsV1() {
        val c = caps(v2AndV1)
        assertEquals(setOf("candle", "prism", "cosmos"), c.effectValues.value)
        assertEquals(Capability.known(setOf("candle")), c.effectsV1)
    }

    @Test
    fun effects_v1Only_isTheFallbackSource() {
        val c = caps(v1Only)
        assertEquals(Evidence.ABSENT, c.effectsV2.evidence)
        assertEquals(setOf("no_effect", "candle"), c.effectValues.value)
    }

    @Test
    fun effects_v2PresentButEmpty_isUnreadable_andDoesNotShadowV1() {
        val c = caps(v2Empty)
        assertEquals(Evidence.UNREADABLE, c.effectsV2.evidence)
        assertEquals(setOf("candle"), c.effectValues.value)
    }

    @Test
    fun supportsEffect_requiresKnownListContainingTheEffect() {
        val c = caps(v2AndV1)
        assertTrue(CapabilityResolver.supportsEffect(c, "prism"))
        assertFalse(CapabilityResolver.supportsEffect(c, "sparkle"))
        assertFalse(CapabilityResolver.supportsEffect(LightCapabilities.unknown(), "prism"))
        assertFalse(CapabilityResolver.supportsEffect(caps(white), "prism"))
    }

    @Test
    fun timedEffects_known_andSupportsTimedEffectIsExact() {
        val c = caps(timed)
        assertTrue(CapabilityResolver.supportsTimedEffect(c, "sunrise"))
        assertFalse(CapabilityResolver.supportsTimedEffect(c, "winddown"))
        assertFalse(CapabilityResolver.supportsTimedEffect(caps(white), "sunrise"))
    }

    @Test
    fun gradient_known_withModesFromModeValues_andLessThanTwoPointsIsNotAStrip() {
        val g = caps(strip).gradient
        assertEquals(Capability.known(GradientCapability(5, setOf("interpolated_palette", "random_pixelated"), 7)), g)
        assertTrue(CapabilityResolver.supportsGradient(caps(strip)))
        assertFalse(CapabilityResolver.supportsGradient(caps(notStrip)))
        assertEquals(Evidence.KNOWN, caps(notStrip).gradient.evidence)
        assertEquals(Evidence.UNREADABLE, caps(gradientNoCount).gradient.evidence)
    }

    @Test
    fun signaling_isDecodedAsTruth_only() {
        assertEquals(Capability.known(setOf("no_signal", "on_off")), caps(signalling).signaling)
    }

    @Test
    fun dynamics_presentIsKnown_absentIsAbsent() {
        assertEquals(Capability.known(Unit), caps("""{"id":"d","type":"light","dynamics":{"status":"none"}}""").dynamics)
        assertEquals(Evidence.ABSENT, caps(white).dynamics.evidence)
    }

    @Test
    fun nothingIsInferredFromArchetypeOrProductNames() {
        val lightstrip = caps("""{"id":"l","type":"light","metadata":{"name":"Hue Play gradient lightstrip","archetype":"hue_lightstrip"}}""")
        assertEquals(Evidence.ABSENT, lightstrip.gradient.evidence)
        assertEquals(Evidence.ABSENT, lightstrip.color.evidence)
    }

    // --- group routing ------------------------------------------------------------------------

    @Test
    fun routeEffect_noMemberReportsAnyList_isRunUnverified_whichNeverPermitsASend() {
        val members = mapOf(key("a") to caps(white), key("b") to LightCapabilities.unknown())
        val verdict = CapabilityResolver.routeEffect("candle", members)
        assertEquals(EffectRouting.RunUnverified(members.keys), verdict)
        assertFalse(verdict.permitsUserMutation)
        assertFalse(CapabilityResolver.routeEffect("candle", emptyMap()).permitsUserMutation)
    }

    @Test
    fun routeEffect_someReportButNoneListsIt_isUnsupported() {
        val members = mapOf(key("a") to caps(v1Only), key("b") to caps(white))
        assertEquals(EffectRouting.Unsupported("cosmos"), CapabilityResolver.routeEffect("cosmos", members))
    }

    @Test
    fun routeEffect_subsetRouting_withNofMCoverage() {
        val members = mapOf(key("a") to caps(v2AndV1), key("b") to caps(v1Only), key("c") to caps(white))
        val verdict = CapabilityResolver.routeEffect("candle", members) as EffectRouting.Run
        assertEquals(setOf(key("a"), key("b")), verdict.targets)
        assertEquals(2, verdict.coverage.capable.size)
        assertEquals(3, verdict.coverage.total)
        assertFalse(verdict.coverage.isFull)
        assertTrue(verdict.permitsUserMutation)
        val prism = CapabilityResolver.routeEffect("prism", members) as EffectRouting.Run
        assertEquals(setOf(key("a")), prism.targets)
    }

    @Test
    fun timedEffects_onAGroup_areAllOrNothing() {
        val full = mapOf(key("a") to caps(timed), key("b") to caps(timed))
        val partial = mapOf(key("a") to caps(timed), key("b") to caps(white))
        assertTrue(CapabilityResolver.offersTimedEffectOnGroup("sunrise", full))
        assertFalse(CapabilityResolver.offersTimedEffectOnGroup("sunrise", partial))
        assertFalse(CapabilityResolver.offersTimedEffectOnGroup("sunrise", emptyMap()))
        assertEquals(1, CapabilityResolver.timedEffectCoverage("sunrise", partial).capable.size)
    }

    @Test
    fun coverage_perControlKind_countsOnlyKnown() {
        val members = mapOf(
            key("a") to caps(colourBridgeGamut), key("b") to caps(colourNoGamut), key("c") to caps(ctWithSchema),
            key("d") to caps(ctNoSchema), key("e") to caps(strip), key("f") to LightCapabilities.unknown(),
        )
        assertEquals(6, CapabilityResolver.coverage(ControlKind.POWER, members).capable.size)
        assertEquals(6, CapabilityResolver.coverage(ControlKind.BRIGHTNESS, members).capable.size)
        assertEquals(setOf(key("a")), CapabilityResolver.coverage(ControlKind.COLOR, members).capable)
        assertEquals(setOf(key("c")), CapabilityResolver.coverage(ControlKind.COLOR_TEMPERATURE, members).capable)
        assertEquals(setOf(key("e")), CapabilityResolver.coverage(ControlKind.GRADIENT, members).capable)
        assertEquals(setOf(key("e")), CapabilityResolver.gradientLights(members))
        assertTrue(CapabilityResolver.coverage(ControlKind.FIRMWARE_EFFECT, members).isEmpty)
    }

    @Test
    fun routingClasses_arePinnedForEveryControlKind() {
        assertEquals(RoutingClass.SUBSET_PER_LIGHT, ControlRouting.classOf(ControlKind.COLOR))
        assertEquals(RoutingClass.SUBSET_PER_LIGHT, ControlRouting.classOf(ControlKind.COLOR_TEMPERATURE))
        assertEquals(RoutingClass.SUBSET_PER_LIGHT, ControlRouting.classOf(ControlKind.FIRMWARE_EFFECT))
        assertEquals(RoutingClass.ALL_OR_NOTHING, ControlRouting.classOf(ControlKind.TIMED_EFFECT))
        assertEquals(RoutingClass.PER_LIGHT_ONLY, ControlRouting.classOf(ControlKind.GRADIENT))
        assertEquals(RoutingClass.GROUP_NATIVE, ControlRouting.classOf(ControlKind.SCENE_RECALL))
    }

    @Test
    fun sameRidOnTwoBridges_areSeparateMembers() {
        val otherBridge = ResourceKey(BridgeId("AABBCCDDEEFF0011"), ResourceType.LIGHT, ResourceId("a"))
        val members = mapOf(key("a") to caps(v2AndV1), otherBridge to caps(white))
        val verdict = CapabilityResolver.routeEffect("candle", members) as EffectRouting.Run
        assertEquals(setOf(key("a")), verdict.targets)
        assertEquals(2, verdict.coverage.total)
    }
}
