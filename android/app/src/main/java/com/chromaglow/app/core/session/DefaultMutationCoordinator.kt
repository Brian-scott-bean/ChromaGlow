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
import com.chromaglow.app.core.session.safety.FlashSafetyConstants
import com.chromaglow.app.core.session.safety.LampRiseLedger
import com.chromaglow.app.core.session.safety.LedgerVerdict
import com.chromaglow.app.core.session.safety.LedgerWrite
import com.chromaglow.app.core.session.safety.LedgerWriteKind
import com.chromaglow.app.core.session.safety.LuminanceFrame
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
 * denied by the safety register / routing class not offered / unsafe timed duration) → plan the
 * exact writes → apply the optimistic overlay and claim field-aware pending authority per
 * (ResourceKey, FieldGroup) → park each write in its latest-wins slot → Accepted(token).
 *
 * The sender drains slots FIFO. Pacing (E-09): per-light writes ≥ [pacingMillis] apart on this
 * bridge; grouped_light and scene writes additionally ≥ [groupPacingMillis] apart (Hue guidance
 * is ≈ 1 grouped command/s; latest-wins absorbs the slider). Before every send the
 * [LampRiseLedger] judges the write against the PHYSICAL lamps it reaches with the frame the
 * lamps would realize — never under-estimated: a lamp in CT mode is judged as white regardless
 * of its stale xy (E-04), a strip by its brightest point (E-10), and an animation initiation on
 * a dark lamp as full output (E-07). Hold keeps the write in its slot; Emit sends exactly one PUT.
 *
 * Settlement (E-03/E-05/B-02): Ok → DELIVERED + Applied. Failure proven before the body reached
 * the socket → FAILED_BEFORE_TRANSMISSION, rollback by token. Bridge said no (429, HTTP 4xx,
 * errors-only body, 401/403) → NOT_APPLIED, rollback by token. Anything the bridge MAY have
 * applied (post-transmission reset/timeout, 5xx, undecodable answer) → AMBIGUOUS: the stamp is
 * kept, the overlay is NOT rolled back, authority is released and a refresh reconciles. Only a
 * REST 401/403 is reported as unauthorized. No signaling path exists here.
 */
