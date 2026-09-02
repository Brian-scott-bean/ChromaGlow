// StageInstrumentControls.swift
// CastChroma — Slice 2 shared touch instrument primitives.
//
// The encoder knob, vertical level fader, and stepped encoder the Studio
// boards compose from (spec §4/§5). One gesture contract, implemented once:
//
//   * direct manipulation — touching the control starts adjusting it;
//   * adaptive fine control — lateral distance during the drag increases
//     precision (InstrumentControlMath.adaptiveGain — pure, tested);
//   * contextual precision — the exact value is quiet at rest, prominent
//     while touching, and recedes after release;
//   * exact entry — tap the readout (or long-press the control) to type;
//     StageDraftMath clamps, so typing cannot escape the range;
//   * double-tap — reset that one parameter to its default;
//   * semantic haptics — ticks at default snap / limits / steps, no buzzing;
//   * accessibility — adjustable trait with increment/decrement, an explicit
//     "Reset to default" action, and the availability reason as the hint.
//
// Reduce Motion: value changes render without implicit animation; the only
// decorative motion (readout fade) is disabled under it.

import SwiftUI

// MARK: - Shared gesture engine

/// The drag state a knob or fader carries: integrates per-sample deltas with
/// the adaptive gain so precision follows the finger continuously.
private struct InstrumentDragState {
    var lastAxisPosition: CGFloat
    var value: Double
}

// MARK: - StageKnob

/// Encoder-style rotary knob: vertical drag adjusts (up = increase), lateral
/// distance refines. The arc sweeps 270°, quiet at rest.
struct StageKnob: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var defaultValue: Double? = nil
    var format: (Double) -> String = { "\(Int($0.rounded()))" }
    var diameter: CGFloat = 64
    /// Points of vertical travel that sweep the full range at coarse gain.
    var travel: CGFloat = 220
    var onEditingChanged: ((Bool) -> Void)? = nil
    /// Exact-entry parser for readouts whose unit is not the value's unit
    /// (a Kelvin readout over a mirek range — review round, B-7). Returns
    /// the value in the RANGE's unit; the knob clamps it. Nil → the shared
    /// `StageDraftMath` parse.
    var parseDraft: ((String) -> Double?)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drag: InstrumentDragState? = nil
    @State private var isTyping = false
    @State private var draft = ""
    @FocusState private var draftFocused: Bool

    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return (value - range.lowerBound) / span
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(StagePalette.raised, lineWidth: 5)
                Circle()
                    .trim(from: 0, to: 0.75 * fraction)
                    .stroke(HuePalette.amber.opacity(drag == nil ? 0.75 : 1.0),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(135))
                // Indicator dot at the value angle.
                Circle()
                    .fill(StagePalette.ink.opacity(drag == nil ? 0.6 : 1.0))
                    .frame(width: 6, height: 6)
                    .offset(y: -(diameter / 2 - 10))
                    .rotationEffect(.degrees(-135 + 270 * fraction))
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle().inset(by: -8))
            .gesture(dragGesture)
            .simultaneousGesture(doubleTapReset)
            .onLongPressGesture(minimumDuration: 0.45) { beginTyping() }

            readoutRow
            Text(title.uppercased())
                .font(HueFont.stageTag)
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(minWidth: max(diameter, HueHit.min))
        .instrumentAccessibility(title: title, value: $value, range: range,
                                 defaultValue: defaultValue, format: format,
                                 onEditingChanged: onEditingChanged)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { g in
                if drag == nil {
                    drag = InstrumentDragState(lastAxisPosition: g.translation.height,
                                               value: value)
                    onEditingChanged?(true)
                }
                guard var state = drag else { return }
                let gain = InstrumentControlMath.adaptiveGain(
                    lateralDistance: g.translation.width)
                // Up = increase → negate the y delta.
                let axisDelta = -(g.translation.height - state.lastAxisPosition)
                let delta = InstrumentControlMath.valueDelta(
                    axisDelta: axisDelta, travel: travel, range: range, gain: gain)
                let previous = state.value
                state.value = InstrumentControlMath.applying(
                    delta: delta, to: state.value, range: range)
                state.lastAxisPosition = g.translation.height
                drag = state
                if value != state.value {
                    value = state.value
                    fireTick(previous: previous, new: state.value)
                }
            }
            .onEnded { _ in
                drag = nil
                onEditingChanged?(false)
            }
    }

    private var doubleTapReset: some Gesture {
        TapGesture(count: 2).onEnded {
            guard let defaultValue else { return }
            onEditingChanged?(true)
            value = min(range.upperBound, max(range.lowerBound, defaultValue))
            onEditingChanged?(false)
            HapticManager.shared.medium()
        }
    }

    private func fireTick(previous: Double, new: Double) {
        if InstrumentControlMath.semanticTick(
            previous: previous, new: new, range: range,
            defaultValue: defaultValue) != nil {
            HapticManager.shared.selection()
        }
    }

    @ViewBuilder private var readoutRow: some View {
        if isTyping {
            TextField("", text: $draft)
                .font(HueFont.stageValue)
                .foregroundStyle(HuePalette.amber)
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.center)
                .frame(width: 76)
                .focused($draftFocused)
                .onSubmit(commitDraft)
                .onChange(of: draftFocused) { _, focused in
                    if !focused { commitDraft() }
                }
                .submitLabel(.done)
        } else {
            Button(action: beginTyping) {
                Text(format(value))
                    .font(HueFont.stageValue)
                    .foregroundStyle(drag == nil ? .white.opacity(0.45) : HuePalette.amber)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .animation(reduceMotion ? nil : HueAnimation.fast, value: drag == nil)
            .accessibilityLabel("\(title) value \(format(value)), tap to type an exact value")
        }
    }

    private func beginTyping() {
        draft = format(value)
        isTyping = true
        draftFocused = true
        HapticManager.shared.selection()
    }

    private func commitDraft() {
        guard isTyping else { return }
        isTyping = false
        draftFocused = false
        let parsed: Double?
        if let parseDraft {
            parsed = parseDraft(draft).map { min(range.upperBound, max(range.lowerBound, $0)) }
        } else {
            parsed = StageDraftMath.parseDraft(draft, range: range)
        }
        guard let parsed else { return }
        onEditingChanged?(true)
        value = parsed
        onEditingChanged?(false)
    }
}

