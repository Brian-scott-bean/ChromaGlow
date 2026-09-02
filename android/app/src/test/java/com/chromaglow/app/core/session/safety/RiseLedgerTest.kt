package com.chromaglow.app.core.session.safety

import com.chromaglow.app.core.hue.capability.CieXy
import com.chromaglow.app.core.identity.BridgeId
import com.chromaglow.app.core.identity.ResourceId
import com.chromaglow.app.core.identity.ResourceKey
import com.chromaglow.app.core.identity.ResourceType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RiseLedgerTest {

    private val bridge = BridgeId("001788FFFE112233")
    private val a = ResourceKey(bridge, ResourceType.LIGHT, ResourceId("a"))
    private val b = ResourceKey(bridge, ResourceType.LIGHT, ResourceId("b"))
    private val period = FlashSafetyConstants.MIN_ONSET_PERIOD_MILLIS

    private fun white(pct: Double) = DefaultFlashSafety.frameFor(pct, true, CieXy(0.3127, 0.3290))
    private fun pale(pct: Double) = DefaultFlashSafety.frameFor(pct, true, CieXy(0.3, 0.3))
    private fun red(pct: Double) = DefaultFlashSafety.frameFor(pct, true, CieXy(0.64, 0.33))
    private fun blue(pct: Double) = DefaultFlashSafety.frameFor(pct, true, CieXy(0.15, 0.06))
    private val off = DefaultFlashSafety.frameFor(0.0, false, null)

    private fun emit(v: RiseVerdict): RiseReservation? {
        assertTrue("expected Emit, was $v", v is RiseVerdict.Emit)
        return (v as RiseVerdict.Emit).reservation
    }

    private fun hold(v: RiseVerdict): Long {
        assertTrue("expected Hold, was $v", v is RiseVerdict.Hold)
        return (v as RiseVerdict.Hold).retryAtMillis
    }

    @Test
    fun firstFrameOfABridgesLife_emits_andIsStampedOnlyIfItIsARiseOutOfBlack() {
        val ledger = DefaultRiseLedger(bridge)
        assertNotNull(emit(ledger.admit(a, white(90.0), 100_000)))
        assertEquals(100_000L, ledger.lastOnsetMillis)

        val dim = DefaultRiseLedger(bridge)
        assertNull("the storm's 0.05 ambient is 0.001 of maximum luminance: not a rise out of black", emit(dim.admit(a, DefaultFlashSafety.frameFor(5.0, true, CieXy(0.1548, 0.1220)), 100_000)))
        assertNull(dim.lastOnsetMillis)
        assertNotNull("the first strike of a session is never delayed", emit(dim.admit(a, white(90.0), 100_020)))
    }

    @Test
    fun fallsAndSubThresholdRises_passWithoutAReservation_andTheTroughIsTheFloor() {
        val ledger = DefaultRiseLedger(bridge)
        val r0 = emit(ledger.admit(a, pale(100.0), 0))!!
        ledger.settle(r0, DeliveryOutcome.DELIVERED, 5)
        assertNull(emit(ledger.admit(a, pale(20.0), 20)))
        // 0.20 → 0.35 is a 0.15 dimming step but only 0.044 of maximum luminance.
        assertNull(emit(ledger.admit(a, pale(35.0), 40)))
        // 0.47 is 0.060 above the frame before it but 0.103 above the TROUGH: a candidate, held.
        hold(ledger.admit(a, pale(47.0), 60))
    }

    @Test
    fun secondRiseInsideThePeriod_isHeld_untilExactlyThePeriod() {
        val ledger = DefaultRiseLedger(bridge)
        val r = emit(ledger.admit(a, white(100.0), 10_000))!!
        ledger.settle(r, DeliveryOutcome.DELIVERED, 10_000)
        assertNull(emit(ledger.admit(a, off, 10_020)))
        assertEquals(10_000 + period, hold(ledger.admit(a, white(100.0), 10_020)))
        assertEquals(10_000 + period, hold(ledger.admit(a, white(100.0), 10_000 + period - 1)))
        assertNotNull(emit(ledger.admit(a, white(100.0), 10_000 + period)))
    }

    @Test
    fun aRiseInFlight_blocksEveryOtherTarget_untilItSettles_andDeliveryMovesTheStampForward() {
        val ledger = DefaultRiseLedger(bridge)
        val r = emit(ledger.admit(a, white(100.0), 1_000))!!
        assertTrue(ledger.isRiseInFlight)
        hold(ledger.admit(b, white(100.0), 1_000 + period))
        ledger.settle(r, DeliveryOutcome.DELIVERED, 1_050)
        assertFalse(ledger.isRiseInFlight)
        assertEquals(1_050L, ledger.lastOnsetMillis)
        hold(ledger.admit(b, white(100.0), 1_050 + period - 1))
        assertNotNull(emit(ledger.admit(b, white(100.0), 1_050 + period)))
    }

    @Test
    fun ambiguousAfterTransmission_commitsTheReservation_likeADelivery() {
        val ledger = DefaultRiseLedger(bridge)
        val r = emit(ledger.admit(a, white(100.0), 1_000))!!
        ledger.settle(r, DeliveryOutcome.AMBIGUOUS_AFTER_TRANSMISSION, 1_030)
        assertFalse(ledger.isRiseInFlight)
        assertEquals("the stamp stays (and moves to the ambiguous delivery time)", 1_030L, ledger.lastOnsetMillis)
        hold(ledger.admit(b, white(100.0), 1_100))
        assertNotNull(emit(ledger.admit(b, white(100.0), 1_030 + period)))
    }

    @Test
    fun failedBeforeTransmission_rollsBackTheStampAndTheWire() {
        val ledger = DefaultRiseLedger(bridge)
        val first = emit(ledger.admit(a, white(100.0), 1_000))!!
        ledger.settle(first, DeliveryOutcome.DELIVERED, 1_000)
        assertNull(emit(ledger.admit(a, off, 1_020)))
        val second = emit(ledger.admit(a, white(100.0), 1_000 + period))!!
        ledger.settle(second, DeliveryOutcome.FAILED_BEFORE_TRANSMISSION, 1_000 + period + 10)
        assertFalse(ledger.isRiseInFlight)
        assertEquals("the clock belongs to the prior onset again", 1_000L, ledger.lastOnsetMillis)
        // The wire is back at "off", so the same rise is admissible right away (period long past).
        assertNotNull(emit(ledger.admit(a, white(100.0), 1_000 + period + 20)))
    }

    @Test
    fun aTimeThatMovesBackwards_isRefused_andDoesNotMoveTheReference() {
        val ledger = DefaultRiseLedger(bridge)
        val r = emit(ledger.admit(a, white(100.0), 5_000))!!
        ledger.settle(r, DeliveryOutcome.DELIVERED, 5_000)
        assertNull(emit(ledger.admit(a, off, 5_020)))
        hold(ledger.admit(a, white(100.0), 4_900))
        assertEquals(5_000L, ledger.lastOnsetMillis)
        assertNotNull(emit(ledger.admit(a, white(100.0), 5_000 + period)))
    }

    @Test
    fun redFlashRule_aChromaStepToOrFromSaturatedRed_isACandidateBelowTheGeneralThreshold() {
        val ledger = DefaultRiseLedger(bridge)
        val r = emit(ledger.admit(a, red(90.0), 1_000))!!
        ledger.settle(r, DeliveryOutcome.DELIVERED, 1_000)
        // red → blue at constant dimming is a luminance FALL (0.21 → 0.07) — the general rule
        // does not see it, WCAG's red flash does.
        hold(ledger.admit(a, blue(90.0), 1_020))
        assertNotNull(emit(ledger.admit(a, blue(90.0), 1_000 + period)))
    }

    @Test
    fun aSilentWire_isForgotten_andTheColdRuleJudgesAbsoluteLuminance() {
        val ledger = DefaultRiseLedger(bridge)
        val r = emit(ledger.admit(a, white(100.0), 1_000))!!
        ledger.settle(r, DeliveryOutcome.DELIVERED, 1_000)
        // Long silence: whatever the bridge shows now is unknown.
        val t = 1_000 + 10 * period
        // A dim frame is not a rise out of black → passes unstamped.
        assertNull(emit(ledger.admit(a, DefaultFlashSafety.frameFor(5.0, true, CieXy(0.1548, 0.1220)), t)))
        // A bright frame is judged against black (absolute rule) → stamped rise.
        assertNotNull(emit(ledger.admit(b, white(100.0), t + 20)))
    }

    @Test
    fun settlingAnUnknownReservation_isANoOp() {
        val ledger = DefaultRiseLedger(bridge)
        ledger.settle(RiseReservation(999), DeliveryOutcome.DELIVERED, 1)
        assertNull(ledger.lastOnsetMillis)
    }
}
