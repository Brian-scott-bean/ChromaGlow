package com.chromaglow.app.core.hue.pairing.protocol

import kotlinx.serialization.json.JsonObject

/**
 * Parses a Hue bridge `/api/0/config` document into a [BridgeConfig].
 *
 * Extracts and normalizes `bridgeid` (required: exactly 16 hex chars, uppercased) and the
 * optional `replacesbridgeid` (uppercased, informational only). Fails closed on anything
 * else. The parser never throws.
 */
object BridgeConfigParser {

    /**
     * Interprets a raw config [body] into a [BridgeConfigOutcome].
     *
     * Fails closed (returns [BridgeConfigOutcome.Malformed]) on oversize input, malformed
     * JSON, a non-object root, or a `bridgeid` that is missing or not exactly 16 hex chars.
     */
    fun parseConfig(body: String): BridgeConfigOutcome {
        if (isOversizeBody(body)) {
            return BridgeConfigOutcome.Malformed("body exceeds ${PairingProtocol.MAX_BODY_BYTES} bytes")
        }

        val root = parseJsonTreeOrNull(body)
            ?: return BridgeConfigOutcome.Malformed("body is not valid JSON")

        val obj = root as? JsonObject
            ?: return BridgeConfigOutcome.Malformed("body is not a JSON object")

        val rawBridgeId = obj.stringField("bridgeid")
            ?: return BridgeConfigOutcome.Malformed("config is missing a string bridgeid")
        val bridgeId = rawBridgeId.uppercase()
        if (!BridgeConfig.BRIDGE_ID_REGEX.matches(bridgeId)) {
            return BridgeConfigOutcome.Malformed("bridgeid is not exactly 16 hex characters")
        }

        // replacesbridgeid is optional, normalized to uppercase, and NEVER the active identity.
        val replacesBridgeId = obj.stringField("replacesbridgeid")
            ?.uppercase()
            ?.takeIf { it.isNotBlank() }

        return try {
            BridgeConfigOutcome.Parsed(
                BridgeConfig(bridgeId = bridgeId, replacesBridgeId = replacesBridgeId),
            )
        } catch (e: IllegalArgumentException) {
            BridgeConfigOutcome.Malformed(e.message ?: "invalid bridge config")
        }
    }
}
