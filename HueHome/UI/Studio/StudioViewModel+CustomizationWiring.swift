//
//  StudioViewModel+CustomizationWiring.swift
//  HueHome
//
//  Unified Customization Engine — Slice 2 (Production Truth Wiring).
//
//  This file makes the Slice 1 foundation PRODUCTION-ACTIVE. Every Studio
//  parameter mutation now flows through here:
//
//    1. A gesture BEGINS → `beginParamEdit` captures the exact
//       `RunningLookIdentity` (bridge + group + kind + look + execution +
//       generation) and every routing fact the eventual sends will need —
//       the API client, the grouped light, the v2-capable light set. Nothing
//       is ever re-resolved from `selectedRoom` after this point.
//    2. Each tick → `updateParamEdit` commits through
//       `CustomizationValueScopes.commit(captured:…)`, which fences on the
//       captured identity. A drag that outlives the selection, a stop, a
//       reset, or a card replacement drops here instead of landing on the
//       wrong target.
//    3. A committed tick pushes the exact instance's resolved value set to
//       the running engine box (`updateStudioParams`, now room-checked),
//       updates the card's persisted next-start defaults, and schedules the
//       debounced bridge send — keyed PER TARGET, so two rooms' edits never
//       cancel each other, and re-fenced after the debounce sleep.
//
//  One-shot writes (toggles, segmented chips, the Beat panel) go through
//  `commitParam`/`commitColorParam`, which capture identity at call time —
//  exact for a tap, which cannot outlive a selection change.
//

import SwiftUI

// MARK: - Captured edit session

/// Everything a parameter gesture needs, captured when the finger lands.
///
/// Immutable by design: the whole point is that NOTHING here is re-read from
/// the live selection later. `identity` is the fence; the rest are the routing
/// facts the debounced send uses after its sleep.
struct StudioParamSession {
    let identity: RunningLookIdentity
    let control: CustomizationControlID
    /// The bridge client captured at gesture start — nil when the bridge has
    /// no resolvable client, in which case the debounced bridge send drops
    /// (the engine-box push and value scopes still land). Never re-resolved.
    let api: HueAPIClient?
    let room: RoomDisplayItem
    let groupedLightID: String?
    let v2CapableLightIDs: [String]
    /// Non-nil when the captured look is a bridge-native firmware effect —
    /// the live v2 re-parameterization path needs the effect name.
    let bridgeNativeEffectName: String?
}

/// Everything one debounce window accumulated for one exact target (R4D).
///
/// The routing facts come from the LATEST session in the window — they are
/// re-captured on every tick from the same running instance, so "latest" and
/// "first" are the same value; the fields are the union of what changed.
struct PendingStudioSend {
    /// The most recent gesture session for this target — its `identity` is the
    /// fence the debounced task re-checks, and its api/room/light facts are
    /// what the send routes on.
    var session: StudioParamSession
    /// Numeric params committed in this window, by param id.
    var numbers: [String: Double] = [:]
    /// Colour params committed in this window, by param id.
    var colors: [String: Color] = [:]
}

extension StudioViewModel {

    // ── Identity install / teardown helpers ─────────────────────

    /// Mint the exact identity for a look that just started on `room`, and
    /// register it with the value scopes (seeding scope 2 from the card's
    /// persisted defaults). Called from each `apply()` arm at the moment the
    /// `RunningEffect` row is installed.
    func installRunningIdentity(room: RoomDisplayItem,
                                card: StudioCard,
                                execution: CustomizationExecution) -> RunningLookIdentity {
        // BELT (R4B). Serialization is the braces — one lifecycle body at a
        // time, so two applies cannot interleave their installs. This is the
        // belt: a scope is keyed by card AND execution, so any install that did
        // not route through `stopEffect` first (a saved-look outcome, a handoff
        // replay, a card whose strategy changed under one id) would leave the
        // predecessor's scope registered and `isCurrent` — an orphan whose
        // debounced sends still pass the fence. A PLACE may hold exactly one
        // live scope; retiring the predecessors here makes that structural
        // rather than a property of the call order.
        for retired in valueScopes.stopRunning(atPlace: room.bridgeID,
                                               groupID: room.id, kind: room.kind) {
            retirePendingSends(for: retired)
        }
        let identity = RunningLookIdentity(
            bridgeID: room.bridgeID, groupID: room.id, kind: room.kind,
            cardID: card.id, execution: execution,
            generation: generationCounter.bump(.cardReplaced))
        valueScopes.startRunning(identity)
        bumpLiveValuesTick()
        return identity
    }

