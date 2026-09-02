package com.chromaglow.app.core.hue.rest

import com.chromaglow.app.core.hue.tls.BridgeTlsIdentity
import com.chromaglow.app.core.identity.BridgeId
import com.chromaglow.app.core.identity.ResourceId
import com.chromaglow.app.core.identity.ResourceType
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import okhttp3.Call
import okhttp3.Callback
import okhttp3.ConnectionSpec
import okhttp3.EventListener
import okhttp3.HttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.io.IOException
import java.io.InterruptedIOException
import java.net.InetSocketAddress
import java.net.Proxy
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLPeerUnverifiedException
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * The production [HueClipClient]: authenticated CLIP v2 over HTTPS to exactly ONE bridge.
 *
 *  - `https://{host}:{port}` (443), `hue-application-key`, JSON; `callTimeout` 10 s.
 *  - TLS from [BridgeTlsIdentity]: bundled-CA-only trust + hostname verifier pinned to
 *    [bridgeId]. A leaf for another bridge aborts the handshake BEFORE any header is written, so
 *    the key is never transmitted across an identity mismatch ([ClipError.TlsIdentity]).
 *  - RESTRICTED/MODERN TLS specs only; no cleartext; no redirects; no automatic retry
 *    (`retryOnConnectionFailure=false`), and this class never re-issues a request itself — a PUT
 *    is sent at most once per call.
 *  - Response bodies are bounded at [MAX_BODY_BYTES]; an oversize body is a decode failure.
 *  - [ClipError.Timeout.afterTransmission] is decided from OkHttp's [EventListener]: true only
 *    once the request body (or, for a bodiless GET, the headers) was handed to the socket.
 *  - The key is materialised per request and never logged; [diagnostics] receives redacted,
 *    secret-free lines only (method + path + outcome).
 */
