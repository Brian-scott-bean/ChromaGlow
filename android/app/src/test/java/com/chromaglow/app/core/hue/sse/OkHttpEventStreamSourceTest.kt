package com.chromaglow.app.core.hue.sse

import com.chromaglow.app.core.hue.rest.ApplicationKey
import com.chromaglow.app.core.hue.rest.ApplicationKeyProvider
import com.chromaglow.app.core.hue.tls.HueTrust
import com.chromaglow.app.core.identity.BridgeId
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException

class OkHttpEventStreamSourceTest {

    private val bridgeId = BridgeId("001788FFFE112233")
    private val secret = "stream-key-000000000000"
    private val rootCa = HeldCertificate.Builder().certificateAuthority(0).commonName("Test CA").ecdsa256().build()
    private val servers = mutableListOf<MockWebServer>()

    @After
    fun tearDown() = servers.forEach { runCatching { it.close() } }

    private class Fixture(val server: MockWebServer, val source: OkHttpEventStreamSource)

    private fun fixture(leafCn: String = bridgeId.value, keys: ApplicationKeyProvider = ApplicationKeyProvider { ApplicationKey.of(secret) }): Fixture {
        val leaf = HeldCertificate.Builder().commonName(leafCn).signedBy(rootCa).ecdsa256().build()
        val server = MockWebServer().also { it.useHttps(HandshakeCertificates.Builder().heldCertificate(leaf, rootCa.certificate).build().sslSocketFactory()); it.start(); servers += it }
        val trust = HueTrust.fromCertificateAuthorities(listOf(rootCa.certificate))
        return Fixture(server, OkHttpEventStreamSource(bridgeId, server.hostName, server.port, keys, trust.forBridge(bridgeId)))
    }

    private fun sse(body: String, code: Int = 200) = MockResponse.Builder().code(code).addHeader("Content-Type", "text/event-stream").body(body).build()

    private suspend fun collectOrThrow(f: Fixture): Pair<List<SseFrame>, Throwable?> {
        val frames = mutableListOf<SseFrame>()
        val error = try { f.source.open().collect { frames += it }; null } catch (e: IOException) { e }
        return frames to error
    }

    // --- parser ------------------------------------------------------------------------------

    @Test
    fun lineParser_dispatchesDataOnBlankLine_joinsMultiLine_andIgnoresOtherFields() {
        val p = SseLineParser()
        assertNull(p.feed(": keepalive"))
        assertNull(p.feed("id: 1:0"))
        assertNull(p.feed("event: update"))
        assertNull(p.feed("data: [1]"))
        assertEquals("[1]", p.feed(""))
        assertNull(p.feed(""))
        assertNull(p.feed("data:first"))
        assertNull(p.feed("data: second"))
        assertEquals("first\nsecond", p.feed(""))
        assertNull(p.feed("data: partial"))
        p.reset()
        assertNull(p.feed(""))
    }

    // --- transport ---------------------------------------------------------------------------

    @Test
    fun connectedThenEveryEvent_isEmitted_withTheRightHeaders_andCompletesWhenTheBridgeCloses() = runTest {
        val f = fixture()
        f.server.enqueue(sse("id: 1\ndata: [{\"type\":\"update\"}]\n\n: hi\n\ndata: [2]\ndata: [3]\n\n"))

        val (frames, error) = collectOrThrow(f)

        assertNull(error)
        assertEquals(listOf(SseFrame.Connected, SseFrame.Data("[{\"type\":\"update\"}]"), SseFrame.Data("[2]\n[3]")), frames)
        val request = f.server.takeRequest()
        assertEquals("/eventstream/clip/v2", request.target)
        assertEquals("text/event-stream", request.headers["Accept"])
        assertEquals(secret, request.headers["hue-application-key"])
    }

    @Test
    fun nonSuccessStatus_isATransientStreamError_notARevocation_andNoConnectedFrame() = runTest {
        val f = fixture()
        f.server.enqueue(sse("", code = 401))
        val (frames, error) = collectOrThrow(f)
        assertTrue(frames.isEmpty())
        assertTrue(error is EventStreamHttpException)
        assertEquals(401, (error as EventStreamHttpException).status)
    }

    @Test
    fun redirect_isRefused() = runTest {
        val f = fixture()
        f.server.enqueue(MockResponse.Builder().code(302).addHeader("Location", "https://example.invalid/").build())
        val (_, error) = collectOrThrow(f)
        assertEquals(302, (error as EventStreamHttpException).status)
        assertEquals(1, f.server.requestCount)
    }

    @Test
    fun leafForAnotherBridge_failsClosed_withZeroRequests() = runTest {
        val f = fixture(leafCn = "AABBCCDDEEFF0011")
        f.server.enqueue(sse("data: x\n\n"))
        val (frames, error) = collectOrThrow(f)
        assertTrue(frames.isEmpty())
        assertTrue(error != null)
        assertEquals(0, f.server.requestCount)
    }

    @Test
    fun missingKey_transmitsNothing() = runTest {
        val f = fixture(keys = { null })
        f.server.enqueue(sse("data: x\n\n"))
        val (_, error) = collectOrThrow(f)
        assertTrue(error is EventStreamCredentialsException)
        assertEquals(0, f.server.requestCount)
    }

    @Test
    fun aLineBeyondTheBound_dropsTheStream() = runTest {
        val f = fixture()
        f.server.enqueue(sse("data: ok\n\ndata: " + "x".repeat((OkHttpEventStreamSource.MAX_LINE_BYTES + 10).toInt()) + "\n\n"))
        val (frames, error) = collectOrThrow(f)
        assertEquals(listOf(SseFrame.Connected, SseFrame.Data("ok")), frames)
        assertTrue(error is EventStreamLineTooLongException)
    }
}
