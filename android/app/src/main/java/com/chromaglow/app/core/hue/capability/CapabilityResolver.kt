package com.chromaglow.app.core.hue.capability

import com.chromaglow.app.core.hue.rest.wire.ClipBlocks
import com.chromaglow.app.core.hue.rest.wire.ClipLight
import com.chromaglow.app.core.hue.rest.wire.ClipXy
import com.chromaglow.app.core.identity.ResourceKey

/**
 * Builds [LightCapabilities] from the light resource's own truth and routes group controls.
 * Rules (plan §10/§11, each pinned by test):
 *  - a light never fetched → [LightCapabilities.unknown] (the caller never invokes [resolve])
 *  - block absent on a read light → ABSENT
 *  - block present but its schema/value unreadable → UNREADABLE (never a fabricated value)
 *  - CT present without a valid `mirek_schema` → UNREADABLE; no per-light 153–500 is invented
 *  - gamut: bridge triangle → BRIDGE; else `gamut_type` A/B/C → SPEC_DERIVED; else UNKNOWN
 *  - `effects_v2.action.effect_values` non-empty shadows v1 (via [LightCapabilities.effectValues])
 *  - nothing is ever inferred from archetype, model or product names
 */
object CapabilityResolver {

    fun resolve(light: ClipLight): LightCapabilities = LightCapabilities(
        color = resolveColor(light),
        colorTemperature = resolveColorTemperature(light),
        effectsV1 = values(light, ClipBlocks.EFFECTS, light.effects?.effectValues),
        effectsV2 = values(light, ClipBlocks.EFFECTS_V2, light.effectsV2?.actionEffectValues),
        timedEffects = values(light, ClipBlocks.TIMED_EFFECTS, light.timedEffects?.effectValues),
        gradient = resolveGradient(light),
        signaling = values(light, ClipBlocks.SIGNALING, light.signaling?.signalValues),
        dynamics = when {
            !light.hasBlock(ClipBlocks.DYNAMICS) -> Capability.absent()
            light.dynamics == null -> Capability.unreadable()
            else -> Capability.known(Unit)
        },
    )

    private fun cieXy(xy: ClipXy?): CieXy? {
        xy ?: return null
        if (xy.x !in 0.0..1.0 || xy.y !in 0.0..1.0) return null
        return CieXy(xy.x, xy.y)
    }

    private fun resolveColor(light: ClipLight): Capability<Gamut> {
        if (!light.hasBlock(ClipBlocks.COLOR)) return Capability.absent()
        val color = light.color ?: return Capability.unreadable()
        val triangle = color.gamut
        if (triangle != null) {
            val r = cieXy(triangle.red)
            val g = cieXy(triangle.green)
            val b = cieXy(triangle.blue)
            if (r != null && g != null && b != null) return Capability.known(Gamut.fromBridge(r, g, b))
        }
        Gamut.fromGamutType(color.gamutType)?.let { return Capability.known(it) }
        // Colour-capable, but the gamut is not readable from the resource: CHECKING, never a guess.
        return Capability.unknown()
    }

    private fun resolveColorTemperature(light: ClipLight): Capability<MirekRange> {
        if (!light.hasBlock(ClipBlocks.COLOR_TEMPERATURE)) return Capability.absent()
        val schema = light.colorTemperature?.schema ?: return Capability.unreadable()
        val range = runCatching { MirekRange(schema.minimum, schema.maximum) }.getOrNull()
            ?: return Capability.unreadable()
        return Capability.known(range)
    }

    private fun resolveGradient(light: ClipLight): Capability<GradientCapability> {
        if (!light.hasBlock(ClipBlocks.GRADIENT)) return Capability.absent()
        val gradient = light.gradient ?: return Capability.unreadable()
        val pointsCapable = gradient.pointsCapable?.takeIf { it >= 0 } ?: return Capability.unreadable()
        return Capability.known(
            GradientCapability(
                pointsCapable = pointsCapable,
                modes = gradient.modeValues?.toSet() ?: emptySet(),
                pixelCount = gradient.pixelCount,
            ),
        )
    }

    /** A value-list capability: absent block → ABSENT; present but empty/missing list → UNREADABLE. */
    private fun values(light: ClipLight, block: String, list: List<String>?): Capability<Set<String>> = when {
        !light.hasBlock(block) -> Capability.absent()
        list.isNullOrEmpty() -> Capability.unreadable()
        else -> Capability.known(list.toSet())
    }

    // ── per-light admission ──

    /** True only when the lamp's effect list is Known AND lists [effect]. The coordinator's gate. */
    fun supportsEffect(caps: LightCapabilities, effect: String): Boolean =
        caps.effectValues.isInteractive && effect in caps.effectValues.value.orEmpty()

    fun supportsTimedEffect(caps: LightCapabilities, effect: String): Boolean =
        caps.timedEffects.isInteractive && effect in caps.timedEffects.value.orEmpty()

    fun supportsGradient(caps: LightCapabilities): Boolean =
        caps.gradient.isInteractive && caps.gradient.value?.supportsGradient == true

    // ── group routing ──

    /**
     * Firmware-effect routing across a group's member lights. [RunUnverified] is returned when NO
     * member reports any effect list at all (a decode/firmware gap); it is diagnostic only and
     * `permitsUserMutation` is false — the coordinator never sends on it.
     */
    fun routeEffect(effect: String, members: Map<ResourceKey, LightCapabilities>): EffectRouting {
        if (members.isEmpty()) return EffectRouting.RunUnverified(emptySet())
        val anyReported = members.values.any { it.effectValues.isInteractive }
        if (!anyReported) return EffectRouting.RunUnverified(members.keys)
        val capable = members.filterValues { supportsEffect(it, effect) }.keys
        val coverage = Coverage(capable, members.size)
        return if (coverage.isEmpty) EffectRouting.Unsupported(effect) else EffectRouting.Run(capable, coverage)
    }

    /** "N of M" coverage of a group by lamps whose capability for [kind] is Known. */
    fun coverage(kind: ControlKind, members: Map<ResourceKey, LightCapabilities>): Coverage {
        val capable = members.filterValues { caps ->
            when (kind) {
                ControlKind.POWER, ControlKind.BRIGHTNESS, ControlKind.SCENE_RECALL -> true
                ControlKind.COLOR -> caps.color.isInteractive
                ControlKind.COLOR_TEMPERATURE -> caps.colorTemperature.isInteractive
                ControlKind.FIRMWARE_EFFECT -> caps.effectValues.isInteractive
                ControlKind.TIMED_EFFECT -> caps.timedEffects.isInteractive
                ControlKind.GRADIENT -> supportsGradient(caps)
            }
        }.keys
        return Coverage(capable, members.size)
    }

    /** Timed effects on a group are ALL-OR-NOTHING: offered only when every member lists [effect]. */
    fun timedEffectCoverage(effect: String, members: Map<ResourceKey, LightCapabilities>): Coverage =
        Coverage(members.filterValues { supportsTimedEffect(it, effect) }.keys, members.size)

    fun offersTimedEffectOnGroup(effect: String, members: Map<ResourceKey, LightCapabilities>): Boolean =
        members.isNotEmpty() && timedEffectCoverage(effect, members).isFull

    /** Members whose gradient capability is Known with ≥ 2 points (strip-class hardware). */
    fun gradientLights(members: Map<ResourceKey, LightCapabilities>): Set<ResourceKey> =
        members.filterValues { supportsGradient(it) }.keys
}
