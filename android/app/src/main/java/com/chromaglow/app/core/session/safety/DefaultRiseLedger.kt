package com.chromaglow.app.core.session.safety

import com.chromaglow.app.core.identity.BridgeId
import com.chromaglow.app.core.identity.ResourceKey
import kotlin.math.min

/**
 * Per-bridge realized-onset ledger, the safety chokepoint inside the MutationCoordinator. Ports
 * the iOS `OnsetGate` semantics that apply to paced REST writes:
 *
 *  - ONE onset clock per bridge; wire memory per PHYSICAL LAMP (last emitted frame, luminance
 *    trough since the last admitted onset, last known frame). A grouped write updates every
 *    member wire; a scene recall or an animation initiation makes the member wires unknown.
 *  - A write is a candidate when ANY affected wire says so (warm: the ≥ 0.10 trough rise or the
 *    red rule; cold: absolute luminance ≥ 0.10 or the red rule against the last known frame);
 *    SCENE and INITIATION writes are always candidates.
 *  - A candidate is admitted only when no rise is in flight and the last realized onset is at
 *    least [periodMillis] ago; otherwise [LedgerVerdict.Hold] with the retry time (blocked by an
 *    in-flight rise → retry after a short pace, not a 1 ms spin — E-11).
 *  - Only an admitted rise a viewer also saw (cold start or a trough rise) re-bases the trough
 *    upward; a red-rule-only admission does not (E-06, iOS `coldStart || troughRise`).
 *  - Every admit returns a ticket. Settlement: DELIVERED moves the stamp to the delivery time and
 *    records the frame as known; AMBIGUOUS keeps the stamp and makes the wire unknown;
 *    NOT_APPLIED keeps the stamp and restores the prior wire; FAILED_BEFORE_TRANSMISSION restores
 *    the stamp and the wire (E-05, E-12).
 *  - The clock reference never moves backwards; a wire silent for a whole period is forgotten.
 */
