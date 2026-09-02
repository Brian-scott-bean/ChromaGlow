package com.chromaglow.app.core.hue.rest

import com.chromaglow.app.core.hue.tls.HueTrust
import com.chromaglow.app.core.identity.BridgeId
import com.chromaglow.app.core.identity.ResourceId
import com.chromaglow.app.core.identity.ResourceType
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.ServerSocket
import java.util.concurrent.TimeUnit

/**
 * ControlClientIdentityTest: the authenticated transport end-to-end over HTTPS with SAN-less
 * test leaves signed by a test CA (mirroring real Hue). Pins the BRIDGE-ID CASE INVARIANT at the
 * wire, the 401/403-only revocation trigger, redirect refusal, the body bound, the timeout
 * transmission flag, and that the application key never leaves the request header.
 */
class OkHttpHueClipClientTest {

    private val bridgeId = BridgeId("001788FFFE112233")
    private val otherBridgeId = BridgeId("AABBCCDDEEFF0011")
    private val secret = "secret-application-key-1234567890"

    private val rootCa: HeldCertificate = certificateAuthority("Test Hue Root CA")
    private val servers = mutableListOf<MockWebServer>()
    private val sockets = mutableListOf<ServerSocket>()

    @After
    fun tearDown() {
        servers.forEach { runCatching { it.close() } }
        sockets.forEach { runCatching { it.close() } }
    }

    private class Fixture(val server: MockWebServer, val client: OkHttpHueClipClient, val diagnostics: MutableList<String>)

    private fun fixture(
        leafCommonName: String,
        serverCa: HeldCertificate = rootCa,
        trustedCa: HeldCertificate = rootCa,
        pinned: BridgeId = bridgeId,
        keys: ApplicationKeyProvider = ApplicationKeyProvider { ApplicationKey.of(secret) },
        callTimeoutMillis: Long = 10_000L,
    ): Fixture {
        val serverLeaf = HeldCertificate.Builder().commonName(leafCommonName).signedBy(serverCa).ecdsa256().build()
        val serverCertificates = HandshakeCertificates.Builder().heldCertificate(serverLeaf, serverCa.certificate).build()
        val server = MockWebServer()
        server.useHttps(serverCertificates.sslSocketFactory())
        server.start()
        servers += server

        val trust = HueTrust.fromCertificateAuthorities(listOf(trustedCa.certificate))
        val diagnostics = mutableListOf<String>()
        val client = OkHttpHueClipClient(
            bridgeId = pinned,
            host = server.hostName,
            port = server.port,
            keys = keys,
            tls = trust.forBridge(pinned),
            callTimeoutMillis = callTimeoutMillis,
            diagnostics = { diagnostics += it },
        )
        return Fixture(server, client, diagnostics)
    }

    private fun certificateAuthority(cn: String): HeldCertificate =
        HeldCertificate.Builder().certificateAuthority(0).commonName(cn).ecdsa256().build()

    private fun json(code: Int = 200, body: String): MockResponse = MockResponse.Builder().code(code).body(body).build()

    private fun err(result: ClipResult<*>): ClipError {
        assertTrue("expected Err, was $result", result is ClipResult.Err)
        return (result as ClipResult.Err).error
    }

    // --- identity -----------------------------------------------------------------------------

    @Test
    fun leafForAnotherBridge_failsClosed_withZeroRequests_soNoKeyIsEverTransmitted() = runTest {
        val f = fixture(leafCommonName = otherBridgeId.value)
        f.server.enqueue(json(body = """{"data":[]}"""))

        val result = f.client.getResources(ResourceType.LIGHT)

        assertEquals(ClipError.TlsIdentity, err(result))
        assertEquals("no request may reach the server across an identity mismatch", 0, f.server.requestCount)
    }

