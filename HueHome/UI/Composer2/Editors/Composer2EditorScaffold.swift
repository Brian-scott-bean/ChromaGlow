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

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(editor.title)
                        .font(HueFont.displaySmall)
                        .foregroundStyle(Composer2Theme.ink)
                    Text(document.selectedLayer.name)
                        .font(HueFont.stageStatus)
                        .foregroundStyle(Composer2Theme.muted)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .font(HueFont.bodyMedium)
                    .foregroundStyle(Composer2Theme.cyan)
                    .frame(minHeight: 44)
                    .accessibilityLabel("Done editing \(editor.title)")
            }
            .padding(.horizontal, HueSpacing.screenH)
            .padding(.top, HueSpacing.lg)
            .padding(.bottom, HueSpacing.sm)

            ScrollView(showsIndicators: false) {
                VStack(spacing: HueSpacing.md) {
                    Composer2EditorContent(document: document, editor: editor)
                    Color.clear.frame(height: HueSpacing.xl)
                }
                .padding(.horizontal, HueSpacing.screenH)
            }
        }
        .background(Composer2Theme.background.ignoresSafeArea())
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
