package com.chromaglow.app.core.credentials

/**
 * Derives Keystore aliases and ciphertext file names from a bridge id.
 *
 * The accepted id shape is the canonical physical Hue identity only: UPPERCASE 16-hex `bridgeid`
 * (D-002), exactly as [com.chromaglow.app.core.bridge.PairedBridgeRecord] enforces. Anything
 * looser (lowercase, UUID-like, demo ids) is refused so a token can never be keyed on a
 * non-canonical or non-Hue identity.
 */
internal object BridgeCredentialAlias {
    private val bridgeIdPattern = Regex("^[0-9A-F]{16}$")

    fun keystoreAlias(bridgeId: String): String {
        val validated = validateBridgeId(bridgeId)
        return "chromaglow.bridge.$validated.api_token"
    }

    fun ciphertextFileName(bridgeId: String): String {
        val validated = validateBridgeId(bridgeId)
        return "bridge_$validated.api_token.enc"
    }

    fun validateBridgeId(bridgeId: String): String {
        require(bridgeId.isNotBlank()) { "bridgeId must not be blank" }
        require(bridgeIdPattern.matches(bridgeId)) {
            "bridgeId must be a canonical uppercase 16-hex Hue bridge id"
        }
        return bridgeId
    }
}
