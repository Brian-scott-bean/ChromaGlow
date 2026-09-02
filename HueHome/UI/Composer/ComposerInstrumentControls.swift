// ComposerInstrumentControls.swift
// CastChroma — Slice 3 (S3-2): the Composer's wrappers around the shared
// StageKit instruments.
//
// Composer keeps Composer's domain model. Each wrapper reads and writes ONE
// typed field of the live `CompositionParamBox` through a read/write pair —
// nothing here is a `StudioParam` or a string-keyed value (spec §20). What
// the Composer borrows is the INSTRUMENT, chosen by meaning (spec §9):
//
//   * `StageKnob`   — rates, character, sensitivity (speed, BPM, spread…)
//   * `StageFader`  — levels and amounts (depth, min/max brightness…)
//   * `StageSteppedEncoder` — discrete choices (pattern, shape, source, mode)
//   * `StageToggleRow`      — on/off (randomize, forward, mirror)
//
// and with the instrument comes its whole contract: direct manipulation,
// adaptive fine control, exact entry, double-tap reset, semantic haptics,
// the adjustable accessibility trait and its "Reset to default" action.
//
// Every wrapper does three things the old `StageSlider` call sites did not:
//   1. resolves through `ComposerAvailabilityContext` and APPLIES the verdict
//      with `ComposerControlGate` (S3-4) — plus the setter-level floor;
//   2. captures a `ComposerEditSession` on the editing bracket and commits
//      every write through the fence (S3-5) — never `activeCompositionBox`;
//   3. keeps a row-local value, so an external write (Revert, the harmony
//      recompute) re-syncs the instrument only while the finger is up — the
//      shape `StudioContinuousControl` established for the board.

import SwiftUI

// MARK: - Continuous (knob / fader)

struct ComposerContinuousControl: View {
    enum Style { case knob, fader }

    let label: String
    let controlID: String
    let vm: StudioViewModel
    let availability: ComposerAvailabilityContext
    let style: Style
    let range: ClosedRange<Double>
    let defaultValue: Double
    var format: ((Double) -> String)? = nil
    var isHero: Bool = false
    let read: (CompositionParamBox) -> Double
    let write: (CompositionParamBox, Double) -> Void

    @State private var localValue: Double = 0
    @State private var isAdjusting = false
    @State private var seeded = false
    @State private var editSession: ComposerEditSession?

    var body: some View {
        let resolution = availability.resolve(controlID)
        let interactive = ComposerControlAvailability.isInteractive(resolution)
        // Reading the box field here is the observation dependency: the box's
        // four configs are `@Observable`, so a Revert or a harmony recompute
        // re-renders this control and the `onChange` below re-syncs it.
        let external = availability.session.map { read($0.box) }
        ComposerControlGate(label: label, resolution: resolution) {
            instrument(interactive: interactive)
        }
        .onAppear {
            guard !seeded else { return }
            localValue = external ?? defaultValue
            seeded = true
        }
        .onChange(of: external) { _, newValue in
            guard !isAdjusting, let newValue, newValue != localValue else { return }
            localValue = newValue
        }
    }

    @ViewBuilder
    private func instrument(interactive: Bool) -> some View {
        let binding = Binding(
            get: { localValue },
            set: { newValue in
                // Not interactive: the value does not move either, so a
                // gesture that slipped past `.disabled` cannot even LOOK like
                // it worked (the drag, the typed draft and the accessibility
                // adjust action all write through here).
                guard interactive else { return }
                localValue = newValue
                // The session captured when the gesture began; a one-shot
                // write (accessibility adjust brackets itself) falls back to
                // the render's own session. Never `activeCompositionBox`.
                guard let session = editSession ?? availability.session else { return }
                vm.commitComposerEdit(session) { write($0, newValue) }
            }
        )
        let editingChanged: (Bool) -> Void = { editing in
            guard interactive else { return }
            isAdjusting = editing
            editSession = editing ? vm.composerEditSession() : nil
        }
        switch style {
        case .knob:
            StageKnob(title: label, value: binding, range: range,
                      defaultValue: defaultValue,
                      format: format ?? { "\(Int($0.rounded()))" },
                      diameter: isHero ? 84 : 60,
                      onEditingChanged: editingChanged)
        case .fader:
            StageFader(title: label, value: binding, range: range,
                       defaultValue: defaultValue,
                       format: format ?? { "\(Int($0.rounded()))" },
                       trackHeight: isHero ? 168 : 128,
                       onEditingChanged: editingChanged)
        }
    }
}

// MARK: - Discrete choice (pads / chips)

