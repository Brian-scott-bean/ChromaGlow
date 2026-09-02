package com.chromaglow.app.core.session

import com.chromaglow.app.core.bridge.BridgeRegistry
import com.chromaglow.app.core.bridge.BridgeRegistryResult
import com.chromaglow.app.core.bridge.PairedBridgeRecord
import com.chromaglow.app.core.credentials.BridgeCredentialStore
import com.chromaglow.app.core.hue.rest.ApplicationKeyProvider
import com.chromaglow.app.core.hue.rest.HueClipClient
import com.chromaglow.app.core.identity.BridgeId
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch
import kotlinx.coroutines.plus

/** How LiveHome builds per-bridge collaborators. Production wires OkHttp/File/Default; tests inject fakes. */
class LiveHomeFactories(
    val transport: (record: PairedBridgeRecord, bridgeId: BridgeId, keys: ApplicationKeyProvider) -> HueClipClient,
    val cache: (bridgeId: BridgeId) -> BridgeSnapshotCache,
    val coordinator: (SessionEnvironment) -> MutationCoordinator,
    /** Per-session attachments (e.g. the event-stream runner) get the record + key provider too. */
    val attachments: List<(SessionEnvironment, PairedBridgeRecord, ApplicationKeyProvider) -> SessionAttachment> = emptyList(),
    val probeBridgeIdentity: Boolean = true,
)

/**
 * Thin composition of [BridgeSession]s — registry read, session create/destroy, HomeSnapshot
 * merge, routing by `target.bridgeId`, lifecycle fan-out. It never parses HTTP, never reduces
 * events, never decides rollback. Every record with a canonical id gets its own session; a record
 * whose token is missing surfaces as that session's Error(LOCAL_STORAGE), never as a sweep.
 */
class DefaultLiveHome(
    private val registry: BridgeRegistry,
    private val credentialStore: BridgeCredentialStore,
    private val factories: LiveHomeFactories,
    private val clock: SessionClock = SessionClock.SYSTEM,
    parentScope: CoroutineScope? = null,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    mainDispatcher: CoroutineDispatcher = Dispatchers.Main.immediate,
) : LiveHome {

    private val supervisor = SupervisorJob(parentScope?.coroutineContext?.get(Job))
    // A caller-supplied scope keeps its own dispatcher (tests inject a test dispatcher); the
    // production default is a Main.immediate scope so session maps are only touched on one thread.
    private val scope: CoroutineScope = (parentScope ?: CoroutineScope(mainDispatcher)) + supervisor

    private val sessions = LinkedHashMap<BridgeId, DefaultBridgeSession>()
    private val homeState = MutableStateFlow(HomeSnapshot(emptyMap(), emptyMap()))
    private var mergeJob: Job? = null

    /** Registry problems are surfaced here (UNAVAILABLE = corrupt/unreadable metadata), never repaired. */
    sealed interface RegistryStatus {
        data object Ok : RegistryStatus
        data object Unavailable : RegistryStatus
        data object Pending : RegistryStatus
    }

    private val registryStatusState = MutableStateFlow<RegistryStatus>(RegistryStatus.Pending)
    val registryStatus: StateFlow<RegistryStatus> get() = registryStatusState

    @Volatile
    private var closed = false

    override val home: StateFlow<HomeSnapshot> get() = homeState

    /** Reads the registry and starts one session per record. Idempotent per bridge id. */
    fun start() {
        scope.launch {
            val records = when (val result = registry.bridges()) {
                is BridgeRegistryResult.Success -> result.value
                BridgeRegistryResult.Corrupt, is BridgeRegistryResult.Failure -> {
                    registryStatusState.value = RegistryStatus.Unavailable
                    return@launch
                }
            }
            registryStatusState.value = RegistryStatus.Ok
            for (record in records) openSession(record)
            rebuildMerge()
        }
    }

    private fun openSession(record: PairedBridgeRecord) {
        val bridgeId = BridgeId.parseOrNull(record.bridgeId) ?: return
        if (closed || sessions.containsKey(bridgeId)) return
        val credentials = SessionCredentials(bridgeId, credentialStore, ioDispatcher)
        val session = DefaultBridgeSession(
            bridgeId = bridgeId,
            parentScope = scope,
            transport = factories.transport(record, bridgeId, credentials),
            credentials = credentials,
            cache = factories.cache(bridgeId),
            clock = clock,
            coordinatorFactory = factories.coordinator,
            attachmentFactories = factories.attachments.map { f -> { env: SessionEnvironment -> f(env, record, credentials) } },
            probeBridgeIdentity = factories.probeBridgeIdentity,
        )
        sessions[bridgeId] = session
        session.start()
    }

    private fun rebuildMerge() {
        mergeJob?.cancel()
        val current = sessions.values.toList()
        if (current.isEmpty()) {
            homeState.value = HomeSnapshot(emptyMap(), emptyMap())
            mergeJob = null
            return
        }
        val flows = current.flatMap { listOf(it.snapshot, it.connection) }
        mergeJob = combine(flows) { values ->
            val bridges = LinkedHashMap<BridgeId, BridgeSnapshot>()
            val connections = LinkedHashMap<BridgeId, ConnectionState>()
            var i = 0
            for (session in current) {
                bridges[session.bridgeId] = values[i] as BridgeSnapshot
                connections[session.bridgeId] = values[i + 1] as ConnectionState
                i += 2
            }
            HomeSnapshot(bridges, connections)
        }.onEach { homeState.value = it }.launchIn(scope)
    }

    override fun session(bridgeId: BridgeId): BridgeSession? = sessions[bridgeId]

    override fun requestRefresh(reason: RefreshReason) {
        sessions.values.forEach { it.requestRefresh(reason) }
    }

    override suspend fun submit(mutation: LiveMutation): MutationOutcome {
        if (closed) return MutationOutcome.Refused(RefusalReason.SESSION_CLOSED)
        val session = sessions[mutation.target.bridgeId] ?: return MutationOutcome.Refused(RefusalReason.TARGET_UNKNOWN)
        return session.submit(mutation)
    }

    override fun onForeground() {
        sessions.values.forEach { it.onForeground() }
    }

    override fun onBackground() {
        sessions.values.forEach { it.onBackground() }
    }

    override fun remove(bridgeId: BridgeId) {
        val session = sessions.remove(bridgeId) ?: return
        session.close()
        rebuildMerge()
    }

    override fun close() {
        if (closed) return
        closed = true
        sessions.values.forEach { it.close() }
        sessions.clear()
        mergeJob?.cancel()
        homeState.value = HomeSnapshot(emptyMap(), emptyMap())
        supervisor.cancel()
    }
}
