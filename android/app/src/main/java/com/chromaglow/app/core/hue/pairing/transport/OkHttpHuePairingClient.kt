package com.chromaglow.app.core.hue.pairing.transport

import android.content.Context
import com.chromaglow.app.core.hue.discovery.BridgeEndpoint
import com.chromaglow.app.core.hue.pairing.protocol.BridgeConfig
import com.chromaglow.app.core.hue.pairing.protocol.BridgeConfigOutcome
import com.chromaglow.app.core.hue.pairing.protocol.BridgeConfigParser
import com.chromaglow.app.core.hue.pairing.protocol.CreateUserOutcome
import com.chromaglow.app.core.hue.pairing.protocol.PairingProtocol
import com.chromaglow.app.core.hue.pairing.protocol.PairingRequest
import com.chromaglow.app.core.hue.pairing.protocol.PairingResponseParser
import com.chromaglow.app.core.hue.pairing.tls.BridgeCommonNameResult
import com.chromaglow.app.core.hue.pairing.tls.HueBridgeCommonName
import com.chromaglow.app.core.hue.pairing.tls.HueLeafHostnameVerifier
import com.chromaglow.app.core.hue.pairing.tls.HueRootCertificates
import okhttp3.HttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.io.IOException
import java.security.cert.X509Certificate
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocketFactory
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager

/**
 * OkHttp-backed [HuePairingClient].
 *
 * Security posture (all enforced by construction, see [baseClient]):
 *  - HTTPS only; URLs are built with [HttpUrl], never string concatenation.
 *  - Redirects are never followed ([OkHttpClient.Builder.followRedirects]/`followSslRedirects`),
 *    so a `3xx` is refused rather than chased.
 *  - The create-user POST is never auto-retried ([OkHttpClient.Builder.retryOnConnectionFailure]
 *    is `false`).
 *  - Response bodies are bounded to [PairingProtocol.MAX_BODY_BYTES]; a larger body fails closed
 *    without being fully buffered.
 *  - A single [callTimeoutMillis] call timeout bounds each request.
 *
 * Chain trust comes from the pinned [trustManager]; SAN-less leaf identity is enforced per call by
 * a [HueLeafHostnameVerifier] carrying the expected `bridgeid`. The two TLS materials are injected
 * so the whole client is unit-testable against MockWebServer without a real bridge; production
 * callers use [fromContext].
 *
 * This client is reentrant (no shared mutable state across calls), adds NO logging, and never
 * persists anything: it neither logs nor retains response bodies, usernames, bridge ids,
 * addresses, or certificate data, and exposes no `clientkey`.
 */
