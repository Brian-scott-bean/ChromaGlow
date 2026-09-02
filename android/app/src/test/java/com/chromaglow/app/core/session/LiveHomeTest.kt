package com.chromaglow.app.core.session

import com.chromaglow.app.core.bridge.BridgeRegistryResult
import com.chromaglow.app.core.bridge.PairedBridgeRecord
import com.chromaglow.app.core.hue.rest.ClipError
import com.chromaglow.app.core.identity.BridgeId
import com.chromaglow.app.core.identity.ResourceId
import com.chromaglow.app.core.identity.ResourceKey
import com.chromaglow.app.core.identity.ResourceType
import com.chromaglow.app.testing.FakeBridgeRegistry
import com.chromaglow.app.testing.FakeCredentialStore
import com.chromaglow.app.testing.FakeHueClipTransport
import com.chromaglow.app.testing.FakeSnapshotCache
import com.chromaglow.app.testing.ManualClock
import com.chromaglow.app.testing.RecordingCoordinator
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runCurrent
import kotlin.reflect.full.memberProperties
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LiveHomeTest {

    private val bridgeA = BridgeId("001788FFFE112233")
    private val bridgeB = BridgeId("AABBCCDDEEFF0011")

    private class Harness(scope: TestScope) {
        val dispatcher = StandardTestDispatcher(scope.testScheduler)
        val registry = FakeBridgeRegistry()
        val credentials = FakeCredentialStore()
        val transports = mutableMapOf<BridgeId, FakeHueClipTransport>()
        val caches = mutableMapOf<BridgeId, FakeSnapshotCache>()
        val coordinators = mutableMapOf<BridgeId, RecordingCoordinator>()
        val home = DefaultLiveHome(
            registry = registry,
            credentialStore = credentials,
            factories = LiveHomeFactories(
                transport = { _, id, _ -> transports.getOrPut(id) { FakeHueClipTransport(id).also { t -> t.collection(ResourceType.LIGHT, """{"data":[{"id":"la","type":"light","metadata":{"name":"A"},"on":{"on":true}}]}""") } } },
                cache = { id -> caches.getOrPut(id) { FakeSnapshotCache(id) } },
                coordinator = { env -> coordinators.getOrPut(env.bridgeId) { RecordingCoordinator() } },
                probeBridgeIdentity = false,
            ),
            clock = ManualClock(),
            parentScope = CoroutineScope(dispatcher),
            ioDispatcher = dispatcher,
            mainDispatcher = dispatcher,
        )

        fun record(id: BridgeId, host: String = "192.168.1.10", active: Boolean = true) =
            PairedBridgeRecord(id.value, "Bridge ${id.value.takeLast(4)}", host, 443, active)
    }

    @Test
    fun start_opensOneSessionPerRecord_evenWhenTwoRecordsShareAHost_andMergesHome() = runTest {
        val h = Harness(this)
        h.registry.records += h.record(bridgeA, host = "192.168.1.10")
        h.registry.records += h.record(bridgeB, host = "192.168.1.10", active = false)
        h.credentials.tokens[bridgeA.value] = "tok-a-0000000000"
        h.credentials.tokens[bridgeB.value] = "tok-b-0000000000"

        h.home.start()
        advanceUntilIdle()

        assertNotNull(h.home.session(bridgeA))
        assertNotNull(h.home.session(bridgeB))
        val snapshot = h.home.home.value
        assertEquals(setOf(bridgeA, bridgeB), snapshot.bridges.keys)
        assertEquals(ConnectionState.Connected, snapshot.connections[bridgeA])
        assertEquals(ConnectionState.Connected, snapshot.connections[bridgeB])
        // Same rid on both bridges, two distinct keys in the merged view.
        assertEquals(2, snapshot.bridges.values.flatMap { it.lights.keys }.toSet().size)
        assertEquals(DefaultLiveHome.RegistryStatus.Ok, h.home.registryStatus.value)
    }

    @Test
    fun corruptRegistry_isUnavailable_opensNoSession_andDeletesNothing() = runTest {
        val h = Harness(this)
        h.registry.readResult = BridgeRegistryResult.Corrupt
        h.credentials.tokens[bridgeA.value] = "tok-a-0000000000"

        h.home.start()
        advanceUntilIdle()

        assertEquals(DefaultLiveHome.RegistryStatus.Unavailable, h.home.registryStatus.value)
        assertNull(h.home.session(bridgeA))
        assertTrue(h.home.home.value.bridges.isEmpty())
        assertEquals(0, h.credentials.deleteCount)
        assertEquals("tok-a-0000000000", h.credentials.tokens[bridgeA.value])
    }

    @Test
    fun recordWithoutToken_isItsOwnLocalStorageError_whileTheOtherBridgeConnects() = runTest {
        val h = Harness(this)
        h.registry.records += h.record(bridgeA)
        h.registry.records += h.record(bridgeB, host = "192.168.1.11")
        h.credentials.tokens[bridgeA.value] = "tok-a-0000000000"

        h.home.start()
        advanceUntilIdle()

        assertEquals(ConnectionState.Connected, h.home.home.value.connections[bridgeA])
        assertEquals(ConnectionState.Error(SessionErrorReason.LOCAL_STORAGE), h.home.home.value.connections[bridgeB])
        assertEquals(0, h.transports.getValue(bridgeB).getCount)
        assertEquals(0, h.credentials.deleteCount)
    }

    @Test
    fun oneBridgeOffline_doesNotAffectTheOther() = runTest {
        val h = Harness(this)
        h.registry.records += h.record(bridgeA)
        h.registry.records += h.record(bridgeB, host = "192.168.1.11")
        h.credentials.tokens[bridgeA.value] = "tok-a-0000000000"
        h.credentials.tokens[bridgeB.value] = "tok-b-0000000000"
        h.transports.getOrPut(bridgeB) { FakeHueClipTransport(bridgeB) }.fail(ResourceType.LIGHT, ClipError.Transport())

        h.home.start()
        advanceUntilIdle()

        assertEquals(ConnectionState.Connected, h.home.home.value.connections[bridgeA])
        assertEquals(ConnectionState.Offline, h.home.home.value.connections[bridgeB])
    }

    @Test
    fun submit_routesByTargetBridge_andRefusesAnUnknownBridge() = runTest {
        val h = Harness(this)
        h.registry.records += h.record(bridgeA)
        h.credentials.tokens[bridgeA.value] = "tok-a-0000000000"
        h.home.start()
        advanceUntilIdle()

        val key = ResourceKey(bridgeA, ResourceType.LIGHT, ResourceId("la"))
        assertTrue(h.home.submit(LiveMutation.SetPower(key, true)) is MutationOutcome.Accepted)
        assertEquals(1, h.coordinators.getValue(bridgeA).submitted.size)
        val unknown = ResourceKey(bridgeB, ResourceType.LIGHT, ResourceId("la"))
        assertEquals(MutationOutcome.Refused(RefusalReason.TARGET_UNKNOWN), h.home.submit(LiveMutation.SetPower(unknown, true)))
    }

    @Test
    fun remove_closesThatSession_andShrinksHome_thenClose_emptiesEverything() = runTest {
        val h = Harness(this)
        h.registry.records += h.record(bridgeA)
        h.registry.records += h.record(bridgeB, host = "192.168.1.11")
        h.credentials.tokens[bridgeA.value] = "tok-a-0000000000"
        h.credentials.tokens[bridgeB.value] = "tok-b-0000000000"
        h.home.start()
        advanceUntilIdle()
        assertEquals(2, h.home.home.value.bridges.size)

        val sessionA = h.home.session(bridgeA)!!
        h.home.remove(bridgeA)
        advanceUntilIdle()

        assertNull(h.home.session(bridgeA))
        assertEquals(setOf(bridgeB), h.home.home.value.bridges.keys)
        assertEquals(MutationOutcome.Refused(RefusalReason.SESSION_CLOSED), sessionA.submit(LiveMutation.SetPower(ResourceKey(bridgeA, ResourceType.LIGHT, ResourceId("la")), true)))
        // Removing is session teardown only: the shell performs the local Forget afterwards.
        assertEquals(0, h.credentials.deleteCount)
        assertEquals(2, h.registry.records.size)

        h.home.close()
        advanceUntilIdle()
        assertTrue(h.home.home.value.bridges.isEmpty())
        assertEquals(MutationOutcome.Refused(RefusalReason.SESSION_CLOSED), h.home.submit(LiveMutation.SetPower(ResourceKey(bridgeB, ResourceType.LIGHT, ResourceId("la")), true)))
    }

    @Test
    fun b07_remove_clearsThatBridgesCache_andOnlyThat() = runTest {
        val h = Harness(this)
        h.registry.records += h.record(bridgeA)
        h.registry.records += h.record(bridgeB, host = "192.168.1.11")
        h.credentials.tokens[bridgeA.value] = "tok-a-0000000000"
        h.credentials.tokens[bridgeB.value] = "tok-b-0000000000"
        h.home.start()
        advanceUntilIdle()
        h.home.remove(bridgeA)
        advanceUntilIdle()
        assertEquals(1, h.caches.getValue(bridgeA).clearCount)
        assertEquals(0, h.caches.getValue(bridgeB).clearCount)
    }

    @Test
    fun b11_removeDuringStart_neverResurrectsTheBridge() = runTest {
        val h = Harness(this)
        h.registry.records += h.record(bridgeA)
        h.credentials.tokens[bridgeA.value] = "tok-a-0000000000"
        val slow = object : com.chromaglow.app.core.bridge.BridgeRegistry by h.registry {
            val gate = kotlinx.coroutines.CompletableDeferred<Unit>()
            override suspend fun bridges(): BridgeRegistryResult<List<PairedBridgeRecord>> { gate.await(); return h.registry.bridges() }
        }
        val home = DefaultLiveHome(slow, h.credentials, LiveHomeFactories(
            transport = { _, id, _ -> h.transports.getOrPut(id) { FakeHueClipTransport(id) } },
            cache = { id -> h.caches.getOrPut(id) { FakeSnapshotCache(id) } },
            coordinator = { RecordingCoordinator() }, probeBridgeIdentity = false,
        ), ManualClock(), CoroutineScope(h.dispatcher), h.dispatcher, h.dispatcher)
        home.start()
        advanceUntilIdle()
        home.remove(bridgeA)               // Forget while the registry read is still pending
        slow.gate.complete(Unit)
        advanceUntilIdle()
        assertNull("a forgotten bridge must not come back as a ghost session", home.session(bridgeA))
        assertTrue(home.home.value.bridges.isEmpty())
    }

    @Test
    fun c1_mutationEvents_mergeSessionEvents_andEmitRefusedForEveryRefusedSubmit() = runTest {
        val h = Harness(this)
        h.registry.records += h.record(bridgeA)
        h.credentials.tokens[bridgeA.value] = "tok-a-0000000000"
        h.home.start()
        advanceUntilIdle()
        val events = mutableListOf<MutationEvent>()
        val job = backgroundScope.launch(h.dispatcher) { h.home.mutationEvents.collect { events += it } }
        runCurrent()
        val unknown = ResourceKey(bridgeB, ResourceType.LIGHT, ResourceId("la"))
        h.home.submit(LiveMutation.SetPower(unknown, true))
        h.coordinators.getValue(bridgeA).refuse = MutationOutcome.Refused(RefusalReason.OFFLINE)
        h.home.submit(LiveMutation.SetPower(ResourceKey(bridgeA, ResourceType.LIGHT, ResourceId("la")), true))
        // A session-level event flows up through the merge.
        (h.home.session(bridgeA) as DefaultBridgeSession).environment.mutationEvents.tryEmit(MutationEvent.Applied(LiveMutation.SetPower(unknown, false)))
        runCurrent()
        assertEquals(RefusalReason.TARGET_UNKNOWN, (events[0] as MutationEvent.Refused).reason)
        assertEquals(RefusalReason.OFFLINE, (events[1] as MutationEvent.Refused).reason)
        assertTrue(events[2] is MutationEvent.Applied)
        job.cancel()
    }

    @Test
    fun c1_mutationEventTypes_carryNoKeyMaterial() {
        val forbidden = listOf("token", "username", "secret", "password", "apikey", "api_key", "clientkey", "credential", "key")
        for (cls in MutationEvent::class.sealedSubclasses) {
            for (prop in cls.memberProperties) {
                val name = prop.name.lowercase()
                assertFalse("${cls.simpleName}.${prop.name}", forbidden.any { name == it || name.endsWith(it) })
                assertFalse("${cls.simpleName}.${prop.name} must not be a raw String", prop.returnType.classifier == String::class)
            }
        }
        assertTrue(MutationFailure.entries.isNotEmpty())
    }

    @Test
    fun c3_bridgeNames_comeFromTheRecordName_sanitized_neverFromModelData() = runTest {
        val h = Harness(this)
        h.registry.records += PairedBridgeRecord(bridgeA.value, "  Living  Room Bridge  ", "192.168.1.10", 443, true)
        h.registry.records += PairedBridgeRecord(bridgeB.value, "x", "192.168.1.11", 443, false)
        h.credentials.tokens[bridgeA.value] = "tok-a-0000000000"
        h.home.start()
        advanceUntilIdle()
        assertEquals("Living Room Bridge", h.home.bridgeNames.value[bridgeA])
        assertEquals("x", h.home.bridgeNames.value[bridgeB])
        h.home.remove(bridgeB)
        assertNull(h.home.bridgeNames.value[bridgeB])
    }

    @Test
    fun lifecycle_fansOutToEverySession() = runTest {
        val h = Harness(this)
        h.registry.records += h.record(bridgeA)
        h.registry.records += h.record(bridgeB, host = "192.168.1.11")
        h.credentials.tokens[bridgeA.value] = "tok-a-0000000000"
        h.credentials.tokens[bridgeB.value] = "tok-b-0000000000"
        h.home.start()
        advanceUntilIdle()
        val a = h.transports.getValue(bridgeA).getCount
        val b = h.transports.getValue(bridgeB).getCount

        h.home.onBackground()
        h.home.onForeground()
        advanceUntilIdle()

        assertEquals(a + 5, h.transports.getValue(bridgeA).getCount)
        assertEquals(b + 5, h.transports.getValue(bridgeB).getCount)
    }
}
