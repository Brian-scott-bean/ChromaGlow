// StudioBoardView.swift
// CastChroma — Slice 2 per-look board renderer.
//
// Renders a `StudioBoardDescriptor` with the shared instrument primitives:
// the hero control leads at a subtly larger size, primary knobs/faders flow
// on the invisible grid, supporting controls sit quieter below, color gets
// the inline B+ editor, and Beat reveals progressively — all inside the
// host's ONE vertical scroll. No Advanced section, no sheet, no popover.
//
// Every continuous gesture goes through the exact-identity session API
// (`beginParamEdit` / `updateParamEdit` / `endParamEdit`); one-shot writes
// go through `commitParam`/`commitColorParam`. The board never talks to the
// orchestrator directly.

import SwiftUI

struct StudioBoardView: View {
    let card: StudioCard
    let effect: RunningEffect
    @Bindable var vm: StudioViewModel

    private var descriptor: StudioBoardDescriptor {
        StudioBoardCatalog.descriptor(for: card)
    }

    /// The capability snapshot every control on this board resolves against —
    /// built once per render pass from CACHED lights only (spec §27).
    private var snapshot: CustomizationTargetSnapshot {
        vm.targetSnapshot(for: effect)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HueSpacing.lg) {
            ForEach(Array(descriptor.sections.enumerated()), id: \.offset) { _, section in
                switch section.kind {
                case .controls:
                    controlsSection(section)
                case .color:
                    colorSection(section)
                case .beat:
                    StageBeatSection(binding: vm.studioBeatBinding(forCardID: card.id))
                        .id("reactionBeatControls")
                }
            }
        }
    }

    // ── Controls ────────────────────────────────────────────────

    @ViewBuilder
    private func controlsSection(_ section: BoardSection) -> some View {
        let hero = section.controls.filter { $0.prominence == .hero }
        let rest = section.controls.filter { $0.prominence != .hero }
        // One snapshot for the whole section — the resolver is pure, so every
        // control in it answers against the same instant of truth.
        let snapshot = self.snapshot

        VStack(alignment: .leading, spacing: HueSpacing.md) {
            if !hero.isEmpty {
                HStack(alignment: .top, spacing: HueSpacing.lg) {
                    ForEach(hero, id: \.paramID) { control in
                        boardControl(control, isHero: true, snapshot: snapshot)
                    }
                    Spacer(minLength: 0)
                }
            }
            if !rest.isEmpty {
                // The invisible grid: continuous controls flow in rows of
                // three, chips/toggles take a full row of their own.
                let continuous = rest.filter { $0.primitive == .knob || $0.primitive == .fader }
                let fullWidth = rest.filter { $0.primitive != .knob && $0.primitive != .fader }
                if !continuous.isEmpty {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: HueSpacing.md,
                                                                 alignment: .top),
                                             count: min(3, max(1, continuous.count))),
                              alignment: .leading, spacing: HueSpacing.lg) {
                        ForEach(continuous, id: \.paramID) { control in
                            boardControl(control, isHero: false, snapshot: snapshot)
                        }
                    }
                }
                ForEach(fullWidth, id: \.paramID) { control in
                    boardControl(control, isHero: false, snapshot: snapshot)
                }
            }
        }
    }

    /// ONE availability answer per control (R2): bridge-native params go
    /// through the audit-§7 verified profile table, app-driven params through
    /// their colour/transport requirement. `speed` has no legacy send path, so
    /// on a room whose lights rejected `effects_v2` it renders DISABLED with a
    /// local reason — never a knob that moves while doing nothing (spec §17) —
    /// and a streaming-only param on a REST room renders STAGED: editable,
    /// saved, and honest about not being live.
    @ViewBuilder
    private func boardControl(_ control: BoardControl,
                              isHero: Bool,
                              snapshot: CustomizationTargetSnapshot) -> some View {
        if let param = card.params.first(where: { $0.id == control.paramID }) {
            let resolution = StudioBoardAvailability.resolve(card: card, param: param,
                                                             snapshot: snapshot)
            // Hidden means DO NOT RENDER (spec §17). A dimmed dead control is
            // the state Hidden exists to avoid, not a lighter version of it.
            if StudioBoardAvailability.rendersControl(resolution) {
                let note = StudioBoardAvailability.note(for: resolution,
                                                        strategy: card.strategy,
                                                        isColor: false)
                let interactive = StudioBoardAvailability.isInteractive(
                    resolution: resolution, strategy: card.strategy)
                let opacity = StudioBoardAvailability.opacity(resolution: resolution,
                                                              strategy: card.strategy)
                VStack(alignment: .leading, spacing: 3) {
                    // The opacity belongs to the CONTROL, not to the pair: a
                    // note nested inside a 0.45 wrapper rendered at ≈0.29 —
                    // the least legible thing on the board was the sentence
                    // explaining why the control was dead.
                    Group {
                        switch control.primitive {
                        case .knob:
                            StudioContinuousControl(param: param, cardID: card.id, vm: vm,
                                                    style: .knob, isHero: isHero,
                                                    isInteractive: interactive)
                        case .fader:
                            StudioContinuousControl(param: param, cardID: card.id, vm: vm,
                                                    style: .fader, isHero: isHero,
                                                    isInteractive: interactive)
                        case .chips:
                            chipsControl(param, isInteractive: interactive)
                        case .toggle:
                            StageToggleRow(
                                title: param.label,
                                isOn: Binding(
                                    get: { vm.paramValue(for: card.id, paramID: param.id,
                                                         default: param.defaultValue) > 0.5 },
                                    set: { newValue in
                                        guard interactive else { return }
                                        vm.commitParam(cardID: card.id, paramID: param.id,
                                                       value: newValue ? 1 : 0)
                                    }
                                )
                            )
                        case .colorEditor:
                            EmptyView()   // color renders in its own section
                        }
                    }
                    .opacity(opacity)
                    if let note {
                        // Capability truth beside the control it affects — only
                        // where it materially changes what the control can do.
                        // Exactly ONE note per control: the funnel already folded
                        // the old separate entOnly hint into this line.
                        Text(note)
                            .font(HueFont.stageTag)
                            .tracking(0.8)
                            // The caption is a caption. Uncapped, the capability
                            // copy wrapped to four-plus lines under a knob in a
                            // three-column grid and became the loudest thing on
                            // the board; a small line budget with a scale floor
                            // keeps it legible without letting it take over.
                            //
                            // THREE, not two: the joined coverage-plus-caveat
                            // note ("1 OF 3 LIGHTS RESPOND · UNVERIFIED HERE")
                            // is the longest thing this caption ever says, and
                            // under a 60 pt knob in a one-third-width column it
                            // needs three lines even at the 0.85 scale floor.
                            // At two it truncated, and the clipped tail was the
                            // caveat — the half that cannot be read anywhere
                            // else on screen.
                            .lineLimit(3)
                            .minimumScaleFactor(0.85)
                            .foregroundStyle(HuePalette.amber.opacity(0.65))
                            .accessibilityLabel("\(param.label): \(note)")
                    }
                }
                .disabled(!interactive)
            }
        }
    }

    private func chipsControl(_ param: StudioParam, isInteractive: Bool) -> some View {
        let options: [(label: String, value: Double)]
        if case .segmented(let opts) = param.kind { options = opts } else { options = [] }
        return StageSteppedEncoder(
            title: param.label,
            options: options,
            selection: Binding(
                get: {
                    let current = vm.paramValue(for: card.id, paramID: param.id,
                                                default: param.defaultValue)
                    return options.min { abs($0.value - current) < abs($1.value - current) }?.value
                        ?? param.defaultValue
                },
                // Belt-and-braces with the wrapper's `.disabled`: a raw tap
                // gesture inside a stepped encoder is not a Button, and only
                // the setter is on every write path.
                set: { newValue in
                    guard isInteractive else { return }
                    vm.commitParam(cardID: card.id, paramID: param.id, value: newValue)
                }
            ),
            prominence: .chips
        )
    }

    // ── Color (inline B+) ───────────────────────────────────────

    /// The colour editor goes through the SAME funnel as every numeric
    /// control (R2). A colourless room disables it with "NO COLOR LIGHTS
    /// HERE" instead of offering a live-looking swatch row that writes into
    /// nothing; Strobe's streaming-only flash colour renders staged.
    ///
    /// The partial-coverage note is suppressed here on purpose — the editor
    /// already badges "n OF m LIGHTS" beside its own chip (spec §13).
    @ViewBuilder
    private func colorSection(_ section: BoardSection) -> some View {
        // ONE snapshot, built once and handed to both readers. Asking the view
        // model twice (here and again inside `colorCapabilityContext`) scanned
        // the whole light cache twice per render pass and could — between the
        // two calls — describe two different instants of truth.
        let snapshot = self.snapshot
        let context = vm.colorCapabilityContext(for: effect, snapshot: snapshot)
        ForEach(section.controls, id: \.paramID) { control in
            if let param = card.params.first(where: { $0.id == control.paramID }) {
                let resolution = StudioBoardAvailability.resolve(card: card, param: param,
                                                                 snapshot: snapshot)
                if StudioBoardAvailability.rendersControl(resolution) {
                    let note = StudioBoardAvailability.note(for: resolution,
                                                            strategy: card.strategy,
                                                            isColor: true)
                    let interactive = StudioBoardAvailability.isInteractive(
                        resolution: resolution, strategy: card.strategy)
                    let opacity = StudioBoardAvailability.opacity(resolution: resolution,
                                                                  strategy: card.strategy)
                    let controlID = CustomizationControlID(cardID: card.id, paramID: param.id)
                    VStack(alignment: .leading, spacing: 3) {
                        StageColorEditor(
                            title: param.label,
                            current: vm.paramColor(for: card.id, paramID: param.id),
                            context: context,
                            isInteractive: interactive,
                            // A collapsed editor when the control is dead: the
                            // hue/saturation pad is a raw drag surface, and
                            // leaving it open under a disabled wrapper invites
                            // exactly the gesture path we mean to close (L6).
                            isExpanded: colorExpansionBinding(controlID,
                                                              isInteractive: interactive),
                            // Belt-and-braces: the wrapper's `.disabled` is the
                            // gate, this is the floor. Nothing the editor's own
                            // gestures do can reach the view model.
                            onApply: interactive
                                ? { color in
                                    vm.commitColorParam(cardID: card.id,
                                                        paramID: param.id, color: color)
                                }
                                : { _ in }
                        )
                        .opacity(opacity)
                        if let note {
                            // Same three-line budget as the grid captions: the
                            // colour caption is narrower than the editor it
                            // sits under, and the caveat must not be the half
                            // that gets clipped.
                            Text(note)
                                .font(HueFont.stageTag)
                                .tracking(0.8)
                                .lineLimit(3)
                                .minimumScaleFactor(0.85)
                                .foregroundStyle(HuePalette.amber.opacity(0.65))
                                .accessibilityLabel("\(param.label): \(note)")
                        }
                    }
                    .disabled(!interactive)
                }
            }
        }
    }

    /// Expansion lives in the SESSION working memory keyed by exact target —
    /// it survives switching between active rooms (spec §14.4) and clears
    /// when the session ends.
    /// A non-interactive control reads as COLLAPSED and refuses to expand,
    /// without erasing the stored expansion: the moment the transport or the
    /// inventory arrives, the editor the user left open is open again.
    private func colorExpansionBinding(_ controlID: CustomizationControlID,
                                       isInteractive: Bool) -> Binding<Bool> {
        let target = effect.identity.targetKey
        return Binding(
            get: {
                guard isInteractive else { return false }
                return vm.sessionMemory.state(for: target).expandedColorControlID == controlID
            },
            set: { expanded in
                guard isInteractive else { return }
                vm.sessionMemory.update(target) {
                    $0.expandedColorControlID = expanded ? controlID : nil
                }
            }
        )
    }
}

