package com.chromaglow.app.core.hue.rest

import com.chromaglow.app.core.hue.capability.CieXy
import com.chromaglow.app.core.hue.capability.MirekRange
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * Deterministic CLIP v2 write bodies (ports of the iOS golden builders). Pure: same input, same
 * JSON, key order fixed. There is deliberately NO signaling body of any kind in this object, and
 * [combine] refuses a grouped body that carries both colour and colour temperature.
 *
 * Clamps live here (D-021): brightness floor 1 (0 only via [allowZero] for effect tint),
 * effects_v2 speed 0…1, mirek to the lamp's Known schema when given else the protocol bound,
 * timed duration 0…6 h, gradient points ≤ min(points_capable, 5) and ≥ 2. `xy` arrives as a
 * [CieXy], already in [0,1]; gamut projection is the coordinator's job.
 */
object ClipBodies {
    const val NO_EFFECT: String = "no_effect"
    const val MIN_GRADIENT_POINTS: Int = 2

    /** CLIP v2 timed_effects duration cap (6 h); equals LiveMutation.MAX_TIMED_EFFECT_MILLIS (pinned by test). */
    const val MAX_TIMED_EFFECT_MILLIS: Long = 21_600_000L

    /** Floor for a timed effect body (60 s); equals LiveMutation.MIN_TIMED_EFFECT_MILLIS. A 0 s "sunrise" is a flash (E-08). */
    const val MIN_TIMED_EFFECT_MILLIS: Long = 60_000L

    /** Protocol gradient point cap; equals LiveMutation.MAX_GRADIENT_POINTS (pinned by test). */
    const val MAX_GRADIENT_POINTS: Int = 5

    const val TIMED_SUNRISE: String = "sunrise"
    const val TIMED_SUNSET: String = "sunset"

    private fun xyObject(xy: CieXy): JsonObject = buildJsonObject {
        put("xy", buildJsonObject { put("x", xy.x); put("y", xy.y) })
    }

    fun power(on: Boolean): ClipWriteBody = ClipWriteBody(buildJsonObject {
        put("on", buildJsonObject { put("on", on) })
    })

    /** Percent 1…100 (or 0…100 with [allowZero]) as an integer, the shape both light and grouped_light accept. */
    fun brightness(percent: Int, allowZero: Boolean = false): ClipWriteBody {
        val floor = if (allowZero) 0 else 1
        return ClipWriteBody(buildJsonObject {
            put("dimming", buildJsonObject { put("brightness", percent.coerceIn(floor, 100)) })
        })
    }

    /** Atomic on + dimming in one PUT (grouped or light). */
    fun powerAndBrightness(on: Boolean, percent: Int): ClipWriteBody =
        combine(power(on), brightness(percent))

    fun color(xy: CieXy): ClipWriteBody = ClipWriteBody(buildJsonObject { put("color", xyObject(xy)) })

    /**
     * Colour temperature clamped to [range] when the lamp's schema is Known, otherwise to the
     * documented protocol bound (the grouped-write clamp; never presented as a lamp's range).
     */
    fun colorTemperature(mirek: Int, range: MirekRange? = null): ClipWriteBody {
        val clamped = range?.clamp(mirek) ?: mirek.coerceIn(MirekRange.PROTOCOL_MINIMUM, MirekRange.PROTOCOL_MAXIMUM)
        return ClipWriteBody(buildJsonObject {
            put("color_temperature", buildJsonObject { put("mirek", clamped) })
        })
    }

    /** Legacy v1 enum: `{"effects":{"effect":e}}`; also the grouped_light fallback and v1 stop. */
    fun effectV1(effect: String): ClipWriteBody = ClipWriteBody(buildJsonObject {
        put("effects", buildJsonObject { put("effect", effect) })
    })

    /**
     * effects_v2 action. `parameters` is emitted only when at least one parameter is provided,
     * and each key only when provided (the caller sends a parameter only when its capability is
     * Known). speed 0…1; mirek to [mirekRange] or the protocol bound.
     */
    fun effectV2(
        effect: String,
        speed: Double? = null,
        color: CieXy? = null,
        mirek: Int? = null,
        mirekRange: MirekRange? = null,
    ): ClipWriteBody {
        require(effect.isNotBlank()) { "effect must not be blank" }
        val parameters = buildJsonObject {
            speed?.let { put("speed", it.coerceIn(0.0, 1.0)) }
            color?.let { put("color", xyObject(it)) }
            mirek?.let { put("color_temperature", buildJsonObject {
                put("mirek", mirekRange?.clamp(it) ?: it.coerceIn(MirekRange.PROTOCOL_MINIMUM, MirekRange.PROTOCOL_MAXIMUM))
            }) }
        }
        return ClipWriteBody(buildJsonObject {
            put("effects_v2", buildJsonObject {
                put("action", buildJsonObject {
                    put("effect", effect)
                    if (parameters.isNotEmpty()) put("parameters", parameters)
                })
            })
        })
    }

