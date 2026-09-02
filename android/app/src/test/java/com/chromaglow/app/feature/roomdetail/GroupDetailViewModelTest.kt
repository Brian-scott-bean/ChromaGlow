package com.chromaglow.app.feature.roomdetail

import com.chromaglow.app.core.identity.TargetRef
import com.chromaglow.app.core.session.ConnectionState
import com.chromaglow.app.feature.testing.FakeLiveHome
import com.chromaglow.app.feature.testing.Fixtures
import com.chromaglow.app.feature.testing.RecordingHomeCommands
import com.chromaglow.app.feature.testing.RecordingHomeCommands.Call
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class GroupDetailViewModelTest {

    private val dispatcher = StandardTestDispatcher()
    private val liveHome = FakeLiveHome(Fixtures.home())
    private val commands = RecordingHomeCommands()

    @Before fun setUp() = Dispatchers.setMain(dispatcher)
    @After fun tearDown() = Dispatchers.resetMain()

    private fun vm(connection: ConnectionState = ConnectionState.Connected): GroupDetailViewModel {
        liveHome.emit(Fixtures.home(connection))
        return GroupDetailViewModel(liveHome, commands, Fixtures.livingRoom, clock = { 0L })
    }

    @Test
    fun groupCommands_targetTheGroupedLight() {
        val vm = vm()
        val g = vm.uiState.value.group!!
        vm.setGroupPower(g, false)
        vm.setGroupBrightness(g, 120)
        assertEquals(
            listOf<Call>(
                Call.GroupPower(TargetRef.Live(Fixtures.livingGrouped), false),
                Call.GroupBrightness(TargetRef.Live(Fixtures.livingGrouped), 100),
            ),
            commands.calls,
        )
    }

    @Test
    fun lightCommands_targetTheExactLight() {
        val vm = vm()
        val floor = vm.uiState.value.lights.first { it.name == "Floor Lamp" }
        vm.setLightPower(floor, false)
        vm.setLightBrightness(floor, 0)
        assertEquals(
            listOf<Call>(
                Call.LightPower(TargetRef.Live(Fixtures.lampColor), false),
                Call.LightBrightness(TargetRef.Live(Fixtures.lampColor), 1),
            ),
            commands.calls,
        )
    }

    @Test
    fun offline_neverCallsCommands() {
        val vm = vm(ConnectionState.Offline)
        val g = vm.uiState.value.group!!
        val l = vm.uiState.value.lights.first()
        vm.setGroupPower(g, true)
        vm.setGroupBrightness(g, 50)
        vm.setLightPower(l, true)
        vm.setLightBrightness(l, 50)
        assertTrue(commands.calls.isEmpty())
    }
}
