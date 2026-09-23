// Composer2ModeSelector.swift
// ChromaGlow — Composer 2 lab (experimental), v2.2.
//
// Looks · Tune · Layers. Three views into one document — the selector
// switches the view, never the composition. The selected tab carries a glow
// that glides between tabs.

import SwiftUI

struct Composer2ModeSelector: View {
    @Binding var selection: Composer2Mode
    @Namespace private var glow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Composer2Mode.allCases) { segment(for: $0) }
        }
        .padding(4)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Composer sections")
    }

    private func segment(for mode: Composer2Mode) -> some View {
        let selected = mode == selection
        return Button {
            guard !selected else { return }
            HapticManager.shared.selection()
            withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.82)) { selection = mode }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 13, weight: .bold))
                Text(mode.title)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(selected ? Composer2Theme.void : Composer2Theme.ink.opacity(0.7))
            .frame(maxWidth: .infinity)
            .frame(minHeight: 42)
            .background {
                if selected {
                    Capsule()
                        .fill(LinearGradient(colors: [Composer2Theme.cyan, Composer2Theme.violet],
                                             startPoint: .leading, endPoint: .trailing))
                        .shadow(color: Composer2Theme.cyan.opacity(0.45), radius: 12)
                        .matchedGeometryEffect(id: "composer2-mode-glow", in: glow)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
    }
}
