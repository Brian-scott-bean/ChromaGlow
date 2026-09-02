package com.chromaglow.app.core.hue.rest.wire

/**
 * Bridge-side WIRE shapes of the CLIP v2 resources the slice reads, decoded tolerantly and kept
 * separate from the session's domain state. Every optional block is nullable: `null` means the
 * block was absent OR unreadable (see [ClipLight.presentBlocks] to tell the two apart, which is
 * what the capability resolver needs for ABSENT vs UNREADABLE). Nothing here is bridge-qualified;
 * the loader stamps the [com.chromaglow.app.core.identity.BridgeId] when it builds domain state.
 */
data class ClipRef(val rid: String, val rtype: String)

/** Raw xy as the bridge sent it; NOT validated to [0,1] here (that happens on conversion to CieXy). */
data class ClipXy(val x: Double, val y: Double)

data class ClipGamut(val red: ClipXy, val green: ClipXy, val blue: ClipXy)

data class ClipColor(val xy: ClipXy?, val gamut: ClipGamut?, val gamutType: String?)

data class ClipMirekSchema(val minimum: Int, val maximum: Int)

data class ClipColorTemperature(val mirek: Int?, val mirekValid: Boolean?, val schema: ClipMirekSchema?)

data class ClipDimming(val brightness: Double?, val minDimLevel: Double?)

data class ClipEffects(val status: String?, val statusValues: List<String>?, val effectValues: List<String>?)

data class ClipEffectParameters(val speed: Double?, val color: ClipXy?, val mirek: Int?)

data class ClipEffectsV2(
    val actionEffectValues: List<String>?,
    val statusEffect: String?,
    val statusEffectValues: List<String>?,
    val statusParameters: ClipEffectParameters?,
)

data class ClipTimedEffects(
    val status: String?,
    val statusValues: List<String>?,
    val effectValues: List<String>?,
    val duration: Long?,
)

data class ClipGradient(
    val points: List<ClipXy>?,
    val mode: String?,
    val modeValues: List<String>?,
    val pointsCapable: Int?,
    val pixelCount: Int?,
)

/** Decode-only in this slice: recorded as truth, never sent. */
data class ClipSignaling(val signalValues: List<String>?, val statusSignal: String?)

data class ClipDynamics(val status: String?, val statusValues: List<String>?, val speed: Double?, val speedValid: Boolean?)

/** Top-level block names the resolver reasons about for ABSENT vs UNREADABLE. */
object ClipBlocks {
    const val COLOR = "color"
    const val COLOR_TEMPERATURE = "color_temperature"
    const val EFFECTS = "effects"
    const val EFFECTS_V2 = "effects_v2"
    const val TIMED_EFFECTS = "timed_effects"
    const val GRADIENT = "gradient"
    const val SIGNALING = "signaling"
    const val DYNAMICS = "dynamics"
    const val DIMMING = "dimming"
}

data class ClipLight(
    val id: String,
    val idV1: String?,
    val owner: ClipRef?,
    val name: String?,
    val archetype: String?,
    val on: Boolean?,
    val dimming: ClipDimming?,
    val color: ClipColor?,
    val colorTemperature: ClipColorTemperature?,
    val effects: ClipEffects?,
    val effectsV2: ClipEffectsV2?,
    val timedEffects: ClipTimedEffects?,
    val gradient: ClipGradient?,
    val signaling: ClipSignaling?,
    val dynamics: ClipDynamics?,
    val mode: String?,
    /** Top-level keys that were PRESENT in the JSON object (any value), for ABSENT vs UNREADABLE. */
    val presentBlocks: Set<String>,
) {
    fun hasBlock(name: String): Boolean = name in presentBlocks
}

enum class ClipGroupKind(val wireType: String) { ROOM("room"), ZONE("zone") }

data class ClipGroup(
    val id: String,
    val kind: ClipGroupKind,
    val name: String?,
    val archetype: String?,
    val children: List<ClipRef>,
    val services: List<ClipRef>,
) {
    /** The first `grouped_light` service rid, if the bridge exposes one. */
    val groupedLightRid: String? get() = services.firstOrNull { it.rtype == "grouped_light" }?.rid
}

data class ClipGroupedLight(
    val id: String,
    val owner: ClipRef?,
    val on: Boolean?,
    val brightness: Double?,
    val xy: ClipXy?,
    val mirek: Int?,
    val alertActionValues: List<String>?,
    val signalValues: List<String>?,
)

data class ClipSceneAction(
    val target: ClipRef,
    val on: Boolean?,
    val brightness: Double?,
    val xy: ClipXy?,
    val mirek: Int?,
)

data class ClipScene(
    val id: String,
    val name: String?,
    val group: ClipRef?,
    /** `status.active`: "inactive" | "static" | "dynamic_palette" (or null when not reported). */
    val statusActive: String?,
    val speed: Double?,
    val type: String?,
    val autoDynamic: Boolean?,
    val actions: List<ClipSceneAction>?,
    val paletteColors: List<ClipXy>?,
) {
    val isActive: Boolean get() = statusActive == "static" || statusActive == "dynamic_palette"
    val isDynamic: Boolean get() = type == "dynamic" || statusActive == "dynamic_palette"
}

/** `GET /clip/v2/resource/bridge` element, for the diagnostic identity probe. */
data class ClipBridge(val id: String, val bridgeId: String?, val timeZone: String?)
