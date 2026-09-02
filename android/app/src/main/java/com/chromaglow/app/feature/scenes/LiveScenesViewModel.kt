package com.chromaglow.app.feature.scenes

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.chromaglow.app.core.identity.ResourceKey
import com.chromaglow.app.core.session.HomeCommands
import com.chromaglow.app.core.session.LiveHome
import com.chromaglow.app.core.session.RefreshReason
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/**
 * Scenes presentation. Activation is optimistic per target: the row shows Activating until the
 * snapshot (SSE or refresh) reports `isActive`, or [activationTimeoutMillis] elapses and the row
 * shows a brief "Didn't activate" that clears after [failureDisplayMillis]. Commands are
 * fire-and-forget by contract, so the snapshot is the only confirmation.
 */
class LiveScenesViewModel(
    private val liveHome: LiveHome,
    private val commands: HomeCommands,
    private val clock: () -> Long = { System.currentTimeMillis() },
    private val activationTimeoutMillis: Long = 4_000L,
    private val failureDisplayMillis: Long = 4_000L,
) : ViewModel() {

    private val pending = MutableStateFlow<Set<ResourceKey>>(emptySet())
    private val failed = MutableStateFlow<Set<ResourceKey>>(emptySet())

    val uiState: StateFlow<LiveScenesUiState> = combine(liveHome.home, pending, failed) { home, p, f ->
        // Pure: a scene the bridge reports active is rendered Active regardless of local marks;
        // the timeout coroutine in [activate] is the only writer of the pending/failed sets.
        LiveScenesUiMapper.map(home, p, f, clock())
    }.stateIn(
        scope = viewModelScope,
        started = SharingStarted.WhileSubscribed(5_000),
        initialValue = LiveScenesUiMapper.map(liveHome.home.value, emptySet(), emptySet(), clock()),
    )

    fun activate(row: SceneRowUi) {
        if (!row.enabled) return
        if (row.activation == SceneActivation.ACTIVATING) return
        failed.update { it - row.key }
        pending.update { it + row.key }
        commands.activateScene(row.target)
        viewModelScope.launch {
            delay(activationTimeoutMillis)
            if (row.key in pending.value && !isActiveNow(row.key)) {
                pending.update { it - row.key }
                failed.update { it + row.key }
                delay(failureDisplayMillis)
                failed.update { it - row.key }
            } else {
                pending.update { it - row.key }
            }
        }
    }

    fun refresh() = commands.refresh(RefreshReason.USER_PULL)

    private fun isActiveNow(key: ResourceKey): Boolean =
        liveHome.home.value.bridges[key.bridgeId]?.scenes?.get(key)?.isActive == true
}
