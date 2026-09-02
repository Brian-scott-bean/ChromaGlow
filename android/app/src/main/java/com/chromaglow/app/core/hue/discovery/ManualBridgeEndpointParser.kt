package com.chromaglow.app.core.hue.discovery

/**
 * Pure-Kotlin parser that turns manually entered text into a [BridgeEndpoint].
 *
 * Validation is entirely local: it never resolves hostnames, never calls Android networking
 * APIs, and never performs DNS. It accepts conservative IPv4 / IPv6 literals and safe ASCII
 * hostnames, then builds an endpoint on the fixed local HTTPS port [MANUAL_BRIDGE_PORT].
 */
object ManualBridgeEndpointParser {

    const val MANUAL_BRIDGE_NAME = "Manual bridge"
    const val MANUAL_BRIDGE_PORT = 443

    const val ERROR_EMPTY = "Enter a bridge IP address or hostname."
    const val ERROR_INVALID = "Enter a valid IPv4, IPv6, or hostname."

    sealed interface Parsed {
        data class Valid(val endpoint: BridgeEndpoint) : Parsed
        data class Invalid(val message: String) : Parsed
    }

    fun parse(raw: String): Parsed {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return Parsed.Invalid(ERROR_EMPTY)

        // Reject schemes, paths, queries, fragments, userinfo, IPv6 zone IDs, and any
        // internal whitespace before attempting host normalization.
        if (trimmed.contains("://")) return Parsed.Invalid(ERROR_INVALID)
        if (trimmed.any { it == '/' || it == '?' || it == '#' || it == '@' || it == '%' || it.isWhitespace() }) {
            return Parsed.Invalid(ERROR_INVALID)
        }

        val normalizedHost = normalizeHost(trimmed) ?: return Parsed.Invalid(ERROR_INVALID)

        return try {
            Parsed.Valid(
                BridgeEndpoint(
                    name = MANUAL_BRIDGE_NAME,
                    host = normalizedHost,
                    port = MANUAL_BRIDGE_PORT,
                ),
            )
        } catch (_: IllegalArgumentException) {
            Parsed.Invalid(ERROR_INVALID)
        }
    }

    private fun normalizeHost(input: String): String? {
        // Bracketed IPv6: strip exactly one matched surrounding pair before validating.
        if (input.startsWith("[") && input.endsWith("]") && input.length >= 2) {
            val inner = input.substring(1, input.length - 1)
            if (inner.contains('[') || inner.contains(']')) return null
            return if (isValidIpv6(inner)) inner else null
        }
        if (input.contains('[') || input.contains(']')) return null

        // Dotted-decimal candidates (digits and dots only) must be valid IPv4 — never a
        // hostname — so malformed addresses such as "256.1.1.1" are rejected outright.
        if (input.all { it.isDigit() || it == '.' }) {
            return if (isValidIpv4(input)) input else null
        }

        if (isValidIpv6(input)) return input
        if (isValidHostname(input)) return input
        return null
    }

    private fun isValidIpv4(input: String): Boolean {
        val parts = input.split(".")
        if (parts.size != 4) return false
        return parts.all { part ->
            part.isNotEmpty() &&
                part.length <= 3 &&
                part.all { it.isDigit() } &&
                // Canonical dotted-decimal only: a leading zero ("010") is octal-ambiguous and
                // would diverge from the discovered form of the same address (audit I-01).
                (part.length == 1 || part[0] != '0') &&
                part.toInt() in 0..255
        }
    }

    private fun isValidIpv6(input: String): Boolean {
        if (input.isEmpty()) return false
        if (input.contains(".")) return false
        if (input.contains(":::")) return false

        val firstDoubleColon = input.indexOf("::")
        if (firstDoubleColon != input.lastIndexOf("::")) return false

        if (firstDoubleColon >= 0) {
            val before = input.substring(0, firstDoubleColon)
            val after = input.substring(firstDoubleColon + 2)
            val head = if (before.isEmpty()) emptyList() else before.split(":")
            val tail = if (after.isEmpty()) emptyList() else after.split(":")
            if (head.size + tail.size > 7) return false
            return head.all { isHextet(it) } && tail.all { isHextet(it) }
        }

        val groups = input.split(":")
        if (groups.size != 8) return false
        return groups.all { isHextet(it) }
    }

    private fun isHextet(group: String): Boolean =
        group.length in 1..4 && group.all { it.isDigit() || it in 'a'..'f' || it in 'A'..'F' }

    private fun isValidHostname(input: String): Boolean {
        if (input.length > 253) return false
        val labels = input.split(".")
        return labels.all { isValidLabel(it) }
    }

    private fun isValidLabel(label: String): Boolean {
        if (label.length !in 1..63) return false
        if (label.startsWith("-") || label.endsWith("-")) return false
        return label.all { it in 'a'..'z' || it in 'A'..'Z' || it.isDigit() || it == '-' }
    }
}
