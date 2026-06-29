package com.chromaglow.app.core.hue.pairing.tls

import java.security.KeyStore
import java.security.cert.X509Certificate
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager

/**
 * Builds an [X509TrustManager] that trusts EXACTLY the injected certificate authorities and
 * nothing else — no system or user CA fallback.
 *
 * This implements the accepted Hue security contract (D-001/D-002): the app pins the two
 * Philips/Signify Hue root CAs and refuses any chain that does not terminate at one of them.
 * It is deliberately pure JVM (no Android `Context`) so it is `testDebugUnitTest`-able; the
 * production roots are supplied by [HueRootCertificates].
 */
object HueRootTrustManager {

    /**
     * Create a trust manager anchored to exactly [caCertificates].
     *
     * The certificates are loaded into a fresh in-memory [KeyStore] as trusted entries and a
     * [TrustManagerFactory] is initialized from it, so the platform default anchors are NEVER
     * consulted. This is intentionally NOT a trust-all manager.
     *
     * @throws IllegalArgumentException if [caCertificates] is empty.
     */
    fun fromCertificateAuthorities(caCertificates: List<X509Certificate>): X509TrustManager {
        require(caCertificates.isNotEmpty()) {
            "At least one CA certificate is required; refusing to build an empty (trust-nothing) anchor set."
        }

        val keyStore = KeyStore.getInstance(KeyStore.getDefaultType()).apply {
            load(null, null)
            caCertificates.forEachIndexed { index, certificate ->
                setCertificateEntry("hue-ca-$index", certificate)
            }
        }

        val factory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply {
            init(keyStore)
        }

        val x509TrustManagers = factory.trustManagers.filterIsInstance<X509TrustManager>()
        check(x509TrustManagers.size == 1) {
            "Expected exactly one X509TrustManager, found ${x509TrustManagers.size}."
        }
        return x509TrustManagers.single()
    }
}
