// ComposerLibraryHome.swift
// ChromaGlow — the Composer tab.
//
// The tab's front page is the Composer's library, the way Home is the front
// page of your rooms: browse, then step onto a stage. Every card plays its
// look. Tapping one opens the Composer instrument (Looks · Tune · Layers, Go
// Live) on that look in the room chosen at the top; long-press plays it
// straight into that room. What's live is the hero, with Stop. Studio
// Classic — bulb effects, Live modes, Perform and older looks — hangs off
// the bottom until those tools move in here.

import SwiftUI

struct ComposerLibraryHome: View {
    let onOpenStudioClassic: () -> Void

    @Environment(UnifiedOrchestrator.self) private var orchestrator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The room looks play in — remembered between launches.
    @AppStorage("composer.library.roomID") private var roomID: String = ""
    @State private var filter: Filter = .forYou
    @State private var open: OpenRequest?
    @State private var showMusicPicker = false
    @State private var notice: String?
    @State private var renameTarget: Composer2Composition?
    @State private var renameText = ""
    @State private var deleteTarget: Composer2Composition?

    private let center = Composer2PlaybackCenter.shared
    private let store = Composer2Store.shared

    enum Filter: Hashable {
        case forYou
        case category(Composer2LookCategory)
        case mine
    }

    /// One presentation of the Composer instrument.
    struct OpenRequest: Identifiable {
        let id = UUID()
        let room: RoomDisplayItem?
        let composition: Composer2Composition?
        let mode: Composer2Mode?
    }

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 260), spacing: 12)]

    // MARK: Rooms

    private var targets: [RoomDisplayItem] { orchestrator.allRooms + orchestrator.allZones }

    private var room: RoomDisplayItem? {
        if let chosen = targets.first(where: { $0.id == roomID }) { return chosen }
        if let live = center.session, let playing = targets.first(where: { $0.id == live.roomID }) { return playing }
        return orchestrator.allRooms.first ?? targets.first
    }

    private var liveRoom: RoomDisplayItem? {
        guard let session = center.session else { return nil }
        return targets.first { $0.id == session.roomID }
    }

    // MARK: Body

    var body: some View {
        ZStack {
            LuminousAmbience(colors: Composer2Theme.swatches(of: heroLook, max: 3))
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    LuminousScreenTitle(title: "Composer",
                                        eyebrow: "Light that feels alive",
                                        eyebrowSymbol: "sparkles",
                                        eyebrowTint: LuminousPalette.cyan,
                                        subtitle: "Storms, fire, Halloween, fireworks — try any look on your room, then Go Live.")
                    if let notice {
                        LuminousNotice(text: notice, symbol: "exclamationmark.circle.fill", tint: LuminousPalette.amber) {
                            withAnimation { self.notice = nil }
                        }
                        .transition(.opacity)
                    }
                    hero
                    musicStrip
                    filterBar
                    library
                    buildYourOwn
                    moreTools
                    Color.clear.frame(height: 24)
                }
                .padding(.horizontal, HueSpacing.screenH)
                .padding(.top, HueSpacing.sm)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(.dark)
        .photosensitivityNotice()
        .fullScreenCover(item: $open) { request in
            Composer2View(room: request.room, composition: request.composition, mode: request.mode)
                .environment(orchestrator)
        }
        .sheet(isPresented: $showMusicPicker) {
            MusicSourcePicker()
        }
        // A one-tap start that meets another app's show asks here; the
        // instrument's own prompt answers when it is on screen.
        .alert(EntertainmentConsentCopy.takeoverTitle, isPresented: Binding(
            get: { center.takeoverPending && !center.hasAttachedScreen },
            set: { if !$0, center.takeoverPending { center.answerTakeover(false) } })) {
            Button(EntertainmentConsentCopy.keepExisting, role: .cancel) { center.answerTakeover(false) }
            Button(EntertainmentConsentCopy.takeOver) {
                HapticManager.shared.light()
                center.answerTakeover(true)
            }
        }
        .alert("Rename look", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") { commitRename() }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .confirmationDialog("Delete this look?", isPresented: Binding(get: { deleteTarget != nil },
                                                                      set: { if !$0 { deleteTarget = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let target = deleteTarget {
                    HapticManager.shared.medium()
                    store.delete(id: target.id)
                }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("\"\(deleteTarget?.name ?? "")\" will be removed from your looks. The built-in looks are never affected.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Menu {
                if targets.isEmpty { Text("No rooms available") }
                Section("Rooms") {
                    ForEach(orchestrator.allRooms, id: \.id) { r in
                        Button { choose(r) } label: { Label(r.name, systemImage: archetypeIcon(for: r.archetype)) }
                    }
                }
                if !orchestrator.allZones.isEmpty {
                    Section("Zones") {
                        ForEach(orchestrator.allZones, id: \.id) { z in
                            Button { choose(z) } label: { Label(z.name, systemImage: "square.stack.3d.up") }
                        }
                    }
                }
            } label: {
                LuminousCapsuleLabel(title: room?.name ?? "Choose a room", symbol: "house.fill")
            }
            .disabled(center.isBusy)
            .accessibilityLabel("Plays in: \(room?.name ?? "no room")")
            .accessibilityHint("Choose the room looks play in")
            Spacer(minLength: 0)
            stateChip
        }
    }

    @ViewBuilder
    private var stateChip: some View {
        if center.isLive, let session = center.session {
            LuminousStateChip(text: "Live · \(session.roomName)", dot: LuminousPalette.live, glowing: true)
        } else if orchestrator.isDemoMode {
            LuminousStateChip(text: "Demo home", dot: LuminousPalette.cyan)
        } else {
            LuminousStateChip(text: "\(Composer2ThemeCatalog.entries.count) looks", dot: LuminousPalette.violet)
        }
    }

    private func choose(_ target: RoomDisplayItem) {
        HapticManager.shared.selection()
        roomID = target.id
    }

    // MARK: Hero

    /// What the hero plays: the live look, else today's showpiece (one a
    /// day, so the tab greets you with something different).
    private var heroLook: Composer2Composition {
        if center.isLive, let id = center.session?.compositionID, let playing = composition(id: id) {
            return playing
        }
        let featured = Composer2ThemeCatalog.featured
        guard !featured.isEmpty else { return Composer2PresetLibrary.thunderstorm }
        let day = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
        return featured[day % featured.count].composition
    }

    private func composition(id: UUID) -> Composer2Composition? {
        store.composition(id: id) ?? Composer2ThemeCatalog.entry(id: id)?.composition
    }

    private var hero: some View {
        let isLive = center.isLive && center.session != nil
        let look = heroLook
        let entry = Composer2ThemeCatalog.entry(id: look.id)
        return VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .top) {
                Composer2MiniStage(composition: look, lights: 9)
                    .frame(height: 176)
                HStack {
                    LuminousLiveBadge(state: isLive ? .live : .preview, text: isLive ? "Live" : "Showpiece")
                    Spacer(minLength: 0)
                    if let entry {
                        LuminousFactBadge(text: entry.category.title, symbol: entry.category.symbol)
                    }
                }
                .padding(12)
            }
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(isLive ? "Playing in \(center.session?.roomName ?? "")" : "Try it on \(room?.name ?? "your room")")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(isLive ? LuminousPalette.live : LuminousPalette.cyan)
                    Text(look.name)
                        .font(.system(.title2, design: .rounded).weight(.heavy))
                        .foregroundStyle(LuminousPalette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    if !look.subtitle.isEmpty {
                        Text(look.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(LuminousPalette.inkSecondary)
                            .lineLimit(2)
                    }
                }
                HStack(spacing: 10) {
                    if isLive {
                        LuminousPrimaryButton(title: "Open", symbol: "slider.horizontal.3") {
                            HapticManager.shared.medium()
                            open = OpenRequest(room: liveRoom ?? room, composition: nil, mode: nil)
                        }
                        LuminousSecondaryButton(title: "Stop", symbol: "stop.fill", tint: LuminousPalette.live) {
                            stop()
                        }
                        .frame(maxWidth: 130)
                    } else {
                        LuminousPrimaryButton(title: "Try it", symbol: "play.fill") {
                            HapticManager.shared.medium()
                            open = OpenRequest(room: room, composition: look, mode: .tune)
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(
            ZStack {
                LuminousPalette.void
                Composer2PaletteWash(colors: Composer2Theme.swatches(of: look, max: 3)).opacity(0.18)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: LuminousPalette.stageRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: LuminousPalette.stageRadius, style: .continuous)
                .strokeBorder(LinearGradient(colors: [(isLive ? LuminousPalette.live : LuminousPalette.cyan).opacity(0.55),
                                                      LuminousPalette.violet.opacity(0.2)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
        )
        .shadow(color: (isLive ? LuminousPalette.live : LuminousPalette.violet).opacity(0.25), radius: 20, y: 8)
        .accessibilityElement(children: .contain)
    }

    // MARK: Music

    private var musicStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            LuminousEyebrow(text: "Music")
                .padding(.horizontal, 4)
            MusicNowPlayingBar(style: .compact, onOpenPicker: { showMusicPicker = true })
        }
    }

    // MARK: Library

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            LuminousSectionHeader(title: "Looks",
                                  subtitle: "\(Composer2ThemeCatalog.entries.count) to start from. Every card is playing.")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    LuminousChip(title: "For you", symbol: "sparkles", selected: filter == .forYou) { select(.forYou) }
                    if !store.compositions.isEmpty {
                        LuminousChip(title: "Yours", symbol: "person.crop.circle", selected: filter == .mine,
                                     accent: LuminousPalette.lime) { select(.mine) }
                    }
                    ForEach(Composer2LookCategory.allCases) { category in
                        LuminousChip(title: category.shortTitle, symbol: category.symbol,
                                     selected: filter == .category(category),
                                     accent: Composer2Theme.accent(for: category)) { select(.category(category)) }
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollClipDisabled()
        }
    }

    private func select(_ f: Filter) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85)) { filter = f }
    }

    @ViewBuilder
    private var library: some View {
        switch filter {
        case .forYou:
            VStack(alignment: .leading, spacing: 22) {
                showpieces
                mineShelf
                ForEach(Composer2LookCategory.allCases) { category in
                    categoryShelf(category)
                }
            }
        case .category(let category):
            VStack(alignment: .leading, spacing: 12) {
                Text(category.tagline)
                    .font(.subheadline)
                    .foregroundStyle(LuminousPalette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(Composer2ThemeCatalog.entries(in: category)) { entry in
                        card(entry.composition, symbol: entry.symbol, accent: Composer2Theme.accent(for: category),
                             isNew: entry.isNew, mine: false)
                    }
                }
            }
        case .mine:
            mineGrid
        }
    }

    private var showpieces: some View {
        VStack(alignment: .leading, spacing: 10) {
            LuminousEyebrow(text: "Showpieces").padding(.horizontal, 4)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(Composer2ThemeCatalog.featured) { entry in
                        card(entry.composition, symbol: entry.symbol, accent: Composer2Theme.accent(for: entry.category),
                             isNew: entry.isNew, mine: false, style: .feature)
                            .frame(width: 260)
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical, 4)
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollClipDisabled()
        }
    }

    @ViewBuilder
    private var mineShelf: some View {
        if !store.compositions.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                shelfHeader(title: "Your looks", symbol: "person.crop.circle.fill", tint: LuminousPalette.lime) {
                    select(.mine)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(store.compositions) { composition in
                            card(composition, symbol: "person.crop.circle", accent: LuminousPalette.lime, isNew: false, mine: true)
                                .frame(width: 168)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollClipDisabled()
            }
        }
    }

    private var mineGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.compositions.isEmpty {
                LuminousEmptyState(symbol: "person.crop.circle", title: "Nothing saved yet",
                                   message: "Open any look, make it yours in Tune or Layers, and save it — it lives here.")
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(store.compositions) { composition in
                        card(composition, symbol: "person.crop.circle", accent: LuminousPalette.lime, isNew: false, mine: true)
                    }
                }
            }
        }
    }

    private func categoryShelf(_ category: Composer2LookCategory) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            shelfHeader(title: category.title, symbol: category.symbol, tint: Composer2Theme.accent(for: category)) {
                select(.category(category))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(Composer2ThemeCatalog.entries(in: category)) { entry in
                        card(entry.composition, symbol: entry.symbol, accent: Composer2Theme.accent(for: category),
                             isNew: entry.isNew, mine: false)
                            .frame(width: 168)
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollClipDisabled()
        }
    }

    private func shelfHeader(title: String, symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(LuminousType.cardTitle)
                    .foregroundStyle(LuminousPalette.ink)
                Spacer(minLength: 0)
                Text("See all")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(LuminousPalette.inkSecondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(LuminousPalette.inkSecondary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), see all")
    }

    // MARK: Card

    private func isPlaying(_ composition: Composer2Composition) -> Bool {
        center.isLive && center.session?.compositionID == composition.id
    }

    private func card(_ composition: Composer2Composition, symbol: String, accent: Color, isNew: Bool, mine: Bool,
                      style: Composer2LookCard.Style = .grid) -> some View {
        Composer2LookCard(composition: composition, symbol: symbol, accent: accent, isNew: isNew,
                          isSelected: isPlaying(composition), isPlaying: isPlaying(composition), style: style) {
            open = OpenRequest(room: room, composition: composition, mode: .tune)
        }
        .contextMenu {
            if isPlaying(composition), center.session?.roomID == room?.id {
                Button { stop() } label: { Label("Stop", systemImage: "stop.fill") }
            } else if let room {
                Button { play(composition) } label: { Label("Play in \(room.name)", systemImage: "play.fill") }
            }
            Button {
                open = OpenRequest(room: room, composition: composition, mode: .tune)
            } label: { Label("Open in Composer", systemImage: "slider.horizontal.3") }
            if mine {
                Divider()
                Button { renameText = composition.name; renameTarget = composition } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button {
                    HapticManager.shared.light()
                    store.duplicate(composition)
                } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                Button(role: .destructive) { deleteTarget = composition } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    // MARK: Build your own

    private var buildYourOwn: some View {
        Button {
            HapticManager.shared.medium()
            open = OpenRequest(room: room, composition: Self.starterLook(), mode: .layers)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(LuminousPalette.void)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(LuminousPalette.signalGradient))
                    .shadow(color: LuminousPalette.cyan.opacity(0.5), radius: 10)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Build your own")
                        .font(LuminousType.cardTitle)
                        .foregroundStyle(LuminousPalette.ink)
                    Text("Stack colour, motion, rhythm and moments into a look nobody else has.")
                        .font(.footnote)
                        .foregroundStyle(LuminousPalette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                LuminousChevron()
            }
            .padding(16)
            .luminousGlass(accent: LuminousPalette.cyan, selected: true)
        }
        .buttonStyle(LuminousPressStyle())
        .accessibilityHint("Opens the Composer's layers on a fresh look")
    }

    /// A fresh one-behaviour look to build from: a slow two-colour flow.
    static func starterLook() -> Composer2Composition {
        let layer = Composer2Layer(
            name: "Glow",
            color: Composer2ColorSource(stops: [Composer2XY(x: 0.1900, y: 0.2800), Composer2XY(x: 0.2600, y: 0.1300)]
                .map { Composer2PaletteStop($0) }),
            motion: Composer2Motion(kind: .flow, periodSeconds: 12))
        return Composer2Composition(name: "My look", subtitle: "", createdAt: Date(), layers: [layer])
    }

    // MARK: More tools

    private var moreTools: some View {
        LuminousGroup(title: "More tools",
                      footer: "Studio Classic keeps the tools that haven't moved into the Composer yet.") {
            Button(action: onOpenStudioClassic) {
                LuminousRow(symbol: "slider.horizontal.3", tint: LuminousPalette.violet, title: "Studio Classic",
                            subtitle: "Bulb effects, Live modes, Perform and your older looks")
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Actions

    private func stop() {
        HapticManager.shared.medium()
        let gateway = Composer2OrchestratorGateway(orchestrator: orchestrator)
        Task { await center.stop(gateway: gateway) }
    }

    /// One tap: play a look in the chosen room, applied (it keeps playing
    /// while ChromaGlow is open). Same owner, same seam as the instrument.
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

    private func commitRename() {
        guard let target = renameTarget else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, var current = store.composition(id: target.id) {
            current.name = trimmed
            store.save(current)
        }
        renameTarget = nil
    }
}
