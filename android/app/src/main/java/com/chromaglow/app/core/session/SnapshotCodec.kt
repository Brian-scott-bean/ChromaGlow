package com.chromaglow.app.core.session

import com.chromaglow.app.core.hue.capability.Capability
import com.chromaglow.app.core.hue.capability.CieXy
import com.chromaglow.app.core.hue.capability.Evidence
import com.chromaglow.app.core.hue.capability.Gamut
import com.chromaglow.app.core.hue.capability.GamutSource
import com.chromaglow.app.core.hue.capability.GradientCapability
import com.chromaglow.app.core.hue.capability.LightCapabilities
import com.chromaglow.app.core.hue.capability.MirekRange
import com.chromaglow.app.core.identity.BridgeId
import com.chromaglow.app.core.identity.ResourceId
import com.chromaglow.app.core.identity.ResourceKey
import com.chromaglow.app.core.identity.ResourceType
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/** Thrown by [SnapshotCodec.decode] for any structural problem; the cache maps it to Discarded. */
class SnapshotFormatException(message: String) : Exception(message)

/**
 * BridgeSnapshot ↔ JSON for the on-disk cache (tree API, no plugin). The envelope carries
 * [BridgeSnapshotCache.FORMAT_VERSION] and the bridge id; a decode for another bridge or another
 * version throws [SnapshotFormatException]. The shape contains only what [BridgeSnapshot] holds,
 * which is secret-free by construction.
 */
internal object SnapshotCodec {
    private const val VERSION_KEY = "format_version"
    private const val BRIDGE_KEY = "bridge_id"

    fun encode(snapshot: BridgeSnapshot): JsonObject = buildJsonObject {
        put(VERSION_KEY, BridgeSnapshotCache.FORMAT_VERSION)
        put(BRIDGE_KEY, snapshot.bridgeId.value)
        put("generation", snapshot.generation)
        put("rooms", buildJsonArray { snapshot.rooms.values.forEach { add(group(it)) } })
        put("zones", buildJsonArray { snapshot.zones.values.forEach { add(group(it)) } })
        put("grouped_lights", buildJsonArray { snapshot.groupedLights.values.forEach { add(groupedLight(it)) } })
        put("lights", buildJsonArray { snapshot.lights.values.forEach { add(light(it)) } })
        put("scenes", buildJsonArray { snapshot.scenes.values.forEach { add(scene(it)) } })
    }

    fun encodeToString(snapshot: BridgeSnapshot): String = encode(snapshot).toString()

    /** Decodes a cached document; the result is always painted [Freshness.Stale] FROM_CACHE. */
    fun decode(text: String, expected: BridgeId): BridgeSnapshot {
        val root = try {
            Json.parseToJsonElement(text) as? JsonObject
        } catch (e: SerializationException) {
            null
        } catch (e: IllegalArgumentException) {
            null
        } ?: throw SnapshotFormatException("not a JSON object")
        val version = root.int(VERSION_KEY) ?: throw SnapshotFormatException("missing format_version")
        if (version != BridgeSnapshotCache.FORMAT_VERSION) throw SnapshotFormatException("unknown format_version $version")
        val bridgeId = root.str(BRIDGE_KEY)?.let { BridgeId.parseOrNull(it) } ?: throw SnapshotFormatException("missing bridge_id")
        if (bridgeId != expected) throw SnapshotFormatException("snapshot belongs to another bridge")
        val generation = root.long("generation") ?: throw SnapshotFormatException("missing generation")
        return try {
            BridgeSnapshot(
                bridgeId = bridgeId,
                generation = generation,
                freshness = Freshness.Stale(sinceGeneration = generation, reason = StaleReason.FROM_CACHE),
                rooms = root.array("rooms").map { group(it.obj(), bridgeId, ResourceType.ROOM, GroupKind.ROOM) }.associateBy { it.key },
                zones = root.array("zones").map { group(it.obj(), bridgeId, ResourceType.ZONE, GroupKind.ZONE) }.associateBy { it.key },
                groupedLights = root.array("grouped_lights").map { groupedLight(it.obj(), bridgeId) }.associateBy { it.key },
                lights = root.array("lights").map { light(it.obj(), bridgeId) }.associateBy { it.key },
                scenes = root.array("scenes").map { scene(it.obj(), bridgeId) }.associateBy { it.key },
            )
        } catch (e: IllegalArgumentException) {
            throw SnapshotFormatException(e.message ?: "invalid snapshot")
        }
    }

    // ── encode helpers ──

