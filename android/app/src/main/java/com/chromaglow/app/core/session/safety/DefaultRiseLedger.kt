package com.chromaglow.app.core.session.safety

import com.chromaglow.app.core.identity.BridgeId
import kotlin.math.min

/**
 * Per-bridge realized-onset ledger, the safety chokepoint inside the MutationCoordinator. Ports
 * the iOS `OnsetGate` semantics that apply to paced REST writes:
 *
 *  - ONE onset clock per bridge; per-target wire memory (last emitted frame + luminance trough
 *    since the last admitted onset).
 *  - A candidate rise is admitted only when no rise is in flight and the last realized onset is
 *    at least [FlashSafetyConstants.MIN_ONSET_PERIOD_MILLIS] ago; otherwise [RiseVerdict.Hold]
 *    with the earliest retry time. Falls and sub-threshold rises pass with no reservation.
 *  - Reserve → send → settle. DELIVERED moves the stamp forward to the delivery time.
 *    AMBIGUOUS_AFTER_TRANSMISSION commits the reservation (treated as delivered).
 *    Only FAILED_BEFORE_TRANSMISSION rolls the stamp and the target's wire memory back.
 *  - The clock reference never moves backwards; a non-finite or earlier time is refused.
 *  - A wire silent for a whole period is forgotten: the next frame is judged by the cold rule
 *    against absolute luminance, and the trough keeps running (never re-based upward by an
 *    unstamped frame).
 */
class DefaultRiseLedger(
    val bridgeId: BridgeId,
    private val safety: FlashSafety = DefaultFlashSafety,
    private val periodMillis: Long = FlashSafetyConstants.MIN_ONSET_PERIOD_MILLIS,
) : RiseLedger {

    private class Wire {
        var lastEmitted: LuminanceFrame? = null
        var lastKnown: LuminanceFrame? = null
        var trough: Double = 0.0
    }

    private class Pending(
        val target: com.chromaglow.app.core.identity.ResourceKey,
        val frame: LuminanceFrame,
        val stampedAt: Long,
        val priorOnset: Long?,
        val priorEmitted: LuminanceFrame?,
        val priorTrough: Double,
    )

    private val wires = HashMap<com.chromaglow.app.core.identity.ResourceKey, Wire>()
    private val pending = HashMap<Long, Pending>()
    private var sequence = 0L

    /** The last realized onset on this bridge (null before the first). */
    var lastOnsetMillis: Long? = null
        private set

    /** A stamped rise whose delivery has not been settled; nobody takes an onset meanwhile. */
    private var unrealized: Long? = null

    private var lastDeliveredAt: Long? = null

    val isRiseInFlight: Boolean get() = unrealized != null

    @Synchronized
    override fun admit(target: com.chromaglow.app.core.identity.ResourceKey, next: LuminanceFrame, atMillis: Long): RiseVerdict {
        val wire = wires.getOrPut(target) { Wire() }
        // A silent wire is an unknown wire: forget every target's last frame, keep the troughs.
        lastDeliveredAt?.let { delivered ->
            if (atMillis - delivered >= periodMillis && wires.values.any { it.lastEmitted != null }) {
                wires.values.forEach { it.lastEmitted = null }
            }
        }
        val previous = wire.lastEmitted
        val coldStart = previous == null && wire.lastKnown == null
        val candidate = if (previous == null) {
            // Cold: absolute rule, plus the red rule against the last KNOWN frame if there is one.
            safety.isOnset(null, wire.trough, next) ||
                (wire.lastKnown?.let { known -> safety.isOnset(known, Double.MAX_VALUE, next) } ?: false)
        } else {
            safety.isOnset(previous, wire.trough, next)
        }
        if (!candidate) {
            record(wire, next, resetTrough = coldStart)
            return RiseVerdict.Emit(null)
        }
        val last = lastOnsetMillis
        val blocked = unrealized != null || (last != null && (atMillis < last || atMillis - last < periodMillis))
        if (blocked) {
            val retryAt = (last ?: atMillis) + periodMillis
            return RiseVerdict.Hold(retryAtMillis = maxOf(retryAt, atMillis + 1))
        }
        val reservation = ++sequence
        pending[reservation] = Pending(
            target = target, frame = next, stampedAt = atMillis, priorOnset = last,
            priorEmitted = wire.lastEmitted, priorTrough = wire.trough,
        )
        lastOnsetMillis = atMillis
        unrealized = reservation
        // Only an admitted onset re-bases the trough upward.
        record(wire, next, resetTrough = true)
        return RiseVerdict.Emit(RiseReservation(reservation))
    }

    @Synchronized
    override fun settle(reservation: RiseReservation, outcome: DeliveryOutcome, atMillis: Long) {
        val p = pending.remove(reservation.value) ?: return
        val wire = wires.getOrPut(p.target) { Wire() }
        when (outcome) {
            DeliveryOutcome.DELIVERED, DeliveryOutcome.AMBIGUOUS_AFTER_TRANSMISSION -> {
                if (unrealized == reservation.value) unrealized = null
                lastDeliveredAt = maxOf(lastDeliveredAt ?: atMillis, atMillis)
                wire.lastKnown = p.frame
                // Delivery moves the stamp forward to the moment the lamps actually rose.
                if (lastOnsetMillis == p.stampedAt && atMillis > p.stampedAt) lastOnsetMillis = atMillis
            }
            DeliveryOutcome.FAILED_BEFORE_TRANSMISSION -> {
                if (unrealized == reservation.value) unrealized = null
                if (lastOnsetMillis == p.stampedAt) lastOnsetMillis = p.priorOnset
                wire.lastEmitted = p.priorEmitted
                wire.trough = p.priorTrough
            }
        }
    }

    /** Non-rising writes still count as deliveries for the silence clock and the known frame. */
    @Synchronized
    fun noteDelivered(target: com.chromaglow.app.core.identity.ResourceKey, frame: LuminanceFrame, atMillis: Long) {
        lastDeliveredAt = maxOf(lastDeliveredAt ?: atMillis, atMillis)
        wires.getOrPut(target) { Wire() }.lastKnown = frame
    }

    private fun record(wire: Wire, frame: LuminanceFrame, resetTrough: Boolean) {
        wire.lastEmitted = frame
        wire.trough = if (resetTrough) frame.relativeLuminance else min(wire.trough, frame.relativeLuminance)
    }
}
