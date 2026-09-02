package com.chromaglow.app.core.session

import com.chromaglow.app.core.hue.sse.EventStreamHttpException
import com.chromaglow.app.core.identity.ResourceType
import com.chromaglow.app.testing.CoordinatorHarness
import com.chromaglow.app.testing.FakeEventStream
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class EventStreamRunnerTest {

    @Test
    fun backoffPolicy_isFiveTenTwentyFortySixtyCapped() {
        assertEquals(listOf(5_000L, 10_000L, 20_000L, 40_000L, 60_000L, 60_000L, 60_000L), (0..6).map { BackoffPolicy.delayMillis(it) })
        assertEquals(60_000L, BackoffPolicy.CAP_MILLIS)
        assertEquals(5_000L, BackoffPolicy.delayMillis(-3))
    }

    private fun runner(h: CoordinatorHarness, stream: FakeEventStream) = EventStreamRunner(h.env, stream, h.authority)

    @Test
    fun reconnectSchedule_followsTheBackoff_andResetsOnASuccessfulConnection() = runTest {
        val h = CoordinatorHarness(this)
        val stream = FakeEventStream(h.bridge) { testScheduler.currentTime }
        repeat(6) { stream.scripts += FakeEventStream.failing() }
        stream.scripts += FakeEventStream.connectedThenDrop()
        stream.scripts += FakeEventStream.connectedAndHang()
        val r = runner(h, stream)

        r.onForeground()
        advanceTimeBy(500_000)
        runCurrent()

        // 6 failures: opens at 0, 5, 15, 35, 75, 135 s; the 7th open (195 s) connects then drops,
        // so the backoff is reset and the 8th open follows after only 5 s.
        assertEquals(listOf(0L, 5_000L, 15_000L, 35_000L, 75_000L, 135_000L, 195_000L, 200_000L), stream.opens)
        assertEquals(StreamState.Connected, r.state.value)
        r.close()
    }

    @Test
    fun background_cancelsTheStream_andForeground_reconnects_neverTwoStreams() = runTest {
        val h = CoordinatorHarness(this)
        val stream = FakeEventStream(h.bridge) { testScheduler.currentTime }
        stream.fallback = FakeEventStream.connectedAndHang()
        val r = runner(h, stream)

        r.onForeground()
        r.onForeground()
        runCurrent()
        assertEquals("a start while running is a no-op", 1, stream.openCount)
        assertEquals(StreamState.Connected, r.state.value)

        r.onBackground()
        runCurrent()
        assertEquals(StreamState.Stopped, r.state.value)
        advanceTimeBy(600_000)
        assertEquals("no reconnect while backgrounded", 1, stream.openCount)

        r.onForeground()
        runCurrent()
        assertEquals(2, stream.openCount)
        assertEquals(StreamState.Connected, r.state.value)
        r.close()
        assertEquals(StreamState.Stopped, r.state.value)
    }

    @Test
    fun authNoiseOnTheStream_isTransient_andNeverReportsUnauthorized() = runTest {
        val h = CoordinatorHarness(this)
        val stream = FakeEventStream(h.bridge) { testScheduler.currentTime }
        stream.scripts += FakeEventStream.failing(EventStreamHttpException(401))
        stream.scripts += FakeEventStream.failing(EventStreamHttpException(403))
        stream.fallback = FakeEventStream.connectedAndHang()
        val r = runner(h, stream)

        r.onForeground()
        advanceTimeBy(20_000)
        runCurrent()

        assertTrue(h.unauthorized.isEmpty())
        assertEquals(3, stream.openCount)
        assertEquals(StreamState.Connected, r.state.value)
        r.close()
    }

    @Test
    fun aReconnection_requestsAnAuthoritativeRefresh_theFirstConnectionDoesNot() = runTest {
        val h = CoordinatorHarness(this)
        val stream = FakeEventStream(h.bridge) { testScheduler.currentTime }
        stream.scripts += FakeEventStream.connectedThenDrop()
        stream.fallback = FakeEventStream.connectedAndHang()
        val r = runner(h, stream)

        r.onForeground()
        runCurrent()
        assertTrue(h.refreshes.isEmpty())
        advanceTimeBy(6_000)
        runCurrent()
        assertEquals(listOf(RefreshReason.STREAM_RECONNECTED), h.refreshes)
        r.close()
    }

    @Test
    fun dataFrames_areReducedIntoTheStore_underTheSharedAuthority() = runTest {
        val h = CoordinatorHarness(this)
        val stream = FakeEventStream(h.bridge) { testScheduler.currentTime }
        val off = """[{"type":"update","data":[{"id":"${h.colorLamp.id}","type":"light","on":{"on":false},"dimming":{"brightness":7}}]}]"""
        stream.fallback = FakeEventStream.connectedAndHang(off)
        val r = runner(h, stream)
        // A pending brightness from the coordinator fences only the DIMMING field of the event.
        h.coordinator.submit(LiveMutation.SetBrightness(h.colorLamp, 90))

        r.onForeground()
        runCurrent()

        val lamp = h.light(h.colorLamp)
        assertFalse(lamp.isOn)
        assertEquals(90.0, lamp.brightness!!, 0.0)
        advanceUntilIdle()
        assertEquals(ResourceType.LIGHT, h.transport.puts().single().type)
        r.close()
    }
}
