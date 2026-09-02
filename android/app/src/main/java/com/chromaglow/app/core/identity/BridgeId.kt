package com.chromaglow.app.core.identity

/**
 * The canonical physical identity of a Hue bridge: the UPPERCASE 16-hex `bridgeid` authenticated
 * from the CA-validated TLS leaf Common Name during pairing (D-002 / D-014).
 *
 * This is the ONLY identity a live session, cache, mutation, or SSE lookup may be keyed on. It is
 * never derived from a host, an mDNS name, or a product/model name, and it is never lowercase.
 * Demo mode does not use this type at all (see [DemoTargetId]).
 */
@JvmInline
value class BridgeId(val value: String) {
    init {
        require(CANONICAL.matches(value)) { "BridgeId must be a canonical uppercase 16-hex Hue bridge id" }
    }

    override fun toString(): String = value

    companion object {
        /** The accepted shape. Identical to the registry and credential-alias contracts. */
        val CANONICAL: Regex = Regex("^[0-9A-F]{16}$")

        /** Non-throwing parse for boundaries that receive untrusted text; never normalises case. */
        fun parseOrNull(raw: String): BridgeId? = if (CANONICAL.matches(raw)) BridgeId(raw) else null
    }
}
