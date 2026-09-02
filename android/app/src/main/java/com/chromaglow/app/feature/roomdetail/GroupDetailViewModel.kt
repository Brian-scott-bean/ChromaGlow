package com.chromaglow.app.feature.roomdetail

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.chromaglow.app.core.hue.capability.CieXy
import com.chromaglow.app.core.hue.capability.MirekRange
import com.chromaglow.app.core.identity.ResourceKey
import com.chromaglow.app.core.identity.TargetRef
import com.chromaglow.app.core.session.HomeCommands
import com.chromaglow.app.core.session.LiveHome
import com.chromaglow.app.feature.home.GroupCardUi
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn

/** Room/Zone detail presentation over the frozen contracts; [groupKey] is the exact live target. */
class GroupDetailViewModel(
    private val liveHome: LiveHome,
    private val commands: HomeCommands,
    val groupKey: ResourceKey,
    private val clock: () -> Long = { System.currentTimeMillis() },
) : ViewModel() {

    val uiState: StateFlow<GroupDetailUiState> = liveHome.home
        .map { GroupDetailUiMapper.map(it, groupKey, clock()) }
        .stateIn(
            scope = viewModelScope,
            started = SharingStarted.WhileSubscribed(5_000),
            initialValue = GroupDetailUiMapper.map(liveHome.home.value, groupKey, clock()),
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

    /** Current mapping from the sources (a stateIn value is stale without a collector). */
    private fun current(): GroupDetailUiState = GroupDetailUiMapper.map(liveHome.home.value, groupKey, clock())

    /**
     * Group colour: addressed to the GROUP key; the coordinator fans out to members whose colour
     * is KNOWN and clamps per lamp. Refused locally when no member is capable or controls are off.
     */
    fun setGroupColor(xy: CieXy) {
        val s = current()
        val group = s.group ?: return
        if (!group.controlsEnabled || s.groupColor == null) return
        commands.setLightColor(TargetRef.Live(groupKey), xy)
    }

    /** Group warmth over the protocol clamp only; never a lamp's KNOWN schema. */
    fun setGroupColorTemperature(mirek: Int) {
        val s = current()
        val group = s.group ?: return
        if (!group.controlsEnabled || s.groupWarmth == null) return
        commands.setLightColorTemperature(
            TargetRef.Live(groupKey),
            mirek.coerceIn(MirekRange.PROTOCOL_MINIMUM, MirekRange.PROTOCOL_MAXIMUM),
        )
    }

    fun setLightPower(light: LightCardUi, on: Boolean) {
        if (!light.controlsEnabled) return
        commands.setLightPower(light.target, on)
    }

    fun setLightBrightness(light: LightCardUi, percent: Int) {
        if (!light.controlsEnabled) return
        commands.setLightBrightness(light.target, percent.coerceIn(1, 100))
    }
}
