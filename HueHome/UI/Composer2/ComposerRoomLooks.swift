// ComposerRoomLooks.swift
// ChromaGlow — a room's Looks: the Composer, brought to the room.
//
// The Room page's third segment. What's playing in this room (with Stop and
// Open), then looks that move — today's showpieces and the person's own —
// each playing on its card. Tap a look to open the Composer on it in this
// room; hold to play it here straight away (applied: it keeps playing while
// ChromaGlow is open). Same playback owner, same seam as the Composer tab.

import SwiftUI

struct ComposerRoomLooks: View {
    let room: RoomDisplayItem

    @Environment(UnifiedOrchestrator.self) private var orchestrator

    /// A prompt raised from a hidden tab is dropped by UIKit and swallows the

    /// next presentation app-wide — only the surface on screen asks.

    @Environment(\.isTabActive) private var isTabActive
    @State private var open: OpenRequest?
    @State private var notice: String?

    private let center = Composer2PlaybackCenter.shared
    private let store = Composer2Store.shared

    struct OpenRequest: Identifiable {
        let id = UUID()
        let composition: Composer2Composition?
        let mode: Composer2Mode?
    }

    private var isPlayingHere: Bool {
        center.isLive && center.session?.roomID == room.id
    }

    private var playingLook: Composer2Composition? {
        guard isPlayingHere, let id = center.session?.compositionID else { return nil }
        return store.composition(id: id) ?? Composer2ThemeCatalog.entry(id: id)?.composition
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let look = playingLook {
                playingCard(look)
            }
            if let notice {
                LuminousNotice(text: notice, symbol: "exclamationmark.circle.fill", tint: LuminousPalette.amber) {
                    withAnimation { self.notice = nil }
                }
                .transition(.opacity)
            }

            VStack(alignment: .leading, spacing: 10) {
                LuminousSectionHeader(title: "Looks that move",
                                      subtitle: "Tap one to try it on \(room.name). Hold to play it here.")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(Composer2ThemeCatalog.featured) { entry in
                            card(entry.composition, symbol: entry.symbol,
                                 accent: Composer2Theme.accent(for: entry.category), isNew: entry.isNew)
                                .frame(width: 220)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollClipDisabled()
            }

            if !store.compositions.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(LuminousPalette.lime)
                        Text("Your looks")
                            .font(LuminousType.cardTitle)
                            .foregroundStyle(LuminousPalette.ink)
                    }
                    .accessibilityAddTraits(.isHeader)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 12) {
                            ForEach(store.compositions) { composition in
                                card(composition, symbol: "person.crop.circle", accent: LuminousPalette.lime, isNew: false)
                                    .frame(width: 168)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .scrollClipDisabled()
                }
            }

            LuminousPrimaryButton(title: "Open the Composer", symbol: "sparkles") {
                HapticManager.shared.medium()
                open = OpenRequest(composition: nil, mode: nil)
            }
            .accessibilityHint("Opens the Composer on \(room.name)")

            Text("Bulb effects like Candle and Fire live in Studio Classic (Composer tab → More tools).")
                .font(.footnote)
                .foregroundStyle(LuminousPalette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .fullScreenCover(item: $open) { request in
            Composer2View(room: room, composition: request.composition, mode: request.mode)
                .environment(orchestrator)
        }
        // A one-tap start that meets another app's show asks here; the
        // instrument's own prompt answers when it is on screen.
        .alert(EntertainmentConsentCopy.takeoverTitle, isPresented: Binding(
            get: { center.takeoverPending && !center.hasAttachedScreen && isTabActive },
            set: { if !$0, center.takeoverPending { center.answerTakeover(false) } })) {
            Button(EntertainmentConsentCopy.keepExisting, role: .cancel) { center.answerTakeover(false) }
            Button(EntertainmentConsentCopy.takeOver) {
                HapticManager.shared.light()
                center.answerTakeover(true)
            }
        }
    }

    // MARK: Playing

    private func playingCard(_ look: Composer2Composition) -> some View {
        HStack(spacing: 14) {
            Composer2MiniStage(composition: look, lights: 5)
                .frame(width: 72, height: 72)
                .background(LuminousPalette.void)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle().fill(LuminousPalette.live).frame(width: 6, height: 6)
                        .shadow(color: LuminousPalette.live, radius: 4)
                    LuminousEyebrow(text: "Playing here", tint: LuminousPalette.live)
                }
                Text(look.name)
                    .font(LuminousType.cardTitle)
                    .foregroundStyle(LuminousPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(Composer2Copy.appliedDetail)
                    .font(.caption)
                    .foregroundStyle(LuminousPalette.inkSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            VStack(spacing: 8) {
                LuminousTextPill(title: "Stop", symbol: "stop.fill", tint: LuminousPalette.live, active: true) {
                    stop()
                }
                .accessibilityLabel("Stop \(look.name) in \(room.name)")
                LuminousTextPill(title: "Open", symbol: "slider.horizontal.3") {
                    open = OpenRequest(composition: nil, mode: nil)
                }
                .accessibilityLabel("Open \(look.name) in the Composer")
            }
        }
        .padding(12)
        .luminousGlass(radius: 22, accent: LuminousPalette.live, selected: true)
    }

    // MARK: Card

    private func isPlaying(_ composition: Composer2Composition) -> Bool {
        center.isLive && center.session?.compositionID == composition.id
    }

    private func card(_ composition: Composer2Composition, symbol: String, accent: Color, isNew: Bool) -> some View {
        Composer2LookCard(composition: composition, symbol: symbol, accent: accent, isNew: isNew,
                          isSelected: isPlaying(composition) && isPlayingHere,
                          isPlaying: isPlaying(composition)) {
            open = OpenRequest(composition: composition, mode: .tune)
        }
        .contextMenu {
            if isPlaying(composition) && isPlayingHere {
                Button { stop() } label: { Label("Stop", systemImage: "stop.fill") }
            } else {
                Button { play(composition) } label: { Label("Play here", systemImage: "play.fill") }
            }
            Button {
                open = OpenRequest(composition: composition, mode: .tune)
            } label: { Label("Open in Composer", systemImage: "slider.horizontal.3") }
        }
    }

    // MARK: Actions

    private func stop() {
        HapticManager.shared.medium()
        let gateway = Composer2OrchestratorGateway(orchestrator: orchestrator)
        Task { await center.stop(gateway: gateway) }
    }

    /// Play a look in this room, applied (it keeps playing while ChromaGlow
    /// is open) — the same owner and seam as the Composer tab's one-tap play.
    private func play(_ composition: Composer2Composition) {
        HapticManager.shared.medium()
        withAnimation { notice = nil }
        let gateway = Composer2OrchestratorGateway(orchestrator: orchestrator)
        let document = Composer2Document(composition: composition, roomContext: Composer2RoomContext(room: room))
        let output = Composer2LiveOutput(composition: composition)
        Task {
            let status = await center.start(document: document, output: output, gateway: gateway, audition: false)
            if case .failed(let message) = status {
                HapticManager.shared.warning()
                withAnimation { notice = message }
                // Answered here; the next Composer screen must not show it.
                center.clearNotice()
            }
        }
    }
}
