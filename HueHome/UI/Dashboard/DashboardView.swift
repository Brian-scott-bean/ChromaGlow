// DashboardView.swift
// ChromaGlow — Home (Luminous).
//
// The house at a glance, drawn as light: every room is a small stage whose
// orbs are its lamps in their real colours, the background glows in the
// colours the lights are showing right now, and whatever is playing sits on
// top with its own Stop. Moods retune the whole home in one tap.
//
// Performance contracts kept from the previous Home:
//   • Room cards take a VALUE-TYPE room (never a binding) and are
//     `.equatable()`; their sliders keep local drag state and commit once.
//   • `signalNavigationStarted()` fires as a room push begins.
//   • Stale-while-revalidate: refresh only when data is ≥ 120 s old, on
//     appear and on foreground; a pull always refreshes (entertainment
//     availability first).
//   • Every clock pauses with `\.isTabActive`.
//   • The orchestrator's toast renders only in MainTabView.

import SwiftUI
import SwiftData

// MARK: - DashboardView

struct DashboardView: View {

    @Environment(UnifiedOrchestrator.self) private var orchestrator
    @Environment(MusicSessionCoordinator.self) private var music
    @State private var showEffectsMenu   = false   // multi-effect stop dropdown
    @State private var showScheduleSheet = false   // upcoming automations dropdown
    @State private var showMusicPicker   = false   // music strip → source picker
    /// The Composer, opened on the room a live look plays in.
    @State private var composerRoom: ComposerPresentation?

    @Query(sort: \AppAutomation.createdAt, order: .forward)
    private var appAutomations: [AppAutomation]
    @Environment(\.modelContext)         private var modelContext
    @Environment(\.scenePhase)           private var scenePhase
    @Environment(\.isTabActive)          private var isTabActive
    /// Persist zones section open/closed state across launches.
    @AppStorage("dashboard.zonesExpanded")  private var zonesExpanded: Bool  = true

    private static let gridSpacing: CGFloat = 12
    private let gridColumns = [GridItem(.adaptive(minimum: 158), spacing: 12)]

    @State private var presetToast:         String?  = nil
    @State private var activePreset:        String?  = nil
    @State private var currentHour:         Int      = Calendar.current.component(.hour, from: Date())
    @State private var allOffWorking:       Bool     = false
    @State private var activatingFavID:     String?  = nil  // tracks which favourite scene is activating
    /// Room/zone whose long-press colour wash sheet is showing.
    @State private var colorPopoverRoom:    RoomDisplayItem? = nil

    struct ComposerPresentation: Identifiable {
        let id = UUID()
        let room: RoomDisplayItem?
    }

    // ── Favorite Scenes (shared with RoomDetailView via @AppStorage) ────────────
    @AppStorage("favoriteSceneIDs") private var favoriteSceneIDsRaw: String = ""
    private var favoriteSceneIDs: [String] {
        favoriteSceneIDsRaw.split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }
    /// Favorite scenes resolved from orchestrator.globalScenes, preserving user order.
    private var favoriteScenes: [GlobalSceneItem] {
        let scenes = orchestrator.globalScenes
        return favoriteSceneIDs.compactMap { favID in
            scenes.first(where: { $0.bridgeSceneID == favID })
        }
    }
    private func removeFavorite(_ sceneID: String) {
        var ids = favoriteSceneIDsRaw.split(separator: ",").map(String.init)
        ids.removeAll { $0 == sceneID }
        favoriteSceneIDsRaw = ids.joined(separator: ",")
    }

    private let clockTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    /// Minimum seconds between auto-refreshes triggered by navigation or foregrounding.
    /// SSE handles real-time updates; this is a staleness fallback only.
    /// Pull-to-refresh always fires immediately regardless.
    private let refreshDebounceInterval: TimeInterval = 120

    // MARK: - Body

