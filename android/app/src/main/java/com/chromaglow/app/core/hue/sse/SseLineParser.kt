package com.chromaglow.app.core.hue.sse

/**
 * Hand-rolled, allocation-light Server-Sent-Events line parser for `/eventstream/clip/v2`.
 * Only `data:` lines matter; `id:`, `event:`, `retry:` and comment (`:`) lines are ignored; a
 * blank line dispatches the accumulated payload (multi-line `data:` joined with '\n', per the
 * SSE spec). Pure: feed lines, collect payloads.
 */
class SseLineParser {
    private val buffer = StringBuilder()
    private var hasData = false

    /** Feed one line WITHOUT its terminator; returns a complete payload when a blank line closes one. */
    fun feed(line: String): String? {
        if (line.isEmpty()) {
            if (!hasData) return null
            val payload = buffer.toString()
            buffer.setLength(0)
            hasData = false
            return payload
        }
        if (line.startsWith(":")) return null
        val colon = line.indexOf(':')
        val field = if (colon < 0) line else line.substring(0, colon)
        if (field != "data") return null
        var value = if (colon < 0) "" else line.substring(colon + 1)
        if (value.startsWith(" ")) value = value.substring(1)
        if (hasData) buffer.append('\n')
        buffer.append(value)
        hasData = true
        return null
    }

    /** Drop any partial payload (stream ended mid-event). */
    fun reset() {
        buffer.setLength(0)
        hasData = false
    }
}
