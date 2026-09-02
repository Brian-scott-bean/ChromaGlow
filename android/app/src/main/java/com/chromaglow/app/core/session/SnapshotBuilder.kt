package com.chromaglow.app.core.session

import com.chromaglow.app.core.hue.capability.CapabilityResolver
import com.chromaglow.app.core.hue.capability.CieXy
import com.chromaglow.app.core.hue.rest.ClipDocument
import com.chromaglow.app.core.hue.rest.wire.ClipGroup
import com.chromaglow.app.core.hue.rest.wire.ClipGroupKind
import com.chromaglow.app.core.hue.rest.wire.ClipGroupedLight
import com.chromaglow.app.core.hue.rest.wire.ClipLight
import com.chromaglow.app.core.hue.rest.wire.ClipResourceCodec
import com.chromaglow.app.core.hue.rest.wire.ClipScene
import com.chromaglow.app.core.hue.rest.wire.ClipXy
import com.chromaglow.app.core.identity.BridgeId
import com.chromaglow.app.core.identity.ResourceId
import com.chromaglow.app.core.identity.ResourceKey
import com.chromaglow.app.core.identity.ResourceType

/** The five authoritative collections one load fetches for a bridge. */
data class ClipCollections(
    val rooms: ClipDocument,
    val zones: ClipDocument,
    val groupedLights: ClipDocument,
    val lights: ClipDocument,
    val scenes: ClipDocument,
)

/**
 * Turns one bridge's fetched collections into an authoritative [BridgeSnapshot]. Every key is
 * stamped with the bridge id here, so nothing downstream ever sees a bare rid. Membership: a
 * room child of rtype `device` resolves to the lights owned by that device; a child of rtype
 * `light` (zones, newer firmware) resolves directly. Unknown children are dropped, never guessed.
 */
object SnapshotBuilder {
    const val NO_EFFECT: String = "no_effect"

    fun build(bridgeId: BridgeId, generation: Long, collections: ClipCollections): BridgeSnapshot {
        fun key(type: ResourceType, id: String) = ResourceKey(bridgeId, type, ResourceId(id))

        val lightsWire: List<ClipLight> = collections.lights.data.mapNotNull { ClipResourceCodec.light(it) }
        val lightKeys: Map<String, ResourceKey> = lightsWire.associate { it.id to key(ResourceType.LIGHT, it.id) }
        val lightsByOwner: Map<String, List<ResourceKey>> = lightsWire
            .filter { it.owner != null }
            .groupBy({ it.owner!!.rid }, { lightKeys.getValue(it.id) })

        val lights: Map<ResourceKey, LightState> = lightsWire.associate { wire ->
            val k = lightKeys.getValue(wire.id)
            k to lightState(k, wire, bridgeId)
        }

        val groupedLights: Map<ResourceKey, GroupedLightState> = collections.groupedLights.data
            .mapNotNull { ClipResourceCodec.groupedLight(it) }
            .associate { wire -> key(ResourceType.GROUPED_LIGHT, wire.id).let { it to groupedLightState(it, wire) } }

        fun groupState(wire: ClipGroup, type: ResourceType, kind: GroupKind): GroupState {
            val children = wire.children.flatMap { child ->
                when (child.rtype) {
                    "light" -> listOfNotNull(lightKeys[child.rid])
                    "device" -> lightsByOwner[child.rid].orEmpty()
                    else -> emptyList()
                }
            }.distinct()
            val grouped = wire.groupedLightRid?.let { key(ResourceType.GROUPED_LIGHT, it) }?.takeIf { it in groupedLights }
            return GroupState(
                key = key(type, wire.id),
                kind = kind,
                name = wire.name ?: DEFAULT_GROUP_NAME,
                archetype = wire.archetype,
                children = children,
                groupedLight = grouped,
            )
        }

        val rooms = collections.rooms.data.mapNotNull { ClipResourceCodec.group(it, ClipGroupKind.ROOM) }
            .map { groupState(it, ResourceType.ROOM, GroupKind.ROOM) }.associateBy { it.key }
        val zones = collections.zones.data.mapNotNull { ClipResourceCodec.group(it, ClipGroupKind.ZONE) }
            .map { groupState(it, ResourceType.ZONE, GroupKind.ZONE) }.associateBy { it.key }

        val scenes = collections.scenes.data.mapNotNull { ClipResourceCodec.scene(it) }
            .mapNotNull { wire -> sceneState(bridgeId, wire) }.associateBy { it.key }

        return BridgeSnapshot(
            bridgeId = bridgeId,
            generation = generation,
            freshness = Freshness.Fresh(generation),
            rooms = rooms,
            zones = zones,
            groupedLights = groupedLights,
            lights = lights,
            scenes = scenes,
        )
    }

    private const val DEFAULT_GROUP_NAME = "Group"
    private const val DEFAULT_LIGHT_NAME = "Light"

    private fun cie(xy: ClipXy?): CieXy? = xy?.takeIf { it.x in 0.0..1.0 && it.y in 0.0..1.0 }?.let { CieXy(it.x, it.y) }

    /** `no_effect`/blank status → no active effect. */
    private fun effectOrNull(status: String?): String? = status?.takeIf { it.isNotBlank() && it != NO_EFFECT }

    fun lightState(key: ResourceKey, wire: ClipLight, bridgeId: BridgeId): LightState = LightState(
        key = key,
        name = wire.name ?: DEFAULT_LIGHT_NAME,
        isOn = wire.on ?: false,
        brightness = wire.dimming?.brightness,
        color = cie(wire.color?.xy),
        mirek = wire.colorTemperature?.mirek,
        mirekValid = wire.colorTemperature?.mirekValid,
        activeEffect = effectOrNull(wire.effectsV2?.statusEffect) ?: effectOrNull(wire.effects?.status),
        activeTimedEffect = effectOrNull(wire.timedEffects?.status),
        gradientPoints = wire.gradient?.points?.mapNotNull { cie(it) } ?: emptyList(),
        owner = wire.owner?.let { ref -> ResourceType.fromWireName(ref.rtype)?.let { ResourceKey(bridgeId, it, ResourceId(ref.rid)) } },
        capabilities = CapabilityResolver.resolve(wire),
    )

    fun groupedLightState(key: ResourceKey, wire: ClipGroupedLight): GroupedLightState =
        GroupedLightState(key = key, isOn = wire.on ?: false, brightness = wire.brightness)

    fun sceneState(bridgeId: BridgeId, wire: ClipScene): SceneState? {
        val group = wire.group ?: return null
        val groupType = when (group.rtype) {
            "room" -> ResourceType.ROOM
            "zone" -> ResourceType.ZONE
            else -> return null
        }
        return SceneState(
            key = ResourceKey(bridgeId, ResourceType.SCENE, ResourceId(wire.id)),
            name = wire.name ?: "Scene",
            group = ResourceKey(bridgeId, groupType, ResourceId(group.rid)),
            isActive = wire.isActive,
            isDynamic = wire.isDynamic,
        )
    }
}
