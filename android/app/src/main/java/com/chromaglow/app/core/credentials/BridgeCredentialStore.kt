package com.chromaglow.app.core.credentials

interface BridgeCredentialStore {
    fun saveApiToken(bridgeId: String, token: String)
    fun loadApiToken(bridgeId: String): BridgeSecretResult
    fun deleteApiToken(bridgeId: String)
}

sealed interface BridgeSecretResult {
    data class Present(val token: String) : BridgeSecretResult
    data object Absent : BridgeSecretResult
    data class Failure(val cause: Throwable) : BridgeSecretResult
}
