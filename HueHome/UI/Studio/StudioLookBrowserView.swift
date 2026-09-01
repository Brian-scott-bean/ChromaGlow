// StudioLookBrowserView.swift
// CastChroma — Slice 2 unified look browser band (spec §16).
//
// The hybrid browser: compact FAVORITES and RECENTS rows above the three
// category decks (Effects / Live / Composer — the pager's pages, reachable
// by the deck dots and swipes), plus the inline details/setup panel and the
// Apply-Current-Look fast path for a newly selected idle room.
//
// Everything here is SAME-SURFACE: the details/setup panel expands in place
// between the band and the decks — no sheet, no fullScreenCover, no detached
// setup screen (binding correction #2). Pre-apply setup is deliberately
// lightweight: the look's hero parameter and brightness as next-start
// defaults, the favorite toggle, and opt-in Preview Live — never a duplicate
// of the live console.

import SwiftUI

struct StudioLookBrowserBand: View {
    @Bindable var vm: StudioViewModel
    /// Immediate apply through StudioView's normal activation flow.
    let onApply: (StudioCard) -> Void
    /// The card whose details/setup panel is expanded inline, if any.
    @Binding var detailsCard: StudioCard?

    private var library: StudioLookLibraryStore { .shared }

    /// Every look the band can name, filtered live against the catalog so a
    /// stale persisted id simply does not render.
    private var allCards: [StudioCard] {
        vm.effectCards + vm.liveModeCards + vm.composerStudioCards
    }

    private func cards(forIDs ids: [String]) -> [StudioCard] {
        let byID = Dictionary(uniqueKeysWithValues: allCards.map { ($0.id, $0) })
        return ids.compactMap { byID[$0] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HueSpacing.sm) {
            if let source = vm.applyCurrentLookSource {
                applyCurrentRow(source)
            }

            let favorites = cards(forIDs: library.favoriteLookIDs)
            if !favorites.isEmpty {
                chipRow(title: "FAVORITES", cards: favorites, showStar: true)
            }
            let recents = cards(forIDs: library.recentLookIDs)
                .filter { !library.isFavorite($0.id) }
            if !recents.isEmpty {
                chipRow(title: "RECENTS", cards: recents, showStar: false)
            }

            if let card = detailsCard {
                LookDetailsPanel(vm: vm, card: card,
                                 onApply: onApply,
                                 onClose: { withAnimation(HueAnimation.fast) { detailsCard = nil } })
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, HueSpacing.screenH)
    }

    // ── Apply Current Look (spec §14.6) ─────────────────────────

    private func applyCurrentRow(_ source: RunningEffect) -> some View {
        HStack(spacing: 8) {
            Button {
                guard let room = vm.selectedRoom else { return }
                Task { await vm.applyCurrentLook(to: room) }
                HapticManager.shared.medium()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Apply \(source.card.name) here")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(StagePalette.stage)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(Capsule().fill(HuePalette.amber))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Copies \(source.room.name)'s current settings once and starts an independent copy in this room")

            Text("or choose another look below")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
            Spacer(minLength: 0)
        }
    }

    // ── Compact chip rows ───────────────────────────────────────

    private func chipRow(title: String, cards: [StudioCard], showStar: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(HueFont.stageTag)
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.42))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(cards) { card in
                        lookChip(card, showStar: showStar)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
    }

