package com.chromaglow.app.core.session

import com.chromaglow.app.core.hue.rest.BridgeIdentityProbe
import com.chromaglow.app.core.hue.rest.BridgeProbeResult
import com.chromaglow.app.core.hue.rest.ClipError
import com.chromaglow.app.core.hue.rest.HueClipClient
import com.chromaglow.app.core.identity.BridgeId
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.plus

/**
 * What a session hands to its attachments (the MutationCoordinator in P5, the stream runner in
 * P6). Everything a collaborator needs to read/write this bridge's state without reaching into
 * the session object or any other bridge.
 */
class SessionEnvironment internal constructor(
    val bridgeId: BridgeId,
    val scope: CoroutineScope,
    val transport: HueClipClient,
    val store: SnapshotStore,
    val connection: StateFlow<ConnectionState>,
    val clock: SessionClock,
    val requestRefresh: (RefreshReason) -> Unit,
    /** Report an explicit 401/403 seen on any path (REST only; SSE auth noise must NOT call this). */
    val reportUnauthorized: (status: Int) -> Unit,
)

/** A per-session collaborator with a lifecycle bound to foreground/background. */
interface SessionAttachment {
    fun onForeground() {}
    fun onBackground() {}
    fun close() {}
}

/**
 * ONE bridge's live session. Owns: its child supervisor scope, snapshot store, credentials,
 * cache, generation-fenced loader, connection truth, and the attachments created through the
 * injected factories. Knows nothing about any other bridge.
 *
 * Start order: credentials → cache (paint Stale FROM_CACHE) → authoritative network load. A
 * record without a readable token never touches the network (Error(LOCAL_STORAGE)). 401/403 on
 * a REST call → Revoked: the key is dropped from memory, the stream is stopped, the record and the
 * stored token are kept. Timeouts, 5xx and stream failures never touch credentials.
 */
