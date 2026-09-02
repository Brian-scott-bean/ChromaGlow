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
 *  - Cold start: `restoreAll()` is classify-only. Live opens when metadata is readable and at
 *    least one record has a readable token; a record whose token is missing/unreadable is still
 *    given a session so it surfaces honestly as that bridge's Error state in Home/Settings with a
 *    local Forget (the approved repair presentation). Zero paired records or unreadable metadata
 *    lands on Setup, which shows the repair state itself. Nothing is deleted here — ever.
 *  - Setup → Live (a fresh pair or Setup's own restore) goes through the same classification, so
 *    the shell and Setup can never disagree about which bridges are live (B-08 / A-05).
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

    /** Classify persisted state once at launch and open Live when the home is usable. */
    suspend fun restoreAtLaunch() {
        openLiveIfUsable()
        startupState.value = if (sessionState.value is AppSession.Live) Startup.Live else Startup.Setup
    }

    /**
     * Setup reported a Paired bridge (fresh pair or its own restore). Re-classify from persisted
     * truth and open Live on the same rule as cold start; the shell never trusts a single record
     * handed to it. Completion is observable through [session].
     */
    fun enterLiveFromSetup() {
        scope.launch { openLiveIfUsable() }
    }

    /** Classify-only; opens Live iff metadata is readable and ≥1 record has a readable token. */
    private suspend fun openLiveIfUsable(): Boolean {
        val restored = workflow.restoreAll()
        if (restored.metadataUnavailable || restored.paired.isEmpty()) return false
        // Every persisted record gets a session (needsRepair ones surface as Error + Forget), so
        // the shell's active set is the whole registry, not the caller's view of it (A-06).
        enterLive(restored.paired + restored.needsRepair)
        return true
    }

    /** Open (or keep) the live home for [records]. Idempotent while already live. */
    private fun enterLive(records: List<PairedBridgeRecord>) {
        val ids = records.mapNotNull { BridgeId.parseOrNull(it.bridgeId) }
        if (ids.isEmpty()) return
        if (sessionState.value is AppSession.Demo) sessionState.value = AppSession.None
        activeBridges += ids
        if (sessionState.value is AppSession.Live) return
        val home = liveHomeFactory(scope)
        liveCommands = LiveHomeCommands(home, scope)
        sessionState.value = AppSession.Live(home)
    }

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