    var body: some View {
        ScrollView {
            content
                .padding(.horizontal, HueSpacing.screenH)
                .padding(.top, 8)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .refreshable {
            // A pull is the user asking, in as many words, for everything to be
            // re-checked — including whether a room can stream. `.userInitiated`
            // bypasses the background throttle.
            orchestrator.refreshEntertainmentAvailability(reason: .userInitiated)
            await orchestrator.loadAll(cacheContext: modelContext)
        }
        .background { LuminousAmbience(colors: ambienceColors) }
        .overlay(alignment: .bottom) {
            if let msg = presetToast {
                LuminousToastCapsule(text: msg)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: presetToast)
        .toolbar(.hidden, for: .navigationBar)
        .navigationTitle("Home")
        .navigationDestination(for: RoomDisplayItem.self) { room in
            RoomDetailView(room: room)
        }
        .sheet(isPresented: $showScheduleSheet) {
            UpcomingAutomationsSheet(automations: allUpcomingAutomations)
        }
        // Long-press a room/zone card → wash the room in a colour.
        .sheet(item: $colorPopoverRoom) { room in
            RoomColorPopover(room: room)
        }
        .sheet(isPresented: $showMusicPicker) {
            MusicSourcePicker()
        }
        .fullScreenCover(item: $composerRoom) { presentation in
            Composer2View(room: presentation.room)
                .environment(orchestrator)
        }
        .onReceive(clockTimer) { _ in
            // Skip the minute tick while Home is hidden; resync on return below.
            guard isTabActive else { return }
            currentHour = Calendar.current.component(.hour, from: Date())
        }
        .onChange(of: isTabActive) { _, active in
            if active { currentHour = Calendar.current.component(.hour, from: Date()) }
        }
        .task {
            // Stale-while-revalidate (startup, navigation back from a room).
            let staleness = Date().timeIntervalSince(orchestrator.lastLoadedAt)
            guard staleness >= refreshDebounceInterval else { return }
            await orchestrator.loadAll(cacheContext: modelContext)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                let staleness = Date().timeIntervalSince(orchestrator.lastLoadedAt)
                if staleness >= refreshDebounceInterval {
                    Task { await orchestrator.loadAll(cacheContext: modelContext) }
                }
            }
        }
        // M-08: partial bulk-write failures (All Off / moods) surface as a
        // toast instead of silently leaving rooms in their old state.
        .onChange(of: orchestrator.lastBulkFailure) { _, failure in
            guard let failure else { return }
            let rooms = failure.roomNames.prefix(3).joined(separator: ", ")
            let suffix = failure.roomNames.count > 3 ? " +\(failure.roomNames.count - 3) more" : ""
            presetToast = "\(failure.operation) didn't reach \(rooms)\(suffix)"
        }
        .preferredColorScheme(.dark)
    }

    /// The colours the house is showing right now — the background glows in them.
    private var ambienceColors: [Color] {
        let lit = orchestrator.allRooms.filter(\.isOn)
        guard !lit.isEmpty else { return [LuminousPalette.night] }
        return Array(lit.sorted { $0.brightness > $1.brightness }.prefix(3).map(\.luminousColor))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            titleBlock
            if orchestrator.allRooms.isEmpty {
                if orchestrator.isLoading {
                    loadingCards
                } else if orchestrator.guestAccessInfo.hasAnyGrant {
                    // Zero allowed rooms is the fail-closed grant outcome, not
                    // a connection problem — say so honestly.
                    GuestZeroRoomsState()
                } else {
                    LuminousEmptyState(symbol: "lightbulb.slash.fill", title: "No rooms yet",
                                       message: "Pull to refresh, or pair a bridge in More → Bridges.")
                }
            } else {
                GuestAccessBanner()

                if orchestrator.activeEffectName != nil {
                    HomeNowPlayingCard(entries: orchestrator.activeEffectEntries,
                                       isAppDriven: orchestrator.activeEffectIsAppDriven,
                                       onStop: stopEffect,
                                       onStopAll: stopAllEffects,
                                       onOpenComposer: openComposer)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                if let suggestion = timeSuggestion, canApplyPresets {
                    TimeSuggestionBanner(suggestion: suggestion) {
                        applyPreset(suggestion.preset)
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                if let next = nextAutomation {
                    let upcomingCount = allUpcomingAutomations.count
                    NextAutomationBanner(name: next.automation.name,
                                         icon: next.automation.action.icon,
                                         fireDate: next.date,
                                         moreCount: max(0, upcomingCount - 1))
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .onTapGesture { if upcomingCount > 1 { showScheduleSheet = true } }
                }

                // Moods retune and re-dim: hidden when no visible room grants
                // both power and adjust (the orchestrator skips those anyway).
                if canApplyPresets {
                    moods
                }

                // Music session strip — a sibling of Now Playing (the effect
                // registry and the music session never merge state).
                if music.hasSession {
                    MusicNowPlayingBar(style: .compact, onOpenPicker: { showMusicPicker = true })
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                roomsSection

                if !orchestrator.allZones.isEmpty {
                    zonesSection
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        let onCount = orchestrator.allRooms.filter(\.isOn).count
        let total = orchestrator.allRooms.count
        return HStack(spacing: 10) {
            if orchestrator.isLoading && orchestrator.allRooms.isEmpty {
                LuminousStateChip(text: "Finding your lights…", dot: LuminousPalette.cyan, glowing: true)
            } else if total == 0 {
                LuminousStateChip(text: orchestrator.isDemoMode ? "Demo home" : "No rooms")
            } else {
                LuminousStateChip(text: onCount == 0 ? "All lights off" : "\(onCount) of \(total) rooms on",
                                  dot: onCount > 0 ? LuminousPalette.amber : LuminousPalette.inkSecondary,
                                  glowing: onCount > 0)
            }
            Spacer(minLength: 0)
            if orchestrator.isLoading && !orchestrator.allRooms.isEmpty {
                ProgressView().tint(LuminousPalette.ink).scaleEffect(0.85)
                    .accessibilityLabel("Refreshing")
            }
            if orchestrator.allRooms.contains(where: \.isOn) {
                if allOffWorking {
                    ProgressView().tint(LuminousPalette.ink)
                        .frame(width: 44, height: 44)
                } else {
                    LuminousRoundButton(symbol: "power", label: "Turn all lights off", action: turnAllOff)
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: orchestrator.allRooms.contains(where: \.isOn))
    }

    private var titleBlock: some View {
        let lightsOn = orchestrator.allRooms.filter(\.isOn).reduce(0) { $0 + $1.lightCount }
        var subtitle = orchestrator.allRooms.isEmpty
            ? "Your lights, drawn as light."
            : (lightsOn == 0 ? "Everything is dark. Tap a mood or a room to bring it up."
                             : "\(lightsOn) light\(lightsOn == 1 ? "" : "s") glowing across your home.")
        if orchestrator.isDemoMode { subtitle += " · Demo home" }
        return LuminousScreenTitle(title: timeGreeting,
                                   eyebrow: "Home",
                                   eyebrowSymbol: timeSymbol,
                                   eyebrowTint: timeTint,
                                   subtitle: subtitle)
    }

    private var timeGreeting: String {
        switch currentHour {
        case 5..<12:  return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<21: return "Good evening"
        default:      return "Good night"
        }
    }

    private var timeSymbol: String {
        switch currentHour {
        case 5..<12:  return "sunrise.fill"
        case 12..<17: return "sun.max.fill"
        case 17..<21: return "sunset.fill"
        default:      return "moon.stars.fill"
        }
    }

    private var timeTint: Color {
        switch currentHour {
        case 5..<12:  return Color(hex: "#FFD36B")
        case 12..<17: return LuminousPalette.cyan
        case 17..<21: return Color(hex: "#FF9F5C")
        default:      return LuminousPalette.violet
        }
    }

    // MARK: - Now Playing

    private func stopEffect(_ entry: ActiveEffectEntry?) {
        guard let entry else { return }
        HapticManager.shared.medium()
        Task {
            // The owner does the teardown (engine loops, per-light cleanup) —
            // a bare grouped-light PUT here would leave the loop running.
            // Routed on the ENTRY: a recovered bridge-stored row's id is its
            // manifest, not its room, and only the manifest says which bridge
            // to clean.
            await orchestrator.requestNowPlayingStop(entry)
        }
    }

    private func stopAllEffects() {
        HapticManager.shared.medium()
        Task {
            for entry in orchestrator.activeEffectEntries {
                await orchestrator.requestNowPlayingStop(entry)
            }
        }
    }

    private func openComposer(_ entry: ActiveEffectEntry) {
        HapticManager.shared.medium()
        let room = (orchestrator.allRooms + orchestrator.allZones).first { $0.id == entry.roomID }
        composerRoom = ComposerPresentation(room: room)
    }

    // MARK: - Moods

    private typealias LightPreset = DashboardLightPreset

    private let presets: [LightPreset] = LightingPreset.all.map(LightPreset.init)

    /// Family Sharing: true when at least one visible room/zone may take a
    /// mood. A mood turns lights on AND re-dims/recolours them (onOff +
    /// adjust) — a phone whose every room lacks either gets no mood surfaces.
    private var canApplyPresets: Bool {
        (orchestrator.allRooms + orchestrator.allZones).contains {
            let features = orchestrator.guestFeatures(for: $0.bridgeID)
            return features.canPower && features.canAdjust
        }
    }

    private var moods: some View {
        VStack(alignment: .leading, spacing: 10) {
            LuminousSectionHeader(title: "Moods",
                                  subtitle: favoriteScenes.isEmpty
                                    ? "Every room at once."
                                    : "Every room at once — then your starred scenes.")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(presets) { preset in
                        HomeMoodTile(title: preset.name,
                                     symbol: preset.icon,
                                     detail: "\(BrightnessDisplay.percent(preset.brightness))% · \(HueColorUtils.kelvin(from: preset.mirek))K",
                                     colors: [preset.lightColor],
                                     level: preset.brightness / 100,
                                     isBusy: activePreset == preset.id) {
                            applyPreset(preset)
                        }
                        .accessibilityLabel("\(preset.name), every room")
                    }
                    ForEach(favoriteScenes) { scene in
                        let roomName = (orchestrator.allRooms + orchestrator.allZones)
                            .first(where: { $0.id == scene.roomID })?.name ?? ""
                        HomeMoodTile(title: scene.name,
                                     symbol: "star.fill",
                                     detail: roomName,
                                     colors: scene.luminousColors,
                                     level: 0.85,
                                     isBusy: activatingFavID == scene.bridgeSceneID) {
                            activateFavoriteScene(scene)
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                removeFavorite(scene.bridgeSceneID)
                            } label: {
                                Label("Unfavorite", systemImage: "star.slash")
                            }
                        }
                        .accessibilityLabel("\(scene.name), \(roomName), starred scene")
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollClipDisabled()
        }
    }

    private func activateFavoriteScene(_ scene: GlobalSceneItem) {
        HapticManager.shared.medium()
        activatingFavID = scene.bridgeSceneID
        orchestrator.activateGlobalScene(scene)
        Task {
            await MainActor.run { presetToast = "\(scene.name) is on" }
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run {
                activatingFavID = nil
                if presetToast?.contains(scene.name) == true { presetToast = nil }
            }
        }
    }

    private func applyPreset(_ preset: LightPreset) {
        HapticManager.shared.medium()
        withAnimation { activePreset = preset.id }

        Task {
            // M-08: the moods share ids with AutomationPreset — delegate to
            // the orchestrator's paced, failure-surfacing bulk path.
            await orchestrator.applyAutomationPreset(id: preset.id)
            await MainActor.run {
                presetToast = "\(preset.name) — every room"
                withAnimation { activePreset = nil }
            }
            try? await Task.sleep(for: .seconds(3))
            await MainActor.run {
                if presetToast?.contains(preset.name) == true { presetToast = nil }
            }
        }
    }

    // ── Time-aware suggestion ─────────────────────────────────────────────────
    // Only shown when every room is off (never interrupts an active scene).

    private typealias TimeSuggestion = DashboardTimeSuggestion

    private var timeSuggestion: TimeSuggestion? {
        guard orchestrator.allRooms.allSatisfy({ !$0.isOn }) else { return nil }
        guard !orchestrator.allRooms.isEmpty else { return nil }
        let energize = presets.first(where: { $0.id == "energize" })!
        let read     = presets.first(where: { $0.id == "read" })!
        let relax    = presets.first(where: { $0.id == "relax" })!
        let sleep    = presets.first(where: { $0.id == "sleep" })!
        switch currentHour {
        case 5..<9:   return TimeSuggestion(message: "Rise and shine",     subtext: "Start the morning bright",   preset: energize)
        case 9..<12:  return TimeSuggestion(message: "Time to focus",      subtext: "Cool, clear light for work", preset: energize)
        case 12..<14: return TimeSuggestion(message: "Afternoon reading?", subtext: "Easy on the eyes",           preset: read)
        case 14..<17: return TimeSuggestion(message: "Afternoon boost",    subtext: "Keep the energy going",      preset: energize)
        case 17..<20: return TimeSuggestion(message: "Time to wind down",  subtext: "Ease into the evening",      preset: relax)
        case 20..<23: return TimeSuggestion(message: "Ready for sleep?",   subtext: "Dim the lights, rest well",  preset: sleep)
        default:      return TimeSuggestion(message: "Still up late?",     subtext: "A low, warm glow",           preset: sleep)
        }
    }

    /// All enabled automations sorted by next fire date (nearest first).
    private var allUpcomingAutomations: [(automation: AppAutomation, date: Date)] {
        let now      = Date()
        let calendar = Calendar.current
        var results: [(AppAutomation, Date)] = []
        for automation in appAutomations where automation.isEnabled {
            for dayOffset in 0..<8 {
                guard let targetDay = calendar.date(byAdding: .day, value: dayOffset, to: now) else { continue }
                let weekday = calendar.component(.weekday, from: targetDay)
                guard automation.weekdays.contains(weekday) else { continue }
                var comps   = calendar.dateComponents([.year, .month, .day], from: targetDay)
                comps.hour   = automation.hour
                comps.minute = automation.minute
                comps.second = 0
                guard let fireDate = calendar.date(from: comps), fireDate > now else { continue }
                results.append((automation, fireDate))
                break
            }
        }
        return results.sorted { $0.1 < $1.1 }
    }

    private var nextAutomation: (automation: AppAutomation, date: Date)? {
        // Derived from the live @Query (audit L-24).
        allUpcomingAutomations.first
    }

    // MARK: - Rooms & zones

    private var roomsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LuminousSectionHeader(title: "Rooms",
                                  subtitle: "Tap a room to step in. Hold one to wash it in a color.")
            LazyVGrid(columns: gridColumns, spacing: Self.gridSpacing) {
                ForEach(orchestrator.allRooms, id: \.id) { room in
                    roomCard(room)
                }
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.8), value: orchestrator.allRooms.count)
        }
    }

    private var zonesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) { zonesExpanded.toggle() }
                HapticManager.shared.selection()
            } label: {
                LuminousSectionHeader(title: "Zones", subtitle: "Lights grouped across rooms.") {
                    HStack(spacing: 8) {
                        Text("\(orchestrator.allZones.count)")
                            .font(LuminousType.value)
                            .foregroundStyle(LuminousPalette.inkSecondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(LuminousPalette.inkSecondary)
                            .rotationEffect(.degrees(zonesExpanded ? 90 : 0))
                    }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(zonesExpanded ? "Hides your zones" : "Shows your zones")

            if zonesExpanded {
                LazyVGrid(columns: gridColumns, spacing: Self.gridSpacing) {
                    ForEach(orchestrator.allZones, id: \.id) { zone in
                        roomCard(zone)
                    }
                }
                .animation(.spring(response: 0.45, dampingFraction: 0.8), value: orchestrator.allZones.count)
            }
        }
    }

    private func roomCard(_ room: RoomDisplayItem) -> some View {
        let features = orchestrator.guestFeatures(for: room.bridgeID)
        return HomeRoomCard(
            room: room,
            lights: lamps(for: room),
            features: features,
            isLive: orchestrator.activeEffectEntries.contains { $0.roomID == room.id },
            onToggle: { desiredOn in orchestrator.setRoom(room, isOn: desiredOn) },
            onBrightness: { newBrightness in orchestrator.setBrightness(newBrightness, for: room) },
            onNavigate: { orchestrator.signalNavigationStarted() },
            // The colour wash repaints the room — adjust-level access; a
            // power-only guest gets no long-press.
            onLongPress: features.canAdjust ? { colorPopoverRoom = room } : nil
        )
        .equatable()
        .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .bottom)), removal: .opacity))
    }

    /// The room's lamps as the card draws them. The per-light cache is
    /// SSE-patched (truthful) but read imperatively, so it is sampled when
    /// the room itself changes; a room that is off draws every lamp dark.
    private func lamps(for room: RoomDisplayItem) -> [LightDisplayItem] {
        let lights = orchestrator.isDemoMode
            ? DemoDataProvider.lights(for: room.id)
            : orchestrator.cachedLightItems(for: room)
        guard room.isOn else {
            return lights.map { var l = $0; l.isOn = false; return l }
        }
        return lights
    }

    private var loadingCards: some View {
        LazyVGrid(columns: gridColumns, spacing: Self.gridSpacing) {
            ForEach(0..<4, id: \.self) { _ in
                RoundedRectangle(cornerRadius: LuminousPalette.cardRadius, style: .continuous)
                    .fill(Color.white.opacity(0.04))
                    .frame(height: 150)
                    .luminousGlass(radius: LuminousPalette.cardRadius)
                    .redacted(reason: .placeholder)
            }
        }
        .accessibilityLabel("Loading rooms")
    }

    // MARK: - All off

    private func turnAllOff() {
        HapticManager.shared.heavy()
        allOffWorking = true
        Task {
            // M-08: the orchestrator's paced, failure-surfacing All Off.
            await orchestrator.turnAllOff()
            await MainActor.run {
                allOffWorking = false
                presetToast   = "All lights off"
            }
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run {
                if presetToast == "All lights off" { presetToast = nil }
            }
        }
    }
}

// MARK: - Toast

/// A short confirmation that floats over the bottom of a screen.
struct LuminousToastCapsule: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(LuminousPalette.ink)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Capsule().fill(.ultraThinMaterial))
            .background(Capsule().fill(LuminousPalette.void.opacity(0.5)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
            .padding(.horizontal, 24)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

// MARK: - Mood tile

/// A mood or a starred scene: the light it makes, as orbs, over its name.
struct HomeMoodTile: View {
    let title: String
    let symbol: String
    let detail: String
    let colors: [Color]
    var level: Double = 1
    var isBusy: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                LuminousPaletteOrbs(colors: colors, count: 3, height: 36)
                    .opacity(0.45 + 0.55 * min(1, max(0.15, level)))
                HStack(spacing: 6) {
                    if isBusy {
                        ProgressView().tint(colors.first ?? LuminousPalette.ink).scaleEffect(0.7)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(colors.first ?? LuminousPalette.ink)
                    }
                    Text(title)
                        .font(LuminousType.cardTitleSmall)
                        .foregroundStyle(LuminousPalette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Text(detail.isEmpty ? " " : detail)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(LuminousPalette.inkSecondary)
                    .lineLimit(1)
            }
            .padding(12)
            .frame(width: 124, alignment: .leading)
            .luminousPanel(radius: 18, glow: colors.first, glowStrength: 0.35 + 0.5 * level)
        }
        .buttonStyle(LuminousPressStyle(scale: 0.95))
        .disabled(isBusy)
    }
}

// MARK: - Shared value types (file-level for cross-struct access)

struct DashboardLightPreset: Identifiable {
    let id:         String
    let name:       String
    let icon:       String
    let brightness: Double
    let mirek:      Int
    let color:      Color

    /// Behavior (id/name/icon/brightness/mirek) comes from the shared catalog;
    /// only the tint is styling that lives at the surface.
    init(_ preset: LightingPreset) {
        id = preset.id
        name = preset.name
        icon = preset.icon
        brightness = preset.brightness
        mirek = preset.mirek
        color = preset.chipColor
    }

    /// The white this mood actually sets, as a screen colour.
    var lightColor: Color {
        let p = LuminousLight.xy(mirek: mirek)
        return HueColorUtils.color(fromX: p.x, y: p.y, brightness: 100)
    }
}

struct DashboardTimeSuggestion {
    let message:  String
    let subtext:  String
    let preset:   DashboardLightPreset
}

extension GlobalSceneItem {
    /// The colours a scene paints with: its real palette when the bridge
    /// listed one, otherwise its tint in three shades.
    var luminousColors: [Color] {
        if !paletteXY.isEmpty {
            return paletteXY.map { HueColorUtils.color(fromX: $0.x, y: $0.y, brightness: 100) }
        }
        return [accentColor, accentColor.opacity(0.8), accentColor]
    }
}

// ══════════════════════════════════════════════════════════
// MARK: - BrightnessRow
//
// Performance contract:
//   • brightness (Double)    — read-only value from parent
//   • onCommit((Double)->())  — called ONCE when drag ends
//
// During drag: only @State vars change → zero @Observable writes
//              → zero parent re-renders → 60 fps smooth.
// After drag:  onCommit fires which updates orchestrator/VM (one write).
// External sync: .onChange(of: brightness) updates localBrightness when
//              SSE pushes a new value from the bridge (not during drag).
// ══════════════════════════════════════════════════════════

struct BrightnessRow: View {

    // ── Inputs ──────────────────────────────────────────
    let brightness: Double   // current "truth" value from parent (read-only)
    let glowColor:  Color
    let onCommit:   (Double) -> Void        // fires once at gesture end

    // ── Local drag state — NEVER propagated to parent during drag ─────
    @State private var localBrightness: Double
    @State private var isDragging:  Bool   = false
    @State private var lastNotch:   Int    = 0

    init(brightness: Double, glowColor: Color,
         onCommit: @escaping (Double) -> Void) {
        self.brightness = brightness
        self.glowColor  = glowColor
        self.onCommit   = onCommit
        _localBrightness = State(initialValue: brightness)
    }

    private var displayValue: Double { localBrightness }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sun.min.fill")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.35))

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.10))
                        .frame(height: 4)
                    Capsule()
                        .fill(LinearGradient(
                            colors: [glowColor.opacity(0.6), glowColor],
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .frame(width: max(6, geo.size.width * CGFloat(displayValue / 100)), height: 4)
                    Circle()
                        .fill(.white)
                        .frame(width: isDragging ? 16 : 12, height: isDragging ? 16 : 12)
                        .shadow(color: glowColor.opacity(0.6), radius: isDragging ? 6 : 3)
                        .offset(x: max(0, geo.size.width * CGFloat(displayValue / 100) - (isDragging ? 8 : 6)))
                        .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isDragging)
                }
                .frame(height: 16)
                .contentShape(Rectangle().inset(by: -8))
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .local)
                        .onChanged { value in
                            if !isDragging {
                                isDragging = true
                                lastNotch  = Int(localBrightness / 10)
                                HapticManager.shared.medium()
                            }
                            let rawPercent = Double(value.location.x / geo.size.width) * 100
                            let newVal     = min(100, max(1, rawPercent))
                            localBrightness = newVal
                            let notch = Int(newVal / 10)
                            if notch != lastNotch {
                                HapticManager.shared.soft()
                                lastNotch = notch
                            }
                        }
                        .onEnded { _ in
                            isDragging = false
                            HapticManager.shared.heavy()
                            onCommit(localBrightness)
                        }
                )
            }
            .frame(height: 16)

            HStack(spacing: 2) {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.35))
                Text("\(BrightnessDisplay.percent(displayValue))%")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 28, alignment: .trailing)
                    .contentTransition(isDragging ? .identity : .numericText())
                    .animation(isDragging ? .none : .default, value: displayValue)
            }
        }
        .padding(.top, 4)
        .onChange(of: brightness) { _, new in
            if !isDragging { localBrightness = new }
        }
        .accessibilityLabel("Brightness")
        .accessibilityValue("\(Int(displayValue)) percent")
        .accessibilityAdjustableAction { direction in
            let step: Double = 10
            let newVal: Double
            switch direction {
            case .increment: newVal = min(100, localBrightness + step)
            case .decrement: newVal = max(1,   localBrightness - step)
            @unknown default: return
            }
            localBrightness = newVal
            onCommit(newVal)
        }
    }
}

