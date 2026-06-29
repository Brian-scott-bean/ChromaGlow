package com.chromaglow.app.core.hue.pairing.protocol

import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.intOrNull

/**
 * Internal helpers shared by the pairing parsers.
 *
 * Everything here uses the structured kotlinx.serialization JSON tree API only
 * ([Json.parseToJsonElement] + safe casts). Nothing relies on the serialization compiler
 * plugin, and no operation here throws: shape mismatches surface as `null`.
 */

/** True when [body] exceeds [PairingProtocol.MAX_BODY_BYTES] UTF-8 bytes. */
internal fun isOversizeBody(body: String): Boolean =
    body.toByteArray(Charsets.UTF_8).size > PairingProtocol.MAX_BODY_BYTES

/**
 * Parses [body] into a JSON tree, returning `null` on malformed JSON instead of throwing.
 */
internal fun parseJsonTreeOrNull(body: String): JsonElement? =
    try {
        Json.parseToJsonElement(body)
    } catch (_: SerializationException) {
        null
    }

/**
 * Returns the value of [name] when it is present as a JSON *string*, else `null`.
 *
 * Numbers, booleans, null, objects, and arrays all yield `null` so callers can fail closed.
 */
internal fun JsonObject.stringField(name: String): String? =
    (this[name] as? JsonPrimitive)?.takeIf { it.isString }?.content

/**
 * Returns the value of [name] when it is present as a JSON integer, else `null`.
 */
internal fun JsonObject.intField(name: String): Int? =
    (this[name] as? JsonPrimitive)?.intOrNull
