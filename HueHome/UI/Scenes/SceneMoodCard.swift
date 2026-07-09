// SceneMoodCard.swift
// ChromaGlow — Scenes Browser
//
// The scene card used across the Scenes tab: icon + name + room label +
// STUDIO provenance badge + active indicator, with a SPEED overlay button
// on dynamic scenes. Extracted verbatim from ScenesTabView.swift (Phase 0
// of the Scenes overhaul) — no behavior change.

import SwiftUI

// ══════════════════════════════════════════════════════════
// MARK: - SceneMoodCard
// ══════════════════════════════════════════════════════════

struct SceneMoodCard: View {

    let scene:       GlobalSceneItem
    let roomName:    String
    /// Hidden inside a room's own section (redundant there); shown on the
    /// Favorites shelf, search results, and flat sort modes.
    var showsRoomLabel: Bool = true
    var isFavorite:  Bool = false
    var isStudio:    Bool = false
    let onActivate:  () -> Void
    let onLongPress: () -> Void

    var body: some View {
        Button(action: onActivate) {
            HStack(alignment: .center, spacing: 12) {

                // ── Icon (with optional SPEED badge) ──────────────────────
                ZStack(alignment: .bottomTrailing) {
                    Circle()
                        .fill(scene.accentColor.opacity(scene.isActive ? 0.30 : 0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: scene.icon)
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(scene.accentColor)
                        .symbolEffect(.pulse, isActive: scene.isActive)
                        .frame(width: 44, height: 44)
                    if scene.isDynamic {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(Circle().fill(scene.accentColor))
                            .offset(x: 4, y: 4)
                    }
                }

                // ── Text ──────────────────────────────────────────────────
                VStack(alignment: .leading, spacing: 3) {
                    Text(scene.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if showsRoomLabel {
                            Text(roomName)
                                .font(.system(size: 9, weight: .semibold))
                                .tracking(1.0)
                                .textCase(.uppercase)
                                .foregroundStyle(StagePalette.muted)
                                .lineLimit(1)
                        }
                        // Provenance: exported from the Studio Composer.
                        if isStudio {
                            StageBadge(text: "STUDIO", style: .amber)
                        }
                    }

                    // Live pattern signature on running dynamic scenes —
                    // decorative wave, same convention as engine cards.
                    if scene.isDynamic && scene.isActive {
                        PatternStripView(pattern: .wave, accent: scene.accentColor)
                            .padding(.top, 4)
                            .frame(maxWidth: 120)
                    }
                }

                Spacer()

                // ── Active indicator + play affordance ────────────────────
                HStack(spacing: 8) {
                    if isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(HuePalette.amber)
                    }
                    if scene.isActive {
                        Circle().fill(.green).frame(width: 7, height: 7)
                    }
                    Image(systemName: scene.isActive ? "play.circle.fill" : "play.circle")
                        .font(.system(size: 22))
                        .foregroundStyle(scene.isActive
                            ? scene.accentColor
                            : .white.opacity(0.28))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 76)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(scene.isActive
                          ? scene.accentColor.opacity(0.13)
                          : Color.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(
                                scene.isActive
                                    ? scene.accentColor.opacity(0.55)
                                    : StagePalette.line,
                                lineWidth: scene.isActive ? 1.5 : 1
                            )
                    )
            )
            .shadow(color: scene.isActive ? scene.accentColor.opacity(0.25) : .clear,
                    radius: 12, x: 0, y: 4)
        }
        .buttonStyle(SceneCardPressStyle())
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint("Double tap to activate")
        // SPEED button overlaid for dynamic scenes — intercepts taps in its hit area
        .overlay(alignment: .topTrailing) {
            if scene.isDynamic {
                Button(action: onLongPress) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(scene.accentColor.opacity(0.75))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Scene speed")
                .padding(.top, 6)
                .padding(.trailing, 6)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.72), value: scene.isActive)
    }

    private var accessibilityDescription: String {
        var parts = ["\(scene.name), \(roomName)"]
        if scene.isDynamic { parts.append("dynamic") }
        if scene.isActive { parts.append("active") }
        if isFavorite { parts.append("favorite") }
        if isStudio { parts.append("created in Studio") }
        return parts.joined(separator: ", ")
    }
}

private struct SceneCardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7),
                       value: configuration.isPressed)
    }
}

// ══════════════════════════════════════════════════════════
// MARK: - SceneShimmerCard
// ══════════════════════════════════════════════════════════

struct SceneShimmerCard: View {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shimmerPhase: CGFloat = -1

    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.white.opacity(0.05))
            .overlay {
                if !reduceMotion {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.clear, .white.opacity(0.07), .clear],
                                startPoint: .init(x: shimmerPhase, y: 0),
                                endPoint:   .init(x: shimmerPhase + 0.5, y: 1)
                            )
                        )
                }
            }
            .aspectRatio(0.88, contentMode: .fit)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    shimmerPhase = 1.5
                }
            }
    }
}
