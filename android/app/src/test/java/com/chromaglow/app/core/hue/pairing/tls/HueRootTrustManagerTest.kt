package com.chromaglow.app.core.hue.pairing.tls

import okhttp3.tls.HeldCertificate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.cert.CertificateException
import java.security.cert.X509Certificate

/**
 * Unit tests for [HueRootTrustManager]. Certificate material is generated with okhttp-tls
 * ([HeldCertificate], default ECDSA P-256), so the negotiated server authType is
 * `"ECDHE_ECDSA"`. The trust manager must trust ONLY the injected CA anchors with no
 * system/user fallback.
 */
class HueRootTrustManagerTest {

    private val ecdhEcdsaAuthType = "ECDHE_ECDSA"
    private val bridgeId = "001788FFFE112233"

    private fun ca(commonName: String): HeldCertificate =
        HeldCertificate.Builder()
            .certificateAuthority(0)
            .commonName(commonName)
            .ecdsa256()
            .build()

    private fun leafSignedBy(
        issuer: HeldCertificate,
        commonName: String = bridgeId,
    ): HeldCertificate =
        HeldCertificate.Builder()
            .commonName(commonName)
            .signedBy(issuer)
            .ecdsa256()
            .build()

    @Test
    fun emptyCaList_isRejected() {
        assertThrows(IllegalArgumentException::class.java) {
            HueRootTrustManager.fromCertificateAuthorities(emptyList())
        }
    }

    @Test
    fun leafSignedByTrustedCa_isAccepted_andIdentityVerifies() {
        val rootCa = ca("Test Hue Root CA")
        val leaf = leafSignedBy(rootCa)
        val trustManager = HueRootTrustManager.fromCertificateAuthorities(listOf(rootCa.certificate))

        // Chain validation must NOT throw.
        trustManager.checkServerTrusted(arrayOf(leaf.certificate), ecdhEcdsaAuthType)

        // And the leaf must satisfy the SAN-less identity contract.
        assertEquals(
            LeafIdentityResult.Trusted(bridgeId),
            verifyLeafIdentity(leaf.certificate, expectedBridgeId = null),
        )
    }

    @Test
    fun leafSignedBySecondOfTwoTrustedCas_isAccepted() {
        val firstCa = ca("First Hue Root CA")
        val secondCa = ca("Second Hue Root CA")
        val leaf = leafSignedBy(secondCa)
        val trustManager = HueRootTrustManager.fromCertificateAuthorities(
            listOf(firstCa.certificate, secondCa.certificate),
        )

        trustManager.checkServerTrusted(arrayOf(leaf.certificate), ecdhEcdsaAuthType)
    }

    @Test
    fun leafSignedByUntrustedCa_throws() {
        val trustedCa = ca("Trusted Hue Root CA")
        val rogueCa = ca("Rogue CA")
        val leaf = leafSignedBy(rogueCa)
        val trustManager = HueRootTrustManager.fromCertificateAuthorities(listOf(trustedCa.certificate))

        assertThrows(CertificateException::class.java) {
            trustManager.checkServerTrusted(arrayOf(leaf.certificate), ecdhEcdsaAuthType)
        }
    }

    @Test
    fun selfSignedLeaf_notChainingToTrustedCa_throws() {
        val trustedCa = ca("Trusted Hue Root CA")
        val selfSigned = HeldCertificate.Builder()
            .commonName(bridgeId)
            .ecdsa256()
            .build()
        val trustManager = HueRootTrustManager.fromCertificateAuthorities(listOf(trustedCa.certificate))

        assertThrows(CertificateException::class.java) {
            trustManager.checkServerTrusted(arrayOf(selfSigned.certificate), ecdhEcdsaAuthType)
        }
    }

    @Test
    fun expiredLeaf_throws() {
        val rootCa = ca("Test Hue Root CA")
        val now = System.currentTimeMillis()
        val expiredLeaf = HeldCertificate.Builder()
            .commonName(bridgeId)
            .signedBy(rootCa)
            .ecdsa256()
            .validityInterval(now - 2 * DAY_MILLIS, now - DAY_MILLIS)
            .build()
        val trustManager = HueRootTrustManager.fromCertificateAuthorities(listOf(rootCa.certificate))

        assertThrows(CertificateException::class.java) {
            trustManager.checkServerTrusted(arrayOf(expiredLeaf.certificate), ecdhEcdsaAuthType)
        }
    }

    @Test
    fun trustManager_acceptedIssuers_areExactlyTheInjectedAnchors() {
        val rootCa = ca("Test Hue Root CA")
        val trustManager = HueRootTrustManager.fromCertificateAuthorities(listOf(rootCa.certificate))

        val acceptedSubjects = trustManager.acceptedIssuers.map { it.subjectX500Principal }
        assertEquals(1, trustManager.acceptedIssuers.size)
        assertTrue(acceptedSubjects.contains(rootCa.certificate.subjectX500Principal))
    }

    @Test
    fun lowercaseLeafCommonName_isNormalizedByIdentityVerifier() {
        val rootCa = ca("Test Hue Root CA")
        val leaf = leafSignedBy(rootCa, commonName = "001788fffe112233")
        val trustManager = HueRootTrustManager.fromCertificateAuthorities(listOf(rootCa.certificate))

        trustManager.checkServerTrusted(arrayOf<X509Certificate>(leaf.certificate), ecdhEcdsaAuthType)
        assertEquals(
            LeafIdentityResult.Trusted("001788FFFE112233"),
            verifyLeafIdentity(leaf.certificate, expectedBridgeId = null),
        )
    }

    private companion object {
        const val DAY_MILLIS = 24L * 60 * 60 * 1000
    }
}
