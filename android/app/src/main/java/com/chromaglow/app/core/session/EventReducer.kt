package com.chromaglow.app.core.session

import com.chromaglow.app.core.hue.capability.CieXy
import com.chromaglow.app.core.hue.rest.wire.ClipJson
import com.chromaglow.app.core.hue.rest.wire.ClipResourceCodec
import com.chromaglow.app.core.hue.rest.wire.arr
import com.chromaglow.app.core.hue.rest.wire.bool
import com.chromaglow.app.core.hue.rest.wire.dbl
import com.chromaglow.app.core.hue.rest.wire.int
import com.chromaglow.app.core.hue.rest.wire.obj
import com.chromaglow.app.core.hue.rest.wire.str
import com.chromaglow.app.core.identity.ResourceId
import com.chromaglow.app.core.identity.ResourceKey
import com.chromaglow.app.core.identity.ResourceType
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject

/**
 * Pure reducer from one SSE payload to the next [BridgeSnapshot]. Rules (each pinned by test):
 *  - keys are built with the snapshot's own bridge id, so a reducer for bridge A can never touch B;
 *  - a field group under pending optimistic authority is NOT applied (echo suppression), while
 *    every other field group of the same event still lands (field-aware);
 *  - a colour event clears the mirek VALUE (mirek = null, mirek_valid = false) but never the
 *    lamp's capability schema; a CT event sets mirek and mirek_valid = true;
 *  - a scene becoming active clears its siblings in the same group; `inactive` clears only itself;
 *  - `delete` events remove the resource; `add` events are left to the authoritative refresh;
 *  - malformed events/items are skipped; button/rotary/motion/light_level/temperature/battery/
 *    device/zigbee families and every unknown type are no-ops.
 */
object EventReducer {

    fun reduce(snapshot: BridgeSnapshot, payload: String, authority: PendingAuthority, nowMillis: Long): BridgeSnapshot {
        val events = ClipJson.parseOrNull(payload) as? JsonArray ?: return snapshot
        var current = snapshot
        for (event in events) {
            val e = event as? JsonObject ?: continue
            val kind = e.str("type") ?: continue
            val data = e.arr("data") ?: continue
            for (item in data) {
                val obj = item as? JsonObject ?: continue
                current = when (kind) {
                    "update" -> applyUpdate(current, obj, authority, nowMillis)
                    "delete" -> applyDelete(current, obj)
                    else -> current // "add", "error" and anything else: the authoritative load reconciles
                }
            }
        }
        return current
    }

    private fun key(s: BridgeSnapshot, type: ResourceType, id: String) = ResourceKey(s.bridgeId, type, ResourceId(id))

    private fun applyDelete(s: BridgeSnapshot, obj: JsonObject): BridgeSnapshot {
        val id = obj.str("id")?.takeIf { it.isNotBlank() && it.none(Char::isWhitespace) } ?: return s
        val type = obj.str("type")?.let { ResourceType.fromWireName(it) } ?: return s
        val k = key(s, type, id)
        return when (type) {
            ResourceType.LIGHT -> s.copy(lights = s.lights - k, rooms = s.rooms.mapValues { it.value.copy(children = it.value.children - k) }, zones = s.zones.mapValues { it.value.copy(children = it.value.children - k) })
            ResourceType.ROOM -> s.copy(rooms = s.rooms - k, scenes = s.scenes.filterValues { it.group != k })
            ResourceType.ZONE -> s.copy(zones = s.zones - k, scenes = s.scenes.filterValues { it.group != k })
            ResourceType.GROUPED_LIGHT -> s.copy(groupedLights = s.groupedLights - k)
            ResourceType.SCENE -> s.copy(scenes = s.scenes - k)
            ResourceType.DEVICE, ResourceType.BRIDGE -> s
        }
    }

    private fun applyUpdate(s: BridgeSnapshot, obj: JsonObject, authority: PendingAuthority, now: Long): BridgeSnapshot {
        val id = obj.str("id")?.takeIf { it.isNotBlank() && it.none(Char::isWhitespace) } ?: return s
        return when (obj.str("type")) {
            "light" -> updateLight(s, key(s, ResourceType.LIGHT, id), obj, authority, now)
            "grouped_light" -> updateGroupedLight(s, key(s, ResourceType.GROUPED_LIGHT, id), obj, authority, now)
            "scene" -> updateScene(s, key(s, ResourceType.SCENE, id), obj, authority, now)
            "room" -> updateGroupName(s, key(s, ResourceType.ROOM, id), obj)
            "zone" -> updateGroupName(s, key(s, ResourceType.ZONE, id), obj)
            else -> s
        }
    }

