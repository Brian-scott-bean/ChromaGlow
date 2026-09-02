package com.chromaglow.app.core.hue.tls

import com.chromaglow.app.core.hue.pairing.tls.BridgeCommonNameResult
import com.chromaglow.app.core.hue.pairing.tls.HueBridgeCommonName
import com.chromaglow.app.core.identity.BridgeId
import java.security.cert.X509Certificate
import javax.net.ssl.HostnameVerifier
import javax.net.ssl.SSLPeerUnverifiedException
import javax.net.ssl.SSLSession

/**
 * The typed verdict of the certificate-CN identity boundary for an authenticated (REST/SSE)
 * connection. Only [Match] permits the connection to proceed; every other verdict is fail-closed
 * and, because it is decided inside the TLS hostname verifier, is reached BEFORE any request
 * header (and therefore before the `hue-application-key`) is written to the socket.
 */
sealed interface LeafIdentityVerdict {
    /** The CA-validated leaf names exactly the bridge this connection is pinned to. */
    data class Match(val bridgeId: BridgeId) : LeafIdentityVerdict

    /** The leaf is a well-formed Hue leaf, but for a DIFFERENT bridge. */
    data class Mismatch(val expected: BridgeId, val presented: BridgeId) : LeafIdentityVerdict

    /** The leaf subject does not carry exactly one 16-hex `CN` (missing, multiple, or malformed). */
    data class Malformed(val reason: BridgeCommonNameResult.Failure) : LeafIdentityVerdict

    /** No verified peer certificate is available on the session (null session / unverified peer). */
    data object NoVerifiedPeer : LeafIdentityVerdict
}

/**
 * The ONE place a Hue certificate Common Name becomes a [BridgeId].
 *
 * Case rule (mandatory): real bridges present the 16-hex `bridgeid` in either case. [BridgeId]
 * itself never normalises — `BridgeId.parseOrNull("001788fffe112233")` is null by contract — so
 * the normalisation lives HERE, at the trusted external boundary, and nowhere else: a CN is
 * validated as exactly 16 hex characters in any case, canonicalised to UPPERCASE, wrapped as a
 * [BridgeId], and compared by value to the expected [BridgeId]. Anything else fails closed.
 *
 * Chain-of-trust and validity are the trust manager's job ([HueTrust]); this object inspects only
 * the already-authenticated leaf.
 */
object BridgeLeafIdentity {

    /** Exactly 16 hex characters, either case. */
    private val CN_SHAPE = Regex("^[0-9A-Fa-f]{16}$")

    /**
     * Canonicalise a raw CN value into a [BridgeId], or null when it is not exactly 16 hex
     * characters. Uppercasing happens only after the shape check, so no other text is ever
     * "normalised" into an id.
     */
    fun canonicalize(commonName: String): BridgeId? {
        if (!CN_SHAPE.matches(commonName)) return null
        return BridgeId.parseOrNull(commonName.uppercase())
    }

    /** Verify an X.509 leaf against the bridge id this connection is pinned to. */
    fun verify(leaf: X509Certificate, expected: BridgeId): LeafIdentityVerdict =
        when (val cn = HueBridgeCommonName.extract(leaf)) {
            is BridgeCommonNameResult.Valid -> {
                // extract() already validated the 16-hex shape and uppercased; canonicalize()
                // re-applies the shape rule so a future change in the extractor cannot widen
                // what becomes a BridgeId here.
                val presented = canonicalize(cn.bridgeId)
                when {
                    presented == null -> LeafIdentityVerdict.Malformed(
                        BridgeCommonNameResult.MalformedCommonName(cn.bridgeId),
                    )
                    presented == expected -> LeafIdentityVerdict.Match(presented)
                    else -> LeafIdentityVerdict.Mismatch(expected = expected, presented = presented)
                }
            }

            is BridgeCommonNameResult.Failure -> LeafIdentityVerdict.Malformed(cn)
        }

    /** Verify the peer leaf of an [SSLSession]; a null/unverified session is [LeafIdentityVerdict.NoVerifiedPeer]. */
    fun verify(session: SSLSession?, expected: BridgeId): LeafIdentityVerdict {
        if (session == null) return LeafIdentityVerdict.NoVerifiedPeer
        val peer = try {
            session.peerCertificates
        } catch (_: SSLPeerUnverifiedException) {
            return LeafIdentityVerdict.NoVerifiedPeer
        }
        val leaf = peer.firstOrNull() as? X509Certificate ?: return LeafIdentityVerdict.NoVerifiedPeer
        return verify(leaf, expected)
    }
}

/**
 * OkHttp/JSSE hostname verifier pinned to ONE [BridgeId]. Hue leaves are SAN-less, so the
 * platform's RFC 6125 verifier can never accept them; this verifier answers `true` ONLY for
 * [LeafIdentityVerdict.Match]. It is never blanket-true and never consults the hostname.
 *
 * Because OkHttp runs the hostname verifier as part of connection establishment, a failing
 * verdict aborts the connection before the request line and headers are written: the
 * application key is never transmitted across an identity mismatch (pinned by test).
 */
class BridgeIdHostnameVerifier(val expected: BridgeId) : HostnameVerifier {

    /** The last verdict this verifier produced; diagnostic only, secret-free. */
    @Volatile
    var lastVerdict: LeafIdentityVerdict? = null
        private set

    override fun verify(hostname: String?, session: SSLSession?): Boolean {
        val verdict = BridgeLeafIdentity.verify(session, expected)
        lastVerdict = verdict
        return verdict is LeafIdentityVerdict.Match
    }
}
