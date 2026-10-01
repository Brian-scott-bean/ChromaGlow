// LuminousSceneCard.swift
// ChromaGlow — Scenes (Luminous): one scene, drawn as the light it makes.
//
// The card's art is an arc of orbs in the scene's colours over the void —
// the same orbs Home draws for a room's lamps and the Composer draws for a
// look — so a scene reads as light, not as an icon. Static by design (no
// clock): a scene is a still mood. Active scenes glow in their own colour
// with a green "On" badge; dynamic scenes carry a Speed button; favourites
// a star; scenes exported from Studio say so.

import SwiftUI
import UIKit

// MARK: - Palette

enum LuminousScenePalette {
    /// The colours a scene paints with: its real palette when the bridge
    /// listed one, otherwise its name-derived tint spread into neighbouring
    /// shades (wider for dynamic scenes, whose colours move).
    static func colors(for scene: GlobalSceneItem) -> [Color] {
        if !scene.paletteXY.isEmpty {
            return scene.paletteXY.map { HueColorUtils.color(fromX: $0.x, y: $0.y, brightness: 100) }
        }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(scene.accentColor).getHue(&h, saturation: &s, brightness: &b, alpha: &a) else {
            return [scene.accentColor]
        }
        let spread: CGFloat = scene.isDynamic ? 0.09 : 0.035
        func shade(_ dh: CGFloat, _ ds: CGFloat, _ db: CGFloat) -> Color {
            let hue = (h + dh + 1).truncatingRemainder(dividingBy: 1)
            return Color(hue: Double(hue),
                         saturation: Double(min(1, max(0, s * ds))),
                         brightness: Double(min(1, max(0.4, b * db))))
        }
        return [shade(-spread, 0.85, 1), shade(0, 1, 1), shade(spread, 1, 0.92)]
    }

    /// The one colour a scene stands for (edges, glows, its icon).
    static func accent(for scene: GlobalSceneItem) -> Color {
        let colors = colors(for: scene)
        return colors[colors.count / 2]
    }
}

// MARK: - Art

/// An arc of orbs in a scene's colours, lit brighter while it is on.
struct LuminousSceneArt: View {
    let colors: [Color]
    var isActive: Bool = false
    var lamps: Int = 5
    var height: CGFloat = 74

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, size in
            guard !colors.isEmpty else { return }
            let level = isActive ? 0.95 : 0.6
            let spots = (0..<max(1, lamps)).map { i in (colors[i % colors.count], level) }
            LuminousMiniRoomStage.draw(in: &ctx, size: size, lamps: spots, wash: isActive ? 0.9 : 0.7)
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - Card

struct LuminousSceneCard: View {

    let scene: GlobalSceneItem
    let roomName: String
    /// Hidden inside a room's own section (redundant there); shown on the
    /// shelves, in search results and in the flat sort modes.
    var showsRoomLabel: Bool = true
    var isFavorite: Bool = false
    var isStudio: Bool = false
    let onActivate: () -> Void
    /// Opens the speed sheet — dynamic scenes only.
    let onSpeed: () -> Void

    private static let radius: CGFloat = LuminousPalette.cardRadius

