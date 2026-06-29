package com.chromaglow.app.core.hue.pairing.protocol

/**
 * Identity fields extracted from a Hue bridge `/api/0/config` document.
 *
 * @property bridgeId the active bridge identity: exactly 16 UPPERCASE hex characters.
 * @property replacesBridgeId the prior identity this bridge replaced, when advertised,
 *   normalized to uppercase. This is informational only and is NEVER the active identity.
 */
data class BridgeConfig(
    val bridgeId: String,
    val replacesBridgeId: String? = null,
) {
    init {
        require(BRIDGE_ID_REGEX.matches(bridgeId)) {
            "bridgeId must be exactly 16 uppercase hex characters"
        }
        require(replacesBridgeId == null || replacesBridgeId.isNotBlank()) {
            "replacesBridgeId, when present, must not be blank"
        }
    }

    companion object {
        /** Canonical Hue bridge identifier: exactly 16 uppercase hex characters. */
        val BRIDGE_ID_REGEX = Regex("[0-9A-F]{16}")
    }
}
