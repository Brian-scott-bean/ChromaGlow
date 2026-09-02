package com.chromaglow.app.feature.scenes

import com.chromaglow.app.core.identity.TargetRef
import com.chromaglow.app.core.session.ConnectionState
import com.chromaglow.app.core.session.LiveMutation
import com.chromaglow.app.core.session.MutationEvent
import com.chromaglow.app.core.session.MutationFailure
import com.chromaglow.app.core.session.RefusalReason
import com.chromaglow.app.feature.testing.BRIDGE_A
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

    @Test
    fun failedEvent_failsFast_beforeTimeout_andShowsSceneFeedback() = runTest(dispatcher) {
        val vm = vm()
        val sub = vm.uiState.launchIn(this); runCurrent()
        vm.activate(vm.uiState.value.row("Bright")); runCurrent()
        assertEquals(SceneActivation.ACTIVATING, vm.uiState.value.row("Bright").activation)
        liveHome.emitEvent(MutationEvent.Failed(LiveMutation.RecallScene(Fixtures.sceneBright), MutationFailure.REJECTED_BY_BRIDGE, rolledBack = true))
        runCurrent()
        assertEquals(SceneActivation.FAILED, vm.uiState.value.row("Bright").activation)
        assertEquals("The scene Bright couldn't be changed. Reverted.", vm.feedback.value!!.message)
        advanceTimeBy(4_001); runCurrent()
        assertEquals(SceneActivation.IDLE, vm.uiState.value.row("Bright").activation)
        sub.cancel()
    }

    @Test
    fun refusedEvent_failsFast() = runTest(dispatcher) {
        val vm = vm()
        val sub = vm.uiState.launchIn(this); runCurrent()
        vm.activate(vm.uiState.value.row("Bright")); runCurrent()
        liveHome.emitEvent(MutationEvent.Refused(LiveMutation.RecallScene(Fixtures.sceneBright), RefusalReason.OFFLINE))
        runCurrent()
        assertEquals(SceneActivation.FAILED, vm.uiState.value.row("Bright").activation)
        sub.cancel()
    }

    @Test
    fun appliedEvent_keepsActivating_untilSnapshotConfirms() = runTest(dispatcher) {
        val vm = vm()
        val sub = vm.uiState.launchIn(this); runCurrent()
        vm.activate(vm.uiState.value.row("Bright")); runCurrent()
        liveHome.emitEvent(MutationEvent.Applied(LiveMutation.RecallScene(Fixtures.sceneBright)))
        runCurrent()
        assertEquals(SceneActivation.ACTIVATING, vm.uiState.value.row("Bright").activation)
        assertTrue(vm.feedback.value == null)
        sub.cancel()
    }

    @Test
    fun bridgeName_labelsTheSection() = runTest(dispatcher) {
        liveHome.name(BRIDGE_A, "Loft")
        val vm = vm()
        val sub = vm.uiState.launchIn(this); runCurrent()
        assertEquals("Loft", vm.uiState.value.sections.single().bridgeLabel)
        assertEquals("Loft", vm.uiState.value.strip.single().bridgeLabel)
        sub.cancel()
    }
}
