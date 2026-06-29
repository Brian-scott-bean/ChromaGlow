package com.chromaglow.app.core.hue.pairing.tls

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import java.security.MessageDigest
import java.security.cert.X509Certificate

/**
 * Instrumented test proving the bundled raw resources are exactly the two accepted Hue root CAs
 * (D-001/D-002). It loads them through the production [HueRootCertificates] loader and asserts
 * each certificate's subject distinguished name and SHA-256 fingerprint match the known-good
 * values.
 *
 * This test is COMPILED in this lane but executed by the batch owner on the shared AVD.
 */
@RunWith(AndroidJUnit4::class)
class HueRootCertificatesTest {

    private val context = ApplicationProvider.getApplicationContext<android.content.Context>()

    @Test
    fun loadsExactlyTwoCertificates() {
        val certificates = HueRootCertificates.load(context)
        assertEquals(2, certificates.size)
    }

    @Test
    fun bundledRoots_haveExpectedSubjectsAndFingerprints() {
        val certificates = HueRootCertificates.load(context)

        val first = certificates[0]
        assertEquals("CN=root-bridge,O=Philips Hue,C=NL", first.subjectX500Principal.name)
        assertEquals(
            "F0:BD:8E:65:09:E8:2F:77:4D:63:BC:00:9D:53:88:C9:69:FE:3D:CF:7D:6D:54:1D:63:51:B7:2B:89:8D:8A:CF",
            sha256Fingerprint(first),
        )

        val second = certificates[1]
        assertEquals("CN=Hue Root CA 01,O=Signify Hue,C=NL", second.subjectX500Principal.name)
        assertEquals(
            "D8:B8:94:48:B2:AF:8E:16:76:18:5A:C0:72:19:EE:9D:CB:C8:F0:1C:12:2A:02:6A:2A:4B:7B:5C:FE:03:28:B8",
            sha256Fingerprint(second),
        )
    }

    @Test
    fun trustManager_trustsExactlyTheTwoBundledRoots() {
        val certificates = HueRootCertificates.load(context).toSet()
        val trustManager = HueRootCertificates.trustManager(context)

        val accepted = trustManager.acceptedIssuers.toSet()
        assertEquals(certificates, accepted)
    }

    private fun sha256Fingerprint(certificate: X509Certificate): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(certificate.encoded)
        return digest.joinToString(":") { byte -> "%02X".format(byte) }
    }
}
