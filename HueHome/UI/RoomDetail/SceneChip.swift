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

    @State private var isPressed = false

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
            .scaleEffect(isPressed ? 0.93 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isActivating)   // prevent double-tap during activation
        .accessibilityLabel(Text("\(scene.name) scene\(scene.isActive ? ", active" : "")"))
        .accessibilityHint(Text(isActivating ? "Activating…" : "Tap to activate"))
        // Press + release spring animation
        // minimumDistance:10 prevents this from eating the horizontal scroll gesture
        .simultaneousGesture(
            DragGesture(minimumDistance: 10)
                .onChanged { _ in
                    withAnimation(.spring(response: 0.18, dampingFraction: 0.6)) {
                        isPressed = true
                    }
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.7)) {
                        isPressed = false
                    }
                }
        )
        .animation(.spring(response: 0.35, dampingFraction: 0.72), value: scene.isActive)
        .animation(.easeInOut(duration: 0.2), value: isActivating)
    }
}
