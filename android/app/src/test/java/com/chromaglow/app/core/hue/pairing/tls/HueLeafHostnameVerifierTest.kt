package com.chromaglow.app.core.hue.pairing.tls

import okhttp3.tls.HeldCertificate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for the pure [verifyLeafIdentity] contract and the [HueLeafHostnameVerifier]
 * adapter.
 *
 * The identity logic lives entirely in [verifyLeafIdentity], which is exercised exhaustively
 * here against real ([HeldCertificate]-generated) leaf certificates. The [javax.net.ssl.SSLSession]
 * adapter is a thin delegation; it is covered minimally via its degenerate null-session path
 * (a full hand-rolled `SSLSession` is avoided because JDK 21 removed `javax.security.cert`,
 * which `SSLSession.getPeerCertificateChain()` references).
 */
class HueLeafHostnameVerifierTest {

    private val bridgeId = "001788FFFE112233"

    private fun leaf(commonName: String): HeldCertificate =
        HeldCertificate.Builder()
            .commonName(commonName)
            .ecdsa256()
            .build()

    @Test
    fun validLeaf_noExpectedId_isTrusted() {
        val result = verifyLeafIdentity(leaf(bridgeId).certificate, expectedBridgeId = null)
        assertEquals(LeafIdentityResult.Trusted(bridgeId), result)
    }

    @Test
    fun lowercaseLeaf_isTrustedAndNormalized() {
        val result = verifyLeafIdentity(leaf("001788fffe112233").certificate, expectedBridgeId = null)
        assertEquals(LeafIdentityResult.Trusted("001788FFFE112233"), result)
    }

    @Test
    fun expectedIdMatchingCaseInsensitively_isTrusted() {
        val result = verifyLeafIdentity(leaf(bridgeId).certificate, expectedBridgeId = "001788fffe112233")
        assertEquals(LeafIdentityResult.Trusted(bridgeId), result)
    }

    @Test
    fun expectedIdMismatch_isRejected() {
        val expected = "AABBCCDDEEFF0011"
        val result = verifyLeafIdentity(leaf(bridgeId).certificate, expectedBridgeId = expected)
        assertEquals(LeafIdentityResult.BridgeIdMismatch(expected = expected, actual = bridgeId), result)
    }

    @Test
    fun malformedLeafCommonName_isCommonNameRejected() {
        val result = verifyLeafIdentity(leaf("not-a-bridge-id").certificate, expectedBridgeId = null)
        assertTrue(result is LeafIdentityResult.CommonNameRejected)
        assertTrue(
            (result as LeafIdentityResult.CommonNameRejected).reason
                is BridgeCommonNameResult.MalformedCommonName,
        )
    }

    @Test
    fun hostnameVerifier_withNullSession_returnsFalse() {
        // The adapter must never be blanket-true: a degenerate session yields false.
        assertFalse(HueLeafHostnameVerifier().verify("dummy.invalid", null))
        assertFalse(HueLeafHostnameVerifier(expectedBridgeId = bridgeId).verify("dummy.invalid", null))
    }
}
