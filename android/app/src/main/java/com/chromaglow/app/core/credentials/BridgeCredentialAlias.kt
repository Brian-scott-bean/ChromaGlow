package com.chromaglow.app.core.credentials

internal object BridgeCredentialAlias {
    private val bridgeIdPattern = Regex("^[A-Za-z0-9_-]+$")

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
            "bridgeId contains unsupported characters"
        }
        return bridgeId
    }
}
