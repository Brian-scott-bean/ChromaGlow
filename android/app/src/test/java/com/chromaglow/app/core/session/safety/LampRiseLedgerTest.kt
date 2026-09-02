package com.chromaglow.app.core.session.safety

import com.chromaglow.app.core.hue.capability.CieXy
import com.chromaglow.app.core.identity.BridgeId
import com.chromaglow.app.core.identity.ResourceId
import com.chromaglow.app.core.identity.ResourceKey
import com.chromaglow.app.core.identity.ResourceType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** E-01, E-02, E-05, E-06, E-11, E-12 and D-03 on the lamp-set surface of the ledger. */
class LampRiseLedgerTest {

    private val bridge = BridgeId("001788FFFE112233")
    private val a = ResourceKey(bridge, ResourceType.LIGHT, ResourceId("a"))
    private val b = ResourceKey(bridge, ResourceType.LIGHT, ResourceId("b"))
    private val c = ResourceKey(bridge, ResourceType.LIGHT, ResourceId("c"))
    private val period = FlashSafetyConstants.MIN_ONSET_PERIOD_MILLIS

    private fun white(pct: Double) = DefaultFlashSafety.frameFor(pct, true, CieXy(0.3127, 0.3290))
    private fun red(pct: Double) = DefaultFlashSafety.frameFor(pct, true, CieXy(0.64, 0.33))
    private fun blue(pct: Double) = DefaultFlashSafety.frameFor(pct, true, CieXy(0.15, 0.06))
    private val off = DefaultFlashSafety.frameFor(0.0, false, null)
    private val full = LuminanceFrame(1.0, false)

    private fun lamp(k: ResourceKey, f: LuminanceFrame) = LedgerWrite(setOf(k), f, LedgerWriteKind.LAMP)
    private fun grouped(f: LuminanceFrame, vararg ks: ResourceKey) = LedgerWrite(ks.toSet(), f, LedgerWriteKind.GROUPED)
    private fun scene(vararg ks: ResourceKey) = LedgerWrite(ks.toSet(), full, LedgerWriteKind.SCENE)

    private fun emit(v: LedgerVerdict): LedgerVerdict.Emit { assertTrue("expected Emit, was $v", v is LedgerVerdict.Emit); return v as LedgerVerdict.Emit }
    private fun hold(v: LedgerVerdict): Long { assertTrue("expected Hold, was $v", v is LedgerVerdict.Hold); return (v as LedgerVerdict.Hold).retryAtMillis }
    private fun DefaultRiseLedger.deliver(w: LedgerWrite, at: Long): LedgerVerdict.Emit = emit(admit(w, at)).also { settle(it.ticket, DeliveryOutcome.DELIVERED, at) }

    // E-01 -------------------------------------------------------------------------------------

    @Test
    fun e01_everySceneRecall_isARiseCandidate_neverAnUnstampedRepeat() {
        val l = DefaultRiseLedger(bridge)
        assertTrue(l.deliver(scene(a, b), 1_000).stamped)
        assertEquals(1_000 + period, hold(l.admit(scene(a, b), 1_200)))
        assertTrue(l.deliver(scene(a, b), 1_000 + period).stamped)
        // Alternating A/B (different scene resources, same lamps) is exactly as constrained.
        hold(l.admit(scene(a, b), 1_000 + period + 100))
    }

    @Test
    fun e01_sceneRecallMarksMemberWiresUnknown_soTheNextLampRiseIsACandidate() {
        val l = DefaultRiseLedger(bridge)
        l.deliver(lamp(a, white(100.0)), 0)
        l.deliver(scene(a, b), period)
        // A member at "full" per the scene? Unknown. A per-light 100 % write is judged cold: absolute rise.
        assertEquals(2 * period, hold(l.admit(lamp(a, white(100.0)), period + 100)))
    }

    // E-02 -------------------------------------------------------------------------------------

