package com.chromaglow.app.core.hue.sse

import com.chromaglow.app.core.identity.BridgeId
import kotlinx.coroutines.flow.Flow

/** One raw server-sent frame from `/eventstream/clip/v2`. Decoding happens in the reducer. */
sealed interface SseFrame {
    /** The stream connected (or reconnected). Resets backoff. */
    data object Connected : SseFrame

    /** One `data:` payload, undecoded. Bounded in size by the transport. */
    data class Data(val payload: String) : SseFrame
}

/**
 * A bridge-qualified SSE source. [open] emits frames until the connection drops, then completes
 * (or throws a transport failure); reconnection, backoff and lifecycle are owned by the session's
 * SSESession, never by the source and never by feature code. Exactly one open stream per bridge.
 */
interface EventStreamSource {
    val bridgeId: BridgeId

    fun open(): Flow<SseFrame>
}
