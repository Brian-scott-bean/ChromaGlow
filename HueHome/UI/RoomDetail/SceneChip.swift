// SceneChip.swift
// HueHome Pro — Epic 4 / Story 4.1
//
// Individual scene tile in the horizontal scene strip.
// Glassmorphic pill card: icon + name, accent border + glow when active.
// Pressing activates the scene via onTap closure.

import SwiftUI

struct SceneChip: View {

    let scene: SceneDisplayItem
    let onTap: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                // ── Icon circle ───────────────────────────
                ZStack {
                    Circle()
                        .fill(scene.isActive
                              ? scene.accentColor.opacity(0.28)
                              : Color.white.opacity(0.08))
                        .frame(width: 44, height: 44)

                    Image(systemName: scene.icon)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(scene.isActive
                                         ? scene.accentColor
                                         : .white.opacity(0.50))
                        .symbolEffect(.bounce, value: scene.isActive)
                }

                // ── Name ─────────────────────────────────
                Text(scene.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(scene.isActive ? .white : .white.opacity(0.60))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 76)
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
        // Press + release spring animation
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
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
    }
}
