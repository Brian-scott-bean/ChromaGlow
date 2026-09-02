package com.chromaglow.app.core.hue.rest.wire

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject

/**
 * Per-element tolerant decoders from a CLIP v2 `data[]` element to the wire models. Each decoder
 * returns null ONLY when the element cannot be identified (missing/blank/whitespace `id`, or a
 * `type` that is not the requested resource); every other malformed fragment degrades to a null
 * block or a skipped list entry. One malformed element never fails a document, and no input —
 * including deeply wrong shapes — throws.
 */
object ClipResourceCodec {

    private fun JsonObject.identity(expectedType: String?): String? {
        val id = str("id")?.takeIf { it.isNotBlank() && it.none(Char::isWhitespace) } ?: return null
        val type = str("type")
        if (expectedType != null && type != null && type != expectedType) return null
        return id
    }

    fun ref(obj: JsonObject?): ClipRef? {
        val rid = obj?.str("rid")?.takeIf { it.isNotBlank() && it.none(Char::isWhitespace) } ?: return null
        val rtype = obj?.str("rtype")?.takeIf { it.isNotBlank() } ?: return null
        return ClipRef(rid, rtype)
    }

    private fun refs(arr: JsonArray?): List<ClipRef> = arr?.mapNotNull { ref(it as? JsonObject) } ?: emptyList()

    fun xy(obj: JsonObject?): ClipXy? {
        val x = obj?.dbl("x") ?: return null
        val y = obj?.dbl("y") ?: return null
        return ClipXy(x, y)
    }

    private fun gamut(obj: JsonObject?): ClipGamut? {
        val red = xy(obj?.obj("red")) ?: return null
        val green = xy(obj?.obj("green")) ?: return null
        val blue = xy(obj?.obj("blue")) ?: return null
        return ClipGamut(red, green, blue)
    }

    private fun color(obj: JsonObject?): ClipColor? {
        obj ?: return null
        return ClipColor(xy = xy(obj.obj("xy")), gamut = gamut(obj.obj("gamut")), gamutType = obj.str("gamut_type"))
    }

    private fun mirekSchema(obj: JsonObject?): ClipMirekSchema? {
        val min = obj?.int("mirek_minimum") ?: return null
        val max = obj?.int("mirek_maximum") ?: return null
        return ClipMirekSchema(min, max)
    }

    private fun colorTemperature(obj: JsonObject?): ClipColorTemperature? {
        obj ?: return null
        return ClipColorTemperature(
            mirek = obj.int("mirek"),
            mirekValid = obj.bool("mirek_valid"),
            schema = mirekSchema(obj.obj("mirek_schema")),
        )
    }

    private fun dimming(obj: JsonObject?): ClipDimming? {
        obj ?: return null
        return ClipDimming(brightness = obj.dbl("brightness"), minDimLevel = obj.dbl("min_dim_level"))
    }

    private fun effects(obj: JsonObject?): ClipEffects? {
        obj ?: return null
        return ClipEffects(status = obj.str("status"), statusValues = obj.strList("status_values"), effectValues = obj.strList("effect_values"))
    }

    private fun effectParameters(obj: JsonObject?): ClipEffectParameters? {
        obj ?: return null
        return ClipEffectParameters(
            speed = obj.dbl("speed"),
            color = xy(obj.obj("color")?.obj("xy")),
            mirek = obj.obj("color_temperature")?.int("mirek"),
        )
    }

    private fun effectsV2(obj: JsonObject?): ClipEffectsV2? {
        obj ?: return null
        val status = obj.obj("status")
        return ClipEffectsV2(
            actionEffectValues = obj.obj("action")?.strList("effect_values"),
            statusEffect = status?.str("effect"),
            statusEffectValues = status?.strList("effect_values"),
            statusParameters = effectParameters(status?.obj("parameters")),
        )
    }

    private fun timedEffects(obj: JsonObject?): ClipTimedEffects? {
        obj ?: return null
        return ClipTimedEffects(
            status = obj.str("status"),
            statusValues = obj.strList("status_values"),
            effectValues = obj.strList("effect_values"),
            duration = obj.long("duration"),
        )
    }

    private fun gradientPoints(arr: JsonArray?): List<ClipXy>? =
        arr?.mapNotNull { xy((it as? JsonObject)?.obj("color")?.obj("xy")) }

