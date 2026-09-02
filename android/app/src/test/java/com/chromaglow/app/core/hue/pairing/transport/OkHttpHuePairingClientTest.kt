package com.chromaglow.app.core.hue.pairing.transport

import com.chromaglow.app.core.hue.discovery.BridgeEndpoint
import com.chromaglow.app.core.hue.pairing.protocol.PairingProtocol
import com.chromaglow.app.core.hue.pairing.protocol.PairingRequest
import com.chromaglow.app.core.hue.pairing.tls.HueRootTrustManager
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.InetAddress
import java.net.Socket
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocketFactory
import javax.net.ssl.TrustManager

/**
 * Unit tests for [OkHttpHuePairingClient], exercised end-to-end against MockWebServer over HTTPS
 * with okhttp-tls test certificates. NO real network is used.
 *
 * The server presents a SAN-less leaf whose Common Name is a 16-hex test `bridgeid`, signed by a
 * test CA — mirroring real Philips Hue bridges. Trust is anchored to exactly that CA via
 * [HueRootTrustManager], and the client [javax.net.ssl.SSLSocketFactory] is derived from the same
 * trust manager. This genuinely drives redirect-refusal, the bounded-body cap, the call timeout,
 * chain-of-trust pinning, and the SAN-less leaf-identity / config-identity matching.
 */
class OkHttpHuePairingClientTest {

    private val bridgeId = "001788FFFE112233"
    private val otherBridgeId = "AABBCCDDEEFF0011"

    private val rootCa: HeldCertificate = certificateAuthority("Test Hue Root CA")

    private val servers = mutableListOf<MockWebServer>()

    @After
    fun tearDown() {
        servers.forEach { runCatching { it.close() } }
    }

    // --- Happy paths --------------------------------------------------------------------------

    @Test
    fun successfulFlow_returnsSuccessUsername_andIssuesConfigThenPost() {
        val f = fixture(leafCommonName = bridgeId)
        f.server.enqueue(json(body = configBody(bridgeId)))
        f.server.enqueue(json(body = successBody("abcdEFGH1234567890")))

        val result = f.client.pair(f.endpoint)

        // Success now carries the canonical authenticated bridge id (UPPERCASE leaf CN) alongside
        // the application key, so a caller can key durable storage on it without re-fetching.
        assertEquals(HuePairingResult.Success(bridgeId = bridgeId, username = "abcdEFGH1234567890"), result)
        assertEquals(2, f.server.requestCount)

        val configRequest = f.server.takeRequest()
        assertEquals("GET", configRequest.method)
        assertEquals("/api/0/config", configRequest.target)

        val createRequest = f.server.takeRequest()
        assertEquals("POST", createRequest.method)
        assertEquals("/api", createRequest.target)
        // The POST carries exactly the Lane B request body (devicetype only, no clientkey).
        assertEquals("""{"devicetype":"chromaglow#android"}""", createRequest.body?.utf8())
        assertEquals(PairingRequest.createUserBody(), createRequest.body?.utf8())
    }

    @Test
    fun identityMatch_isCaseInsensitive_acrossLeafConfigAndHint() {
        // Leaf CN lowercase, config uppercase, hint mixed case: all the same id → success.
        val f = fixture(leafCommonName = "001788fffe112233")
        f.server.enqueue(json(body = configBody("001788FFFE112233")))
        f.server.enqueue(json(body = successBody("key-Normalized")))

        val result = f.client.pair(f.endpoint, expectedBridgeId = "001788FffE112233")

        // The returned bridge id is the UPPERCASE-normalized canonical identity even though the
        // leaf CN was served lowercase — callers always get a consistent storage key.
        assertEquals(HuePairingResult.Success(bridgeId = "001788FFFE112233", username = "key-Normalized"), result)
        assertEquals(2, f.server.requestCount)
    }

    @Test
    fun matchingHint_isAccepted() {
        val f = fixture(leafCommonName = bridgeId)
        f.server.enqueue(json(body = configBody(bridgeId)))
        f.server.enqueue(json(body = successBody("paired")))

        val result = f.client.pair(f.endpoint, expectedBridgeId = bridgeId)

        assertEquals(HuePairingResult.Success(bridgeId = bridgeId, username = "paired"), result)
    }

    // --- Create-user outcome mapping ----------------------------------------------------------

    @Test
    fun linkButtonNotPressed_type101_isRetryable() {
        val f = fixture(leafCommonName = bridgeId)
        f.server.enqueue(json(body = configBody(bridgeId)))
        f.server.enqueue(json(body = errorBody(type = 101, description = "link button not pressed")))

        val result = f.client.pair(f.endpoint)

        assertEquals(HuePairingResult.LinkButtonNotPressed, result)
        assertTrue(result.isRetryable)
        assertEquals(2, f.server.requestCount)
    }

