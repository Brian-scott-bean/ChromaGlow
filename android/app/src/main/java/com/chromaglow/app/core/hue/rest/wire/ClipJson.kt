package com.chromaglow.app.core.hue.rest.wire

import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull

/**
 * Tolerant tree-API accessors for CLIP v2 JSON. kotlinx.serialization is used as a JSON tree
 * only — no compiler plugin, no `@Serializable`. Nothing here throws on a shape mismatch: the
 * wrong type yields null, and callers decide what "missing" means for capability truth.
 */
internal object ClipJson {
    val parser: Json = Json { ignoreUnknownKeys = true; isLenient = false }

    fun parseOrNull(text: String): JsonElement? =
        try {
            parser.parseToJsonElement(text)
        } catch (_: SerializationException) {
            null
        } catch (_: IllegalArgumentException) {
            null
        }
}

internal fun JsonObject.obj(name: String): JsonObject? = this[name] as? JsonObject

internal fun JsonObject.arr(name: String): JsonArray? = this[name] as? JsonArray

internal fun JsonObject.str(name: String): String? =
    (this[name] as? JsonPrimitive)?.takeIf { it.isString }?.content

internal fun JsonObject.bool(name: String): Boolean? =
    (this[name] as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull

internal fun JsonObject.int(name: String): Int? =
    (this[name] as? JsonPrimitive)?.takeIf { !it.isString }?.intOrNull

internal fun JsonObject.long(name: String): Long? =
    (this[name] as? JsonPrimitive)?.takeIf { !it.isString }?.longOrNull

/** Finite doubles only: NaN/Infinity can never enter the model. */
internal fun JsonObject.dbl(name: String): Double? =
    (this[name] as? JsonPrimitive)?.takeIf { !it.isString }?.doubleOrNull?.takeIf { it.isFinite() }

/** Every string element of the array named [name]; non-string elements are skipped. Null when absent/not an array. */
internal fun JsonObject.strList(name: String): List<String>? =
    arr(name)?.mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content }
