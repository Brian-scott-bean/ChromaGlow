// LuminousScenesParts.swift
// ChromaGlow — Luminous design language: pieces the Scenes screens needed
// that the kit didn't have yet (candidates for LuminousKit).
//
//   • LuminousTextField  — a glass text field with an icon, a clear button
//                          and an optional hard character cap.
//   • LuminousChoiceRow  — one selectable row (a room, a zone) for pickers
//                          built from LuminousGroup.

import SwiftUI

// MARK: - Text field

// MARK: - Choice row

/// One selectable row in a glass group: the place's icon (lit when
/// chosen), its name, a quiet detail, an optional tag, and a check.
struct LuminousChoiceRow: View {
    let symbol: String
    let title: String
    var subtitle: String? = nil
    var tag: String? = nil
    let selected: Bool
    var tint: Color = LuminousPalette.cyan

    var body: some View {
        HStack(spacing: 14) {
            LuminousIconBadge(symbol: symbol, tint: selected ? tint : LuminousPalette.inkSecondary,
                              size: 34, lit: selected)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(LuminousPalette.ink)
                        .lineLimit(1)
                    if let tag {
                        Text(tag)
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(LuminousPalette.ink.opacity(0.75))
                            .padding(.horizontal, 6)
                            .frame(minHeight: 18)
                            .background(Capsule().fill(Color.white.opacity(0.1)))
                            .fixedSize()
                    }
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(LuminousPalette.inkSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(selected ? tint : LuminousPalette.inkTertiary)
                .shadow(color: selected ? tint.opacity(0.6) : .clear, radius: 6)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 58)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
    }
}