    /// Forget the scopes entry and cancel the pending send for the row at
    /// `key`, if one exists. For removal paths that bypass `stopEffect`
    /// (saved-look outcomes, handoff replays).
    func stopRunningScopes(forRowAt key: StudioSelectionKey) {
        guard let effect = runningEffects[key] else { return }
        retirePendingSends(for: effect.identity.targetKey)
        valueScopes.stopRunning(effect.identity)
        sessionMemory.clear(for: effect.identity.targetKey)
        bumpLiveValuesTick()
    }

    // ── Session manager: Apply Current Look (spec §14.6) ────────

    /// Remember the last ACTIVE target the user was looking at — the source
    /// for "Apply Current Look". Called by the selection-change wiring.
    func noteSelectionChanged() {
        if let room = selectedRoom, runningEffect(for: room) != nil {
            lastViewedActiveTarget = StudioSelectionKey(room: room)
        }
    }

    /// The look "Apply Current Look" would copy: the last active target the
    /// user viewed, or the only active target when there is exactly one.
    /// Nil when the SELECTED room is already active (nothing to offer), when
    /// nothing runs, or when the source would be a guess.
    var applyCurrentLookSource: RunningEffect? {
        if let room = selectedRoom, runningEffect(for: room) != nil { return nil }
        if let key = lastViewedActiveTarget,
           let effect = runningEffects[key], effect.recovered == nil { return effect }
        if runningEffects.count == 1,
           let only = runningEffects.values.first, only.recovered == nil { return only }
        return nil
    }

    /// The copy-once step: seed the source card's next-start defaults from
    /// its CURRENT exact live values, so the apply that follows starts the
    /// new instance from them. Returns the card to apply, or nil when there
    /// is no unambiguous source. Extracted so the copy-once semantics are
    /// directly testable on the production path.
    @discardableResult
    func seedApplyCurrentLook() -> StudioCard? {
        guard let source = applyCurrentLookSource else { return nil }
        let live = valueScopes.live(for: source.identity)
        valueScopes.setDefaults(live, forCard: source.cardID)
        persistDefaults(immediately: false)
        bumpLiveValuesTick()
        return source.card
    }

    /// Copy the source's CURRENT exact live settings ONCE, then start a new
    /// independently keyed running instance on `room` through the normal
    /// production path. Independence is automatic: `startRunning` registers
    /// the new instance under its own target key, so later edits on either
    /// side never link (spec §14.6/§14.7).
    func applyCurrentLook(to room: RoomDisplayItem) async {
        await serialized { [weak self] in await self?.applyCurrentLookCore(to: room) }
    }

    private func applyCurrentLookCore(to room: RoomDisplayItem) async {
        guard let card = seedApplyCurrentLook() else { return }
        await applyCore(card, roomOverride: room, preferEntertainmentOverride: nil)
    }

    /// Card lookup across every catalog the browser can apply.
    func lookCard(forID id: String) -> StudioCard? {
        (effectCards + liveModeCards + composerStudioCards + [starterCompositionCard()])
            .first { $0.id == id }
    }

    // ── Preview Live (spec §16.5) ───────────────────────────────

    /// Opt-in audition on the EXACT selected target: snapshot the previous
    /// running look and its exact live values, then start the candidate
    /// through the normal apply path.
    ///
    /// Serialized (R4B/R4C): the snapshot must describe the world the apply
    /// then mutates, and nothing else may take the room in between.
    func beginPreviewLive(card: StudioCard) async {
        await serialized { [weak self] in await self?.beginPreviewLiveCore(card: card) }
    }

