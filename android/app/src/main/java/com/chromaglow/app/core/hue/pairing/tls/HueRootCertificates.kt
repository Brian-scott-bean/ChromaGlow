package com.chromaglow.app.core.hue.pairing.tls

import android.content.Context
import com.chromaglow.app.R
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import javax.net.ssl.X509TrustManager

/**
 * Loads the two bundled Philips/Signify Hue root CA certificates from raw resources.
 *
 * This is the ONLY Android-`Context`-dependent production code in this package; everything else
 * is pure JVM so it stays unit-testable. The bundled bytes are verified (subject + SHA-256
 * fingerprint) by the instrumented test for this package.
 */
object HueRootCertificates {

    /**
     * Raw-resource ids of the two accepted Hue roots, in a stable order:
     *  - [R.raw.hue_root_bridge]: `C=NL, O=Philips Hue, CN=root-bridge`
     *  - [R.raw.hue_root_ca_01]: `C=NL, O=Signify Hue, CN=Hue Root CA 01`
     */
    private val ROOT_RESOURCE_IDS = intArrayOf(
        R.raw.hue_root_bridge,
        R.raw.hue_root_ca_01,
    )

    /** Load both bundled Hue root CA certificates as [X509Certificate]s. */
    fun load(context: Context): List<X509Certificate> {
        val certificateFactory = CertificateFactory.getInstance("X.509")
        return ROOT_RESOURCE_IDS.map { resourceId ->
            context.resources.openRawResource(resourceId).use { input ->
                certificateFactory.generateCertificate(input) as X509Certificate
            }
        }
    }

    /**
     * Convenience that loads the bundled roots and builds an [X509TrustManager] anchored to
     * exactly those two CAs (no system/user fallback) via [HueRootTrustManager].
     */
    fun trustManager(context: Context): X509TrustManager =
        HueRootTrustManager.fromCertificateAuthorities(load(context))
}