    private fun gradient(obj: JsonObject?): ClipGradient? {
        obj ?: return null
        return ClipGradient(
            points = gradientPoints(obj.arr("points")),
            mode = obj.str("mode"),
            modeValues = obj.strList("mode_values"),
            pointsCapable = obj.int("points_capable"),
            pixelCount = obj.int("pixel_count"),
        )
    }

    private fun signaling(obj: JsonObject?): ClipSignaling? {
        obj ?: return null
        return ClipSignaling(signalValues = obj.strList("signal_values"), statusSignal = obj.obj("status")?.str("signal"))
    }

    private fun dynamics(obj: JsonObject?): ClipDynamics? {
        obj ?: return null
        return ClipDynamics(
            status = obj.str("status"),
            statusValues = obj.strList("status_values"),
            speed = obj.dbl("speed"),
            speedValid = obj.bool("speed_valid"),
        )
    }

    fun light(element: JsonObject): ClipLight? {
        val id = element.identity("light") ?: return null
        val metadata = element.obj("metadata")
        return ClipLight(
            id = id,
            idV1 = element.str("id_v1"),
            owner = ref(element.obj("owner")),
            name = metadata?.str("name"),
            archetype = metadata?.str("archetype"),
            on = element.obj("on")?.bool("on"),
            dimming = dimming(element.obj(ClipBlocks.DIMMING)),
            color = color(element.obj(ClipBlocks.COLOR)),
            colorTemperature = colorTemperature(element.obj(ClipBlocks.COLOR_TEMPERATURE)),
            effects = effects(element.obj(ClipBlocks.EFFECTS)),
            effectsV2 = effectsV2(element.obj(ClipBlocks.EFFECTS_V2)),
            timedEffects = timedEffects(element.obj(ClipBlocks.TIMED_EFFECTS)),
            gradient = gradient(element.obj(ClipBlocks.GRADIENT)),
            signaling = signaling(element.obj(ClipBlocks.SIGNALING)),
            dynamics = dynamics(element.obj(ClipBlocks.DYNAMICS)),
            mode = element.str("mode"),
            presentBlocks = element.keys.toSet(),
        )
    }

    fun group(element: JsonObject, kind: ClipGroupKind): ClipGroup? {
        val id = element.identity(kind.wireType) ?: return null
        val metadata = element.obj("metadata")
        return ClipGroup(
            id = id,
            kind = kind,
            name = metadata?.str("name"),
            archetype = metadata?.str("archetype"),
            children = refs(element.arr("children")),
            services = refs(element.arr("services")),
        )
    }

    fun groupedLight(element: JsonObject): ClipGroupedLight? {
        val id = element.identity("grouped_light") ?: return null
        return ClipGroupedLight(
            id = id,
            owner = ref(element.obj("owner")),
            on = element.obj("on")?.bool("on"),
            brightness = element.obj("dimming")?.dbl("brightness"),
            xy = xy(element.obj("color")?.obj("xy")),
            mirek = element.obj("color_temperature")?.int("mirek"),
            alertActionValues = element.obj("alert")?.strList("action_values"),
            signalValues = element.obj("signaling")?.strList("signal_values"),
        )
    }

    private fun sceneAction(obj: JsonObject?): ClipSceneAction? {
        val target = ref(obj?.obj("target")) ?: return null
        val action = obj?.obj("action")
        return ClipSceneAction(
            target = target,
            on = action?.obj("on")?.bool("on"),
            brightness = action?.obj("dimming")?.dbl("brightness"),
            xy = xy(action?.obj("color")?.obj("xy")),
            mirek = action?.obj("color_temperature")?.int("mirek"),
        )
    }

    fun scene(element: JsonObject): ClipScene? {
        val id = element.identity("scene") ?: return null
        val palette = element.obj("palette")
        return ClipScene(
            id = id,
            name = element.obj("metadata")?.str("name"),
            group = ref(element.obj("group")),
            statusActive = element.obj("status")?.str("active"),
            speed = element.dbl("speed"),
            type = element.str("type"),
            autoDynamic = element.bool("auto_dynamic"),
            actions = element.arr("actions")?.mapNotNull { sceneAction(it as? JsonObject) },
            paletteColors = palette?.arr("color")?.mapNotNull { xy((it as? JsonObject)?.obj("color")?.obj("xy")) },
        )
    }

    fun bridge(element: JsonObject): ClipBridge? {
        val id = element.identity("bridge") ?: return null
        return ClipBridge(id = id, bridgeId = element.str("bridge_id"), timeZone = element.obj("time_zone")?.str("time_zone"))
    }
}