class DefaultBridgeSession(
    override val bridgeId: BridgeId,
    parentScope: CoroutineScope,
    private val transport: HueClipClient,
    private val credentials: SessionCredentials,
    private val cache: BridgeSnapshotCache,
    private val clock: SessionClock,
    coordinatorFactory: (SessionEnvironment) -> MutationCoordinator,
    private val attachmentFactories: List<(SessionEnvironment) -> SessionAttachment> = emptyList(),
    private val probeBridgeIdentity: Boolean = true,
) : BridgeSession {

    private val supervisor = SupervisorJob(parentScope.coroutineContext[Job])
    private val scope: CoroutineScope = parentScope + supervisor

    private val store = SnapshotStore(BridgeSnapshot.empty(bridgeId))
    private val connectionState = MutableStateFlow<ConnectionState>(ConnectionState.Connecting)
    private val loader = BridgeLoader(transport)
    private val refreshRequests = Channel<RefreshReason>(Channel.CONFLATED)

    /** Secret-free diagnostics (probe result, load failures). */
    private val diagnosticsLog = ArrayDeque<String>()
    val diagnostics: List<String> get() = synchronized(diagnosticsLog) { diagnosticsLog.toList() }

    @Volatile
    private var closed = false

    @Volatile
    private var revoked = false

    @Volatile
    private var started = false

    val environment: SessionEnvironment = SessionEnvironment(
        bridgeId = bridgeId,
        scope = scope,
        transport = transport,
        store = store,
        connection = connectionState,
        clock = clock,
        requestRefresh = ::requestRefresh,
        reportUnauthorized = ::onUnauthorized,
    )

    private val coordinator: MutationCoordinator = coordinatorFactory(environment)
    private val attachments: List<SessionAttachment> = attachmentFactories.map { it(environment) }

    override val snapshot: StateFlow<BridgeSnapshot> get() = store.flow
    override val connection: StateFlow<ConnectionState> get() = connectionState

    /** Idempotent. Launches the refresh worker and the initial load sequence. */
    fun start() {
        if (started || closed) return
        started = true
        scope.launch { refreshWorker() }
        scope.launch { initialise() }
    }

    private suspend fun initialise() {
        when (credentials.load()) {
            CredentialState.Loaded -> Unit
            CredentialState.Absent, CredentialState.Unreadable, CredentialState.Dropped -> {
                // The approved repair/unavailable state: no network at all, nothing deleted.
                connectionState.value = ConnectionState.Error(SessionErrorReason.LOCAL_STORAGE)
                return
            }
        }
        when (val cached = cache.read()) {
            is CacheReadResult.Hit -> store.update { cached.snapshot }
            is CacheReadResult.Discarded -> note("cache discarded: ${cached.reason}")
            CacheReadResult.Miss -> Unit
        }
        if (probeBridgeIdentity) {
            when (val probe = BridgeIdentityProbe(transport).probe()) {
                BridgeProbeResult.Match -> note("bridge probe: match")
                is BridgeProbeResult.Mismatch -> note("bridge probe: MISMATCH (diagnostic only)")
                is BridgeProbeResult.Malformed -> note("bridge probe: malformed (${probe.reason})")
                is BridgeProbeResult.Unavailable -> {
                    note("bridge probe: unavailable (${probe.error::class.simpleName})")
                    (probe.error as? ClipError.Unauthorized)?.let { onUnauthorized(it.status) }
                }
            }
        }
        requestRefresh(RefreshReason.SESSION_START)
        attachments.forEach { it.onForeground() }
    }

    private suspend fun refreshWorker() {
        for (reason in refreshRequests) {
            if (closed || revoked) continue
            if (credentials.state != CredentialState.Loaded) continue
            when (val outcome = loader.load()) {
                is LoadOutcome.Loaded -> {
                    store.update { outcome.snapshot }
                    connectionState.value = ConnectionState.Connected
                    cache.write(outcome.snapshot)
                }
                is LoadOutcome.Unauthorized -> onUnauthorized(outcome.status)
                is LoadOutcome.Failed -> onLoadFailed(outcome.error)
                LoadOutcome.Superseded -> Unit
            }
        }
    }

    private fun onLoadFailed(error: ClipError) {
        note("load failed: ${error::class.simpleName}")
        val hasSnapshot = store.value.generation > 0 || store.value.lights.isNotEmpty() || store.value.rooms.isNotEmpty()
        if (error is ClipError.Unauthorized) return onUnauthorized(error.status)
        connectionState.value = when (error) {
            ClipError.TlsIdentity -> ConnectionState.Error(SessionErrorReason.TLS_IDENTITY)
            ClipError.MissingCredentials -> ConnectionState.Error(SessionErrorReason.LOCAL_STORAGE)
            is ClipError.BridgeRejected -> if (hasSnapshot) stale() else ConnectionState.Error(SessionErrorReason.BRIDGE_REJECTED)
            else -> if (hasSnapshot) stale() else ConnectionState.Offline
        }
        if (hasSnapshot) {
            store.update { s -> s.copy(freshness = Freshness.Stale(sinceGeneration = s.generation, reason = StaleReason.LOAD_FAILED)) }
        }
    }

    private fun stale(): ConnectionState {
        val current = connectionState.value
        return if (current is ConnectionState.Stale) current else ConnectionState.Stale(clock.nowMillis())
    }

    private fun onUnauthorized(status: Int) {
        if (revoked) return
        revoked = true
        note("unauthorized $status → revoked (record kept)")
        credentials.drop()
        attachments.forEach { it.onBackground() }
        connectionState.value = ConnectionState.Revoked
    }

    override fun requestRefresh(reason: RefreshReason) {
        if (closed) return
        refreshRequests.trySend(reason)
    }

    override suspend fun submit(mutation: LiveMutation): MutationOutcome {
        if (closed) return MutationOutcome.Refused(RefusalReason.SESSION_CLOSED)
        if (mutation.target.bridgeId != bridgeId) return MutationOutcome.Refused(RefusalReason.TARGET_UNKNOWN)
        return coordinator.submit(mutation)
    }

    fun onForeground() {
        if (closed || revoked) return
        attachments.forEach { it.onForeground() }
        requestRefresh(RefreshReason.FOREGROUND)
    }

    fun onBackground() {
        if (closed) return
        attachments.forEach { it.onBackground() }
    }

    override fun close() {
        if (closed) return
        closed = true
        attachments.forEach { runCatching { it.close() } }
        refreshRequests.close()
        supervisor.cancel()
        scope.cancel()
    }

    private fun note(line: String) {
        synchronized(diagnosticsLog) {
            diagnosticsLog.addLast(line)
            while (diagnosticsLog.size > MAX_DIAGNOSTICS) diagnosticsLog.removeFirst()
        }
    }

    private companion object {
        const val MAX_DIAGNOSTICS = 32
    }
}
