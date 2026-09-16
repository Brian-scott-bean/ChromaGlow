// Composer2CustomizeGrid.swift
// ChromaGlow — Composer 2 lab (experimental).
//
// The six creative dimensions of the selected behavior, as an adaptive grid
// of cards, followed by the door into Expert mode.

import SwiftUI

struct Composer2CustomizeGrid: View {
    let document: Composer2Document

    private let columns = [GridItem(.adaptive(minimum: 168, maximum: 400), spacing: HueSpacing.md)]

    var body: some View {
        VStack(spacing: HueSpacing.md) {
            if document.composition.layers.count > 1 {
                Composer2LayerPicker(document: document)
            }
            LazyVGrid(columns: columns, spacing: HueSpacing.md) {
                ForEach(Composer2Dimension.allCases) { dimension in
                    card(for: dimension)
                }
            }
            Composer2BuildYourOwnCard(layerCount: document.composition.layers.count) {
                document.mode = .expert
            }
        }
    }

    @ViewBuilder
    private func card(for dimension: Composer2Dimension) -> some View {
        let layer = document.selectedLayer
        let total = document.roomContext.layout.count
        switch dimension {
        case .palette:
            Composer2LayerCard(dimension: .palette, valueText: Composer2Copy.summary(color: layer.color),
                               isOn: true, showsToggle: false,
                               onOpen: { document.activeEditor = .palette }, onToggle: { _ in }) {
                Composer2PalettePreview(color: layer.color)
            }
        case .motion:
            Composer2LayerCard(dimension: .motion, valueText: Composer2Copy.summary(motion: layer.motion),
                               isOn: dimension.isOn(in: layer), showsToggle: true,
                               onOpen: { document.activeEditor = .motion },
                               onToggle: { document.setDimension(.motion, on: $0) }) {
                Composer2MotionPreview(motion: layer.motion, accent: Composer2Theme.accent(for: .motion))
            }
        case .rhythm:
            Composer2LayerCard(dimension: .rhythm, valueText: Composer2Copy.summary(rhythm: layer.rhythm),
                               isOn: dimension.isOn(in: layer), showsToggle: true,
                               onOpen: { document.activeEditor = .rhythm },
                               onToggle: { document.setDimension(.rhythm, on: $0) }) {
                Composer2RhythmPreview(rhythm: layer.rhythm, accent: Composer2Theme.accent(for: .rhythm))
            }
        case .space:
            Composer2LayerCard(dimension: .space, valueText: Composer2Copy.summary(mask: layer.mask, total: total, direction: layer.motion),
                               isOn: true, showsToggle: false,
                               onOpen: { document.activeEditor = .space }, onToggle: { _ in }) {
                Composer2SpacePreview(mask: layer.mask, motion: layer.motion, layout: document.roomContext.layout,
                                      accent: Composer2Theme.accent(for: .space))
            }
        case .audio:
            Composer2LayerCard(dimension: .audio, valueText: Composer2Copy.summary(audio: layer.audio),
                               isOn: dimension.isOn(in: layer), showsToggle: true,
                               onOpen: { document.activeEditor = .audio },
                               onToggle: { document.setDimension(.audio, on: $0) }) {
                Composer2AudioPreview(audio: layer.audio, accent: Composer2Theme.accent(for: .audio))
            }
        case .variation:
            Composer2LayerCard(dimension: .variation, valueText: Composer2Copy.summary(variation: layer.variation),
                               isOn: dimension.isOn(in: layer), showsToggle: true,
                               onOpen: { document.activeEditor = .variation },
                               onToggle: { document.setDimension(.variation, on: $0) }) {
                Composer2VariationPreview(variation: layer.variation, accent: Composer2Theme.accent(for: .variation))
            }
        }
    }
}

// MARK: - Layer picker (multi-behavior compositions)

struct Composer2LayerPicker: View {
    let document: Composer2Document

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(document.composition.layers) { layer in
                    let selected = layer.id == document.selectedLayerID
                    Button {
                        HapticManager.shared.selection()
                        document.select(layerID: layer.id)
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(layer.enabled ? Composer2Theme.cyan : Composer2Theme.muted).frame(width: 6, height: 6)
                            Text(layer.name).font(HueFont.stageChip).lineLimit(1)
                        }
                        .foregroundStyle(selected ? Composer2Theme.ink : Composer2Theme.muted)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 34)
                        .background(Capsule().fill(selected ? Composer2Theme.cyan.opacity(0.16) : Composer2Theme.glass))
                        .overlay(Capsule().strokeBorder(selected ? Composer2Theme.cyan.opacity(0.5) : Composer2Theme.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Behavior \(layer.name)")
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityLabel("Behaviors")
    }
}

// MARK: - Dimension on/off semantics

extension Composer2Dimension {
    /// Whether the dimension is "doing something" on this layer.
    func isOn(in layer: Composer2Layer) -> Bool {
        switch self {
        case .palette: return true
        case .motion: return layer.motion.kind != .static
        case .rhythm: return layer.rhythm.shape != .steady
        case .space: return true
        case .audio: return layer.audio.isActive
        case .variation: return layer.variation.amount > 0
        }
    }
}

extension Composer2Document {
    /// Turn a dimension off without losing its settings, and back on with a
    /// sensible restore (the last kind is kept in the value itself where possible).
    func setDimension(_ dimension: Composer2Dimension, on: Bool) {
        editSelectedLayer { layer in
            switch dimension {
            case .palette, .space:
                break
            case .motion:
                if on {
                    if layer.motion.kind == .static { layer.motion.kind = .flow }
                } else {
                    layer.motion.kind = .static
                }
            case .rhythm:
                if on {
                    if layer.rhythm.shape == .steady { layer.rhythm.shape = .breathe }
                } else {
                    layer.rhythm.shape = .steady
                }
            case .audio:
                if on {
                    if !layer.audio.isActive { layer.audio.source = .amplitude }
                } else {
                    layer.audio.source = .off
                }
            case .variation:
                if on {
                    if layer.variation.amount <= 0 { layer.variation = .organic }
                } else {
                    layer.variation.amount = 0
                }
            }
        }
    }
}
