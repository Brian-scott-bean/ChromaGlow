package com.chromaglow.app.feature.scenes

import com.chromaglow.app.core.identity.BridgeId
import com.chromaglow.app.core.identity.ResourceKey
import com.chromaglow.app.core.identity.TargetRef
import com.chromaglow.app.ui.components.ConnectionRowUi

enum class ScenesPhase { NO_BRIDGES, LOADING, EMPTY, CONTENT }

/** Scenes grouped by bridge, then by the room/zone they belong to. */
data class LiveScenesUiState(
    val phase: ScenesPhase,
    val strip: List<ConnectionRowUi>,
    val sections: List<BridgeScenesUi>,
)

data class BridgeScenesUi(
    val bridgeId: BridgeId,
    val bridgeLabel: String,
    val groups: List<GroupScenesUi>,
)

data class GroupScenesUi(
    val groupKey: ResourceKey?,
    val groupName: String,
    val scenes: List<SceneRowUi>,
)

enum class SceneActivation { IDLE, ACTIVATING, ACTIVE, FAILED }

data class SceneRowUi(
    val key: ResourceKey,
    val name: String,
    val isDynamic: Boolean,
    val activation: SceneActivation,
    val enabled: Boolean,
    val disabledReason: String?,
) {
    val target: TargetRef.Live get() = TargetRef.Live(key)
    val composeKey: String get() = key.composeKey
}
