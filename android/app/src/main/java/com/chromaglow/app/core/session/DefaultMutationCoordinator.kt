package com.chromaglow.app.core.session

import com.chromaglow.app.core.hue.capability.CapabilityResolver
import com.chromaglow.app.core.hue.capability.CieXy
import com.chromaglow.app.core.hue.capability.EffectRouting
import com.chromaglow.app.core.hue.capability.LightCapabilities
import com.chromaglow.app.core.hue.rest.ClipBodies
import com.chromaglow.app.core.hue.rest.ClipError
import com.chromaglow.app.core.hue.rest.ClipResult
import com.chromaglow.app.core.hue.rest.ClipWriteBody
import com.chromaglow.app.core.identity.ResourceKey
import com.chromaglow.app.core.identity.ResourceType
import com.chromaglow.app.core.session.safety.DefaultEffectSafetyRegister
import com.chromaglow.app.core.session.safety.DefaultFlashSafety
import com.chromaglow.app.core.session.safety.DefaultRiseLedger
import com.chromaglow.app.core.session.safety.DeliveryOutcome
import com.chromaglow.app.core.session.safety.EffectSafetyRegister
import com.chromaglow.app.core.session.safety.FlashSafety
import com.chromaglow.app.core.session.safety.LuminanceFrame
import com.chromaglow.app.core.session.safety.RiseLedger
import com.chromaglow.app.core.session.safety.RiseVerdict
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * THE single outbound mutation authority for one bridge (frozen contract [MutationCoordinator]).
 *
 * submit(): refuse (closed / Revoked / Offline / unknown target / capability not Known / effect
 * denied by the safety register / routing class not offered) → plan the exact writes (a light
 * write, a grouped_light write, a scene recall, or a per-light fan-out for SUBSET/ALL_OR_NOTHING
 * routing) → apply the optimistic overlay and claim field-aware pending authority per
 * (ResourceKey, FieldGroup) → park each write in its latest-wins slot → Accepted(token).
 *
 * The sender drains slots FIFO with ≥ [pacingMillis] between sends on this bridge. Before every
 * send the [RiseLedger] is asked with the frame the write would realize: Hold keeps the write in
 * its slot and re-asks at the retry time; Emit sends exactly one PUT. Settlement: Ok →
 * DELIVERED; failure proven before the body reached the socket → FAILED_BEFORE_TRANSMISSION
 * (rollback by token); anything else — including Timeout(afterTransmission = true), HTTP errors
 * and bridge refusals — → AMBIGUOUS_AFTER_TRANSMISSION (the reservation stays committed). A
 * failure never rolls back a slot a newer token already owns. Only a REST 401/403 is reported
 * as unauthorized. No signaling path exists here.
 */
