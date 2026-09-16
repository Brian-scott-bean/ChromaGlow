// Composer2QuickPanel.swift
// ChromaGlow — Composer 2 lab (experimental).
//
// Proof that the engine can be simple: a mood, its colours, and three
// sliders. Everything here writes into the same composition the other
// modes edit.

import SwiftUI

struct Composer2QuickPanel: View {
    let document: Composer2Document
    var onImport: () -> Void = {}
    private let store = Composer2Store.shared

    var body: some View {
        VStack(alignment: .leading, spacing: HueSpacing.lg) {
            section("Mood") {
                moodChips
                Button {
                    HapticManager.shared.light()
                    onImport()
                } label: {
                    Label(Composer2Copy.importLegacyTitle, systemImage: "square.and.arrow.down")
                        .font(HueFont.stageChip)
                        .foregroundStyle(Composer2Theme.cyan)
                        .frame(minHeight: 36)
                }
                .buttonStyle(.plain)
                .accessibilityHint(Composer2Copy.importLegacyHint)
            }
            section("Colours") { colourRow }
            section("Feel") { sliders }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(HueFont.stageTag)
                .foregroundStyle(Composer2Theme.muted)
                .tracking(1.2)
            content()
        }
        .padding(HueSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .composer2Glass()
    }

    // MARK: Mood

    private var moodChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.all) { composition in
                    let selected = document.sourceID == composition.id
                    Button {
                        HapticManager.shared.selection()
                        var next = composition
                        next.target = document.composition.target
                        document.load(next)
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: Composer2PresetLibrary.symbol(for: composition.id))
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(selected ? Composer2Theme.background : Composer2Theme.cyan)
                                .frame(width: 44, height: 44)
                                .background(Circle().fill(selected ? Composer2Theme.cyan : Composer2Theme.cyan.opacity(0.12)))
                            Text(composition.name)
                                .font(HueFont.stageChip)
                                .foregroundStyle(selected ? Composer2Theme.ink : Composer2Theme.muted)
                                .lineLimit(1)
                        }
                        .frame(width: 84)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 14).fill(selected ? Composer2Theme.cyan.opacity(0.12) : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? Composer2Theme.cyan.opacity(0.5) : .clear, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Mood \(composition.name)")
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: Colours

    private var colourRow: some View {
        let stops = document.selectedLayer.color.sanitizedStops
        return HStack(spacing: 10) {
            ForEach(Array(stops.enumerated()), id: \.offset) { _, stop in
                Circle()
                    .fill(Composer2Theme.solidColor(x: stop.x, y: stop.y))
                    .frame(width: 34, height: 34)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                    .shadow(color: Composer2Theme.solidColor(x: stop.x, y: stop.y).opacity(0.5), radius: 6)
            }
            Button {
                HapticManager.shared.light()
                document.activeEditor = .palette
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Composer2Theme.ink)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Composer2Theme.glassRaised))
                    .overlay(Circle().strokeBorder(Composer2Theme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit colours")
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Sliders

    private var sliders: some View {
        VStack(spacing: 14) {
            StageSlider(title: "Intensity", value: binding(\.intensity, range: 0...1), range: 0...1,
                        format: { "\(Int(($0 * 100).rounded()))%" },
                        onEditingChanged: { _ in Composer2PlaybackCenter.shared.noteEditBurst() })
            StageSlider(title: "Speed", value: speedBinding, range: 0...1,
                        format: { Composer2QuickMapping.speedLabel(slider: $0) },
                        onEditingChanged: { _ in Composer2PlaybackCenter.shared.noteEditBurst() })
            StageSlider(title: "Energy", value: energyBinding, range: 0...1,
                        format: { Composer2QuickMapping.energyWord($0) },
                        onEditingChanged: { _ in Composer2PlaybackCenter.shared.noteEditBurst() })
        }
    }

    private func binding(_ keyPath: WritableKeyPath<Composer2MasterControls, Double>, range: ClosedRange<Double>) -> Binding<Double> {
        Binding(
            get: { document.composition.master[keyPath: keyPath] },
            set: { value in document.edit { $0.master[keyPath: keyPath] = Composer2Math.clamp(value, range.lowerBound, range.upperBound) } }
        )
    }

    private var speedBinding: Binding<Double> {
        Binding(
            get: { Composer2QuickMapping.slider(fromSpeed: document.composition.master.speed) },
            set: { value in document.edit { $0.master.speed = Composer2QuickMapping.speed(fromSlider: value) } }
        )
    }

    private var energyBinding: Binding<Double> {
        Binding(
            get: { document.composition.master.energy },
            set: { value in document.edit { Composer2QuickMapping.apply(energy: value, to: &$0) } }
        )
    }
}

// MARK: - Pure mapping

enum Composer2QuickMapping {
    /// Speed slider 0…1 ↔ master speed 0.25…4 (log scale, 0.5 = ×1).
    static func slider(fromSpeed speed: Double) -> Double {
        let s = Composer2Math.clamp(speed, 0.25, 4)
        return Composer2Math.clamp01(0.5 + log2(s) / 4)
    }

    static func speed(fromSlider value: Double) -> Double {
        pow(2, (Composer2Math.clamp01(value) - 0.5) * 4)
    }

    static func speedLabel(slider value: Double) -> String {
        let s = speed(fromSlider: value)
        return String(format: "×%.2g", s)
    }

    static func variationPreset(forEnergy energy: Double) -> Composer2Variation.Preset {
        switch Composer2Math.clamp01(energy) {
        case ..<0.2: return .exact
        case ..<0.4: return .subtle
        case ..<0.6: return .organic
        case ..<0.8: return .evolving
        default: return .wild
        }
    }

    /// Energy scales the composition's variation (0 = exact, 0.5 = as
    /// authored, 1 = doubled) without rewriting any layer's own settings —
    /// Advanced and Expert edits survive a Quick-mode drag.
    static func apply(energy: Double, to composition: inout Composer2Composition) {
        let e = Composer2Math.clamp01(energy)
        composition.master.energy = e
        composition.master.variation = e * 2
    }

    /// The word shown for an energy value.
    static func energyWord(_ energy: Double) -> String {
        switch Composer2Math.clamp01(energy) {
        case ..<0.1: return "Exact"
        case ..<0.35: return "Calm"
        case ..<0.65: return "As authored"
        case ..<0.9: return "Lively"
        default: return "Wild"
        }
    }
}
