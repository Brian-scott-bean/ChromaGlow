package com.chromaglow.app.core.hue.pairing.protocol

/**
 * Typed result of interpreting a Hue "create user" response.
 *
 * The parser always returns one of these variants and never throws to the caller, so the
 * transport lane can branch exhaustively. Only [Success] indicates a usable application key.
 */
sealed interface CreateUserOutcome {

    /** True only for the single retryable outcome ([LinkButtonNotPressed]). */
    val isRetryable: Boolean
        get() = this is LinkButtonNotPressed

    /**
     * The bridge accepted pairing.
     *
     * @property username the bridge application key ("username"); guaranteed non-blank.
     *   Any `clientkey` the bridge may have returned is intentionally dropped here and is
     *   never retained, returned, or logged.
     */
    data class Success(val username: String) : CreateUserOutcome {
        init {
            require(username.isNotBlank()) { "username must not be blank" }
        }

        /** Redacted: the application key never appears in diagnostics or logs (audit L-31). */
        override fun toString(): String = "Success(username=***)"
    }

    /**
     * Hue error type `101`: the link button has not been pressed yet.
     *
     * This is the ONLY retryable outcome — the caller should prompt the user to press the
     * bridge button and poll again.
     */
    data object LinkButtonNotPressed : CreateUserOutcome

    /** Hue error type `7`: the bridge rejected the request as invalid. Not retryable. */
    data object InvalidRequest : CreateUserOutcome

    /**
     * The bridge returned an error whose [type] we do not specifically handle.
     *
     * @property type the raw Hue error type.
     * @property description the raw Hue error description (may be empty).
     */
    data class UnknownError(val type: Int, val description: String) : CreateUserOutcome

    /**
     * The response could not be interpreted as a valid Hue pairing reply and was rejected
     * (fail closed): malformed JSON, wrong shape, empty/multi-element/ambiguous array,
     * missing fields, or an oversize body.
     *
     * @property reason short, non-sensitive description of why parsing failed.
     */
    data class Malformed(val reason: String) : CreateUserOutcome
}