    @Test
    fun e02_groupedFallIsVisibleToThePerLightRise_onTheSameLamp() {
        val l = DefaultRiseLedger(bridge)
        l.deliver(lamp(a, white(100.0)), 0)                      // stamped rise on lamp a
        l.deliver(grouped(white(1.0), a, b), 100)                 // room fall lands on a AND b
        // The per-light rise to 100 on lamp a is a real rise from the room's fall: held to the period.
        assertEquals(period, hold(l.admit(lamp(a, white(100.0)), 200)))
        assertTrue(l.deliver(lamp(a, white(100.0)), period).stamped)
    }

    @Test
    fun e02_groupedRiseUpdatesEveryMemberWire() {
        val l = DefaultRiseLedger(bridge)
        l.deliver(grouped(white(1.0), a, b, c), 0)
        assertTrue(l.deliver(grouped(white(100.0), a, b, c), period).stamped)
        // Each member now remembers 100 %: a per-light 100 on any member is not a rise.
        assertFalse(emit(l.admit(lamp(b, white(100.0)), period + 10)).stamped)
    }

    @Test
    fun e02_aCandidateOnAnyAffectedLamp_makesTheGroupedWriteACandidate() {
        val l = DefaultRiseLedger(bridge)
        l.deliver(lamp(a, white(100.0)), 0)
        l.deliver(lamp(b, white(1.0)), 50)
        // Grouped to 100: no rise for a, a rise for b → candidate → held.
        assertEquals(period, hold(l.admit(grouped(white(100.0), a, b), 100)))
    }

    // E-05 / D-03 ------------------------------------------------------------------------------

    @Test
    fun e05_notApplied_keepsTheStamp_butRestoresTheWire_soTheRealRiseIsHeld() {
        val l = DefaultRiseLedger(bridge)
        l.deliver(lamp(a, white(1.0)), 0)
        val rise = emit(l.admit(lamp(a, white(100.0)), period))
        assertTrue(rise.stamped)
        l.settle(rise.ticket, DeliveryOutcome.NOT_APPLIED, period + 20)      // 429: the lamp stayed at 1 %
        // 100 ms later the same rise is still a rise (wire restored) and the stamp still stands → held.
        assertEquals(2 * period, hold(l.admit(lamp(a, white(100.0)), period + 100)))
        assertTrue(l.deliver(lamp(a, white(100.0)), 2 * period).stamped)
    }

    @Test
    fun d03_sequence_429Rise_okRise_off_rise_isHeldFromTheFirstAdmit() {
        val l = DefaultRiseLedger(bridge)
        l.deliver(lamp(a, white(1.0)), 0)
        val first = emit(l.admit(lamp(a, white(100.0)), 1_000))
        l.settle(first.ticket, DeliveryOutcome.NOT_APPLIED, 1_010)
        hold(l.admit(lamp(a, white(100.0)), 1_100))                               // still inside the period
        assertTrue(l.deliver(lamp(a, white(100.0)), 1_000 + period).stamped)       // realized at +340
        assertFalse(emit(l.admit(lamp(a, off, ), 1_000 + period + 100)).stamped)   // fall
        assertEquals(1_000 + 2 * period, hold(l.admit(lamp(a, white(100.0)), 1_000 + period + 200)))
    }

    @Test
    fun e05_ambiguous_keepsTheStamp_andMarksTheWireUnknown_soTheSameRiseIsACandidateAgain() {
        val l = DefaultRiseLedger(bridge)
        l.deliver(lamp(a, white(1.0)), 0)
        val rise = emit(l.admit(lamp(a, white(100.0)), period))
        l.settle(rise.ticket, DeliveryOutcome.AMBIGUOUS_AFTER_TRANSMISSION, period + 30)
        assertFalse(l.isRiseInFlight)
        // Unknown wire → the repeat is judged cold (absolute) → candidate → held to a full period.
        hold(l.admit(lamp(a, white(100.0)), period + 100))
        assertTrue(emit(l.admit(lamp(a, white(100.0)), period + 30 + period)).stamped)
    }

    // E-06 -------------------------------------------------------------------------------------

