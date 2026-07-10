// MixerTrayView.swift
// CastChroma — Zone C mixer tray (extracted from StudioView in Round 4, R4-2).
//
// The bottom tray that springs up when an effect runs: a three-row header —
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

struct MixerTrayView: View {
    @Environment(UnifiedOrchestrator.self) private var orchestrator

    let vm: StudioViewModel
    @Binding var isMixerExpanded: Bool
    @Binding var performVM: PerformanceViewModel?
    @Binding var activeCompositionTab: CompositionLayerTab
    @Binding var activeHarmonyRule: HarmonyRule
    @Binding var editingSwatch: SwatchEditItem?
    /// Full dismissal (tray → "Live Controls" pill). Owned by StudioView.
    let onCollapse: () -> Void
    /// Populate + present the composition save sheet (state lives in StudioView).
    let onSaveComposition: (StudioCard) -> Void
    /// Transport switch for a running composition (in-flight guard lives in StudioView).
    let onTransportSwitch: (RunningEffect, Bool) -> Void

    @State private var mixerDragOffset: CGFloat = 0
    @State private var showParamSheet = false

    var body: some View {
        mixerTray
            .offset(y: mixerDragOffset)
            .gesture(mixerDismissDragGesture)
    }

    private var mixerTray: some View {
        let effect = vm.currentRoomEffect

        return VStack(spacing: 0) {
            if let effect {
                let card = effect.card

                // Full-width, taller grab-bar hit area: tap anywhere on the top bar to close.
                Capsule()
                    .fill(Color.white.opacity(0.28))
                    .frame(width: 36, height: 4)
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onCollapse()
                        HapticManager.shared.light()
                    }

                // ── Header (Perform grammar: 34pt circles, mono tags, bold name) ──
                //
                // Three rows, because one row cannot hold this much. Up to four
                // 34pt action circles plus an icon are ~170pt of incompressible
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
                                .frame(width: 34, height: 34)
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
                                    .frame(width: 34, height: 34)
                                    .background(Circle().fill(Color.white.opacity(0.08)))
                            }
                            .buttonStyle(.plain)
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
                                    .frame(width: 34, height: 34)
                                    .background(Circle().fill(HuePalette.amber))
                            }
                            .buttonStyle(.plain)
                            .fixedSize()
                            .accessibilityLabel("Perform")