// ══════════════════════════════════════════════════════════
// MARK: - TimeSuggestionBanner
// ══════════════════════════════════════════════════════════

/// Everything is off — offer the mood that fits the hour.
struct TimeSuggestionBanner: View {

    let suggestion: DashboardTimeSuggestion
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            LuminousPaletteOrbs(colors: [suggestion.preset.lightColor], count: 1, height: 44)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(suggestion.message)
                    .font(LuminousType.cardTitleSmall)
                    .foregroundStyle(LuminousPalette.ink)
                    .lineLimit(1)
                Text(suggestion.subtext)
                    .font(.caption)
                    .foregroundStyle(LuminousPalette.inkSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            LuminousPrimaryButton(title: suggestion.preset.name, symbol: suggestion.preset.icon, compact: true, action: onTap)
                .accessibilityLabel("\(suggestion.preset.name), every room")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .luminousPanel(radius: 20, glow: suggestion.preset.lightColor, glowStrength: 0.5)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: suggestion.message)
    }
}

// ══════════════════════════════════════════════════════════
// MARK: - NextAutomationBanner
// ══════════════════════════════════════════════════════════

struct NextAutomationBanner: View {
    let name:      String
    let icon:      String
    let fireDate:  Date
    var moreCount: Int = 0          // number of additional automations beyond the first

