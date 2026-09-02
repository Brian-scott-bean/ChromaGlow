package com.chromaglow.app.feature.home

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.chromaglow.app.core.session.HomeCommands
import com.chromaglow.app.core.session.LiveHome
import com.chromaglow.app.core.session.RefreshReason
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn

/**
 * Home presentation. Takes the frozen [LiveHome] + [HomeCommands] contracts only: no transport,
 * no client construction, no Android context. Commands are forwarded exactly once per user
 * intent, and refused locally when the card's connection policy says controls are disabled (the
 * coordinator refuses too; the UI just never asks).
 */
class HomeViewModel(
    private val liveHome: LiveHome,
    private val commands: HomeCommands,
    private val clock: () -> Long = { System.currentTimeMillis() },
) : ViewModel() {

    val uiState: StateFlow<HomeUiState> = liveHome.home
        .map { HomeUiMapper.map(it, clock()) }
        .stateIn(
            scope = viewModelScope,
            started = SharingStarted.WhileSubscribed(5_000),
            initialValue = HomeUiMapper.map(liveHome.home.value, clock()),
        )

    fun setGroupPower(card: GroupCardUi, on: Boolean) {
        val target = card.target ?: return
        if (!card.controlsEnabled) return
        commands.setGroupPower(target, on)
    }

    fun setGroupBrightness(card: GroupCardUi, percent: Int) {
        val target = card.target ?: return
        if (!card.controlsEnabled) return
        commands.setGroupBrightness(target, percent.coerceIn(1, 100))
    }

    fun refresh() {
        commands.refresh(RefreshReason.USER_PULL)
    }
}
