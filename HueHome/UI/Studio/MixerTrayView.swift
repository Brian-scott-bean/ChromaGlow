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
// Original description — a three-row header —
// (1) icon, name, room, and the revert/Perform/save/stop circles; (2) a
// horizontally scrolling badge lane (LIVE, coverage, beat chip, transport
// badge, room count); (3) the transport status sentence at full width — plus
// the content area: the CompositionEditorPanel for composition cards, or the
// essential StudioParamRow sliders for engine cards. Header heights are
// declared in `MixerTrayMetrics.headerBlockHeight`.
//
// The tray owns its transient state (drag offset, param sheet); expand /
// collapse-to-half mutate the `isMixerExpanded` binding; full dismissal and
// save-sheet population go through callbacks because their state must
// outlive the tray (StudioView presents the save sheet and the "Live
// Controls" pill).

import SwiftUI

struct StudioCustomizationHost: View {
    @Environment(UnifiedOrchestrator.self) private var orchestrator

    let vm: StudioViewModel
    @Binding var performVM: PerformanceViewModel?
    @Binding var activeCompositionTab: CompositionLayerTab
    @Binding var activeHarmonyRule: HarmonyRule
    @Binding var editingSwatch: SwatchEditItem?
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
                        hostContent
                    } header: {
                        hostHeader
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            // Auto-anchor: enabling a beat source scrolls the beat controls
            // into view. It now scrolls the REAL surface, not an inner box.
            .onChange(of: vm.activeCompositionBox?.reaction.source) { _, newSource in
                guard let newSource,
                      newSource == .beat || newSource == .onset || newSource == .tapTempo
                else { return }
                withAnimation(HueAnimation.fast) {
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
        .id(vm.currentRoomEffect?.cardID
            ?? vm.selectedRoom.map { StudioSelectionKey(room: $0).stableID })
    }

    // ── Pinned header ─────────────────────────────────────────────────

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

                headerRows(effect: effect, card: card)

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

    @ViewBuilder
    private func headerRows(effect: RunningEffect, card: StudioCard) -> some View {
                // ── Header (Perform grammar: 40pt circles, mono tags, bold name) ──
                //
                // Three rows, because one row cannot hold this much. Up to four
                // 40pt action circles plus an icon are ~200pt of incompressible
                // width; on a 360pt phone that left the name and the transport
                // status sentence a few points each, and they wrapped mid-word.
                // Row 1 is identity + actions, row 2 is a scrollable badge lane
                // (so N badges never squeeze the name), row 3 is the status
                // sentence at full width. Nothing is truncated.
                VStack(alignment: .leading, spacing: HueSpacing.xs) {

                    // ── Row 1: identity + actions ────────────────
                    HStack(spacing: 10) {
                        // Effect icon
                        ZStack {
                            Circle()
                                .fill(card.accentColor.opacity(0.20))
                                .frame(width: 40, height: 40)
                            Image(systemName: card.icon)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(card.accentColor)
                        }
                        .fixedSize()

                        VStack(alignment: .leading, spacing: 1) {
                            Text(card.name)
                                .font(HueFont.stageName)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .allowsTightening(true)
                                .foregroundStyle(StagePalette.ink)
                            Text(effect.room.name)
                                .font(HueFont.stageTag)
                                .tracking(1.2)
                                .textCase(.uppercase)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .allowsTightening(true)
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)

                        if case .composition(let presetID) = card.strategy,
                           presetID != StudioViewModel.composerStarterDraftPresetID,
                           card.compositionTier != .bridgeOptimized {
                            // Revert live edits back to the saved preset.
                            // (One-shots have no live box — nothing to revert.)
                            Button {
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
                        }

                        if case .composition = card.strategy,
                           card.compositionTier != .bridgeOptimized {
                            // Perform + Save need the live box and render loop a
                            // bridge-optimized one-shot never has — both buttons
                            // were silent no-ops there.
                            // Round 3 (C): enter the full-screen Perform surface —
                            // deck A inherits this live composition, uninterrupted.
                            Button {
                                guard let box = vm.activeCompositionBox else { return }
                                // R4-7: thread the backing preset so sequences can
                                // persist. The "+ Create" draft sentinel counts as
                                // unsaved — attaching a sequence to the hidden
                                // template would corrupt every future draft.
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
                                        Circle()
                                            .fill(HuePalette.amber.opacity(0.15))
                                    )
                            }
                            .buttonStyle(.plain)
                            .stageTapTarget(visual: 40)
                            .fixedSize()
                            .accessibilityLabel("Save composition")

                            // ── Save onto the bridge ──────────────
                            //
                            // First-class, beside the local save. This was
                            // reachable only through Palette → +N more →
                            // "Save as Hue dynamic scene" — which is a
                            // DIFFERENT feature: that one creates a Hue scene
                            // ChromaGlow can never stop, while this takes the
                            // manifest-backed path that survives a relaunch
                            // and keeps an exact Stop.
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
                            // Disabled ONLY while a save is in flight — a
                            // second tap mid-save is the overlapping-saves
                            // race. Deliberately NOT disabled when merely
                            // ineligible: a tap explains WHY a look cannot
                            // live on the bridge, which is more use than a
                            // dimmed control that says nothing.
                            .disabled(vm.isSavingLookToBridge)
                            .accessibilityLabel("Save to bridge")
                        }

                        // Stop control
                        Button {
                            Task { await vm.explicitStop(card) }
                            HapticManager.shared.light()
                        } label: {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(HuePalette.Noir.destructive)
                                .frame(width: 40, height: 40)
                                .background(
                                    Circle()
                                        .fill(HuePalette.Noir.destructive.opacity(0.15))
                                )
                        }
                        .buttonStyle(.plain)
                        .stageTapTarget(visual: 40)
                        .fixedSize()
                        .accessibilityLabel("Stop \(card.name)")
                    }

                    // ── Row 2: badge lane (scrolls rather than squeezes) ──
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            // Live indicator
                            StageBadge(text: "LIVE", style: .live)

                            // Partial firmware-effect coverage (R4 Effects port) —
                            // statusMessage is write-only, so the badge IS the signal.
                            if case .bridgeNative = card.strategy,
                               let cov = vm.effectCoverage[card.id],
                               !cov.isFull, !cov.isEmpty {
                                StageBadge(text: "\(cov.label.uppercased()) LIGHTS", style: .muted)
                            }

                            // Beat chip: engine cards read beat_mode/beat_per_cycle/
                            // beat_phase from the live param box every tick, so panel
                            // edits land without restarting the engine.
                            if case .appDriven = card.strategy {
                                BeatChipButton(
                                    capabilities: .global,
                                    binding: studioBeatBinding(forCardID: card.id),
                                    compact: true
                                )
                                .fixedSize()
                            }

                            // Scope / transport badge for Studio engine cards
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
                                    // Deliberately NOT disabled (packet 7
                                    // follow-up): the verdict is cached, and
                                    // taking this row was the only thing that
                                    // ever refreshed the cache — a stale "no"
                                    // therefore disabled its own remedy. The
                                    // reason footer below still explains.
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

                            // Active rooms count badge
                            if vm.runningEffects.count > 1 {
                                StageBadge(text: "\(vm.runningEffects.count) ROOMS", style: .amber)
                            }
                        }
                        // The trailing capsule otherwise kisses the screen edge.
                        .padding(.trailing, 2)
                    }
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                    .frame(height: MixerTrayMetrics.badgeLaneHeight)

                    // ── Row 3: transport status, full width ──────
                    if let status = transportStatus(for: effect, card: card) {
                        Text(status.text)
                            .font(HueFont.stageStatus)
                            .foregroundStyle(status.tint)
                            .multilineTextAlignment(.leading)
                            // Wrap on word breaks across the full tray width,
                            // instead of being squeezed into a badge column.
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, HueSpacing.screenH)
                .padding(.top, HueSpacing.md)
                .padding(.bottom, HueSpacing.sm)
    }

    // ── Scrolling content ─────────────────────────────────────────────

    @ViewBuilder
    private var hostContent: some View {
        if let effect = vm.currentRoomEffect {
            let card = effect.card

            VStack(spacing: 0) {
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
                    CompositionEditorPanel(
                        vm: vm,
                        activeCompositionTab: $activeCompositionTab,
                        activeHarmonyRule: $activeHarmonyRule,
                        editingSwatch: $editingSwatch
                    )
                    .padding(.horizontal, HueSpacing.screenH)
                    .padding(.top, HueSpacing.md)
                    .padding(.bottom, HueSpacing.md)
                } else {
                    // ── Every param for this card, in one continuous column:
                    // essentials and the color row first, then the rest under an
                    // ADVANCED caption. No reveal, no sheet — you scroll down and
                    // the controls are there.
                    let inlineParams = MixerTrayMetrics.inlineParams(for: card)
                    let overflowParams = MixerTrayMetrics.overflowParams(for: card)

                    if !inlineParams.isEmpty || !overflowParams.isEmpty {
                        // FLATTENED, same reason as the composition panel.
                        VStack(spacing: HueSpacing.md) {
                            ForEach(inlineParams) { param in
                                StudioParamRow(param: param, cardID: card.id, vm: vm)
                            }

                            // A landmark in the page, not a gate. The caption tells
                            // the user what they have scrolled into; it hides
                            // nothing.
                            if !overflowParams.isEmpty {
                                Text("ADVANCED")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .tracking(1.2)
                                    .foregroundStyle(.white.opacity(0.38))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 6)
                                    .id("studioAdvancedControls")
                                ForEach(overflowParams) { param in
                                    StudioParamRow(param: param, cardID: card.id, vm: vm)
                                }
                            }
                        }
                        .padding(.horizontal, HueSpacing.screenH)
                        .padding(.top, HueSpacing.md)
                        .padding(.bottom, HueSpacing.md)
                    }
                }
            }
        }
    }


    // ── Beat binding for Studio engine cards ─────────────────

    /// Routes beat-panel edits through commitParam so they land on the exact
    /// running instance (fenced on identity captured at call time), persist as
    /// the card's next-start defaults, AND push live to the running engine's
    /// param box — writing the box directly would be clobbered by the next
    /// slider change.
    private func studioBeatBinding(forCardID cardID: String) -> Binding<BeatBinding> {
        Binding(
            get: { BeatBinding.fromStudioValues(vm.paramNumbers(for: cardID)) },
            set: { newValue in
                for (key, value) in newValue.studioValues {
                    vm.commitParam(cardID: cardID, paramID: key, value: value)
                }
            }
        )
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