// MARK: - StageFader

/// Vertical level fader for brightness/level/intensity semantics. Same
/// gesture contract as the knob; the cap position IS the value.
struct StageFader: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var defaultValue: Double? = nil
    var format: (Double) -> String = { "\(Int($0.rounded()))" }
    var trackHeight: CGFloat = 148
    var onEditingChanged: ((Bool) -> Void)? = nil
    /// See `StageKnob.parseDraft`.
    var parseDraft: ((String) -> Double?)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drag: InstrumentDragState? = nil
    @State private var isTyping = false
    @State private var draft = ""
    @FocusState private var draftFocused: Bool

    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return (value - range.lowerBound) / span
    }

    var body: some View {
        VStack(spacing: 6) {
            readoutRow
            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(StagePalette.raised)
                    .frame(width: 8)
                Capsule()
                    .fill(HuePalette.amber.opacity(drag == nil ? 0.7 : 1.0))
                    .frame(width: 8, height: max(4, trackHeight * fraction))
                // Cap
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(StagePalette.ink.opacity(drag == nil ? 0.85 : 1.0))
                    .frame(width: 34, height: 14)
                    .offset(y: -(trackHeight - 14) * fraction)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
            }
            .frame(width: 44, height: trackHeight)
            .contentShape(Rectangle().inset(by: -8))
            .gesture(dragGesture)
            .simultaneousGesture(doubleTapReset)
            .onLongPressGesture(minimumDuration: 0.45) { beginTyping() }

            Text(title.uppercased())
                .font(HueFont.stageTag)
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(minWidth: HueHit.min)
        .instrumentAccessibility(title: title, value: $value, range: range,
                                 defaultValue: defaultValue, format: format,
                                 onEditingChanged: onEditingChanged)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { g in
                if drag == nil {
                    drag = InstrumentDragState(lastAxisPosition: g.translation.height,
                                               value: value)
                    onEditingChanged?(true)
                }
                guard var state = drag else { return }
                let gain = InstrumentControlMath.adaptiveGain(
                    lateralDistance: g.translation.width)
                let axisDelta = -(g.translation.height - state.lastAxisPosition)
                let delta = InstrumentControlMath.valueDelta(
                    axisDelta: axisDelta, travel: trackHeight, range: range, gain: gain)
                let previous = state.value
                state.value = InstrumentControlMath.applying(
                    delta: delta, to: state.value, range: range)
                state.lastAxisPosition = g.translation.height
                drag = state
                if value != state.value {
                    value = state.value
                    if InstrumentControlMath.semanticTick(
                        previous: previous, new: state.value, range: range,
                        defaultValue: defaultValue) != nil {
                        HapticManager.shared.selection()
                    }
                }
            }
            .onEnded { _ in
                drag = nil
                onEditingChanged?(false)
            }
    }

    private var doubleTapReset: some Gesture {
        TapGesture(count: 2).onEnded {
            guard let defaultValue else { return }
            onEditingChanged?(true)
            value = min(range.upperBound, max(range.lowerBound, defaultValue))
            onEditingChanged?(false)
            HapticManager.shared.medium()
        }
    }

    @ViewBuilder private var readoutRow: some View {
        if isTyping {
            TextField("", text: $draft)
                .font(HueFont.stageValue)
                .foregroundStyle(HuePalette.amber)
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.center)
                .frame(width: 64)
                .focused($draftFocused)
                .onSubmit(commitDraft)
                .onChange(of: draftFocused) { _, focused in
                    if !focused { commitDraft() }
                }
                .submitLabel(.done)
        } else {
            Button(action: beginTyping) {
                Text(format(value))
                    .font(HueFont.stageValue)
                    .foregroundStyle(drag == nil ? .white.opacity(0.45) : HuePalette.amber)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .animation(reduceMotion ? nil : HueAnimation.fast, value: drag == nil)
            .accessibilityLabel("\(title) value \(format(value)), tap to type an exact value")
        }
    }

    private func beginTyping() {
        draft = format(value)
        isTyping = true
        draftFocused = true
        HapticManager.shared.selection()
    }

    private func commitDraft() {
        guard isTyping else { return }
        isTyping = false
        draftFocused = false
        let parsed: Double?
        if let parseDraft {
            parsed = parseDraft(draft).map { min(range.upperBound, max(range.lowerBound, $0)) }
        } else {
            parsed = StageDraftMath.parseDraft(draft, range: range)
        }
        guard let parsed else { return }
        onEditingChanged?(true)
        value = parsed
        onEditingChanged?(false)
    }
}

