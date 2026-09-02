package com.chromaglow.app.core.session

import com.chromaglow.app.core.hue.capability.CieXy
import com.chromaglow.app.core.hue.capability.LightCapabilities
import com.chromaglow.app.core.identity.BridgeId
import com.chromaglow.app.core.identity.ResourceId
import com.chromaglow.app.core.identity.ResourceKey
import com.chromaglow.app.core.identity.ResourceType
import com.chromaglow.app.core.identity.TargetRef
import com.chromaglow.app.core.session.safety.DefaultEffectSafetyRegister
import com.chromaglow.app.core.session.safety.FlashSafetyConstants
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.reflect.KClass
import kotlin.reflect.full.memberFunctions
import kotlin.reflect.full.memberProperties
import kotlin.reflect.full.primaryConstructor

class SessionContractTest {

    private val bridgeA = BridgeId("001788FFFE112233")
    private val bridgeB = BridgeId("AABBCCDDEEFF0011")

    private fun key(bridge: BridgeId, type: ResourceType, id: String) = ResourceKey(bridge, type, ResourceId(id))

    private fun light(bridge: BridgeId, id: String) = LightState(
        key = key(bridge, ResourceType.LIGHT, id), name = "Lamp", isOn = true, brightness = 50.0,
        color = CieXy(0.3, 0.3), mirek = null, mirekValid = false, activeEffect = null,
        activeTimedEffect = null, gradientPoints = emptyList(), owner = null,
        capabilities = LightCapabilities.unknown(),
    )

    // 9. BridgeSnapshotCache / BridgeSnapshot are bridge-qualified by construction.
    @Test
    fun bridgeSnapshot_refusesResourcesOfAnotherBridge() {
        assertThrows(IllegalArgumentException::class.java) {
            BridgeSnapshot.empty(bridgeA).copy(lights = mapOf(light(bridgeB, "l1").key to light(bridgeB, "l1")))
        }
    }

    @Test
    fun bridgeSnapshot_refusesWrongTypeInATypedMap() {
        val wrong = key(bridgeA, ResourceType.SCENE, "s1")
        assertThrows(IllegalArgumentException::class.java) {
            BridgeSnapshot.empty(bridgeA).copy(lights = mapOf(wrong to light(bridgeA, "s1").copy(key = wrong)))
        }
    }

    @Test
    fun bridgeSnapshot_sameRidOnTwoBridges_liveInSeparateSnapshots() {
        val a = BridgeSnapshot.empty(bridgeA).copy(lights = mapOf(light(bridgeA, "same").key to light(bridgeA, "same")))
        val b = BridgeSnapshot.empty(bridgeB).copy(lights = mapOf(light(bridgeB, "same").key to light(bridgeB, "same")))
        val home = HomeSnapshot(bridges = mapOf(bridgeA to a, bridgeB to b), connections = emptyMap())
        assertEquals(2, home.bridges.values.flatMap { it.lights.keys }.toSet().size)
        assertThrows(IllegalArgumentException::class.java) { HomeSnapshot(mapOf(bridgeA to b), emptyMap()) }
    }

    @Test
    fun snapshotTypes_areSecretFreeByConstruction() {
        // Every property name reachable from BridgeSnapshot is scanned; a credential-looking name
        // anywhere in the persisted shape fails this test.
        val forbidden = listOf("token", "username", "secret", "password", "apikey", "api_key", "clientkey", "credential")
        val seen = mutableSetOf<KClass<*>>()
        fun scan(cls: KClass<*>) {
            if (!seen.add(cls)) return
            for (prop in cls.memberProperties) {
                val name = prop.name.lowercase()
                assertFalse("secret-looking property ${cls.simpleName}.${prop.name}", forbidden.any { name.contains(it) })
            }
            cls.primaryConstructor?.parameters?.forEach { p ->
                val k = p.type.classifier as? KClass<*> ?: return@forEach
                if (k.qualifiedName?.startsWith("com.chromaglow") == true) scan(k)
            }
        }
        scan(BridgeSnapshot::class)
        for (nested in listOf(GroupState::class, GroupedLightState::class, LightState::class, SceneState::class)) scan(nested)
        assertTrue(seen.contains(LightState::class))
    }

