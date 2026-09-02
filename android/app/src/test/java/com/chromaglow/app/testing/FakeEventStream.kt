package com.chromaglow.app.testing

import com.chromaglow.app.core.hue.sse.EventStreamSource
import com.chromaglow.app.core.hue.sse.SseFrame
import com.chromaglow.app.core.identity.BridgeId
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.flow
import java.io.IOException

/** Scripted [EventStreamSource]: each open() plays the next script; records open times. */
class FakeEventStream(
    override val bridgeId: BridgeId,
    private val now: () -> Long = { 0L },
) : EventStreamSource {
    val scripts = ArrayDeque<Flow<SseFrame>>()
    val opens = mutableListOf<Long>()
    val openCount: Int get() = opens.size

    /** Played when the script queue is empty. */
    var fallback: Flow<SseFrame> = flow { throw IOException("no script") }

    override fun open(): Flow<SseFrame> = flow {
        opens += now()
        emitAll(scripts.removeFirstOrNull() ?: fallback)
    }

    companion object {
        fun failing(cause: Throwable = IOException("boom")): Flow<SseFrame> = flow { throw cause }

        /** Connects and holds the connection open until cancelled. */
        fun connectedAndHang(vararg payloads: String): Flow<SseFrame> = flow {
            emit(SseFrame.Connected)
            payloads.forEach { emit(SseFrame.Data(it)) }
            awaitCancellation()
        }

        /** Connects, delivers payloads, then drops. */
        fun connectedThenDrop(vararg payloads: String): Flow<SseFrame> = flow {
            emit(SseFrame.Connected)
            payloads.forEach { emit(SseFrame.Data(it)) }
            throw IOException("dropped")
        }
    }
}
