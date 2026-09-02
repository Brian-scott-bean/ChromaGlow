package com.chromaglow.app.core.session

import com.chromaglow.app.core.identity.BridgeId
import kotlinx.coroutines.flow.StateFlow

/**
 * ONE bridge's live session. Owns its snapshot, cache, loader, coordinator, stream and connection
 * truth. Knows nothing about any other bridge.
 */
interface BridgeSession {
    val bridgeId: BridgeId

    val snapshot: StateFlow<BridgeSnapshot>

    val connection: StateFlow<ConnectionState>

    fun requestRefresh(reason: RefreshReason)

    /** Routes to this session's MutationCoordinator; the only mutation entry for this bridge. */
    suspend fun submit(mutation: LiveMutation): MutationOutcome

    /** Cancels every job owned by the session. Idempotent. Requires no network. */
    fun close()
}

/** The merged view the Home screen renders: every bridge's snapshot and connection, by id. */
data class HomeSnapshot(
    val bridges: Map<BridgeId, BridgeSnapshot>,
    val connections: Map<BridgeId, ConnectionState>,
) {
    init {
        for ((id, snapshot) in bridges) require(snapshot.bridgeId == id) { "snapshot keyed under the wrong bridge" }
    }
}

/**
 * Composes [BridgeSession]s. Permitted responsibilities ONLY: read the registry, create/destroy
 * sessions, merge snapshots, route a mutation to its bridge, fan lifecycle signals. It never
 * parses HTTP, never reduces events, never decides rollback — it is not an orchestrator.
 */
interface LiveHome {
    val home: StateFlow<HomeSnapshot>

    fun session(bridgeId: BridgeId): BridgeSession?

    fun requestRefresh(reason: RefreshReason)

    /** Routes by `mutation.target.bridgeId`; an unknown bridge is refused, never guessed. */
    suspend fun submit(mutation: LiveMutation): MutationOutcome

    fun onForeground()

    fun onBackground()

    /** Tears down the session for [bridgeId]; the shell then performs the local Forget. */
    fun remove(bridgeId: BridgeId)

    fun close()
}