    private func beginPreviewLiveCore(card: StudioCard) async {
        guard let room = selectedRoom else { return }

        // A SECOND audition chains onto the ORIGINAL snapshot. Re-snapshotting
        // here would capture the FIRST audition as "the previous look", so
        // "Put It Back" would restore the thing the user had already rejected
        // and the real previous look would be unrecoverable.
        let hadSnapshot = previewLive.isPreviewing
        if !hadSnapshot {
            let previous = runningEffect(for: room)
            _ = previewLive.begin(
                previous: previous?.identity,
                previousValues: previous.map { valueScopes.live(for: $0.identity) },
                previousWasStreaming: previous?.isEntertainment ?? false)
            previewLiveRoom = room
        }

        // The flag disables the button for the duration AND tells `stopEffect`
        // that the replacement teardown about to run belongs to this audition,
        // so it must not consume the snapshot the audition is chaining onto.
        setAuditionInFlight(true)
        await applyCore(card, roomOverride: room, preferEntertainmentOverride: nil)
        setAuditionInFlight(false)

        if let started = runningEffect(for: room), started.cardID == card.id {
            previewLive.previewStarted(started.identity)
            // Only NOW is there an audition to put back. Setting this before
            // the apply meant a refusal (handoff prompt, Reduce Motion, an
            // unsupported room) left the browser showing "Keep It / Put It
            // Back" for a look that never started.
            setPreviewingLive(true)
            return
        }

        // The apply refused and nothing changed. When this call took the
        // snapshot, the machine now holds one with no audition — consume it, so
        // a later cancel cannot fence against a stale identity.
        //
        // When an EARLIER audition owns the snapshot, it is still running and
        // still restorable: leave the machine, the room, and the flag exactly
        // as they were.
        if !hadSnapshot {
            _ = previewLive.cancelVerdict(live: nil)
            previewLiveRoom = nil
            setPreviewingLive(false)
        }
    }

    /// Cancel: restore the previous look EXACTLY — fenced on the audition's
    /// identity, so a target change, stop, replacement, or generation bump
    /// in between drops the restore instead of crossing targets.
    func cancelPreviewLive() async {
        await serialized { [weak self] in await self?.cancelPreviewLiveCore() }
    }

    private func cancelPreviewLiveCore() async {
        // The verdict is computed INSIDE the serialized body, against the row
        // as it is at this instant — not against a value read before queueing.
        let room = previewLiveRoom
        previewLiveRoom = nil
        setPreviewingLive(false)
        let live = room.flatMap { runningEffects[StudioSelectionKey(room: $0)]?.identity }
        let hadAudition = previewLive.previewIdentity != nil

        switch previewLive.cancelVerdict(live: live) {
        case .drop:
            // The world moved on — touch nothing. But SAY so: a "Put It Back"
            // that silently restores nothing is indistinguishable from a
            // broken button. (`stopEffect` already spoke when it was the one
            // that consumed the audition, which is why this is gated.)
            if hadAudition {
                studioNotice = StudioNotice(message: PreviewLiveCopy.restoreDropped)
                statusMessage = "⚠ \(PreviewLiveCopy.restoreDropped)"
            }
            return

        case .restore(let snapshot):
            guard let room else { return }
            guard let previous = snapshot.previous,
                  let values = snapshot.previousValues,
                  let card = lookCard(forID: previous.cardID) else {
                // The target was idle before the audition — cancel just stops
                // the preview and leaves the room as it was.
                await stopActiveTargetCore(StudioSelectionKey(room: room))
                return
            }
            // Reinstate the EXACT values by seeding the card's next-start
            // defaults from the snapshot (the copy-once idiom), then restart
            // through the normal path. Defaults tracking live values is the
            // established last-used behavior, so this is consistent, not a
            // corruption — PROVIDED the restart actually installs the card.
            // It may not: the restore apply runs the full production path and
            // can refuse (a handoff prompt, a third-party takeover, a room
            // that lost its lights). Overwriting the user's persisted defaults
            // for a look that was never put back is a silent corruption of
            // state they will meet again next time they tap the card, so the
            // pre-restore defaults are captured and rolled back on refusal.
            let before = valueScopes.defaults(forCard: previous.cardID)
            valueScopes.setDefaults(values, forCard: previous.cardID)
            persistDefaults(immediately: false)
            bumpLiveValuesTick()
            await applyCore(card, roomOverride: room,
                            preferEntertainmentOverride: snapshot.previousWasStreaming ? true : nil)
            guard runningEffect(for: room)?.cardID != previous.cardID else { return }
            valueScopes.setDefaults(before, forCard: previous.cardID)
            persistDefaults(immediately: false)
            bumpLiveValuesTick()
            studioNotice = StudioNotice(message: PreviewLiveCopy.restoreDropped)
            statusMessage = "⚠ \(PreviewLiveCopy.restoreDropped)"
        }
    }

    /// Apply: the audition is the keeper — discard the snapshot.
    func commitPreviewLive() {
        previewLive.commit()
        previewLiveRoom = nil
        setPreviewingLive(false)
    }

    // ── Board plumbing ──────────────────────────────────────────

