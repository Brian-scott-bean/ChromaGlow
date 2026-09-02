package com.chromaglow.app.core.session.safety

import com.chromaglow.app.core.identity.ResourceKey

/** Ticket for one admitted rise; settled at delivery. */
@JvmInline
value class RiseReservation(val value: Long)

/** The ledger's answer for a candidate write. A hold is not a refusal: latest-wins re-asks. */
sealed interface RiseVerdict {
    data class Emit(val reservation: RiseReservation?) : RiseVerdict
    data class Hold(val retryAtMillis: Long) : RiseVerdict
}

/**
 * How a reserved write ended. AMBIGUOUS_AFTER_TRANSMISSION (timeout/lost response after the body
 * was sent) MUST be treated as delivered: the reservation stays committed so an unsafe successor
 * rise can never be admitted on the strength of an unknown outcome.
 */
enum class DeliveryOutcome {
    DELIVERED,
    FAILED_BEFORE_TRANSMISSION,
    AMBIGUOUS_AFTER_TRANSMISSION,

    /**
     * The bridge authoritatively did NOT apply the write (429, HTTP 4xx, `errors[]` with no data).
     * Clock-conservative: the stamp stays; the wire memory is restored to what it was (E-05).
     */
    NOT_APPLIED,
}

/**
 * Per-bridge realized-onset ledger: the safety chokepoint inside MutationCoordinator. Reserve →
 * send → settle at delivery; only [DeliveryOutcome.FAILED_BEFORE_TRANSMISSION] rolls a
 * reservation back. Falls and same-level writes pass without a reservation.
 */
interface RiseLedger {
    fun admit(target: ResourceKey, next: LuminanceFrame, atMillis: Long): RiseVerdict

    fun settle(reservation: RiseReservation, outcome: DeliveryOutcome, atMillis: Long)
}