                            Button {
                                onSaveComposition(card)
                                HapticManager.shared.light()
                            } label: {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.system(size: 12))
                                    .foregroundStyle(HuePalette.amber)
                                    .frame(width: 34, height: 34)
                                    .background(
                                        Circle()
                                            .fill(HuePalette.amber.opacity(0.15))
                                    )
                            }
                            .buttonStyle(.plain)
                            .fixedSize()
                            .accessibilityLabel("Save composition")
                        }

                        // Stop control
                        Button {
                            Task { await vm.explicitStop(card) }
                            HapticManager.shared.light()
                        } label: {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(HuePalette.Noir.destructive)
                                .frame(width: 34, height: 34)
                                .background(
                                    Circle()
                                        .fill(HuePalette.Noir.destructive.opacity(0.15))
                                )
                        }
                        .buttonStyle(.plain)
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
                                StageBadge(text: effect.isEntertainment ? "ENT AREA" : "ROOM",
                                           style: effect.isEntertainment ? .amber : .muted)
                            } else if case .composition = card.strategy {
                                Menu {
                                    // Built on open, so the Keychain read in
                                    // `entertainmentAvailability` is not per-frame.
                                    let availability = orchestrator.entertainmentAvailability(for: effect.room)

                                    Button {
                                        onTransportSwitch(effect, true)
                                    } label: {
                                        Label("Entertainment Area (Streaming)", systemImage: "bolt.fill")
                                    }
                                    .disabled(!availability.canStream)

                                    Button {
                                        onTransportSwitch(effect, false)
                                    } label: {
                                        Label("Room Only (REST)", systemImage: "iphone")
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
                                    .padding(.vertical, 2)
                                    .background(
                                        Capsule().fill(
                                            composerIsStreaming(effect)
                                                ? HuePalette.amber.opacity(0.15)
                                                : Color.white.opacity(0.10)
                                        )
                                    )
                                    .fixedSize()
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

                // ── Separator ────────────────────────────────
                Rectangle()
                    .fill(StagePalette.line)
                    .frame(height: 0.5)
                    .padding(.horizontal, HueSpacing.screenH)

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
                    GeometryReader { scrollGeo in
                        ScrollViewReader { proxy in
                            ScrollView(showsIndicators: false) {
                                CompositionEditorPanel(
                                    vm: vm,
                                    isExpanded: isMixerExpanded,
                                    activeCompositionTab: $activeCompositionTab,
                                    activeHarmonyRule: $activeHarmonyRule,
                                    editingSwatch: $editingSwatch
                                )
                                .padding(.horizontal, HueSpacing.screenH)
                                .padding(.top, HueSpacing.md)
                                .padding(.bottom, HueSpacing.md)
                            }
                            .scrollBounceBehavior(.basedOnSize)
                            .frame(height: scrollGeo.size.height)
                            // Auto-anchor: enabling a beat source scrolls the
                            // beat controls into view — no hunting.
                            .onChange(of: vm.activeCompositionBox?.reaction.source) { _, newSource in
                                guard let newSource,
                                      newSource == .beat || newSource == .onset || newSource == .tapTempo
                                else { return }
                                withAnimation(HueAnimation.fast) {
                                    proxy.scrollTo("reactionBeatControls", anchor: .center)
                                }
                            }
                        }
                    }
                } else {
                    // ── Inline params: essentials + the color row (color is the
                    // most-hunted adjustment — it costs one row to keep it out
                    // of the sheet). Remaining advanced params live behind
                    // "+N more", or inline when the tray is dragged up.
                    let inlineParams = MixerTrayMetrics.inlineParams(for: card)
                    let overflowParams = MixerTrayMetrics.overflowParams(for: card)

                    if !inlineParams.isEmpty {
                        GeometryReader { scrollGeo in
                            ScrollView(showsIndicators: false) {
                                VStack(spacing: HueSpacing.md) {
                                    ForEach(inlineParams) { param in
                                        StudioParamRow(param: param, cardID: card.id, vm: vm)
                                    }

                                    // Dragged-up tray shows everything inline —
                                    // no sheet hunting for power users.
                                    if isMixerExpanded && !overflowParams.isEmpty {
                                        Text("ADVANCED")
                                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                                            .tracking(1.2)
                                            .foregroundStyle(.white.opacity(0.38))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.top, 6)
                                        ForEach(overflowParams) { param in
                                            StudioParamRow(param: param, cardID: card.id, vm: vm)
                                        }
                                    }
                                }
                                .padding(.horizontal, HueSpacing.screenH)
                                .padding(.top, HueSpacing.md)
                                .padding(.bottom, HueSpacing.md)
                            }
                            .scrollBounceBehavior(.basedOnSize)
                            .frame(height: scrollGeo.size.height)
                        }
                    }

                    // ── More params reveal ───────────────────────
                    if !overflowParams.isEmpty && !isMixerExpanded {
                        StageMoreButton(count: overflowParams.count) {
                            showParamSheet = true
                        }
                    }
                }

                // ── Param sheet (inside if-let for unwrapped card) ──
                Color.clear.frame(height: 0)
                    .sheet(isPresented: $showParamSheet) {
                        // StageSheetScaffold owns detents / drag indicator / background interaction.
                        StudioParamSheet(card: card, vm: vm)
                    }
            }
        }
        // Flat stage surface (Perform grammar) — no live blur over the
        // animating card grid.
        .background(
            RoundedRectangle(cornerRadius: HueRadius.xl, style: .continuous)
                .fill(StagePalette.surface)
        )
        .clipShape(RoundedRectangle(cornerRadius: HueRadius.xl))
        .overlay(
            RoundedRectangle(cornerRadius: HueRadius.xl, style: .continuous)
                .strokeBorder(StagePalette.line, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 20, y: -2)
        .padding(.horizontal, HueSpacing.sm)
        .id(vm.currentRoomEffect?.cardID ?? vm.selectedRoom?.id)
        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
    }

    /// Bidirectional tray drag: up expands to near-full-screen, down collapses expanded→half,
    /// then half→dismiss (to the "Live Controls" pill). Only captures drags that begin near the
    /// tray header so child controls (like the hue/saturation pad) keep their own drag semantics.
    private var mixerDismissDragGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard value.startLocation.y <= 64 else { return }
                if value.translation.height >= 0 {
                    mixerDragOffset = value.translation.height
                } else {
                    // Small rubber-band hint on upward drags.
                    mixerDragOffset = max(value.translation.height, -48)
                }
            }
            .onEnded { value in
                guard value.startLocation.y <= 64 else {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                        mixerDragOffset = 0
                    }
                    return
                }
                let dragDistance = value.translation.height
                let predictedDistance = value.predictedEndTranslation.height
                let shouldExpand = dragDistance < -60 || predictedDistance < -120
                let shouldCollapse = dragDistance > 100 || predictedDistance > 160

                if shouldExpand && !isMixerExpanded {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        isMixerExpanded = true
                        mixerDragOffset = 0
                    }
                    HapticManager.shared.medium()
                } else if shouldCollapse && isMixerExpanded {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        isMixerExpanded = false
                        mixerDragOffset = 0
                    }
                    HapticManager.shared.light()
                } else if shouldCollapse {
                    hideMixerKeyboard()
                    onCollapse()
                    HapticManager.shared.medium()
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                        mixerDragOffset = 0
                    }
                } else {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                        mixerDragOffset = 0
                    }
                }
            }
    }

    // ── Beat binding for Studio engine cards ─────────────────

    /// Routes beat-panel edits through setParamValue so they persist in the
    /// card's param dict AND push live to the running engine's param box —
    /// writing the box directly would be clobbered by the next slider change.
    private func studioBeatBinding(forCardID cardID: String) -> Binding<BeatBinding> {
        Binding(
            get: { BeatBinding.fromStudioValues(vm.paramValues[cardID] ?? [:]) },
            set: { newValue in
                for (key, value) in newValue.studioValues {
                    vm.setParamValue(for: cardID, paramID: key, value: value)
                }
            }
        )
    }

    private func runtimeOnlyCadenceText() -> String {
        guard let cadence = vm.activeRESTCadenceForSelectedRoom else {
            return "Runtime-only REST is rate-capped"
        }
        return "Runtime-only REST is rate-capped (Live: ~\(String(format: "%.1f", cadence))s)"
    }

    /// The one-sentence transport status under the header, or nil when the
    /// running transport is exactly what was asked for and needs no comment.
    /// Composition cards only — engine cards say it all in the scope badge.
    private func transportStatus(
        for effect: RunningEffect,
        card: StudioCard
    ) -> (text: String, tint: Color)? {
        guard case .composition = card.strategy else { return nil }

        if orchestrator.compositionTransportByRoom[effect.room.id] == .bridgeStored {
            return ("Running on bridge — close the app, lights keep going",
                    HuePalette.amber.opacity(0.9))
        }
        if effect.transportFallback {
            return ("Streaming unavailable on this bridge/session, using REST",
                    HuePalette.amber.opacity(0.75))
        }
        if !effect.isEntertainment, card.compositionTier == .runtimeOnly {
            return (runtimeOnlyCadenceText(), .white.opacity(0.48))
        }
        return nil
    }

    /// The badge names the transport in the same grammar engine cards use
    /// ("ENT AREA" / "ROOM"). It stays short because the nuance — why we fell
    /// back, what bridge-stored means — lives in `transportStatus`'s sentence
    /// directly beneath it, where there is room to say it properly.
    private func composerTransportBadgeText(for effect: RunningEffect) -> String {
        // Bridge-stored animations run on the bridge hardware itself
        if orchestrator.compositionTransportByRoom[effect.room.id] == .bridgeStored {
            return "BRIDGE ⚡"
        }
        return composerIsStreaming(effect) ? "ENT AREA" : "ROOM · REST"
    }

    /// Live transport for a composition card — the orchestrator's per-room
    /// truth survives a mid-session DTLS→REST failover; the RunningEffect's
    /// `isEntertainment` is a snapshot from apply time and does not.
    private func composerIsStreaming(_ effect: RunningEffect) -> Bool {
        if let transport = orchestrator.compositionTransportByRoom[effect.room.id] {
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