    @State private var now: Date = Date()
    @Environment(\.isTabActive) private var isTabActive
    // 10s cadence: the relative label only visibly changes near the final
    // minute, and the ticker is paused entirely while Home is off-screen.
    private let ticker = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    /// Shared formatter. Accessed only on the main thread; nonisolated(unsafe)
    /// matches the codebase idiom for main-confined shared state.
    nonisolated(unsafe) fileprivate static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private var timeLabel: String {
        let rel = Self.relativeFormatter.localizedString(for: fireDate, relativeTo: now)
        let abs = fireDate.formatted(date: .omitted, time: .shortened)
        let interval = fireDate.timeIntervalSince(now)
        return interval < 6 * 3600 ? rel : abs
    }

    var body: some View {
        HStack(spacing: 12) {
            LuminousIconBadge(symbol: icon, tint: LuminousPalette.violet, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                LuminousEyebrow(text: "Next up")
                Text(name)
                    .font(LuminousType.cardTitleSmall)
                    .foregroundStyle(LuminousPalette.ink)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Text(timeLabel)
                    .font(LuminousType.value)
                    .foregroundStyle(LuminousPalette.ink.opacity(0.75))
                if moreCount > 0 {
                    Text("+\(moreCount)")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(LuminousPalette.void)
                        .padding(.horizontal, 8)
                        .frame(minHeight: 24)
                        .background(Capsule().fill(LuminousPalette.violet))
                    LuminousChevron()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 60)
        .luminousGlass(radius: 18)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(moreCount > 0 ? "Double tap to see every upcoming schedule" : "")
        .onAppear { now = Date() }
        .onReceive(ticker) { newNow in
            guard isTabActive else { return }
            now = newNow
        }
        .onChange(of: isTabActive) { _, active in
            if active { now = Date() }
        }
    }
}

// MARK: - UpcomingAutomationsSheet

struct UpcomingAutomationsSheet: View {
    let automations: [(automation: AppAutomation, date: Date)]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    LuminousScreenTitle(title: "Coming up", eyebrow: "Schedules",
                                        eyebrowSymbol: "calendar.badge.clock", eyebrowTint: LuminousPalette.violet,
                                        subtitle: "Every schedule, soonest first.")
                    LuminousGroup {
                        ForEach(Array(automations.enumerated()), id: \.offset) { idx, item in
                            LuminousRow(symbol: item.automation.action.icon, tint: LuminousPalette.violet,
                                        title: item.automation.name,
                                        subtitle: "\(item.automation.timeLabel) · \(item.automation.daysLabel)") {
                                Text(NextAutomationBanner.relativeFormatter.localizedString(for: item.date, relativeTo: Date()))
                                    .font(LuminousType.value)
                                    .foregroundStyle(LuminousPalette.violet)
                            }
                            if idx < automations.count - 1 { LuminousRowDivider() }
                        }
                    }
                }
                .padding(.horizontal, HueSpacing.screenH)
                .padding(.vertical, 16)
            }
            .background { LuminousAmbience(colors: [LuminousPalette.violet]) }
            .luminousNavigationChrome()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(LuminousPalette.cyan)
                }
            }
        }
        .luminousSheet()
    }
}
