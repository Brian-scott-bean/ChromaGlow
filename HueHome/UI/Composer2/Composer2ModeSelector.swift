// Composer2ModeSelector.swift
// ChromaGlow — Composer 2 lab (experimental).
//
// Quick / Customize / Advanced / Expert. Four views into one document — the
// selector switches the view, never the composition.

import SwiftUI

struct Composer2ModeSelector: View {
    @Binding var selection: Composer2Mode
    @Namespace private var glow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(Composer2Mode.allCases) { segment(for: $0) }
                }
            } else {
                HStack(spacing: 4) {
                    ForEach(Composer2Mode.allCases) { segment(for: $0) }
                }
            }
        }
        .padding(4)
        .background(Capsule().fill(Composer2Theme.glass))
        .overlay(Capsule().strokeBorder(Composer2Theme.line, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Composer mode")
    }

    private func segment(for mode: Composer2Mode) -> some View {
        let selected = mode == selection
        return Button {
            guard !selected else { return }
            HapticManager.shared.selection()
            withAnimation(reduceMotion ? nil : HueAnimation.fast) { selection = mode }
        } label: {
            Text(mode.title)
                .font(HueFont.stageChip)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(selected ? Composer2Theme.ink : Composer2Theme.muted)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 38)
                .background {
                    if selected {
                        Capsule()
                            .fill(Composer2Theme.cyan.opacity(0.16))
                            .overlay(Capsule().strokeBorder(Composer2Theme.cyan.opacity(0.55), lineWidth: 1))
                            .shadow(color: Composer2Theme.cyan.opacity(0.35), radius: 10)
                            .matchedGeometryEffect(id: "composer2-mode-glow", in: glow)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(mode.title) mode")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
    }
}
