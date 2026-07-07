// MixerTrayView.swift
// CastChroma — Zone C mixer tray (extracted from StudioView in Round 4, R4-2).
//
// The bottom tray that springs up when an effect runs: header (icon, name,
// LIVE chip, beat chip, transport/scope badge, save, Perform, stop) plus the
// content area — the CompositionEditorPanel for composition cards, or the
// essential StudioParamRow sliders for engine cards.
//
// Pure move — view content is byte-identical to the StudioView original.
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
    @Binding var showPerform: Bool
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

                // ── Header ───────────────────────────────────
                HStack(spacing: 10) {
                    // Effect icon
                    ZStack {
                        Circle()
                            .fill(card.accentColor.opacity(0.20))
                            .frame(width: 32, height: 32)
                        Image(systemName: card.icon)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(card.accentColor)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text(card.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(effect.room.name)
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(1.0)
                            .textCase(.uppercase)
                            .foregroundStyle(.white.opacity(0.4))
                    }

                    // Live indicator
                    HStack(spacing: 4) {
                        Circle().fill(HuePalette.Noir.success)
                            .frame(width: 5, height: 5)
                        Text("LIVE")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(HuePalette.Noir.success)
                    }

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
                    }

                    // Scope / transport badge for Studio engine cards
                    if case .appDriven = card.strategy {
                        StageBadge(text: effect.isEntertainment ? "ENT AREA" : "ROOM",
                                   style: effect.isEntertainment ? .amber : .muted)
                    } else if case .composition = card.strategy {
                        VStack(alignment: .leading, spacing: 2) {
                            Menu {
                                Button {
                                    onTransportSwitch(effect, true)
                                } label: {
                                    Label("Entertainment Area (Streaming)", systemImage: "bolt.fill")
                                }

                                Button {
                                    onTransportSwitch(effect, false)
                                } label: {
                                    Label("Room Only (REST)", systemImage: "iphone")
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(composerTransportBadgeText(for: effect))
                                        .font(.system(size: 9, weight: .bold))
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.system(size: 7, weight: .bold))
                                        .opacity(0.82)
                                }
                                .foregroundStyle(effect.isEntertainment ? HuePalette.amber : .white.opacity(0.75))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(
                                        effect.isEntertainment
                                            ? HuePalette.amber.opacity(0.15)
                                            : Color.white.opacity(0.10)
                                    )
                                )
                            }
                            .buttonStyle(.plain)

                            if orchestrator.isBridgeStored {
                                Text("Running on bridge — close the app, lights keep going")
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundStyle(HuePalette.amber.opacity(0.9))
                            } else if effect.transportFallback {
                                Text("Streaming unavailable on this bridge/session, using REST")
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundStyle(HuePalette.amber.opacity(0.75))
                            } else if !effect.isEntertainment, card.compositionTier == .runtimeOnly {
                                Text(runtimeOnlyCadenceText())
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.48))
                            }
                        }
                    }

                    // Active rooms count badge
                    if vm.runningEffects.count > 1 {
                        Text("\(vm.runningEffects.count) rooms")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(HuePalette.amber)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(HuePalette.amber.opacity(0.15)))
                    }

                    Spacer()

                    if case .composition = card.strategy {
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
                                isStreaming: effect.isEntertainment,
                                presetID: presetID,
                                compositionStore: vm.compositionStore
                            )
                            showPerform = true
                            HapticManager.shared.medium()
                        } label: {
                            Image(systemName: "slider.vertical.3")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.black.opacity(0.85))
                                .padding(8)
                                .background(Circle().fill(HuePalette.amber))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Perform")

                        Button {
                            onSaveComposition(card)
                            HapticManager.shared.light()
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 12))
                                .foregroundStyle(HuePalette.amber)
                                .padding(8)
                                .background(
                                    Circle()
                                        .fill(HuePalette.amber.opacity(0.15))
                                )
                        }
                        .buttonStyle(.plain)
                    }

                    // Stop control
                    Button {
                        Task { await vm.explicitStop(card) }
                        HapticManager.shared.light()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(HuePalette.Noir.destructive)
                            .padding(8)
                            .background(
                                Circle()
                                    .fill(HuePalette.Noir.destructive.opacity(0.15))
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, HueSpacing.screenH)
                .padding(.top, HueSpacing.md)
                .padding(.bottom, HueSpacing.sm)

                // ── Separator ────────────────────────────────
                Rectangle()
                    .fill(HuePalette.Noir.separator)
                    .frame(height: 0.5)
                    .padding(.horizontal, HueSpacing.screenH)

                if case .composition = card.strategy {
                    GeometryReader { scrollGeo in
                        ScrollViewReader { proxy in
                            ScrollView(showsIndicators: false) {
                                CompositionEditorPanel(
                                    vm: vm,
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
                    // ── Essential parameter sliders ──────────────
                    let essentialParams = card.params.filter { $0.tier == .essential }
                    if !essentialParams.isEmpty {
                        GeometryReader { scrollGeo in
                            ScrollView(showsIndicators: false) {
                                VStack(spacing: HueSpacing.md) {
                                    ForEach(essentialParams) { param in
                                        StudioParamRow(param: param, cardID: card.id, vm: vm)
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

                    // ── More params chevron ──────────────────────
                    let advancedCount = card.params.filter { $0.tier != .essential }.count
                    if advancedCount > 0 {
                        Button {
                            showParamSheet = true
                            HapticManager.shared.light()
                        } label: {
                            HStack(spacing: 4) {
                                Text("\(advancedCount) more")
                                    .font(.system(size: 11, weight: .medium))
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            .foregroundStyle(.white.opacity(0.45))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // ── Param sheet (inside if-let for unwrapped card) ──
                Color.clear.frame(height: 0)
                    .sheet(isPresented: $showParamSheet) {
                        StudioParamSheet(card: card, vm: vm)
                            .presentationDetents([.medium, .large])
                            .presentationDragIndicator(.visible)
                            .presentationBackgroundInteraction(.enabled)
                    }
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: HueRadius.xl))
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

    private func composerTransportBadgeText(for effect: RunningEffect) -> String {
        // Bridge-stored animations run on the bridge hardware itself
        if orchestrator.isBridgeStored {
            return "BRIDGE ⚡"
        }
        if effect.transportFallback {
            return "COMPOSER: ROOM (REST FALLBACK)"
        }
        return effect.isEntertainment ? "COMPOSER: ENT AREA" : "COMPOSER: ROOM (REST)"
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
