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
    /** Field-aware optimistic authority shared by this bridge's coordinator and its stream reducer. */
    val authority: PendingAuthority = PendingAuthority(),
    /** Post-admission mutation feedback emitted by the coordinator (C-1). */
    val mutationEvents: kotlinx.coroutines.flow.MutableSharedFlow<MutationEvent> = MutationEvents.sink(),
    /** The stream runner reports every reduced event so a load in flight can be reconciled afterwards (B-06). */
    val onStreamEvent: () -> Unit = {},
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

    /** Lifecycle truth: attachments (the stream) run only while foregrounded (B-05). */
    @Volatile
    private var foregrounded = true

    @Volatile
    private var attachmentsRunning = false

    /** A load is between mint and accept; events reduced meanwhile must be reconciled afterwards (B-06). */
    @Volatile
    private var loadInFlight = false

    @Volatile
    private var eventsDuringLoad = false

    /** The load now running is the single follow-up a stale load earned; events during it never arm another (B-17). */
    @Volatile
    private var currentLoadIsFollowUp = false

    @Volatile
    private var nextLoadIsFollowUp = false

    internal val environment: SessionEnvironment = SessionEnvironment(
        bridgeId = bridgeId,
        scope = scope,
        transport = transport,
        store = store,
        connection = connectionState,
        clock = clock,
        requestRefresh = ::requestRefresh,
        reportUnauthorized = ::onUnauthorized,
        onStreamEvent = { if (loadInFlight && !currentLoadIsFollowUp) eventsDuringLoad = true },
    )

    private val coordinator: MutationCoordinator = coordinatorFactory(environment)
    private val attachments: List<SessionAttachment> = attachmentFactories.map { it(environment) }

    override val snapshot: StateFlow<BridgeSnapshot> get() = store.flow
    override val connection: StateFlow<ConnectionState> get() = connectionState
    override val mutationEvents: kotlinx.coroutines.flow.SharedFlow<MutationEvent> get() = environment.mutationEvents

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
        if (revoked) return // a 401/403 on the probe: no refresh, no stream (B-04)
        requestRefresh(RefreshReason.SESSION_START)
        if (foregrounded) startAttachments()
    }

    private fun startAttachments() {
        if (closed || revoked || attachmentsRunning || credentials.state != CredentialState.Loaded) return
        attachmentsRunning = true
        attachments.forEach { it.onForeground() }
    }

    private fun stopAttachments() {
        if (!attachmentsRunning) return
        attachmentsRunning = false
        attachments.forEach { it.onBackground() }
    }

    private suspend fun refreshWorker() {
        for (reason in refreshRequests) {
            if (closed || revoked) continue
            if (credentials.state != CredentialState.Loaded) continue
            loadInFlight = true
            eventsDuringLoad = false
            currentLoadIsFollowUp = nextLoadIsFollowUp
            nextLoadIsFollowUp = false
            val outcome = try {
                loader.load()
            } catch (cancelled: kotlinx.coroutines.CancellationException) {
                throw cancelled
            } catch (_: RuntimeException) {
                LoadOutcome.Failed(ClipError.Transport(afterTransmission = false)) // A-01: never an uncaught crash
            } finally {
                loadInFlight = false
            }
            when (outcome) {
                is LoadOutcome.Loaded -> {
                    // Unexpired optimistic overlays survive the authoritative load (B-01).
                    store.update { current -> environment.authority.overlayPending(outcome.snapshot, current, clock.nowMillis()) }
                    connectionState.value = ConnectionState.Connected
                    cache.write(outcome.snapshot)
                    if (eventsDuringLoad && !currentLoadIsFollowUp) {
                        // Newer stream truth changed the snapshot while the older GET was in flight:
                        // reconcile ONCE (B-06); the follow-up itself never earns another (B-17).
                        eventsDuringLoad = false
                        nextLoadIsFollowUp = true
                        requestRefresh(RefreshReason.STREAM_RECONNECTED)
                    }
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
        stopAttachments()
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

    /** Contract order: authoritative refresh FIRST, then the stream reconnects (B-05). */
    fun onForeground() {
        foregrounded = true
        if (closed || revoked) return
        requestRefresh(RefreshReason.FOREGROUND)
        startAttachments()
    }

    fun onBackground() {
        foregrounded = false
        if (closed) return
        stopAttachments()
    }

    override fun close() {
        if (closed) return
        closed = true
        attachments.forEach { runCatching { it.close() } }
        (coordinator as? SessionAttachment)?.let { runCatching { it.close() } } // B-10
        refreshRequests.close()
        supervisor.cancel()
        scope.cancel()
        credentials.drop() // A-04: the wipeable key never outlives its session
    }

    /** Every diagnostic line is redacted (header shapes and this session's own key) before it is kept (D-08). */
    private fun note(line: String) {
        val safe = credentials.redact(com.chromaglow.app.core.hue.rest.Redactor.redact(line))
        synchronized(diagnosticsLog) {
            diagnosticsLog.addLast(safe)
            while (diagnosticsLog.size > MAX_DIAGNOSTICS) diagnosticsLog.removeFirst()
        }
    }

    private companion object {
        const val MAX_DIAGNOSTICS = 32
    }
}
