// HueToastView.swift
// CastChroma
//
// Lightweight top-of-screen toast for transient error messages.
// Displayed as a glass pill with a warning icon — auto-dismissed after 3 s
// by the caller (orchestrator / vm). Allows hit-testing on the content behind.

import SwiftUI

struct HueToastView: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.wifi")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(red: 1.0, green: 0.76, blue: 0.2))
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        .accessibilityLabel(Text("Error: \(message)"))
        .accessibilityAddTraits(.isStaticText)
    }
}

#Preview {
    ZStack {
        Color(red: 0.05, green: 0.05, blue: 0.08).ignoresSafeArea()
        HueToastView(message: "Couldn't reach bridge — Hallway reverted")
            .padding(.horizontal, 24)
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
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.green)
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
            Button(action: action) {
                Text(actionTitle)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color(red: 1.0, green: 0.76, blue: 0.2))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
    }
}
