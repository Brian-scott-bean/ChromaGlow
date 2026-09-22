// Composer2EntryCard.swift
// ChromaGlow — Composer 2 lab (experimental).
//
// The single integration point with Studio: one card on the composer deck.
// It owns its own presentation state and cover, so StudioView's body — which
// sits at the type-checker's ceiling — gains exactly one line. Saved
// Composer 2 looks play from here as one-tap Studio looks through the same
// playback owner the screen uses.

import SwiftUI

struct Composer2EntryCard: View {
    let selectedRoom: RoomDisplayItem?

    @Environment(UnifiedOrchestrator.self) private var orchestrator
    @State private var isPresented = false
    @State private var openComposition: Composer2Composition?
    @State private var renameTarget: Composer2Composition?
    @State private var renameText = ""
    /// The last one-tap result that needs words (demo, no room, declined…).
    @State private var cardNotice: String?
    private let center = Composer2PlaybackCenter.shared
    private let store = Composer2Store.shared

    var body: some View {
        VStack(spacing: 8) {
            entryButton
            if let session = center.session, center.isLive {
                playingPill(session)
            }
            if !store.compositions.isEmpty {
                savedLooks
            }
            if let cardNotice {
                Text(cardNotice)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .transition(.opacity)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        // A one-tap start that meets another app's show asks HERE: the
        // Composer 2 screen's prompt is the only other answer, and it is not
        // on screen — the question used to wait forever and hold every stop.
        .alert(EntertainmentConsentCopy.takeoverTitle, isPresented: Binding(
            get: { center.takeoverPending && !center.hasAttachedScreen },
            set: { if !$0, center.takeoverPending { center.answerTakeover(false) } })) {
            Button(EntertainmentConsentCopy.keepExisting, role: .cancel) { center.answerTakeover(false) }
            Button(EntertainmentConsentCopy.takeOver) {
                HapticManager.shared.light()
                center.answerTakeover(true)
            }
        }
        .fullScreenCover(isPresented: $isPresented) {
            Composer2View(room: selectedRoom)
                .environment(orchestrator)
        }
        .fullScreenCover(item: $openComposition) { composition in
            Composer2View(room: selectedRoom, composition: composition)
                .environment(orchestrator)
        }
        .alert("Rename", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let stale = renameTarget {
                    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Rename the CURRENT saved copy, not the snapshot taken
                    // when the menu opened (a save in between would revert).
                    if !trimmed.isEmpty, var target = store.composition(id: stale.id) {
                        target.name = trimmed
                        store.save(target)
                        if let open = center.retainedDocument(for: center.session?.roomID),
                           open.sourceID == target.id, !open.isDirty {
                            open.rename(trimmed)
                            open.isDirty = false
                        }
                    }
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
    }

    private var entryButton: some View {
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
    }

    private func playingPill(_ session: Composer2PlaybackCenter.Session) -> some View {
        HStack(spacing: 10) {
            Circle().fill(Composer2Theme.live).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(Composer2Copy.playingPill(room: session.roomName)) · \(session.compositionName)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                Text(Composer2Copy.appliedDetail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
            }
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

    private var savedLooks: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Composer2Copy.savedLooksTitle.uppercased())
                .font(HueFont.stageTag)
                .foregroundStyle(.white.opacity(0.45))
                .tracking(1.2)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(store.compositions) { composition in
                        lookChip(composition)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Composer2Copy.savedLooksTitle)
    }

    private func lookChip(_ composition: Composer2Composition) -> some View {
        let playingThis = center.isLive && center.session?.compositionID == composition.id
        return Button {
            play(composition)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: playingThis ? "waveform" : "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(playingThis ? Composer2Theme.live : Composer2Theme.cyan)
                Text(composition.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background(Capsule().fill(Color.white.opacity(playingThis ? 0.12 : 0.06)))
            .overlay(Capsule().strokeBorder((playingThis ? Composer2Theme.live : Composer2Theme.cyan).opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { openComposition = composition } label: { Label(Composer2Copy.openInComposer2, systemImage: "slider.horizontal.3") }
            Button { renameText = composition.name; renameTarget = composition } label: { Label("Rename", systemImage: "pencil") }
            Button(role: .destructive) {
                HapticManager.shared.medium()
                store.delete(id: composition.id)
            } label: { Label("Delete", systemImage: "trash") }
        }
        .accessibilityLabel("\(composition.name)\(playingThis ? ", playing" : "")")
        .accessibilityHint(selectedRoom.map { Composer2Copy.playIn(room: $0.name) } ?? "Choose a room in Studio first")
    }

    /// One tap: play a saved look in the selected room, applied (it keeps
    /// playing while ChromaGlow is open). Same owner, same seam as the screen.
    private func play(_ composition: Composer2Composition) {
        HapticManager.shared.medium()
        withAnimation { cardNotice = nil }
        let gateway = Composer2OrchestratorGateway(orchestrator: orchestrator)
        // The toggle is room-scoped: the playing look stops only when it is
        // playing in the room Studio has selected; otherwise the tap plays
        // it here (the VoiceOver hint says "Play in ‹room›").
        if center.isLive, center.session?.compositionID == composition.id,
           center.session?.roomID == selectedRoom?.id {
            Task { await center.stop(gateway: gateway) }
            return
        }
        let document = Composer2Document(composition: composition, roomContext: Composer2RoomContext(room: selectedRoom))
        let output = Composer2LiveOutput(composition: composition)
        Task {
            let status = await center.start(document: document, output: output, gateway: gateway, audition: false)
            if case .failed(let message) = status {
                HapticManager.shared.warning()
                withAnimation { cardNotice = message }
                // Answered here; the next Composer 2 screen must not show it.
                center.clearNotice()
            }
        }
    }
}
