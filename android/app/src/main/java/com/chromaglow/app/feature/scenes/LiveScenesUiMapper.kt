package com.chromaglow.app.feature.scenes

import com.chromaglow.app.core.identity.BridgeId
import com.chromaglow.app.core.identity.ResourceKey
import com.chromaglow.app.core.session.ConnectionState
import com.chromaglow.app.core.session.HomeSnapshot
import com.chromaglow.app.feature.home.HomeUiMapper

/**
 * Pure mapping. Activation is per scene TARGET: the snapshot's `isActive` is the bridge's truth,
 * the ViewModel's [pending] set layers "Activating" on top until the snapshot confirms, and
 * [failed] marks a request the snapshot never confirmed within the timeout. Nothing here is
 * globally exclusive; two groups may each have an active scene.
 */
object LiveScenesUiMapper {

    fun map(
        home: HomeSnapshot,
        pending: Set<ResourceKey>,
        failed: Set<ResourceKey>,
        nowMillis: Long,
        names: Map<BridgeId, String> = emptyMap(),
    ): LiveScenesUiState {
        if (home.bridges.isEmpty()) return LiveScenesUiState(ScenesPhase.NO_BRIDGES, emptyList(), emptyList())
        val multi = home.bridges.size > 1
        val strip = home.bridges.keys.sortedBy { it.value }.map { id ->
            HomeUiMapper.connectionRow(id, home.connections[id] ?: ConnectionState.Connecting, nowMillis, multi, names[id])
        }
        var anyData = false
        var anyConnecting = false
        val sections = home.bridges.entries.sortedBy { it.key.value }.mapNotNull { (id, snapshot) ->
            val connection = home.connections[id] ?: ConnectionState.Connecting
            val hasData = snapshot.generation > 0 || snapshot.scenes.isNotEmpty()
            if (hasData) anyData = true
            if (connection is ConnectionState.Connecting && !hasData) anyConnecting = true
            if (snapshot.scenes.isEmpty()) return@mapNotNull null
            val (enabled, reason) = HomeUiMapper.interaction(connection)
            val groups = snapshot.scenes.values
                .groupBy { it.group }
                .map { (groupKey, scenes) ->
                    val name = snapshot.rooms[groupKey]?.name ?: snapshot.zones[groupKey]?.name ?: "Other"
                    GroupScenesUi(
                        groupKey = groupKey,
                        groupName = name,
                        scenes = scenes.sortedBy { it.name.lowercase() }.map { scene ->
                            SceneRowUi(
                                key = scene.key,
                                name = scene.name,
                                isDynamic = scene.isDynamic,
                                activation = when {
                                    scene.isActive -> SceneActivation.ACTIVE
                                    scene.key in pending -> SceneActivation.ACTIVATING
                                    scene.key in failed -> SceneActivation.FAILED
                                    else -> SceneActivation.IDLE
                                },
                                enabled = enabled,
                                disabledReason = if (enabled) null else reason,
                            )
                        },
                    )
                }
                .sortedBy { it.groupName.lowercase() }
            BridgeScenesUi(bridgeId = id, bridgeLabel = HomeUiMapper.bridgeLabel(id, multi, names[id]), groups = groups)
        }
        val phase = when {
            sections.isNotEmpty() -> ScenesPhase.CONTENT
            !anyData && anyConnecting -> ScenesPhase.LOADING
            else -> ScenesPhase.EMPTY
        }
        return LiveScenesUiState(phase = phase, strip = strip, sections = sections)
    }
}