    private func lookChip(_ card: StudioCard, showStar: Bool) -> some View {
        Button {
            onApply(card)
            HapticManager.shared.medium()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: card.icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(card.accentColor)
                Text(card.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StagePalette.ink)
                    .lineLimit(1)
                if showStar {
                    Image(systemName: "star.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(HuePalette.amber.opacity(0.8))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Capsule().fill(Color.white.opacity(0.07)))
            .overlay(Capsule().strokeBorder(StagePalette.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                library.toggleFavorite(card.id)
            } label: {
                Label(library.isFavorite(card.id) ? "Remove Favorite" : "Add Favorite",
                      systemImage: library.isFavorite(card.id) ? "star.slash" : "star")
            }
            Button {
                withAnimation(HueAnimation.fast) { detailsCard = card }
            } label: {
                Label("Details & Setup", systemImage: "slider.horizontal.3")
            }
        }
        .accessibilityLabel("\(card.name), applies immediately")
    }
}

// MARK: - Inline details / setup panel (spec §16.4/§16.5)

struct LookDetailsPanel: View {
    @Bindable var vm: StudioViewModel
    let card: StudioCard
    let onApply: (StudioCard) -> Void
    let onClose: () -> Void

    private var library: StudioLookLibraryStore { .shared }

    /// The audition this panel's card owns, if any.
    ///
    /// `vm.isPreviewingLive` is ONE global flag; this panel is per CARD.
    /// Gating Keep It / Put It Back on the flag alone meant re-pointing the
    /// panel at another look (chip context menu → "Details & Setup") offered
    /// that card an undo it did not own, and "Keep It" recorded the WRONG card
    /// as applied. The audition's identity names its card — compare it.
    private var isThisCardsAudition: Bool {
        vm.isPreviewingLive && vm.previewAuditionCardID == card.id
    }

    /// An audition is running, but for a DIFFERENT card than this panel shows.
    private var otherAuditionCardName: String? {
        guard vm.isPreviewingLive,
              let auditionID = vm.previewAuditionCardID,
              auditionID != card.id else { return nil }
        return vm.lookCard(forID: auditionID)?.name ?? "another look"
    }

    /// The row this panel's card is running on the SELECTED room, if it is the
    /// running look there. Non-nil is what makes the hero sliders live
    /// controls rather than next-start defaults.
    private var runningHere: RunningEffect? {
        guard let effect = vm.currentRoomEffect,
              effect.cardID == card.id, effect.recovered == nil else { return nil }
        return effect
    }

    /// The lightweight setup set: the look's designed hero parameter plus
    /// brightness — next-start defaults, not the live console.
    private var setupParams: [StudioParam] {
        let hero = StudioBoardCatalog.descriptor(for: card).heroParamID
        var ids: [String] = []
        if let hero { ids.append(hero) }
        if hero != "brightness", card.params.contains(where: { $0.id == "brightness" }) {
            ids.append("brightness")
        }
        return ids.compactMap { id in
            card.params.first { $0.id == id && {
                if case .slider = $0.kind { return true }; return false }($0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HueSpacing.sm) {
            HStack(spacing: 8) {
                Image(systemName: card.icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(card.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(StagePalette.ink)
                    Text(card.tagline)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    library.toggleFavorite(card.id)
                    HapticManager.shared.selection()
                } label: {
                    Image(systemName: library.isFavorite(card.id) ? "star.fill" : "star")
                        .font(.system(size: 14))
                        .foregroundStyle(HuePalette.amber.opacity(library.isFavorite(card.id) ? 1 : 0.5))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(library.isFavorite(card.id)
                                    ? "Remove \(card.name) from favorites"
                                    : "Add \(card.name) to favorites")
                Button {
                    if isThisCardsAudition { Task { await vm.cancelPreviewLive() } }
                    onClose()
                    HapticManager.shared.light()
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close details")
            }

            // Lightweight setup. These sliders write next-start DEFAULTS when
            // the card is idle here, and the LIVE instance when it is the look
            // running on the selected room — so when they are live they must
            // pass the same capability funnel the board does. Strobe's
            // `speed` is streaming-only: shown here bare, it was a knob that
            // moved while reaching nothing, with no note saying why.
            ForEach(setupParams) { param in
                if case .slider(let min, let max) = param.kind {
                    let resolution = runningHere.flatMap {
                        StudioBoardAvailability.resolve(
                            card: card, param: param,
                            snapshot: vm.targetSnapshot(for: $0))
                    }
                    let note = resolution.flatMap {
                        StudioBoardAvailability.note(for: $0, isColor: false)
                    }
                    let interactive = resolution
                        .map { StudioBoardAvailability.isInteractive($0.availability) } ?? true
                    let opacity = resolution
                        .map { StudioBoardAvailability.opacity($0.availability) } ?? 1
                    VStack(alignment: .leading, spacing: 3) {
                        StageSlider(
                            title: param.label,
                            value: Binding(
                                get: { vm.paramValue(for: card.id, paramID: param.id,
                                                     default: param.defaultValue) },
                                set: { vm.commitParam(cardID: card.id, paramID: param.id, value: $0) }
                            ),
                            range: min...max,
                            format: param.format ?? { "\(Int($0.rounded()))" }
                        )
                        if let note {
                            Text(note)
                                .font(HueFont.stageTag)
                                .tracking(0.8)
                                .foregroundStyle(HuePalette.amber.opacity(0.65))
                                .accessibilityLabel("\(param.label): \(note)")
                        } else if runningHere == nil {
                            // Honest about WHICH value this edits: nothing is
                            // running here, so the write is a next-start
                            // default and changes no light right now.
                            Text("SETS THE NEXT START")
                                .font(HueFont.stageTag)
                                .tracking(0.8)
                                .foregroundStyle(.white.opacity(0.38))
                                .accessibilityLabel("\(param.label): sets the value this look starts at")
                        }
                    }
                    .disabled(!interactive)
                    .opacity(opacity)
                }
            }

            HStack(spacing: 10) {
                if let runningName = otherAuditionCardName {
                    // An audition owned by ANOTHER card is playing on the
                    // selected room. Offering this card's Apply / PREVIEW LIVE
                    // here would queue a second audition behind a live one; say
                    // what is running instead.
                    Text("A preview of \(runningName) is running")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .accessibilityLabel("A preview of \(runningName) is running; finish it first")
                } else if isThisCardsAudition {
                    Button {
                        Task { await vm.commitPreviewLive() }
                        StudioLookLibraryStore.shared.noteApplied(card.id)
                        onClose()
                        HapticManager.shared.medium()
                    } label: {
                        Text("Keep It")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(StagePalette.stage)
                            .padding(.horizontal, 14)
                            .frame(height: 36)
                            .background(Capsule().fill(HuePalette.Noir.success))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Keep \(card.name)")

                    Button {
                        Task { await vm.cancelPreviewLive() }
                        HapticManager.shared.light()
                    } label: {
                        Text("Put It Back")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(.horizontal, 14)
                            .frame(height: 36)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Restore the previous look exactly")
                } else {
                    Button {
                        onApply(card)
                        onClose()
                    } label: {
                        Text("Apply")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(StagePalette.stage)
                            .padding(.horizontal, 16)
                            .frame(height: 36)
                            .background(Capsule().fill(HuePalette.amber))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Apply \(card.name)")

                    // Opt-in audition on the exact selected room; the
                    // previous look and its exact values are snapshotted and
                    // restored on "Put It Back" (spec §16.5).
                    Button {
                        Task { await vm.beginPreviewLive(card: card) }
                        HapticManager.shared.light()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "eye")
                                .font(.system(size: 11))
                            Text("PREVIEW LIVE")
                                .font(HueFont.stageTag)
                                .tracking(0.8)
                        }
                        .foregroundStyle(HuePalette.amber)
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .background(Capsule().fill(HuePalette.amber.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    // Disabled while an audition's apply is in flight (R4C):
                    // a second tap would queue a second audition behind the
                    // first and overwrite the identity "Put It Back" is fenced
                    // on with a look the user never saw start.
                    .disabled(vm.selectedRoom == nil || vm.isAuditionInFlight)
                    .accessibilityHint("Tries \(card.name) on the selected room; the previous look can be restored exactly")
                }
                Spacer(minLength: 0)
            }
        }
        .padding(HueSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: HueRadius.lg, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: HueRadius.lg, style: .continuous)
                .strokeBorder(StagePalette.line, lineWidth: 1)
        )
    }
}
