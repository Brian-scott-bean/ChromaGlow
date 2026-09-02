package com.chromaglow.app.feature.scenes

import com.chromaglow.app.core.identity.TargetRef
import com.chromaglow.app.core.session.ConnectionState
import com.chromaglow.app.feature.testing.FakeLiveHome
import com.chromaglow.app.feature.testing.Fixtures
import com.chromaglow.app.feature.testing.RecordingHomeCommands
import com.chromaglow.app.feature.testing.RecordingHomeCommands.Call
import com.chromaglow.app.feature.testing.homeOf
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class LiveScenesViewModelTest {

    private val dispatcher = StandardTestDispatcher()
    private val liveHome = FakeLiveHome(Fixtures.home())
    private val commands = RecordingHomeCommands()

    @Before fun setUp() = Dispatchers.setMain(dispatcher)
    @After fun tearDown() = Dispatchers.resetMain()

    private fun vm() = LiveScenesViewModel(liveHome, commands, clock = { 0L }, activationTimeoutMillis = 4_000, failureDisplayMillis = 4_000)

    private fun LiveScenesUiState.row(name: String): SceneRowUi =
        sections.flatMap { it.groups }.flatMap { it.scenes }.first { it.name == name }

    @Test
    fun activate_forwardsExactTarget_andMarksActivating() = runTest(dispatcher) {
        val vm = vm()
        val sub: Job = vm.uiState.launchIn(this)
        runCurrent()
        vm.activate(vm.uiState.value.row("Bright"))
        runCurrent()
        assertEquals(listOf<Call>(Call.Scene(TargetRef.Live(Fixtures.sceneBright))), commands.calls)
        assertEquals(SceneActivation.ACTIVATING, vm.uiState.value.row("Bright").activation)
        sub.cancel()
    }

    @Test
    fun snapshotConfirmation_turnsActivatingIntoActive_andSuppressesTimeoutFailure() = runTest(dispatcher) {
        val vm = vm()
        val sub = vm.uiState.launchIn(this)
        runCurrent()
        vm.activate(vm.uiState.value.row("Bright"))
        runCurrent()
        // SSE/refresh confirms: Bright active, Relax cleared on the bridge.
        val confirmed = Fixtures.bridgeA().let { s ->
            s.copy(scenes = s.scenes.mapValues { (k, v) -> v.copy(isActive = k == Fixtures.sceneBright) })
        }
        liveHome.emit(homeOf(confirmed to ConnectionState.Connected))
        runCurrent()
        assertEquals(SceneActivation.ACTIVE, vm.uiState.value.row("Bright").activation)
        assertEquals(SceneActivation.IDLE, vm.uiState.value.row("Relax").activation)
        advanceTimeBy(10_000); runCurrent()
        assertEquals(SceneActivation.ACTIVE, vm.uiState.value.row("Bright").activation)
        sub.cancel()
    }

    @Test
    fun noConfirmation_becomesFailed_thenClears() = runTest(dispatcher) {
        val vm = vm()
        val sub = vm.uiState.launchIn(this)
        runCurrent()
        vm.activate(vm.uiState.value.row("Bright"))
        advanceTimeBy(4_001); runCurrent()
        assertEquals(SceneActivation.FAILED, vm.uiState.value.row("Bright").activation)
        advanceTimeBy(4_001); runCurrent()
        assertEquals(SceneActivation.IDLE, vm.uiState.value.row("Bright").activation)
        sub.cancel()
    }

    @Test
    fun activatingRow_isNotReSent() = runTest(dispatcher) {
        val vm = vm()
        val sub = vm.uiState.launchIn(this)
        runCurrent()
        vm.activate(vm.uiState.value.row("Bright"))
        runCurrent()
        vm.activate(vm.uiState.value.row("Bright"))
        runCurrent()
        assertEquals(1, commands.calls.size)
        sub.cancel()
    }

    @Test
    fun disabledRow_neverSends() = runTest(dispatcher) {
        liveHome.emit(Fixtures.home(ConnectionState.Offline))
        val vm = vm()
        vm.activate(vm.uiState.value.row("Bright"))
        assertTrue(commands.calls.isEmpty())
    }

    @Test
    fun otherGroupActive_isUntouchedByActivation() = runTest(dispatcher) {
        val vm = vm()
        val sub = vm.uiState.launchIn(this)
        runCurrent()
        vm.activate(vm.uiState.value.row("Nightlight"))
        runCurrent()
        assertEquals(SceneActivation.ACTIVE, vm.uiState.value.row("Relax").activation)
        assertEquals(SceneActivation.ACTIVATING, vm.uiState.value.row("Nightlight").activation)
        sub.cancel()
    }
}
