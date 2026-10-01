// HueToastView.swift
// ChromaGlow — the app-wide toasts (Luminous).
//
// HueToastView: a glass pill for transient failures (bridge unreachable,
// guest refusals) — drawn once, over every tab, by MainTabView; the caller
// owns the auto-dismiss. HueActionToast: the same pill with an undo-style
// action (scene copy/move).

import SwiftUI

struct HueToastView: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(LuminousPalette.amber)
            Text(message)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(LuminousPalette.ink)
                .lineLimit(2)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Capsule().fill(.ultraThinMaterial))
        .background(Capsule().fill(LuminousPalette.void.opacity(0.5)))
        .overlay(Capsule().strokeBorder(LuminousPalette.amber.opacity(0.35), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
        .padding(.horizontal, 20)
        .accessibilityLabel(Text("Error: \(message)"))
        .accessibilityAddTraits(.isStaticText)
    }
}

#Preview {
    ZStack {
        LuminousPalette.void.ignoresSafeArea()
        HueToastView(message: "Couldn't reach bridge — Hallway reverted")
    }
}

// MARK: - HueActionToast

/// Toast with a trailing action button — used for undoable operations
/// (scene copy/move). The caller owns the dismiss timer.
struct HueActionToast: View {
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(LuminousPalette.live)
            Text(message)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(LuminousPalette.ink)
                .lineLimit(2)
            Button(action: action) {
                Text(actionTitle)
                    .font(.system(.footnote, design: .rounded).weight(.heavy))
                    .foregroundStyle(LuminousPalette.cyan)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .frame(minHeight: 44)
        .background(Capsule().fill(.ultraThinMaterial))
        .background(Capsule().fill(LuminousPalette.void.opacity(0.5)))
        .overlay(Capsule().strokeBorder(LuminousPalette.live.opacity(0.35), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
    }
}
