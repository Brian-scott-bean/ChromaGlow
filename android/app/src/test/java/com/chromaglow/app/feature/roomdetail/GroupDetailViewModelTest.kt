package com.chromaglow.app.feature.roomdetail

import com.chromaglow.app.core.hue.capability.CieXy
import com.chromaglow.app.core.identity.TargetRef
import com.chromaglow.app.core.session.ConnectionState
import com.chromaglow.app.core.session.LiveMutation
import com.chromaglow.app.core.session.MutationEvent
import com.chromaglow.app.core.session.MutationFailure
import com.chromaglow.app.core.session.RefusalReason
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertNull
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

    @Test
    fun groupColourAndWarmth_addressTheGroupKey_andClampWarmthToProtocol() {
        val vm = vm()
        vm.setGroupColor(CieXy(0.4, 0.4))
        vm.setGroupColorTemperature(9000)
        vm.setGroupColorTemperature(10)
        assertEquals(
            listOf<Call>(
                Call.LightColor(TargetRef.Live(Fixtures.livingRoom), CieXy(0.4, 0.4)),
                Call.LightCt(TargetRef.Live(Fixtures.livingRoom), 500),
                Call.LightCt(TargetRef.Live(Fixtures.livingRoom), 153),
            ),
            commands.calls,
        )
    }

    @Test
    fun groupColour_refusedWhenNoMemberIsColourCapable() {
        liveHome.emit(Fixtures.home())
        val vm = GroupDetailViewModel(liveHome, commands, Fixtures.bedroom, clock = { 0L }) // CT-only member
        vm.setGroupColor(CieXy(0.4, 0.4))
        vm.setGroupColorTemperature(300)
        assertEquals(listOf<Call>(Call.LightCt(TargetRef.Live(Fixtures.bedroom), 300)), commands.calls)
    }

    @Test
    fun groupInstruments_refusedOffline() {
        val vm = vm(ConnectionState.Offline)
        vm.setGroupColor(CieXy(0.4, 0.4))
        vm.setGroupColorTemperature(300)
        assertTrue(commands.calls.isEmpty())
    }

    @Test
    fun feedback_coversGroupedLight_groupKey_andMembers_notOtherRooms() = runTest(dispatcher) {
        val vm = vm(); runCurrent()
        liveHome.emitEvent(MutationEvent.Refused(LiveMutation.SetColor(Fixtures.livingRoom, CieXy(0.4, 0.4)), RefusalReason.CAPABILITY_NOT_KNOWN))
        runCurrent()
        assertEquals("Living Room colour can't be set yet. Still checking what these lights can do.", vm.feedback.value!!.message)
        liveHome.emitEvent(MutationEvent.Failed(LiveMutation.SetBrightness(Fixtures.lampColor, 10), MutationFailure.TRANSPORT, rolledBack = true))
        runCurrent()
        assertEquals("Floor Lamp brightness couldn't be changed. Reverted.", vm.feedback.value!!.message)
        vm.dismissFeedback(vm.feedback.value!!)
        liveHome.emitEvent(MutationEvent.Refused(LiveMutation.SetPower(Fixtures.bedGrouped, true), RefusalReason.OFFLINE))
        runCurrent()
        assertNull(vm.feedback.value) // another room's grouped light is not this screen's feedback
    }
}
