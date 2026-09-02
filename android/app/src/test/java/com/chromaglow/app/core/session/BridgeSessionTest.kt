package com.chromaglow.app.core.session

import com.chromaglow.app.core.credentials.BridgeCredentialStore
import com.chromaglow.app.core.credentials.BridgeSecretResult
import com.chromaglow.app.core.hue.rest.ClipError
import com.chromaglow.app.core.identity.BridgeId
import com.chromaglow.app.core.identity.ResourceId
import com.chromaglow.app.core.identity.ResourceKey
import com.chromaglow.app.core.identity.ResourceType
import com.chromaglow.app.testing.FakeCredentialStore
import com.chromaglow.app.testing.FakeHueClipTransport
import com.chromaglow.app.testing.FakeSnapshotCache
import com.chromaglow.app.testing.ManualClock
import com.chromaglow.app.testing.RecordingAttachment
import com.chromaglow.app.testing.RecordingCoordinator
import com.chromaglow.app.testing.FakeEventStream
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BridgeSessionTest {

    private val bridge = BridgeId("001788FFFE112233")
    private val other = BridgeId("AABBCCDDEEFF0011")
    private val lightKey = ResourceKey(bridge, ResourceType.LIGHT, ResourceId("la"))

    private class Harness(
        scope: TestScope,
        token: String? = "tok-000000000000",
        store: BridgeCredentialStore? = null,
        probe: Boolean = true,
        realCoordinator: Boolean = false,
        stream: FakeEventStream? = null,
    ) {
        val bridge = BridgeId("001788FFFE112233")
        val dispatcher = StandardTestDispatcher(scope.testScheduler)
        val credentialStore: BridgeCredentialStore = store ?: FakeCredentialStore().also { s -> token?.let { s.tokens[bridge.value] = it } }
        val transport = FakeHueClipTransport(bridge)
        val cache = FakeSnapshotCache(bridge)
        val clock = ManualClock()
        val coordinator = RecordingCoordinator()
        var realCoordinatorInstance: DefaultMutationCoordinator? = null
        val attachment = RecordingAttachment()
        val credentials = SessionCredentials(bridge, credentialStore, dispatcher)
        val virtualClock = SessionClock { scope.testScheduler.currentTime }
        val session = DefaultBridgeSession(
            bridgeId = bridge,
            parentScope = CoroutineScope(dispatcher),
            transport = transport,
            credentials = credentials,
            cache = cache,
            clock = if (realCoordinator) virtualClock else clock,
            coordinatorFactory = { env -> if (realCoordinator) DefaultMutationCoordinator(env).also { realCoordinatorInstance = it } else coordinator },
            attachmentFactories = listOf<(SessionEnvironment) -> SessionAttachment>({ attachment }) +
                (if (stream != null) listOf<(SessionEnvironment) -> SessionAttachment>({ env -> EventStreamRunner(env, stream, env.authority) }) else emptyList()),
            probeBridgeIdentity = probe,
        )

        init {
            transport.collection(ResourceType.LIGHT, """{"data":[{"id":"la","type":"light","metadata":{"name":"A"},"on":{"on":true}}]}""")
            transport.collection(ResourceType.BRIDGE, """{"data":[{"id":"b","type":"bridge","bridge_id":"001788fffe112233"}]}""")
        }
    }

    @Test
    fun start_loadsCredentials_thenNetwork_andBecomesConnected_withCacheWritten() = runTest {
        val h = Harness(this)
        assertEquals(ConnectionState.Connecting, h.session.connection.value)
        h.session.start()
        advanceUntilIdle()

        assertEquals(ConnectionState.Connected, h.session.connection.value)
        assertEquals(1, h.session.snapshot.value.lights.size)
        assertEquals(Freshness.Fresh(1), h.session.snapshot.value.freshness)
        assertEquals(1, h.cache.writes.size)
        assertEquals(ResourceType.BRIDGE, h.transport.wire.first().type)
        assertTrue(h.session.diagnostics.any { it.contains("bridge probe: match") })
        assertEquals(listOf("foreground"), h.attachment.events)
    }

    @Test
    fun cacheHit_isPaintedStaleFromCache_beforeTheNetworkAnswers() = runTest {
        val h = Harness(this, probe = false)
        h.cache.stored = BridgeSnapshot.empty(h.bridge).copy(generation = 4, lights = mapOf(lightKey to lightState(lightKey, "Cached")))
        val gate = CompletableDeferred<Unit>()
        h.transport.getGate = gate
        h.session.start()
        advanceUntilIdle()

        assertEquals(Freshness.Stale(4, StaleReason.FROM_CACHE), h.session.snapshot.value.freshness)
        assertEquals("Cached", h.session.snapshot.value.lights.getValue(lightKey).name)
        assertEquals(ConnectionState.Connecting, h.session.connection.value)

        gate.complete(Unit)
        advanceUntilIdle()
        assertEquals(ConnectionState.Connected, h.session.connection.value)
        assertEquals("A", h.session.snapshot.value.lights.getValue(lightKey).name)
        assertTrue(h.session.snapshot.value.freshness is Freshness.Fresh)
    }

    @Test
    fun unauthorized_becomesRevoked_dropsTheKeyFromMemory_keepsTheStoredToken_andStopsAllNetwork() = runTest {
        val h = Harness(this, probe = false)
        h.transport.fail(ResourceType.SCENE, ClipError.Unauthorized(401))
        h.session.start()
        advanceUntilIdle()

        assertEquals(ConnectionState.Revoked, h.session.connection.value)
        assertNull(h.credentials.applicationKey())
        assertEquals(CredentialState.Dropped, h.credentials.state)
        assertEquals("the stored token is never deleted by the session", BridgeSecretResult.Present("tok-000000000000"), h.credentialStore.loadApiToken(h.bridge.value))
        assertEquals(listOf("foreground", "background"), h.attachment.events)

        val before = h.transport.getCount
        h.session.requestRefresh(RefreshReason.USER_PULL)
        h.session.onForeground()
        advanceUntilIdle()
        assertEquals("no request after revocation", before, h.transport.getCount)
    }

    @Test
    fun absentToken_isLocalStorageError_withZeroNetwork_andNothingDeleted() = runTest {
        val store = FakeCredentialStore()
        val h = Harness(this, store = store)
        h.session.start()
        advanceUntilIdle()

        assertEquals(ConnectionState.Error(SessionErrorReason.LOCAL_STORAGE), h.session.connection.value)
        assertEquals(0, h.transport.getCount)
        assertEquals(0, store.deleteCount)
    }

    @Test
    fun unreadableToken_isLocalStorageError_withZeroNetwork() = runTest {
        val store = object : BridgeCredentialStore {
            override fun saveApiToken(bridgeId: String, token: String) = Unit
            override fun loadApiToken(bridgeId: String): BridgeSecretResult = BridgeSecretResult.Failure(IllegalStateException("keystore"))
            override fun deleteApiToken(bridgeId: String) = error("must not delete")
        }
        val h = Harness(this, store = store)
        h.session.start()
        advanceUntilIdle()
        assertEquals(ConnectionState.Error(SessionErrorReason.LOCAL_STORAGE), h.session.connection.value)
        assertEquals(0, h.transport.getCount)
    }

    @Test
    fun transportFailure_withNoSnapshot_isOffline_andNeverTouchesCredentials() = runTest {
        val h = Harness(this, probe = false)
        h.transport.fail(ResourceType.LIGHT, ClipError.Timeout(true))
        h.session.start()
        advanceUntilIdle()
        assertEquals(ConnectionState.Offline, h.session.connection.value)
        assertEquals(CredentialState.Loaded, h.credentials.state)
    }

    @Test
    fun transportFailure_withASnapshot_isStale_andKeepsTheSnapshot() = runTest {
        val h = Harness(this, probe = false)
        h.session.start()
        advanceUntilIdle()
        assertEquals(ConnectionState.Connected, h.session.connection.value)

        h.transport.fail(ResourceType.LIGHT, ClipError.Http(503))
        h.clock.advance(5_000)
        h.session.requestRefresh(RefreshReason.USER_PULL)
        advanceUntilIdle()

        assertEquals(ConnectionState.Stale(h.clock.nowMillis()), h.session.connection.value)
        assertEquals(1, h.session.snapshot.value.lights.size)
        assertEquals(Freshness.Stale(1, StaleReason.LOAD_FAILED), h.session.snapshot.value.freshness)
        assertEquals(CredentialState.Loaded, h.credentials.state)
    }

    @Test
    fun tlsIdentityFailure_isTlsIdentityError() = runTest {
        val h = Harness(this, probe = false)
        h.transport.fail(ResourceType.ROOM, ClipError.TlsIdentity)
        h.session.start()
        advanceUntilIdle()
        assertEquals(ConnectionState.Error(SessionErrorReason.TLS_IDENTITY), h.session.connection.value)
    }

    @Test
    fun refreshRequests_areCoalesced_toAtMostOneInFlightPlusOnePending() = runTest {
        val h = Harness(this, probe = false)
        h.session.start()
        advanceUntilIdle()
        val loadsAfterStart = h.transport.getCount / 5

        val gate = CompletableDeferred<Unit>()
        h.transport.getGate = gate
        h.session.requestRefresh(RefreshReason.USER_PULL)
        advanceUntilIdle()
        repeat(50) { h.session.requestRefresh(RefreshReason.POST_MUTATION) }
        gate.complete(Unit)
        h.transport.getGate = null
        advanceUntilIdle()

        assertEquals(loadsAfterStart + 2, h.transport.getCount / 5)
    }

    @Test
    fun submit_routesToTheCoordinator_refusesOtherBridges_andRefusesWhenClosed() = runTest {
        val h = Harness(this, probe = false)
        h.session.start()
        advanceUntilIdle()

        val ok = h.session.submit(LiveMutation.SetPower(lightKey, true))
        assertTrue(ok is MutationOutcome.Accepted)
        assertEquals(1, h.coordinator.submitted.size)
        val foreign = h.session.submit(LiveMutation.SetPower(ResourceKey(other, ResourceType.LIGHT, ResourceId("la")), true))
        assertEquals(MutationOutcome.Refused(RefusalReason.TARGET_UNKNOWN), foreign)
        h.session.close()
        assertEquals(MutationOutcome.Refused(RefusalReason.SESSION_CLOSED), h.session.submit(LiveMutation.SetPower(lightKey, true)))
        assertEquals(1, h.coordinator.submitted.size)
    }

    @Test
    fun closeWithALoadInFlight_cancelsCleanly_andTheLateResultNeverLands() = runTest {
        val h = Harness(this, probe = false)
        val gate = CompletableDeferred<Unit>()
        h.transport.getGate = gate
        h.session.start()
        advanceUntilIdle()
        assertTrue(h.transport.getCount > 0)

        h.session.close()
        gate.complete(Unit)
        advanceUntilIdle()

        assertEquals(0, h.session.snapshot.value.lights.size)
        assertEquals(ConnectionState.Connecting, h.session.connection.value)
        assertTrue(h.attachment.events.contains("close"))
        h.session.close() // idempotent
    }

    @Test
    fun foregroundAndBackground_fanOutToAttachments_andForegroundRefreshes() = runTest {
        val h = Harness(this, probe = false)
        h.session.start()
        advanceUntilIdle()
        val loads = h.transport.getCount

        h.session.onBackground()
        h.session.onForeground()
        advanceUntilIdle()

        assertEquals(listOf("foreground", "background", "foreground"), h.attachment.events)
        assertEquals(loads + 5, h.transport.getCount)
    }

    // --- fix batch -----------------------------------------------------------------------------

    @Test
    fun b01_anAuthoritativeLoadLandingMidMutation_keepsTheOptimisticValue_untilItSettles() = runTest {
        val h = Harness(this, probe = false, realCoordinator = true)
        h.session.start()
        advanceUntilIdle()
        val gate = CompletableDeferred<Unit>()
        h.transport.getGate = gate
        h.session.requestRefresh(RefreshReason.USER_PULL)
        advanceUntilIdle()
        val putGate = h.transport.holdNextPut()
        assertTrue(h.session.submit(LiveMutation.SetPower(lightKey, false)) is MutationOutcome.Accepted)
        advanceUntilIdle()
        assertFalse(h.session.snapshot.value.lights.getValue(lightKey).isOn)
        gate.complete(Unit)               // the older GET (lamp on) lands while the PUT is in flight
        advanceUntilIdle()
        assertFalse("the load must not flicker the pending field back on", h.session.snapshot.value.lights.getValue(lightKey).isOn)
        putGate.complete(com.chromaglow.app.core.hue.rest.ClipResult.Ok(com.chromaglow.app.core.hue.rest.ClipDocument(emptyList())))
        advanceUntilIdle()
        assertFalse(h.session.snapshot.value.lights.getValue(lightKey).isOn)
    }

    @Test
    fun b04_aProbeThatAnswersUnauthorized_revokesWithoutEverStartingTheStream() = runTest {
        val stream = FakeEventStream(bridge) { testScheduler.currentTime }
        stream.fallback = FakeEventStream.connectedAndHang()
        val h = Harness(this, probe = true, stream = stream)
        h.transport.fail(ResourceType.BRIDGE, ClipError.Unauthorized(401))
        h.session.start()
        advanceTimeBy(1_000)
        assertEquals(ConnectionState.Revoked, h.session.connection.value)
        assertEquals(0, stream.openCount)
        assertTrue(h.attachment.events.none { it == "foreground" })
        assertEquals("no load after a revoked probe", 1, h.transport.getCount)
        h.session.close()
    }

    @Test
    fun b05_backgroundDuringStart_keepsTheStreamOff_andForegroundRefreshesBeforeReconnecting() = runTest {
        val h = Harness(this, probe = true)
        h.session.start()
        h.session.onBackground()
        advanceUntilIdle()
        assertTrue("attachments never started while backgrounded: ${h.attachment.events}", h.attachment.events.isEmpty())
        val loads = h.transport.getCount
        h.session.onForeground()
        advanceUntilIdle()
        assertEquals(listOf("foreground"), h.attachment.events)
        assertEquals(loads + 5, h.transport.getCount)
    }

    @Test
    fun b05_foregroundBeforeCredentialsLoaded_doesNotStartAKeylessStream() = runTest {
        val h = Harness(this, probe = false)
        h.session.onForeground()   // before start(): nothing loaded yet
        assertTrue(h.attachment.events.isEmpty())
        h.session.start()
        advanceUntilIdle()
        assertEquals(listOf("foreground"), h.attachment.events)
    }

    @Test
    fun b06_anEventReducedDuringAnInFlightLoad_isReconciledByAFollowUpRefresh() = runTest {
        val stream = FakeEventStream(bridge) { testScheduler.currentTime }
        val off = """[{"type":"update","data":[{"id":"la","type":"light","on":{"on":false}}]}]"""
        stream.fallback = FakeEventStream.connectedAndHang(off)
        val h = Harness(this, probe = false, stream = stream)
        h.cache.stored = BridgeSnapshot.empty(h.bridge).copy(generation = 1, lights = mapOf(lightKey to lightState(lightKey, "Cached").copy(isOn = true)))
        val gate = CompletableDeferred<Unit>()
        h.transport.getGate = gate
        h.session.start()
        advanceTimeBy(1_000)               // load in flight, stream connected, event reduced
        h.transport.getGate = null
        val loadsBefore = h.transport.getCount / 5
        gate.complete(Unit)                // the older GET (lamp on) lands
        advanceTimeBy(5_000)
        assertEquals("one reconciling load followed the stale one", loadsBefore + 1, h.transport.getCount / 5)
        h.session.close()
    }

    @Test
    fun b17_aChattyBridge_earnsExactlyOneFollowUpLoad_perExternalRefresh() = runTest {
        val stream = FakeEventStream(bridge) { testScheduler.currentTime }
        // Continuous frames that flip the lamp every 50 ms: every one changes the snapshot.
        stream.fallback = kotlinx.coroutines.flow.flow {
            emit(com.chromaglow.app.core.hue.sse.SseFrame.Connected)
            repeat(200) { i ->
                emit(com.chromaglow.app.core.hue.sse.SseFrame.Data("""[{"type":"update","data":[{"id":"la","type":"light","on":{"on":${i % 2 == 0}}}]}]"""))
                kotlinx.coroutines.delay(50)
            }
            kotlinx.coroutines.awaitCancellation()
        }
        val h = Harness(this, probe = false, stream = stream)
        h.cache.stored = BridgeSnapshot.empty(h.bridge).copy(generation = 1, lights = mapOf(lightKey to lightState(lightKey, "Cached")))
        val gate = CompletableDeferred<Unit>()
        h.transport.getGate = gate
        h.session.start()
        advanceTimeBy(1_000)
        h.transport.getGate = null
        val loadsBefore = h.transport.getCount / 5
        gate.complete(Unit)
        advanceTimeBy(10_000)
        assertEquals("one stale load + exactly one follow-up, then quiet", loadsBefore + 1, h.transport.getCount / 5)
        // An external refresh may earn one more follow-up, never a chain.
        h.session.requestRefresh(RefreshReason.USER_PULL)
        advanceTimeBy(10_000)
        assertTrue("no chain: ${h.transport.getCount / 5}", h.transport.getCount / 5 <= loadsBefore + 3)
        h.session.close()
    }

    @Test
    fun b17_framesThatDoNotChangeTheSnapshot_neverEarnAFollowUp() = runTest {
        val stream = FakeEventStream(bridge) { testScheduler.currentTime }
        stream.fallback = kotlinx.coroutines.flow.flow {
            emit(com.chromaglow.app.core.hue.sse.SseFrame.Connected)
            repeat(200) {
                emit(com.chromaglow.app.core.hue.sse.SseFrame.Data("""[{"type":"update","data":[{"id":"ghost","type":"light","on":{"on":false}}]}]"""))
                kotlinx.coroutines.delay(50)
            }
            kotlinx.coroutines.awaitCancellation()
        }
        val h = Harness(this, probe = false, stream = stream)
        h.cache.stored = BridgeSnapshot.empty(h.bridge).copy(generation = 1, lights = mapOf(lightKey to lightState(lightKey, "Cached")))
        val gate = CompletableDeferred<Unit>()
        h.transport.getGate = gate
        h.session.start()
        advanceTimeBy(1_000)
        h.transport.getGate = null
        val loadsBefore = h.transport.getCount / 5
        gate.complete(Unit)
        advanceTimeBy(10_000)
        assertEquals(loadsBefore, h.transport.getCount / 5)
        h.session.close()
    }

    @Test
    fun b10_a04_close_closesTheCoordinator_andDropsTheKey() = runTest {
        val h = Harness(this, probe = false, realCoordinator = true)
        h.session.start()
        advanceUntilIdle()
        assertEquals(CredentialState.Loaded, h.credentials.state)
        h.session.close()
        assertEquals(CredentialState.Dropped, h.credentials.state)
        assertNull(h.credentials.applicationKey())
        assertEquals(MutationOutcome.Refused(RefusalReason.SESSION_CLOSED), h.realCoordinatorInstance!!.submit(LiveMutation.SetPower(lightKey, true)))
        assertEquals("the stored token is untouched", BridgeSecretResult.Present("tok-000000000000"), h.credentialStore.loadApiToken(h.bridge.value))
    }

    @Test
    fun d06_twoOverlappingLoads_theOlderResultIsSuperseded_andNeverLands() = runTest {
        val fake = FakeHueClipTransport(bridge)
        val loader = BridgeLoader(fake)
        fake.collection(ResourceType.LIGHT, """{"data":[{"id":"old","type":"light"}]}""")
        val gate1 = CompletableDeferred<Unit>()
        fake.getGate = gate1
        val first = async(StandardTestDispatcher(testScheduler)) { loader.load() }
        advanceUntilIdle()
        fake.getGate = null
        fake.collection(ResourceType.LIGHT, """{"data":[{"id":"new","type":"light"}]}""")
        val second = loader.load()
        gate1.complete(Unit)
        advanceUntilIdle()
        assertEquals(LoadOutcome.Superseded, first.await())
        assertEquals("new", (second as LoadOutcome.Loaded).snapshot.lights.keys.single().id.value)
    }

    @Test
    fun d08_noDiagnosticLineEverContainsTheToken() = runTest {
        val h = Harness(this, probe = true)
        h.transport.fail(ResourceType.BRIDGE, ClipError.Http(500))
        h.transport.fail(ResourceType.SCENE, ClipError.Transport(afterTransmission = true))
        h.session.start()
        advanceUntilIdle()
        assertTrue(h.session.diagnostics.isNotEmpty())
        for (line in h.session.diagnostics) assertFalse(line, line.contains("tok-000000000000"))
        // Even a line that WOULD carry the key is masked by the session's own redaction.
        assertEquals("key=<redacted>", h.credentials.redact("key=tok-000000000000"))
    }

    private fun lightState(key: ResourceKey, name: String) = LightState(
        key = key, name = name, isOn = false, brightness = null, color = null, mirek = null, mirekValid = null,
        activeEffect = null, activeTimedEffect = null, gradientPoints = emptyList(), owner = null,
        capabilities = com.chromaglow.app.core.hue.capability.LightCapabilities.unknown(),
    )
}
