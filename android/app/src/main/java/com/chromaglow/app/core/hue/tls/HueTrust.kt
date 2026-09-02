package com.chromaglow.app.core.hue.tls

import android.content.Context
import com.chromaglow.app.core.hue.pairing.tls.HueRootCertificates
import com.chromaglow.app.core.hue.pairing.tls.HueRootTrustManager
import com.chromaglow.app.core.identity.BridgeId
import java.security.cert.X509Certificate
import java.util.concurrent.ConcurrentHashMap
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocketFactory
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager

/**
 * Everything an authenticated connection to ONE bridge needs at the TLS layer: the CA-only socket
 * factory + trust manager (shared), and the hostname verifier pinned to that bridge's id.
 */
class BridgeTlsIdentity internal constructor(
    val bridgeId: BridgeId,
    val sslSocketFactory: SSLSocketFactory,
    val trustManager: X509TrustManager,
    val hostnameVerifier: BridgeIdHostnameVerifier,
)

/**
 * The reusable trust root for REST and SSE, built OVER the accepted pairing TLS stack
 * (D-001/D-002): trust is anchored to the bundled Hue CA roots only — platform anchors are never
 * consulted, there is no TOFU and no trust-all — and every connection is pinned to its record's
 * [BridgeId] through a per-bridge [BridgeIdHostnameVerifier].
 *
 * One verifier is cached per bridge so OkHttp's connection pool treats each bridge as one stable
 * `Address` (a fresh verifier instance per call would defeat connection reuse).
 */
class HueTrust(val trustManager: X509TrustManager) {

    val sslSocketFactory: SSLSocketFactory = SSLContext.getInstance("TLS").apply {
        init(null, arrayOf<TrustManager>(trustManager), null)
    }.socketFactory

    private val identities = ConcurrentHashMap<BridgeId, BridgeTlsIdentity>()

    /** The TLS identity for [bridgeId]; the same instance is returned for the life of this trust. */
    fun forBridge(bridgeId: BridgeId): BridgeTlsIdentity =
        identities.getOrPut(bridgeId) {
            BridgeTlsIdentity(
                bridgeId = bridgeId,
                sslSocketFactory = sslSocketFactory,
                trustManager = trustManager,
                hostnameVerifier = BridgeIdHostnameVerifier(bridgeId),
            )
        }

    companion object {
        /** Production: the two bundled Hue roots from `res/raw`. */
        fun fromContext(context: Context): HueTrust = HueTrust(HueRootCertificates.trustManager(context))

        /** Tests / injection: an explicit CA anchor set (never empty). */
        fun fromCertificateAuthorities(cas: List<X509Certificate>): HueTrust =
            HueTrust(HueRootTrustManager.fromCertificateAuthorities(cas))
    }
}
