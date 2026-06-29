package com.chromaglow.app.core.hue.pairing.tls

import java.security.cert.X509Certificate
import javax.net.ssl.HostnameVerifier
import javax.net.ssl.SSLPeerUnverifiedException
import javax.net.ssl.SSLSession

/**
 * Outcome of verifying a leaf certificate's SAN-less Hue identity.
 */
sealed interface LeafIdentityResult {

    /** The leaf satisfies the identity contract; carries the normalized UPPERCASE bridge id. */
    data class Trusted(val bridgeId: String) : LeafIdentityResult

    /** The leaf does not satisfy the identity contract. */
    sealed interface Rejected : LeafIdentityResult

    /** The leaf's Common Name failed the [HueBridgeCommonName] contract. */
    data class CommonNameRejected(val reason: BridgeCommonNameResult.Failure) : Rejected

    /** The leaf carried a valid bridge id but it did not match the expected one. */
    data class BridgeIdMismatch(val expected: String, val actual: String) : Rejected
}

/**
 * Pure leaf-identity contract for SAN-less Hue bridge leaf certificates.
 *
 * Hue bridge leaves currently carry no Subject Alternative Names, so the standard
 * hostname-based [HostnameVerifier] cannot match them. Instead the leaf is identified by its
 * subject Common Name (the 16-hex `bridgeid`). Chain-of-trust and validity are enforced
 * separately by [HueRootTrustManager]; this function ONLY runs the identity contract and never
 * returns a blanket success.
 */
fun verifyLeafIdentity(leaf: X509Certificate, expectedBridgeId: String?): LeafIdentityResult {
    return when (val commonName = HueBridgeCommonName.extract(leaf)) {
        is BridgeCommonNameResult.Valid -> {
            if (expectedBridgeId == null || commonName.bridgeId.equals(expectedBridgeId, ignoreCase = true)) {
                LeafIdentityResult.Trusted(commonName.bridgeId)
            } else {
                LeafIdentityResult.BridgeIdMismatch(
                    expected = expectedBridgeId.uppercase(),
                    actual = commonName.bridgeId,
                )
            }
        }

        is BridgeCommonNameResult.Failure ->
            LeafIdentityResult.CommonNameRejected(commonName)
    }
}

/**
 * Narrowly-scoped [HostnameVerifier] for SAN-less Hue bridge leaves.
 *
 * It pulls the leaf certificate from the negotiated session and delegates to
 * [verifyLeafIdentity]. It returns `true` ONLY when the Common Name identity contract holds
 * (and, when [expectedBridgeId] is supplied, matches it case-insensitively). It is never a
 * blanket-`true` verifier: a missing/unverified peer chain, a non-X.509 leaf, or any identity
 * failure yields `false`.
 *
 * This verifier intentionally does NOT validate the certificate chain or validity window; that
 * is the job of the [HueRootTrustManager] installed on the same TLS stack.
 */
class HueLeafHostnameVerifier(
    private val expectedBridgeId: String? = null,
) : HostnameVerifier {

    override fun verify(hostname: String?, session: SSLSession?): Boolean {
        if (session == null) return false
        val peerCertificates = try {
            session.peerCertificates
        } catch (_: SSLPeerUnverifiedException) {
            return false
        }
        val leaf = peerCertificates.firstOrNull() as? X509Certificate ?: return false
        return verifyLeafIdentity(leaf, expectedBridgeId) is LeafIdentityResult.Trusted
    }
}
