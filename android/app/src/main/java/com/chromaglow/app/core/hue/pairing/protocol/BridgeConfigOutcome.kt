package com.chromaglow.app.core.hue.pairing.protocol

/**
 * Typed result of parsing a Hue `/api/0/config` document.
 *
 * The parser always returns one of these variants and never throws to the caller.
 */
sealed interface BridgeConfigOutcome {

    /** The config was understood and yielded a valid [config]. */
    data class Parsed(val config: BridgeConfig) : BridgeConfigOutcome

    /**
     * The config could not be interpreted and was rejected (fail closed): oversize body,
     * malformed JSON, non-object root, or a missing/invalid `bridgeid`.
     *
     * @property reason short, non-sensitive description of why parsing failed.
     */
    data class Malformed(val reason: String) : BridgeConfigOutcome
}