    @Test
    fun invalidRequest_type7_isNonRetryableFailure() {
        val f = fixture(leafCommonName = bridgeId)
        f.server.enqueue(json(body = configBody(bridgeId)))
        f.server.enqueue(json(body = errorBody(type = 7, description = "invalid")))

        val result = f.client.pair(f.endpoint)

        assertEquals(HuePairingResult.Failure(PairingFailureReason.InvalidRequest), result)
        assertTrue(!result.isRetryable)
    }

    @Test
    fun unknownErrorType_isMappedToBridgeError() {
        val f = fixture(leafCommonName = bridgeId)
        f.server.enqueue(json(body = configBody(bridgeId)))
        f.server.enqueue(json(body = errorBody(type = 4, description = "method not available")))

        val result = f.client.pair(f.endpoint)

        assertEquals(
            HuePairingResult.Failure(PairingFailureReason.BridgeError(4, "method not available")),
            result,
        )
    }

    @Test
    fun malformedCreateUserResponse_failsClosed() {
        val f = fixture(leafCommonName = bridgeId)
        f.server.enqueue(json(body = configBody(bridgeId)))
        f.server.enqueue(json(body = "this is not json"))

        val result = f.client.pair(f.endpoint)

        val reason = failureReason(result)
        assertTrue("expected MalformedResponse, was $reason", reason is PairingFailureReason.MalformedResponse)
        assertEquals(PairingStage.CREATE_USER, (reason as PairingFailureReason.MalformedResponse).stage)
    }

    // --- Config / identity failures (must NOT issue the POST) ----------------------------------

    @Test
    fun malformedConfigResponse_failsClosed_withNoPost() {
        val f = fixture(leafCommonName = bridgeId)
        f.server.enqueue(json(body = "{ not json"))

        val result = f.client.pair(f.endpoint)

        val reason = failureReason(result)
        assertTrue("expected MalformedResponse, was $reason", reason is PairingFailureReason.MalformedResponse)
        assertEquals(PairingStage.CONFIG, (reason as PairingFailureReason.MalformedResponse).stage)
        assertEquals(1, f.server.requestCount)
    }

    @Test
    fun configBridgeIdNotMatchingLeafCn_failsClosed_withNoPost() {
        // Leaf authenticates as bridgeId, but the config advertises a different id → mismatch.
        val f = fixture(leafCommonName = bridgeId)
        f.server.enqueue(json(body = configBody(otherBridgeId)))

        val result = f.client.pair(f.endpoint)

        assertEquals(HuePairingResult.Failure(PairingFailureReason.IdentityMismatch), result)
        assertEquals(1, f.server.requestCount)
    }

    @Test
    fun suppliedHintNotMatchingLeafIdentity_failsClosed_withNoPost() {
        // Leaf + config both authenticate as bridgeId, but the caller's hint is a different id.
        // The per-call hostname verifier rejects the leaf at the TLS layer → fail closed, no POST.
        val f = fixture(leafCommonName = bridgeId)
        f.server.enqueue(json(body = configBody(bridgeId)))

        val result = f.client.pair(f.endpoint, expectedBridgeId = otherBridgeId)

        assertTrue("expected Failure, was $result", result is HuePairingResult.Failure)
        assertEquals(0, f.server.requestCount)
    }

    @Test
    fun oversizedConfigBody_failsClosed_withoutFollowingPost() {
        val f = fixture(leafCommonName = bridgeId)
        // Strictly larger than the 64 KiB cap.
        f.server.enqueue(json(body = "x".repeat(PairingProtocol.MAX_BODY_BYTES + 1)))

        val result = f.client.pair(f.endpoint)

        assertEquals(
            HuePairingResult.Failure(PairingFailureReason.ResponseTooLarge(PairingStage.CONFIG)),
            result,
        )
        assertEquals(1, f.server.requestCount)
    }

    @Test
    fun redirectIsRefused_failsClosed_withoutFollowing() {
        val f = fixture(leafCommonName = bridgeId)
        f.server.enqueue(
            MockResponse.Builder()
                .code(302)
                .addHeader("Location", "https://127.0.0.1:1/elsewhere")
                .build(),
        )

        val result = f.client.pair(f.endpoint)

        assertEquals(
            HuePairingResult.Failure(PairingFailureReason.UnexpectedHttpStatus(PairingStage.CONFIG, 302)),
            result,
        )
        // The redirect was refused, not chased: exactly one request reached the server.
        assertEquals(1, f.server.requestCount)
    }

