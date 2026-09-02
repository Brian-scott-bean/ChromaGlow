package com.chromaglow.app.feature.home

import com.chromaglow.app.core.hue.capability.CieXy
import com.chromaglow.app.core.session.ConnectionState
import com.chromaglow.app.core.session.LiveMutation
import com.chromaglow.app.core.session.MutationEvent
import com.chromaglow.app.core.session.MutationFailure
import com.chromaglow.app.core.session.RefusalReason
import com.chromaglow.app.feature.testing.BRIDGE_A
import com.chromaglow.app.feature.testing.BRIDGE_B
import com.chromaglow.app.feature.testing.FakeLiveHome
import com.chromaglow.app.feature.testing.Fixtures
import com.chromaglow.app.feature.testing.RecordingHomeCommands
import com.chromaglow.app.feature.testing.homeOf
import com.chromaglow.app.feature.testing.snapshot
import com.chromaglow.app.ui.components.FeedbackKind
import com.chromaglow.app.ui.components.MutationFeedbackCopy
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class HomeFeedbackAndNamesTest {

    private val dispatcher = StandardTestDispatcher()
    private val liveHome = FakeLiveHome(Fixtures.home())
    private val commands = RecordingHomeCommands()

    @Before fun setUp() = Dispatchers.setMain(dispatcher)
    @After fun tearDown() = Dispatchers.resetMain()

    private fun vm() = HomeViewModel(liveHome, commands, clock = { 0L })

    @Test
    fun refusedGroupedWrite_showsRefusedCopy_namingTheGroup() = runTest(dispatcher) {
        val vm = vm(); runCurrent()
        liveHome.emitEvent(MutationEvent.Refused(LiveMutation.SetBrightness(Fixtures.livingGrouped, 40), RefusalReason.OFFLINE))
        runCurrent()
        val f = vm.feedback.value!!
        assertEquals(FeedbackKind.REFUSED, f.kind)
        assertEquals("Living Room brightness wasn't sent. The bridge is offline.", f.message)
    }

    @Test
    fun failedRolledBack_saysReverted_andDismissClears() = runTest(dispatcher) {
        val vm = vm(); runCurrent()
        liveHome.emitEvent(MutationEvent.Failed(LiveMutation.SetPower(Fixtures.bedGrouped, true), MutationFailure.HTTP_ERROR, rolledBack = true))
        runCurrent()
        val f = vm.feedback.value!!
        assertEquals(FeedbackKind.FAILED_REVERTED, f.kind)
        assertEquals("Bedroom power couldn't be changed. Reverted.", f.message)
        vm.dismissFeedback(f)
        assertNull(vm.feedback.value)
    }

    @Test
    fun ambiguousTimeout_isFailedUnknown_withRefreshingCopy_noRawError() = runTest(dispatcher) {
        val vm = vm(); runCurrent()
        liveHome.emitEvent(MutationEvent.Failed(LiveMutation.SetBrightness(Fixtures.livingGrouped, 40), MutationFailure.TIMEOUT_AMBIGUOUS, rolledBack = false))
        runCurrent()
        val f = vm.feedback.value!!
        assertEquals(FeedbackKind.FAILED_UNKNOWN, f.kind)
        assertEquals("Couldn't confirm the change to Living Room brightness. Refreshing.", f.message)
        assertFalse(f.message.contains("TIMEOUT"))
    }

    @Test
    fun appliedIsSilent_andPerLightEventsAreNotHomeFeedback() = runTest(dispatcher) {
        val vm = vm(); runCurrent()
        liveHome.emitEvent(MutationEvent.Applied(LiveMutation.SetPower(Fixtures.livingGrouped, true)))
        liveHome.emitEvent(MutationEvent.Refused(LiveMutation.SetColor(Fixtures.lampColor, CieXy(0.4, 0.4)), RefusalReason.OFFLINE))
        runCurrent()
        assertNull(vm.feedback.value)
    }

    @Test
    fun dismissingAnOlderMessage_keepsANewerOne() = runTest(dispatcher) {
        val vm = vm(); runCurrent()
        liveHome.emitEvent(MutationEvent.Refused(LiveMutation.SetPower(Fixtures.livingGrouped, true), RefusalReason.OFFLINE))
        runCurrent()
        val first = vm.feedback.value!!
        liveHome.emitEvent(MutationEvent.Refused(LiveMutation.SetPower(Fixtures.bedGrouped, true), RefusalReason.OFFLINE))
        runCurrent()
        vm.dismissFeedback(first)
        assertTrue(vm.feedback.value!!.message.startsWith("Bedroom"))
    }

    @Test
    fun bridgeNames_labelTheStrip_fallbackOtherwise() = runTest(dispatcher) {
        val home = FakeLiveHome(homeOf(snapshot(bridge = BRIDGE_A) to ConnectionState.Connected, snapshot(bridge = BRIDGE_B) to ConnectionState.Connected))
        home.name(BRIDGE_A, "Downstairs")
        val vm = HomeViewModel(home, commands, clock = { 0L })
        val sub = vm.uiState.launchIn(this); runCurrent()
        assertEquals(listOf("Downstairs", "Bridge …0002"), vm.uiState.value.strip.map { it.bridgeLabel })
        home.name(BRIDGE_B, "Upstairs"); runCurrent()
        assertEquals(listOf("Downstairs", "Upstairs"), vm.uiState.value.strip.map { it.bridgeLabel })
        sub.cancel()
    }

    @Test
    fun copy_coversEveryRefusalReason_withoutIdentifiers() {
        RefusalReason.entries.forEach { reason ->
            val f = MutationFeedbackCopy.from(MutationEvent.Refused(LiveMutation.SetPower(Fixtures.livingGrouped, true), reason), 1) { "Living Room" }!!
            assertTrue(reason.name, f.message.isNotBlank())
            assertFalse(reason.name, f.message.contains(reason.name))
            assertFalse(f.message.contains(BRIDGE_A.value))
        }
        MutationFailure.entries.forEach { failure ->
            val f = MutationFeedbackCopy.from(MutationEvent.Failed(LiveMutation.RecallScene(Fixtures.sceneRelax), failure, rolledBack = false), 1) { "Relax" }!!
            assertTrue(f.message.startsWith("Couldn't confirm the change to The scene Relax") || f.message.startsWith("The scene Relax"))
            assertFalse(f.message.contains(failure.name))
        }
    }
}
