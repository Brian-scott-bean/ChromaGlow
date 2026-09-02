package com.chromaglow.app.feature.home

import com.chromaglow.app.core.identity.TargetRef
import com.chromaglow.app.core.session.ConnectionState
import com.chromaglow.app.core.session.RefreshReason
import com.chromaglow.app.feature.testing.FakeLiveHome
import com.chromaglow.app.feature.testing.Fixtures
import com.chromaglow.app.feature.testing.RecordingHomeCommands
import com.chromaglow.app.feature.testing.RecordingHomeCommands.Call
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class HomeViewModelTest {

    private val dispatcher = StandardTestDispatcher()
    private val liveHome = FakeLiveHome(Fixtures.home())
    private val commands = RecordingHomeCommands()

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    private fun viewModel() = HomeViewModel(liveHome, commands, clock = { 0L })

    @Test
    fun initialState_isMappedSynchronously_fromCurrentHome() {
        val vm = viewModel()
        assertEquals(HomePhase.CONTENT, vm.uiState.value.phase)
        assertEquals(2, vm.uiState.value.rooms.size)
    }

    @Test
    fun homeUpdates_flowIntoUiState() = runTest(dispatcher) {
        val vm = viewModel()
        liveHome.emit(Fixtures.home(ConnectionState.Offline))
        val state = vm.uiState.first { it.rooms.all { card -> !card.controlsEnabled } }
        assertTrue(state.rooms.all { !it.controlsEnabled })
    }

    @Test
    fun setGroupPower_forwardsExactLiveTarget() {
        val vm = viewModel()
        val living = vm.uiState.value.rooms.first { it.name == "Living Room" }
        vm.setGroupPower(living, false)
        assertEquals(listOf<Call>(Call.GroupPower(TargetRef.Live(Fixtures.livingGrouped), false)), commands.calls)
    }

    @Test
    fun setGroupBrightness_clampsAndForwards() {
        val vm = viewModel()
        val living = vm.uiState.value.rooms.first { it.name == "Living Room" }
        vm.setGroupBrightness(living, 0)
        vm.setGroupBrightness(living, 250)
        assertEquals(
            listOf<Call>(
                Call.GroupBrightness(TargetRef.Live(Fixtures.livingGrouped), 1),
                Call.GroupBrightness(TargetRef.Live(Fixtures.livingGrouped), 100),
            ),
            commands.calls,
        )
    }

    @Test
    fun disabledCard_neverAsksTheCoordinator() {
        val vm = viewModel()
        val disabled = vm.uiState.value.rooms.first().copy(controlsEnabled = false, disabledReason = "Bridge offline")
        vm.setGroupPower(disabled, true)
        vm.setGroupBrightness(disabled, 50)
        assertTrue(commands.calls.isEmpty())
    }

    @Test
    fun cardWithoutTarget_neverAsksTheCoordinator() {
        val vm = viewModel()
        val noTarget = vm.uiState.value.rooms.first().copy(target = null)
        vm.setGroupPower(noTarget, true)
        assertTrue(commands.calls.isEmpty())
    }

    @Test
    fun refresh_isUserPull() {
        viewModel().refresh()
        assertEquals(listOf<Call>(Call.Refresh(RefreshReason.USER_PULL)), commands.calls)
    }
}
