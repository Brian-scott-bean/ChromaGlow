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
import com.chromaglow.app.core.session.BridgeSnapshot
import com.chromaglow.app.core.session.ConnectionState
import com.chromaglow.app.core.session.DefaultMutationCoordinator
import com.chromaglow.app.core.session.Freshness
import com.chromaglow.app.core.session.GroupKind
import com.chromaglow.app.core.session.GroupState
import com.chromaglow.app.core.session.GroupedLightState
import com.chromaglow.app.core.session.LightState
import com.chromaglow.app.core.session.PendingAuthority
import com.chromaglow.app.core.session.RefreshReason
import com.chromaglow.app.core.session.SceneState
import com.chromaglow.app.core.session.SessionClock
import com.chromaglow.app.core.session.SessionEnvironment
import com.chromaglow.app.core.session.SnapshotStore
import com.chromaglow.app.core.session.safety.DefaultRiseLedger
import com.chromaglow.app.core.session.safety.EffectSafetyRegister
import com.chromaglow.app.core.session.safety.LampRiseLedger
import com.chromaglow.app.core.session.safety.LedgerTicket
import com.chromaglow.app.core.session.safety.LedgerVerdict
import com.chromaglow.app.core.session.safety.LedgerWrite
import com.chromaglow.app.core.session.safety.LuminanceFrame
import com.chromaglow.app.core.session.safety.RiseLedger
import com.chromaglow.app.core.session.safety.RiseVerdict
import com.chromaglow.app.core.session.safety.DeliveryOutcome
import com.chromaglow.app.core.session.safety.RiseReservation
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope

/** Everything a coordinator test needs: a scripted snapshot, a virtual-time clock, a recording transport. */
class CoordinatorHarness(
    scope: TestScope,
    register: EffectSafetyRegister = com.chromaglow.app.core.session.safety.DefaultEffectSafetyRegister,
    ledgerFactory: (BridgeId) -> LampRiseLedger = { DefaultRiseLedger(it) },
    pacingMillis: Long = 100L,
) {
    val bridge = BridgeId("001788FFFE112233")
    val dispatcher = StandardTestDispatcher(scope.testScheduler)
    val clock = SessionClock { scope.testScheduler.currentTime }
    val transport = FakeHueClipTransport(bridge) { scope.testScheduler.currentTime }
    val connection = MutableStateFlow<ConnectionState>(ConnectionState.Connected)
    val refreshes = mutableListOf<RefreshReason>()
    val unauthorized = mutableListOf<Int>()

    fun key(type: ResourceType, id: String) = ResourceKey(bridge, type, ResourceId(id))

    val colorLamp = key(ResourceType.LIGHT, "color")
    val ctLamp = key(ResourceType.LIGHT, "ct")
    val whiteLamp = key(ResourceType.LIGHT, "white")
    val stripLamp = key(ResourceType.LIGHT, "strip")
    val unknownLamp = key(ResourceType.LIGHT, "unknown")
    val room = key(ResourceType.ROOM, "room")
    val grouped = key(ResourceType.GROUPED_LIGHT, "gl")
    /** D-04 fixtures: a colour lamp in CT mode with a STALE saturated-blue xy, and a strip with mixed-luminance points. */
    val ctModeLamp = key(ResourceType.LIGHT, "ctmode")
    val redStrip = key(ResourceType.LIGHT, "redstrip")
    val room2 = key(ResourceType.ROOM, "room2")
    val grouped2 = key(ResourceType.GROUPED_LIGHT, "gl2")
    val scene = key(ResourceType.SCENE, "scene")
    val scene2 = key(ResourceType.SCENE, "scene2")

    private fun light(
        k: ResourceKey, name: String, caps: LightCapabilities, on: Boolean = true, bri: Double? = 50.0, xy: CieXy? = null,
        mirekValid: Boolean? = xy == null, points: List<CieXy> = emptyList(),
    ) = LightState(
        key = k, name = name, isOn = on, brightness = bri, color = xy, mirek = 300, mirekValid = mirekValid,
        activeEffect = null, activeTimedEffect = null, gradientPoints = points, owner = null, capabilities = caps,
    )

    val colorCaps = LightCapabilities(
        color = Capability.known(Gamut.specDerived(GamutType.C)), colorTemperature = Capability.known(MirekRange(153, 454)),
        effectsV1 = Capability.known(setOf("candle")), effectsV2 = Capability.known(setOf("no_effect", "candle", "prism", "cosmos")),
        timedEffects = Capability.known(setOf("no_effect", "sunrise", "sunset")), gradient = Capability.absent(),
        signaling = Capability.known(setOf("no_signal", "on_off")), dynamics = Capability.known(Unit),
    )
    val ctCaps = LightCapabilities.unknown().copy(
        color = Capability.absent(), colorTemperature = Capability.known(MirekRange(200, 454)),
        effectsV1 = Capability.known(setOf("no_effect", "candle")), effectsV2 = Capability.absent(),
        timedEffects = Capability.known(setOf("no_effect", "sunrise", "sunset")), gradient = Capability.absent(),
    )
    val whiteCaps = LightCapabilities.unknown().copy(
        color = Capability.absent(), colorTemperature = Capability.unreadable(), effectsV1 = Capability.absent(), effectsV2 = Capability.absent(),
        timedEffects = Capability.absent(), gradient = Capability.absent(), signaling = Capability.absent(), dynamics = Capability.absent(),
    )
    val stripCaps = colorCaps.copy(gradient = Capability.known(GradientCapability(5, setOf("interpolated_palette", "random_pixelated"), 7)))

    val initial: BridgeSnapshot = BridgeSnapshot(
        bridgeId = bridge, generation = 1, freshness = Freshness.Fresh(1),
        rooms = mapOf(
            room to GroupState(room, GroupKind.ROOM, "Living", null, listOf(colorLamp, ctLamp, whiteLamp), grouped),
            room2 to GroupState(room2, GroupKind.ROOM, "Studio", null, listOf(ctModeLamp, redStrip), grouped2),
        ),
        zones = emptyMap(),
        groupedLights = mapOf(grouped to GroupedLightState(grouped, true, 50.0), grouped2 to GroupedLightState(grouped2, true, 50.0)),
        lights = mapOf(
            colorLamp to light(colorLamp, "Color", colorCaps, xy = CieXy(0.3127, 0.3290)),
            ctLamp to light(ctLamp, "CT", ctCaps),
            whiteLamp to light(whiteLamp, "White", whiteCaps),
            stripLamp to light(stripLamp, "Strip", stripCaps, xy = CieXy(0.3127, 0.3290)),
            unknownLamp to light(unknownLamp, "Unknown", LightCapabilities.unknown()),
            ctModeLamp to light(ctModeLamp, "CT mode", colorCaps, xy = CieXy(0.15, 0.06), mirekValid = true),
            redStrip to light(redStrip, "Red strip", stripCaps, xy = CieXy(0.15, 0.06), points = listOf(CieXy(0.15, 0.06), CieXy(0.64, 0.33), CieXy(0.3127, 0.3290))),
        ),
        scenes = mapOf(
            scene to SceneState(scene, "Relax", room, isActive = false, isDynamic = false),
            scene2 to SceneState(scene2, "Energize", room, isActive = true, isDynamic = false),
        ),
    )

    val store = SnapshotStore(initial)
    val ledger: LampRiseLedger = ledgerFactory(bridge)
    val authority = PendingAuthority()

    val env = SessionEnvironment(
        bridgeId = bridge, scope = CoroutineScope(dispatcher), transport = transport, store = store,
        connection = connection, clock = clock, requestRefresh = { refreshes += it }, reportUnauthorized = { unauthorized += it },
    )

    val coordinator = DefaultMutationCoordinator(env, ledger = ledger, register = register, authority = authority, pacingMillis = pacingMillis)

    fun light(k: ResourceKey): LightState = store.value.lights.getValue(k)
}

