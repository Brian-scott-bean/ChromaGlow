package com.chromaglow.app.testing

import com.chromaglow.app.core.hue.capability.Capability
import com.chromaglow.app.core.hue.capability.CieXy
import com.chromaglow.app.core.hue.capability.Gamut
import com.chromaglow.app.core.hue.capability.GamutType
import com.chromaglow.app.core.hue.capability.GradientCapability
import com.chromaglow.app.core.hue.capability.LightCapabilities
import com.chromaglow.app.core.hue.capability.MirekRange
import com.chromaglow.app.core.identity.BridgeId
import com.chromaglow.app.core.identity.ResourceId
import com.chromaglow.app.core.identity.ResourceKey
import com.chromaglow.app.core.identity.ResourceType
import com.chromaglow.app.core.identity.TargetRef
import com.chromaglow.app.core.session.BridgeSession
import com.chromaglow.app.core.session.BridgeSnapshot
import com.chromaglow.app.core.session.ConnectionState
import com.chromaglow.app.core.session.EffectParameters
import com.chromaglow.app.core.session.Freshness
import com.chromaglow.app.core.session.GroupKind
import com.chromaglow.app.core.session.GroupState
import com.chromaglow.app.core.session.GroupedLightState
import com.chromaglow.app.core.session.HomeCommands
import com.chromaglow.app.core.session.HomeSnapshot
import com.chromaglow.app.core.session.LightState
import com.chromaglow.app.core.session.LiveHome
import com.chromaglow.app.core.session.LiveMutation
import com.chromaglow.app.core.session.MutationOutcome
import com.chromaglow.app.core.session.MutationToken
import com.chromaglow.app.core.session.RefreshReason
import com.chromaglow.app.core.session.SceneState
import com.chromaglow.app.core.session.TimedEffect
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * Deterministic fakes over the frozen P2 contracts for presentation tests. No transport, no
 * coroutine machinery beyond StateFlow. The androidTest source set carries a byte-identical copy
 * under `com.chromaglow.app.testing`.
 */

val BRIDGE_A: BridgeId = BridgeId("001788FFFE000001")
val BRIDGE_B: BridgeId = BridgeId("001788FFFE000002")

fun key(bridge: BridgeId, type: ResourceType, id: String): ResourceKey =
    ResourceKey(bridge, type, ResourceId(id))

fun roomKey(id: String, bridge: BridgeId = BRIDGE_A) = key(bridge, ResourceType.ROOM, id)
fun zoneKey(id: String, bridge: BridgeId = BRIDGE_A) = key(bridge, ResourceType.ZONE, id)
fun groupedKey(id: String, bridge: BridgeId = BRIDGE_A) = key(bridge, ResourceType.GROUPED_LIGHT, id)
fun lightKey(id: String, bridge: BridgeId = BRIDGE_A) = key(bridge, ResourceType.LIGHT, id)
fun sceneKey(id: String, bridge: BridgeId = BRIDGE_A) = key(bridge, ResourceType.SCENE, id)

/** Capability presets that mirror real lamp classes. */
object Caps {
    fun white(): LightCapabilities = LightCapabilities(
        color = Capability.absent(),
        colorTemperature = Capability.absent(),
        effectsV1 = Capability.absent(),
        effectsV2 = Capability.absent(),
        timedEffects = Capability.absent(),
        gradient = Capability.absent(),
        signaling = Capability.absent(),
        dynamics = Capability.known(Unit),
    )

    fun ctOnly(range: MirekRange = MirekRange(153, 454)): LightCapabilities = white().copy(
        colorTemperature = Capability.known(range),
    )

    fun ctWithoutSchema(): LightCapabilities = white().copy(colorTemperature = Capability.unreadable())

    fun color(
        gamut: Gamut = Gamut.specDerived(GamutType.C),
        range: MirekRange = MirekRange(153, 500),
        effects: Set<String> = setOf("candle", "fire", "sparkle"),
        timed: Set<String> = setOf("sunrise", "sunset"),
    ): LightCapabilities = LightCapabilities(
        color = Capability.known(gamut),
        colorTemperature = Capability.known(range),
        effectsV1 = Capability.known(setOf("candle")),
        effectsV2 = Capability.known(effects),
        timedEffects = Capability.known(timed),
        gradient = Capability.absent(),
        signaling = Capability.absent(),
        dynamics = Capability.known(Unit),
    )

    fun colorGamutUnknown(): LightCapabilities = color().copy(color = Capability.unknown())

    fun gradient(pointsCapable: Int = 5, modes: Set<String> = setOf("interpolated_palette", "random_pixelated")): LightCapabilities =
        color().copy(gradient = Capability.known(GradientCapability(pointsCapable, modes, pixelCount = 7)))

    fun unknown(): LightCapabilities = LightCapabilities.unknown()
}

