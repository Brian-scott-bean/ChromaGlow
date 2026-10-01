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

/// A glass text field: an icon that lights in the field's colour, the text,
/// a clear button, and — with `limit` — a hard cap that counts down in the
/// last few characters (bridge names cap at 32).
struct LuminousTextField: View {
    let placeholder: String
    @Binding var text: String
    var symbol: String? = nil
    var tint: Color = LuminousPalette.cyan
    var limit: Int? = nil
    var autofocus: Bool = false
    var onSubmit: () -> Void = {}

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(focused || !text.isEmpty ? tint : LuminousPalette.inkSecondary)
                        .accessibilityHidden(true)
                }
                TextField(placeholder, text: $text)
                    .font(.body)
                    .foregroundStyle(LuminousPalette.ink)
                    .tint(tint)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit(onSubmit)
                if !text.isEmpty {
                    Button {
                        text = ""
                        HapticManager.shared.light()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(LuminousPalette.inkSecondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear")
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, text.isEmpty ? 14 : 0)
            .frame(minHeight: 50)
            .luminousGlass(radius: 16, accent: tint, selected: focused)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: focused)

            if let limit, text.count > limit - 4 {
                Text("\(max(0, limit - text.count)) characters remaining")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(text.count >= limit ? LuminousPalette.danger : LuminousPalette.inkSecondary)
                    .padding(.horizontal, 6)
            }
        }
        .onChange(of: text) { _, newValue in
            if let limit, newValue.count > limit {
                text = String(newValue.prefix(limit))
            }
        }
        .onAppear { if autofocus { focused = true } }
    }
}

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
