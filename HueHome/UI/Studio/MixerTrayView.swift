// MixerTrayView.swift
// CastChroma — Zone C customization host (extracted from StudioView in Round 4,
// R4-2; converted from a bottom-anchored tray to an inline region in Track A C5).
//
// FILENAME NOTE: this file holds `StudioCustomizationHost`, not `MixerTrayView`.
// Renaming the FILE is a `project.pbxproj` edit (the app target uses an explicit
// sources phase), which this packet forbids. The rename is a queued chore.
//
// The inline customization region below the permanently mounted rolodex. It owns
// exactly ONE vertical scroll surface; the header rides as a pinned section
// header so Stop / Perform / Save / Revert and "Back to decks" stay reachable at
// any scroll offset. Horizontal scrollers (the badge lane, composer chips) and
// StageKit drag controls keep their own containers — horizontal-in-vertical
// nests cleanly and is not the conflict this change exists to remove.
//
// What the overlay era left behind, and why it is gone: the tray was a
// fixed-height box, so its content needed inner `GeometryReader { ScrollViewReader
// { ScrollView } }` wrappers to be reachable at all, and it mounted a
// full-screen invisible scrim that swallowed the next drag on the wheel. Both
// are deleted. `isMixerExpanded` was a HEIGHT job; full-region there is no
// height to expand, so only its advanced-params reveal survives, as host-local
// state.
//
// Slice 2: the pinned header is ONE quiet identity line (StudioIdentityHeader)
// plus "Back to decks"; the old badge lane, action circles, and status
// sentence live in the operational panel that expands from the identity,
// inline in the same scroll. Content is the per-look StudioBoardView for
// engine/effect cards, or the CompositionEditorPanel for compositions.
//
// The tray owns its transient state (drag offset, param sheet); expand /
// collapse-to-half mutate the `isMixerExpanded` binding; full dismissal and
// save-sheet population go through callbacks because their state must
// outlive the tray (StudioView presents the save sheet and the "Live
// Controls" pill).

import SwiftUI

struct StudioCustomizationHost: View {
    @Environment(UnifiedOrchestrator.self) private var orchestrator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let vm: StudioViewModel
    @Binding var performVM: PerformanceViewModel?
    /// Return to the card decks. Owned by StudioView (it also owns the
    /// "Live Controls" pill that comes back here).
    let onBackToDecks: () -> Void
    /// Populate + present the composition save sheet (state lives in StudioView).
    let onSaveComposition: (StudioCard) -> Void
    /// Transport switch for a running composition (in-flight guard lives in StudioView).
    let onTransportSwitch: (RunningEffect, Bool) -> Void

    // No disclosure state. `showAdvanced` and `showParamSheet` are GONE: the host
    // is one continuous page, so every control for the selected card is simply
    // rendered and the user scrolls to it. A reveal affordance here was the
    // build-47 row-36 defect in both its forms — the sheet it opened was a
    // detached surface, and the inline branch it gated was never reachable
    // because nothing ever wrote `showAdvanced = true`.