    /// Beat-panel edits routed through `commitParam`, so they land on the
    /// exact running instance AND persist as the card's next-start defaults
    /// AND push live to the engine box. One implementation for the header
    /// shortcut and the inline board section alike.
    func studioBeatBinding(forCardID cardID: String) -> Binding<BeatBinding> {
        Binding(
            get: { BeatBinding.fromStudioValues(self.paramNumbers(for: cardID)) },
            set: { newValue in
                for (key, value) in newValue.studioValues {
                    self.commitParam(cardID: cardID, paramID: key, value: value)
                }
            }
        )
    }

    /// The resolver snapshot for a running instance, from CACHED lights only
    /// (no fetch — spec §27). A missing cache yields the all-`.unreadable`
    /// snapshot, so controls resolve unavailable-with-retry instead of
    /// standing on nothing.
    func targetSnapshot(for effect: RunningEffect) -> CustomizationTargetSnapshot {
        let transport: CustomizationTransport
        switch effect.card.strategy {
        case .bridgeNative:
            transport = effect.v2CapableLightIDs.isEmpty ? .legacy : .bridgeEffectV2
        case .appDriven, .composition:
            transport = effect.isEntertainment ? .entertainment : .roomREST
        }
        guard let lights = orchestrator?.cachedRawLights(for: effect.room.bridgeID),
              !effect.lightIDs.isEmpty else {
            return CustomizationSnapshotBuilder.unreadable(
                identity: effect.identity, totalLights: effect.lightIDs.count,
                transport: transport, running: true)
        }
        let idSet = Set(effect.lightIDs)
        let scoped = lights.filter { idSet.contains($0.id) }
        guard !scoped.isEmpty else {
            return CustomizationSnapshotBuilder.unreadable(
                identity: effect.identity, totalLights: effect.lightIDs.count,
                transport: transport, running: true)
        }
        var declared: [String: [String]] = [:]
        if case .bridgeNative(let name) = effect.card.strategy {
            declared[name] = effect.card.params.map(\.id)
        }
        return CustomizationSnapshotBuilder.snapshot(
            identity: effect.identity, lights: scoped,
            declaredEffectParams: declared,
            entertainmentAvailable: .unknown,
            transport: transport, running: true)
    }

    /// Honest color context for the inline editor, from CACHED lights only
    /// (no fetch — spec §27): the known gamut when the target has exactly
    /// one, the widest authoring gamut otherwise, plus the coverage the local
    /// truth chip renders.
    ///
    /// The coverage comes from `targetSnapshot(for:).color` — the SAME value
    /// the resolver measures — so the chip can never claim `.known` coverage
    /// on a target whose lights were never read. It previously built its own
    /// `.known` coverage unconditionally, which made "we could not read these
    /// lights" indistinguishable from "all of them do colour".
    func colorCapabilityContext(for effect: RunningEffect) -> ColorCapabilityContext {
        var context = ColorCapabilityContext()
        context.coverage = targetSnapshot(for: effect).color
        guard let lights = orchestrator?.cachedRawLights(for: effect.room.bridgeID),
              !effect.lightIDs.isEmpty else { return context }
        let idSet = Set(effect.lightIDs)
        let scoped = lights.filter { idSet.contains($0.id) }
        guard !scoped.isEmpty else { return context }
        let colorCapable = scoped.filter { $0.color != nil }
        let gamuts = Set(colorCapable.compactMap {
            $0.color?.gamut_type?.uppercased()
        }.compactMap { HueColorUtils.Gamut(rawValue: $0) })
        if gamuts.count == 1, let only = gamuts.first {
            context.gamut = only
        }
        return context
    }

    /// Advance a running row's generation without disturbing its live values —
    /// the transport-change / reconnect fence. Writes captured before the call
    /// drop; the screen keeps showing the real values.
    func rekeyRunningInstance(at key: StudioSelectionKey,
                              reason: CustomizationInvalidationReason) {
        guard let effect = runningEffects[key] else { return }
        retirePendingSends(for: effect.identity.targetKey)
        if let newIdentity = valueScopes.rekey(
            effect.identity, to: generationCounter.bump(reason)) {
            runningEffects[key]?.identity = newIdentity
        }
        bumpLiveValuesTick()
    }

    // ── Gesture session API ─────────────────────────────────────

