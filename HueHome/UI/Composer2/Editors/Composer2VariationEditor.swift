// Composer2VariationEditor.swift
// ChromaGlow — Composer 2 lab (experimental).
//
// The difference between a loop and something alive. Seeded, so the same
// seed reproduces the same sequence when that matters.

import SwiftUI

struct Composer2VariationEditorContent: View {
    let document: Composer2Document

    private var variation: Composer2Variation { document.selectedLayer.variation }

    var body: some View {
        VStack(spacing: HueSpacing.md) {
            Composer2EditorSection(title: "Preset") {
                Composer2ChipRow(title: "Feel", options: Composer2Variation.Preset.allCases.map {
                    (Composer2Copy.presetName($0), $0, nil)
                }, selection: Binding(
                    get: { variation.matchingPreset ?? .organic },
                    set: { preset in
                        let seed = variation.seed
                        document.editSelectedLayer { $0.variation = preset.value.withSeed(seed) }
                    }))
                Composer2SliderRow(title: "Amount", value: document.layerBinding(\.variation.amount), range: 0...1)
            }
            Composer2EditorSection(title: "Seed", subtitle: "The same seed plays the same sequence. Reseed for a fresh take.") {
                HStack(spacing: 12) {
                    Text(seedText)
                        .font(HueFont.stageValue)
                        .foregroundStyle(Composer2Theme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Spacer(minLength: 0)
                    Button {
                        HapticManager.shared.medium()
                        let fresh = Composer2Hash.mix(UInt64(Date().timeIntervalSince1970 * 1000), UInt64(document.selectedLayerIndex + 1))
                        document.editSelectedLayer { $0.variation.seed = fresh }
                    } label: {
                        Label("Reseed", systemImage: "dice")
                            .font(HueFont.bodyMedium)
                            .foregroundStyle(Composer2Theme.ink)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .background(Capsule().fill(Composer2Theme.glassRaised))
                            .overlay(Capsule().strokeBorder(Composer2Theme.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    if variation.seed != nil {
                        Button("Auto") {
                            HapticManager.shared.selection()
                            document.editSelectedLayer { $0.variation.seed = nil }
                        }
                        .font(HueFont.stageChip)
                        .foregroundStyle(Composer2Theme.cyan)
                        .frame(minHeight: 44)
                        .accessibilityLabel("Use the automatic seed")
                    }
                }
            }
            Composer2EditorSection(title: "Details") {
                Composer2SliderRow(title: "Speed variation", value: document.layerBinding(\.variation.speedVariation), range: 0...1)
                Composer2SliderRow(title: "Brightness variation", value: document.layerBinding(\.variation.brightnessVariation), range: 0...1)
                Composer2SliderRow(title: "Palette drift", value: document.layerBinding(\.variation.paletteDrift), range: 0...1)
                Composer2SliderRow(title: "Per-light phase", value: document.layerBinding(\.variation.perLightPhase), range: 0...1)
                Composer2SliderRow(title: "Event timing", value: document.layerBinding(\.variation.eventTiming), range: 0...1)
                Composer2SliderRow(title: "Spatial randomness", value: document.layerBinding(\.variation.spatialRandomness), range: 0...1)
                Composer2SliderRow(title: "Evolve", value: document.layerBinding(\.variation.evolveRate), range: 0...1,
                                   format: { $0 <= 0 ? "frozen" : "\(Int(($0 * 100).rounded()))%" })
            }
        }
    }

    private var seedText: String {
        if let seed = variation.seed { return "Seed \(seed)" }
        return "Seed: automatic (from the layer)"
    }
}
