package com.chromaglow.app.core.credentials

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class BridgeCredentialAliasTest {
    @Test
    fun sameBridgeId_returnsStableAliasAndFilename() {
        val bridgeId = "550e8400-e29b-41d4-a716-446655440000"

        val aliasOne = BridgeCredentialAlias.keystoreAlias(bridgeId)
        val aliasTwo = BridgeCredentialAlias.keystoreAlias(bridgeId)
        val fileOne = BridgeCredentialAlias.ciphertextFileName(bridgeId)
        val fileTwo = BridgeCredentialAlias.ciphertextFileName(bridgeId)

        assertEquals(aliasOne, aliasTwo)
        assertEquals(fileOne, fileTwo)
        assertEquals(
            "chromaglow.bridge.$bridgeId.api_token",
            aliasOne,
        )
        assertEquals("bridge_$bridgeId.api_token.enc", fileOne)
    }

    @Test
    fun differentBridgeIds_returnDifferentAliasAndFilename() {
        val firstAlias = BridgeCredentialAlias.keystoreAlias("bridge-alpha")
        val secondAlias = BridgeCredentialAlias.keystoreAlias("bridge-beta")
        val firstFile = BridgeCredentialAlias.ciphertextFileName("bridge-alpha")
        val secondFile = BridgeCredentialAlias.ciphertextFileName("bridge-beta")

        assertNotEquals(firstAlias, secondAlias)
        assertNotEquals(firstFile, secondFile)
    }

    @Test
    fun syntheticUuidLikeBridgeId_isAccepted() {
        val bridgeId = "550e8400-e29b-41d4-a716-446655440000"

        BridgeCredentialAlias.validateBridgeId(bridgeId)
        BridgeCredentialAlias.keystoreAlias(bridgeId)
        BridgeCredentialAlias.ciphertextFileName(bridgeId)
    }

    @Test(expected = IllegalArgumentException::class)
    fun blankBridgeId_isRejected() {
        BridgeCredentialAlias.validateBridgeId("   ")
    }

    @Test(expected = IllegalArgumentException::class)
    fun dotInBridgeId_isRejected() {
        BridgeCredentialAlias.validateBridgeId("bridge.id")
    }

    @Test(expected = IllegalArgumentException::class)
    fun slashInBridgeId_isRejected() {
        BridgeCredentialAlias.validateBridgeId("bridge/id")
    }

    @Test(expected = IllegalArgumentException::class)
    fun backslashInBridgeId_isRejected() {
        BridgeCredentialAlias.validateBridgeId("bridge\\id")
    }

    @Test(expected = IllegalArgumentException::class)
    fun whitespaceInBridgeId_isRejected() {
        BridgeCredentialAlias.validateBridgeId("bridge id")
    }

    @Test(expected = IllegalArgumentException::class)
    fun pathTraversalForm_isRejected() {
        BridgeCredentialAlias.validateBridgeId("..")
    }
}