    private fun key(k: ResourceKey): JsonObject = buildJsonObject { put("type", k.type.wireName); put("id", k.id.value) }

    private fun xy(xy: CieXy): JsonObject = buildJsonObject { put("x", xy.x); put("y", xy.y) }

    private fun group(g: GroupState): JsonObject = buildJsonObject {
        put("key", key(g.key))
        put("name", g.name)
        g.archetype?.let { put("archetype", it) }
        put("children", buildJsonArray { g.children.forEach { add(key(it)) } })
        g.groupedLight?.let { put("grouped_light", key(it)) }
    }

    private fun groupedLight(g: GroupedLightState): JsonObject = buildJsonObject {
        put("key", key(g.key))
        put("on", g.isOn)
        g.brightness?.let { put("brightness", it) }
    }

    private fun <T> capability(c: Capability<T>, value: (T) -> JsonElement): JsonObject = buildJsonObject {
        put("evidence", c.evidence.name)
        c.value?.let { put("value", value(it)) }
    }

    private fun gamut(g: Gamut): JsonObject = buildJsonObject {
        put("source", g.source.name); put("red", xy(g.red)); put("green", xy(g.green)); put("blue", xy(g.blue))
    }

    private fun strings(s: Set<String>): JsonArray = JsonArray(s.map { JsonPrimitive(it) })

    private fun capabilities(c: LightCapabilities): JsonObject = buildJsonObject {
        put("color", capability(c.color) { gamut(it) })
        put("color_temperature", capability(c.colorTemperature) { buildJsonObject { put("min", it.minimum); put("max", it.maximum) } })
        put("effects_v1", capability(c.effectsV1) { strings(it) })
        put("effects_v2", capability(c.effectsV2) { strings(it) })
        put("timed_effects", capability(c.timedEffects) { strings(it) })
        put("gradient", capability(c.gradient) { buildJsonObject {
            put("points_capable", it.pointsCapable); put("modes", strings(it.modes)); it.pixelCount?.let { p -> put("pixel_count", p) }
        } })
        put("signaling", capability(c.signaling) { strings(it) })
        put("dynamics", capability(c.dynamics) { JsonPrimitive(true) })
    }

    private fun light(l: LightState): JsonObject = buildJsonObject {
        put("key", key(l.key))
        put("name", l.name)
        put("on", l.isOn)
        l.brightness?.let { put("brightness", it) }
        l.color?.let { put("color", xy(it)) }
        l.mirek?.let { put("mirek", it) }
        l.mirekValid?.let { put("mirek_valid", it) }
        l.activeEffect?.let { put("active_effect", it) }
        l.activeTimedEffect?.let { put("active_timed_effect", it) }
        put("gradient_points", buildJsonArray { l.gradientPoints.forEach { add(xy(it)) } })
        l.owner?.let { put("owner", key(it)) }
        put("capabilities", capabilities(l.capabilities))
    }

    private fun scene(s: SceneState): JsonObject = buildJsonObject {
        put("key", key(s.key))
        put("name", s.name)
        put("group", key(s.group))
        put("active", s.isActive)
        put("dynamic", s.isDynamic)
    }

    // ── decode helpers ──

