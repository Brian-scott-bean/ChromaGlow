package com.chromaglow.app.core.hue.rest

/**
 * Typed, secret-free transport outcomes. Only [Unauthorized] (an explicit 401/403 over pinned TLS)
 * may ever move a session toward a revoked state; timeouts, 5xx, TLS and decode failures are
 * transient and never touch credentials.
 */
sealed interface ClipError {
    data object MissingCredentials : ClipError

    /**
     * Connection-level failure (reset, EOF, DNS, TLS handshake). Cause intentionally not retained.
     * [afterTransmission] is true when the request body had already been handed to the socket
     * (a reset while awaiting the response): the bridge MAY have applied it, so safety accounting
     * treats it exactly like [Timeout] with `afterTransmission = true`.
     */
    data class Transport(val afterTransmission: Boolean = false) : ClipError

    /**
     * The call timed out. [afterTransmission] is true when the request body had been handed to
     * the socket, so the bridge MAY have applied it: safety accounting treats that as delivered.
     */
    data class Timeout(val afterTransmission: Boolean) : ClipError

    /** Explicit 401/403 from the bridge. The ONLY variant allowed to trigger revocation handling. */
    data class Unauthorized(val status: Int) : ClipError

    data class Http(val status: Int) : ClipError

    data object RateLimited : ClipError

    /** 2xx with `errors[]` and no `data` — a refusal wearing a success status. */
    data class BridgeRejected(val descriptions: List<String>) : ClipError

    data class Decode(val reason: String) : ClipError

    /** The CA-validated leaf did not match the bridge id this client is pinned to. */
    data object TlsIdentity : ClipError
}

/** Result carrier: no exception crosses the transport boundary. */
sealed interface ClipResult<out T> {
    data class Ok<T>(val value: T, val partialErrors: List<String> = emptyList()) : ClipResult<T>
    data class Err(val error: ClipError) : ClipResult<Nothing>
}