class DefaultMutationCoordinator(
    private val env: SessionEnvironment,
    private val ledger: RiseLedger = DefaultRiseLedger(env.bridgeId),
    private val safety: FlashSafety = DefaultFlashSafety,
    private val register: EffectSafetyRegister = DefaultEffectSafetyRegister,
    val authority: PendingAuthority = PendingAuthority(),
    private val pacingMillis: Long = DEFAULT_PACING_MILLIS,
    private val authorityMillis: Long = DEFAULT_AUTHORITY_MILLIS,
    private val transitionMillis: Long = DEFAULT_TRANSITION_MILLIS,
    private val postMutationRefreshMillis: Long = DEFAULT_AUTHORITY_MILLIS,
) : MutationCoordinator, SessionAttachment {

    /** One planned outbound write. [frame] is what the lamp would show once applied. */
    private class Write(
        val token: MutationToken,
        val target: ResourceKey,
        val field: FieldGroup,
        val body: ClipWriteBody,
        val frame: LuminanceFrame,
        val prior: LuminanceFrame?,
    )

    private sealed interface Plan {
        data class Writes(val writes: List<Write>) : Plan
        data class Refuse(val reason: RefusalReason) : Plan
    }

    private val queue = LinkedHashMap<Pair<ResourceKey, FieldGroup>, Write>()
    private val retryAt = HashMap<Pair<ResourceKey, FieldGroup>, Long>()
    private val queueLock = Mutex()
    private val wake = Channel<Unit>(Channel.CONFLATED)
    private var sender: Job? = null
    private var refreshJob: Job? = null
    private var nextToken = 1L
    private var lastSendAt: Long? = null

    @Volatile
    private var closed = false

    /** Diagnostics for tests/UI: how many PUTs left this coordinator. */
    @Volatile
    var sentCount: Int = 0
        private set

    private fun now() = env.clock.nowMillis()

    override suspend fun submit(mutation: LiveMutation): MutationOutcome {
        if (closed) return MutationOutcome.Refused(RefusalReason.SESSION_CLOSED)
        when (env.connection.value) {
            ConnectionState.Revoked -> return MutationOutcome.Refused(RefusalReason.REVOKED)
            ConnectionState.Offline, is ConnectionState.Error -> return MutationOutcome.Refused(RefusalReason.OFFLINE)
            ConnectionState.Connecting, ConnectionState.Connected, is ConnectionState.Stale -> Unit
        }
        if (mutation.target.bridgeId != env.bridgeId) return MutationOutcome.Refused(RefusalReason.TARGET_UNKNOWN)
        val token = MutationToken(nextToken++)
        val snapshot = env.store.value
        val writes = when (val plan = plan(mutation, snapshot, token)) {
            is Plan.Refuse -> return MutationOutcome.Refused(plan.reason)
            is Plan.Writes -> plan.writes
        }
        if (writes.isEmpty()) return MutationOutcome.Refused(RefusalReason.CAPABILITY_NOT_KNOWN)
        applyOverlay(mutation, writes, token)
        queueLock.withLock {
            for (w in writes) {
                queue.remove(w.target to w.field)
                queue[w.target to w.field] = w
                retryAt.remove(w.target to w.field)
            }
        }
        ensureSender()
        wake.trySend(Unit)
        return MutationOutcome.Accepted(token)
    }

    // ── planning ──

    private fun plan(m: LiveMutation, s: BridgeSnapshot, token: MutationToken): Plan {
        val key = m.target
        val light = s.lights[key]
        val group = s.rooms[key] ?: s.zones[key]
        val grouped = s.groupedLights[key]
        val scene = s.scenes[key]
        if (light == null && group == null && grouped == null && scene == null) return Plan.Refuse(RefusalReason.TARGET_UNKNOWN)

        fun lightWrite(l: LightState, field: FieldGroup, body: ClipWriteBody, after: LightState): Write =
            Write(token, l.key, field, body, frameOf(after), frameOf(l))

        fun members(): Map<ResourceKey, LightState> = group!!.children.mapNotNull { s.lights[it] }.associateBy { it.key }
        fun capsOf(map: Map<ResourceKey, LightState>): Map<ResourceKey, LightCapabilities> = map.mapValues { it.value.capabilities }

        fun groupedTarget(): GroupedLightState? = grouped ?: group?.groupedLight?.let { s.groupedLights[it] }

        return when (m) {
            is LiveMutation.SetPower -> when {
                light != null -> Plan.Writes(listOf(lightWrite(light, m.field, ClipBodies.power(m.on), light.copy(isOn = m.on))))
                else -> {
                    val g = groupedTarget() ?: return Plan.Refuse(RefusalReason.TARGET_UNKNOWN)
                    Plan.Writes(listOf(Write(token, g.key, m.field, ClipBodies.power(m.on), groupedFrame(g.copy(isOn = m.on)), groupedFrame(g))))
                }
            }
            is LiveMutation.SetBrightness -> when {
                light != null -> Plan.Writes(listOf(lightWrite(light, m.field, ClipBodies.brightness(m.percent), light.copy(brightness = m.percent.toDouble()))))
                else -> {
                    val g = groupedTarget() ?: return Plan.Refuse(RefusalReason.TARGET_UNKNOWN)
                    val after = g.copy(isOn = true, brightness = m.percent.toDouble())
                    Plan.Writes(listOf(Write(token, g.key, m.field, ClipBodies.powerAndBrightness(true, m.percent), groupedFrame(after), groupedFrame(g))))
                }
            }
            is LiveMutation.SetColor -> {
                val targets = if (light != null) listOf(light) else if (group != null) members().values.toList() else return Plan.Refuse(RefusalReason.TARGET_UNKNOWN)
                val capable = targets.filter { it.capabilities.color.isInteractive }
                if (capable.isEmpty()) return Plan.Refuse(RefusalReason.CAPABILITY_NOT_KNOWN)
                Plan.Writes(capable.map { l ->
                    lightWrite(l, m.field, ClipBodies.combine(ClipBodies.color(m.xy), ClipBodies.transition(transitionMillis)), l.copy(color = m.xy, mirekValid = false))
                })
            }
            is LiveMutation.SetColorTemperature -> {
                val targets = if (light != null) listOf(light) else if (group != null) members().values.toList() else return Plan.Refuse(RefusalReason.TARGET_UNKNOWN)
                val capable = targets.filter { it.capabilities.colorTemperature.isInteractive }
                if (capable.isEmpty()) return Plan.Refuse(RefusalReason.CAPABILITY_NOT_KNOWN)
                Plan.Writes(capable.map { l ->
                    val range = l.capabilities.colorTemperature.value!!
                    val clamped = range.clamp(m.mirek)
                    lightWrite(l, m.field, ClipBodies.combine(ClipBodies.colorTemperature(clamped, range), ClipBodies.transition(transitionMillis)), l.copy(mirek = clamped, mirekValid = true))
                })
            }
            is LiveMutation.SelectEffect -> {
                if (register.isDenied(m.effect)) return Plan.Refuse(RefusalReason.EFFECT_DENIED_BY_SAFETY_REGISTER)
                val targets: List<LightState> = when {
                    light != null -> if (CapabilityResolver.supportsEffect(light.capabilities, m.effect)) listOf(light) else return Plan.Refuse(RefusalReason.CAPABILITY_NOT_KNOWN)
                    group != null -> {
                        val ms = members()
                        when (val routing = CapabilityResolver.routeEffect(m.effect, capsOf(ms))) {
                            is EffectRouting.Run -> routing.targets.mapNotNull { ms[it] }
                            else -> return Plan.Refuse(RefusalReason.CAPABILITY_NOT_KNOWN) // Unsupported or RunUnverified: never a send
                        }
                    }
                    else -> return Plan.Refuse(RefusalReason.TARGET_UNKNOWN)
                }
                Plan.Writes(targets.map { l ->
                    val body = if (l.capabilities.effectsV2.isInteractive) {
                        val ctRange = l.capabilities.colorTemperature.value
                        ClipBodies.effectV2(
                            effect = m.effect,
                            speed = m.parameters.speed,
                            color = m.parameters.color?.takeIf { l.capabilities.color.isInteractive },
                            mirek = m.parameters.mirek?.takeIf { ctRange != null },
                            mirekRange = ctRange,
                        )
                    } else {
                        ClipBodies.effectV1(m.effect)
                    }
                    lightWrite(l, m.field, body, l.copy(activeEffect = m.effect))
                })
            }
            is LiveMutation.StopEffect -> {
                val targets = if (light != null) listOf(light) else if (group != null) members().values.toList() else return Plan.Refuse(RefusalReason.TARGET_UNKNOWN)
                val capable = targets.filter { it.capabilities.effectValues.isInteractive }
                if (capable.isEmpty()) return Plan.Refuse(RefusalReason.CAPABILITY_NOT_KNOWN)
                Plan.Writes(capable.map { l -> lightWrite(l, m.field, ClipBodies.stopEffect(viaV2 = l.capabilities.effectsV2.isInteractive), l.copy(activeEffect = null)) })
            }
            is LiveMutation.StartTimedEffect -> {
                val targets: List<LightState> = when {
                    light != null -> if (CapabilityResolver.supportsTimedEffect(light.capabilities, m.effect.wireName)) listOf(light) else return Plan.Refuse(RefusalReason.CAPABILITY_NOT_KNOWN)
                    group != null -> {
                        val ms = members()
                        if (!CapabilityResolver.offersTimedEffectOnGroup(m.effect.wireName, capsOf(ms))) return Plan.Refuse(RefusalReason.CAPABILITY_NOT_KNOWN)
                        ms.values.toList()
                    }
                    else -> return Plan.Refuse(RefusalReason.TARGET_UNKNOWN)
                }
                // One PUT per lamp, no app frames: the bridge owns the slow ramp. The frame handed
                // to the ledger is the lamp's current level (a long transition is not an onset).
                Plan.Writes(targets.map { l ->
                    Write(token, l.key, m.field, ClipBodies.timedEffect(m.effect.wireName, m.durationMillis, clearFirmwareEffect = true), frameOf(l), frameOf(l))
                })
            }
            is LiveMutation.CancelTimedEffect -> {
                val targets = if (light != null) listOf(light) else if (group != null) members().values.toList() else return Plan.Refuse(RefusalReason.TARGET_UNKNOWN)
                val capable = targets.filter { it.capabilities.timedEffects.isInteractive }
                if (capable.isEmpty()) return Plan.Refuse(RefusalReason.CAPABILITY_NOT_KNOWN)
                Plan.Writes(capable.map { l -> lightWrite(l, m.field, ClipBodies.cancelTimedEffect(), l.copy(activeTimedEffect = null)) })
            }
            is LiveMutation.SetGradient -> {
                // PER_LIGHT_ONLY: never offered on a group.
                val l = light ?: return Plan.Refuse(if (group != null) RefusalReason.CAPABILITY_NOT_KNOWN else RefusalReason.TARGET_UNKNOWN)
                val cap = l.capabilities.gradient.value?.takeIf { CapabilityResolver.supportsGradient(l.capabilities) }
                    ?: return Plan.Refuse(RefusalReason.CAPABILITY_NOT_KNOWN)
                val mode = m.mode?.takeIf { it in cap.modes }
                val body = ClipBodies.gradient(m.points, pointsCapable = cap.pointsCapable, mode = mode, transitionMillis = transitionMillis)
                val kept = m.points.take(minOf(cap.pointsCapable, ClipBodies.MAX_GRADIENT_POINTS))
                Plan.Writes(listOf(lightWrite(l, m.field, body, l.copy(gradientPoints = kept, color = kept.firstOrNull() ?: l.color))))
            }
            is LiveMutation.RecallScene -> {
                val sc = scene ?: return Plan.Refuse(RefusalReason.TARGET_UNKNOWN)
                // A recall can realize anything up to full white: judged as the worst-case rise.
                Plan.Writes(listOf(Write(token, sc.key, m.field, ClipBodies.sceneRecall(), LuminanceFrame(1.0, isSaturatedRed = false), null)))
            }
        }
    }

    private fun frameOf(l: LightState): LuminanceFrame = safety.frameFor(l.brightness, l.isOn, l.color)

    /** Grouped lights carry no chromaticity in the snapshot: white (max luminance factor) is the conservative frame. */
    private fun groupedFrame(g: GroupedLightState): LuminanceFrame = safety.frameFor(g.brightness, g.isOn, null)

    // ── optimistic overlay + authority ──

    private fun applyOverlay(m: LiveMutation, writes: List<Write>, token: MutationToken) {
        val deadline = now() + authorityMillis
        val before = env.store.value
        for (w in writes) {
            val restore = restoreFor(w.target, w.field, before)
            authority.claim(w.target, w.field, token, deadline, restore)
        }
        env.store.update { s -> writes.fold(s) { acc, w -> overlay(acc, m, w) } }
    }

    /** A closure restoring exactly one (key, field) to its pre-overlay value. */
    private fun restoreFor(key: ResourceKey, field: FieldGroup, before: BridgeSnapshot): (BridgeSnapshot) -> BridgeSnapshot = { s ->
        when (key.type) {
            ResourceType.LIGHT -> {
                val prior = before.lights[key]; val cur = s.lights[key]
                if (prior == null || cur == null) s else s.copy(lights = s.lights + (key to copyField(cur, prior, field)))
            }
            ResourceType.GROUPED_LIGHT -> {
                val prior = before.groupedLights[key]; val cur = s.groupedLights[key]
                if (prior == null || cur == null) s else s.copy(groupedLights = s.groupedLights + (key to when (field) {
                    FieldGroup.POWER -> cur.copy(isOn = prior.isOn)
                    FieldGroup.DIMMING -> cur.copy(isOn = prior.isOn, brightness = prior.brightness)
                    else -> cur
                }))
            }
            ResourceType.SCENE -> {
                val group = before.scenes[key]?.group
                s.copy(scenes = s.scenes.mapValues { (k, v) -> if (v.group == group) v.copy(isActive = before.scenes[k]?.isActive ?: v.isActive) else v })
            }
            else -> s
        }
    }

    private fun copyField(cur: LightState, prior: LightState, field: FieldGroup): LightState = when (field) {
        FieldGroup.POWER -> cur.copy(isOn = prior.isOn)
        FieldGroup.DIMMING -> cur.copy(brightness = prior.brightness)
        FieldGroup.COLOR -> cur.copy(color = prior.color, mirekValid = prior.mirekValid)
        FieldGroup.COLOR_TEMPERATURE -> cur.copy(mirek = prior.mirek, mirekValid = prior.mirekValid)
        FieldGroup.EFFECT -> cur.copy(activeEffect = prior.activeEffect)
        FieldGroup.TIMED_EFFECT -> cur.copy(activeTimedEffect = prior.activeTimedEffect)
        FieldGroup.GRADIENT -> cur.copy(gradientPoints = prior.gradientPoints, color = prior.color)
        FieldGroup.SCENE -> cur
    }

    private fun overlay(s: BridgeSnapshot, m: LiveMutation, w: Write): BridgeSnapshot = when (w.target.type) {
        ResourceType.LIGHT -> {
            val l = s.lights[w.target] ?: return s
            val after = when (m) {
                is LiveMutation.SetPower -> l.copy(isOn = m.on)
                is LiveMutation.SetBrightness -> l.copy(brightness = m.percent.toDouble())
                is LiveMutation.SetColor -> l.copy(color = m.xy, mirekValid = false)
                is LiveMutation.SetColorTemperature -> l.copy(mirek = l.capabilities.colorTemperature.value?.clamp(m.mirek) ?: m.mirek, mirekValid = true)
                is LiveMutation.SelectEffect -> l.copy(activeEffect = m.effect)
                is LiveMutation.StopEffect -> l.copy(activeEffect = null)
                is LiveMutation.StartTimedEffect -> l.copy(activeTimedEffect = m.effect.wireName, activeEffect = null)
                is LiveMutation.CancelTimedEffect -> l.copy(activeTimedEffect = null)
                is LiveMutation.SetGradient -> {
                    val cap = l.capabilities.gradient.value
                    val kept = m.points.take(minOf(cap?.pointsCapable ?: ClipBodies.MAX_GRADIENT_POINTS, ClipBodies.MAX_GRADIENT_POINTS))
                    l.copy(gradientPoints = kept, color = kept.firstOrNull() ?: l.color)
                }
                is LiveMutation.RecallScene -> l
            }
            s.copy(lights = s.lights + (w.target to after))
        }
        ResourceType.GROUPED_LIGHT -> {
            val g = s.groupedLights[w.target] ?: return s
            val after = when (m) {
                is LiveMutation.SetPower -> g.copy(isOn = m.on)
                is LiveMutation.SetBrightness -> g.copy(isOn = true, brightness = m.percent.toDouble())
                else -> g
            }
            s.copy(groupedLights = s.groupedLights + (w.target to after))
        }
        ResourceType.SCENE -> {
            val sc = s.scenes[w.target] ?: return s
            s.copy(scenes = s.scenes.mapValues { (k, v) -> if (v.group == sc.group) v.copy(isActive = k == w.target) else v })
        }
        else -> s
    }

    // ── sender ──

    private fun ensureSender() {
        if (sender?.isActive == true) return
        sender = env.scope.launch { drain() }
    }

    private suspend fun drain() {
        while (!closed) {
            val next = queueLock.withLock { pickNext() }
            if (next == null) {
                val soonest = queueLock.withLock { retryAt.values.minOrNull() }
                if (soonest == null) {
                    wake.receive()
                } else {
                    val wait = soonest - now()
                    if (wait > 0) delay(wait)
                    queueLock.withLock { retryAt.entries.removeIf { it.value <= now() } }
                }
                continue
            }
            pace()
            val verdict = ledger.admit(next.target, next.frame, now())
            when (verdict) {
                is RiseVerdict.Hold -> queueLock.withLock {
                    // Still the latest for its slot? Then park it until the ledger's retry time.
                    if (queue[next.target to next.field] === next) retryAt[next.target to next.field] = verdict.retryAtMillis
                }
                is RiseVerdict.Emit -> {
                    queueLock.withLock { if (queue[next.target to next.field] === next) queue.remove(next.target to next.field) }
                    send(next, verdict)
                }
            }
        }
    }

    /** FIFO among slots that are not parked. */
    private fun pickNext(): Write? {
        val t = now()
        for ((slot, write) in queue) {
            val until = retryAt[slot]
            if (until == null || until <= t) {
                retryAt.remove(slot)
                return write
            }
        }
        return null
    }

    private suspend fun pace() {
        val last = lastSendAt ?: return
        val wait = pacingMillis - (now() - last)
        if (wait > 0) delay(wait)
    }

    private suspend fun send(w: Write, verdict: RiseVerdict.Emit) {
        lastSendAt = now()
        sentCount++
        val result = env.transport.putResource(w.target.type, w.target.id, w.body)
        val at = now()
        when (result) {
            is ClipResult.Ok -> {
                verdict.reservation?.let { ledger.settle(it, DeliveryOutcome.DELIVERED, at) }
                    ?: (ledger as? DefaultRiseLedger)?.noteDelivered(w.target, w.frame, at)
                scheduleRefresh()
            }
            is ClipResult.Err -> {
                val outcome = when (val e = result.error) {
                    is ClipError.Timeout -> if (e.afterTransmission) DeliveryOutcome.AMBIGUOUS_AFTER_TRANSMISSION else DeliveryOutcome.FAILED_BEFORE_TRANSMISSION
                    ClipError.Transport, ClipError.MissingCredentials, ClipError.TlsIdentity -> DeliveryOutcome.FAILED_BEFORE_TRANSMISSION
                    else -> DeliveryOutcome.AMBIGUOUS_AFTER_TRANSMISSION
                }
                verdict.reservation?.let { ledger.settle(it, outcome, at) }
                (result.error as? ClipError.Unauthorized)?.let { env.reportUnauthorized(it.status) }
                rollback(w)
            }
        }
    }

    /** Rollback by token: only if this write's token still owns the slot's authority. */
    private fun rollback(w: Write) {
        val claim = authority.takeForRollback(w.target, w.field, w.token) ?: return
        env.store.update { claim.restore(it) }
    }

    private fun scheduleRefresh() {
        if (refreshJob?.isActive == true) return
        refreshJob = env.scope.launch {
            delay(postMutationRefreshMillis)
            env.requestRefresh(RefreshReason.POST_MUTATION)
        }
    }

    override fun close() {
        closed = true
        sender?.cancel()
        refreshJob?.cancel()
        queue.clear()
        retryAt.clear()
        authority.clear()
    }

    companion object {
        const val DEFAULT_PACING_MILLIS: Long = 100L
        const val DEFAULT_AUTHORITY_MILLIS: Long = 1_500L
        const val DEFAULT_TRANSITION_MILLIS: Long = 400L

        /** Factory for LiveHome: one coordinator + one ledger per session. */
        fun factory(register: EffectSafetyRegister = DefaultEffectSafetyRegister): (SessionEnvironment) -> MutationCoordinator =
            { env -> DefaultMutationCoordinator(env, register = register) }
    }
}
