package com.chromaglow.app.feature.settings

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.chromaglow.app.core.identity.BridgeId
import com.chromaglow.app.core.session.LiveHome
import com.chromaglow.app.core.session.SessionShellCommands
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn

/**
 * Settings presentation over [LiveHome] + the shell's [SessionShellCommands]. Forget is a
 * two-step, confirmed action routed to the shell, which tears the session down and performs
 * the local-only deletion; this ViewModel never touches storage.
 */
class LiveSettingsViewModel(
    private val liveHome: LiveHome,
    private val shell: SessionShellCommands,
    private val appVersion: String,
    private val clock: () -> Long = { System.currentTimeMillis() },
) : ViewModel() {

    private val confirming = MutableStateFlow<BridgeId?>(null)

    val uiState: StateFlow<LiveSettingsUiState> = combine(liveHome.home, confirming) { home, c ->
        LiveSettingsUiMapper.map(home, appVersion, c, clock())
    }.stateIn(
        scope = viewModelScope,
        started = SharingStarted.WhileSubscribed(5_000),
        initialValue = LiveSettingsUiMapper.map(liveHome.home.value, appVersion, null, clock()),
    )

    fun requestForget(bridgeId: BridgeId) {
        if (bridgeId !in liveHome.home.value.bridges.keys) return
        confirming.value = bridgeId
    }

    fun cancelForget() {
        confirming.value = null
    }

    /** Only the bridge whose confirmation is open can be forgotten; the shell does the work. */
    fun confirmForget() {
        val id = confirming.value ?: return
        confirming.value = null
        if (id !in liveHome.home.value.bridges.keys) return
        shell.forgetBridge(id)
    }
}
