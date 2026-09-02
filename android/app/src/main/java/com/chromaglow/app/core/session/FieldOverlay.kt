package com.chromaglow.app.core.session

import com.chromaglow.app.core.identity.ResourceKey
import com.chromaglow.app.core.identity.ResourceType

/**
 * The one definition of "copy field group F of resource K from snapshot `source` onto snapshot
 * `target`". Used for rollback (source = pre-overlay truth) and for re-applying unexpired
 * optimistic overlays onto an authoritative load (source = the current optimistic snapshot, B-01).
 */
object FieldOverlay {
    fun copy(target: BridgeSnapshot, source: BridgeSnapshot, key: ResourceKey, field: FieldGroup): BridgeSnapshot = when (key.type) {
        ResourceType.LIGHT -> {
            val from = source.lights[key]; val to = target.lights[key]
            if (from == null || to == null) target else target.copy(lights = target.lights + (key to copyLight(to, from, field)))
        }
        ResourceType.GROUPED_LIGHT -> {
            val from = source.groupedLights[key]; val to = target.groupedLights[key]
            if (from == null || to == null) target else target.copy(groupedLights = target.groupedLights + (key to when (field) {
                FieldGroup.POWER -> to.copy(isOn = from.isOn)
                FieldGroup.DIMMING -> to.copy(isOn = from.isOn, brightness = from.brightness)
                else -> to
            }))
        }
        ResourceType.SCENE -> {
            val group = source.scenes[key]?.group ?: target.scenes[key]?.group ?: return target
            target.copy(scenes = target.scenes.mapValues { (k, v) ->
                if (v.group == group) v.copy(isActive = source.scenes[k]?.isActive ?: v.isActive, isDynamic = source.scenes[k]?.isDynamic ?: v.isDynamic) else v
            })
        }
        else -> target
    }

    fun copyLight(to: LightState, from: LightState, field: FieldGroup): LightState = when (field) {
        FieldGroup.POWER -> to.copy(isOn = from.isOn)
        FieldGroup.DIMMING -> to.copy(brightness = from.brightness)
        FieldGroup.COLOR -> to.copy(color = from.color, mirekValid = from.mirekValid)
        FieldGroup.COLOR_TEMPERATURE -> to.copy(mirek = from.mirek, mirekValid = from.mirekValid)
        FieldGroup.EFFECT -> to.copy(activeEffect = from.activeEffect)
        FieldGroup.TIMED_EFFECT -> to.copy(activeTimedEffect = from.activeTimedEffect)
        FieldGroup.GRADIENT -> to.copy(gradientPoints = from.gradientPoints, color = from.color)
        FieldGroup.SCENE -> to
    }
}