    @Test
    fun nonSuccessHttpStatus_failsClosed() {
        val f = fixture(leafCommonName = bridgeId)
        f.server.enqueue(MockResponse.Builder().code(500).body("boom").build())

        val result = f.client.pair(f.endpoint)

        assertEquals(
            HuePairingResult.Failure(PairingFailureReason.UnexpectedHttpStatus(PairingStage.CONFIG, 500)),
            result,
        )
    }

    // --- TLS / transport failures -------------------------------------------------------------

    @Test
    fun serverCertNotSignedByTrustedCa_handshakeFails_failsClosed() {
        val rogueCa = certificateAuthority("Rogue CA")
        // Server leaf is signed by the rogue CA; the client trusts only the real rootCa.
        val f = fixture(leafCommonName = bridgeId, serverCa = rogueCa, trustedCa = rootCa)
        f.server.enqueue(json(body = configBody(bridgeId)))

        val result = f.client.pair(f.endpoint)

        assertEquals(HuePairingResult.Failure(PairingFailureReason.TransportError), result)
        assertEquals(0, f.server.requestCount)
    }

    @Test
    fun unroutableHost_failsClosedAsTransportError_withoutThrowing() {
        // L-38: OkHttp's HttpUrl.Builder throws IllegalArgumentException for a host it cannot
        // encode. That must surface as a typed TransportError, never escape the client, and never
        // issue a request.
        val f = fixture(leafCommonName = bridgeId)
        val unroutable = BridgeEndpoint(name = "Bridge", host = "bad<host>", port = f.endpoint.port)

        val result = f.client.pair(unroutable)

        assertEquals(PairingFailureReason.TransportError, failureReason(result))
        assertEquals(0, f.server.requestCount)
    }

    @Test
    fun stalledResponse_exceedingCallTimeout_failsClosed() {
        val f = fixture(leafCommonName = bridgeId, callTimeoutMillis = 1_000L)
        // Handshake completes immediately, then headers are withheld well past the call timeout.
        f.server.enqueue(
            MockResponse.Builder()
                .headersDelay(30, TimeUnit.SECONDS)
                .body(configBody(bridgeId))
                .build(),
        )

        val started = System.nanoTime()
        val result = f.client.pair(f.endpoint)
        val elapsedMillis = (System.nanoTime() - started) / 1_000_000

        assertEquals(HuePairingResult.Failure(PairingFailureReason.TransportError), result)
        // Bounded by the injected call timeout, not the 30s server delay.
        assertTrue("timed out too slowly: ${elapsedMillis}ms", elapsedMillis < 10_000)
    }

    // --- Identity-continuity correction (D-014) ------------------------------------------------

    @Test
    fun distinctLeafIdentitiesAcrossLegs_nullHint_failsClosed_andNeverPosts() {
        // Two CA-valid, SAN-less leaves signed by the SAME trusted test CA, distinct 16-hex CNs.
        // The GET leg presents leaf A (idA); a later re-handshake (forced by the POST leg pinning
        // its verifier to the authenticated id) presents leaf B (idB). With a NULL hint the GET
        // authenticates idA, but the POST must NOT be delivered to idB: the POST verifier is pinned
        // to idA, so leaf B is rejected at the TLS layer and the create-user request never lands.
        val idA = bridgeId
        val idB = otherBridgeId
        val leafA = HeldCertificate.Builder()
            .commonName(idA)
            .signedBy(rootCa)
            .ecdsa256()
            .build()
        val leafB = HeldCertificate.Builder()
            .commonName(idB)
            .signedBy(rootCa)
            .ecdsa256()
            .build()
        val serverA = HandshakeCertificates.Builder().heldCertificate(leafA).build()
        val serverB = HandshakeCertificates.Builder().heldCertificate(leafB).build()

        val server = MockWebServer()
        // First TLS connection (the GET) serves leaf A; every later connection (the POST's forced
        // re-handshake) serves leaf B.
        server.useHttps(
            SwitchingSslSocketFactory(
                first = serverA.sslSocketFactory(),
                rest = serverB.sslSocketFactory(),
            ),
        )
        server.start()
        servers += server

        // GET authenticates idA; the POST success response must never be consumed.
        server.enqueue(json(body = configBody(idA)))
        server.enqueue(json(body = successBody("must-never-be-returned")))

        val trustManager = HueRootTrustManager.fromCertificateAuthorities(listOf(rootCa.certificate))
        val sslContext = SSLContext.getInstance("TLS").apply {
            init(null, arrayOf<TrustManager>(trustManager), null)
        }
        val client = OkHttpHuePairingClient(sslContext.socketFactory, trustManager)
        val endpoint = BridgeEndpoint(name = "Test Bridge", host = server.hostName, port = server.port)

        val result = client.pair(endpoint, expectedBridgeId = null)

        // Fail closed: the differing POST leaf was rejected at the handshake → not Success.
        assertTrue("expected fail-closed Failure, was $result", result is HuePairingResult.Failure)
        // The create-user POST never reached the server: only the GET (idA) was served.
        assertEquals(1, server.requestCount)
    }