/** A ledger with no safety at all: the breach control for the wire-spacing oracle. */
class AlwaysEmitLedger : LampRiseLedger {
    var admits = 0
    private var seq = 0L
    override fun admit(target: ResourceKey, next: LuminanceFrame, atMillis: Long): RiseVerdict { admits++; return RiseVerdict.Emit(null) }
    override fun settle(reservation: RiseReservation, outcome: DeliveryOutcome, atMillis: Long) = Unit
    override fun admit(write: LedgerWrite, atMillis: Long): LedgerVerdict { admits++; return LedgerVerdict.Emit(LedgerTicket(++seq), stamped = false) }
    override fun settle(ticket: LedgerTicket, outcome: DeliveryOutcome, atMillis: Long) = Unit
}

/** Counts admits/settles while delegating to the real ledger. */
class SpyLedger(private val inner: LampRiseLedger) : LampRiseLedger {
    var admits = 0
    val settles = mutableListOf<DeliveryOutcome>()
    val writes = mutableListOf<LedgerWrite>()
    override fun admit(target: ResourceKey, next: LuminanceFrame, atMillis: Long): RiseVerdict { admits++; return inner.admit(target, next, atMillis) }
    override fun settle(reservation: RiseReservation, outcome: DeliveryOutcome, atMillis: Long) { settles += outcome; inner.settle(reservation, outcome, atMillis) }
    override fun admit(write: LedgerWrite, atMillis: Long): LedgerVerdict { admits++; writes += write; return inner.admit(write, atMillis) }
    override fun settle(ticket: LedgerTicket, outcome: DeliveryOutcome, atMillis: Long) { settles += outcome; inner.settle(ticket, outcome, atMillis) }
}
