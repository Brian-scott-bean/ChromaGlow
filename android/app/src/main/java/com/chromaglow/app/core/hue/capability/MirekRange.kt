package com.chromaglow.app.core.hue.capability

/**
 * A lamp's own colour-temperature range from `color_temperature.mirek_schema`. Only a Known
 * range makes a per-light warmth control interactive; the 153–500 protocol bound is a grouped/
 * body-layer clamp and is never presented as a lamp's Known range.
 */
data class MirekRange(val minimum: Int, val maximum: Int) {
    init {
        require(minimum in PROTOCOL_MINIMUM..PROTOCOL_MAXIMUM) { "minimum out of protocol bounds" }
        require(maximum in PROTOCOL_MINIMUM..PROTOCOL_MAXIMUM) { "maximum out of protocol bounds" }
        require(minimum <= maximum) { "minimum must not exceed maximum" }
    }

    fun clamp(mirek: Int): Int = mirek.coerceIn(minimum, maximum)

    operator fun contains(mirek: Int): Boolean = mirek in minimum..maximum

    companion object {
        /** Documented CLIP v2 protocol bounds; a clamp for grouped writes, not a lamp's truth. */
        const val PROTOCOL_MINIMUM: Int = 153
        const val PROTOCOL_MAXIMUM: Int = 500
    }
}