    /// ONE vertical scroll surface for the whole customization region.
    ///
    /// The tray used to be a fixed-height box, so its content needed its own
    /// inner `GeometryReader { ScrollViewReader { ScrollView } }` to be
    /// reachable. Inline, that inner scroller is what would fight the parent —
    /// so the wrappers are gone and this is the only vertical scroller here.
    /// The header rides along as a pinned section header, which keeps Stop /
    /// Perform / Save / Revert and "Back to decks" reachable at any offset.
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        hostContent(proxy: proxy)
                    } header: {
                        hostHeader
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            // Auto-anchor: enabling a beat source scrolls the beat controls
            // into view. It now scrolls the REAL surface, not an inner box.
            .onChange(of: vm.composerEditSession()?.box.reaction.source) { _, newSource in
                guard let newSource,
                      newSource == .beat || newSource == .onset || newSource == .tapTempo
                else { return }
                withAnimation(reduceMotion ? nil : HueAnimation.fast) {
                    proxy.scrollTo("reactionBeatControls", anchor: .center)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: HueRadius.xl, style: .continuous)
                .fill(StagePalette.surface)
        )
        .clipShape(RoundedRectangle(cornerRadius: HueRadius.xl))
        .overlay(
            RoundedRectangle(cornerRadius: HueRadius.xl, style: .continuous)
                .strokeBorder(StagePalette.line, lineWidth: 1)
        )
        .padding(.horizontal, HueSpacing.sm)
        // Exact selection identity, not a bare room id: two bridges sharing a
        // Hue room id produced the SAME view identity, so SwiftUI reused this
        // subtree across a real room change and carried the previous bridge's
        // state into it.
        //
        // Slice 3: the running branch used to key on the bare `cardID`, so the
        // SAME look on two targets (one preset on two rooms, or on a room and
        // a zone sharing an id) shared one view identity and carried the
        // first target's gesture/focus state into the second. The target key
        // (bridge + kind + group + card + execution, no generation) is the
        // identity the comment above always claimed.
        .id(vm.currentRoomEffect.map { $0.identity.targetKey.stableID }
            ?? vm.selectedRoom.map { StudioSelectionKey(room: $0).stableID })
    }

    // ── Pinned header (Slice 2: quiet — spec §13) ─────────────────────
    //
    // The three-row header is retired. What pins now is "Back to decks" and
    // ONE calm identity line — PARTY · LIVING ROOM › — plus the exact
    // selected-target Stop. Everything the old badge lane and action circles
    // carried lives in the operational panel that expands FROM the identity,
    // inline in the host's one scroll.

    @ViewBuilder
    private var hostHeader: some View {
        if let effect = vm.currentRoomEffect {
            let card = effect.card

            VStack(spacing: 0) {
                // Replaces the grab bar. The capsule's only job was "drag or tap
                // to dismiss", and dismissal is now a named destination rather
                // than a gesture that competed with every child control.
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                    Text("Back to decks")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                }
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, HueSpacing.screenH)
                .frame(height: MixerTrayMetrics.backToDecksRowHeight)
                .contentShape(Rectangle())
                .onTapGesture {
                    onBackToDecks()
                    HapticManager.shared.light()
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Back to decks")

                StudioIdentityHeader(
                    card: card,
                    roomName: effect.room.name,
                    detailsOpen: vm.sessionMemory.binding(
                        for: effect.identity.targetKey, \.identityPanelOpen),
                    onStop: {
                        Task { await vm.explicitStop(card) }
                        HapticManager.shared.medium()
                    }
                )

                // ── Separator ────────────────────────────────
                Rectangle()
                    .fill(StagePalette.line)
                    .frame(height: 0.5)
                    .padding(.horizontal, HueSpacing.screenH)
            }
            // Opaque: a pinned header scrolls content underneath itself.
            .background(StagePalette.surface)
        }
    }

    // ── Operational panel (expands from the identity) ─────────────────
    //
    // Transport truth, coverage, room count, the composition action circles
    // (Revert / Perform / Save / Save-to-bridge), Reset to Defaults for
    // engine and effect cards, and the Beat shortcut. Status lives HERE,
    // behind the tappable identity, not permanently in the header — and
    // appears beside a control only where it materially changes it.

    @ViewBuilder
    private func operationalPanel(effect: RunningEffect, card: StudioCard,
                                  proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: HueSpacing.sm) {

            // Truth line: live state, coverage, transport, room count.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    StageBadge(text: "LIVE", style: .live)

                    if case .bridgeNative = card.strategy,
                       let cov = vm.effectCoverage[card.id],
                       !cov.isFull, !cov.isEmpty {
                        StageBadge(text: "\(cov.label.uppercased()) LIGHTS", style: .muted)
                    }

                    if case .appDriven = card.strategy {
                        StageBadge(text: effect.isEntertainment
                                       ? TransportVocabulary.badgeStreaming
                                       : TransportVocabulary.badgeRoom,
                                   style: effect.isEntertainment ? .amber : .muted)
                    } else if case .composition = card.strategy {
                        Menu {
                            // Built on open, so the Keychain read in
                            // `entertainmentAvailability` is not per-frame.
                            let availability = orchestrator.entertainmentAvailability(for: effect.room)

                            Button {
                                onTransportSwitch(effect, true)
                            } label: {
                                Label(TransportVocabulary.streamingMenuLabel, systemImage: "bolt.fill")
                            }
                            // Deliberately NOT disabled (packet 7 follow-up):
                            // the verdict is cached, and taking this row was
                            // the only thing that ever refreshed the cache — a
                            // stale "no" therefore disabled its own remedy.
                            Button {
                                onTransportSwitch(effect, false)
                            } label: {
                                Label(TransportVocabulary.roomOnlyMenuLabel, systemImage: "iphone")
                            }

                            if let reason = availability.reason {
                                Section(reason) { EmptyView() }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(composerTransportBadgeText(for: effect))
                                    .font(HueFont.stageTag)
                                    .tracking(0.6)
                                    .lineLimit(1)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 7, weight: .bold))
                                    .opacity(0.82)
                            }
                            .foregroundStyle(composerIsStreaming(effect) ? HuePalette.amber : .white.opacity(0.75))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 5)
                            .background(
                                Capsule().fill(
                                    composerIsStreaming(effect)
                                        ? HuePalette.amber.opacity(0.15)
                                        : Color.white.opacity(0.10)
                                )
                            )
                            .fixedSize()
                            .stageTapTarget(visual: 26)
                        }
                        .buttonStyle(.plain)
                    }

                    if vm.runningEffects.count > 1 {
                        StageBadge(text: "\(vm.runningEffects.count) ROOMS", style: .amber)
                    }
                }
                .padding(.trailing, 2)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .frame(height: MixerTrayMetrics.badgeLaneHeight)

            // Transport status sentence, full width (composition cards).
            if let status = transportStatus(for: effect, card: card) {
                Text(status.text)
                    .font(HueFont.stageStatus)
                    .foregroundStyle(status.tint)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Actions.
            HStack(spacing: 10) {
                if case .composition(let presetID) = card.strategy,
                   presetID != StudioViewModel.composerStarterDraftPresetID,
                   card.compositionTier != .bridgeOptimized {
                    // Revert live edits back to the saved preset.
                    // (One-shots have no live box — nothing to revert.)
                    Button {
                        // A typed draft commits on focus loss; resigning the
                        // keyboard FIRST makes the order deterministic — the
                        // draft lands, then the Revert wins (review round, A-4).
                        hideMixerKeyboard()
                        vm.revertActiveComposition()
                        HapticManager.shared.light()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.75))
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .stageTapTarget(visual: 40)
                    .fixedSize()
                    .accessibilityLabel("Revert to saved")
                    .accessibilityHint("Restores the saved composition on this room")
                }

                if case .composition = card.strategy,
                   card.compositionTier != .bridgeOptimized {
                    // Perform + Save need the live box and render loop a
                    // bridge-optimized one-shot never has.
                    Button {
                        // The session's box — the exact running instance this
                        // header belongs to — never the selection's (A-9).
                        guard let box = vm.composerEditSession(for: effect)?.box else { return }
                        // R4-7: thread the backing preset so sequences can
                        // persist. The "+ Create" draft sentinel counts as
                        // unsaved.
                        var presetID: UUID? = nil
                        if case .composition(let pid) = card.strategy,
                           pid != StudioViewModel.composerStarterDraftPresetID {
                            presetID = pid
                        }
                        performVM = PerformanceViewModel(
                            orchestrator: orchestrator,
                            room: effect.room,
                            liveBox: box,
                            liveName: card.name,
                            presetID: presetID,
                            compositionStore: vm.compositionStore
                        )
                        HapticManager.shared.medium()
                    } label: {
                        Image(systemName: "slider.vertical.3")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.black.opacity(0.85))
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(HuePalette.amber))
                    }
                    .buttonStyle(.plain)
                    .stageTapTarget(visual: 40)
                    .fixedSize()
                    .accessibilityLabel("Perform")

                    Button {
                        onSaveComposition(card)
                        HapticManager.shared.light()
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 12))
                            .foregroundStyle(HuePalette.amber)
                            .frame(width: 40, height: 40)
                            .background(
                                Circle().fill(HuePalette.amber.opacity(0.15))
                            )
                    }
                    .buttonStyle(.plain)
                    .stageTapTarget(visual: 40)
                    .fixedSize()
                    .accessibilityLabel("Save composition")

                    // ── Save onto the bridge (manifest-backed, exact Stop) ──
                    Button {
                        Task { await vm.saveActiveLookToBridge(card) }
                        HapticManager.shared.light()
                    } label: {
                        if vm.isSavingLookToBridge {
                            ProgressView()
                                .tint(HuePalette.amber)
                                .scaleEffect(0.6)
                                .frame(width: 40, height: 40)
                                .background(
                                    Circle().fill(HuePalette.amber.opacity(0.15))
                                )
                        } else {
                            Image(systemName: "externaldrive.badge.checkmark")
                                .font(.system(size: 12))
                                .foregroundStyle(vm.canSaveActiveLookToBridge
                                                 ? HuePalette.amber : .white.opacity(0.3))
                                .frame(width: 40, height: 40)
                                .background(
                                    Circle().fill(HuePalette.amber.opacity(
                                        vm.canSaveActiveLookToBridge ? 0.15 : 0.05))
                                )
                        }
                    }
                    .buttonStyle(.plain)
                    .stageTapTarget(visual: 40)
                    .fixedSize()
                    // Disabled ONLY while a save is in flight; not when
                    // merely ineligible — a tap explains WHY.
                    .disabled(vm.isSavingLookToBridge)
                    .accessibilityLabel("Save to bridge")
                } else {
                    // Effects / Live: overall Reset for exactly THIS running
                    // instance (the accessible, non-gesture reset path).
                    Button {
                        Task { await vm.resetParams(for: card) }
                        HapticManager.shared.light()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Reset to Defaults")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.horizontal, 12)
                        .frame(height: 40)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Reset \(card.name) to defaults in \(effect.room.name)")
                }

                if case .appDriven = card.strategy {
                    // Shortcut to the in-page Beat instrument — scrolls the
                    // one real surface; never a popover-only path (spec §19).
                    Button {
                        withAnimation(reduceMotion ? nil : HueAnimation.fast) {
                            proxy.scrollTo("reactionBeatControls", anchor: .center)
                        }
                        HapticManager.shared.light()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "metronome.fill")
                                .font(.system(size: 11))
                            Text("BEAT")
                                .font(HueFont.stageTag)
                                .tracking(0.8)
                        }
                        .foregroundStyle(HuePalette.amber)
                        .padding(.horizontal, 12)
                        .frame(height: 40)
                        .background(Capsule().fill(HuePalette.amber.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Go to beat controls")
                }

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, HueSpacing.screenH)
        .padding(.top, HueSpacing.sm)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // ── Scrolling content ─────────────────────────────────────────────

    @ViewBuilder
    private func hostContent(proxy: ScrollViewProxy) -> some View {
        if let effect = vm.currentRoomEffect {
            let card = effect.card

            VStack(spacing: 0) {
                // The operational panel expands from the identity header —
                // part of the same scroll, never a sheet.
                if vm.sessionMemory.state(for: effect.identity.targetKey).identityPanelOpen {
                    operationalPanel(effect: effect, card: card, proxy: proxy)
                }
                if case .composition = card.strategy,
                   card.compositionTier == .bridgeOptimized {
                    // One-shot scene: no live box, so the editor's bindings
                    // would write to nothing (or, pre-fix, another room's box).
                    VStack(spacing: HueSpacing.sm) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(.white.opacity(0.35))
                        Text("Applied in one shot — a still scene has no live controls.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                        Text("Add it to a room from the Scenes tab's Studio shelf to keep it on the bridge.")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, HueSpacing.screenH * 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if case .composition = card.strategy {
                    // FLATTENED. The GeometryReader / ScrollViewReader /
                    // ScrollView wrappers here existed only because the tray was
                    // a fixed-height box; inline they would be a second vertical
                    // scroller fighting the parent. The ScrollViewReader and the
                    // beat auto-anchor moved up to the host's single surface.
                    // The layer tab is this TARGET's working memory, not a
                    // StudioView-wide slot: keyed by the exact running
                    // identity (bridge + group + kind + card), so the same
                    // preset on two rooms edits two layers.
                    CompositionEditorPanel(
                        vm: vm,
                        orchestrator: orchestrator,
                        activeCompositionTab: vm.sessionMemory.binding(
                            for: effect.identity.targetKey, \.activeCompositionTab),
                        // The chip is THIS target's memory; a user tap rewrites
                        // the palette through the fence (A-1 / A-2).
                        activeHarmonyRule: Binding(
                            get: { vm.harmonyRule(for: effect) },
                            set: { vm.setHarmonyRule($0) }),
                        onDismissKeyboard: hideMixerKeyboard
                    )
                    .padding(.horizontal, HueSpacing.screenH)
                    .padding(.top, HueSpacing.md)
                    .padding(.bottom, HueSpacing.md)
                } else if effect.recovered == nil {
                    // ── The per-look board (Slice 2): hero + primary +
                    // supporting controls on the invisible grid, inline B+
                    // color, and the Beat instrument — one continuous column,
                    // no ADVANCED caption, no reveal, no sheet. Every control
                    // the look genuinely has is on this one page.
                    StudioBoardView(card: card, effect: effect, vm: vm)
                        .padding(.horizontal, HueSpacing.screenH)
                        .padding(.top, HueSpacing.md)
                        .padding(.bottom, HueSpacing.md)
                }
            }
        }
    }


    /// The Room-mode sentence for this room: the measured cadence combined
    /// with whatever transport degradation the orchestrator recorded for this
    /// EXACT room on this EXACT bridge (packet 5).
    ///
    /// `effect.room.bridgeID` — never a default — for the same reason packet 4
    /// deleted the global cadence fallback: two rooms can share an ID on
    /// different bridges, and showing one's reason under the other's card is
    /// exactly the dishonesty this is meant to remove. Reading the store here
    /// is also what registers the Observation dependency, so the sentence
    /// refreshes when only the reason changes.
    private func roomModeStatusText(for effect: RunningEffect) -> String {
        let degradation = orchestrator.compositionDegradation(
            roomID: effect.room.id, bridgeID: effect.room.bridgeID)
        return TransportVocabulary.roomModeStatus(
            fallback: degradation?.fallbackReason,
            largeRoom: degradation?.isLargeRoom ?? false,
            liveSeconds: vm.activeRESTCadenceForSelectedRoom)
    }

    /// The one-sentence transport status under the header, or nil when the
    /// running transport is exactly what was asked for and needs no comment.
    /// Composition cards only — engine cards say it all in the scope badge.
    private func transportStatus(
        for effect: RunningEffect,
        card: StudioCard
    ) -> (text: String, tint: Color)? {
        guard case .composition = card.strategy else { return nil }

        // Exact bridge+room, not the room-only aggregate: under a duplicate room
        // id across two bridges the aggregate answers nil on disagreement, which
        // rendered this sentence against the wrong bridge's playback.
        if orchestrator.compositionTransport(
            bridgeID: effect.room.bridgeID, roomID: effect.room.id) == .bridgeStored {
            return (TransportVocabulary.bridgeStoredStatus,
                    HuePalette.amber.opacity(0.9))
        }
        // Packet 5: the exact-keyed degradation state is the authority when it
        // has something to say — it survives a mid-session failover, it keeps
        // the fallback cause and the rolling-delivery fact as separate truths,
        // and it is generation-fenced. `transportFallback` stays as the
        // apply-time snapshot for the streaming case it already covered.
        let degradation = orchestrator.compositionDegradation(
            roomID: effect.room.id, bridgeID: effect.room.bridgeID)
        if let degradation, degradation.fallbackReason != nil {
            return (roomModeStatusText(for: effect), HuePalette.amber.opacity(0.75))
        }
        if effect.transportFallback {
            return (TransportVocabulary.fallbackStatus,
                    HuePalette.amber.opacity(0.75))
        }
        if !effect.isEntertainment, card.compositionTier == .runtimeOnly {
            // Covers both the plain cadence sentence and the large-room
            // rotation sentence — `roomModeStatus` picks between them.
            return (roomModeStatusText(for: effect), .white.opacity(0.48))
        }
        return nil
    }

    /// The badge names the play mode in the same grammar engine cards use
    /// (TransportVocabulary badges). It stays short because the nuance — why
    /// we fell back, what bridge-stored means — lives in `transportStatus`'s
    /// sentence directly beneath it, where there is room to say it properly.
    private func composerTransportBadgeText(for effect: RunningEffect) -> String {
        // Bridge-stored animations run on the bridge hardware itself. Exact
        // bridge+room — see `transportStatus`.
        if orchestrator.compositionTransport(
            bridgeID: effect.room.bridgeID, roomID: effect.room.id) == .bridgeStored {
            return TransportVocabulary.badgeBridge
        }
        return composerIsStreaming(effect)
            ? TransportVocabulary.badgeStreaming
            : TransportVocabulary.badgeRoom
    }

    /// Live transport for a composition card — the orchestrator's per-room
    /// truth survives a mid-session DTLS→REST failover; the RunningEffect's
    /// `isEntertainment` is a snapshot from apply time and does not.
    private func composerIsStreaming(_ effect: RunningEffect) -> Bool {
        if let transport = orchestrator.compositionTransport(
            bridgeID: effect.room.bridgeID, roomID: effect.room.id) {
            return transport == .entertainment
        }
        return effect.isEntertainment
    }

    private func hideMixerKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }
}
