package com.chromaglow.app.core.session

import com.chromaglow.app.core.hue.capability.CieXy
import com.chromaglow.app.core.identity.BridgeId
import com.chromaglow.app.core.identity.DemoTargetId
import com.chromaglow.app.core.identity.ResourceId
import com.chromaglow.app.core.identity.ResourceKey
import com.chromaglow.app.core.identity.ResourceType
import com.chromaglow.app.core.identity.TargetRef
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LiveHomeCommandsTest {

    private class FakeLiveHome : LiveHome {
        val submitted = mutableListOf<LiveMutation>()
        val refreshes = mutableListOf<RefreshReason>()
        override val home: StateFlow<HomeSnapshot> = MutableStateFlow(HomeSnapshot(emptyMap(), emptyMap()))
        override fun session(bridgeId: BridgeId): BridgeSession? = null
        override fun requestRefresh(reason: RefreshReason) { refreshes += reason }
        override suspend fun submit(mutation: LiveMutation): MutationOutcome { submitted += mutation; return MutationOutcome.Accepted(MutationToken(1)) }
        override fun onForeground() = Unit
        override fun onBackground() = Unit
        override fun remove(bridgeId: BridgeId) = Unit
        override fun close() = Unit
    }

    private val key = ResourceKey(BridgeId("001788FFFE112233"), ResourceType.LIGHT, ResourceId("l1"))
    private val live = TargetRef.Live(key)
    private val demo = TargetRef.Demo(DemoTargetId("demo-bridge-main", "l1"))

    @Test
    fun everyCommand_mapsToExactlyOneMutation_onTheSameKey() = runTest {
        val home = FakeLiveHome()
        val outcomes = mutableListOf<MutationOutcome>()
        val commands = LiveHomeCommands(home, CoroutineScope(StandardTestDispatcher(testScheduler))) { _, o -> outcomes += o }

        commands.setLightPower(live, true)
        commands.setLightBrightness(live, 250)
        commands.setGroupBrightness(live, -4)
        commands.setLightColor(live, CieXy(0.2, 0.4))
        commands.setLightColorTemperature(live, 300)
        commands.selectEffect(live, "candle", EffectParameters(speed = 0.5))
        commands.stopEffect(live)
        commands.startTimedEffect(live, TimedEffect.SUNSET, 99_999_999L)
        commands.cancelTimedEffect(live)
        commands.setGradient(live, List(7) { CieXy(0.3, 0.3) }, "interpolated_palette")
        commands.activateScene(live)
        commands.refresh(RefreshReason.USER_PULL)
        advanceUntilIdle()

        assertEquals(11, home.submitted.size)
        assertTrue(home.submitted.all { it.target == key })
        assertEquals(100, (home.submitted[1] as LiveMutation.SetBrightness).percent)
        assertEquals(1, (home.submitted[2] as LiveMutation.SetBrightness).percent)
        assertEquals(LiveMutation.MAX_TIMED_EFFECT_MILLIS, (home.submitted[7] as LiveMutation.StartTimedEffect).durationMillis)
        assertEquals(5, (home.submitted[9] as LiveMutation.SetGradient).points.size)
        assertEquals(listOf(RefreshReason.USER_PULL), home.refreshes)
        assertEquals(11, outcomes.size)
    }

    @Test
    fun demoTargets_andBlankOrEmptyInputs_produceNoMutation() = runTest {
        val home = FakeLiveHome()
        val commands = LiveHomeCommands(home, CoroutineScope(StandardTestDispatcher(testScheduler)))
        commands.setLightPower(demo, true)
        commands.activateScene(demo)
        commands.selectEffect(live, "  ", EffectParameters())
        commands.setGradient(live, emptyList(), null)
        advanceUntilIdle()
        assertTrue(home.submitted.isEmpty())
    }
}