class OkHttpHuePairingClient(
    private val sslSocketFactory: SSLSocketFactory,
    private val trustManager: X509TrustManager,
    callTimeoutMillis: Long = DEFAULT_CALL_TIMEOUT_MILLIS,
) : HuePairingClient {

    /**
     * Production-configured base client. The per-call [HueLeafHostnameVerifier] (which pins the
     * expected `bridgeid`) is layered on top via [OkHttpClient.newBuilder] in [pair], so a single
     * connection pool and configuration are shared across calls.
     */
    private val baseClient: OkHttpClient = OkHttpClient.Builder()
        .followRedirects(false)
        .followSslRedirects(false)
        .retryOnConnectionFailure(false)
        .callTimeout(callTimeoutMillis, TimeUnit.MILLISECONDS)
        .sslSocketFactory(sslSocketFactory, trustManager)
        .build()

    override fun pair(endpoint: BridgeEndpoint, expectedBridgeId: String?): HuePairingResult {
        // Per-call verifier pins the expected identity at the TLS layer (defense in depth with the
        // explicit application-level identity check below).
        val client = baseClient.newBuilder()
            .hostnameVerifier(HueLeafHostnameVerifier(expectedBridgeId))
            .build()

        // Step 1: probe identity via GET /api/0/config and capture the CA-validated leaf.
        val probe = when (val step = fetchConfig(client, endpoint)) {
            is Step.Ok -> step.value
            is Step.Failed -> return step.failure
        }

        val authenticatedId = when (val cn = HueBridgeCommonName.extract(probe.leaf)) {
            is BridgeCommonNameResult.Valid -> cn.bridgeId
            is BridgeCommonNameResult.Failure ->
                return HuePairingResult.Failure(PairingFailureReason.UnverifiableLeafIdentity)
        }

        val config: BridgeConfig = when (val parsed = BridgeConfigParser.parseConfig(probe.body)) {
            is BridgeConfigOutcome.Parsed -> parsed.config
            is BridgeConfigOutcome.Malformed ->
                return HuePairingResult.Failure(
                    PairingFailureReason.MalformedResponse(PairingStage.CONFIG, parsed.reason),
                )
        }

        // The authenticated identity is the leaf CN. The config's bridgeid AND any caller hint must
        // both agree with it (case-insensitively). Any mismatch fails closed BEFORE the POST.
        if (!config.bridgeId.equals(authenticatedId, ignoreCase = true)) {
            return HuePairingResult.Failure(PairingFailureReason.IdentityMismatch)
        }
        if (expectedBridgeId != null && !expectedBridgeId.equals(authenticatedId, ignoreCase = true)) {
            return HuePairingResult.Failure(PairingFailureReason.IdentityMismatch)
        }

        // Step 2: only now request an application key via POST /api.
        val createBody = when (val step = createUser(client, endpoint)) {
            is Step.Ok -> step.value
            is Step.Failed -> return step.failure
        }
        return mapCreateUserOutcome(PairingResponseParser.parseCreateUser(createBody))
    }

    /**
     * Performs `GET /api/0/config`. Yields the bounded body paired with the CA-validated leaf
     * certificate, or a typed failure (transport error, non-2xx/redirect, oversized body, or a
     * missing/non-X.509 leaf).
     */
    private fun fetchConfig(client: OkHttpClient, endpoint: BridgeEndpoint): Step<ConfigProbe> {
        val url = httpsUrl(endpoint).addPathSegment("api").addPathSegment("0").addPathSegment("config").build()
        val request = Request.Builder().url(url).get().build()
        return try {
            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) {
                    return failed(PairingFailureReason.UnexpectedHttpStatus(PairingStage.CONFIG, response.code))
                }
                val body = readBoundedBody(response)
                    ?: return failed(PairingFailureReason.ResponseTooLarge(PairingStage.CONFIG))
                val leaf = response.handshake?.peerCertificates?.firstOrNull() as? X509Certificate
                    ?: return failed(PairingFailureReason.UnverifiableLeafIdentity)
                Step.Ok(ConfigProbe(body = body, leaf = leaf))
            }
        } catch (_: IOException) {
            failed(PairingFailureReason.TransportError)
        }
    }

    /**
     * Performs `POST /api` with the Lane B request body. Yields the bounded response body, or a
     * typed failure (transport error, non-2xx, or oversized body).
     */
    private fun createUser(client: OkHttpClient, endpoint: BridgeEndpoint): Step<String> {
        val url = httpsUrl(endpoint).addPathSegment("api").build()
        val body = PairingRequest.createUserBody().toRequestBody(JSON_MEDIA_TYPE)
        val request = Request.Builder().url(url).post(body).build()
        return try {
            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) {
                    return failed(PairingFailureReason.UnexpectedHttpStatus(PairingStage.CREATE_USER, response.code))
                }
                val responseBody = readBoundedBody(response)
                    ?: return failed(PairingFailureReason.ResponseTooLarge(PairingStage.CREATE_USER))
                Step.Ok(responseBody)
            }
        } catch (_: IOException) {
            failed(PairingFailureReason.TransportError)
        }
    }

    private fun mapCreateUserOutcome(outcome: CreateUserOutcome): HuePairingResult =
        when (outcome) {
            is CreateUserOutcome.Success -> HuePairingResult.Success(outcome.username)
            CreateUserOutcome.LinkButtonNotPressed -> HuePairingResult.LinkButtonNotPressed
            CreateUserOutcome.InvalidRequest ->
                HuePairingResult.Failure(PairingFailureReason.InvalidRequest)
            is CreateUserOutcome.UnknownError ->
                HuePairingResult.Failure(PairingFailureReason.BridgeError(outcome.type, outcome.description))
            is CreateUserOutcome.Malformed ->
                HuePairingResult.Failure(
                    PairingFailureReason.MalformedResponse(PairingStage.CREATE_USER, outcome.reason),
                )
        }

    /**
     * Reads at most [PairingProtocol.MAX_BODY_BYTES] bytes from the response body and returns the
     * decoded UTF-8 string, or `null` if the body is larger than the cap (fail closed).
     *
     * Bounded by construction: `BufferedSource.request` reads from the socket only until the buffer
     * holds `cap + 1` bytes, so a hostile or runaway endpoint can never force unbounded buffering —
     * the oversize case is detected and rejected without reading the remainder.
     */
    private fun readBoundedBody(response: Response): String? {
        val source = response.body.source()
        if (source.request(PairingProtocol.MAX_BODY_BYTES.toLong() + 1L)) {
            return null
        }
        return source.readUtf8()
    }

    private fun httpsUrl(endpoint: BridgeEndpoint): HttpUrl.Builder =
        HttpUrl.Builder()
            .scheme("https")
            .host(endpoint.host)
            .port(endpoint.port)

    /** GET /api/0/config result: the bounded body plus the CA-validated leaf certificate. */
    private data class ConfigProbe(val body: String, val leaf: X509Certificate)

    /** Internal short-circuit carrier so request helpers stay non-throwing and reentrant. */
    private sealed interface Step<out T> {
        data class Ok<T>(val value: T) : Step<T>
        data class Failed(val failure: HuePairingResult.Failure) : Step<Nothing>
    }

    private fun failed(reason: PairingFailureReason): Step.Failed =
        Step.Failed(HuePairingResult.Failure(reason))

    companion object {
        /** Default per-request call timeout: 10 seconds. */
        const val DEFAULT_CALL_TIMEOUT_MILLIS: Long = 10_000L

        private val JSON_MEDIA_TYPE = "application/json".toMediaType()

        /**
         * Production factory: wires the pinned Hue root [trustManager] from bundled resources and
         * derives a matching client [SSLSocketFactory] from it (no client keys, trust only).
         */
        fun fromContext(context: Context): HuePairingClient {
            val trustManager = HueRootCertificates.trustManager(context)
            val sslContext = SSLContext.getInstance("TLS").apply {
                init(null, arrayOf<TrustManager>(trustManager), null)
            }
            return OkHttpHuePairingClient(sslContext.socketFactory, trustManager)
        }
    }
}