    @Test
    fun e06_aRedRuleOnlyAdmission_doesNotLiftTheTrough() {
        val l = DefaultRiseLedger(bridge)
        // Known dim white wire, then long silence (wire forgotten, trough 0.0 remains from the fall).
        l.deliver(lamp(a, white(60.0)), 0)
        l.deliver(lamp(a, off), 100)
        val t = 100 + 10 * period
        // Cold, dim red (~0.05): not an absolute rise; red rule vs the last known (off, red?) no. Make the
        // known frame red first so the red rule can fire below the threshold.
        val l2 = DefaultRiseLedger(bridge)
        l2.deliver(lamp(a, red(60.0)), 0)
        l2.deliver(lamp(a, off), 100)
        val dimRed = red(40.0) // ≈ 0.02 luminance; red→red under the cold red rule against known red(60)
        val v = emit(l2.admit(lamp(a, dimRed), t))
        // Whether or not it stamped, the trough must NOT have been re-based above the floor a viewer saw.
        val climb = white(45.0) // ≈ 0.14 absolute: a rise the eye sees from black
        if (v.stamped) l2.settle(v.ticket, DeliveryOutcome.DELIVERED, t)
        val verdict = l2.admit(lamp(a, climb), t + period)
        assertTrue("a 0.14 climb after a red-only step must still be a candidate (it emits stamped, or holds)",
            (verdict is LedgerVerdict.Emit && verdict.stamped) || verdict is LedgerVerdict.Hold)
        assertTrue(t >= 0 && l.lastOnsetMillis != null)
    }

    // E-11 -------------------------------------------------------------------------------------

    @Test
    fun e11_holdWhileARiseIsInFlight_retriesAfterAPace_notEveryMillisecond() {
        val l = DefaultRiseLedger(bridge)
        emit(l.admit(lamp(a, white(100.0)), 5_000)) // in flight, unsettled
        val retry = hold(l.admit(lamp(b, white(100.0)), 5_050))
        assertEquals(5_050 + DefaultRiseLedger.IN_FLIGHT_RETRY_MILLIS, retry)
    }

    // E-12 -------------------------------------------------------------------------------------

    @Test
    fun e12_aFailedNonReservedWrite_restoresThePriorWire_soALaterRedStepIsNotHidden() {
        val l = DefaultRiseLedger(bridge)
        l.deliver(lamp(a, red(60.0)), 0)                  // wire: saturated red
        // red → white at the same level: luminance RISE actually; use red → dim non-red fall instead.
        val fall = emit(l.admit(lamp(a, blue(60.0)), period))  // red→blue: fall + red rule → candidate → stamped
        assertTrue(fall.stamped)
        l.settle(fall.ticket, DeliveryOutcome.DELIVERED, period)
        // Now a non-red fall that fails before transmission: the wire must go back to blue, not remember "off".
        val failed = emit(l.admit(lamp(a, off), period + 100))
        assertFalse(failed.stamped)
        l.settle(failed.ticket, DeliveryOutcome.FAILED_BEFORE_TRANSMISSION, period + 110)
        // blue → red at equal dimming is the WCAG red step (candidate). Had the wire believed "off",
        // red(60) would still be a candidate by the absolute rule, so probe with a dim red that is only
        // a candidate via the red rule against BLUE: |Δ| ≥ 0.02 and one side red.
        val dimRed = red(55.0)
        assertTrue(DefaultFlashSafety.isOnset(blue(60.0), blue(60.0).relativeLuminance, dimRed))
        assertEquals(2 * period, hold(l.admit(lamp(a, dimRed), period + 200)))
    }

    @Test
    fun unstampedTicket_viaTheFrozenApi_isNotRetained() {
        val l = DefaultRiseLedger(bridge)
        l.admit(a, white(100.0), 0).let { (it as RiseVerdict.Emit).reservation!! }.also { l.settle(it, DeliveryOutcome.DELIVERED, 0) }
        val v = l.admit(a, white(20.0), 50) as RiseVerdict.Emit
        assertEquals(null, v.reservation)
        l.settle(RiseReservation(2), DeliveryOutcome.FAILED_BEFORE_TRANSMISSION, 60) // no-op, no throw
        assertEquals(0L, l.lastOnsetMillis)
    }
}
