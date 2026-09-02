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
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BridgeSessionTest {

    private val bridge = BridgeId("001788FFFE112233")
    private val other = BridgeId("AABBCCDDEEFF0011")
    private val lightKey = ResourceKey(bridge, ResourceType.LIGHT, ResourceId("la"))

    private class Harness(scope: TestScope, token: String? = "tok-000000000000", store: BridgeCredentialStore? = null, probe: Boolean = true) {
        val bridge = BridgeId("001788FFFE112233")
        val dispatcher = StandardTestDispatcher(scope.testScheduler)
        val credentialStore: BridgeCredentialStore = store ?: FakeCredentialStore().also { s -> token?.let { s.tokens[bridge.value] = it } }
        val transport = FakeHueClipTransport(bridge)
        val cache = FakeSnapshotCache(bridge)
        val clock = ManualClock()
        val coordinator = RecordingCoordinator()
        val attachment = RecordingAttachment()
        val credentials = SessionCredentials(bridge, credentialStore, dispatcher)
        val session = DefaultBridgeSession(
            bridgeId = bridge,
            parentScope = CoroutineScope(dispatcher),
            transport = transport,
            credentials = credentials,
            cache = cache,
            clock = clock,
            coordinatorFactory = { coordinator },
            attachmentFactories = listOf({ attachment }),
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

    private fun lightState(key: ResourceKey, name: String) = LightState(
        key = key, name = name, isOn = false, brightness = null, color = null, mirek = null, mirekValid = null,
        activeEffect = null, activeTimedEffect = null, gradientPoints = emptyList(), owner = null,
        capabilities = com.chromaglow.app.core.hue.capability.LightCapabilities.unknown(),
    )
}