// MARK: - Continuous control row (knob / fader)

/// The knob/fader wrapper carrying the exact-identity session pattern the
/// slider row established: row-local value, session captured on the editing
/// bracket, external writes re-sync only when the finger is up.
private struct StudioContinuousControl: View {
    enum Style { case knob, fader }

    let param: StudioParam
    let cardID: String
    @Bindable var vm: StudioViewModel
    let style: Style
    var isHero: Bool = false
    /// The funnel's verdict, carried INTO the control.
    ///
    /// `.disabled()` on the wrapper is the gate; this is the floor beneath it.
    /// A knob's drag, its long-press-to-type field and its accessibility
    /// adjust action are raw gestures, not `Control`s, and every one of them
    /// writes through the binding below — so short-circuiting the setter (and
    /// the edit-session bracket) closes all three at once, whatever the
    /// wrapper does.
    var isInteractive: Bool = true

    @State private var localValue: Double = 0
    @State private var isAdjusting = false
    @State private var seeded = false
    @State private var editSession: StudioParamSession?

    private var range: ClosedRange<Double> {
        if case .slider(let min, let max) = param.kind { return min...max }
        return 0...100
    }

    var body: some View {
        control
            .onAppear {
                guard !seeded else { return }
                localValue = vm.paramValue(for: cardID, paramID: param.id,
                                           default: param.defaultValue)
                seeded = true
            }
            .onChange(of: vm.paramValue(for: cardID, paramID: param.id,
                                        default: param.defaultValue)) { _, newValue in
                guard !isAdjusting else { return }
                if newValue != localValue { localValue = newValue }
            }
    }