class DefaultMutationCoordinator(
    private val env: SessionEnvironment,
    private val ledger: LampRiseLedger = DefaultRiseLedger(env.bridgeId),
    private val safety: FlashSafety = DefaultFlashSafety,
    private val register: EffectSafetyRegister = DefaultEffectSafetyRegister,
    val authority: PendingAuthority = env.authority,
    private val pacingMillis: Long = DEFAULT_PACING_MILLIS,
    private val groupPacingMillis: Long = DEFAULT_GROUP_PACING_MILLIS,
    private val authorityMillis: Long = DEFAULT_AUTHORITY_MILLIS,
    private val transitionMillis: Long = DEFAULT_TRANSITION_MILLIS,
    private val postMutationRefreshMillis: Long = DEFAULT_AUTHORITY_MILLIS,
) : MutationCoordinator, SessionAttachment {

    /** One planned outbound write with the lamps it reaches and the frame they would realize. */
    private class Write(
        val token: MutationToken,
        val mutation: LiveMutation,
        val target: ResourceKey,
        val field: FieldGroup,
        val body: ClipWriteBody,
        val ledgerWrite: LedgerWrite,
    ) {
        val isGroupWrite: Boolean get() = target.type == ResourceType.GROUPED_LIGHT || target.type == ResourceType.SCENE
    }

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
    private var lastGroupSendAt: Long? = null

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
            Write(token, m, l.key, field, body, LedgerWrite(setOf(l.key), frameOf(after), LedgerWriteKind.LAMP))

        fun members(): Map<ResourceKey, LightState> = group!!.children.mapNotNull { s.lights[it] }.associateBy { it.key }
        fun capsOf(map: Map<ResourceKey, LightState>): Map<ResourceKey, LightCapabilities> = map.mapValues { it.value.capabilities }

        /** The grouped_light a group/grouped target resolves to, and the physical lamps it reaches. */
        fun groupedTarget(): Pair<GroupedLightState, Set<ResourceKey>>? {
            val g = grouped ?: group?.groupedLight?.let { s.groupedLights[it] } ?: return null
            val owner = group ?: (s.rooms.values + s.zones.values).firstOrNull { it.groupedLight == g.key }
            val lamps = owner?.children?.toSet().orEmpty().ifEmpty { setOf(g.key) }
            return g to lamps
        }

        fun groupedWrite(g: GroupedLightState, lamps: Set<ResourceKey>, field: FieldGroup, body: ClipWriteBody, after: GroupedLightState): Write =
            Write(token, m, g.key, field, body, LedgerWrite(lamps, groupedFrame(after), LedgerWriteKind.GROUPED))

        /** Effect / timed initiation on a dark or near-dark lamp is judged as a worst-case full rise (E-07). */
        fun initiation(l: LightState, field: FieldGroup, body: ClipWriteBody, after: LightState): Write {
            val current = frameOf(l)
            val dark = !l.isOn || current.relativeLuminance < FlashSafetyConstants.ONSET_RISE_THRESHOLD
            val ledgerWrite = if (dark) LedgerWrite(setOf(l.key), WORST_CASE, LedgerWriteKind.INITIATION) else LedgerWrite(setOf(l.key), frameOf(after), LedgerWriteKind.INITIATION)
            return Write(token, m, l.key, field, body, ledgerWrite)
        }

        return when (m) {
            is LiveMutation.SetPower -> when {
                light != null -> Plan.Writes(listOf(lightWrite(light, m.field, ClipBodies.power(m.on), light.copy(isOn = m.on))))
                else -> {
                    val (g, lamps) = groupedTarget() ?: return Plan.Refuse(RefusalReason.TARGET_UNKNOWN)
                    Plan.Writes(listOf(groupedWrite(g, lamps, m.field, ClipBodies.power(m.on), g.copy(isOn = m.on))))
                }
            }
            is LiveMutation.SetBrightness -> when {
                light != null -> Plan.Writes(listOf(lightWrite(light, m.field, ClipBodies.brightness(m.percent), light.copy(brightness = m.percent.toDouble()))))
                else -> {
                    val (g, lamps) = groupedTarget() ?: return Plan.Refuse(RefusalReason.TARGET_UNKNOWN)
                    Plan.Writes(listOf(groupedWrite(g, lamps, m.field, ClipBodies.powerAndBrightness(true, m.percent), g.copy(isOn = true, brightness = m.percent.toDouble()))))
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
                    initiation(l, m.field, body, l.copy(activeEffect = m.effect))
                })
            }
            is LiveMutation.StopEffect -> {
                val targets = if (light != null) listOf(light) else if (group != null) members().values.toList() else return Plan.Refuse(RefusalReason.TARGET_UNKNOWN)
                val capable = targets.filter { it.capabilities.effectValues.isInteractive }
                if (capable.isEmpty()) return Plan.Refuse(RefusalReason.CAPABILITY_NOT_KNOWN)
                Plan.Writes(capable.map { l -> lightWrite(l, m.field, ClipBodies.stopEffect(viaV2 = l.capabilities.effectsV2.isInteractive), l.copy(activeEffect = null)) })
            }
            is LiveMutation.StartTimedEffect -> {
                if (m.durationMillis < LiveMutation.MIN_TIMED_EFFECT_MILLIS) return Plan.Refuse(RefusalReason.UNSAFE_DURATION)
                val targets: List<LightState> = when {
                    light != null -> if (CapabilityResolver.supportsTimedEffect(light.capabilities, m.effect.wireName)) listOf(light) else return Plan.Refuse(RefusalReason.CAPABILITY_NOT_KNOWN)
                    group != null -> {
                        val ms = members()
                        if (!CapabilityResolver.offersTimedEffectOnGroup(m.effect.wireName, capsOf(ms))) return Plan.Refuse(RefusalReason.CAPABILITY_NOT_KNOWN)
                        ms.values.toList()
                    }
                    else -> return Plan.Refuse(RefusalReason.TARGET_UNKNOWN)
                }
                // One PUT per lamp, no app frames: the bridge owns the slow ramp.
                Plan.Writes(targets.map { l ->
                    initiation(l, m.field, ClipBodies.timedEffect(m.effect.wireName, m.durationMillis, clearFirmwareEffect = true), l.copy(activeTimedEffect = m.effect.wireName, activeEffect = null))
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
                Plan.Writes(listOf(lightWrite(l, m.field, body, l.copy(gradientPoints = kept, color = kept.firstOrNull() ?: l.color, mirekValid = false))))
            }
            is LiveMutation.RecallScene -> {
                val sc = scene ?: return Plan.Refuse(RefusalReason.TARGET_UNKNOWN)
                val lamps = (s.rooms[sc.group] ?: s.zones[sc.group])?.children?.toSet().orEmpty()
                // A recall can realize anything up to full white on every member: always a candidate.
                Plan.Writes(listOf(Write(token, m, sc.key, m.field, ClipBodies.sceneRecall(), LedgerWrite(lamps, WORST_CASE, LedgerWriteKind.SCENE))))
            }
        }
    }

    /**
     * The frame a lamp would realize. Never under-estimated: in CT mode (`mirekValid == true`) or
     * without a colour the lamp is judged as D65 white (E-04); a strip is judged by its
     * brightest point (E-10).
     */
    private fun frameOf(l: LightState): LuminanceFrame {
        if (l.mirekValid == true) return safety.frameFor(l.brightness, l.isOn, null)
        if (l.gradientPoints.isNotEmpty()) {
            return l.gradientPoints.map { safety.frameFor(l.brightness, l.isOn, it) }.maxBy { it.relativeLuminance }
        }
        return safety.frameFor(l.brightness, l.isOn, l.color)
    }

    /** Grouped lights carry no chromaticity in the snapshot: white (max luminance factor) is the conservative frame. */
    private fun groupedFrame(g: GroupedLightState): LuminanceFrame = safety.frameFor(g.brightness, g.isOn, null)

    // ── optimistic overlay + authority ──

    private fun applyOverlay(m: LiveMutation, writes: List<Write>, token: MutationToken) {
        val deadline = now() + authorityMillis
        val before = env.store.value
        for (w in writes) authority.claim(w.target, w.field, token, deadline, prior = before)
        env.store.update { s -> writes.fold(s) { acc, w -> overlay(acc, m, w) } }
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
                    l.copy(gradientPoints = kept, color = kept.firstOrNull() ?: l.color, mirekValid = false)
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
                // Nothing is ready: sleep until the earliest slot (parked or pacing) could go, or a wake.
                val soonest = queueLock.withLock { queue.entries.minOfOrNull { (slot, w) -> maxOf(retryAt[slot] ?: 0L, readyAt(w)) } }
                if (soonest == null) {
                    wake.receive()
                } else {
                    val wait = soonest - now()
                    if (wait > 0) delay(wait)
                    queueLock.withLock { retryAt.entries.removeIf { it.value <= now() } }
                }
                continue
            }
            when (val verdict = ledger.admit(next.ledgerWrite, now())) {
                is LedgerVerdict.Hold -> queueLock.withLock {
                    // Still the latest for its slot? Then park it until the ledger's retry time.
                    if (queue[next.target to next.field] === next) retryAt[next.target to next.field] = verdict.retryAtMillis
                }
                is LedgerVerdict.Emit -> {
                    queueLock.withLock { if (queue[next.target to next.field] === next) queue.remove(next.target to next.field) }
                    send(next, verdict)
                }
            }
        }
    }

    /** FIFO among slots that are neither parked by the ledger nor waiting for their pace; a grouped slot waiting on its 1 s pace never blocks the lights behind it (E-09). */
    private fun pickNext(): Write? {
        val t = now()
        for ((slot, write) in queue) {
            val until = retryAt[slot]
            if (until != null && until > t) continue
            if (readyAt(write) > t) continue
            retryAt.remove(slot)
            return write
        }
        return null
    }

    /** Per-light ≥ pacingMillis since ANY send; grouped/scene additionally ≥ groupPacingMillis since the last grouped/scene send (E-09). */
    private fun readyAt(w: Write): Long {
        var ready = lastSendAt?.let { it + pacingMillis } ?: 0L
        if (w.isGroupWrite) ready = maxOf(ready, lastGroupSendAt?.let { it + groupPacingMillis } ?: 0L)
        return ready
    }

    private suspend fun send(w: Write, verdict: LedgerVerdict.Emit) {
        val sentAt = now()
        lastSendAt = sentAt
        if (w.isGroupWrite) lastGroupSendAt = sentAt
        // The fence must cover the wire window, not only the submit moment (B-09).
        authority.extend(w.target, w.field, w.token, sentAt + authorityMillis)
        sentCount++
        val result = env.transport.putResource(w.target.type, w.target.id, w.body)
        val at = now()
        when (result) {
            is ClipResult.Ok -> {
                ledger.settle(verdict.ticket, DeliveryOutcome.DELIVERED, at)
                emit(MutationEvent.Applied(w.mutation))
                scheduleRefresh()
            }
            is ClipResult.Err -> {
                val e = result.error
                val outcome = when (e) {
                    is ClipError.Timeout -> if (e.afterTransmission) DeliveryOutcome.AMBIGUOUS_AFTER_TRANSMISSION else DeliveryOutcome.FAILED_BEFORE_TRANSMISSION
                    is ClipError.Transport -> if (e.afterTransmission) DeliveryOutcome.AMBIGUOUS_AFTER_TRANSMISSION else DeliveryOutcome.FAILED_BEFORE_TRANSMISSION
                    ClipError.MissingCredentials, ClipError.TlsIdentity -> DeliveryOutcome.FAILED_BEFORE_TRANSMISSION
                    is ClipError.Unauthorized, ClipError.RateLimited, is ClipError.BridgeRejected -> DeliveryOutcome.NOT_APPLIED
                    is ClipError.Http -> if (e.status in 400..499) DeliveryOutcome.NOT_APPLIED else DeliveryOutcome.AMBIGUOUS_AFTER_TRANSMISSION
                    is ClipError.Decode -> DeliveryOutcome.AMBIGUOUS_AFTER_TRANSMISSION
                }
                ledger.settle(verdict.ticket, outcome, at)
                (e as? ClipError.Unauthorized)?.let { env.reportUnauthorized(it.status) }
                val rolledBack = if (outcome == DeliveryOutcome.AMBIGUOUS_AFTER_TRANSMISSION) {
                    // The lamp may hold the new value: keep the overlay, drop the fence, let truth reconcile.
                    authority.release(w.target, w.field, w.token)
                    scheduleRefresh()
                    false
                } else {
                    rollback(w)
                }
                emit(MutationEvent.Failed(w.mutation, failureOf(e), rolledBack))
            }
        }
        wake.trySend(Unit)
    }

    private fun failureOf(e: ClipError): MutationFailure = when (e) {
        is ClipError.BridgeRejected -> MutationFailure.REJECTED_BY_BRIDGE
        is ClipError.Unauthorized -> MutationFailure.UNAUTHORIZED
        ClipError.RateLimited -> MutationFailure.RATE_LIMITED
        is ClipError.Http -> MutationFailure.HTTP_ERROR
        is ClipError.Timeout -> if (e.afterTransmission) MutationFailure.TIMEOUT_AMBIGUOUS else MutationFailure.TRANSPORT
        is ClipError.Transport -> if (e.afterTransmission) MutationFailure.TIMEOUT_AMBIGUOUS else MutationFailure.TRANSPORT
        ClipError.MissingCredentials, ClipError.TlsIdentity -> MutationFailure.TRANSPORT
        is ClipError.Decode -> MutationFailure.DECODE
    }

    private fun emit(event: MutationEvent) {
        env.mutationEvents.tryEmit(event)
    }

    /** Rollback by token: only if this write's token still owns the slot's authority. Returns whether it did. */
    private fun rollback(w: Write): Boolean {
        val claim = authority.takeForRollback(w.target, w.field, w.token) ?: return false
        env.store.update { authority.rollback(it, w.target, w.field, claim) }
        return true
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
        /** Per-light REST pace on one bridge (~10 commands/s budget). */
        const val DEFAULT_PACING_MILLIS: Long = 100L

        /** grouped_light / scene pace on one bridge: Hue guidance is ≈ 1 grouped command per second (E-09). */
        const val DEFAULT_GROUP_PACING_MILLIS: Long = 1_000L
        const val DEFAULT_AUTHORITY_MILLIS: Long = 1_500L
        const val DEFAULT_TRANSITION_MILLIS: Long = 400L

        /** Full white: the frame a write of unknown outcome is judged as. */
        private val WORST_CASE = LuminanceFrame(1.0, isSaturatedRed = false)

        /** Factory for LiveHome: one coordinator + one ledger per session. */
        fun factory(register: EffectSafetyRegister = DefaultEffectSafetyRegister): (SessionEnvironment) -> MutationCoordinator =
            { env -> DefaultMutationCoordinator(env, register = register) }
    }
}