    /// Begin a parameter gesture. Returns nil when the selected room is not
    /// running `cardID` (or is a recovered mirror with no live runtime) — the
    /// edit is then a defaults-only write with no live push and no bridge send.
    func beginParamEdit(cardID: String, paramID: String) -> StudioParamSession? {
        guard let effect = currentRoomEffect,
              effect.cardID == cardID,
              effect.recovered == nil,
              let orchestrator else { return nil }
        var effectName: String? = nil
        if case .bridgeNative(let name) = effect.card.strategy { effectName = name }
        return StudioParamSession(
            identity: effect.identity,
            control: CustomizationControlID(cardID: cardID, paramID: paramID),
            api: orchestrator.hueClient(for: effect.room.bridgeID),
            room: effect.room,
            groupedLightID: effect.room.groupedLightID,
            v2CapableLightIDs: effect.v2CapableLightIDs,
            bridgeNativeEffectName: effectName)
    }

    /// One tick of a gesture. Commits through the fence; a committed value
    /// reaches the engine box, the persisted defaults, and (debounced) the
    /// bridge. A dropped value reaches nothing.
    func updateParamEdit(_ session: StudioParamSession, value: Double) {
        let result = valueScopes.commit(
            captured: session.identity, control: session.control, number: value)
        applyCommit(result, session: session, number: value, color: nil)
    }

    func updateParamEdit(_ session: StudioParamSession, color: Color) {
        let result = valueScopes.commit(
            captured: session.identity, control: session.control, color: color)
        applyCommit(result, session: session, number: nil, color: color)
    }

    /// End of gesture. The per-tick commits already landed; this exists so
    /// call sites have an explicit bracket (and future haptic/undo seams).
    func endParamEdit(_ session: StudioParamSession) {
        // Nothing to flush: every tick committed through the fence.
    }

    // ── One-shot writes (toggle, segmented, Beat panel, swatches) ──

    /// Captures identity at call time — exact for a tap. When the card is not
    /// running on the selected room, writes the persisted default only.
    func commitParam(cardID: String, paramID: String, value: Double) {
        if let session = beginParamEdit(cardID: cardID, paramID: paramID) {
            updateParamEdit(session, value: value)
        } else {
            var set = valueScopes.defaults(forCard: cardID)
            set.numbers[paramID] = value
            valueScopes.setDefaults(set, forCard: cardID)
            persistDefaults(immediately: false)
            bumpLiveValuesTick()
        }
    }

    func commitColorParam(cardID: String, paramID: String, color: Color) {
        if let session = beginParamEdit(cardID: cardID, paramID: paramID) {
            updateParamEdit(session, color: color)
        } else {
            var set = valueScopes.defaults(forCard: cardID)
            set.colors[paramID] = color
            valueScopes.setDefaults(set, forCard: cardID)
            persistDefaults(immediately: false)
            bumpLiveValuesTick()
        }
    }

    /// Live numbers for a card as the UI should display them — the selected
    /// exact instance's when it is running, the persisted defaults otherwise.
    /// (The Beat panel reads the whole dict at once.)
    func paramNumbers(for cardID: String) -> [String: Double] {
        _ = liveValuesTick
        if let effect = currentRoomEffect, effect.cardID == cardID, effect.recovered == nil {
            return valueScopes.live(for: effect.identity).numbers
        }
        return valueScopes.defaults(forCard: cardID).numbers
    }

    // ── Commit application ──────────────────────────────────────

    private func applyCommit(_ result: CustomizationCommitResult<Color>,
                             session: StudioParamSession,
                             number: Double?, color: Color?) {
        guard case .committed(let identity, let resolved) = result else { return }

        // 1. Engine box — the exact bridge AND room this identity names.
        //    (No-op for bridge-native/composition looks: no engine runtime.)
        orchestrator?.updateStudioParams(
            values: resolved.numbers, colors: resolved.colors,
            bridgeID: identity.bridgeID, roomID: identity.groupID)

        // 2. Persisted next-start defaults keep tracking last-used values
        //    (existing product behavior), debounced by the store.
        var defaults = valueScopes.defaults(forCard: identity.cardID)
        if let number { defaults.numbers[session.control.paramID] = number }
        if let color { defaults.colors[session.control.paramID] = color }
        valueScopes.setDefaults(defaults, forCard: identity.cardID)
        persistDefaults(immediately: false)

        // 3. Debounced bridge send, keyed per exact target.
        scheduleBridgeSend(session: session, number: number, color: color)

        bumpLiveValuesTick()
    }