    private fun JsonObject.str(n: String) = (this[n] as? JsonPrimitive)?.takeIf { it.isString }?.content
    private fun JsonObject.int(n: String) = (this[n] as? JsonPrimitive)?.takeIf { !it.isString }?.intOrNull
    private fun JsonObject.long(n: String) = (this[n] as? JsonPrimitive)?.takeIf { !it.isString }?.longOrNull
    private fun JsonObject.dbl(n: String) = (this[n] as? JsonPrimitive)?.takeIf { !it.isString }?.doubleOrNull
    private fun JsonObject.bool(n: String) = (this[n] as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull
    private fun JsonObject.array(n: String): JsonArray = this[n] as? JsonArray ?: throw SnapshotFormatException("missing array $n")
    private fun JsonElement.obj(): JsonObject = this as? JsonObject ?: throw SnapshotFormatException("expected object")
    private fun JsonObject.req(n: String): JsonObject = this[n]?.obj() ?: throw SnapshotFormatException("missing $n")

    private fun key(o: JsonObject, bridge: BridgeId, expected: ResourceType? = null): ResourceKey {
        val type = o.str("type")?.let { ResourceType.fromWireName(it) } ?: throw SnapshotFormatException("bad key type")
        if (expected != null && type != expected) throw SnapshotFormatException("key type mismatch")
        val id = o.str("id") ?: throw SnapshotFormatException("bad key id")
        return ResourceKey(bridge, type, ResourceId(id))
    }

    private fun xy(o: JsonObject): CieXy = CieXy(o.dbl("x") ?: throw SnapshotFormatException("bad xy"), o.dbl("y") ?: throw SnapshotFormatException("bad xy"))

    private fun group(o: JsonObject, bridge: BridgeId, type: ResourceType, kind: GroupKind) = GroupState(
        key = key(o.req("key"), bridge, type),
        kind = kind,
        name = o.str("name") ?: throw SnapshotFormatException("group name"),
        archetype = o.str("archetype"),
        children = o.array("children").map { key(it.obj(), bridge) },
        groupedLight = (o["grouped_light"] as? JsonObject)?.let { key(it, bridge, ResourceType.GROUPED_LIGHT) },
    )

    private fun groupedLight(o: JsonObject, bridge: BridgeId) = GroupedLightState(
        key = key(o.req("key"), bridge, ResourceType.GROUPED_LIGHT),
        isOn = o.bool("on") ?: throw SnapshotFormatException("grouped on"),
        brightness = o.dbl("brightness"),
    )

    private fun <T> capability(o: JsonObject?, value: (JsonElement) -> T): Capability<T> {
        o ?: throw SnapshotFormatException("missing capability")
        val evidence = o.str("evidence")?.let { runCatching { Evidence.valueOf(it) }.getOrNull() } ?: throw SnapshotFormatException("bad evidence")
        val raw = o["value"]?.takeIf { it !is JsonNull }
        return if (evidence == Evidence.KNOWN) {
            Capability.known(value(raw ?: throw SnapshotFormatException("KNOWN without value")))
        } else {
            Capability(null, evidence)
        }
    }

    private fun strings(e: JsonElement): Set<String> = (e as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content }?.toSet()
        ?: throw SnapshotFormatException("bad string set")

    private fun gamut(e: JsonElement): Gamut {
        val o = e.obj()
        val source = o.str("source")?.let { runCatching { GamutSource.valueOf(it) }.getOrNull() } ?: throw SnapshotFormatException("gamut source")
        return Gamut(xy(o.req("red")), xy(o.req("green")), xy(o.req("blue")), source)
    }

    private fun capabilities(o: JsonObject) = LightCapabilities(
        color = capability(o["color"] as? JsonObject) { gamut(it) },
        colorTemperature = capability(o["color_temperature"] as? JsonObject) { val r = it.obj(); MirekRange(r.int("min") ?: throw SnapshotFormatException("min"), r.int("max") ?: throw SnapshotFormatException("max")) },
        effectsV1 = capability(o["effects_v1"] as? JsonObject) { strings(it) },
        effectsV2 = capability(o["effects_v2"] as? JsonObject) { strings(it) },
        timedEffects = capability(o["timed_effects"] as? JsonObject) { strings(it) },
        gradient = capability(o["gradient"] as? JsonObject) { val g = it.obj(); GradientCapability(g.int("points_capable") ?: throw SnapshotFormatException("pc"), strings(g["modes"] ?: JsonArray(emptyList())), g.int("pixel_count")) },
        signaling = capability(o["signaling"] as? JsonObject) { strings(it) },
        dynamics = capability(o["dynamics"] as? JsonObject) { },
    )

    private fun light(o: JsonObject, bridge: BridgeId) = LightState(
        key = key(o.req("key"), bridge, ResourceType.LIGHT),
        name = o.str("name") ?: throw SnapshotFormatException("light name"),
        isOn = o.bool("on") ?: throw SnapshotFormatException("light on"),
        brightness = o.dbl("brightness"),
        color = (o["color"] as? JsonObject)?.let { xy(it) },
        mirek = o.int("mirek"),
        mirekValid = o.bool("mirek_valid"),
        activeEffect = o.str("active_effect"),
        activeTimedEffect = o.str("active_timed_effect"),
        gradientPoints = o.array("gradient_points").map { xy(it.obj()) },
        owner = (o["owner"] as? JsonObject)?.let { key(it, bridge) },
        capabilities = capabilities(o.req("capabilities")),
    )

    private fun scene(o: JsonObject, bridge: BridgeId) = SceneState(
        key = key(o.req("key"), bridge, ResourceType.SCENE),
        name = o.str("name") ?: throw SnapshotFormatException("scene name"),
        group = key(o.req("group"), bridge),
        isActive = o.bool("active") ?: false,
        isDynamic = o.bool("dynamic") ?: false,
    )
}