    @Test
    fun uppercaseLeafCn_matchesPinnedId_andSendsTheKeyHeader() = runTest {
        val f = fixture(leafCommonName = "001788FFFE112233")
        f.server.enqueue(json(body = """{"data":[{"id":"l1","type":"light"}]}"""))

        val result = f.client.getResources(ResourceType.LIGHT)

        assertTrue(result is ClipResult.Ok)
        val request = f.server.takeRequest()
        assertEquals("GET", request.method)
        assertEquals("/clip/v2/resource/light", request.target)
        assertEquals(secret, request.headers["hue-application-key"])
    }

    @Test
    fun lowercaseLeafCn_matchesPinnedUppercaseId() = runTest {
        val f = fixture(leafCommonName = "001788fffe112233")
        f.server.enqueue(json(body = """{"data":[]}"""))

        assertTrue(f.client.getResources(ResourceType.ROOM) is ClipResult.Ok)
        assertEquals(1, f.server.requestCount)
    }

    @Test
    fun mixedCaseLeafCn_matchesPinnedUppercaseId() = runTest {
        val f = fixture(leafCommonName = "001788FffE112233")
        f.server.enqueue(json(body = """{"data":[]}"""))

        assertTrue(f.client.getResources(ResourceType.ZONE) is ClipResult.Ok)
    }

    @Test
    fun leafNotSignedByTrustedCa_isTransport_notUnauthorized_andSendsNothing() = runTest {
        val rogue = certificateAuthority("Rogue CA")
        val f = fixture(leafCommonName = bridgeId.value, serverCa = rogue, trustedCa = rootCa)
        f.server.enqueue(json(body = """{"data":[]}"""))

        assertEquals(ClipError.Transport, err(f.client.getResources(ResourceType.LIGHT)))
        assertEquals(0, f.server.requestCount)
    }

    @Test
    fun malformedLeafCn_failsClosed_withZeroRequests() = runTest {
        val f = fixture(leafCommonName = "not-a-bridge")
        f.server.enqueue(json(body = """{"data":[]}"""))

        assertEquals(ClipError.TlsIdentity, err(f.client.getResources(ResourceType.LIGHT)))
        assertEquals(0, f.server.requestCount)
    }

    // --- status mapping -----------------------------------------------------------------------

    @Test
    fun status401_and403_areUnauthorized_theOnlyRevocationTrigger() = runTest {
        val f = fixture(leafCommonName = bridgeId.value)
        f.server.enqueue(json(code = 401, body = ""))
        f.server.enqueue(json(code = 403, body = ""))

        assertEquals(ClipError.Unauthorized(401), err(f.client.getResources(ResourceType.LIGHT)))
        assertEquals(ClipError.Unauthorized(403), err(f.client.getResources(ResourceType.LIGHT)))
    }

    @Test
    fun status503_isHttp_neverUnauthorized() = runTest {
        val f = fixture(leafCommonName = bridgeId.value)
        f.server.enqueue(json(code = 503, body = "unavailable"))

        assertEquals(ClipError.Http(503), err(f.client.getResources(ResourceType.LIGHT)))
    }

    @Test
    fun status429_isRateLimited() = runTest {
        val f = fixture(leafCommonName = bridgeId.value)
        f.server.enqueue(json(code = 429, body = ""))

        assertEquals(ClipError.RateLimited, err(f.client.getResources(ResourceType.LIGHT)))
    }

    @Test
    fun redirect_isRefused_andNeverFollowed() = runTest {
        val f = fixture(leafCommonName = bridgeId.value)
        f.server.enqueue(MockResponse.Builder().code(302).addHeader("Location", "https://example.invalid/").build())
        f.server.enqueue(json(body = """{"data":[]}"""))

        assertEquals(ClipError.Http(302), err(f.client.getResources(ResourceType.LIGHT)))
        assertEquals(1, f.server.requestCount)
    }

    // --- body policy --------------------------------------------------------------------------

    @Test
    fun twoHundredWithErrorsAndNoData_isBridgeRejected() = runTest {
        val f = fixture(leafCommonName = bridgeId.value)
        f.server.enqueue(json(body = """{"errors":[{"description":"resource not available"}],"data":[]}"""))

        assertEquals(ClipError.BridgeRejected(listOf("resource not available")), err(f.client.getResources(ResourceType.LIGHT)))
    }

