package com.chromaglow.app.core.hue.sse

import com.chromaglow.app.core.hue.rest.ApplicationKeyProvider
import com.chromaglow.app.core.hue.tls.BridgeTlsIdentity
import com.chromaglow.app.core.identity.BridgeId
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.isActive
import okhttp3.ConnectionSpec
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.IOException
import java.util.concurrent.TimeUnit

/** The stream ended with a non-2xx status. Transient for the session: NEVER a revocation trigger. */
class EventStreamHttpException(val status: Int) : IOException("event stream status $status")

/** A line exceeded the bound; the stream is dropped and reconnected by the runner. */
class EventStreamLineTooLongException : IOException("event stream line exceeds bound")

/** Missing/cleared application key: nothing is transmitted. */
class EventStreamCredentialsException : IOException("no application key")

/**
 * Production [EventStreamSource]: `GET https://{host}/eventstream/clip/v2` with
 * `Accept: text/event-stream` and the application key, over the SAME [BridgeTlsIdentity] the
 * REST client uses (bundled-CA trust + hostname verifier pinned to [bridgeId]). Read timeout is
 * disabled (the bridge holds the connection open); lines are bounded at [MAX_LINE_BYTES]. The flow
 * emits [SseFrame.Connected] once the response headers arrive with a 2xx, then one
 * [SseFrame.Data] per SSE event, and completes/throws when the connection drops. Reconnection,
 * backoff and lifecycle belong to the session's runner, never here.
 */
class OkHttpEventStreamSource(
    override val bridgeId: BridgeId,
    private val host: String,
    private val port: Int = DEFAULT_PORT,
    private val keys: ApplicationKeyProvider,
    tls: BridgeTlsIdentity,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    connectTimeoutMillis: Long = 10_000L,
) : EventStreamSource {

    init {
        require(tls.bridgeId == bridgeId) { "TLS identity is pinned to a different bridge" }
    }

    private val client: OkHttpClient = OkHttpClient.Builder()
        .followRedirects(false)
        .followSslRedirects(false)
        .retryOnConnectionFailure(false)
        .connectTimeout(connectTimeoutMillis, TimeUnit.MILLISECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .writeTimeout(connectTimeoutMillis, TimeUnit.MILLISECONDS)
        .connectionSpecs(listOf(ConnectionSpec.RESTRICTED_TLS, ConnectionSpec.MODERN_TLS))
        .sslSocketFactory(tls.sslSocketFactory, tls.trustManager)
        .hostnameVerifier(tls.hostnameVerifier)
        .build()

    override fun open(): Flow<SseFrame> = flow {
        val key = keys.applicationKey()?.takeIf { !it.isCleared } ?: throw EventStreamCredentialsException()
        val url = HttpUrl.Builder().scheme("https").host(host).port(port)
            .addPathSegment("eventstream").addPathSegment("clip").addPathSegment("v2").build()
        val request = key.withHeaderValue { header ->
            Request.Builder().url(url)
                .header(APPLICATION_KEY_HEADER, header)
                .header("Accept", "text/event-stream")
                .get().build()
        }
        val call = client.newCall(request)
        try {
            call.execute().use { response ->
                if (response.code !in 200..299) throw EventStreamHttpException(response.code)
                emit(SseFrame.Connected)
                val source = response.body.source()
                val parser = SseLineParser()
                while (currentCoroutineContext().isActive) {
                    // Bounded line read: refuse a line longer than the cap before buffering it whole.
                    val newline = source.indexOf('\n'.code.toByte(), 0L, MAX_LINE_BYTES + 1L)
                    if (newline == -1L) {
                        if (source.exhausted()) break
                        if (source.request(MAX_LINE_BYTES + 1L)) throw EventStreamLineTooLongException()
                        break
                    }
                    val line = source.readUtf8(newline).trimEnd('\r')
                    source.skip(1)
                    parser.feed(line)?.let { emit(SseFrame.Data(it)) }
                }
            }
        } finally {
            call.cancel()
        }
    }.flowOn(ioDispatcher)

    companion object {
        const val MAX_LINE_BYTES: Long = 256L * 1024L
        const val DEFAULT_PORT: Int = 443
        const val APPLICATION_KEY_HEADER: String = "hue-application-key"
    }
}