fun light(
    id: String,
    name: String,
    owner: ResourceKey? = null,
    isOn: Boolean = true,
    brightness: Double? = 72.0,
    color: CieXy? = null,
    mirek: Int? = null,
    mirekValid: Boolean? = null,
    activeEffect: String? = null,
    activeTimedEffect: String? = null,
    gradientPoints: List<CieXy> = emptyList(),
    capabilities: LightCapabilities = Caps.color(),
    bridge: BridgeId = BRIDGE_A,
): LightState = LightState(
    key = lightKey(id, bridge),
    name = name,
    isOn = isOn,
    brightness = brightness,
    color = color,
    mirek = mirek,
    mirekValid = mirekValid,
    activeEffect = activeEffect,
    activeTimedEffect = activeTimedEffect,
    gradientPoints = gradientPoints,
    owner = owner,
    capabilities = capabilities,
)

fun group(
    key: ResourceKey,
    name: String,
    children: List<ResourceKey>,
    groupedLight: ResourceKey?,
    kind: GroupKind = if (key.type == ResourceType.ZONE) GroupKind.ZONE else GroupKind.ROOM,
): GroupState = GroupState(key, kind, name, archetype = null, children = children, groupedLight = groupedLight)

fun grouped(key: ResourceKey, isOn: Boolean = true, brightness: Double? = 72.0): GroupedLightState =
    GroupedLightState(key, isOn, brightness)

fun scene(key: ResourceKey, name: String, group: ResourceKey, isActive: Boolean = false, isDynamic: Boolean = false): SceneState =
    SceneState(key, name, group, isActive, isDynamic)

fun snapshot(
    bridge: BridgeId = BRIDGE_A,
    generation: Long = 1,
    freshness: Freshness = Freshness.Fresh(generation),
    rooms: List<GroupState> = emptyList(),
    zones: List<GroupState> = emptyList(),
    groupedLights: List<GroupedLightState> = emptyList(),
    lights: List<LightState> = emptyList(),
    scenes: List<SceneState> = emptyList(),
): BridgeSnapshot = BridgeSnapshot(
    bridgeId = bridge,
    generation = generation,
    freshness = freshness,
    rooms = rooms.associateBy { it.key },
    zones = zones.associateBy { it.key },
    groupedLights = groupedLights.associateBy { it.key },
    lights = lights.associateBy { it.key },
    scenes = scenes.associateBy { it.key },
)

/** A ready-made two-room, one-zone home on bridge A with one colour lamp and one white lamp. */
object Fixtures {
    val livingRoom = roomKey("room-living")
    val bedroom = roomKey("room-bed")
    val upstairs = zoneKey("zone-up")
    val livingGrouped = groupedKey("gl-living")
    val bedGrouped = groupedKey("gl-bed")
    val upGrouped = groupedKey("gl-up")
    val lampColor = lightKey("light-color")
    val lampWhite = lightKey("light-white")
    val lampCt = lightKey("light-ct")
    val sceneRelax = sceneKey("scene-relax")
    val sceneBright = sceneKey("scene-bright")
    val sceneBed = sceneKey("scene-bed")

    fun home(connection: ConnectionState = ConnectionState.Connected): HomeSnapshot = HomeSnapshot(
        bridges = mapOf(BRIDGE_A to bridgeA()),
        connections = mapOf(BRIDGE_A to connection),
    )

    fun bridgeA(): BridgeSnapshot = snapshot(
        rooms = listOf(
            group(livingRoom, "Living Room", listOf(lampColor, lampWhite), livingGrouped),
            group(bedroom, "Bedroom", listOf(lampCt), bedGrouped),
        ),
        zones = listOf(group(upstairs, "Upstairs", listOf(lampCt, lampColor), upGrouped)),
        groupedLights = listOf(
            grouped(livingGrouped, isOn = true, brightness = 72.0),
            grouped(bedGrouped, isOn = false, brightness = 40.0),
            grouped(upGrouped, isOn = true, brightness = 55.0),
        ),
        lights = listOf(
            light("light-color", "Floor Lamp", color = CieXy(0.45, 0.41), mirek = null, mirekValid = false, capabilities = Caps.color()),
            light("light-white", "Ceiling", brightness = 100.0, capabilities = Caps.white()),
            light("light-ct", "Reading Light", mirek = 366, mirekValid = true, capabilities = Caps.ctOnly(MirekRange(153, 454))),
        ),
        scenes = listOf(
            scene(sceneRelax, "Relax", livingRoom, isActive = true),
            scene(sceneBright, "Bright", livingRoom),
            scene(sceneBed, "Nightlight", bedroom, isDynamic = true),
        ),
    )
}