    // ── Debounced bridge sends (R4D) ────────────────────────────
    //
    // ONE task per exact running target, and one PendingStudioSend beside it
    // accumulating what that window changed.
    //
    // THE DEFECT this replaces: the slot was keyed per target but carried a
    // single (number|color) pair, so a second param committed inside the 150 ms
    // window cancelled the first param's task and the first param's value never
    // reached the bridge at all. Dragging Brightness and then Warmth left the
    // room at the old brightness while the UI, the scopes and the persisted
    // defaults all said otherwise.
    //
    // Per-PARAM tasks would not fix it: `RestSender` keeps a latest-wins
    // mailbox per `RestScope`, so two closures enqueued for the same room in
    // the same turn would still lose one. The fix has to COALESCE — one grouped
    // PUT carrying every grouped field, then one `EffectsV2Body` per light
    // carrying every v2 field.

    /// Cancel the pending send for one exact target and forget what it had
    /// accumulated. The single idiom for every teardown path — `stopEffect`,
    /// `stopRunningScopes`, `rekeyRunningInstance`, `resetParams`, and the
    /// place-level belt in `installRunningIdentity`.
    ///
    /// Dropping the accumulated fields matters as much as cancelling the task:
    /// a surviving `pendingParamSends` entry would be picked up by the NEXT
    /// window on the same target key and re-send values the user authored
    /// against a run that no longer exists.
    func retirePendingSends(for key: RunningLookTargetKey) {
        paramSendTasks[key]?.cancel()
        paramSendTasks[key] = nil
        pendingParamSends[key] = nil
    }

