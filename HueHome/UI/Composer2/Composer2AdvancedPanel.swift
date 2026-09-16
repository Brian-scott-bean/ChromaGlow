// Composer2AdvancedPanel.swift
// ChromaGlow — Composer 2 lab (experimental).
//
// Every detail of the selected behavior, in place, as expandable sections —
// no modular stack required. The sections embed the same editor content the
// Customize cards open in sheets.

import SwiftUI

struct Composer2AdvancedPanel: View {
    let document: Composer2Document
    @State private var expanded: Set<Composer2Editor> = []
    @State private var seeded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let order: [(Composer2Editor, String)] = [
        (.palette, "Palette details"),
        (.motion, "Motion physics"),
        (.rhythm, "Rhythm"),
        (.space, "Spatial distribution"),
        (.events, "Event timing"),
        (.audio, "Audio response"),
        (.variation, "Variation")
    ]

    var body: some View {
        VStack(spacing: HueSpacing.md) {
            if document.composition.layers.count > 1 {
                Composer2LayerPicker(document: document)
            }
            ForEach(order, id: \.0) { editor, title in
                section(editor, title: title)
            }
        }
        .onAppear {
            guard !seeded else { return }
            seeded = true
            expanded = [document.selectedLayer.events != nil ? .events : .palette]
        }
    }

    private func section(_ editor: Composer2Editor, title: String) -> some View {
        let isOpen = expanded.contains(editor)
        let accent = editor.dimension.map { Composer2Theme.accent(for: $0) } ?? Composer2Theme.coral
        return VStack(spacing: 0) {
            Button {
                HapticManager.shared.selection()
                withAnimation(reduceMotion ? nil : HueAnimation.fast) {
                    if isOpen { expanded.remove(editor) } else { expanded.insert(editor) }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: editor.dimension?.symbol ?? "bolt.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(accent.opacity(0.14)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(HueFont.stageName)
                            .foregroundStyle(Composer2Theme.ink)
                        Text(summary(for: editor))
                            .font(HueFont.stageStatus)
                            .foregroundStyle(Composer2Theme.muted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Composer2Theme.muted)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .padding(HueSpacing.lg)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(summary(for: editor))")
            .accessibilityHint(isOpen ? "Collapses the section" : "Expands the section")

            if isOpen {
                Composer2EditorContent(document: document, editor: editor)
                    .padding(.horizontal, HueSpacing.sm)
                    .padding(.bottom, HueSpacing.md)
                    .transition(.opacity)
            }
        }
        .composer2Glass(accent: accent, selected: isOpen)
    }

    private func summary(for editor: Composer2Editor) -> String {
        let layer = document.selectedLayer
        switch editor {
        case .palette: return Composer2Copy.summary(color: layer.color)
        case .motion: return Composer2Copy.summary(motion: layer.motion)
        case .rhythm: return Composer2Copy.summary(rhythm: layer.rhythm)
        case .space: return Composer2Copy.summary(mask: layer.mask, total: document.roomContext.layout.count, direction: layer.motion)
        case .events: return Composer2Copy.summary(events: layer.events)
        case .audio: return Composer2Copy.summary(audio: layer.audio)
        case .variation: return Composer2Copy.summary(variation: layer.variation)
        }
    }
}