// MARK: - Stepped encoder

/// Discrete selector: prominent decisions render as tactile pads, quiet ones
/// as the shared chip row — one primitive per semantic class (spec §9).
///
/// Generic over the selection's type (Slice 3): the board's `.segmented`
/// params are `Double`-valued, the Composer's are typed enums (palette mode,
/// motion pattern, envelope shape, reaction source, harmony rule, the layer
/// tab) — one primitive, whatever the domain calls the choice. `items` carry
/// the chip row's icon / curve thumbnail so a pattern keeps its signature
/// and a brightness shape keeps its waveform.
struct StageSteppedEncoder<Value: Hashable>: View {
    enum Prominence { case pads, chips }

    let title: String
    let items: [ChipPickerRow<Value>.Item]
    @Binding var selection: Value
    var prominence: Prominence = .chips

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The board's form: label/value pairs.
    init(title: String,
         options: [(label: String, value: Value)],
         selection: Binding<Value>,
         prominence: Prominence = .chips) {
        self.title = title
        self.items = options.map { ChipPickerRow<Value>.Item(value: $0.value, label: $0.label) }
        self._selection = selection
        self.prominence = prominence
    }

    /// The Composer's form: chip items with icons / curve thumbnails.
    init(title: String,
         items: [ChipPickerRow<Value>.Item],
         selection: Binding<Value>,
         prominence: Prominence = .chips) {
        self.title = title
        self.items = items
        self._selection = selection
        self.prominence = prominence
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // An empty title is a caption deliberately omitted (a control
            // whose section header already names it), not a blank line.
            if !title.isEmpty {
                Text(title)
                    .font(HueFont.stageControl)
                    .foregroundStyle(.white.opacity(0.60))
            }
            switch prominence {
            case .chips:
                ChipPickerRow(items: items, selection: $selection)
            case .pads:
                // Pads reflow into a column at accessibility text sizes
                // (review round, B-6): a fixed row of five 73 pt pads wraps
                // its labels mid-word long before the largest sizes.
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 8) {
                        ForEach(items, id: \.value) { item in pad(item) }
                    }
                } else {
                    HStack(spacing: 8) {
                        ForEach(items, id: \.value) { item in pad(item) }
                    }
                }
            }
        }
    }

    private func pad(_ item: ChipPickerRow<Value>.Item) -> some View {
        Button {
            selection = item.value
            HapticManager.shared.selection()
        } label: {
            HStack(spacing: 4) {
                if let icon = item.icon {
                    Image(systemName: icon).font(.caption2.weight(.semibold))
                }
                Text(item.label)
                    .font(HueFont.stageControl)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(selection == item.value
                             ? StagePalette.stage : StagePalette.ink)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selection == item.value
                          ? HuePalette.amber
                          : StagePalette.raised)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.accessibilityLabel ?? item.label)
        .accessibilityAddTraits(selection == item.value ? .isSelected : [])
    }
}

// MARK: - Shared accessibility

private struct InstrumentAccessibility: ViewModifier {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double?
    let format: (Double) -> String
    let onEditingChanged: ((Bool) -> Void)?

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .contain)
            .accessibilityLabel(title)
            .accessibilityValue(format(value))
            .accessibilityAddTraits(.allowsDirectInteraction)
            .accessibilityAdjustableAction { direction in
                let span = range.upperBound - range.lowerBound
                let step = span / 20
                onEditingChanged?(true)
                switch direction {
                case .increment:
                    value = min(range.upperBound, value + step)
                case .decrement:
                    value = max(range.lowerBound, value - step)
                @unknown default:
                    break
                }
                onEditingChanged?(false)
            }
            .accessibilityAction(named: "Reset to default") {
                guard let defaultValue else { return }
                onEditingChanged?(true)
                value = min(range.upperBound, max(range.lowerBound, defaultValue))
                onEditingChanged?(false)
            }
    }
}

private extension View {
    func instrumentAccessibility(title: String, value: Binding<Double>,
                                 range: ClosedRange<Double>, defaultValue: Double?,
                                 format: @escaping (Double) -> String,
                                 onEditingChanged: ((Bool) -> Void)?) -> some View {
        modifier(InstrumentAccessibility(title: title, value: value, range: range,
                                         defaultValue: defaultValue, format: format,
                                         onEditingChanged: onEditingChanged))
    }
}
