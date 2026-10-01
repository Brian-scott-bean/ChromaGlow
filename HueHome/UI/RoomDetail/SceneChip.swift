// SceneChip.swift
// ChromaGlow — Room (Luminous): one of the room's scenes.
//
// A glass tile whose top is the scene's light — an arc of orbs in its
// colour — over its name. The active scene glows; while a recall is in
// flight a spinner replaces its icon and the tile ignores another tap.
// Presses use a ButtonStyle (never a DragGesture) so the tile never steals
// a scroll.

import SwiftUI

struct RoomSceneTile: View {

    let scene: SceneDisplayItem
    /// True while the recall is in flight → spinner, no double tap.
    let isActivating: Bool
    var isFavorite: Bool = false
    /// Select mode: the tap picks the scene instead of recalling it.
    var isSelecting: Bool = false
    let onTap: () -> Void

    private var statusLine: String {
        if isSelecting { return "Tap to select" }
        return scene.isActive ? "On now" : (isActivating ? "Setting…" : "Tap to set")
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                LuminousPaletteOrbs(colors: scene.previewColors, count: 3, lit: true, height: 40)
                    .opacity(scene.isActive ? 1 : 0.55)
                HStack(spacing: 6) {
                    if isActivating {
                        ProgressView().tint(scene.previewAccent).scaleEffect(0.7)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: scene.icon)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(scene.previewAccent)
                    }
                    Text(scene.name)
                        .font(LuminousType.cardTitleSmall)
                        .foregroundStyle(LuminousPalette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Text(statusLine)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(scene.isActive && !isSelecting ? LuminousPalette.live : LuminousPalette.inkSecondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .luminousPanel(radius: 18, glow: scene.isActive ? scene.previewAccent : nil,
                           glowStrength: scene.isActive ? 0.8 : 0)
            .overlay(alignment: .topTrailing) {
                if isFavorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(LuminousPalette.amber)
                        .padding(10)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(LuminousPressStyle(scale: 0.95))
        .disabled(isActivating)
        .accessibilityLabel("\(scene.name) scene\(scene.isActive ? ", active" : "")\(isFavorite ? ", favourite" : "")")
        .accessibilityHint(isSelecting ? "Selects this scene" : (isActivating ? "Activating…" : "Tap to activate"))
    }
}
