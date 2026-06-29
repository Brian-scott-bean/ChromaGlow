package com.chromaglow.app.core.hue.pairing.workflow

import com.chromaglow.app.core.bridge.PairedBridgeRecord

/**
 * A UI-safe, non-secret reason a pairing attempt or local persistence step failed terminally.
 *
 * Deliberately a closed set of opaque categories: it carries NO raw exception text, response body,
 * bridge id, token, certificate detail, or filesystem path, so presentation can map each to static
 * user-facing copy without leaking anything.
 */
enum class PairingErrorReason {
    /** The bridge rejected the create-user request (Hue error type 7). */
    INVALID_REQUEST,

    /** The bridge's authenticated identity did not satisfy the pinned-identity contract. */
    IDENTITY_MISMATCH,

    /** The bridge could not be reached or its TLS identity/CA could not be trusted. */
    UNTRUSTED_OR_UNREACHABLE,

    /** The bridge returned an error the protocol layer does not specifically handle. */
    BRIDGE_ERROR,

    /** The bridge's response could not be interpreted (malformed, oversized, or unexpected status). */
    BRIDGE_RESPONSE_INVALID,

    /** Local token/metadata persistence failed; any partial local state was rolled back. */
    LOCAL_PERSISTENCE,
}

/**
 * Outcome of a single [LivePairingWorkflow.pair] attempt, safe to expose to presentation.
 *
 * No variant carries the application key/username — only the non-secret [PairedBridgeRecord] on
 * success. [LinkButtonRequired] is the sole retryable outcome.
 */
sealed interface PairingOutcome {

    /** Pairing succeeded and the bridge is fully persisted locally (token + metadata committed). */
    data class Paired(val bridge: PairedBridgeRecord) : PairingOutcome

    /** Hue type 101: the user must press the physical link button, then retry. Nothing persisted. */
    data object LinkButtonRequired : PairingOutcome

    /** Terminal failure with a UI-safe [reason]. Nothing remains persisted. */
    data class Failed(val reason: PairingErrorReason) : PairingOutcome
}

/**
 * The paired state reconstructed at startup. A session is [Paired] only when the metadata record
 * AND a readable token both exist; anything else is a repair/recovery/unpaired state.
 */
sealed interface RestoredState {

    /** No persisted bridge. */
    data object Unpaired : RestoredState

    /** A record exists and its token is readable: a valid restored session. */
    data class Paired(val bridge: PairedBridgeRecord) : RestoredState

    /**
     * A record exists but its token is missing or unreadable. The bridge cannot be used until the
     * user re-pairs or forgets it (a repair/forget state, never a live session).
     */
    data class NeedsRepair(val bridge: PairedBridgeRecord) : RestoredState

    /** Stored metadata was corrupt or could not be read: surface a recovery/forget affordance. */
    data object Unavailable : RestoredState
}

/** Outcome of a local-only [LivePairingWorkflow.forget]. */
sealed interface ForgetResult {

    /** The local token and metadata are gone (or were already gone): idempotent success. */
    data object Forgotten : ForgetResult

    /** A local cleanup step failed; the operation is safe to retry. */
    data object CleanupFailed : ForgetResult
}
