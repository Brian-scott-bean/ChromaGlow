package com.chromaglow.app.feature.home

import com.chromaglow.app.core.identity.BridgeId
import com.chromaglow.app.core.identity.ResourceKey
import com.chromaglow.app.core.identity.TargetRef
import com.chromaglow.app.core.session.GroupKind
import com.chromaglow.app.ui.components.ConnectionRowUi

/**
 * What the Home screen renders. Pure data derived from [com.chromaglow.app.core.session.HomeSnapshot]
 * + connections by [HomeUiMapper]; never holds transport types, credentials, or callbacks.
 */
data class HomeUiState(
    val phase: HomePhase,
    val strip: List<ConnectionRowUi>,
    val rooms: List<GroupCardUi>,
    val zones: List<GroupCardUi>,
)

enum class HomePhase {
    /** No bridge has produced any snapshot yet and at least one is still connecting. */
    LOADING,

    /** Every bridge answered (or failed) and there are no rooms and no zones to show. */
    EMPTY,

    /** At least one group card exists (fresh, stale, or offline). */
    CONTENT,

    /** No bridge is registered in the live session at all. */
    NO_BRIDGES,
}

/** One room or zone card. [target] is the grouped_light the controls address (bridge-qualified). */
data class GroupCardUi(
    val groupKey: ResourceKey,
    val target: TargetRef.Live?,
    val bridgeId: BridgeId,
    val kind: GroupKind,
    val name: String,
    val lightCount: Int,
    val isOn: Boolean,
    val brightness: Int?,
    val controlsEnabled: Boolean,
    val disabledReason: String?,
) {
    val composeKey: String get() = groupKey.composeKey

    val subtitle: String
        get() = buildString {
            append(if (isOn) "On" else "Off")
            if (brightness != null) append(" · $brightness%")
            append(" · ")
            append(lightCount)
            append(if (lightCount == 1) " light" else " lights")
        }
}
