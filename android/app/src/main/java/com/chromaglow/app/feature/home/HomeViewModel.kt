package com.chromaglow.app.feature.home

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.chromaglow.app.core.identity.ResourceKey
import com.chromaglow.app.core.identity.ResourceType
import com.chromaglow.app.core.session.HomeCommands
import com.chromaglow.app.core.session.LiveHome
import com.chromaglow.app.core.session.RefreshReason
import com.chromaglow.app.ui.components.MutationFeedbackController
import com.chromaglow.app.ui.components.MutationFeedbackUi
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
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

    val uiState: StateFlow<HomeUiState> = combine(liveHome.home, liveHome.bridgeNames) { home, names ->
        HomeUiMapper.map(home, clock(), names)
    }.stateIn(
        scope = viewModelScope,
        started = SharingStarted.WhileSubscribed(5_000),
        initialValue = HomeUiMapper.map(liveHome.home.value, clock(), liveHome.bridgeNames.value),
    )

    /** Home renders grouped lights only, so only grouped_light outcomes are its feedback. */
    private val feedbackController = MutationFeedbackController(
        scope = viewModelScope,
        events = liveHome.mutationEvents,
        isRelevant = { it.target.type == ResourceType.GROUPED_LIGHT },
        nameOf = { key -> groupNameFor(key) },
    )

    val feedback: StateFlow<MutationFeedbackUi?> = feedbackController.feedback

    fun dismissFeedback(shown: MutationFeedbackUi) = feedbackController.dismiss(shown)

    private fun groupNameFor(groupedLight: ResourceKey): String? {
        val snapshot = liveHome.home.value.bridges[groupedLight.bridgeId] ?: return null
        return (snapshot.rooms.values + snapshot.zones.values).firstOrNull { it.groupedLight == groupedLight }?.name
    }

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
