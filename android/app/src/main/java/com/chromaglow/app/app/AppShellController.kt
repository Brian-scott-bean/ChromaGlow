package com.chromaglow.app.app

import com.chromaglow.app.core.bridge.PairedBridgeRecord
import com.chromaglow.app.core.hue.pairing.workflow.LivePairingWorkflow
import com.chromaglow.app.core.identity.BridgeId
import com.chromaglow.app.core.session.HomeCommands
import com.chromaglow.app.core.session.LiveHome
import com.chromaglow.app.core.session.LiveHomeCommands
import com.chromaglow.app.core.session.SessionShellCommands
import com.chromaglow.app.data.demo.DemoModeBoundary
import com.chromaglow.app.data.demo.DemoModeSession
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

/**
 * The app shell's session owner (P7). It is the ONLY place that creates or tears down a
 * [LiveHome], and the shell-side implementation of [SessionShellCommands].
 *
 * Rules it enforces:
 *  - Cold start: `restoreAll()` is classify-only. Live opens only when every record has a readable
 *    token and metadata is readable; anything else lands on Setup, which shows the repair state
 *    itself. Nothing is deleted here — ever.
 *  - Demo and Live are exclusive; entering one tears the other down.
 *  - Forget is local-only and ordered: the bridge's session is removed first, then the token and
 *    record are deleted, and only then does the shell flip to Setup (so Setup's own restore sees
 *    the post-forget truth and cannot bounce straight back into Live).
 *
 * Not a Compose object: everything here is plain state so it can be tested on the JVM.
 * All methods are expected on the main thread (the [scope]'s dispatcher).
 */
class AppShellController(
    private val workflow: LivePairingWorkflow,
    private val liveHomeFactory: (CoroutineScope) -> LiveHome,
    private val scope: CoroutineScope,
) : SessionShellCommands {

    /** Where the cold-start classification landed. [Pending] until `restoreAtLaunch` finishes. */
    sealed interface Startup {
        data object Pending : Startup
        data object Setup : Startup
        data object Live : Startup
    }

    private val sessionState = MutableStateFlow<AppSession>(AppSession.None)
    val session: StateFlow<AppSession> get() = sessionState

    private val startupState = MutableStateFlow<Startup>(Startup.Pending)
    val startup: StateFlow<Startup> get() = startupState

    private val activeBridges = LinkedHashSet<BridgeId>()
    private var liveCommands: LiveHomeCommands? = null

    /** Commands for the current live session; null while not live. */
    val commands: HomeCommands? get() = liveCommands

    /** Classify persisted state once at launch and open Live only on a fully healthy home. */
    suspend fun restoreAtLaunch() {
        val restored = workflow.restoreAll()
        val healthy = !restored.metadataUnavailable &&
            restored.needsRepair.isEmpty() &&
            restored.paired.isNotEmpty()
        if (healthy) enterLive(restored.paired)
        startupState.value = if (sessionState.value is AppSession.Live) Startup.Live else Startup.Setup
    }

    /** Open (or keep) the live home for [records]. Idempotent while already live. */
    fun enterLive(records: List<PairedBridgeRecord>) {
        val ids = records.mapNotNull { BridgeId.parseOrNull(it.bridgeId) }
        if (ids.isEmpty()) return
        if (sessionState.value is AppSession.Demo) sessionState.value = AppSession.None
        activeBridges += ids
        if (sessionState.value is AppSession.Live) return
        val home = liveHomeFactory(scope)
        liveCommands = LiveHomeCommands(home, scope)
        sessionState.value = AppSession.Live(home)
    }

    fun enterLive(record: PairedBridgeRecord) = enterLive(listOf(record))

    fun enterDemo(): DemoModeSession {
        teardownLive()
        val demo = DemoModeBoundary.enterDemoMode()
        sessionState.value = AppSession.Demo(demo)
        return demo
    }

    fun exitDemo() {
        if (sessionState.value is AppSession.Demo) sessionState.value = AppSession.None
    }

    override fun forgetBridge(bridgeId: BridgeId) {
        val home = (sessionState.value as? AppSession.Live)?.home ?: return
        scope.launch {
            home.remove(bridgeId)
            activeBridges.remove(bridgeId)
            // Local-only. A cleanup failure leaves whatever survived for Setup to classify
            // honestly (NeedsRepair / Paired); nothing is retried or swept here.
            workflow.forget(bridgeId.value)
            if (activeBridges.isEmpty()) teardownLive()
        }
    }

    override fun exitToSetup() = teardownLive()

    fun onForeground() {
        (sessionState.value as? AppSession.Live)?.home?.onForeground()
    }

    fun onBackground() {
        (sessionState.value as? AppSession.Live)?.home?.onBackground()
    }

    /** Process-level shutdown: close the live home without touching persisted state. */
    fun close() = teardownLive()

    private fun teardownLive() {
        (sessionState.value as? AppSession.Live)?.home?.close()
        liveCommands = null
        activeBridges.clear()
        if (sessionState.value is AppSession.Live) sessionState.value = AppSession.None
    }
}