    @ViewBuilder private var control: some View {
        let binding = Binding(
            get: { localValue },
            set: { newValue in
                // Not interactive: the value does not move either, so a gesture
                // that slipped past `.disabled` cannot even LOOK like it worked.
                guard isInteractive else { return }
                localValue = newValue
                if let session = editSession {
                    vm.updateParamEdit(session, value: newValue)
                } else {
                    vm.commitParam(cardID: cardID, paramID: param.id, value: newValue)
                }
            }
        )
        let editingChanged: (Bool) -> Void = { editing in
            // No session for a control the user may not edit — an opened-and-
            // never-closed edit bracket would hold a generation fence over a
            // target nobody is editing.
            guard isInteractive else { return }
            isAdjusting = editing
            if editing {
                editSession = vm.beginParamEdit(cardID: cardID, paramID: param.id)
            } else {
                if let session = editSession { vm.endParamEdit(session) }
                editSession = nil
            }
        }
        switch style {
        case .knob:
            StageKnob(title: param.label, value: binding, range: range,
                      defaultValue: param.defaultValue,
                      format: param.format ?? { "\(Int($0.rounded()))" },
                      diameter: isHero ? 84 : 60,
                      onEditingChanged: editingChanged)
        case .fader:
            StageFader(title: param.label, value: binding, range: range,
                       defaultValue: param.defaultValue,
                       format: param.format ?? { "\(Int($0.rounded()))" },
                       trackHeight: isHero ? 168 : 128,
                       onEditingChanged: editingChanged)
        }
    }
}
