package com.chromaglow.app.app

import com.chromaglow.app.core.bridge.BridgeRegistryResult
import com.chromaglow.app.core.bridge.PairedBridgeRecord
import com.chromaglow.app.core.hue.pairing.transport.HuePairingResult
import com.chromaglow.app.core.hue.pairing.workflow.LivePairingWorkflow
import com.chromaglow.app.core.identity.BridgeId
import com.chromaglow.app.core.session.BridgeSession
import com.chromaglow.app.core.session.HomeSnapshot
import com.chromaglow.app.core.session.LiveHome
import com.chromaglow.app.core.session.LiveMutation
import com.chromaglow.app.core.session.MutationOutcome
import com.chromaglow.app.core.session.RefreshReason
import com.chromaglow.app.core.session.RefusalReason
import com.chromaglow.app.testing.FakeBridgeRegistry
import com.chromaglow.app.testing.FakeCredentialStore
import com.chromaglow.app.testing.FakeHuePairingClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * P7 shell semantics on the JVM: cold-start classification never deletes, Demo/Live exclusivity,
 * ordered local-only Forget (session removed → token+record deleted → Setup), lifecycle fan-out.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class AppShellControllerTest {

    private val idA = "001788FFFE0000AA"
    private val idB = "001788FFFE0000BB"
    private val recordA = PairedBridgeRecord(idA, "A", "192.168.1.10", 443, true)
    private val recordB = PairedBridgeRecord(idB, "B", "192.168.1.11", 443, false)

    private class FakeLiveHome : LiveHome {
        val events = mutableListOf<String>()
        override val home: StateFlow<HomeSnapshot> = MutableStateFlow(HomeSnapshot(emptyMap(), emptyMap()))
        override fun session(bridgeId: BridgeId): BridgeSession? = null
        override fun requestRefresh(reason: RefreshReason) { events += "refresh:$reason" }
        override suspend fun submit(mutation: LiveMutation): MutationOutcome =
            MutationOutcome.Refused(RefusalReason.OFFLINE)
        override fun onForeground() { events += "foreground" }
        override fun onBackground() { events += "background" }
        override fun remove(bridgeId: BridgeId) { events += "remove:${bridgeId.value}" }
        override fun close() { events += "close" }
    }

    private class Harness(scope: TestScope) {
        val store = FakeCredentialStore()
        val registry = FakeBridgeRegistry()
        val homes = mutableListOf<FakeLiveHome>()
        val workflow = LivePairingWorkflow(
            pairingClient = FakeHuePairingClient(HuePairingResult.LinkButtonNotPressed),
            credentialStore = store,
            bridgeRegistry = registry,
            ioDispatcher = StandardTestDispatcher(scope.testScheduler),
        )
        val controller = AppShellController(
            workflow = workflow,
            liveHomeFactory = { _: CoroutineScope -> FakeLiveHome().also { homes += it } },
            scope = scope,
        )
    }

    @Test
    fun launch_healthyPairedRecord_opensLive() = runTest {
        val h = Harness(this)
        h.registry.records += recordA
        h.store.tokens[idA] = "key-a"

        h.controller.restoreAtLaunch()

        assertEquals(AppShellController.Startup.Live, h.controller.startup.value)
        assertTrue(h.controller.session.value is AppSession.Live)
        assertNotNull(h.controller.commands)
        assertEquals(1, h.homes.size)
    }

    @Test
    fun launch_recordWithoutToken_landsOnSetup_andDeletesNothing() = runTest {
        val h = Harness(this)
        h.registry.records += recordA
        h.registry.records += recordB
        h.store.tokens[idB] = "key-b" // A needs repair; B is fine — the whole home stays on Setup.

        h.controller.restoreAtLaunch()

        assertEquals(AppShellController.Startup.Setup, h.controller.startup.value)
        assertEquals(AppSession.None, h.controller.session.value)
        assertEquals(0, h.store.deleteCount)
        assertEquals(2, h.registry.records.size)
        assertEquals("key-b", h.store.tokens[idB])
        assertTrue(h.homes.isEmpty())
    }

    @Test
    fun launch_corruptRegistry_landsOnSetup_andKeepsCredentials() = runTest {
        val h = Harness(this)
        h.registry.readResult = BridgeRegistryResult.Corrupt
        h.store.tokens[idA] = "key-a"

        h.controller.restoreAtLaunch()

        assertEquals(AppShellController.Startup.Setup, h.controller.startup.value)
        assertEquals("key-a", h.store.tokens[idA])
        assertEquals(0, h.store.deleteCount)
    }

    @Test
    fun launch_unpaired_landsOnSetup() = runTest {
        val h = Harness(this)
        h.controller.restoreAtLaunch()
        assertEquals(AppShellController.Startup.Setup, h.controller.startup.value)
        assertEquals(AppSession.None, h.controller.session.value)
    }

    @Test
    fun forgetLastBridge_removesSession_thenDeletesLocally_thenReturnsToSetup() = runTest {
        val h = Harness(this)
        h.registry.records += recordA
        h.store.tokens[idA] = "key-a"
        h.controller.restoreAtLaunch()
        val home = h.homes.single()

        h.controller.forgetBridge(BridgeId(idA))
        // Nothing flips synchronously: Setup must only be shown once the local delete is done.
        assertTrue(h.controller.session.value is AppSession.Live)
        testScheduler.advanceUntilIdle()

        assertEquals(listOf("remove:$idA", "close"), home.events)
        assertTrue(h.store.tokens.isEmpty())
        assertTrue(h.registry.records.isEmpty())
        assertEquals(AppSession.None, h.controller.session.value)
        assertNull(h.controller.commands)
    }

    @Test
    fun forgetOneOfTwo_keepsLive_andDeletesOnlyThatBridge() = runTest {
        val h = Harness(this)
        h.registry.records += recordA
        h.registry.records += recordB
        h.store.tokens[idA] = "key-a"
        h.store.tokens[idB] = "key-b"
        h.controller.restoreAtLaunch()
        val home = h.homes.single()

        h.controller.forgetBridge(BridgeId(idB))
        testScheduler.advanceUntilIdle()

        assertEquals(listOf("remove:$idB"), home.events)
        assertEquals("key-a", h.store.tokens[idA])
        assertNull(h.store.tokens[idB])
        assertEquals(listOf(recordA), h.registry.records)
        assertTrue(h.controller.session.value is AppSession.Live)
    }

    @Test
    fun enterDemo_whileLive_closesLiveHome_andExitDemoReturnsToNone() = runTest {
        val h = Harness(this)
        h.registry.records += recordA
        h.store.tokens[idA] = "key-a"
        h.controller.restoreAtLaunch()
        val home = h.homes.single()

        h.controller.enterDemo()
        assertTrue(h.controller.session.value is AppSession.Demo)
        assertEquals(listOf("close"), home.events)
        assertNull(h.controller.commands)
        // Demo never touches persisted live state.
        assertEquals("key-a", h.store.tokens[idA])
        assertEquals(listOf(recordA), h.registry.records)

        h.controller.exitDemo()
        assertEquals(AppSession.None, h.controller.session.value)
    }

    @Test
    fun enterLive_isIdempotent_andPairedFromSetupOpensOneHome() = runTest {
        val h = Harness(this)
        h.controller.restoreAtLaunch()
        assertEquals(AppShellController.Startup.Setup, h.controller.startup.value)

        h.controller.enterLive(recordA)
        h.controller.enterLive(recordA)

        assertEquals(1, h.homes.size)
        assertSame(h.homes.single(), (h.controller.session.value as AppSession.Live).home)
    }

    @Test
    fun lifecycle_isForwardedOnlyWhileLive() = runTest {
        val h = Harness(this)
        h.controller.onForeground() // no session: no crash
        h.registry.records += recordA
        h.store.tokens[idA] = "key-a"
        h.controller.restoreAtLaunch()
        val home = h.homes.single()

        h.controller.onBackground()
        h.controller.onForeground()
        h.controller.exitToSetup()
        h.controller.onForeground()

        assertEquals(listOf("background", "foreground", "close"), home.events)
        assertEquals(AppSession.None, h.controller.session.value)
        // exitToSetup is not Forget: persisted state is untouched.
        assertEquals("key-a", h.store.tokens[idA])
    }
}
