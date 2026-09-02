package com.chromaglow.app.core.session

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update

/** Injected monotonic-ish wall time for stale stamps, pacing and the ledger. Tests drive it. */
fun interface SessionClock {
    fun nowMillis(): Long

    companion object {
        val SYSTEM: SessionClock = SessionClock { System.currentTimeMillis() }
    }
}

/**
 * The single owner of one bridge's [BridgeSnapshot]. Every writer (loader, cache paint, SSE
 * reducer, optimistic overlay, rollback) goes through [update], which is atomic per call; the
 * snapshot's own constructor keeps every key bridge-qualified.
 */
class SnapshotStore(initial: BridgeSnapshot) {
    private val state = MutableStateFlow(initial)

    val flow: StateFlow<BridgeSnapshot> get() = state

    val value: BridgeSnapshot get() = state.value

    fun update(transform: (BridgeSnapshot) -> BridgeSnapshot): BridgeSnapshot {
        state.update(transform)
        return state.value
    }
}
