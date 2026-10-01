// HomeNowPlaying.swift
// ChromaGlow — Home (Luminous): what's playing, with its own Stop.
//
// The live thread of the app: whatever a look, effect or Studio Classic
// session is doing to real lights sits at the top of Home. A Composer look
// shows its own little stage and opens the Composer on that room; every
// entry stops through `requestNowPlayingStop` on the ENTRY (never a bare
// grouped-light PUT). Several entries ask which one to stop.

import SwiftUI

struct HomeNowPlayingCard: View {
    let entries: [ActiveEffectEntry]
    let isAppDriven: Bool
    let onStop: (ActiveEffectEntry?) -> Void
    let onStopAll: () -> Void
    let onOpenComposer: (ActiveEffectEntry) -> Void

    @State private var showStopMenu = false
    private let center = Composer2PlaybackCenter.shared

    /// The Now Playing row the Composer publishes.
    static let composerEffectID = "composer2"

    private var primary: ActiveEffectEntry? { entries.last }

    /// The Composer look behind an entry, when it is one.
    private var composerLook: Composer2Composition? {
        guard primary?.effectID == Self.composerEffectID,
              let id = center.session?.compositionID else { return nil }
        return Composer2Store.shared.composition(id: id) ?? Composer2ThemeCatalog.entry(id: id)?.composition
    }

    var body: some View {
        let look = composerLook
        HStack(spacing: 14) {
            art(look)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle().fill(LuminousPalette.live).frame(width: 6, height: 6)
                        .shadow(color: LuminousPalette.live, radius: 4)
                    Text("NOW PLAYING")
                        .font(LuminousType.eyebrow)
                        .tracking(1.2)
                        .foregroundStyle(LuminousPalette.live)
                }
                Text(primary?.effectName ?? "")
                    .font(LuminousType.cardTitle)
                    .foregroundStyle(LuminousPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(roomLine)
                    .font(.caption)
                    .foregroundStyle(LuminousPalette.inkSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            VStack(spacing: 6) {
                Button {
                    if entries.count > 1 { showStopMenu = true } else { onStop(primary) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold))
                        Text("Stop").font(.system(.subheadline, design: .rounded).weight(.heavy))
                        if entries.count > 1 {
                            Image(systemName: "chevron.up").font(.system(size: 9, weight: .bold))
                        }
                    }
                    .foregroundStyle(LuminousPalette.void)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 40)
                    .background(Capsule().fill(LuminousPalette.liveGradient))
                    .shadow(color: LuminousPalette.live.opacity(0.5), radius: 10)
                    .frame(minHeight: 44)
                    .contentShape(Capsule())
                }
                .buttonStyle(LuminousPressStyle(scale: 0.92))
                .accessibilityLabel(entries.count > 1 ? "Stop, choose which" : "Stop \(primary?.effectName ?? "")")
                // The global clock is here too: transport-only (no per-look
                // binding — that lives on the owning surface).
                BeatChipButton(capabilities: [.transport, .manualBPM, .barMeter], compact: true)
            }
        }
        .padding(12)
        .luminousGlass(radius: 22, accent: LuminousPalette.live, selected: true)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture {
            if let primary, look != nil { onOpenComposer(primary) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityHint(look != nil ? "Double tap to open it in the Composer" : "")
        .confirmationDialog("Playing now", isPresented: $showStopMenu, titleVisibility: .visible) {
            ForEach(entries) { entry in
                Button("Stop \"\(entry.effectName)\" in \(entry.roomName)", role: .destructive) { onStop(entry) }
            }
            Button("Stop All", role: .destructive) { onStopAll() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var roomLine: String {
        guard let primary else { return "" }
        var line = entries.count > 1
            ? "\(primary.roomName) · \(entries.count - 1) more room\(entries.count > 2 ? "s" : "")"
            : primary.roomName
        if isAppDriven { line += " · keeps playing while ChromaGlow is open" }
        return line
    }

    @ViewBuilder
    private func art(_ look: Composer2Composition?) -> some View {
        if let look {
            Composer2MiniStage(composition: look, lights: 5)
                .frame(width: 70, height: 70)
                .background(LuminousPalette.void)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        } else {
            LuminousIconBadge(symbol: primary?.effectIcon ?? "sparkles", tint: LuminousPalette.live, size: 56)
                .frame(width: 70, height: 70)
        }
    }
}
