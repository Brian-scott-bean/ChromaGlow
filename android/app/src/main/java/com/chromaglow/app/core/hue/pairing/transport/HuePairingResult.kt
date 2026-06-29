package com.chromaglow.app.core.hue.pairing.transport

/**
 * Identifies which leg of the two-step pairing exchange produced a failure.
 *
 * Purely diagnostic and non-sensitive: it carries no bridge identity, credential, or address.
 */
enum class PairingStage {
    /** The `GET /api/0/config` identity probe. */
    CONFIG,

    /** The `POST /api` create-user (link-button) request. */
    CREATE_USER,
}

/**
 * Typed, non-throwing reason for a terminal pairing failure.
 *
 * Every variant is deliberately free of secrets and device data: no usernames, bridge ids,
 * local addresses, or certificate material ever appear here, so a caller can surface or store a
 * reason without leaking sensitive information.
 */
sealed interface PairingFailureReason {

    /** The bridge rejected the create-user request as invalid (Hue error type `7`). */
    data object InvalidRequest : PairingFailureReason

    /**
     * The bridge returned an error type the protocol layer does not specifically handle.
     *
     * @property type the raw Hue error type.
     * @property description the raw Hue error description (generic protocol text; may be empty).
     */
    data class BridgeError(val type: Int, val description: String) : PairingFailureReason

    /**
     * A response body could not be interpreted and was rejected (fail closed).
     *
     * @property stage which request produced the body.
     * @property reason short, non-sensitive description of why parsing failed.
     */
    data class MalformedResponse(val stage: PairingStage, val reason: String) : PairingFailureReason

    /**
     * A response body exceeded the 64 KiB cap and was rejected without being fully buffered.
     *
     * @property stage which request produced the oversized body.
     */
    data class ResponseTooLarge(val stage: PairingStage) : PairingFailureReason

    /**
     * The server returned an unexpected (non-2xx) HTTP status. Because redirects are never
     * followed, a `3xx` redirect surfaces here too (the redirect is refused, not chased).
     *
     * @property stage which request produced the status.
     * @property code the raw HTTP status code.
     */
    data class UnexpectedHttpStatus(val stage: PairingStage, val code: Int) : PairingFailureReason

    /**
     * The CA-validated leaf certificate did not present a usable SAN-less Hue identity (missing
     * leaf, non-X.509 leaf, or a Common Name that is not a 16-hex bridge id).
     */
    data object UnverifiableLeafIdentity : PairingFailureReason

    /**
     * The config `bridgeid` and/or a supplied hint did not match the identity authenticated from
     * the leaf certificate's Common Name. No identifiers are exposed here by design.
     */
    data object IdentityMismatch : PairingFailureReason

    /**
     * A transport-level error occurred: TLS handshake failure (untrusted CA, rejected leaf
     * identity), connection reset, or a call timeout. The underlying cause is intentionally not
     * retained to avoid leaking addresses or certificate data.
     */
    data object TransportError : PairingFailureReason
}

/**
 * Outcome of a single [HuePairingClient.pair] attempt.
 *
 * The client never throws across this boundary for an expected condition: every result —
 * including identity, transport, and protocol failures — is one of these typed variants
 * (fail closed). Only [Success] yields a usable application key, and only
 * [LinkButtonNotPressed] is retryable.
 */
sealed interface HuePairingResult {

    /** True only for the single retryable outcome ([LinkButtonNotPressed]). */
    val isRetryable: Boolean
        get() = this is LinkButtonNotPressed

    /**
     * The bridge accepted pairing over a CA-validated, identity-checked channel.
     *
     * @property bridgeId the canonical authenticated identity of the paired bridge: the UPPERCASE
     *   16-hex `bridgeid` extracted from the CA-validated leaf Common Name and confirmed to agree
     *   with `/api/0/config` (and any caller hint) across both the GET and POST legs. A caller can
     *   key durable credential/metadata storage on this without re-fetching or fabricating identity.
     * @property username the bridge application key. It is never logged or persisted by this
     *   client; any `clientkey` the bridge may have returned was dropped by the protocol layer.
     */
    data class Success(val bridgeId: String, val username: String) : HuePairingResult

    /**
     * Hue error type `101`: the link button has not been pressed yet. This is the ONLY retryable
     * outcome — the caller should prompt the user to press the bridge button and call again.
     */
    data object LinkButtonNotPressed : HuePairingResult

    /** A terminal, non-retryable failure. */
    data class Failure(val reason: PairingFailureReason) : HuePairingResult
}
