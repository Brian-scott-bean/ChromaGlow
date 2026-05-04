// SceneChip.swift
// CastChroma — Stage 1 (renamed RoomSceneChip to avoid conflict with HueComponents.SceneChip)
//
// Full-featured scene tile for Room Detail's horizontal scene strip.
// Takes a SceneDisplayItem with isActive state and accent color.
// isActivating: true while API call is in flight → shows spinner, disables double-tap.

import SwiftUI

struct RoomSceneChip: View {

    let scene: SceneDisplayItem
    let isActivating: Bool   // true while API call is in flight → shows spinner
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                // ── Icon circle (spinner when activating) ──────────────────────────
                ZStack {
                    Circle()
                        .fill(scene.isActive
                              ? scene.accentColor.opacity(0.28)
                              : Color.white.opacity(0.08))
                        .frame(width: 44, height: 44)

                    if isActivating {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(scene.accentColor)
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: scene.icon)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(scene.isActive
                                             ? scene.accentColor
                                             : .white.opacity(0.50))
                            .symbolEffect(.bounce, value: scene.isActive)
                    }
                }

                // ── Name ─────────────────────────────────
                Text(scene.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(scene.isActive ? .white : .white.opacity(0.60))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .truncationMode(.tail)
            }
            .frame(width: 76, height: 80)
            .padding(.vertical, 14)
            .padding(.horizontal, 8)
            .background {
                // Glass surface
                RoundedRectangle(cornerRadius: 18)
                    .fill(.ultraThinMaterial)
                // Accent glow when active
                if scene.isActive {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(scene.accentColor.opacity(0.12))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(
                        scene.isActive
                            ? scene.accentColor.opacity(0.70)
                            : Color.white.opacity(0.12),
                        lineWidth: scene.isActive ? 1.5 : 1
                    )
            }
            .shadow(
                color: scene.isActive ? scene.accentColor.opacity(0.45) : .clear,
                radius: 12, x: 0, y: 4
            )
        }
        // Custom ButtonStyle handles press scale WITHOUT a DragGesture —
        // DragGesture was stealing the horizontal ScrollView's pan on iPhone.
        .buttonStyle(SceneChipButtonStyle())
        .disabled(isActivating)
        .accessibilityLabel(Text("\(scene.name) scene\(scene.isActive ? ", active" : "")"))
        .accessibilityHint(Text(isActivating ? "Activating…" : "Tap to activate"))
        .animation(.spring(response: 0.35, dampingFraction: 0.72), value: scene.isActive)
        .animation(.easeInOut(duration: 0.2), value: isActivating)
    }
}

/// Scroll-friendly press animation. Unlike DragGesture, ButtonStyle's
/// isPressed is managed by UIKit's gesture system which correctly defers
/// to scroll gestures — so horizontal ScrollView swiping works on iPhone.
private struct SceneChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.65), value: configuration.isPressed)
    }
}