    @Test
    fun twoHundredWithErrorsAndData_isOkWithPartialErrors() = runTest {
        val f = fixture(leafCommonName = bridgeId.value)
        f.server.enqueue(json(body = """{"errors":[{"description":"one lamp offline"}],"data":[{"id":"l1","type":"light"}]}"""))

        val ok = f.client.getResources(ResourceType.LIGHT) as ClipResult.Ok
        assertEquals(1, ok.value.data.size)
        assertEquals(listOf("one lamp offline"), ok.partialErrors)
    }

    @Test
    fun malformedJson_isDecode() = runTest {
        val f = fixture(leafCommonName = bridgeId.value)
        f.server.enqueue(json(body = "{ not json"))

        assertTrue(err(f.client.getResources(ResourceType.LIGHT)) is ClipError.Decode)
    }

    @Test
    fun bodyLargerThanOneMebibyte_isDecode_notBuffered() = runTest {
        val f = fixture(leafCommonName = bridgeId.value)
        val huge = "[" + "1,".repeat(((OkHttpHueClipClient.MAX_BODY_BYTES / 2) + 8).toInt()) + "1]"
        f.server.enqueue(json(body = """{"data":$huge}"""))

        assertTrue(err(f.client.getResources(ResourceType.LIGHT)) is ClipError.Decode)
    }

    @Test
    fun bodyAtExactlyTheBound_isStillRead() = runTest {
        val f = fixture(leafCommonName = bridgeId.value)
        val prefix = """{"data":[],"pad":""""
        val suffix = """"}"""
        val body = prefix + "x".repeat((OkHttpHueClipClient.MAX_BODY_BYTES - prefix.length - suffix.length).toInt()) + suffix
        assertEquals(OkHttpHueClipClient.MAX_BODY_BYTES, body.length.toLong())
        f.server.enqueue(json(body = body))

        assertTrue(f.client.getResources(ResourceType.LIGHT) is ClipResult.Ok)
    }

    // --- PUT ----------------------------------------------------------------------------------

    @Test
    fun put_sendsExactJsonBody_withJsonContentType_toTheResourcePath() = runTest {
        val f = fixture(leafCommonName = bridgeId.value)
        f.server.enqueue(json(body = """{"data":[{"rid":"l1","rtype":"light"}],"errors":[]}"""))
        val body = ClipWriteBody(buildJsonObject { put("on", buildJsonObject { put("on", true) }) })

        val result = f.client.putResource(ResourceType.LIGHT, ResourceId("l1"), body)

        assertTrue(result is ClipResult.Ok)
        val request = f.server.takeRequest()
        assertEquals("PUT", request.method)
        assertEquals("/clip/v2/resource/light/l1", request.target)
        assertEquals("""{"on":{"on":true}}""", request.body?.utf8())
        assertTrue(request.headers["Content-Type"]!!.startsWith("application/json"))
        assertEquals(secret, request.headers["hue-application-key"])
    }

    @Test
    fun put_isNeverRetried_onAServerFailure() = runTest {
        val f = fixture(leafCommonName = bridgeId.value)
        f.server.enqueue(json(code = 500, body = "boom"))
        f.server.enqueue(json(body = """{"data":[]}"""))

        assertEquals(ClipError.Http(500), err(f.client.putResource(ResourceType.LIGHT, ResourceId("l1"), ClipBodies.power(true))))
        assertEquals("exactly one PUT may reach the wire per call", 1, f.server.requestCount)
    }

    // --- timeouts -----------------------------------------------------------------------------

    @Test
    fun stalledResponseAfterHeadersWereSent_isTimeoutAfterTransmission() = runTest {
        val f = fixture(leafCommonName = bridgeId.value, callTimeoutMillis = 800L)
        f.server.enqueue(MockResponse.Builder().code(200).body("""{"data":[]}""").headersDelay(5, TimeUnit.SECONDS).build())

        val error = err(f.client.putResource(ResourceType.LIGHT, ResourceId("l1"), ClipBodies.power(true)))

        assertEquals(ClipError.Timeout(afterTransmission = true), error)
    }

