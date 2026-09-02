package com.chromaglow.app.core.session

import com.chromaglow.app.core.hue.capability.CieXy
import com.chromaglow.app.core.hue.capability.LightCapabilities
import com.chromaglow.app.core.identity.BridgeId
import com.chromaglow.app.core.identity.ResourceId
import com.chromaglow.app.core.identity.ResourceKey
import com.chromaglow.app.core.identity.ResourceType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** D-07: authority is keyed by the full bridge-qualified key and the field; B-01 overlay; B-09 extend. */
class PendingAuthorityTest {

    private val a = BridgeId("001788FFFE112233")
    private val b = BridgeId("AABBCCDDEEFF0011")
    private fun light(bridge: BridgeId, id: String, bri: Double) = LightState(
        ResourceKey(bridge, ResourceType.LIGHT, ResourceId(id)), "L", true, bri, CieXy(0.3, 0.3), null, false, null, null, emptyList(), null, LightCapabilities.unknown(),
    )
    private fun snap(bridge: BridgeId, bri: Double): BridgeSnapshot {
        val l = light(bridge, "x", bri)
        return BridgeSnapshot.empty(bridge).copy(lights = mapOf(l.key to l))
    }

    private val keyA = ResourceKey(a, ResourceType.LIGHT, ResourceId("x"))
    private val keyAGrouped = ResourceKey(a, ResourceType.GROUPED_LIGHT, ResourceId("x"))
    private val keyB = ResourceKey(b, ResourceType.LIGHT, ResourceId("x"))

    @Test
    fun sameRid_differentBridgeOrType_areIndependentClaims() {
        val auth = PendingAuthority()
        auth.claim(keyA, FieldGroup.DIMMING, MutationToken(1), 1_000, prior = snap(a, 10.0))
        assertTrue(auth.isPending(keyA, FieldGroup.DIMMING, 500))
        assertFalse("rid-only keying would wrongly fence bridge B", auth.isPending(keyB, FieldGroup.DIMMING, 500))
        assertFalse("rid-only keying would wrongly fence the grouped_light", auth.isPending(keyAGrouped, FieldGroup.DIMMING, 500))
        assertFalse("field-aware", auth.isPending(keyA, FieldGroup.COLOR, 500))
        assertEquals(1, auth.pendingCount())
    }

    @Test
    fun rollbackByToken_restoresTheOldestPriorOfAChain_andIgnoresStaleTokens() {
        val auth = PendingAuthority()
        val truth = snap(a, 10.0)
        auth.claim(keyA, FieldGroup.DIMMING, MutationToken(1), 1_000, prior = truth)
        auth.claim(keyA, FieldGroup.DIMMING, MutationToken(2), 1_200, prior = snap(a, 50.0))
        assertNull("token 1 no longer owns the slot", auth.takeForRollback(keyA, FieldGroup.DIMMING, MutationToken(1)))
        val claim = auth.takeForRollback(keyA, FieldGroup.DIMMING, MutationToken(2))!!
        val restored = auth.rollback(snap(a, 90.0), keyA, FieldGroup.DIMMING, claim)
        assertEquals(10.0, restored.lights.getValue(keyA).brightness!!, 0.0)
    }

    @Test
    fun overlayPending_reappliesUnexpiredClaimsOntoALoadedSnapshot_andDropsExpiredOnes() {
        val auth = PendingAuthority()
        auth.claim(keyA, FieldGroup.DIMMING, MutationToken(1), 2_000, prior = snap(a, 10.0))
        val loaded = snap(a, 10.0)   // the bridge still reports 10 (PUT in flight)
        val current = snap(a, 90.0)  // optimistic
        assertEquals(90.0, auth.overlayPending(loaded, current, 1_000).lights.getValue(keyA).brightness!!, 0.0)
        assertEquals("expired claim: the load wins", 10.0, auth.overlayPending(loaded, current, 2_001).lights.getValue(keyA).brightness!!, 0.0)
        assertEquals(0, auth.pendingCount())
    }

    @Test
    fun extend_pushesTheDeadlineOnlyForTheOwningToken_andNeverBackwards() {
        val auth = PendingAuthority()
        auth.claim(keyA, FieldGroup.POWER, MutationToken(1), 1_000, prior = snap(a, 10.0))
        auth.extend(keyA, FieldGroup.POWER, MutationToken(2), 5_000)
        assertFalse(auth.isPending(keyA, FieldGroup.POWER, 1_500))
        auth.claim(keyA, FieldGroup.POWER, MutationToken(3), 1_000, prior = snap(a, 10.0))
        auth.extend(keyA, FieldGroup.POWER, MutationToken(3), 500)
        assertTrue(auth.isPending(keyA, FieldGroup.POWER, 900))
        auth.extend(keyA, FieldGroup.POWER, MutationToken(3), 3_000)
        assertTrue(auth.isPending(keyA, FieldGroup.POWER, 2_900))
    }
}