    /// Accumulate this commit into the target's window and (re)arm the single
    /// debounced task. After the sleep the task re-fences on the captured
    /// identity — Stop, Reset, replacement, or a rekey between schedule and
    /// fire drops the whole window. Inside the mailbox closure the existing
    /// `stillCurrent()` epoch probes keep covering the post-enqueue window.
    private func scheduleBridgeSend(session: StudioParamSession,
                                    number: Double?, color: Color?) {
        let targetKey = session.identity.targetKey
        var pending = pendingParamSends[targetKey] ?? PendingStudioSend(session: session)
        pending.session = session
        if let number { pending.numbers[session.control.paramID] = number }
        if let color { pending.colors[session.control.paramID] = color }
        pendingParamSends[targetKey] = pending

        paramSendTasks[targetKey]?.cancel()
        paramSendTasks[targetKey] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            // Everything from here to the removal below is one synchronous
            // main-actor stretch, so a replacement scheduled meanwhile either
            // cancelled us before it (we return) or lands after it (its task
            // and its window are installed after ours are cleared). There is no
            // window in which this clears a SUCCESSOR's slot.
            guard !Task.isCancelled, let self else { return }
            guard let window = self.pendingParamSends.removeValue(forKey: targetKey) else { return }
            self.paramSendTasks[targetKey] = nil
            guard self.valueScopes.isCurrent(window.session.identity) else { return }
            await self.performBridgeSend(window)
        }
    }

    /// Emit ONE coalesced bridge write for everything the window accumulated.
    ///
    /// Routing per param is EXACTLY what it was before the coalescing — the
    /// only change is that fields which used to travel in separate PUTs now
    /// share one:
    ///
    ///   * `brightness` — grouped light only (there is no per-light v2 field
    ///     for it); drops when the room has no room control.
    ///   * `base_color` — v2 per-light re-parameterization when the look is a
    ///     bridge-native effect with v2-capable lights; otherwise the legacy
    ///     grouped `xy` fallback (preserved shipping behaviour, classified as
    ///     an approximation rather than deleted).
    ///   * `warmth` — same split, as `mirek`. A grouped mirek PUT fights a
    ///     running firmware effect, which is why the v2 path is preferred.
    ///   * `speed` — bridge-native AND v2-capable only. There is no legacy
    ///     speed path; on a v1-only room this send does not exist and the
    ///     capability layer says so rather than faking it.
    ///   * `transition` shapes this send's `dynamics.duration` and issues no
    ///     command of its own; `saturation` has no bridge-native consumer.
    ///   * anything else is an app-driven engine tunable, already delivered by
    ///     the committed box push.
    private func performBridgeSend(_ window: PendingStudioSend) async {
        let session = window.session
        // No orchestrator or no captured client: nothing to send — the
        // committed values already reached the scopes and the engine box.
        guard let orchestrator, let api = session.api else { return }
        let roomID = session.room.id
        let bridgeID = session.room.bridgeID

        // Transition (Smoothness) is read from the instance's CURRENT live
        // values at fire time — it shapes this send's dynamics.duration.
        let live = valueScopes.live(for: session.identity)
        let transitionDefault = (effectCards + liveModeCards)
            .first { $0.id == session.control.cardID }?
            .params.first { $0.id == "transition" }?.defaultValue ?? 400
        let transitionMs = Int(live.numbers["transition"] ?? transitionDefault)

        let effectName = session.bridgeNativeEffectName
        let capable = session.v2CapableLightIDs
        let prefersV2 = effectName != nil && !capable.isEmpty

        // Grouped PUT fields.
        var groupedBrightness: Double? = window.numbers["brightness"]
        var groupedXY: (Double, Double)? = nil
        var groupedMirek: Int? = nil
        // Per-light effects_v2 fields.
        var v2Speed: Double? = nil
        var v2ColorXY: CGPoint? = nil
        var v2Mirek: Int? = nil

        if let color = window.colors["base_color"] {
            let uiColor = UIColor(color)
            var h: CGFloat = 0, sat: CGFloat = 0, b: CGFloat = 0
            uiColor.getHue(&h, saturation: &sat, brightness: &b, alpha: nil)
            let xy = HueColorUtils.xyFrom(hue: Double(h), saturation: Double(sat),
                                          brightness: Double(b))
            if prefersV2 {
                v2ColorXY = CGPoint(x: xy.x, y: xy.y)
            } else {
                groupedXY = (xy.x, xy.y)
            }
        }

        if let warmth = window.numbers["warmth"] {
            let mirek = Int(warmth.rounded())
            if prefersV2 {
                v2Mirek = mirek
            } else {
                groupedMirek = mirek
            }
        }

        if let speed = window.numbers["speed"], prefersV2 {
            v2Speed = min(1.0, max(0.0, speed / 100.0))
        }

        let groupedLightID = session.groupedLightID
        if groupedLightID == nil {
            // No room control: the grouped fallbacks have nowhere to land.
            groupedBrightness = nil
            groupedXY = nil
            groupedMirek = nil
        }
        let needsGrouped = groupedBrightness != nil || groupedXY != nil || groupedMirek != nil
        let v2Body: EffectsV2Body? = {
            guard let effectName, v2Speed != nil || v2ColorXY != nil || v2Mirek != nil else {
                return nil
            }
            return EffectsV2Body(effect: effectName, speed: v2Speed,
                                 colorXY: v2ColorXY, mirek: v2Mirek)
        }()
        guard needsGrouped || v2Body != nil else { return }

        let gate = orchestrator.commandGate(for: bridgeID)
        let brightness = groupedBrightness
        let xy = groupedXY
        let mirek = groupedMirek

        await orchestrator.enqueueStudioRestWrite(roomID: roomID, bridgeID: bridgeID) { stillCurrent in
            // Cooperative cancellation before EVERY send, including the first
            // (packet 3) — Task.isCancelled is inert inside the mailbox's
            // unstructured flush task.
            if needsGrouped, let groupedLightID {
                guard await stillCurrent() else { return }
                try? await api.setGroupedLightEffect(
                    id: groupedLightID, on: nil,
                    brightness: brightness, xy: xy, mirek: mirek,
                    duration: transitionMs)
            }
            if let v2Body {
                for id in capable {
                    guard await stillCurrent() else { return }
                    _ = await gate.send(retry: false) {
                        try await api.setLightEffectV2(id: id, body: v2Body)
                    }
                }
            }
        }
    }

    #if DEBUG
    /// TEST SEAM: fire the pending window for one exact target NOW, through the
    /// production emit path, instead of waiting out the debounce.
    ///
    /// Exists because the alternative is a `Task.sleep` in a test, and a suite
    /// that sleeps to observe a debounce is a suite that goes flaky on a loaded
    /// CI machine. The task is cancelled first, so the real one cannot also
    /// fire; every guard the real task runs is run here in the same order.
    func testFlushPendingParamSends(for key: RunningLookTargetKey) async {
        paramSendTasks[key]?.cancel()
        paramSendTasks[key] = nil
        guard let window = pendingParamSends.removeValue(forKey: key) else { return }
        guard valueScopes.isCurrent(window.session.identity) else { return }
        await performBridgeSend(window)
    }
    #endif
}