    @Test
    fun connectionThatNeverCompletesTheHandshake_isTimeoutBeforeTransmission() = runTest {
        // A raw socket that accepts and never speaks TLS: the handshake stalls until callTimeout.
        val socket = ServerSocket(0).also { sockets += it }
        val trust = HueTrust.fromCertificateAuthorities(listOf(rootCa.certificate))
        val client = OkHttpHueClipClient(
            bridgeId = bridgeId, host = "127.0.0.1", port = socket.localPort,
            keys = { ApplicationKey.of(secret) }, tls = trust.forBridge(bridgeId), callTimeoutMillis = 800L,
        )

        val error = err(client.putResource(ResourceType.LIGHT, ResourceId("l1"), ClipBodies.power(true)))

        assertEquals(ClipError.Timeout(afterTransmission = false), error)
    }

    // --- credentials --------------------------------------------------------------------------

    @Test
    fun missingKey_isMissingCredentials_andNothingIsSent() = runTest {
        val f = fixture(leafCommonName = bridgeId.value, keys = { null })
        f.server.enqueue(json(body = """{"data":[]}"""))

        assertEquals(ClipError.MissingCredentials, err(f.client.getResources(ResourceType.LIGHT)))
        assertEquals(0, f.server.requestCount)
    }

    @Test
    fun clearedKey_isMissingCredentials_andNothingIsSent() = runTest {
        val key = ApplicationKey.of(secret).also { it.clear() }
        val f = fixture(leafCommonName = bridgeId.value, keys = { key })
        f.server.enqueue(json(body = """{"data":[]}"""))

        assertEquals(ClipError.MissingCredentials, err(f.client.getResources(ResourceType.LIGHT)))
        assertEquals(0, f.server.requestCount)
    }

    @Test
    fun replacedKey_isUsedOnTheNextRequest_andTheStaleKeyIsNeverSentAgain() = runTest {
        var current = ApplicationKey.of("old-key-000000000000")
        val f = fixture(leafCommonName = bridgeId.value, keys = { current })
        f.server.enqueue(json(body = """{"data":[]}"""))
        f.server.enqueue(json(body = """{"data":[]}"""))

        f.client.getResources(ResourceType.LIGHT)
        current.clear()
        current = ApplicationKey.of("new-key-111111111111")
        f.client.getResources(ResourceType.LIGHT)

        assertEquals("old-key-000000000000", f.server.takeRequest().headers["hue-application-key"])
        assertEquals("new-key-111111111111", f.server.takeRequest().headers["hue-application-key"])
    }

    @Test
    fun theKeyNeverAppearsInDiagnostics_orInToString() = runTest {
        val f = fixture(leafCommonName = bridgeId.value)
        f.server.enqueue(json(body = """{"errors":[{"description":"nope"}],"data":[]}"""))
        f.server.enqueue(json(code = 401, body = ""))

        f.client.getResources(ResourceType.LIGHT)
        f.client.putResource(ResourceType.LIGHT, ResourceId("l1"), ClipBodies.power(false))

        assertTrue(f.diagnostics.isNotEmpty())
        for (line in f.diagnostics) assertFalse(line, line.contains(secret))
        assertFalse(ApplicationKey.of(secret).toString().contains(secret))
        assertNull(f.diagnostics.firstOrNull { it.contains("hue-application-key", ignoreCase = true) })
    }

    @Test
    fun clientRefusesATlsIdentityPinnedToAnotherBridge() {
        val trust = HueTrust.fromCertificateAuthorities(listOf(rootCa.certificate))
        val thrown = runCatching {
            OkHttpHueClipClient(bridgeId, "127.0.0.1", 443, { null }, trust.forBridge(otherBridgeId))
        }.exceptionOrNull()
        assertTrue(thrown is IllegalArgumentException)
    }
}