    /** Stop a firmware effect on the API the lamp speaks (v2 when it has effects_v2, else v1). */
    fun stopEffect(viaV2: Boolean): ClipWriteBody = if (viaV2) effectV2(NO_EFFECT) else effectV1(NO_EFFECT)

    /**
     * Start a bridge-native timed effect ([effect] is the wire name, e.g. [TIMED_SUNRISE]).
     * Duration clamped [MIN_TIMED_EFFECT_MILLIS]…[MAX_TIMED_EFFECT_MILLIS].
     * A running firmware effect takes precedence on the bridge, so [clearFirmwareEffect] (default
     * true) sends `effects.no_effect` in the SAME PUT.
     */
    fun timedEffect(effect: String, durationMillis: Long, clearFirmwareEffect: Boolean = true): ClipWriteBody {
        require(effect.isNotBlank()) { "effect must not be blank" }
        val duration = durationMillis.coerceIn(MIN_TIMED_EFFECT_MILLIS, MAX_TIMED_EFFECT_MILLIS)
        return ClipWriteBody(buildJsonObject {
            put("timed_effects", buildJsonObject {
                put("effect", effect)
                put("duration", duration)
            })
            if (clearFirmwareEffect) put("effects", buildJsonObject { put("effect", NO_EFFECT) })
        })
    }

    /** Cancel a running timed effect: `{"timed_effects":{"effect":"no_effect"}}`. */
    fun cancelTimedEffect(): ClipWriteBody = ClipWriteBody(buildJsonObject {
        put("timed_effects", buildJsonObject { put("effect", NO_EFFECT) })
    })

    /**
     * Gradient points along a strip. Points are capped at min([pointsCapable], 5) and padded to
     * at least 2 by repeating the last point (the bridge rejects fewer). [mode] only when given
     * (the caller offers only values from `mode_values`). Optional on/dimming/transition ride in
     * the same PUT so one paced command carries the whole strip state.
     */
    fun gradient(
        points: List<CieXy>,
        pointsCapable: Int,
        mode: String? = null,
        on: Boolean? = null,
        brightnessPercent: Int? = null,
        transitionMillis: Long? = null,
    ): ClipWriteBody {
        require(points.isNotEmpty()) { "gradient needs at least one point" }
        val cap = minOf(pointsCapable, MAX_GRADIENT_POINTS).coerceAtLeast(MIN_GRADIENT_POINTS)
        val capped = points.take(cap).toMutableList()
        while (capped.size < MIN_GRADIENT_POINTS) capped += capped.last()
        return ClipWriteBody(buildJsonObject {
            put("gradient", buildJsonObject {
                put("points", buildJsonArray {
                    capped.forEach { add(buildJsonObject { put("color", xyObject(it)) }) }
                })
                mode?.let { put("mode", it) }
            })
            on?.let { put("on", buildJsonObject { put("on", it) }) }
            brightnessPercent?.let { put("dimming", buildJsonObject { put("brightness", it.coerceIn(1, 100)) }) }
            transitionMillis?.let { put("dynamics", buildJsonObject { put("duration", it.coerceAtLeast(0L)) }) }
        })
    }

    fun sceneRecall(): ClipWriteBody = ClipWriteBody(buildJsonObject {
        put("recall", buildJsonObject { put("action", "active") })
    })

    /** MODEL ONLY in this slice: no production caller. */
    fun dynamicPaletteRecall(durationMillis: Long? = null): ClipWriteBody = ClipWriteBody(buildJsonObject {
        put("recall", buildJsonObject {
            put("action", "dynamic_palette")
            durationMillis?.let { put("duration", it.coerceAtLeast(0L)) }
        })
    })

    /** `{"dynamics":{"duration":ms}}` — the internal short transition on colour/CT/gradient writes. */
    fun transition(durationMillis: Long): ClipWriteBody = ClipWriteBody(buildJsonObject {
        put("dynamics", buildJsonObject { put("duration", durationMillis.coerceAtLeast(0L)) })
    })

    /**
     * Merge bodies into one PUT. Refuses a body that carries BOTH `color` and `color_temperature`
     * (the bridge rejects the combined grouped write) and refuses any `signaling` key outright.
     */
    fun combine(vararg bodies: ClipWriteBody): ClipWriteBody {
        val merged = LinkedHashMap<String, JsonElement>()
        for (body in bodies) for ((k, v) in body.json) merged[k] = v
        require(!("color" in merged && "color_temperature" in merged)) { "colour and colour temperature must never share one body" }
        require("signaling" !in merged) { "no signaling body exists in this slice" }
        return ClipWriteBody(JsonObject(merged))
    }

    /** Convenience: does this body change on/off, dimming, colour, CT or gradient (a light-level state write)? */
    fun isStateWrite(body: ClipWriteBody): Boolean =
        body.json.keys.any { it == "on" || it == "dimming" || it == "color" || it == "color_temperature" || it == "gradient" }
}
