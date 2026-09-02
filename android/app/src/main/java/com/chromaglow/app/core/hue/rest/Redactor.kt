package com.chromaglow.app.core.hue.rest

/**
 * Masks credentials in any text destined for a log line or diagnostic. The transport never logs
 * URLs with keys, but every diagnostic string still passes through here so a future mistake
 * cannot leak the application key.
 */
object Redactor {
    const val MASK: String = "<redacted>"

    private val HEADER_VALUE = Regex("(?i)(hue-application-key\"?\\s*[:=]\\s*)(\"?)([^\\s,;\"'}]+)(\"?)")
    private val USERNAME_JSON = Regex("(?i)(\"username\"\\s*:\\s*\")([^\"]*)(\")")
    private val CLIENTKEY_JSON = Regex("(?i)(\"clientkey\"\\s*:\\s*\")([^\"]*)(\")")

    /**
     * Mask header values, `username`/`clientkey` JSON fields and every literal in [secrets].
     * Secrets shorter than 4 characters are not searched for (masking "a" everywhere destroys
     * the text without protecting anything).
     */
    fun redact(text: String, secrets: Collection<String> = emptyList()): String {
        var out = HEADER_VALUE.replace(text) { m -> "${m.groupValues[1]}${m.groupValues[2]}$MASK${m.groupValues[4]}" }
        out = USERNAME_JSON.replace(out) { m -> "${m.groupValues[1]}$MASK${m.groupValues[3]}" }
        out = CLIENTKEY_JSON.replace(out) { m -> "${m.groupValues[1]}$MASK${m.groupValues[3]}" }
        for (secret in secrets) {
            if (secret.length >= 4) out = out.replace(secret, MASK)
        }
        return out
    }
}
