package com.chromaglow.app.core.session

/** Why a session is in [ConnectionState.Error]. Static, UI-safe categories only. */
enum class SessionErrorReason {
    UNREACHABLE,
    TLS_IDENTITY,
    BRIDGE_REJECTED,
    LOCAL_STORAGE,
}

/**
 * Per-bridge connection truth as the UI consumes it. Deterministic and secret-free.
 *
 * - [Stale] keeps the last snapshot fully interactive.
 * - [Offline] keeps the snapshot visible with controls disabled.
 * - [Revoked] is entered ONLY on an explicit 401/403; the record is kept and re-pair is offered.
 */
sealed interface ConnectionState {
    data object Connecting : ConnectionState
    data object Connected : ConnectionState
    data class Stale(val sinceEpochMillis: Long) : ConnectionState
    data object Offline : ConnectionState
    data object Revoked : ConnectionState
    data class Error(val reason: SessionErrorReason) : ConnectionState
}