class OkHttpHueClipClient(
    override val bridgeId: BridgeId,
    private val host: String,
    private val port: Int = DEFAULT_PORT,
    private val keys: ApplicationKeyProvider,
    tls: BridgeTlsIdentity,
    callTimeoutMillis: Long = DEFAULT_CALL_TIMEOUT_MILLIS,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val diagnostics: (String) -> Unit = {},
) : HueClipClient {

    init {
        require(tls.bridgeId == bridgeId) { "TLS identity is pinned to a different bridge" }
        require(host.isNotBlank()) { "host must not be blank" }
        require(port in 1..65535) { "port out of range" }
    }

    /** Per-call transmission facts, filled by [TransmissionListener]. */
    internal class Transmission {
        @Volatile var headersSent = false
        @Volatile var bodySent = false
        @Volatile var hasBody = false
        /** Set when any connection attempt of this call was refused by the pinned hostname verifier. */
        @Volatile var identityRejected = false
        val transmitted: Boolean get() = if (hasBody) bodySent else headersSent
    }

    private class TransmissionListener : EventListener() {
        override fun requestHeadersEnd(call: Call, request: Request) {
            call.request().tag(Transmission::class.java)?.headersSent = true
        }

        override fun requestBodyEnd(call: Call, byteCount: Long) {
            call.request().tag(Transmission::class.java)?.bodySent = true
        }

        override fun connectFailed(call: Call, inetSocketAddress: InetSocketAddress, proxy: Proxy, protocol: Protocol?, ioe: IOException) {
            if (ioe.isIdentityRejection()) call.request().tag(Transmission::class.java)?.identityRejected = true
        }
    }

    private val client: OkHttpClient = OkHttpClient.Builder()
        .followRedirects(false)
        .followSslRedirects(false)
        .retryOnConnectionFailure(false)
        .callTimeout(callTimeoutMillis, TimeUnit.MILLISECONDS)
        .connectionSpecs(listOf(ConnectionSpec.RESTRICTED_TLS, ConnectionSpec.MODERN_TLS))
        .sslSocketFactory(tls.sslSocketFactory, tls.trustManager)
        .hostnameVerifier(tls.hostnameVerifier)
        .eventListener(TransmissionListener())
        .build()

    override suspend fun getResources(type: ResourceType): ClipResult<ClipDocument> =
        execute("GET", path(type, null), body = null)

    override suspend fun getResource(type: ResourceType, id: ResourceId): ClipResult<ClipDocument> =
        execute("GET", path(type, id), body = null)

    override suspend fun putResource(type: ResourceType, id: ResourceId, body: ClipWriteBody): ClipResult<ClipDocument> =
        execute("PUT", path(type, id), body = body.json.toString())

    private fun path(type: ResourceType, id: ResourceId?): List<String> =
        listOf("clip", "v2", "resource", type.wireName) + listOfNotNull(id?.value)

    private suspend fun execute(method: String, segments: List<String>, body: String?): ClipResult<ClipDocument> {
        val key = keys.applicationKey()?.takeIf { !it.isCleared } ?: return ClipResult.Err(ClipError.MissingCredentials)
        val transmission = Transmission().apply { hasBody = body != null }
        val label = "$method /${segments.joinToString("/")}"
        return withContext(ioDispatcher) {
            try {
                // URL construction stays INSIDE the try: a hostile/damaged record host must become a
                // typed Transport failure, never an uncaught IllegalArgumentException (A-01).
                val url = HttpUrl.Builder().scheme("https").host(host).port(port).apply {
                    segments.forEach { addPathSegment(it) }
                }.build()
                val request = key.withHeaderValue { headerValue ->
                    Request.Builder()
                        .url(url)
                        .header(APPLICATION_KEY_HEADER, headerValue)
                        .header("Accept", "application/json")
                        .tag(Transmission::class.java, transmission)
                        .apply {
                            if (body != null) method(method, body.toRequestBody(JSON)) else method(method, null)
                        }
                        .build()
                }
                client.newCall(request).await().use { response -> classify(response, label) }
            } catch (e: IOException) {
                val error = mapIo(e, transmission)
                diagnostics(Redactor.redact("$label -> ${error::class.simpleName} (${e::class.simpleName})"))
                ClipResult.Err(error)
            } catch (e: IllegalArgumentException) {
                diagnostics(Redactor.redact("$label -> Transport (invalid host)"))
                ClipResult.Err(ClipError.Transport(afterTransmission = false))
            }
        }
    }

    private fun classify(response: Response, label: String): ClipResult<ClipDocument> {
        val code = response.code
        val result: ClipResult<ClipDocument> = when {
            code == 401 || code == 403 -> ClipResult.Err(ClipError.Unauthorized(code))
            code == 429 -> ClipResult.Err(ClipError.RateLimited)
            code !in 200..299 -> ClipResult.Err(ClipError.Http(code))
            else -> {
                val text = readBounded(response)
                if (text == null) {
                    ClipResult.Err(ClipError.Decode("response body exceeds ${MAX_BODY_BYTES} bytes"))
                } else {
                    ClipEnvelopeParser.toResult(ClipEnvelopeParser.parse(text))
                }
            }
        }
        val outcome = when (result) {
            is ClipResult.Ok -> "ok(${result.value.data.size})"
            is ClipResult.Err -> result.error::class.simpleName ?: "error"
        }
        diagnostics(Redactor.redact("$label -> $code $outcome"))
        return result
    }

    /** Null when the body is larger than [MAX_BODY_BYTES]; never buffers past the bound + 1. */
    private fun readBounded(response: Response): String? {
        val source = response.body.source()
        if (source.request(MAX_BODY_BYTES + 1L)) return null
        return source.readUtf8()
    }

    /**
     * Every IOException is classified with the transmission facts: once the body (or, for a
     * bodiless call, the headers) was handed to the socket, the bridge MAY have applied the
     * request, and the error says so (E-03). Only a hostname-verifier rejection is TlsIdentity.
     */
    private fun mapIo(e: IOException, transmission: Transmission): ClipError = when {
        transmission.identityRejected || e.isIdentityRejection() -> ClipError.TlsIdentity
        e is InterruptedIOException || e.message?.contains("timeout", ignoreCase = true) == true ->
            ClipError.Timeout(afterTransmission = transmission.transmitted)
        else -> ClipError.Transport(afterTransmission = transmission.transmitted)
    }

    /** Coroutine bridge for OkHttp's async call; cancelling the coroutine cancels the call. */
    private suspend fun Call.await(): Response = suspendCancellableCoroutine { cont ->
        enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                if (cont.isCancelled) return
                cont.resumeWithException(e)
            }

            override fun onResponse(call: Call, response: Response) {
                cont.resume(response)
            }
        })
        cont.invokeOnCancellation { cancel() }
    }

    companion object {
        /** True when this exception, any cause, or any suppressed exception is a hostname-verifier rejection. */
        private fun Throwable.isIdentityRejection(): Boolean {
            val seen = HashSet<Throwable>()
            val queue = ArrayDeque<Throwable>().apply { add(this@isIdentityRejection) }
            while (queue.isNotEmpty()) {
                val t = queue.removeFirst()
                if (!seen.add(t)) continue
                if (t is SSLPeerUnverifiedException) return true
                t.cause?.let { queue.add(it) }
                t.suppressed.forEach { queue.add(it) }
            }
            return false
        }

        const val DEFAULT_PORT: Int = 443
        const val DEFAULT_CALL_TIMEOUT_MILLIS: Long = 10_000L
        const val MAX_BODY_BYTES: Long = 1L shl 20
        const val APPLICATION_KEY_HEADER: String = "hue-application-key"
        private val JSON = "application/json".toMediaType()
    }
}