    // --- Test fixtures ------------------------------------------------------------------------

    /**
     * An [SSLSocketFactory] that delegates per TLS connection: the FIRST accepted connection uses
     * [first], every later connection uses [rest]. This lets a single [MockWebServer] present a
     * different CA-valid leaf on a re-established connection, exercising the across-legs identity
     * transition that the D-014 correction must fail closed on.
     */
    private class SwitchingSslSocketFactory(
        private val first: SSLSocketFactory,
        private val rest: SSLSocketFactory,
    ) : SSLSocketFactory() {

        private val connectionCount = AtomicInteger(0)

        private fun delegate(): SSLSocketFactory =
            if (connectionCount.getAndIncrement() == 0) first else rest

        override fun getDefaultCipherSuites(): Array<String> = first.defaultCipherSuites

        override fun getSupportedCipherSuites(): Array<String> = first.supportedCipherSuites

        // MockWebServer wraps each accepted raw socket via this overload, once per TLS connection.
        override fun createSocket(s: Socket?, host: String?, port: Int, autoClose: Boolean): Socket =
            delegate().createSocket(s, host, port, autoClose)

        override fun createSocket(host: String?, port: Int): Socket =
            throw UnsupportedOperationException()

        override fun createSocket(host: String?, port: Int, localHost: InetAddress?, localPort: Int): Socket =
            throw UnsupportedOperationException()

        override fun createSocket(host: InetAddress?, port: Int): Socket =
            throw UnsupportedOperationException()

        override fun createSocket(address: InetAddress?, port: Int, localAddress: InetAddress?, localPort: Int): Socket =
            throw UnsupportedOperationException()
    }

    private class Fixture(
        val server: MockWebServer,
        val client: OkHttpHuePairingClient,
        val endpoint: BridgeEndpoint,
    )

    private fun fixture(
        leafCommonName: String,
        serverCa: HeldCertificate = rootCa,
        trustedCa: HeldCertificate = rootCa,
        callTimeoutMillis: Long = 10_000L,
    ): Fixture {
        // SAN-less server leaf (mirrors real Hue): identity carried solely by the CN.
        val serverLeaf = HeldCertificate.Builder()
            .commonName(leafCommonName)
            .signedBy(serverCa)
            .ecdsa256()
            .build()
        val serverCertificates = HandshakeCertificates.Builder()
            .heldCertificate(serverLeaf, serverCa.certificate)
            .build()

        val server = MockWebServer()
        server.useHttps(serverCertificates.sslSocketFactory())
        server.start()
        servers += server

        val trustManager = HueRootTrustManager.fromCertificateAuthorities(listOf(trustedCa.certificate))
        val sslContext = SSLContext.getInstance("TLS").apply {
            init(null, arrayOf<TrustManager>(trustManager), null)
        }
        val client = OkHttpHuePairingClient(sslContext.socketFactory, trustManager, callTimeoutMillis)

        val endpoint = BridgeEndpoint(name = "Test Bridge", host = server.hostName, port = server.port)
        return Fixture(server, client, endpoint)
    }

    private fun certificateAuthority(commonName: String): HeldCertificate =
        HeldCertificate.Builder()
            .certificateAuthority(0)
            .commonName(commonName)
            .ecdsa256()
            .build()

    private fun json(code: Int = 200, body: String): MockResponse =
        MockResponse.Builder().code(code).body(body).build()

    private fun configBody(bridgeId: String): String = """{"bridgeid":"$bridgeId"}"""

    private fun successBody(username: String): String = """[{"success":{"username":"$username"}}]"""

    private fun errorBody(type: Int, description: String): String =
        """[{"error":{"type":$type,"address":"/","description":"$description"}}]"""

    private fun failureReason(result: HuePairingResult): PairingFailureReason {
        assertTrue("expected Failure, was $result", result is HuePairingResult.Failure)
        return (result as HuePairingResult.Failure).reason
    }
}
