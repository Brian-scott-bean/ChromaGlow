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

extension StudioViewModel {

    // ── Identity install / teardown helpers ─────────────────────

    /// Mint the exact identity for a look that just started on `room`, and
    /// register it with the value scopes (seeding scope 2 from the card's
    /// persisted defaults). Called from each `apply()` arm at the moment the
    /// `RunningEffect` row is installed.
    func installRunningIdentity(room: RoomDisplayItem,
                                card: StudioCard,
                                execution: CustomizationExecution) -> RunningLookIdentity {
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
        paramSendTasks[effect.identity.targetKey]?.cancel()
        paramSendTasks[effect.identity.targetKey] = nil
        valueScopes.stopRunning(effect.identity)
        sessionMemory.clear(for: effect.identity.targetKey)
        bumpLiveValuesTick()
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
    /// one, the widest authoring gamut otherwise, plus partial coverage for
    /// the local truth chip.
    func colorCapabilityContext(for effect: RunningEffect) -> ColorCapabilityContext {
        var context = ColorCapabilityContext()
        guard let lights = orchestrator?.cachedRawLights(for: effect.room.bridgeID),
              !effect.lightIDs.isEmpty else { return context }
        let idSet = Set(effect.lightIDs)
        let scoped = lights.filter { idSet.contains($0.id) }
        guard !scoped.isEmpty else { return context }
        let colorCapable = scoped.filter { $0.color != nil }
        context.coverage = CapabilityCoverage(
            supported: colorCapable.count, total: scoped.count, evidence: .known)
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
        paramSendTasks[effect.identity.targetKey]?.cancel()
        paramSendTasks[effect.identity.targetKey] = nil
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

    // ── Debounced bridge sends ──────────────────────────────────

    /// One pending send per exact running target. A newer edit on the SAME
    /// target replaces the older one (latest wins); another target's pending
    /// send is untouched. After the debounce sleep the send re-fences on the
    /// captured identity — Stop, Reset, replacement, or a rekey between
    /// schedule and fire drops it. Inside the mailbox closure the existing
    /// `stillCurrent()` epoch probes keep covering the post-enqueue window.
    private func scheduleBridgeSend(session: StudioParamSession,
                                    number: Double?, color: Color?) {
        let targetKey = session.identity.targetKey
        paramSendTasks[targetKey]?.cancel()
        paramSendTasks[targetKey] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard self.valueScopes.isCurrent(session.identity) else { return }
            await self.performBridgeSend(session: session, number: number, color: color)
        }
    }

    private func performBridgeSend(session: StudioParamSession,
                                   number: Double?, color: Color?) async {
        // No orchestrator or no captured client: nothing to send — the
        // committed value already reached the scopes and the engine box.
        guard let orchestrator, let api = session.api else { return }
        let roomID = session.room.id
        let bridgeID = session.room.bridgeID
        let paramID = session.control.paramID

        // Transition (Smoothness) is read from the instance's CURRENT live
        // values at fire time — it shapes this send's dynamics.duration.
        let live = valueScopes.live(for: session.identity)
        let transitionDefault = (effectCards + liveModeCards)
            .first { $0.id == session.control.cardID }?
            .params.first { $0.id == "transition" }?.defaultValue ?? 400
        let transitionMs = Int(live.numbers["transition"] ?? transitionDefault)

        if let color {
            // Color sends: only base_color re-parameterizes a bridge-native
            // effect. Other color params (Live flash/ambient colors) reach
            // their engines through the box push — no bridge call here.
            guard paramID == "base_color", let effectName = session.bridgeNativeEffectName else { return }
            let uiColor = UIColor(color)
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
            uiColor.getHue(&h, saturation: &s, brightness: &b, alpha: nil)
            let xy = HueColorUtils.xyFrom(hue: Double(h), saturation: Double(s), brightness: Double(b))
            if !session.v2CapableLightIDs.isEmpty {
                let gate = orchestrator.commandGate(for: bridgeID)
                let capable = session.v2CapableLightIDs
                let point = CGPoint(x: xy.x, y: xy.y)
                await orchestrator.enqueueStudioRestWrite(roomID: roomID, bridgeID: bridgeID) { stillCurrent in
                    // Cooperative cancellation before EVERY send, including the
                    // first light (packet 3) — Task.isCancelled is inert inside
                    // the mailbox's unstructured flush task.
                    for id in capable {
                        guard await stillCurrent() else { return }
                        _ = await gate.send(retry: false) {
                            try await api.setLightEffectV2(
                                id: id, body: EffectsV2Body(effect: effectName, colorXY: point))
                        }
                    }
                }
            } else if let groupedLightID = session.groupedLightID {
                // Legacy grouped fallback — PRESERVED shipping behavior for
                // v2-incapable rooms. Whether it visibly fights the running
                // firmware effect is a hardware-pending question; the control
                // is classified as an approximation there, not deleted.
                await orchestrator.enqueueStudioRestWrite(roomID: roomID, bridgeID: bridgeID) { _ in
                    try? await api.setGroupedLightEffect(
                        id: groupedLightID, on: nil,
                        brightness: nil, xy: (xy.x, xy.y), mirek: nil,
                        duration: transitionMs)
                }
            }
            return
        }

        guard let number else { return }
        switch paramID {
        case "brightness":
            guard let groupedLightID = session.groupedLightID else { return }
            await orchestrator.enqueueStudioRestWrite(roomID: roomID, bridgeID: bridgeID) { _ in
                try? await api.setGroupedLightEffect(
                    id: groupedLightID, on: nil,
                    brightness: number, xy: nil, mirek: nil,
                    duration: transitionMs)
            }

        case "warmth":
            let mirek = Int(number.rounded())
            if let effectName = session.bridgeNativeEffectName,
               !session.v2CapableLightIDs.isEmpty {
                // Re-parameterize the EFFECT's color_temperature per-light —
                // a grouped mirek PUT fights the running firmware effect (R5).
                let gate = orchestrator.commandGate(for: bridgeID)
                let capable = session.v2CapableLightIDs
                await orchestrator.enqueueStudioRestWrite(roomID: roomID, bridgeID: bridgeID) { stillCurrent in
                    for id in capable {
                        guard await stillCurrent() else { return }
                        _ = await gate.send(retry: false) {
                            try await api.setLightEffectV2(
                                id: id, body: EffectsV2Body(effect: effectName, mirek: mirek))
                        }
                    }
                }
            } else if let groupedLightID = session.groupedLightID {
                // Grouped v1 fallback — preserved; see the base_color note.
                await orchestrator.enqueueStudioRestWrite(roomID: roomID, bridgeID: bridgeID) { _ in
                    try? await api.setGroupedLightEffect(
                        id: groupedLightID, on: nil,
                        brightness: nil, xy: nil, mirek: mirek,
                        duration: transitionMs)
                }
            }

        case "speed":
            // Bridge-native only, v2-capable only: there is no legacy speed
            // path — on v1-only rooms this send does not exist, and the
            // capability layer must say so rather than fake it.
            guard let effectName = session.bridgeNativeEffectName,
                  !session.v2CapableLightIDs.isEmpty else { return }
            let clamped = min(1.0, max(0.0, number / 100.0))
            let gate = orchestrator.commandGate(for: bridgeID)
            let capable = session.v2CapableLightIDs
            await orchestrator.enqueueStudioRestWrite(roomID: roomID, bridgeID: bridgeID) { stillCurrent in
                for id in capable {
                    guard await stillCurrent() else { return }
                    _ = await gate.send(retry: false) {
                        try await api.setLightEffectV2(
                            id: id, body: EffectsV2Body(effect: effectName, speed: clamped))
                    }
                }
            }

        case "transition", "saturation":
            // Transition shapes SUBSEQUENT sends' duration (no command of its
            // own); saturation has no bridge-native runtime consumer.
            break

        default:
            // App-driven engine tunables are read from the live box the
            // committed push already updated — no bridge call.
            break
        }
    }
}
