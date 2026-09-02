package com.chromaglow.app.feature.setup

import com.chromaglow.app.core.bridge.BridgeRegistryResult
import com.chromaglow.app.core.bridge.PairedBridgeRecord
import com.chromaglow.app.core.hue.discovery.BridgeDiscoverySnapshot
import com.chromaglow.app.core.hue.discovery.BridgeEndpoint
import com.chromaglow.app.core.hue.pairing.transport.HuePairingResult
import com.chromaglow.app.core.hue.pairing.transport.PairingFailureReason
import com.chromaglow.app.core.hue.pairing.workflow.LivePairingWorkflow
import com.chromaglow.app.testing.FakeBridgeDiscoveryService
import com.chromaglow.app.testing.FakeBridgeRegistry
import com.chromaglow.app.testing.FakeCredentialStore
import com.chromaglow.app.testing.FakeHuePairingClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Deterministic JVM tests for [SetupViewModel] (the previously instrumented-only presentation
 * state machine). The seam is the main dispatcher: `viewModelScope` runs on a
 * [StandardTestDispatcher] under virtual time, so every transition is driven by [runCurrent] with
 * no sleeps, no Compose, and no Android framework.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class SetupViewModelTest {

    private val dispatcher = StandardTestDispatcher()
    private val scope = TestScope(dispatcher)

    private val bridgeId = "001788FFFE112233"
    private val username = "appkey-xyz"
    private val record = PairedBridgeRecord(bridgeId, "Living Room", "192.168.1.50", 443, true)
    private val endpoint = BridgeEndpoint(name = "Living Room", host = "192.168.1.50", port = 80)

    private val client = FakeHuePairingClient(HuePairingResult.LinkButtonNotPressed)
    private val store = FakeCredentialStore()
    private val registry = FakeBridgeRegistry()
    private val discovery = FakeBridgeDiscoveryService()

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    private fun viewModel(): SetupViewModel {
        val workflow = LivePairingWorkflow(client, store, registry, ioDispatcher = dispatcher)
        return SetupViewModel(workflow, discovery)
    }

    private fun runCurrent() = scope.runCurrent()

    // --- restore ---------------------------------------------------------------------------------

    @Test
    fun init_restoresPairedSession_whenRecordAndTokenExist() {
        store.tokens[bridgeId] = username
        registry.records.add(record)

        val vm = viewModel()
        runCurrent()

        assertEquals(BridgePairingUiState.Paired(record), vm.uiState.pairing)
    }

    @Test
    fun init_recordWithoutToken_isRecoveryWithForget_andDeletesNothing() {
        registry.records.add(record)

        val vm = viewModel()
        runCurrent()

        val pairing = vm.uiState.pairing as BridgePairingUiState.Recovery
        assertEquals(bridgeId, pairing.forgettableBridgeId)
        assertFalse(pairing.canResetSavedBridges)
        assertEquals(listOf(record), registry.records)
        assertEquals(0, store.deleteCount)
    }

    @Test
    fun init_unreadableMetadata_isRecoveryWithReset_andKeepsCredentials() {
        store.tokens[bridgeId] = username
        registry.readResult = BridgeRegistryResult.Corrupt

        val vm = viewModel()
        runCurrent()

        val pairing = vm.uiState.pairing as BridgePairingUiState.Recovery
        assertTrue(pairing.canResetSavedBridges)
        assertEquals(null, pairing.forgettableBridgeId)
        assertEquals(SetupViewModel.UNAVAILABLE_MESSAGE, pairing.message)
        assertEquals(username, store.tokens[bridgeId])
        assertEquals(0, store.deleteCount)
    }

    // --- pairing transitions ----------------------------------------------------------------------

    @Test
    fun pair_type101_returnsToSelectedWithRetryMessage_andPersistsNothing() {
        val vm = viewModel()
        runCurrent()
        vm.selectDiscoveredBridge(endpoint)

        vm.pair()
        assertEquals(BridgePairingUiState.Pairing(endpoint), vm.uiState.pairing)
        runCurrent()

        assertEquals(
            BridgePairingUiState.Selected(endpoint, retryMessage = SetupViewModel.LINK_BUTTON_MESSAGE),
            vm.uiState.pairing,
        )
        assertTrue(store.tokens.isEmpty())
        assertTrue(registry.records.isEmpty())
        assertEquals(1, client.callCount)
    }

    @Test
    fun pair_success_isPaired_andTokenNeverEntersUiState() {
        client.result = HuePairingResult.Success(bridgeId, username)
        val vm = viewModel()
        runCurrent()
        vm.selectDiscoveredBridge(endpoint)

        vm.pair()
        runCurrent()

        val expected = PairedBridgeRecord(bridgeId, "Living Room", "192.168.1.50", 443, true)
        assertEquals(BridgePairingUiState.Paired(expected), vm.uiState.pairing)
        assertFalse(vm.uiState.toString().contains(username))
        assertEquals(username, store.tokens[bridgeId])
    }

    @Test
    fun pair_whileAlreadyPairing_isIgnored() {
        val vm = viewModel()
        runCurrent()
        vm.selectDiscoveredBridge(endpoint)

        vm.pair()
        vm.pair()
        runCurrent()

        assertEquals(1, client.callCount)
    }

    @Test
    fun pair_terminalFailure_isRecoveryWithTryAgain() {
        client.result = HuePairingResult.Failure(PairingFailureReason.TransportError)
        val vm = viewModel()
        runCurrent()
        vm.selectDiscoveredBridge(endpoint)

        vm.pair()
        runCurrent()

        val pairing = vm.uiState.pairing as BridgePairingUiState.Recovery
        assertEquals(endpoint, pairing.retryBridge)
        vm.tryAgain()
        assertEquals(BridgePairingUiState.Selected(endpoint), vm.uiState.pairing)
    }

    // --- forget / reset ---------------------------------------------------------------------------

    @Test
    fun forget_fromPaired_clearsTokenAndRecord() {
        store.tokens[bridgeId] = username
        registry.records.add(record)
        val vm = viewModel()
        runCurrent()

        vm.forget()
        runCurrent()

        assertEquals(BridgePairingUiState.None, vm.uiState.pairing)
        assertTrue(store.tokens.isEmpty())
        assertTrue(registry.records.isEmpty())
    }

    @Test
    fun resetSavedBridges_clearsMetadataOnly_andReturnsToEntry() {
        store.tokens[bridgeId] = username
        registry.readResult = BridgeRegistryResult.Corrupt
        val vm = viewModel()
        runCurrent()

        vm.resetSavedBridges()
        runCurrent()

        assertEquals(BridgePairingUiState.None, vm.uiState.pairing)
        assertEquals(1, registry.clearCount)
        assertEquals(username, store.tokens[bridgeId])
        assertEquals(0, store.deleteCount)
    }

    @Test
    fun resetSavedBridges_isIgnored_unlessRecoveryOffersIt() {
        registry.records.add(record)
        val vm = viewModel()
        runCurrent()

        vm.resetSavedBridges()
        runCurrent()

        assertEquals(0, registry.clearCount)
        assertEquals(listOf(record), registry.records)
    }

    @Test
    fun resetSavedBridges_failure_staysRecoverable() {
        registry.readResult = BridgeRegistryResult.Corrupt
        registry.failClear = true
        val vm = viewModel()
        runCurrent()

        vm.resetSavedBridges()
        runCurrent()

        val pairing = vm.uiState.pairing as BridgePairingUiState.Recovery
        assertTrue(pairing.canResetSavedBridges)
        assertEquals(SetupViewModel.RESET_FAILED_MESSAGE, pairing.message)
    }

    // --- discovery lifecycle (L-55) -------------------------------------------------------------

    @Test
    fun stopDiscovery_stopsService_andClearsScanningFlag() {
        val vm = viewModel()
        runCurrent()
        vm.scanForBridge()
        discovery.emit(BridgeDiscoverySnapshot(isScanning = true, choices = emptyList()))
        assertTrue(vm.uiState.isScanning)
        val stopsBefore = discovery.stopCount

        vm.stopDiscovery()

        assertEquals(stopsBefore + 1, discovery.stopCount)
        assertFalse(vm.uiState.isScanning)
    }

    @Test
    fun selectingDiscoveredBridge_stopsDiscovery() {
        val vm = viewModel()
        runCurrent()
        vm.scanForBridge()
        val stopsBefore = discovery.stopCount

        vm.selectDiscoveredBridge(endpoint)

        assertEquals(stopsBefore + 1, discovery.stopCount)
    }
}
