package com.chromaglow.app.core.credentials

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class BridgeCredentialAliasTest {

    private val bridgeId = "001788FFFE112233"

    @Test
    fun sameBridgeId_returnsStableAliasAndFilename() {
        val aliasOne = BridgeCredentialAlias.keystoreAlias(bridgeId)
        val aliasTwo = BridgeCredentialAlias.keystoreAlias(bridgeId)
        val fileOne = BridgeCredentialAlias.ciphertextFileName(bridgeId)
        val fileTwo = BridgeCredentialAlias.ciphertextFileName(bridgeId)

        assertEquals(aliasOne, aliasTwo)
        assertEquals(fileOne, fileTwo)
        assertEquals("chromaglow.bridge.$bridgeId.api_token", aliasOne)
        assertEquals("bridge_$bridgeId.api_token.enc", fileOne)
    }

    @Test
    fun differentBridgeIds_returnDifferentAliasAndFilename() {
        val other = "AABBCCDDEEFF0011"

        assertNotEquals(BridgeCredentialAlias.keystoreAlias(bridgeId), BridgeCredentialAlias.keystoreAlias(other))
        assertNotEquals(
            BridgeCredentialAlias.ciphertextFileName(bridgeId),
            BridgeCredentialAlias.ciphertextFileName(other),
        )
    }

    @Test
    fun canonicalUppercaseHexId_isAccepted() {
        assertEquals(bridgeId, BridgeCredentialAlias.validateBridgeId(bridgeId))
        assertEquals("0000000000000000", BridgeCredentialAlias.validateBridgeId("0000000000000000"))
        assertEquals("FFFFFFFFFFFFFFFF", BridgeCredentialAlias.validateBridgeId("FFFFFFFFFFFFFFFF"))
    }

    // The alias contract now equals the registry's PairedBridgeRecord contract: canonical
    // UPPERCASE 16-hex only. Every looser shape the old pattern admitted is refused.

    @Test(expected = IllegalArgumentException::class)
    fun lowercaseHexId_isRejected() {
        BridgeCredentialAlias.validateBridgeId("001788fffe112233")
    }

    @Test(expected = IllegalArgumentException::class)
    fun uuidLikeId_isRejected() {
        BridgeCredentialAlias.validateBridgeId("550e8400-e29b-41d4-a716-446655440000")
    }

    @Test(expected = IllegalArgumentException::class)
    fun demoBridgeId_isRejected() {
        BridgeCredentialAlias.validateBridgeId("demo-bridge-main")
    }

    @Test(expected = IllegalArgumentException::class)
    fun fifteenHexChars_isRejected() {
        BridgeCredentialAlias.validateBridgeId("001788FFFE11223")
    }

    @Test(expected = IllegalArgumentException::class)
    fun seventeenHexChars_isRejected() {
        BridgeCredentialAlias.validateBridgeId("001788FFFE1122334")
    }

    @Test(expected = IllegalArgumentException::class)
    fun nonHexCharacter_isRejected() {
        BridgeCredentialAlias.validateBridgeId("001788FFFE11223G")
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
