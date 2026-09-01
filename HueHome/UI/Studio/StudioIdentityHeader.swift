// StudioIdentityHeader.swift
// CastChroma — Slice 2 quiet header (spec §13).
//
// The historically busy three-row header becomes one calm line:
//
//     ● PARTY · LIVING ROOM ›                                   [stop]
//
// The identity itself is the interactive element: tapping it expands the
// operational panel (transport truth, coverage, actions) INLINE as the first
// section of the host's one scroll — status stays behind the identity
// instead of permanently occupying the board. The selected-target Stop keeps
// its own always-visible circle: one tap, exact target, never a sibling.

import SwiftUI

struct StudioIdentityHeader: View {
    let card: StudioCard
    let roomName: String
    /// Whether the operational panel below is open (session working memory).
    @Binding var detailsOpen: Bool
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(HueAnimation.fast) { detailsOpen.toggle() }
                HapticManager.shared.light()
            } label: {
                HStack(spacing: 8) {
                    // Tiny live indicator — quiet, not a badge lane.
                    Circle()
                        .fill(HuePalette.Noir.success)
                        .frame(width: 6, height: 6)
                    Group {
                        Text(card.name.uppercased())
                            .foregroundStyle(StagePalette.ink)
                        + Text("  ·  ")
                            .foregroundStyle(.white.opacity(0.3))
                        + Text(roomName.uppercased())
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .font(HueFont.stageControl)
                    .tracking(1.1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .allowsTightening(true)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                        .rotationEffect(.degrees(detailsOpen ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(card.name) running in \(roomName)")
            .accessibilityValue(detailsOpen ? "details shown" : "details hidden")
            .accessibilityHint("Shows transport, coverage, and actions for this room")

            Spacer(minLength: 8)

            // Selected-target Stop: one tap, exactly this room's look.
            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(HuePalette.Noir.destructive)
                    .frame(width: 40, height: 40)
                    .background(
                        Circle().fill(HuePalette.Noir.destructive.opacity(0.15))
                    )
            }
            .buttonStyle(.plain)
            .stageTapTarget(visual: 40)
            .fixedSize()
            .accessibilityLabel("Stop \(card.name) in \(roomName)")
        }
        .padding(.horizontal, HueSpacing.screenH)
        .frame(height: 48)
    }
}
