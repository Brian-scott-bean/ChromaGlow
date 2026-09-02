package com.chromaglow.app.core.hue.discovery

/**
 * Sanitises an untrusted, attacker-controllable display string (an mDNS `serviceName`) before it
 * is rendered or persisted as a bridge name (audit L-40).
 *
 * Pure Kotlin, no Android imports. Removes every control and format character (which covers the
 * Unicode bidirectional overrides and isolates used for RTL/homograph spoofing, zero-width joiners,
 * and C0/C1 controls), drops private-use and unassigned code points, collapses whitespace runs,
 * trims, and bounds the length. A name that is empty after cleaning falls back to [fallback]
 * (the numeric host), which is always shown beneath the name anyway.
 */
internal object BridgeDisplayName {

    /** Upper bound on a rendered/persisted bridge name, in UTF-16 code units. */
    const val MAX_LENGTH: Int = 64

    fun sanitize(raw: String?, fallback: String): String {
        if (raw == null) return fallback
        val cleaned = StringBuilder(raw.length)
        var pendingSpace = false
        var index = 0
        while (index < raw.length) {
            val codePoint = raw.codePointAt(index)
            index += Character.charCount(codePoint)
            when (Character.getType(codePoint).toByte()) {
                // Whitespace-class controls (tab, CR, LF, ...) and Unicode line/paragraph
                // separators act as a word separator; a run collapses to one space.
                Character.LINE_SEPARATOR,
                Character.PARAGRAPH_SEPARATOR,
                Character.SPACE_SEPARATOR,
                -> pendingSpace = cleaned.isNotEmpty()
                // Non-whitespace controls, format characters (bidi overrides/isolates/marks,
                // zero-width joiners), private-use, surrogates and unassigned code points are
                // invisible or spoofing vectors: they vanish without leaving a separator.
                Character.CONTROL -> if (Character.isWhitespace(codePoint)) pendingSpace = cleaned.isNotEmpty()
                Character.FORMAT,
                Character.PRIVATE_USE,
                Character.SURROGATE,
                Character.UNASSIGNED,
                -> Unit
                else -> {
                    if (pendingSpace) {
                        cleaned.append(' ')
                        pendingSpace = false
                    }
                    cleaned.appendCodePoint(codePoint)
                }
            }
        }
        val bounded = cleaned.toString().trim().take(MAX_LENGTH).trimEnd()
        return bounded.ifBlank { fallback }
    }
}