class FakeBridgeSession(
    override val bridgeId: BridgeId,
    initial: BridgeSnapshot = BridgeSnapshot.empty(bridgeId),
    initialConnection: ConnectionState = ConnectionState.Connecting,
) : BridgeSession {
    override val snapshot = MutableStateFlow(initial)
    override val connection = MutableStateFlow(initialConnection)
    val refreshes = mutableListOf<RefreshReason>()
    val submitted = mutableListOf<LiveMutation>()
    var outcome: MutationOutcome = MutationOutcome.Accepted(MutationToken(1))
    var closed = false

    override fun requestRefresh(reason: RefreshReason) { refreshes += reason }
    override suspend fun submit(mutation: LiveMutation): MutationOutcome { submitted += mutation; return outcome }
    override fun close() { closed = true }
}

class FakeLiveHome(initial: HomeSnapshot = HomeSnapshot(emptyMap(), emptyMap())) : LiveHome {
    override val home = MutableStateFlow(initial)
    val sessions = mutableMapOf<BridgeId, FakeBridgeSession>()
    val refreshes = mutableListOf<RefreshReason>()
    val submitted = mutableListOf<LiveMutation>()
    val removed = mutableListOf<BridgeId>()
    var foregrounds = 0
    var backgrounds = 0
    var closed = false

    fun emit(snapshot: HomeSnapshot) { home.value = snapshot }

    override fun session(bridgeId: BridgeId): BridgeSession? = sessions[bridgeId]
    override fun requestRefresh(reason: RefreshReason) { refreshes += reason }
    override suspend fun submit(mutation: LiveMutation): MutationOutcome {
        submitted += mutation
        return MutationOutcome.Accepted(MutationToken(submitted.size.toLong()))
    }
    override fun onForeground() { foregrounds++ }
    override fun onBackground() { backgrounds++ }
    override fun remove(bridgeId: BridgeId) { removed += bridgeId }
    override fun close() { closed = true }
}

/** Records every command; one entry per call, in order. */
class RecordingHomeCommands : HomeCommands {
    sealed interface Call {
        data class GroupPower(val target: TargetRef, val on: Boolean) : Call
        data class GroupBrightness(val target: TargetRef, val percent: Int) : Call
        data class LightPower(val target: TargetRef, val on: Boolean) : Call
        data class LightBrightness(val target: TargetRef, val percent: Int) : Call
        data class LightColor(val target: TargetRef, val xy: CieXy) : Call
        data class LightCt(val target: TargetRef, val mirek: Int) : Call
        data class Effect(val target: TargetRef, val effect: String, val parameters: EffectParameters) : Call
        data class StopEffect(val target: TargetRef) : Call
        data class Timed(val target: TargetRef, val effect: TimedEffect, val durationMillis: Long) : Call
        data class CancelTimed(val target: TargetRef) : Call
        data class Gradient(val target: TargetRef, val points: List<CieXy>, val mode: String?) : Call
        data class Scene(val target: TargetRef) : Call
        data class Refresh(val reason: RefreshReason) : Call
    }

    val calls = mutableListOf<Call>()

    override fun setGroupPower(target: TargetRef, on: Boolean) { calls += Call.GroupPower(target, on) }
    override fun setGroupBrightness(target: TargetRef, percent: Int) { calls += Call.GroupBrightness(target, percent) }
    override fun setLightPower(target: TargetRef, on: Boolean) { calls += Call.LightPower(target, on) }
    override fun setLightBrightness(target: TargetRef, percent: Int) { calls += Call.LightBrightness(target, percent) }
    override fun setLightColor(target: TargetRef, xy: CieXy) { calls += Call.LightColor(target, xy) }
    override fun setLightColorTemperature(target: TargetRef, mirek: Int) { calls += Call.LightCt(target, mirek) }
    override fun selectEffect(target: TargetRef, effect: String, parameters: EffectParameters) { calls += Call.Effect(target, effect, parameters) }
    override fun stopEffect(target: TargetRef) { calls += Call.StopEffect(target) }
    override fun startTimedEffect(target: TargetRef, effect: TimedEffect, durationMillis: Long) { calls += Call.Timed(target, effect, durationMillis) }
    override fun cancelTimedEffect(target: TargetRef) { calls += Call.CancelTimed(target) }
    override fun setGradient(target: TargetRef, points: List<CieXy>, mode: String?) { calls += Call.Gradient(target, points, mode) }
    override fun activateScene(target: TargetRef) { calls += Call.Scene(target) }
    override fun refresh(reason: RefreshReason) { calls += Call.Refresh(reason) }
}

/** Convenience for tests that only need a home flow. */
fun homeOf(vararg pairs: Pair<BridgeSnapshot, ConnectionState>): HomeSnapshot = HomeSnapshot(
    bridges = pairs.associate { it.first.bridgeId to it.first },
    connections = pairs.associate { it.first.bridgeId to it.second },
)
