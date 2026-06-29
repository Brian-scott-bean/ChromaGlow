package com.chromaglow.app.core.hue.pairing.protocol

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject

/**
 * Parses the Hue "create user" (link-button pairing) response.
 *
 * Hue replies with a single-element JSON array, either
 * `[{"success":{"username":"<key>"}}]` or `[{"error":{"type":N,"description":"..."}}]`.
 * Anything else is rejected as [CreateUserOutcome.Malformed]. The parser never throws.
 */
object PairingResponseParser {

    /** Hue error type for "link button not pressed" (retryable). */
    const val ERROR_TYPE_LINK_BUTTON_NOT_PRESSED: Int = 101

    /** Hue error type for an invalid request. */
    const val ERROR_TYPE_INVALID_REQUEST: Int = 7

    /**
     * Interprets a raw create-user response [body] into a [CreateUserOutcome].
     *
     * Fails closed (returns [CreateUserOutcome.Malformed]) on oversize input, malformed JSON,
     * a non-array root, an array whose size is not exactly one, a non-object element, an
     * element that does not contain exactly one of `success`/`error`, or missing fields.
     */
    fun parseCreateUser(body: String): CreateUserOutcome {
        if (isOversizeBody(body)) {
            return CreateUserOutcome.Malformed("body exceeds ${PairingProtocol.MAX_BODY_BYTES} bytes")
        }

        val root = parseJsonTreeOrNull(body)
            ?: return CreateUserOutcome.Malformed("body is not valid JSON")

        val array = root as? JsonArray
            ?: return CreateUserOutcome.Malformed("body is not a JSON array")
        if (array.size != 1) {
            return CreateUserOutcome.Malformed("expected exactly one array element, found ${array.size}")
        }

        val entry = array[0] as? JsonObject
            ?: return CreateUserOutcome.Malformed("array element is not a JSON object")

        val success = entry["success"] as? JsonObject
        val error = entry["error"] as? JsonObject

        // Exactly one of success/error must be present; otherwise the shape is ambiguous.
        if ((success == null) == (error == null)) {
            return CreateUserOutcome.Malformed("element must contain exactly one of success/error")
        }

        return if (success != null) {
            parseSuccess(success)
        } else {
            parseError(error!!)
        }
    }

    private fun parseSuccess(success: JsonObject): CreateUserOutcome {
        val username = success.stringField("username")
        if (username.isNullOrBlank()) {
            return CreateUserOutcome.Malformed("success is missing a non-blank username")
        }
        // Any "clientkey" present is intentionally ignored and never retained.
        return CreateUserOutcome.Success(username)
    }

    private fun parseError(error: JsonObject): CreateUserOutcome {
        val type = error.intField("type")
            ?: return CreateUserOutcome.Malformed("error is missing a numeric type")
        val description = error.stringField("description").orEmpty()
        return when (type) {
            ERROR_TYPE_LINK_BUTTON_NOT_PRESSED -> CreateUserOutcome.LinkButtonNotPressed
            ERROR_TYPE_INVALID_REQUEST -> CreateUserOutcome.InvalidRequest
            else -> CreateUserOutcome.UnknownError(type = type, description = description)
        }
    }
}
