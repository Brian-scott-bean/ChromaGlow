// Composer2EditorScaffold.swift
// ChromaGlow — Composer 2 lab (experimental).
//
// Sheet chrome and the shared rows every editor is built from. Each editor
// ships a `…Content` view (embeddable in Advanced mode) and opens in this
// sheet from a Customize card.

import SwiftUI

struct Composer2EditorSheet: View {
    let document: Composer2Document
    let editor: Composer2Editor
    let feed: Composer2PreviewFeed
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Composer2Editor
    @Namespace private var tabGlow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(document: Composer2Document, editor: Composer2Editor, feed: Composer2PreviewFeed) {
        self.document = document
        self.editor = editor
        self.feed = feed
        _tab = State(initialValue: editor)
    }

    private var accent: Color {
        tab.dimension.map { Composer2Theme.accent(for: $0) } ?? Composer2Theme.coral
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(document.selectedLayer.name)
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .foregroundStyle(Composer2Theme.ink)
                        .lineLimit(1)
                    Text("Changes play instantly")
                        .font(.caption)
                        .foregroundStyle(Composer2Theme.muted)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .font(.headline)
                    .foregroundStyle(Composer2Theme.cyan)
                    .frame(minHeight: 44)
                    .accessibilityLabel("Done editing \(document.selectedLayer.name)")
            }
            .padding(.horizontal, HueSpacing.screenH)
            .padding(.top, HueSpacing.lg)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Composer2Editor.allCases) { item in
                        let selected = item == tab
                        let itemAccent = item.dimension.map { Composer2Theme.accent(for: $0) } ?? Composer2Theme.coral
                        Button {
                            HapticManager.shared.selection()
                            withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) { tab = item }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: item.symbol).font(.system(size: 12, weight: .bold))
                                Text(item.title).font(.subheadline.weight(.semibold))
                            }
                            .foregroundStyle(selected ? Composer2Theme.void : Composer2Theme.ink.opacity(0.8))
                            .padding(.horizontal, 12)
                            .frame(minHeight: 38)
                            .background {
                                if selected {
                                    Capsule().fill(itemAccent)
                                        .shadow(color: itemAccent.opacity(0.5), radius: 10)
                                        .matchedGeometryEffect(id: "editor-tab", in: tabGlow)
                                } else {
                                    Capsule().fill(Color.white.opacity(0.06))
                                }
                            }
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(item.title)
                        .accessibilityAddTraits(selected ? [.isSelected] : [])
                    }
                }
                .padding(.horizontal, HueSpacing.screenH)
                .padding(.vertical, 10)
            }

            ScrollView(showsIndicators: false) {
                VStack(spacing: HueSpacing.md) {
                    Composer2EditorContent(document: document, editor: tab)
                        .id(tab)
                        .transition(.opacity)
                    Color.clear.frame(height: HueSpacing.xl)
                }
                .padding(.horizontal, HueSpacing.screenH)
            }
        }
        .background(
            ZStack {
                Composer2Theme.background
                RadialGradient(colors: [accent.opacity(0.14), .clear], center: .top, startRadius: 0, endRadius: 420)
            }
            .ignoresSafeArea()
        )
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Composer2Theme.background)
        .preferredColorScheme(.dark)
    }
}

/// Routes an editor id to its content view.
struct Composer2EditorContent: View {
    let document: Composer2Document
    let editor: Composer2Editor

    var body: some View {
        switch editor {
        case .palette: Composer2PaletteEditorContent(document: document)
        case .motion: Composer2MotionEditorContent(document: document)
        case .rhythm: Composer2RhythmEditorContent(document: document)
        case .space: Composer2SpaceEditorContent(document: document)
        case .audio: Composer2AudioEditorContent(document: document)
        case .variation: Composer2VariationEditorContent(document: document)
        case .events: Composer2EventsEditorContent(document: document)
        case .layer: Composer2LayerSettingsContent(document: document)
        }
    }
}

/// The behavior itself: its name, how strongly it contributes, how it
/// blends with the layers below, and whether it plays at all.
struct Composer2LayerSettingsContent: View {
    let document: Composer2Document