struct ComposerChoiceControl<Value: Hashable>: View {
    let label: String
    let controlID: String
    let vm: StudioViewModel
    let availability: ComposerAvailabilityContext
    let items: [ChipPickerRow<Value>.Item]
    var prominence: StageSteppedEncoder<Value>.Prominence = .chips
    /// What the encoder shows with no live box (never written back).
    let fallback: Value
    let read: (CompositionParamBox) -> Value
    let write: (CompositionParamBox, Value) -> Void
    /// Runs after a committed change — the palette-mode row uses it to
    /// dismiss harmony when the new mode ignores colour fields.
    var afterCommit: ((Value) -> Void)? = nil

    var body: some View {
        let resolution = availability.resolve(controlID)
        let interactive = ComposerControlAvailability.isInteractive(resolution)
        ComposerControlGate(label: label, resolution: resolution) {
            StageSteppedEncoder(
                title: label,
                items: items,
                selection: Binding(
                    get: { availability.session.map { read($0.box) } ?? fallback },
                    set: { newValue in
                        guard interactive, let session = availability.session else { return }
                        guard vm.commitComposerEdit(session, { write($0, newValue) }).isCommit else { return }
                        afterCommit?(newValue)
                    }
                ),
                prominence: prominence)
        }
    }
}

// MARK: - Toggle

struct ComposerToggleControl: View {
    let label: String
    let controlID: String
    let vm: StudioViewModel
    let availability: ComposerAvailabilityContext
    let read: (CompositionParamBox) -> Bool
    let write: (CompositionParamBox, Bool) -> Void

    var body: some View {
        let resolution = availability.resolve(controlID)
        let interactive = ComposerControlAvailability.isInteractive(resolution)
        ComposerControlGate(label: label, resolution: resolution) {
            StageToggleRow(
                title: label,
                isOn: Binding(
                    get: { availability.session.map { read($0.box) } ?? false },
                    set: { newValue in
                        guard interactive, let session = availability.session else { return }
                        vm.commitComposerEdit(session) { write($0, newValue) }
                    }
                ))
        }
    }
}

// MARK: - Reaction targets (multi-select pads)

/// Which outputs a reaction modulates: brightness / colour / speed, any
/// combination, at least one. Multi-select PADS rather than three raw
/// toggles — a set of modes, not three unrelated switches. The `.color` pad
/// carries its own colour requirement (`targetColor`): modulating a colour no
/// light here renders is a dead pad, and it says so.
struct ComposerTargetPads: View {
    let vm: StudioViewModel
    let availability: ComposerAvailabilityContext

    private static func label(_ target: ReactionConfig.Target) -> String {
        switch target {
        case .brightness: return "Brightness"
        case .color: return "Color"
        case .speed: return "Speed"
        }
    }

    var body: some View {
        let targetsRes = availability.resolve("targets")
        let colorRes = availability.resolve("targetColor")
        ComposerControlGate(label: "Targets", resolution: targetsRes) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Targets")
                    .font(HueFont.stageControl)
                    .foregroundStyle(.white.opacity(0.60))
                HStack(spacing: 8) {
                    ForEach(ReactionConfig.Target.allCases, id: \.self) { target in
                        let resolution = target == .color ? colorRes : targetsRes
                        let interactive = ComposerControlAvailability.isInteractive(resolution)
                        let selected = availability.session?.box.reaction.targets.contains(target) ?? false
                        Button {
                            guard interactive, let session = availability.session else { return }
                            vm.commitComposerEdit(session) { box in
                                var targets = box.reaction.targets
                                if selected {
                                    targets.removeAll { $0 == target }
                                } else if !targets.contains(target) {
                                    targets.append(target)
                                }
                                // At least one output always reacts.
                                if targets.isEmpty { targets = [.brightness] }
                                box.reaction.targets = targets
                            }
                            HapticManager.shared.selection()
                        } label: {
                            Text(Self.label(target))
                                .font(HueFont.stageControl)
                                .foregroundStyle(selected ? StagePalette.stage : StagePalette.ink)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(selected ? HuePalette.amber : StagePalette.raised)
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(!interactive)
                        .opacity(ComposerControlAvailability.opacity(resolution))
                        .accessibilityLabel("\(Self.label(target)) target")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                if let note = ComposerControlAvailability.note(for: colorRes, isColor: false),
                   ComposerControlAvailability.note(for: targetsRes, isColor: false) == nil {
                    Text(note)
                        .font(HueFont.stageTag)
                        .foregroundStyle(HuePalette.amber.opacity(0.65))
                        .tracking(0.6)
                        .accessibilityLabel("Color target: \(note)")
                }
            }
        }
    }
}