class DefaultRiseLedger(
    val bridgeId: BridgeId,
    private val safety: FlashSafety = DefaultFlashSafety,
    private val periodMillis: Long = FlashSafetyConstants.MIN_ONSET_PERIOD_MILLIS,
    private val inFlightRetryMillis: Long = IN_FLIGHT_RETRY_MILLIS,
) : LampRiseLedger {

    private class Wire {
        var lastEmitted: LuminanceFrame? = null
        var lastKnown: LuminanceFrame? = null
        var trough: Double = 0.0

        fun snapshot() = WirePrior(lastEmitted, lastKnown, trough)
        fun restore(p: WirePrior) { lastEmitted = p.emitted; lastKnown = p.known; trough = p.trough }
        fun unknown() { lastEmitted = null; trough = min(trough, 0.0) }
    }

    private class WirePrior(val emitted: LuminanceFrame?, val known: LuminanceFrame?, val trough: Double)

    private class Pending(
        val write: LedgerWrite,
        val priors: Map<ResourceKey, WirePrior>,
        val stampedAt: Long?,
        val priorOnset: Long?,
    )

    private val wires = HashMap<ResourceKey, Wire>()
    private val pending = HashMap<Long, Pending>()
    private var sequence = 0L

    /** The last realized onset on this bridge (null before the first). */
    var lastOnsetMillis: Long? = null
        private set

    /** A stamped rise whose delivery has not been settled; nobody takes an onset meanwhile. */
    private var unrealized: Long? = null
    private var lastDeliveredAt: Long? = null

    val isRiseInFlight: Boolean get() = unrealized != null

    // ── frozen single-target contract, delegating to the lamp-set path ──

    @Synchronized
    override fun admit(target: ResourceKey, next: LuminanceFrame, atMillis: Long): RiseVerdict =
        when (val v = admit(LedgerWrite(setOf(target), next, LedgerWriteKind.LAMP), atMillis)) {
            is LedgerVerdict.Hold -> RiseVerdict.Hold(v.retryAtMillis)
            is LedgerVerdict.Emit -> {
                // The frozen contract hands out a reservation only for a stamped rise; an unstamped
                // ticket cannot be settled through it, so drop its record.
                if (!v.stamped) pending.remove(v.ticket.value)
                RiseVerdict.Emit(if (v.stamped) RiseReservation(v.ticket.value) else null)
            }
        }

    @Synchronized
    override fun settle(reservation: RiseReservation, outcome: DeliveryOutcome, atMillis: Long) =
        settle(LedgerTicket(reservation.value), outcome, atMillis)

    // ── lamp-set admission ──

    @Synchronized
    override fun admit(write: LedgerWrite, atMillis: Long): LedgerVerdict {
        forgetIfSilent(atMillis)
        val lamps = write.lamps.map { wires.getOrPut(it) { Wire() } }
        val tol = 1e-9
        val threshold = FlashSafetyConstants.ONSET_RISE_THRESHOLD - tol
        val lum = write.frame.relativeLuminance

        val forced = write.kind == LedgerWriteKind.SCENE || write.kind == LedgerWriteKind.INITIATION
        val candidate = forced || lamps.any { w -> isCandidate(w, write.frame) }

        val priors = write.lamps.associateWith { wires.getValue(it).snapshot() }

        if (!candidate) {
            // An unstamped frame re-bases the trough only on a TRUE cold start (no history at all).
            for (w in lamps) record(w, write.frame, resetTrough = w.lastEmitted == null && w.lastKnown == null)
            return LedgerVerdict.Emit(ticket(write, priors, stampedAt = null, priorOnset = lastOnsetMillis), stamped = false)
        }

        val last = lastOnsetMillis
        if (unrealized != null) return LedgerVerdict.Hold(atMillis + inFlightRetryMillis)
        if (last != null && (atMillis < last || atMillis - last < periodMillis)) {
            return LedgerVerdict.Hold(maxOf(last + periodMillis, atMillis + 1))
        }

        val ticket = ticket(write, priors, stampedAt = atMillis, priorOnset = last)
        lastOnsetMillis = atMillis
        unrealized = ticket.value
        for (w in lamps) {
            when (write.kind) {
                LedgerWriteKind.SCENE, LedgerWriteKind.INITIATION -> w.unknown()
                LedgerWriteKind.LAMP, LedgerWriteKind.GROUPED -> {
                    val coldStart = w.lastEmitted == null && w.lastKnown == null
                    val troughRise = lum - w.trough >= threshold
                    record(w, write.frame, resetTrough = coldStart || troughRise)
                }
            }
        }
        return LedgerVerdict.Emit(ticket, stamped = true)
    }

    private fun isCandidate(w: Wire, next: LuminanceFrame): Boolean {
        val previous = w.lastEmitted
        if (previous != null) return safety.isOnset(previous, w.trough, next)
        // Cold: absolute rule; plus the red rule against the last KNOWN frame if there is one.
        if (safety.isOnset(null, w.trough, next)) return true
        val known = w.lastKnown ?: return false
        return safety.isOnset(known, Double.MAX_VALUE, next)
    }

    private fun ticket(write: LedgerWrite, priors: Map<ResourceKey, WirePrior>, stampedAt: Long?, priorOnset: Long?): LedgerTicket {
        val id = ++sequence
        pending[id] = Pending(write, priors, stampedAt, priorOnset)
        return LedgerTicket(id)
    }

    @Synchronized
    override fun settle(ticket: LedgerTicket, outcome: DeliveryOutcome, atMillis: Long) {
        val p = pending.remove(ticket.value) ?: return
        if (unrealized == ticket.value) unrealized = null
        val lamps = p.write.lamps.map { wires.getOrPut(it) { Wire() } }
        when (outcome) {
            DeliveryOutcome.DELIVERED -> {
                lastDeliveredAt = maxOf(lastDeliveredAt ?: atMillis, atMillis)
                for (w in lamps) {
                    if (p.write.kind == LedgerWriteKind.SCENE || p.write.kind == LedgerWriteKind.INITIATION) {
                        w.lastKnown = null // the bridge owns what the lamp shows now
                    } else {
                        w.lastKnown = p.write.frame
                    }
                }
                // Delivery moves the stamp forward to the moment the lamps actually rose.
                if (p.stampedAt != null && lastOnsetMillis == p.stampedAt && atMillis > p.stampedAt) lastOnsetMillis = atMillis
            }
            DeliveryOutcome.AMBIGUOUS_AFTER_TRANSMISSION -> {
                // Clock: the rise happened at an unknown time up to now, so the LATER reference is the
                // conservative one — move the stamp forward like a delivery. Wire: unknown — the next
                // rise on any affected lamp is a candidate.
                lastDeliveredAt = maxOf(lastDeliveredAt ?: atMillis, atMillis)
                if (p.stampedAt != null && lastOnsetMillis == p.stampedAt && atMillis > p.stampedAt) lastOnsetMillis = atMillis
                for ((key, w) in p.write.lamps.zip(lamps)) {
                    val prior = p.priors.getValue(key)
                    w.lastEmitted = null
                    w.trough = min(prior.trough, p.write.frame.relativeLuminance)
                    w.lastKnown = prior.known
                }
            }
            DeliveryOutcome.NOT_APPLIED -> {
                // Clock: keep the stamp (conservative). Wire: exactly what it was.
                for ((key, w) in p.write.lamps.zip(lamps)) w.restore(p.priors.getValue(key))
            }
            DeliveryOutcome.FAILED_BEFORE_TRANSMISSION -> {
                if (p.stampedAt != null && lastOnsetMillis == p.stampedAt) lastOnsetMillis = p.priorOnset
                for ((key, w) in p.write.lamps.zip(lamps)) w.restore(p.priors.getValue(key))
            }
        }
    }

    private fun forgetIfSilent(atMillis: Long) {
        val delivered = lastDeliveredAt ?: return
        if (atMillis - delivered >= periodMillis) wires.values.forEach { it.lastEmitted = null }
    }

    private fun record(wire: Wire, frame: LuminanceFrame, resetTrough: Boolean) {
        wire.lastEmitted = frame
        wire.trough = if (resetTrough) frame.relativeLuminance else min(wire.trough, frame.relativeLuminance)
    }

    companion object {
        /** Retry pace while a rise is in flight; the coordinator also wakes on settle. */
        const val IN_FLIGHT_RETRY_MILLIS: Long = 100L
    }
}