    private fun updateLight(s: BridgeSnapshot, k: ResourceKey, obj: JsonObject, authority: PendingAuthority, now: Long): BridgeSnapshot {
        var light = s.lights[k] ?: return s
        fun free(field: FieldGroup) = !authority.isPending(k, field, now)

        obj.obj("on")?.bool("on")?.let { if (free(FieldGroup.POWER)) light = light.copy(isOn = it) }
        obj.obj("dimming")?.dbl("brightness")?.let { if (free(FieldGroup.DIMMING)) light = light.copy(brightness = it) }
        ClipResourceCodec.xy(obj.obj("color")?.obj("xy"))?.let { xy ->
            if (free(FieldGroup.COLOR) && xy.x in 0.0..1.0 && xy.y in 0.0..1.0) {
                // Colour-only event: the CT value is no longer what the lamp shows; the schema (a
                // capability) is untouched.
                light = light.copy(color = CieXy(xy.x, xy.y), mirek = null, mirekValid = false)
            }
        }
        obj.obj("color_temperature")?.let { ct ->
            if (free(FieldGroup.COLOR_TEMPERATURE)) {
                val mirek = ct.int("mirek")
                val valid = ct.bool("mirek_valid")
                if (mirek != null) light = light.copy(mirek = mirek, mirekValid = valid ?: true)
                else if (valid != null) light = light.copy(mirekValid = valid)
            }
        }
        val v2Effect = obj.obj("effects_v2")?.obj("status")?.str("effect")
        val v1Effect = obj.obj("effects")?.str("status")
        (v2Effect ?: v1Effect)?.let { if (free(FieldGroup.EFFECT)) light = light.copy(activeEffect = it.takeIf { e -> e != SnapshotBuilder.NO_EFFECT && e.isNotBlank() }) }
        obj.obj("timed_effects")?.str("status")?.let { if (free(FieldGroup.TIMED_EFFECT)) light = light.copy(activeTimedEffect = it.takeIf { e -> e != SnapshotBuilder.NO_EFFECT && e.isNotBlank() }) }
        obj.obj("gradient")?.arr("points")?.let { points ->
            if (free(FieldGroup.GRADIENT)) {
                val xys = points.mapNotNull { p -> ClipResourceCodec.xy((p as? JsonObject)?.obj("color")?.obj("xy")) }
                    .filter { it.x in 0.0..1.0 && it.y in 0.0..1.0 }.map { CieXy(it.x, it.y) }
                light = light.copy(gradientPoints = xys)
            }
        }
        obj.obj("metadata")?.str("name")?.takeIf { it.isNotBlank() }?.let { light = light.copy(name = it) }
        return if (light === s.lights[k]) s else s.copy(lights = s.lights + (k to light))
    }

    private fun updateGroupedLight(s: BridgeSnapshot, k: ResourceKey, obj: JsonObject, authority: PendingAuthority, now: Long): BridgeSnapshot {
        var g = s.groupedLights[k] ?: return s
        obj.obj("on")?.bool("on")?.let { if (!authority.isPending(k, FieldGroup.POWER, now) && !authority.isPending(k, FieldGroup.DIMMING, now)) g = g.copy(isOn = it) }
        obj.obj("dimming")?.dbl("brightness")?.let { if (!authority.isPending(k, FieldGroup.DIMMING, now)) g = g.copy(brightness = it) }
        return if (g === s.groupedLights[k]) s else s.copy(groupedLights = s.groupedLights + (k to g))
    }

    private fun updateScene(s: BridgeSnapshot, k: ResourceKey, obj: JsonObject, authority: PendingAuthority, now: Long): BridgeSnapshot {
        val scene = s.scenes[k] ?: return s
        val active = obj.obj("status")?.str("active") ?: return updateSceneName(s, k, obj)
        if (authority.isPending(k, FieldGroup.SCENE, now)) return updateSceneName(s, k, obj)
        val isActive = active == "static" || active == "dynamic_palette"
        val isDynamic = active == "dynamic_palette"
        val scenes = if (isActive) {
            s.scenes.mapValues { (id, v) -> if (id == k) v.copy(isActive = true, isDynamic = isDynamic) else if (v.group == scene.group) v.copy(isActive = false, isDynamic = false) else v }
        } else {
            s.scenes + (k to scene.copy(isActive = false, isDynamic = false))
        }
        return updateSceneName(s.copy(scenes = scenes), k, obj)
    }

    private fun updateSceneName(s: BridgeSnapshot, k: ResourceKey, obj: JsonObject): BridgeSnapshot {
        val name = obj.obj("metadata")?.str("name")?.takeIf { it.isNotBlank() } ?: return s
        val scene = s.scenes[k] ?: return s
        return s.copy(scenes = s.scenes + (k to scene.copy(name = name)))
    }

    private fun updateGroupName(s: BridgeSnapshot, k: ResourceKey, obj: JsonObject): BridgeSnapshot {
        val name = obj.obj("metadata")?.str("name")?.takeIf { it.isNotBlank() } ?: return s
        s.rooms[k]?.let { return s.copy(rooms = s.rooms + (k to it.copy(name = name))) }
        s.zones[k]?.let { return s.copy(zones = s.zones + (k to it.copy(name = name))) }
        return s
    }
}