    var body: some View {
        let colors = LuminousScenePalette.colors(for: scene)
        let accent = colors[colors.count / 2]
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        return Button(action: onActivate) {
            VStack(alignment: .leading, spacing: 0) {
                // The art sits below the badge row so the orbs never
                // crowd the On badge or the star.
                LuminousSceneArt(colors: colors, isActive: scene.isActive, height: 62)
                    .padding(.top, 24)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: scene.icon)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(accent)
                        Text(scene.name)
                            .font(LuminousType.cardTitleSmall)
                            .foregroundStyle(LuminousPalette.ink)
                            // A single word never breaks mid-word — it shrinks.
                            .lineLimit(scene.name.contains(" ") ? 2 : 1)
                            .minimumScaleFactor(0.75)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    metaLine
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                ZStack {
                    LuminousPalette.void
                    Composer2PaletteWash(colors: colors).opacity(scene.isActive ? 0.22 : 0.09)
                    LinearGradient(colors: [Color.white.opacity(0.05), .clear], startPoint: .top, endPoint: .center)
                }
            )
            .clipShape(shape)
            .overlay(
                shape.strokeBorder(
                    LinearGradient(colors: scene.isActive
                                   ? [accent.opacity(0.85), accent.opacity(0.25)]
                                   : [Color.white.opacity(0.16), Color.white.opacity(0.04)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: scene.isActive ? 1.4 : 1)
            )
            .shadow(color: scene.isActive ? accent.opacity(0.4) : .black.opacity(0.3),
                    radius: scene.isActive ? 16 : 10, y: scene.isActive ? 2 : 6)
            .contentShape(shape)
        }
        .buttonStyle(LuminousPressStyle(scale: 0.95))
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint("Double tap to activate")
        .overlay(alignment: .topLeading) {
            // State on the art: On (green) and the favourite star.
            HStack(spacing: 6) {
                if scene.isActive {
                    LuminousLiveBadge(state: .active, text: "On")
                }
                if isFavorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(LuminousPalette.amber)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(.ultraThinMaterial))
                        .accessibilityHidden(true)
                }
            }
            .padding(8)
            .allowsHitTesting(false)
        }
        // Speed sits above the card's tap so it stays its own target.
        .overlay(alignment: .topTrailing) {
            if scene.isDynamic {
                Button(action: onSpeed) {
                    Image(systemName: "speedometer")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(LuminousPalette.ink)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(.ultraThinMaterial))
                        .overlay(Circle().strokeBorder(accent.opacity(0.5), lineWidth: 1))
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(LuminousPressStyle(scale: 0.88))
                .accessibilityLabel("Scene speed")
                .padding(2)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.72), value: scene.isActive)
    }

    /// Room · Dynamic · Studio — whichever apply, on one quiet line.
    @ViewBuilder
    private var metaLine: some View {
        let showsAnything = showsRoomLabel || scene.isDynamic || isStudio
        if showsAnything {
            HStack(spacing: 6) {
                if showsRoomLabel {
                    Text(roomName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(LuminousPalette.inkSecondary)
                        .lineLimit(1)
                }
                if scene.isDynamic {
                    HStack(spacing: 3) {
                        Image(systemName: "bolt.fill").font(.system(size: 8, weight: .bold))
                        Text("Dynamic").font(.caption2.weight(.bold))
                    }
                    .foregroundStyle(LuminousPalette.violet)
                    .fixedSize()
                }
                // Provenance: exported from Studio Classic's Composer.
                if isStudio {
                    Text("Studio")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(LuminousPalette.void)
                        .padding(.horizontal, 6)
                        .frame(minHeight: 16)
                        .background(Capsule().fill(LuminousPalette.lime))
                        .fixedSize()
                }
            }
        } else {
            Text(" ").font(.caption)
        }
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

// MARK: - Skeleton

/// A glass placeholder the size of a scene card, while scenes load.
struct LuminousSceneSkeleton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isTabActive) private var isTabActive
    @State private var phase: CGFloat = -1

    var body: some View {
        RoundedRectangle(cornerRadius: LuminousPalette.cardRadius, style: .continuous)
            .fill(Color.white.opacity(0.03))
            .overlay {
                if !reduceMotion && isTabActive {
                    RoundedRectangle(cornerRadius: LuminousPalette.cardRadius, style: .continuous)
                        .fill(LinearGradient(colors: [.clear, .white.opacity(0.06), .clear],
                                             startPoint: .init(x: phase, y: 0),
                                             endPoint: .init(x: phase + 0.5, y: 1)))
                }
            }
            .frame(height: 140)
            .luminousGlass(radius: LuminousPalette.cardRadius)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1.5 }
            }
            .accessibilityHidden(true)
    }
}
