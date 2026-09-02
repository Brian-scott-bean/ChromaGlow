package com.chromaglow.app.core.hue.capability

import com.chromaglow.app.core.identity.BridgeId
import com.chromaglow.app.core.identity.ResourceId
import com.chromaglow.app.core.identity.ResourceKey
import com.chromaglow.app.core.identity.ResourceType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class CapabilityContractTest {

    // 4. Unknown is distinct from Absent/Unsupported/Unreadable, and only Known is interactive.
    @Test
    fun evidence_unknownIsDistinct_andOnlyKnownIsInteractive() {
        val known = Capability.known(MirekRange(153, 500))
        val absent = Capability.absent<MirekRange>()
        val unsupported = Capability.unsupported<MirekRange>()
        val unreadable = Capability.unreadable<MirekRange>()
        val unknown = Capability.unknown<MirekRange>()

        assertEquals(setOf(Evidence.KNOWN, Evidence.ABSENT, Evidence.UNSUPPORTED, Evidence.UNREADABLE, Evidence.UNKNOWN),
            listOf(known, absent, unsupported, unreadable, unknown).map { it.evidence }.toSet())
        assertNotEquals(unknown, unsupported)
        assertNotEquals(unknown, absent)
        assertNotEquals(unknown, unreadable)

        assertTrue(known.isInteractive)
        for (c in listOf(absent, unsupported, unreadable, unknown)) assertFalse(c.isInteractive)
        // Unknown/Unreadable stage as CHECKING; Absent/Unsupported hide; never both.
        assertTrue(unknown.isChecking && unreadable.isChecking)
        assertTrue(absent.isHidden && unsupported.isHidden)
        assertFalse(unknown.isHidden || unreadable.isHidden || absent.isChecking || unsupported.isChecking)
    }

    @Test
    fun capability_knownRequiresValue_andNonKnownCarriesNone() {
        assertThrows(IllegalArgumentException::class.java) { Capability<Unit>(null, Evidence.KNOWN) }
        assertThrows(IllegalArgumentException::class.java) { Capability(Unit, Evidence.UNKNOWN) }
    }

    // 5. CT without mirek schema is not Known/interactable.
    @Test
    fun colorTemperature_withoutSchema_isUnreadable_neverInteractive() {
        val caps = LightCapabilities.unknown().copy(colorTemperature = Capability.unreadable())

        assertEquals(Evidence.UNREADABLE, caps.colorTemperature.evidence)
        assertFalse(caps.colorTemperature.isInteractive)
        assertTrue(caps.colorTemperature.isChecking)
        assertNull(caps.colorTemperature.value)
    }

    @Test
    fun mirekRange_clampsToTheLampsOwnRange_andEnforcesProtocolBounds() {
        val range = MirekRange(200, 450)
        assertEquals(200, range.clamp(153))
        assertEquals(450, range.clamp(500))
        assertTrue(300 in range)
        assertThrows(IllegalArgumentException::class.java) { MirekRange(100, 450) }
        assertThrows(IllegalArgumentException::class.java) { MirekRange(300, 200) }
        assertEquals(153, MirekRange.PROTOCOL_MINIMUM)
        assertEquals(500, MirekRange.PROTOCOL_MAXIMUM)
    }

    // 7. Gamut provenance distinguishes Bridge vs SpecDerived; nothing is inferred otherwise.
    @Test
    fun gamut_provenanceIsExplicit_andUnknownTypeYieldsNoGamut() {
        val bridge = Gamut.fromBridge(CieXy(0.7, 0.3), CieXy(0.17, 0.7), CieXy(0.15, 0.05))
        val spec = Gamut.fromGamutType("C")

        assertEquals(GamutSource.BRIDGE, bridge.source)
        assertEquals(GamutSource.SPEC_DERIVED, spec!!.source)
        assertEquals(Gamut.specDerived(GamutType.C), spec)
        assertEquals(GamutSource.SPEC_DERIVED, Gamut.fromGamutType("a")!!.source)
        assertNull(Gamut.fromGamutType("D"))
        assertNull(Gamut.fromGamutType(null))
        assertNull(Gamut.fromGamutType("Hue Go"))
    }

    @Test
    fun gamut_specTables_areTheThreePublishedHueGamuts() {
        assertEquals(CieXy(0.704, 0.296), Gamut.specDerived(GamutType.A).red)
        assertEquals(CieXy(0.409, 0.518), Gamut.specDerived(GamutType.B).green)
        assertEquals(CieXy(0.153, 0.048), Gamut.specDerived(GamutType.C).blue)
    }

    @Test
    fun effectValues_v2ShadowsV1_whenKnown() {
        val v1 = Capability.known(setOf("candle"))
        val v2 = Capability.known(setOf("candle", "prism"))
        val both = LightCapabilities.unknown().copy(effectsV1 = v1, effectsV2 = v2)
        val onlyV1 = LightCapabilities.unknown().copy(effectsV1 = v1)

        assertEquals(v2, both.effectValues)
        assertEquals(v1, onlyV1.effectValues)
        assertEquals(Evidence.UNKNOWN, LightCapabilities.unknown().effectValues.evidence)
    }

    @Test
    fun gradientCapability_requiresAtLeastTwoPoints() {
        assertTrue(GradientCapability(5, setOf("interpolated_palette"), 7).supportsGradient)
        assertFalse(GradientCapability(1, emptySet(), null).supportsGradient)
    }

    // 6. RunUnverified cannot produce an allowed user mutation result.
    @Test
    fun effectRouting_onlyRunPermitsMutation() {
        val key = ResourceKey(BridgeId("001788FFFE112233"), ResourceType.LIGHT, ResourceId("l1"))

        assertTrue(EffectRouting.Run(setOf(key), Coverage(setOf(key), 2)).permitsUserMutation)
        assertFalse(EffectRouting.Run(emptySet(), Coverage(emptySet(), 2)).permitsUserMutation)
        assertFalse(EffectRouting.Unsupported("cosmos").permitsUserMutation)
        assertFalse(EffectRouting.RunUnverified(setOf(key)).permitsUserMutation)
    }

    // 8. Routing classification exactly matches the approved mapping.
    @Test
    fun controlRouting_matchesTheApprovedMapExactly() {
        val expected = mapOf(
            ControlKind.POWER to RoutingClass.GROUP_NATIVE,
            ControlKind.BRIGHTNESS to RoutingClass.GROUP_NATIVE,
            ControlKind.COLOR to RoutingClass.SUBSET_PER_LIGHT,
            ControlKind.COLOR_TEMPERATURE to RoutingClass.SUBSET_PER_LIGHT,
            ControlKind.FIRMWARE_EFFECT to RoutingClass.SUBSET_PER_LIGHT,
            ControlKind.TIMED_EFFECT to RoutingClass.ALL_OR_NOTHING,
            ControlKind.GRADIENT to RoutingClass.PER_LIGHT_ONLY,
            ControlKind.SCENE_RECALL to RoutingClass.GROUP_NATIVE,
        )
        assertEquals(expected.keys, ControlKind.entries.toSet())
        for ((kind, routing) in expected) assertEquals(kind.name, routing, ControlRouting.classOf(kind))
        // No signaling control exists in the approved slice.
        assertFalse(ControlKind.entries.any { it.name.contains("SIGNAL") })
    }
}
