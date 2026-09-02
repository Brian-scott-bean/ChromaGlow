package com.chromaglow.app.core.session.safety

import com.chromaglow.app.core.identity.ResourceKey

/** How a write reaches the lamps, which decides how the ledger updates their wire memory. */
enum class LedgerWriteKind {
    /** A per-light state write: the frame lands on exactly that lamp. */
    LAMP,

    /** A grouped_light write: the same frame lands on every member lamp. */
    GROUPED,

    /**
     * A scene recall: what each member shows afterwards is unknown to the app. ALWAYS a rise
     * candidate (judged as full white), and every member wire becomes unknown (E-01/E-02).
     */
    SCENE,

    /**
     * Initiation of a bridge-run animation (firmware or timed effect) on a lamp that is dark or
     * near-dark: judged as a worst-case full rise, and the wire becomes unknown afterwards (E-07).
     */
    INITIATION,
}

/**
 * One candidate write for the ledger: the PHYSICAL lamps it can change and the frame it would
 * put on them. Wires are kept per lamp, so a grouped, scene and per-light write to the same lamp
 * share one memory (E-02, the Android analogue of iOS's per-source `projectedField`).
 */
data class LedgerWrite(
    val lamps: Set<ResourceKey>,
    val frame: LuminanceFrame,
    val kind: LedgerWriteKind,
)

/** Handle for one admitted write, stamped or not; every admit gets one so every failure can restore the wire (E-12). */
@JvmInline
value class LedgerTicket(val value: Long)

sealed interface LedgerVerdict {
    /** Send it. [stamped] is true when this write took the bridge's onset clock. */
    data class Emit(val ticket: LedgerTicket, val stamped: Boolean) : LedgerVerdict

    data class Hold(val retryAtMillis: Long) : LedgerVerdict
}

/**
 * Additive over the frozen [RiseLedger]: lamp-set admission and settlement by ticket. The
 * coordinator uses only this surface; the frozen single-target methods remain for the contract.
 */
interface LampRiseLedger : RiseLedger {
    fun admit(write: LedgerWrite, atMillis: Long): LedgerVerdict

    fun settle(ticket: LedgerTicket, outcome: DeliveryOutcome, atMillis: Long)
}
