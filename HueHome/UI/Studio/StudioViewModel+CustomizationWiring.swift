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
    /// This exact window's identity (fifth review round).
    ///
    /// `RunningLookIdentity` cannot do this job: successive windows on one
    /// running instance all carry the SAME identity, and what has to be told
    /// apart here is one window from its own successor. The in-flight record
    /// is cleared by the mailbox closure that was enqueued for it, and the
    /// mailbox runs closures late: W1 can sit pending behind a busy
    /// `RestSender` while W2 merges it, records ITSELF as in flight and
    /// suspends on its own enqueue — and W1's closure, dequeued in that
    /// window, wiped W2's record. W3 then carried nothing forward and its
    /// enqueue replaced W2's still-pending closure, so W2's fields never
    /// reached the bridge at all. The closure clears the record only when the
    /// record is still its own.
    ///
    /// Not part of the memberwise initializer (a `let` with a default never
    /// is), so every window mints its own and no call site can spoof one.
    let token = UUID()
    /// The most recent gesture session for this target — its `identity` is the
    /// fence the debounced task re-checks, and its api/room/light facts are
    /// what the send routes on.
    var session: StudioParamSession
    /// Numeric params committed in this window, by param id.
    var numbers: [String: Double] = [:]
    /// Colour params committed in this window, by param id.
    var colors: [String: Color] = [:]
    /// Which member of the mutually exclusive grouped pair was committed LAST.
    ///
    /// `color` and `color_temperature` cannot share one CLIP grouped body, so
    /// a window holding both emits two PUTs — and the SECOND one wins on the
    /// wall. The emit order was hard-coded xy-then-mirek, so a user who picked
    /// a colour after dragging warmth watched the older warmth overwrite the
    /// colour they had just chosen. The window records the order it actually
    /// saw, and the emit puts the later one last.
    var lastColourLikeCommit: ColourLikeCommit? = nil

    /// The two grouped fields that cannot travel together.
    enum ColourLikeCommit: Hashable {
        case xy      // base_color
        case mirek   // warmth
    }
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
        //
        // The key the successor will occupy, computed before the sweep: a
        // RESTART of the same look on the same place retires and re-registers
        // the SAME target key.
        let successorKey = RunningLookTargetKey(
            bridgeID: room.bridgeID, groupID: room.id, kind: room.kind,
            cardID: card.id, execution: execution)
        for retired in valueScopes.stopRunning(atPlace: room.bridgeID,
                                               groupID: room.id, kind: room.kind) {
            retirePendingSends(for: retired)
            // The retired scope's working memory (expansions, board position)
            // described a run that no longer exists. Leaving it behind hands
            // the successor another look's UI state under the same key.
            //
            // …unless the retired key IS the successor's. A same-card restart
            // (a reset's re-apply, a handoff replay, a transport change that
            // goes back through apply) is the same look on the same place, and
            // wiping its board position and expansions there made the console
            // jump under the user for a run that never changed.
            guard retired != successorKey else { continue }
            sessionMemory.clear(for: retired)
        }
        let identity = RunningLookIdentity(
            bridgeID: room.bridgeID, groupID: room.id, kind: room.kind,
            cardID: card.id, execution: execution,
            generation: generationCounter.bump(.cardReplaced))
        // Sparse own-values over a base frozen from the card's persisted
        // defaults right now — see `CustomizationValueScopes.frozenBases` for
        // why a COMPLETE catalog seed closes the cross-instance leak at the
        // cost of a worse one (every untouched param becoming a persisted
        // "the user set this").
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
        // LAYERED, not replaced (H1). `live(for:)` is SPARSE own-values over a
        // base frozen when THIS instance started, so it is silent about any
        // default written after that instant — the look browser's setup
        // sliders on an idle room write exactly those. `setDefaults` replaces
        // the whole dictionary, so copying the live set in raw DELETED them.
        // Layering keeps copy-once intact (everything the instance holds still
        // wins) while destroying nothing it never had an opinion about.
        let live = valueScopes.live(for: source.identity)
            .layered(over: valueScopes.defaults(forCard: source.cardID))
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

    /// True while ANY lifecycle question is on screen waiting for the user.
    ///
    /// A prompt is not a refusal. An `applyCore` that ends with one of these
    /// standing has neither started nor declined the look — it has DEFERRED
    /// it, and the confirmation path will run the same apply for real. Preview
    /// Live has to tell the two apart: treating a deferred apply as a refusal
    /// is what rolled the restore's defaults back under an open prompt, so the
    /// confirmation then applied the wrong values.
    var hasPendingLifecyclePrompt: Bool {
        entertainmentHandoffPrompt != nil
            || studioHandoffRequest != nil
            || foreignTakeoverRequest != nil
            || areaChoiceRequest != nil
    }

    /// The card the LIVE audition is playing, if one is playing.
    ///
    /// `isPreviewingLive` is a single global flag while the details panel is
    /// PER CARD: re-pointing the panel at another look (chip context menu →
    /// "Details & Setup") used to show that card Keep It / Put It Back, and
    /// "Keep It" then recorded the wrong card as applied. The panel gates on
    /// this instead, so the audition's controls belong to the audition's card
    /// and to no other.
    var previewAuditionCardID: String? { previewLive.previewIdentity?.cardID }

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
        let key = StudioSelectionKey(room: room)

        // ── Refuse rather than arm a snapshot that cannot be honoured ──

        // M1. A chained audition on a DIFFERENT room would move
        // `previewIdentity` to room B while `previewLiveRoom` still named room
        // A: the cancel would then fence B's audition against A's row, drop,
        // and A's original look would be unrecoverable. One audition, one
        // room — say which room, and change nothing.
        if previewLive.isPreviewing, let armed = previewLiveRoom,
           StudioSelectionKey(room: armed) != key {
            studioNotice = StudioNotice(
                message: PreviewLiveCopy.finishPreviewFirst(in: armed.name))
            statusMessage = "⚠ \(PreviewLiveCopy.finishPreviewFirst(in: armed.name))"
            return
        }

        if let previous = runningEffects[key] {
            // B1. A recovered bridge-stored animation has no app-side runtime
            // and no restartable card — "Put It Back" could not put it back.
            if previous.recovered != nil {
                studioNotice = StudioNotice(message: PreviewLiveCopy.recoveredCannotBePreviewedOver)
                statusMessage = "⚠ \(PreviewLiveCopy.recoveredCannotBePreviewedOver)"
                return
            }
            // B1. The snapshot holds NUMBERS AND COLOURS. A running
            // composition's live state is its `CompositionParamBox` — palette,
            // motion, envelope, reaction — which the audition's replacement
            // stop evicts and which "Put It Back" would rebuild from the SAVED
            // preset. Every unsaved composer edit would be destroyed by the one
            // button that promises an exact undo. Nothing here can snapshot
            // that box honestly, so the audition is refused and NOTHING is
            // mutated: no snapshot, no flag, no room.
            if case .composition = previous.card.strategy,
               hasLiveCompositionBox(at: key) {
                studioNotice = StudioNotice(message: PreviewLiveCopy.compositionCannotBePreviewedOver)
                statusMessage = "⚠ \(PreviewLiveCopy.compositionCannotBePreviewedOver)"
                return
            }
        }

        // Captured BEFORE the apply. "Did the audition start" cannot be
        // `started.cardID == card.id` alone: when the audition card IS the
        // card already running, a refusal leaves that row untouched and the
        // test passes on the PREVIOUS instance (H2). Every real start mints a
        // new generation, so a changed identity is the only honest evidence.
        let previousIdentity = runningEffects[key]?.identity

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
                // M5: the OBSERVED transport, not the requested one. A look
                // that asked for streaming and fell back to REST has
                // `isEntertainment == false` by the time it is snapshotted, and
                // the restore must reproduce THAT, not the ambition.
                previousWasStreaming: previous?.isEntertainment ?? false)
            previewLiveRoom = room
        }

        // The flag disables the button for the duration AND tells `stopEffect`
        // that the replacement teardown about to run belongs to this audition,
        // so it must not consume the snapshot the audition is chaining onto.
        setAuditionInFlight(true)
        await applyCore(card, roomOverride: room, preferEntertainmentOverride: nil)
        setAuditionInFlight(false)

        if notePreviewAuditionOutcome(card: card, room: room,
                                      previousIdentity: previousIdentity) {
            return
        }

        // M5. A lifecycle prompt is standing: the audition is WAITING, not
        // refused. Keep the snapshot and the armed room exactly as they are —
        // the confirmation path re-runs `notePreviewAuditionOutcome`, so the
        // audition arms Put It Back if and when it actually starts, and the
        // matching cancel consumes the snapshot instead.
        //
        // NAME the deferral (fifth review round). The confirmation that
        // resolves this prompt replays whatever apply raised it, and only THIS
        // card on THIS room is the audition's own replay — see
        // `withDeferredAuditionInFlight`, which used to exempt every replay
        // that happened to run while a preview was armed.
        if hasPendingLifecyclePrompt {
            deferredAudition = (cardID: card.id, key: key)
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

    /// Did an audition actually START on `room`? Arms "Put It Back" when it
    /// did, and reports the answer.
    ///
    /// Shared by `beginPreviewLiveCore` and by every confirmation core, so an
    /// audition deferred behind a prompt is armed by the confirmation that
    /// finally starts it rather than being silently forgotten (M5).
    ///
    /// The identity comparison is the whole test (H2). `cardID` alone answers
    /// "yes" for a refused apply of the card that was ALREADY running there:
    /// the row is untouched, but it names the audition's card, so Put It Back
    /// would stop and restart an unchanged look.
    @discardableResult
    func notePreviewAuditionOutcome(card: StudioCard,
                                    room: RoomDisplayItem,
                                    previousIdentity: RunningLookIdentity?) -> Bool {
        guard previewLive.isPreviewing,
              let armed = previewLiveRoom,
              StudioSelectionKey(room: armed) == StudioSelectionKey(room: room),
              let started = runningEffect(for: room),
              started.cardID == card.id,
              started.identity != previousIdentity else { return false }
        previewLive.previewStarted(started.identity)
        // The deferral is spent: this audition is running now, so a LATER
        // confirmation replay is somebody else's apply (fifth review round).
        deferredAudition = nil
        // Only NOW is there an audition to put back. Setting this before the
        // apply meant a refusal (handoff prompt, Reduce Motion, an unsupported
        // room) left the browser showing "Keep It / Put It Back" for a look
        // that never started.
        setPreviewingLive(true)
        return true
    }

    /// A lifecycle prompt was DISMISSED. An audition that was waiting behind it
    /// never started, so its snapshot describes a world nothing changed —
    /// consume it rather than leave a fence a later cancel could measure
    /// against. An audition that HAD started keeps everything: it is still
    /// playing and still restorable.
    func discardArmedPreviewIfNotStarted() {
        guard previewLive.isPreviewing, previewLive.previewIdentity == nil else { return }
        _ = previewLive.cancelVerdict(live: nil)
        previewLiveRoom = nil
        setPreviewingLive(false)
    }

    /// The SINGLE exit rule for every confirmation body: when this path is
    /// over and no question is left standing, a deferred audition that never
    /// started must not be left armed.
    ///
    /// THE STRANDING THIS ENDS. An audition whose apply raised a prompt keeps
    /// its snapshot deliberately (M5) — the confirmation is going to run the
    /// apply for real. But a confirmation has many ways to end WITHOUT
    /// starting anything: a stale area choice, an unreadable bridge, a
    /// `.failed` resolution, an owner that changed into something the consent
    /// did not name, or a replayed `applyCore` that simply refuses. Each of
    /// those left `previewLive.isPreviewing` true with `previewIdentity` nil:
    /// no UI can offer Keep It or Put It Back for a look that never started,
    /// nothing consumes the machine, and every OTHER room's Preview Live is
    /// then refused with "finish the preview in Room A first" — permanently.
    ///
    /// Called from a `defer` in each confirmation core, so a future early
    /// return cannot reintroduce the leak by forgetting a call site.
    ///
    /// A standing prompt is exempt for the same reason it always was: the
    /// question is still open, so the audition is still deferred, not refused.
    func releaseDeferredPreviewIfUnresolved() {
        guard !hasPendingLifecyclePrompt else { return }
        // No question is standing, so nothing is deferred any more — whether
        // the audition started or not (fifth review round). The guard above is
        // what keeps a `.changedOwner` re-present deferred: it asks the same
        // question again, so the marker must survive with the snapshot.
        deferredAudition = nil
        discardArmedPreviewIfNotStarted()
        resolveDeferredRestoreRollback()
    }

    /// Settle a RESTORE that was deferred behind a lifecycle prompt (M2).
    ///
    /// `cancelPreviewLiveCore` leaves the snapshot's values sitting in the
    /// card's persisted defaults when a prompt stands, because the
    /// confirmation's apply has to start from them. Its own rollback is
    /// therefore unreachable, and the preview machine is already consumed —
    /// so `discardArmedPreviewIfNotStarted` cannot stand in for it. This does:
    /// the restore either LANDED (the deferred row now runs the card the
    /// snapshot named — keep the values, they are the ones the user is
    /// looking at) or it did not, in which case the pre-restore defaults come
    /// back and the drop is SAID, exactly as an immediately refused restore
    /// says it.
    ///
    /// Called only with no question standing: a prompt still open means the
    /// restore is still deferred, not resolved.
    func resolveDeferredRestoreRollback() {
        guard !hasPendingLifecyclePrompt, !pendingRestoreRollbacks.isEmpty else { return }
        // Consumed whole, then settled entry by entry: every card that was
        // waiting is answered on this pass, and none is left behind for a
        // later prompt to overwrite (fifth review round).
        let pending = pendingRestoreRollbacks
        pendingRestoreRollbacks.removeAll()
        var anyDropped = false
        for (cardID, entry) in pending {
            // The same test `cancelPreviewLiveCore` runs immediately after its
            // own apply — and for the same reason it is an IDENTITY test.
            if restoreLanded(at: entry.rowKey, cardID: cardID,
                             preApplyIdentity: entry.preApplyIdentity) { continue }
            valueScopes.setDefaults(entry.before, forCard: cardID)
            anyDropped = true
        }
        guard anyDropped else { return }
        persistDefaults(immediately: false)
        bumpLiveValuesTick()
        // ONE sentence however many restores were dropped: the user pressed
        // "Put It Back", and "we couldn't put it back" is the whole message.
        studioNotice = StudioNotice(message: PreviewLiveCopy.restoreDropped)
        statusMessage = "⚠ \(PreviewLiveCopy.restoreDropped)"
    }

    /// Did a "Put It Back" restore actually LAND on `rowKey`?
    ///
    /// CARD ID IS NOT THE TEST (fifth review round) — the same H2 lesson
    /// `notePreviewAuditionOutcome` already learned, on the other side of the
    /// audition. A SAME-CARD audition leaves the row already running
    /// `previous.cardID` before the restore apply, so `cardID != previous`
    /// answered "landed" for a restore that was flatly refused: no rollback of
    /// the defaults, no "we couldn't put it back", and the whole deferred-M2
    /// machinery unreachable for that class. Put It Back silently did nothing.
    ///
    /// Every real restart mints a new generation, so a row that names the card
    /// AND is a different run from the one standing there before the apply is
    /// the only honest evidence of a restore.
    func restoreLanded(at rowKey: StudioSelectionKey,
                       cardID: String,
                       preApplyIdentity: RunningLookIdentity?) -> Bool {
        guard let now = runningEffects[rowKey], now.cardID == cardID else { return false }
        return now.identity != preApplyIdentity
    }

    /// Run a confirmation's replayed `applyCore` with the audition flag raised
    /// when an audition is still pending behind the prompt (M1).
    ///
    /// THE CHAIN THIS FIXES. `beginPreviewLiveCore` brackets its own apply in
    /// `setAuditionInFlight(true/false)` precisely so the replacement teardown
    /// that apply performs — `stopEffect` → `removeRunningRow` →
    /// `notePreviewRowRemoved` — does not consume the snapshot the audition is
    /// chaining onto. A confirmation replays that same apply with the flag
    /// DOWN, so a chained audition deferred behind a prompt had its own
    /// replacement stop eat the machine, post "we couldn't put it back", and
    /// leave `notePreviewAuditionOutcome` failing its `isPreviewing` guard:
    /// the second look ran with no undo at all.
    ///
    /// The previous value is restored rather than forced to false, so this can
    /// never lower a flag some outer bracket raised.
    ///
    /// WHY THE REPLAY HAS TO BE IDENTIFIED (fifth review round). The condition
    /// was `previewLive.isPreviewing` alone — "a preview is armed" — which is
    /// true for every confirmation that runs during an audition, and a
    /// confirmation replays whatever apply raised its prompt. Two ways that
    /// went wrong, both with the user's own deliberate action:
    ///
    ///   • HIJACK. An audition is playing on room A; the user deliberately
    ///     applies another card to room A; that apply raises a prompt. On
    ///     confirm the replay ran with the flag up, so the replacement stop's
    ///     `notePreviewRowRemoved` was suppressed instead of consuming the
    ///     machine — and the unconditional `notePreviewAuditionOutcome` then
    ///     armed the DELIBERATE apply as the audition. "Put It Back" undid a
    ///     change the user meant to make.
    ///   • STRANDING. An audition is playing on room A; the user applies to
    ///     room B on the same bridge; on confirm the replay's engine-singleton
    ///     / one-DTLS-per-bridge / light-overlap teardown removes room A's row
    ///     with the notice suppressed. The machine stayed armed on a row that
    ///     no longer exists, nothing said "we couldn't put it back", and every
    ///     other room's Preview Live was refused with "finish the preview in
    ///     Room A first" for the rest of the session.
    ///
    /// So the exemption is granted to exactly one replay: the one whose card
    /// and room match the deferral `beginPreviewLiveCore` recorded when its own
    /// apply raised the prompt.
    func withDeferredAuditionInFlight(card: StudioCard,
                                      room: RoomDisplayItem,
                                      _ body: () async -> Void) async {
        let previous = isAuditionInFlight
        let isTheDeferredAudition = previewLive.isPreviewing
            && deferredAudition?.cardID == card.id
            && deferredAudition?.key == StudioSelectionKey(room: room)
        if isTheDeferredAudition { setAuditionInFlight(true) }
        await body()
        setAuditionInFlight(previous)
    }

    /// The ONE way a running row leaves `runningEffects`.
    ///
    /// Every removal is also the disappearance of a row the live audition may
    /// have been fenced on, and three of them (`applyBridgeSaveOutcome`'s two
    /// arms, `applySavedLookStopOutcome`) forgot to say so — leaving "Put It
    /// Back" offering an undo that would land on whatever took the room next.
    /// Funnelling them through here makes the notification structural instead
    /// of a thing each new removal site has to remember.
    ///
    /// The identity-matched guards stay at the CALL SITES: only they know
    /// whether the row standing there is the one this path owns.
    func removeRunningRow(at key: StudioSelectionKey) {
        guard runningEffects[key] != nil else { return }
        notePreviewRowRemoved(rowKey: key)
        runningEffects.removeValue(forKey: key)
    }

    /// A row was REMOVED by a path that does not run `stopEffect`
    /// (`replayStudioHandoff`, a lost Entertainment session). If it was the
    /// live audition's row, the snapshot can never be restored onto it now —
    /// consume the machine rather than leave "Put It Back" offering an undo
    /// that would land on whatever takes the room next, and SAY so, because
    /// the affordance disappearing with no sentence is the silent-drop defect.
    ///
    /// One implementation, three call sites (`stopEffect`, the handoff replay,
    /// the session-lost removal) — the three ways a row can vanish.
    ///
    /// No double restore: `cancelPreviewLive` computes its verdict (which nils
    /// `previewIdentity`) BEFORE the restore apply reaches here, and an
    /// audition's own replacement stop runs while `isAuditionInFlight` is true
    /// — which is precisely what that flag exists to distinguish.
    func notePreviewRowRemoved(rowKey: StudioSelectionKey) {
        guard !isAuditionInFlight,
              previewLive.previewIdentity?.selectionKey == rowKey else { return }
        _ = previewLive.cancelVerdict(live: nil)
        previewLiveRoom = nil
        setPreviewingLive(false)
        studioNotice = StudioNotice(message: PreviewLiveCopy.restoreDropped)
        statusMessage = "⚠ \(PreviewLiveCopy.restoreDropped)"
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
        // Captured BEFORE the verdict, which nils `previewIdentity`. The
        // restore below needs to know WHICH instance was auditioning, not
        // merely that one was (fifth review round — the same-card audition).
        let auditionIdentity = previewLive.previewIdentity
        let hadAudition = auditionIdentity != nil

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
                // the preview and leaves the room AS IT WAS.
                //
                // M3: NOT the explicit stop. "Idle" means no look was running,
                // not that the room was dark: `stopActiveTargetCore` sets
                // `isExplicitStop`, which turns the lights OFF. Putting the
                // room back is not the same as switching it off, and the user
                // has no undo for that from here.
                await stopPreviewTargetPreservingLights(StudioSelectionKey(room: room))
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
            //
            // LAYERED, not replaced (H1). The snapshot's value set is the
            // instance's SPARSE own-values over the base frozen when it
            // started, so it says nothing about a default written after that
            // instant (a setup slider moved in the look browser while this
            // room ran). Replacing the dictionary wholesale deleted those.
            let before = valueScopes.defaults(forCard: previous.cardID)
            // …but the base being layered over is not always `before` (fifth
            // review round). THE SAME-CARD AUDITION. The browser offers
            // Preview Live on the look that is ALREADY running, and
            // `notePreviewAuditionOutcome` only asks for a changed identity —
            // so the audition instance and the previous instance can share one
            // card. Every live commit on the audition also writes that card's
            // persisted defaults (`applyCommit` step 2), so `before` then
            // contains keys the AUDITION authored and the previous instance
            // never had — a warmth of 300 the user only ever set on the
            // audition. Layering keeps them, and the restart seeds from them:
            // "Put It Back" comes back with a mirek the previous look never
            // sent (spec §16.5 wants the wire restored exactly), and the
            // "a stored warmth default ⇒ the user chose it" sentinel is
            // permanently armed.
            //
            // Subtract exactly what the audition instance OWNS — its sparse
            // own-values, so a key the previous look really had still comes
            // back out of the snapshot, which wins over this base anyway. Only
            // for the SAME card: defaults are per card, so a different-card
            // audition cannot have touched these keys.
            //
            // `before` itself is left alone — it is the rollback baseline, and
            // a restore that never lands must put the world back as it was,
            // audition writes included.
            var restoreBase = before
            if let auditionIdentity, auditionIdentity.cardID == previous.cardID {
                restoreBase = before.removing(
                    keysOf: valueScopes.ownValues(for: auditionIdentity))
            }
            valueScopes.setDefaults(values.layered(over: restoreBase), forCard: previous.cardID)
            persistDefaults(immediately: false)
            bumpLiveValuesTick()
            // M5: the observed transport, both ways. `true : nil` let a
            // previous look that had FALLEN BACK to REST come back streaming,
            // because nil re-derives the preference from the preset instead of
            // reproducing what was actually there. App-driven cards ignore the
            // override entirely, so passing `false` costs them nothing.
            //
            // Captured for the landed test below (fifth review round): the row
            // as it stands immediately BEFORE the restore apply. See
            // `restoreLanded(at:cardID:preApplyIdentity:)`.
            let rowKey = StudioSelectionKey(room: room)
            let preRestoreIdentity = runningEffects[rowKey]?.identity
            await applyCore(card, roomOverride: room,
                            preferEntertainmentOverride: snapshot.previousWasStreaming)
            if restoreLanded(at: rowKey, cardID: previous.cardID,
                             preApplyIdentity: preRestoreIdentity) { return }

            // H3. A prompt is standing: the restore is DEFERRED, not refused.
            // Rolling the defaults back here would leave the confirmation's
            // apply seeded from the PRE-RESTORE values — the exact wrong ones —
            // and would spend a "we couldn't put it back" sentence on a
            // question the user has not answered yet. Leave the snapshot values
            // in place for the confirmation to start from, say nothing, and
            // keep the machine consumed (this cancel has spent the audition
            // either way).
            //
            // M2. But the rollback cannot simply be forgotten either. The
            // machine IS consumed, so if the confirmation then refuses,
            // `discardArmedPreviewIfNotStarted` short-circuits and NOTHING
            // rolls these defaults back — the user is left with the previous
            // look's values persisted under a card that was never put back,
            // and no sentence saying so. Hand the rollback to whichever path
            // resolves the prompt: `releaseDeferredPreviewIfUnresolved` runs
            // it on every confirmation and every dismissal.
            if hasPendingLifecyclePrompt {
                // An existing entry for the SAME card holds the truer `before`
                // — it was captured before any restore touched the defaults.
                // Keyed per card (fifth review round): a single slot let a
                // second deferred restore, for a DIFFERENT card, silently drop
                // the first card's rollback.
                if pendingRestoreRollbacks[previous.cardID] == nil {
                    pendingRestoreRollbacks[previous.cardID] =
                        (rowKey: rowKey, before: before,
                         preApplyIdentity: preRestoreIdentity)
                }
                return
            }

            valueScopes.setDefaults(before, forCard: previous.cardID)
            persistDefaults(immediately: false)
            bumpLiveValuesTick()
            studioNotice = StudioNotice(message: PreviewLiveCopy.restoreDropped)
            statusMessage = "⚠ \(PreviewLiveCopy.restoreDropped)"
        }
    }

    /// Apply: the audition is the keeper — discard the snapshot.
    ///
    /// Serialized like every other preview transition (L3): it mutates the
    /// lifecycle state the apply/cancel bodies read, so it must not interleave
    /// with one of them.
    func commitPreviewLive() async {
        await serialized { [weak self] in
            guard let self else { return }
            self.previewLive.commit()
            self.previewLiveRoom = nil
            self.setPreviewingLive(false)
        }
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
        // OBSERVATION DEPENDENCY, not dead code. `lightsByBridge` is
        // @ObservationIgnored infrastructure, so a board that resolved
        // "CHECKING WHAT THESE LIGHTS SUPPORT" against an empty cache would sit
        // there forever: the inventory landing later mutated nothing SwiftUI
        // was watching, so nothing re-rendered and the note never went away.
        // Reading the orchestrator's inventory generation here enrolls every
        // board that resolves through this snapshot in exactly one observable
        // fact — "a fresh light inventory arrived" — so the answer re-resolves
        // the moment the bridge finally answers.
        _ = orchestrator?.capabilityInventoryGeneration
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
        // The RUNNING bridge-native effect, so the snapshot's `effectsV2`
        // coverage measures what this look's per-light send can actually
        // reach rather than generic v2 support. A room of one cosmos-capable
        // light and two candle/fire-only lights is 3/3 generically and 1/3
        // for Cosmos — and 1/3 is the number the user's colour, warmth and
        // speed controls actually move.
        var runningEffectV2Name: String? = nil
        if case .bridgeNative(let name) = effect.card.strategy {
            declared[name] = effect.card.params.map(\.id)
            runningEffectV2Name = name
        }
        return CustomizationSnapshotBuilder.snapshot(
            identity: effect.identity, lights: scoped,
            declaredEffectParams: declared,
            runningEffectV2Name: runningEffectV2Name,
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
    ///
    /// `snapshot:` lets a caller that has ALREADY built the snapshot hand it
    /// over rather than pay for a second scan of the light cache. The board
    /// builds one per render pass for its resolutions and then asked for the
    /// colour context, which built a second one — two passes over every light,
    /// and two separate instants of truth describing one control.
    func colorCapabilityContext(
        for effect: RunningEffect,
        snapshot: CustomizationTargetSnapshot? = nil
    ) -> ColorCapabilityContext {
        var context = ColorCapabilityContext()
        context.coverage = snapshot?.color ?? targetSnapshot(for: effect).color
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
        // The window already handed to the mailbox dies here too: it was
        // authored against a run that no longer exists, so carrying it into a
        // successor's window would re-send exactly the values this teardown
        // exists to fence.
        inFlightParamSends[key] = nil
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
        // CROSS-WINDOW LOSS (M3). `RestSender` keeps a latest-wins mailbox per
        // scope, so the closure a previous window enqueued can be DROPPED for
        // this one — and that window's fields were removed from
        // `pendingParamSends` when it was enqueued, so they would simply be
        // gone. Carry anything still in flight into this window; newer values
        // win, and re-sending a field whose closure did run is idempotent.
        if let inFlight = inFlightParamSends[targetKey] {
            pending.numbers.merge(inFlight.numbers) { mine, _ in mine }
            pending.colors.merge(inFlight.colors) { mine, _ in mine }
            // A carried-forward field is OLDER than anything this window
            // committed, so it only supplies the order when this window has
            // not seen either member of the pair itself.
            if pending.lastColourLikeCommit == nil {
                pending.lastColourLikeCommit = inFlight.lastColourLikeCommit
            }
        }
        pending.session = session
        if let number { pending.numbers[session.control.paramID] = number }
        if let color { pending.colors[session.control.paramID] = color }
        switch session.control.paramID {
        case "base_color": pending.lastColourLikeCommit = .xy
        case "warmth":     pending.lastColourLikeCommit = .mirek
        default: break
        }
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
        // MUTUALLY EXCLUSIVE ON THE V2 PATH TOO (H2). `EffectsV2Body`'s
        // dictionary emits `parameters.color` and `parameters.color_temperature`
        // out of ONE body, and the bridge rejects a body that carries both.
        // The grouped path splits them into two PUTs; this one cannot — it has
        // a single body per light, sent through `gate.send(retry: false)`,
        // which SWALLOWS the rejection. So a window that changed colour AND
        // warmth on any v2-capable room (the PREFERRED path for every
        // bridge-native look) silently lost the colour, the warmth, and the
        // speed riding with them: the values were in the scopes, in the
        // defaults and on the screen, and the lights never moved.
        //
        // Only the LATER-committed member travels — the same answer the
        // grouped path gives by putting it in the second PUT, which is the one
        // that wins on the wall. `lastColourLikeCommit` is always set when
        // either field is present; the `?? .xy` is a shape default, never
        // reached with both fields non-nil.
        //
        // ACCEPTED DEBT: the APPLY-time `applyStudioEffectV2Parameters`
        // (StudioViewModel) still builds one body from a seeded colour AND a
        // seeded mirek together. That is pre-existing shipping behaviour on a
        // different path (start, not live edit) with a different failure mode
        // (the firmware default look, not a lost user gesture), and it is
        // deliberately left alone here rather than changed under a live-edit
        // fix. Recorded so the asymmetry is a decision, not an oversight.
        var v2ExclusiveXY = v2ColorXY
        var v2ExclusiveMirek = v2Mirek
        if v2ColorXY != nil, v2Mirek != nil {
            if (window.lastColourLikeCommit ?? .xy) == .xy {
                v2ExclusiveMirek = nil
            } else {
                v2ExclusiveXY = nil
            }
        }
        let v2Body: EffectsV2Body? = {
            guard let effectName,
                  v2Speed != nil || v2ExclusiveXY != nil || v2ExclusiveMirek != nil else {
                return nil
            }
            return EffectsV2Body(effect: effectName, speed: v2Speed,
                                 colorXY: v2ExclusiveXY, mirek: v2ExclusiveMirek)
        }()
        guard needsGrouped || v2Body != nil else { return }

        let gate = orchestrator.commandGate(for: bridgeID)
        let brightness = groupedBrightness

        // ORDER OF THE EXCLUSIVE PAIR. Two PUTs means the second one wins on
        // the wall, so the later-COMMITTED field has to go second. The order
        // used to be fixed (xy, then mirek), which meant a warmth value merely
        // carried forward in the window overwrote the colour the user had just
        // picked. `lastColourLikeCommit` is the window's record of what
        // actually happened; absent one (only ever one field present), the
        // order is irrelevant.
        var exclusive: [(xy: (Double, Double)?, mirek: Int?)] = []
        if let groupedXY { exclusive.append((xy: groupedXY, mirek: nil)) }
        if let groupedMirek { exclusive.append((xy: nil, mirek: groupedMirek)) }
        if exclusive.count == 2, window.lastColourLikeCommit == .xy {
            exclusive.reverse()   // the colour was committed later — it lands last
        }
        let orderedExclusive = exclusive
        let identity = session.identity
        let targetKey = identity.targetKey

        // The window is now IN FLIGHT: recorded here so a successor window can
        // carry its fields if the mailbox drops this closure (M3), cleared by
        // the closure the moment it actually runs.
        inFlightParamSends[targetKey] = window
        // Captured for the clear below — see `PendingStudioSend.token`.
        let sendToken = window.token

        await orchestrator.enqueueStudioRestWrite(roomID: roomID, bridgeID: bridgeID) { [weak self] scopeIsCurrent in
            // ONLY IF THE RECORD IS STILL THIS WINDOW'S (fifth review round).
            // An unkeyed clear here let a late-running W1 erase W2's record,
            // and W3 then carried none of W2's fields while replacing W2's
            // still-pending closure — the user's values were in the scopes, in
            // the defaults and on the screen, and never on the wire.
            if self?.inFlightParamSends[targetKey]?.token == sendToken {
                self?.inFlightParamSends[targetKey] = nil
            }
            // Cooperative cancellation before EVERY send, including the first
            // (packet 3) — Task.isCancelled is inert inside the mailbox's
            // unstructured flush task.
            //
            // AND the identity fence. `stillCurrent` is bound to the Studio
            // `RestScope` EPOCH, which only the `.appDriven` teardown bumps —
            // so for a bridge-native row a closure already enqueued when Stop
            // landed kept sending `effects_v2` bodies AFTER the `no_effect`
            // sweep, re-arming the firmware effect on lights the user had just
            // turned off. The scopes know: every teardown path retires the
            // instance, so `isCurrent` is false for exactly the runs whose
            // writes must not land, on every strategy.
            let stillCurrent: @MainActor () async -> Bool = {
                guard await scopeIsCurrent() else { return false }
                guard let self, self.valueScopes.isCurrent(identity) else { return false }
                return true
            }
            if needsGrouped, let groupedLightID {
                // MUTUALLY EXCLUSIVE CLIP FIELDS. `setGroupedLightEffect`
                // writes `color` and `color_temperature` into ONE body, and the
                // bridge rejects a grouped body carrying both — `try?` then
                // swallowed the rejection, so a window that changed colour AND
                // warmth silently lost its brightness too. They travel as two
                // PUTs, in COMMIT ORDER, with the dimming riding the first.
                if orderedExclusive.isEmpty {
                    guard await stillCurrent() else { return }
                    try? await api.setGroupedLightEffect(
                        id: groupedLightID, on: nil,
                        brightness: brightness, xy: nil, mirek: nil,
                        duration: transitionMs)
                } else {
                    for (index, field) in orderedExclusive.enumerated() {
                        guard await stillCurrent() else { return }
                        try? await api.setGroupedLightEffect(
                            id: groupedLightID, on: nil,
                            brightness: index == 0 ? brightness : nil,
                            xy: field.xy, mirek: field.mirek,
                            duration: transitionMs)
                    }
                }
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