    @Test
    fun cacheContract_isVersioned_andReadOutcomesAreNonFatal() {
        assertEquals(1, BridgeSnapshotCache.FORMAT_VERSION)
        val outcomes: List<CacheReadResult> = listOf(
            CacheReadResult.Hit(BridgeSnapshot.empty(bridgeA)), CacheReadResult.Miss, CacheReadResult.Discarded("bad version"),
        )
        assertEquals(3, outcomes.map { it::class }.toSet().size)
    }

    // 10. Feature/UI-facing command interfaces expose TargetRef, not bare resource IDs.
    @Test
    fun homeCommands_everyTargetedCommandTakesTargetRef_neverAStringId() {
        val targeted = HomeCommands::class.java.declaredMethods.filter { it.name != "refresh" }
        assertTrue(targeted.size >= 12)
        for (m in targeted) {
            assertEquals("${m.name} must address a TargetRef", TargetRef::class.java, m.parameterTypes.first())
            assertFalse("${m.name} must not take a bare String id", m.parameterTypes.drop(1).any { it == String::class.java && m.name != "selectEffect" && m.name != "setGradient" })
        }
        // Shell-boundary Forget takes the physical BridgeId (a value class, so Kotlin reflection),
        // never a string.
        val forget = SessionShellCommands::class.memberFunctions.single { it.name == "forgetBridge" }
        assertEquals(BridgeId::class, forget.parameters.last().type.classifier)
    }

    @Test
    fun liveMutation_isBridgeQualified_andHasNoSignalingVariant() {
        val variants = LiveMutation::class.sealedSubclasses
        assertTrue(variants.size >= 10)
        assertFalse(variants.any { it.simpleName!!.contains("Signal", ignoreCase = true) })
        for (v in variants) assertTrue(v.simpleName, v.memberProperties.any { it.name == "target" })
        assertThrows(IllegalArgumentException::class.java) { LiveMutation.SetBrightness(key(bridgeA, ResourceType.LIGHT, "l"), 0) }
        assertThrows(IllegalArgumentException::class.java) {
            LiveMutation.StartTimedEffect(key(bridgeA, ResourceType.LIGHT, "l"), TimedEffect.SUNRISE, LiveMutation.MAX_TIMED_EFFECT_MILLIS + 1)
        }
        assertThrows(IllegalArgumentException::class.java) {
            LiveMutation.SetGradient(key(bridgeA, ResourceType.LIGHT, "l"), List(6) { CieXy(0.3, 0.3) }, null)
        }
    }

    @Test
    fun fieldGroups_separateBrightnessFromColour_andEffectFromPower() {
        val k = key(bridgeA, ResourceType.LIGHT, "l")
        assertEquals(FieldGroup.DIMMING, LiveMutation.SetBrightness(k, 50).field)
        assertEquals(FieldGroup.COLOR, LiveMutation.SetColor(k, CieXy(0.3, 0.3)).field)
        assertEquals(FieldGroup.EFFECT, LiveMutation.SelectEffect(k, "candle").field)
        assertEquals(FieldGroup.POWER, LiveMutation.SetPower(k, true).field)
        assertEquals(8, FieldGroup.entries.size)
    }

    @Test
    fun safetyConstants_pinTheEstablishedInvariant() {
        assertEquals(340L, FlashSafetyConstants.MIN_ONSET_PERIOD_MILLIS)
        assertEquals(0.10, FlashSafetyConstants.ONSET_RISE_THRESHOLD, 0.0)
        assertEquals(0.02, FlashSafetyConstants.RED_STEP_LUMINANCE_DELTA, 0.0)
        assertTrue(1000.0 / FlashSafetyConstants.MIN_ONSET_PERIOD_MILLIS <= FlashSafetyConstants.MAX_FLASH_HZ)
        assertTrue(DefaultEffectSafetyRegister.denied.isEmpty())
        assertFalse(DefaultEffectSafetyRegister.isDenied("candle"))
    }

    @Test
    fun connectionState_coversEveryProductState() {
        val states: List<ConnectionState> = listOf(
            ConnectionState.Connecting, ConnectionState.Connected, ConnectionState.Stale(1L),
            ConnectionState.Offline, ConnectionState.Revoked, ConnectionState.Error(SessionErrorReason.UNREACHABLE),
        )
        assertEquals(6, states.map { it::class }.toSet().size)
    }
}
