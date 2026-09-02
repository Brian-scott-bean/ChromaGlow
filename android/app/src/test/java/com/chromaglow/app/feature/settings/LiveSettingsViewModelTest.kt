package com.chromaglow.app.feature.settings

import com.chromaglow.app.core.identity.BridgeId
import com.chromaglow.app.core.session.ConnectionState
import com.chromaglow.app.core.session.HomeSnapshot
import com.chromaglow.app.core.session.SessionShellCommands
import com.chromaglow.app.feature.testing.BRIDGE_A
import com.chromaglow.app.feature.testing.BRIDGE_B
import com.chromaglow.app.feature.testing.FakeLiveHome
import com.chromaglow.app.feature.testing.Fixtures
import com.chromaglow.app.feature.testing.homeOf
import com.chromaglow.app.feature.testing.snapshot
import com.chromaglow.app.ui.components.ConnectionTone
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class LiveSettingsViewModelTest {

    private class RecordingShell : SessionShellCommands {
        val forgotten = mutableListOf<BridgeId>()
        var exits = 0
        override fun forgetBridge(bridgeId: BridgeId) { forgotten += bridgeId }
        override fun exitToSetup() { exits++ }
    }

    private val dispatcher = StandardTestDispatcher()
    private val shell = RecordingShell()

    @Before fun setUp() = Dispatchers.setMain(dispatcher)
    @After fun tearDown() = Dispatchers.resetMain()

    private fun vm(home: HomeSnapshot = Fixtures.home()) =
        LiveSettingsViewModel(FakeLiveHome(home), shell, appVersion = "1.0", clock = { 0L })

    @Test
    fun mapsBridgesWithStatus_modeAndVersion() {
        val s = vm(homeOf(snapshot(bridge = BRIDGE_A) to ConnectionState.Connected, snapshot(bridge = BRIDGE_B) to ConnectionState.Offline)).uiState.value
        assertEquals("Live Mode", s.modeLabel)
        assertEquals("1.0", s.appVersion)
        assertEquals(listOf(BRIDGE_A, BRIDGE_B), s.bridges.map { it.bridgeId })
        assertEquals(listOf("Bridge …0001", "Bridge …0002"), s.bridges.map { it.label })
        assertEquals(ConnectionTone.LIVE, s.bridges[0].row.tone)
        assertEquals(ConnectionTone.BLOCKED, s.bridges[1].row.tone)
        assertNull(s.confirmingForget)
    }

    @Test
    fun forget_isTwoStep_andRoutesToShellOnlyOnConfirm() = runTest(dispatcher) {
        val vm = vm()
        vm.requestForget(BRIDGE_A)
        assertEquals(BRIDGE_A, vm.uiState.first { it.confirmingForget != null }.confirmingForget)
        assertTrue(shell.forgotten.isEmpty())
        vm.confirmForget()
        assertEquals(listOf(BRIDGE_A), shell.forgotten)
        assertNull(vm.uiState.first { it.confirmingForget == null }.confirmingForget)
    }

    @Test
    fun cancel_closesWithoutForgetting() = runTest(dispatcher) {
        val vm = vm()
        vm.requestForget(BRIDGE_A)
        vm.cancelForget()
        vm.confirmForget() // nothing is open
        assertTrue(shell.forgotten.isEmpty())
        assertNull(vm.uiState.first { it.confirmingForget == null }.confirmingForget)
    }

    @Test
    fun unknownBridge_cannotBeForgotten() {
        val vm = vm()
        vm.requestForget(BRIDGE_B)
        vm.confirmForget()
        assertTrue(shell.forgotten.isEmpty())
        assertEquals(0, shell.exits)
    }

    @Test
    fun noBridges_emptyListNoConfirm() {
        val s = vm(HomeSnapshot(emptyMap(), emptyMap())).uiState.value
        assertTrue(s.bridges.isEmpty())
        assertNull(s.confirmingForget)
    }
}
