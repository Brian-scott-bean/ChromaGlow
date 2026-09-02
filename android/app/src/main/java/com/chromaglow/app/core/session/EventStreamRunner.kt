package com.chromaglow.app.core.session

import com.chromaglow.app.core.hue.sse.EventStreamSource
import com.chromaglow.app.core.hue.sse.SseFrame
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

/** Observable stream truth for diagnostics/UI: secret-free. */
sealed interface StreamState {
    data object Stopped : StreamState
    data object Connecting : StreamState
    data object Connected : StreamState
    data class Waiting(val attempt: Int, val retryInMillis: Long) : StreamState
}

/**
 * ONE event stream per BridgeSession. Owns reconnect (5,10,20,40,60,60… s, reset on a
 * successful connection), lifecycle (background → cancel; foreground → reconnect; the session
 * issues the authoritative refresh first), and reduction of every frame through [EventReducer]
 * under the coordinator's [PendingAuthority]. Never two streams: a start while running is a
 * no-op. A stream failure of ANY kind — including a 401/403 on the stream — is transient here
 * and only schedules a reconnect; revocation is decided solely by the REST client.
 */
class EventStreamRunner(
    private val env: SessionEnvironment,
    private val source: EventStreamSource,
    private val authority: PendingAuthority,
    private val reducer: (BridgeSnapshot, String, PendingAuthority, Long) -> BridgeSnapshot = EventReducer::reduce,
) : SessionAttachment {

    private val stateFlow = MutableStateFlow<StreamState>(StreamState.Stopped)
    val state: StateFlow<StreamState> get() = stateFlow

    private var job: Job? = null
    private var everConnected = false

    /** Number of times the source was opened (diagnostic). */
    var openCount: Int = 0
        private set

    override fun onForeground() = start()

    override fun onBackground() = stop()

    override fun close() = stop()

    fun start() {
        if (job?.isActive == true) return
        job = env.scope.launch { run() }
    }

    fun stop() {
        job?.cancel()
        job = null
        stateFlow.value = StreamState.Stopped
    }

    private suspend fun run() {
        var attempt = 0
        while (true) {
            stateFlow.value = StreamState.Connecting
            try {
                openCount++
                source.open().collect { frame ->
                    when (frame) {
                        SseFrame.Connected -> {
                            attempt = 0
                            stateFlow.value = StreamState.Connected
                            // A RE-connection may have missed events: reconcile authoritatively.
                            if (everConnected) env.requestRefresh(RefreshReason.STREAM_RECONNECTED)
                            everConnected = true
                        }
                        is SseFrame.Data -> {
                            val before = env.store.value
                            val after = env.store.update { s -> reducer(s, frame.payload, authority, env.clock.nowMillis()) }
                            // Only a frame that actually changed the snapshot can make an in-flight load stale (B-17).
                            if (after !== before) env.onStreamEvent()
                        }
                    }
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                // Transport, TLS, HTTP (incl. auth noise), line bound, decode: all transient here.
            }
            val wait = BackoffPolicy.delayMillis(attempt)
            stateFlow.value = StreamState.Waiting(attempt, wait)
            attempt++
            delay(wait)
        }
    }
}
