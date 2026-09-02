package com.chromaglow.app.core.bridge

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * Structured JSON codec for the persisted [PairedBridgeRecord] list.
 *
 * Uses the kotlinx.serialization JSON *tree* API only ([Json.parseToJsonElement] + builders); it
 * does NOT use the serialization compiler plugin or `@Serializable`. The encoded form is a JSON
 * array of flat objects stored as a single Preferences string value.
 *
 * [decode] fails closed by throwing [MalformedMetadataException] on any structural problem
 * (non-array root, missing/typed-wrong field, or a value that violates a [PairedBridgeRecord]
 * guard). The registry maps that to an explicit corruption outcome.
 */
internal object PairedBridgeCodec {

    private const val FIELD_BRIDGE_ID = "bridgeId"
    private const val FIELD_NAME = "name"
    private const val FIELD_HOST = "host"
    private const val FIELD_PORT = "port"
    private const val FIELD_IS_ACTIVE = "isActive"

    fun encode(records: List<PairedBridgeRecord>): String {
        val array = buildJsonArray {
            records.forEach { record ->
                add(
                    buildJsonObject {
                        put(FIELD_BRIDGE_ID, record.bridgeId)
                        put(FIELD_NAME, record.name)
                        put(FIELD_HOST, record.host)
                        put(FIELD_PORT, record.port)
                        put(FIELD_IS_ACTIVE, record.isActive)
                    },
                )
            }
        }
        return array.toString()
    }

    /**
     * Recoverable parse: a structurally valid array is decoded element by element, so one damaged
     * entry hides neither the others nor the Forget path (Baylee convergence finding). Invalid
     * entries are counted in [RecoveredMetadata.skipped]; duplicate ids keep the first occurrence.
     * A root that is not a JSON array (or not JSON at all) still throws [MalformedMetadataException]
     * — nothing can be recovered from it.
     */
    fun decodeRecoverable(raw: String): RecoveredMetadata {
        val array = parseArrayRoot(raw)
        val records = ArrayList<PairedBridgeRecord>(array.size)
        val seen = HashSet<String>()
        var skipped = 0
        for (element in array) {
            val record = try {
                decodeEntry(element)
            } catch (_: MalformedMetadataException) {
                skipped += 1
                continue
            }
            if (seen.add(record.bridgeId)) records.add(record) else skipped += 1
        }
        return RecoveredMetadata(records = records, skipped = skipped)
    }

    /**
     * Strict parse: [raw] must be entirely valid, or [MalformedMetadataException] is thrown. Kept
     * for callers that need all-or-nothing semantics (tests, round-trip checks).
     */
    fun decode(raw: String): List<PairedBridgeRecord> =
        parseArrayRoot(raw).map { element -> decodeEntry(element) }

    private fun parseArrayRoot(raw: String): JsonArray {
        val root = try {
            Json.parseToJsonElement(raw)
        } catch (cause: Exception) {
            throw MalformedMetadataException("metadata is not valid JSON", cause)
        }
        return root as? JsonArray
            ?: throw MalformedMetadataException("metadata root is not a JSON array")
    }

    private fun decodeEntry(element: kotlinx.serialization.json.JsonElement): PairedBridgeRecord {
        val obj = element as? JsonObject
            ?: throw MalformedMetadataException("metadata entry is not a JSON object")
        return try {
            PairedBridgeRecord(
                bridgeId = obj.requireString(FIELD_BRIDGE_ID),
                name = obj.requireString(FIELD_NAME),
                host = obj.requireString(FIELD_HOST),
                port = obj.requireInt(FIELD_PORT),
                isActive = obj.requireBoolean(FIELD_IS_ACTIVE),
            )
        } catch (cause: IllegalArgumentException) {
            // Covers both a violated record guard and a field-extraction failure below.
            throw MalformedMetadataException("metadata entry is invalid", cause)
        }
    }

    private fun JsonObject.requireString(field: String): String {
        val primitive = this[field] as? JsonPrimitive
        require(primitive != null && primitive.isString) { "field '$field' is not a string" }
        return primitive.content
    }

    private fun JsonObject.requireInt(field: String): Int {
        val primitive = this[field] as? JsonPrimitive
        require(primitive != null && !primitive.isString) { "field '$field' is not a number" }
        return primitive.content.toIntOrNull()
            ?: throw IllegalArgumentException("field '$field' is not an integer")
    }

    private fun JsonObject.requireBoolean(field: String): Boolean {
        val primitive = this[field] as? JsonPrimitive
        require(primitive != null && !primitive.isString) { "field '$field' is not a boolean" }
        return when (primitive.content) {
            "true" -> true
            "false" -> false
            else -> throw IllegalArgumentException("field '$field' is not a boolean")
        }
    }
}

/** Result of [PairedBridgeCodec.decodeRecoverable]: the usable records plus how many were dropped. */
internal data class RecoveredMetadata(
    val records: List<PairedBridgeRecord>,
    val skipped: Int,
)

/** Thrown when stored bridge metadata cannot be decoded into valid records (fail closed). */
internal class MalformedMetadataException(
    message: String,
    cause: Throwable? = null,
) : Exception(message, cause)
