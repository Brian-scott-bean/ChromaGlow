package com.chromaglow.app.core.hue.pairing.protocol

/**
 * Shared constants for the Hue link-button pairing protocol contracts.
 *
 * This package is pure Kotlin: it owns the structured request/response/config shapes only.
 * It performs no networking, no TLS, and touches no Android APIs. A separate transport lane
 * is responsible for actually issuing the HTTPS requests and feeding the raw bodies here.
 */
object PairingProtocol {

    /**
     * Maximum accepted response body size, in UTF-8 bytes (64 KiB).
     *
     * Any body strictly larger than this is rejected (fail closed) before parsing, so a
     * hostile or runaway endpoint can never force us to materialize an unbounded JSON tree.
     */
    const val MAX_BODY_BYTES: Int = 65_536
}
