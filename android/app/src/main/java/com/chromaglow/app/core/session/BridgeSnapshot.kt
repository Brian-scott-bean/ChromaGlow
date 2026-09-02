package com.chromaglow.app.core.session

import com.chromaglow.app.core.hue.capability.CieXy
import com.chromaglow.app.core.hue.capability.LightCapabilities
import com.chromaglow.app.core.identity.BridgeId
import com.chromaglow.app.core.identity.ResourceKey
import com.chromaglow.app.core.identity.ResourceType

/** Whether a snapshot is the latest authoritative read or a retained older one. */
sealed interface Freshness {
    data class Fresh(val generation: Long) : Freshness
    data class Stale(val sinceGeneration: Long, val reason: StaleReason) : Freshness
}

enum class StaleReason { LOAD_FAILED, FROM_CACHE, STREAM_SILENT }

enum class GroupKind { ROOM, ZONE }

data class GroupState(
    val key: ResourceKey,
    val kind: GroupKind,
    val name: String,
    val archetype: String?,
    val children: List<ResourceKey>,
    val groupedLight: ResourceKey?,
)

data class GroupedLightState(
    val key: ResourceKey,
    val isOn: Boolean,
    val brightness: Double?,
)

data class LightState(
    val key: ResourceKey,
    val name: String,
    val isOn: Boolean,
    val brightness: Double?,
    val color: CieXy?,
    val mirek: Int?,
    val mirekValid: Boolean?,
    val activeEffect: String?,
    val activeTimedEffect: String?,
    val gradientPoints: List<CieXy>,
    val owner: ResourceKey?,
    val capabilities: LightCapabilities,
)

data class SceneState(
    val key: ResourceKey,
    val name: String,
    val group: ResourceKey,
    val isActive: Boolean,
    val isDynamic: Boolean,
)

/**
 * The authoritative, bridge-qualified state of ONE bridge. Every key inside is REQUIRED to carry
 * this snapshot's [bridgeId] (checked at construction), so a snapshot can never hold another
 * bridge's resource. Secret-free by construction: no credential field exists on any nested type
 * (pinned by test). Suitable for Home, Room/Zone, Light detail, Scenes, cache painting, SSE
 * reduction and optimistic overlays.
 */
data class BridgeSnapshot(
    val bridgeId: BridgeId,
    val generation: Long,
    val freshness: Freshness,
    val rooms: Map<ResourceKey, GroupState>,
    val zones: Map<ResourceKey, GroupState>,
    val groupedLights: Map<ResourceKey, GroupedLightState>,
    val lights: Map<ResourceKey, LightState>,
    val scenes: Map<ResourceKey, SceneState>,
) {
    init {
        require(generation >= 0) { "generation must be non-negative" }
        requireAll(rooms.keys, ResourceType.ROOM)
        requireAll(zones.keys, ResourceType.ZONE)
        requireAll(groupedLights.keys, ResourceType.GROUPED_LIGHT)
        requireAll(lights.keys, ResourceType.LIGHT)
        requireAll(scenes.keys, ResourceType.SCENE)
    }

    private fun requireAll(keys: Set<ResourceKey>, type: ResourceType) {
        for (key in keys) {
            require(key.bridgeId == bridgeId) { "snapshot for $bridgeId cannot hold ${key.bridgeId} resources" }
            require(key.type == type) { "map for $type cannot hold a ${key.type} key" }
        }
    }

    companion object {
        fun empty(bridgeId: BridgeId): BridgeSnapshot = BridgeSnapshot(
            bridgeId = bridgeId,
            generation = 0,
            freshness = Freshness.Stale(sinceGeneration = 0, reason = StaleReason.LOAD_FAILED),
            rooms = emptyMap(),
            zones = emptyMap(),
            groupedLights = emptyMap(),
            lights = emptyMap(),
            scenes = emptyMap(),
        )
    }
}
