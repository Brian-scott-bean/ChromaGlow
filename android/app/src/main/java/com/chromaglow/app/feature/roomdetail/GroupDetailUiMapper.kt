package com.chromaglow.app.feature.roomdetail

import com.chromaglow.app.core.identity.ResourceKey
import com.chromaglow.app.core.identity.TargetRef
import com.chromaglow.app.core.session.BridgeSnapshot
import com.chromaglow.app.core.session.ConnectionState
import com.chromaglow.app.core.session.GroupState
import com.chromaglow.app.core.session.HomeSnapshot
import com.chromaglow.app.core.session.LightState
import com.chromaglow.app.feature.home.GroupCardUi
import com.chromaglow.app.feature.home.HomeUiMapper
import kotlin.math.roundToInt

/** Pure mapping for Room/Zone detail. Membership follows the freeze rule: child rid == light OR owner. */
object GroupDetailUiMapper {

    fun map(home: HomeSnapshot, groupKey: ResourceKey, nowMillis: Long): GroupDetailUiState {
        val snapshot = home.bridges[groupKey.bridgeId]
        val connection = home.connections[groupKey.bridgeId] ?: ConnectionState.Connecting
        val strip = listOf(HomeUiMapper.connectionRow(groupKey.bridgeId, connection, nowMillis, home.bridges.size > 1))
        val group = snapshot?.let { it.rooms[groupKey] ?: it.zones[groupKey] }
            ?: return GroupDetailUiState(found = false, group = null, lights = emptyList(), coverage = emptyList(), strip = strip)
        val (enabled, reason) = HomeUiMapper.interaction(connection)
        val members = memberLights(snapshot, group).sortedBy { it.name.lowercase() }
        return GroupDetailUiState(
            found = true,
            group = groupCard(snapshot, group, members.size, enabled, reason),
            lights = members.map { lightCard(it, enabled, reason) },
            coverage = coverageLines(members),
            strip = strip,
            groupColor = instrument(members.count { it.capabilities.color.isInteractive }, members.size),
            groupWarmth = instrument(members.count { it.capabilities.colorTemperature.isInteractive }, members.size),
        )
    }

    /** Hidden (null) unless at least one member reports the capability as KNOWN. */
    fun instrument(capableCount: Int, total: Int): GroupInstrumentUi? =
        if (capableCount > 0) GroupInstrumentUi(capableCount, total) else null

    fun memberLights(snapshot: BridgeSnapshot, group: GroupState): List<LightState> {
        val children = group.children.toSet()
        return snapshot.lights.values.filter { light ->
            light.key in children || (light.owner != null && light.owner in children)
        }
    }

    private fun groupCard(snapshot: BridgeSnapshot, group: GroupState, lightCount: Int, enabled: Boolean, reason: String?): GroupCardUi {
        val grouped = group.groupedLight?.let { snapshot.groupedLights[it] }
        return GroupCardUi(
            groupKey = group.key,
            target = group.groupedLight?.let { TargetRef.Live(it) },
            bridgeId = snapshot.bridgeId,
            kind = group.kind,
            name = group.name,
            lightCount = lightCount,
            isOn = grouped?.isOn ?: false,
            brightness = grouped?.brightness?.roundToInt()?.coerceIn(1, 100),
            controlsEnabled = enabled && group.groupedLight != null,
            disabledReason = when {
                !enabled -> reason
                group.groupedLight == null -> "This group has no grouped light to control"
                else -> null
            },
        )
    }

    fun lightCard(light: LightState, enabled: Boolean, reason: String?): LightCardUi = LightCardUi(
        key = light.key,
        name = light.name,
        isOn = light.isOn,
        brightness = light.brightness?.roundToInt()?.coerceIn(1, 100),
        colorXy = light.color,
        mirek = if (light.mirekValid == true) light.mirek else null,
        knownGlyphs = glyphs(light),
        controlsEnabled = enabled,
        disabledReason = if (enabled) null else reason,
    )

    /** Only KNOWN capabilities become glyphs. Unknown and Absent are never advertised. */
    fun glyphs(light: LightState): List<String> {
        val caps = light.capabilities
        return buildList {
            if (caps.color.isInteractive) add("Colour")
            if (caps.colorTemperature.isInteractive) add("Warmth")
            if (caps.effectValues.isInteractive && !caps.effectValues.value.isNullOrEmpty()) add("Effects")
            if (caps.gradient.isInteractive && caps.gradient.value?.supportsGradient == true) add("Gradient")
        }
    }

    /** "N of M lights support X" for every capability at least one member reports; silent otherwise. */
    fun coverageLines(members: List<LightState>): List<String> {
        val total = members.size
        if (total == 0) return emptyList()
        fun line(label: String, count: Int): String? = when {
            count == 0 -> null
            count == total -> if (total == 1) "This light supports $label" else "All $total lights support $label"
            else -> "$count of $total lights support $label"
        }
        return listOfNotNull(
            line("colour", members.count { it.capabilities.color.isInteractive }),
            line("warmth", members.count { it.capabilities.colorTemperature.isInteractive }),
            line("effects", members.count { it.capabilities.effectValues.isInteractive && !it.capabilities.effectValues.value.isNullOrEmpty() }),
            line("gradient", members.count { it.capabilities.gradient.isInteractive && it.capabilities.gradient.value?.supportsGradient == true }),
        )
    }
}
