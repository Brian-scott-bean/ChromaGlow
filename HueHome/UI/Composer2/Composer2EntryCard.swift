// Composer2EntryCard.swift
// ChromaGlow — Composer 2 lab (experimental).
//
// The single integration point with Studio: one card on the composer deck.
// It owns its own presentation state and cover, so StudioView's body — which
// sits at the type-checker's ceiling — gains exactly one line. Deleting that
// line and this folder removes the experiment.

import SwiftUI

struct Composer2EntryCard: View {
    let selectedRoom: RoomDisplayItem?

    @Environment(UnifiedOrchestrator.self) private var orchestrator
    @State private var isPresented = false
    private let center = Composer2PlaybackCenter.shared

    var body: some View {
        VStack(spacing: 8) {
            Button {
                HapticManager.shared.medium()
                isPresented = true
            } label: {
                HStack(spacing: HueSpacing.md) {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(colors: [Composer2Theme.cyan, Composer2Theme.violet],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 44, height: 44)
                            .shadow(color: Composer2Theme.cyan.opacity(0.5), radius: 12)
                        Image(systemName: "sparkles")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Composer2Theme.background)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(Composer2Copy.entryTitle)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                            StageBadge(text: Composer2Copy.experimentalBadge, style: .amber)
                        }
                        Text(Composer2Copy.entrySubtitle)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .padding(HueSpacing.lg)
                .background(
                    RoundedRectangle(cornerRadius: HueRadius.xl, style: .continuous)
                        .fill(Composer2Theme.navy.opacity(0.85))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: HueRadius.xl, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [Composer2Theme.cyan.opacity(0.5), Composer2Theme.violet.opacity(0.35)],
                                                     startPoint: .leading, endPoint: .trailing), lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: HueRadius.xl, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(Composer2Copy.entryTitle), experimental")
            .accessibilityHint("Opens the Composer 2 instrument")

            if let session = center.session, center.isLive {
                HStack(spacing: 10) {
                    Circle().fill(Composer2Theme.live).frame(width: 7, height: 7)
                    Text("\(Composer2Copy.playingPill(room: session.roomName)) · \(session.compositionName)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button {
                        HapticManager.shared.medium()
                        let gateway = Composer2OrchestratorGateway(orchestrator: orchestrator)
                        Task { await center.stop(gateway: gateway) }
                    } label: {
                        Text("Stop")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Composer2Theme.background)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 30)
                            .background(Capsule().fill(Composer2Theme.live))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop Composer 2 playback in \(session.roomName)")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Composer2Theme.live.opacity(0.3), lineWidth: 1))
            }
        }
        .fullScreenCover(isPresented: $isPresented) {
            Composer2View(room: selectedRoom)
                .environment(orchestrator)
        }
    }
}