    var body: some View {
        VStack(spacing: HueSpacing.md) {
            Composer2EditorSection(title: "Behavior") {
                TextField("Name", text: Binding(
                    get: { document.selectedLayer.name },
                    set: { name in
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { document.editSelectedLayer { $0.name = trimmed } }
                    }))
                    .font(.headline)
                    .foregroundStyle(Composer2Theme.ink)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
                    .accessibilityLabel("Behavior name")
                StageToggleRow(title: "Playing", isOn: document.layerBinding(\.enabled))
                Composer2SliderRow(title: "Strength", value: document.layerBinding(\.opacity), range: 0...1)
            }
            Composer2EditorSection(title: "Blend", subtitle: "How this behavior lands on the ones below it.") {
                Composer2ChipRow(title: "Mode", options: [
                    ("Covers below", Composer2BlendMode.replace, "square.fill"),
                    ("Adds light", .addLighten, "plus.circle.fill"),
                    ("Brighter wins", .maxBrightness, "arrow.up.circle.fill")
                ], selection: document.layerBinding(\.blend))
            }
        }
    }
}

// MARK: - Shared rows

struct Composer2EditorSection<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(HueFont.stageTag)
                    .foregroundStyle(Composer2Theme.muted)
                    .tracking(1.2)
                if let subtitle {
                    Text(subtitle)
                        .font(HueFont.caption)
                        .foregroundStyle(Composer2Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content()
        }
        .padding(HueSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .composer2Glass()
    }
}

/// A `StageSlider` that flushes Room-mode writes when the gesture ends.
struct Composer2SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.0f%%", $0 * 100) }

    var body: some View {
        StageSlider(title: title, value: $value, range: range, format: format,
                    onEditingChanged: { editing in
                        if !editing { Composer2PlaybackCenter.shared.noteEditBurst() }
                    })
    }
}

struct Composer2ChipRow<Value: Hashable>: View {
    let title: String
    let options: [(label: String, value: Value, icon: String?)]
    @Binding var selection: Value

    var body: some View {
        StageSteppedEncoder(
            title: title,
            items: options.map { ChipPickerRow<Value>.Item(value: $0.value, label: $0.label, icon: $0.icon) },
            selection: Binding(get: { selection }, set: { newValue in
                if newValue != selection {
                    HapticManager.shared.selection()
                    selection = newValue
                    Composer2PlaybackCenter.shared.noteEditBurst()
                }
            }),
            prominence: .chips)
    }
}

struct Composer2StepperRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var format: (Int) -> String = { "\($0)" }

    var body: some View {
        HStack {
            Text(title)
                .font(HueFont.stageControl)
                .foregroundStyle(Composer2Theme.ink)
            Spacer()
            Text(format(value))
                .font(HueFont.stageValue)
                .foregroundStyle(Composer2Theme.muted)
            Stepper("", value: Binding(get: { value }, set: { newValue in
                value = min(range.upperBound, max(range.lowerBound, newValue))
                HapticManager.shared.selection()
                Composer2PlaybackCenter.shared.noteEditBurst()
            }), in: range)
            .labelsHidden()
            .accessibilityLabel(title)
            .accessibilityValue(format(value))
        }
        .frame(minHeight: 44)
    }
}

// MARK: - Bindings into the selected layer

extension Composer2Document {
    func layerBinding<T>(_ keyPath: WritableKeyPath<Composer2Layer, T>) -> Binding<T> {
        Binding(
            get: { self.selectedLayer[keyPath: keyPath] },
            set: { value in self.editSelectedLayer { $0[keyPath: keyPath] = value } }
        )
    }

    /// A 0…1 slider over a log-scaled seconds range.
    func logSecondsBinding(_ keyPath: WritableKeyPath<Composer2Layer, Double>, range: ClosedRange<Double>) -> Binding<Double> {
        let lo = log(range.lowerBound), hi = log(range.upperBound)
        return Binding(
            get: {
                let v = Composer2Math.clamp(self.selectedLayer[keyPath: keyPath], range.lowerBound, range.upperBound)
                return (log(v) - lo) / (hi - lo)
            },
            set: { t in
                let v = exp(lo + Composer2Math.clamp01(t) * (hi - lo))
                self.editSelectedLayer { $0[keyPath: keyPath] = v }
            }
        )
    }

    /// Seconds within a log-scaled range, for readouts.
    func logSeconds(_ t: Double, range: ClosedRange<Double>) -> Double {
        let lo = log(range.lowerBound), hi = log(range.upperBound)
        return exp(lo + Composer2Math.clamp01(t) * (hi - lo))
    }
}

func composer2Seconds(_ s: Double) -> String {
    if s < 1 { return String(format: "%.2f s", s) }
    if s < 10 { return String(format: "%.1f s", s) }
    return String(format: "%.0f s", s)
}
