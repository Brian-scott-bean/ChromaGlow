    // DashboardView.swift
// CastChroma — Epic 2 / Story 2.1
//
// Performance re-pass (v0.3.3):
// ─────────────────────────────
// The previous @Bindable + $orch.allRooms[i] pattern wrote to @Observable
// on every drag tick (60 fps) → full view-tree re-render on each frame.
//
// Fix: RoomCard accepts a VALUE TYPE room, not a @Binding. BrightnessRow
// keeps its own @State var localBrightness and only calls onCommit() on
// drag END. Zero @Observable mutations during a drag. Result: silky 60 fps.

import SwiftUI
import SwiftData

// MARK: - DashboardView

struct DashboardView: View {

    @Environment(UnifiedOrchestrator.self) private var orchestrator
    @Environment(MusicSessionCoordinator.self) private var music
    @State private var showLog           = false
    @State private var showEffectsMenu   = false   // multi-effect stop dropdown
    @State private var showScheduleSheet = false   // upcoming automations dropdown
    @State private var showMusicPicker = false     // music strip → source picker

    @Query(sort: \AppAutomation.createdAt, order: .forward)
    private var appAutomations: [AppAutomation]
    @Environment(\.modelContext)         private var modelContext
    @Environment(\.scenePhase)           private var scenePhase
    @Environment(\.isTabActive)          private var isTabActive
    /// Persist zones section open/closed state across launches.
    @AppStorage("dashboard.zonesExpanded")  private var zonesExpanded: Bool  = true
    @AppStorage("castchroma.useWideCards")  private var useWideCards: Bool   = false

    // MARK: - Layout
    //
    // Home uses the canonical SwiftUI dashboard pattern:
    //   ScrollView → VStack → sections, with ONE horizontal padding on the
    //   VStack and `.adaptive` LazyVGrid columns. The system handles
    //   responsiveness — there is no custom layout profile, no GeometryReader,
    //   no per-section padding. Cards reflow from 1 column on iPhone SE to 2+
    //   columns on larger devices automatically.
    //
    private static let horizontalInset: CGFloat = 20
    private static let sectionSpacing: CGFloat  = 14
    private static let gridSpacing: CGFloat     = 14
    private static let minimumCardWidth: CGFloat = 170

    private var gridColumns: [GridItem] {
        if useWideCards {
            return [GridItem(.flexible(), spacing: Self.gridSpacing)]
        }
        return [GridItem(.adaptive(minimum: Self.minimumCardWidth), spacing: Self.gridSpacing)]
    }

    @State private var presetToast:         String?  = nil
    @State private var activePreset:        String?  = nil
    @State private var currentHour:         Int      = Calendar.current.component(.hour, from: Date())
    @State private var allOffWorking:       Bool     = false
    @State private var activatingFavID:     String?  = nil  // tracks which fav scene pill is activating
    /// Room/zone whose long-press color popup is showing (sheet item).
    @State private var colorPopoverRoom:    RoomDisplayItem? = nil


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
    //
    // Architecture: ScrollView is the root. The ambient background goes on
    // the .background modifier (NOT as a sibling in a ZStack) so its
    // .ignoresSafeArea cannot pollute content sizing. The toast is an
    // .overlay on the ScrollView. Modal/sheets/lifecycle modifiers attach
    // to the ScrollView. This is the canonical SwiftUI dashboard pattern.
    //
    var body: some View {
        ScrollView {
            content
                .padding(.horizontal, Self.horizontalInset)
                .padding(.top, 8)
                .padding(.bottom, 100) // clear floating tab bar
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .refreshable {
            await orchestrator.loadAll(cacheContext: modelContext)
        }
        .background {
            DashboardAmbientBackground(hour: currentHour)
                .ignoresSafeArea()
        }
        .overlay(alignment: .top) {
            if let msg = orchestrator.toastMessage {
                HueToastView(message: msg)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
                    .zIndex(10)
            }
        }
        .overlay(alignment: .bottom) {
            if let msg = presetToast {
                Text(msg)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                    .shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 4)
                    .padding(.bottom, 104)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: orchestrator.toastMessage)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: presetToast)
        .navigationTitle(orchestrator.isDemoMode ? "My Lights  ✦ Demo" : "My Lights")
        .navigationBarTitleDisplayMode(.large)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar { toolbarItems }
        .navigationDestination(for: RoomDisplayItem.self) { room in
            RoomDetailView(room: room)
        }
        .sheet(isPresented: $showScheduleSheet) {
            UpcomingAutomationsSheet(automations: allUpcomingAutomations)
        }
        // Long-press a room/zone card → paint the room (color wheel + harmony).
        .sheet(item: $colorPopoverRoom) { room in
            RoomColorPopover(room: room)
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
            // Stale-while-revalidate: trigger a background loadAll() on every
            // dashboard appearance (startup, navigation-back from a room) if
            // data is older than refreshDebounceInterval seconds.
            // AppRootView already fires loadAll() at startup — the isLoading
            // guard inside loadAll() will suppress that concurrent initial call.
            let staleness = Date().timeIntervalSince(orchestrator.lastLoadedAt)
            guard staleness >= refreshDebounceInterval else { return }
            await orchestrator.loadAll(cacheContext: modelContext)
        }
        .onChange(of: scenePhase) { _, newPhase in
            // When app returns to foreground, refresh if data is stale.
            if newPhase == .active {
                let staleness = Date().timeIntervalSince(orchestrator.lastLoadedAt)
                if staleness >= refreshDebounceInterval {
                    Task { await orchestrator.loadAll(cacheContext: modelContext) }
                }
            }
        }
        // M-08: partial bulk-write failures (All Off / automations) surface as
        // a toast instead of silently leaving rooms in their old state.
        .onChange(of: orchestrator.lastBulkFailure) { _, failure in
            guard let failure else { return }
            let rooms = failure.roomNames.prefix(3).joined(separator: ", ")
            let suffix = failure.roomNames.count > 3 ? " +\(failure.roomNames.count - 3) more" : ""
            presetToast = "⚠ \(failure.operation) failed for \(rooms)\(suffix)"
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Content
    //
    // ONE VStack. ONE horizontal padding (applied by the parent ScrollView).
    // No section sets its own horizontal padding — that's the rule that
    // keeps Home deterministic on every device size.
    //
    @ViewBuilder
    private var content: some View {
        if orchestrator.allRooms.isEmpty {
            if orchestrator.isLoading {
                shimmerView
            } else if orchestrator.guestAccessInfo.hasAnyGrant {
                // Zero allowed rooms is the fail-closed grant outcome, not
                // a connection problem — say so honestly.
                GuestZeroRoomsState()
            } else {
                emptyState
            }
        } else {
            VStack(alignment: .leading, spacing: Self.sectionSpacing) {
                GuestAccessBanner()

                summaryHeader

                if let suggestion = timeSuggestion {
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

                // Presets row deliberately bleeds past the trailing edge so
                // chips can scroll under the screen border (Apple-style rail).
                presetsBar
                    .padding(.horizontal, -Self.horizontalInset)
                    .padding(.leading, Self.horizontalInset)

                if orchestrator.activeEffectName != nil {
                    nowPlayingBar
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                // Music session strip — sibling of the effects bar above
                // (the effect registry and the music session never merge).
                // Whole-strip tap opens the picker, same as Studio's bar —
                // it LOOKED tappable but was inert without the closure
                // (audit R9, F11). Sheet is scoped to the strip on purpose.
                if music.hasSession {
                    MusicNowPlayingBar(style: .compact,
                                       onOpenPicker: { showMusicPicker = true })
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .sheet(isPresented: $showMusicPicker) {
                            MusicSourcePicker()
                        }
                }

                LazyVGrid(columns: gridColumns, spacing: Self.gridSpacing) {
                    ForEach(orchestrator.allRooms, id: \.id) { room in
                        RoomCard(
                            room: room,
                            onToggle: { desiredOn in orchestrator.setRoom(room, isOn: desiredOn) },
                            onBrightness: { newBrightness in orchestrator.setBrightness(newBrightness, for: room) },
                            onNavigate: { orchestrator.signalNavigationStarted() },
                            onLongPress: { colorPopoverRoom = room },
                            features: orchestrator.guestFeatures(for: room.bridgeID)
                        )
                        .equatable()
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .bottom)),
                            removal:   .opacity
                        ))
                    }
                }
                .animation(.spring(response: 0.45, dampingFraction: 0.8), value: orchestrator.allRooms.count)

                if !orchestrator.allZones.isEmpty {
                    zonesSectionHeader
                        .padding(.top, 12)

                    if zonesExpanded {
                        LazyVGrid(columns: gridColumns, spacing: Self.gridSpacing) {
                            ForEach(orchestrator.allZones, id: \.id) { zone in
                                RoomCard(
                                    room: zone,
                                    onToggle: { desiredOn in orchestrator.setRoom(zone, isOn: desiredOn) },
                                    onBrightness: { newBrightness in orchestrator.setBrightness(newBrightness, for: zone) },
                                    onNavigate: { orchestrator.signalNavigationStarted() },
                                    onLongPress: { colorPopoverRoom = zone },
                                    features: orchestrator.guestFeatures(for: zone.bridgeID)
                                )
                                .equatable()
                                .transition(.asymmetric(
                                    insertion: .opacity.combined(with: .move(edge: .bottom)),
                                    removal:   .opacity
                                ))
                            }
                        }
                        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: orchestrator.allZones.count)
                    }
                }
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Now Playing Bar

    private var nowPlayingBar: some View {
        let entries = orchestrator.activeEffectEntries
        let primary = entries.last   // most recent — matches activeEffectName/Icon

        return HStack(spacing: 12) {
            // Pulsing indicator dot
            Circle()
                .fill(orchestrator.activeEffectIsAppDriven ? Color.cyan : Color.green)
                .frame(width: 8, height: 8)
                .overlay(
                    Circle()
                        .fill((orchestrator.activeEffectIsAppDriven ? Color.cyan : Color.green).opacity(0.35))
                        .frame(width: 16)
                )

            if let icon = primary?.effectIcon {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(primary?.effectName ?? "")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let roomName = primary?.roomName {
                    Text(entries.count > 1
                         ? "\(roomName) · \(entries.count - 1) more room\(entries.count > 2 ? "s" : "")"
                         : roomName)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }

            if orchestrator.activeEffectIsAppDriven {
                Text("— keep app open")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer()

            // Global clock presence: transport-only panel (no per-effect
            // binding from here — that lives on the owning surface).
            BeatChipButton(capabilities: [.transport, .manualBPM, .barMeter],
                           compact: true)

            Button {
                if entries.count > 1 {
                    showEffectsMenu = true
                } else {
                    stopEffect(entries.last)
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Stop")
                        .font(.system(size: 13, weight: .semibold))
                    if entries.count > 1 {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 10, weight: .bold))
                    }
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(.white.opacity(0.9)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.1), lineWidth: 1))
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: orchestrator.activeEffectName)
        .confirmationDialog("Active Effects", isPresented: $showEffectsMenu, titleVisibility: .visible) {
            ForEach(orchestrator.activeEffectEntries) { entry in
                Button("Stop \"\(entry.effectName)\" in \(entry.roomName)", role: .destructive) {
                    stopEffect(entry)
                }
            }
            Button("Stop All", role: .destructive) {
                stopAllEffects()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func stopEffect(_ entry: ActiveEffectEntry?) {
        guard let entry else { return }
        HapticManager.shared.medium()
        Task {
            // Studio owns the teardown (engine loops, per-light cleanup) —
            // a bare grouped-light PUT here would leave the loop running.
            await orchestrator.requestNowPlayingStop(roomID: entry.id)
        }
    }

    private func stopAllEffects() {
        HapticManager.shared.medium()
        Task {
            for entry in orchestrator.activeEffectEntries {
                await orchestrator.requestNowPlayingStop(roomID: entry.id)
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Presets Bar

    // Each preset gets a stable id — ready for future drag-to-reorder / add-remove customization
    // NOTE: LightPreset is file-level (see bottom of file) for access by TimeSuggestionBanner
    private typealias LightPreset = DashboardLightPreset

    private let presets: [LightPreset] = LightingPreset.all.map(LightPreset.init)

    private var presetsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                // ── Built-in presets ──
                ForEach(presets) { preset in
                    Button {
                        applyPreset(preset)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: preset.icon)
                                .font(.system(size: 11, weight: .semibold))
                            Text(preset.name)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                        }
                        .foregroundStyle(activePreset == preset.id ? .black : preset.color)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(
                            Capsule()
                                .fill(activePreset == preset.id
                                      ? preset.color
                                      : preset.color.opacity(0.12))
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(preset.color.opacity(activePreset == preset.id ? 0 : 0.3), lineWidth: 1)
                        )
                        .scaleEffect(activePreset == preset.id ? 0.96 : 1.0)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: activePreset)
                    }
                    .buttonStyle(.plain)
                }

                // ── Favorite scenes (pinned from RoomDetail) ──
                if !favoriteScenes.isEmpty {
                    // Thin divider between built-in presets and favorites
                    Rectangle()
                        .fill(Color.white.opacity(0.12))
                        .frame(width: 1, height: 24)
                        .padding(.horizontal, 2)

                    ForEach(favoriteScenes) { scene in
                        let isActivating = activatingFavID == scene.bridgeSceneID
                        let roomName = orchestrator.allRooms.first(where: { $0.id == scene.roomID })?.name
                            ?? orchestrator.allZones.first(where: { $0.id == scene.roomID })?.name
                            ?? ""

                        Button {
                            activateFavoriteScene(scene)
                        } label: {
                            HStack(spacing: 6) {
                                if isActivating {
                                    ProgressView()
                                        .progressViewStyle(.circular)
                                        .tint(scene.accentColor)
                                        .scaleEffect(0.6)
                                } else {
                                    Image(systemName: scene.icon)
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(scene.name)
                                        .font(.system(size: 13, weight: .semibold))
                                        .lineLimit(1)
                                    if !roomName.isEmpty {
                                        Text(roomName)
                                            .font(.system(size: 9, weight: .medium))
                                            .opacity(0.65)
                                    }
                                }
                                Image(systemName: "star.fill")
                                    .font(.system(size: 8))
                                    .opacity(0.5)
                            }
                            .foregroundStyle(scene.accentColor)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(scene.accentColor.opacity(0.12))
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(scene.accentColor.opacity(0.3), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isActivating)
                        .contextMenu {
                            Button(role: .destructive) {
                                removeFavorite(scene.bridgeSceneID)
                            } label: {
                                Label("Unfavorite", systemImage: "star.slash")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 1) // prevents clip of stroke at edge
        }
    }

    private func activateFavoriteScene(_ scene: GlobalSceneItem) {
        HapticManager.shared.medium()
        activatingFavID = scene.bridgeSceneID
        orchestrator.activateGlobalScene(scene)
        Task {
            await MainActor.run {
                presetToast = "\(scene.name) applied"
            }
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
            // M-08: the Dashboard preset ids match AutomationPreset ids
            // (energize/read/relax/sleep, same brightness+mirek) — delegate
            // to the orchestrator's paced, failure-surfacing bulk path
            // instead of a duplicate unthrottled burst.
            await orchestrator.applyAutomationPreset(id: preset.id)
            await MainActor.run {
                presetToast = "\(preset.name) applied to all rooms"
                withAnimation { activePreset = nil }
            }
            try? await Task.sleep(for: .seconds(3))
            await MainActor.run {
                if presetToast?.contains(preset.name) == true { presetToast = nil }
            }
        }
    }

    // MARK: - Summary Header
    // ──────────────────────────────────────────────

    private var timeGreeting: String {
        switch currentHour {
        case 5..<12:  return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<21: return "Good evening"
        default:      return "Good night"
        }
    }

    // ── Time-aware suggestion ─────────────────────────────────────────────────
    // Maps the current hour to a contextual prompt + the preset that best fits.
    // Only shown when all lights are off (avoids interrupting an active scene).

    private typealias TimeSuggestion = DashboardTimeSuggestion

    private var timeSuggestion: TimeSuggestion? {
        // Don't show if any lights are already on
        guard orchestrator.allRooms.allSatisfy({ !$0.isOn }) else { return nil }
        guard !orchestrator.allRooms.isEmpty else { return nil }
        let energize = presets.first(where: { $0.id == "energize" })!
        let read     = presets.first(where: { $0.id == "read" })!
        let relax    = presets.first(where: { $0.id == "relax" })!
        let sleep    = presets.first(where: { $0.id == "sleep" })!
        switch currentHour {
        case 5..<9:   return TimeSuggestion(message: "Rise and shine ☀️",     subtext: "Start your morning strong",    preset: energize)
        case 9..<12:  return TimeSuggestion(message: "Time to focus 🎯",       subtext: "Peak productivity hours",      preset: energize)
        case 12..<14: return TimeSuggestion(message: "Afternoon reading? 📖",  subtext: "Easy on the eyes",             preset: read)
        case 14..<17: return TimeSuggestion(message: "Afternoon boost ⚡",     subtext: "Keep the energy going",        preset: energize)
        case 17..<20: return TimeSuggestion(message: "Time to wind down 🌙",   subtext: "Ease into your evening",       preset: relax)
        case 20..<23: return TimeSuggestion(message: "Ready for sleep? 😴",    subtext: "Dim the lights, rest well",    preset: sleep)
        default:      return TimeSuggestion(message: "Still up late? 🌃",      subtext: "Try sleep mode",               preset: sleep)
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
        // Derive from the live @Query — the old no-predicate SwiftData fetch
        // ran on every body pass under SSE-driven churn (audit L-24).
        let automations = appAutomations.filter(\.isEnabled)
        guard !automations.isEmpty else { return nil }

        let now      = Date()
        let calendar = Calendar.current
        var earliest: (AppAutomation, Date)?

        for automation in automations {
            for dayOffset in 0..<8 {
                guard let targetDay = calendar.date(byAdding: .day, value: dayOffset, to: now) else { continue }
                let weekday = calendar.component(.weekday, from: targetDay)
                guard automation.weekdays.contains(weekday) else { continue }

                var comps        = calendar.dateComponents([.year, .month, .day], from: targetDay)
                comps.hour       = automation.hour
                comps.minute     = automation.minute
                comps.second     = 0
                guard let fireDate = calendar.date(from: comps), fireDate > now else { continue }

                if earliest == nil || fireDate < earliest!.1 {
                    earliest = (automation, fireDate)
                }
                break
            }
        }
        return earliest
    }


    // MARK: - Summary Header
    // ──────────────────────────────────────────────

    private var summaryHeader: some View {
        let onCount = orchestrator.allRooms.filter { $0.isOn }.count
        let total   = orchestrator.allRooms.count

        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(timeGreeting)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text(onCount == 0
                     ? "All lights off"
                     : "\(onCount) of \(total) on")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            Circle()
                .fill(onCount > 0 ? Color.yellow : Color.white.opacity(0.2))
                .frame(width: 9, height: 9)
                .shadow(color: onCount > 0 ? .yellow.opacity(0.9) : .clear, radius: 8)
        }
    }

    // ── Zones section header ── collapsible, persisted via @AppStorage ────────
    private var zonesSectionHeader: some View {
        Button {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
                zonesExpanded.toggle()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "square.3.layers.3d")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))

                Text("Zones")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))

                // Zone count badge
                let zCount = orchestrator.allZones.count
                Text("\(zCount)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.black.opacity(0.7))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.white.opacity(0.25)))

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .rotationEffect(.degrees(zonesExpanded ? 90 : 0))
            }
        }
        .buttonStyle(.plain)
    }

    // ── ambientBackground moved to DashboardAmbientBackground struct (see below) ─
    // Extracting to a dedicated View struct ensures SwiftUI never re-renders the
    // blur-heavy orbs when orchestrator.allRooms changes due to SSE events.

    // ──────────────────────────────────────────────
    // MARK: - Empty / Loading / Shimmer
    // ──────────────────────────────────────────────

    private var shimmerView: some View {
        VStack(spacing: 14) {
            ForEach(0..<4, id: \.self) { _ in
                ShimmerCard()
            }
        }
        .padding(.top, 16)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "lightbulb.slash.fill")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.25))
            Text("No rooms found")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.55))
            Text("Pull to refresh or pair a bridge\nin Settings.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.35))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // ──────────────────────────────────────────────
    // MARK: - Toolbar
    // ──────────────────────────────────────────────

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            if orchestrator.isLoading {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(0.85)
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    useWideCards.toggle()
                }
                HapticManager.shared.light()
            } label: {
                Image(systemName: useWideCards ? "rectangle.grid.1x2.fill" : "square.grid.2x2")
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            // All Off button—only shows when at least one room is on
            if orchestrator.allRooms.contains(where: { $0.isOn }) {
                Button {
                    turnAllOff()
                } label: {
                    if allOffWorking {
                        ProgressView().tint(.white).scaleEffect(0.8)
                    } else {
                        Image(systemName: "power")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
            }
        }
    }

    private func turnAllOff() {
        HapticManager.shared.heavy()
        allOffWorking = true
        Task {
            // M-08: delegate to the orchestrator's paced, failure-surfacing
            // All Off (per-bridge routing, gate pacing, retry, toast via
            // lastBulkFailure) instead of a duplicate unthrottled burst.
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

// ══════════════════════════════════════════════════════════
// MARK: - RoomCard
//
// Accepts a VALUE TYPE RoomDisplayItem — no @Binding.
// BrightnessRow inside has its own local @State so drags
// never touch the orchestrator's @Observable allRooms array.
// Full card = NavigationLink to detail.
// Power button = overlay, guaranteed to intercept first.
// ══════════════════════════════════════════════════════════

struct RoomCard: View {

    let room: RoomDisplayItem
    let onToggle:         (Bool)           -> Void   // Bool = desired new on-state
    let onBrightness:     (Double)         -> Void   // called ONCE on drag end
    var onEllipsisTap:    (() -> Void)?    = nil  // nil = no ··· button shown
    var onNavigate:       (() -> Void)?    = nil  // fired when card body tap triggers navigation
    var onLongPress:      (() -> Void)?    = nil  // hold the card → room color popup
    /// Family Sharing: which controls this card may offer. Unrestricted for
    /// the owner's own bridges; a grant without onOff hides the power
    /// toggle, without brightness hides the slider (card stays status-only).
    var features: GuestFeatureSet = .unrestricted

    // ── Local optimistic state ────────────────────────────────────────────────
    // localIsOn flips INSTANTLY on tap — no dependency on the @Observable chain.
    // Seeds from room.isOn on first appear; .onChange keeps it in sync when the
    // orchestrator confirms state (SSE, loadAll, API rollback).
    @State private var localIsOn: Bool

    // ── Glow color state ─────────────────────────────────────────────────────
    // localGlowColor mirrors localIsOn's pattern: it's a @State seeded from the
    // room's dominant color at init, then synced via .onChange when SSE events
    // update dominantColorX/Y or dominantMirek.
    //
    // WHY @State instead of a computed property:
    // Computed properties on non-Equatable struct views can silently miss SwiftUI
    // re-renders depending on runtime version and rendering context. Making it
    // @State means any SSE color update triggers a guaranteed first-class @State
    // mutation — which always drives a body re-render plus an animated transition.
    @State private var localGlowColor: Color

    init(room: RoomDisplayItem,
         onToggle: @escaping (Bool) -> Void,
         onBrightness: @escaping (Double) -> Void,
         onEllipsisTap: (() -> Void)? = nil,
         onNavigate: (() -> Void)? = nil,
         onLongPress: (() -> Void)? = nil,
         features: GuestFeatureSet = .unrestricted) {
        self.room             = room
        self.onToggle         = onToggle
        self.onBrightness     = onBrightness
        self.onEllipsisTap    = onEllipsisTap
        self.onNavigate       = onNavigate
        self.onLongPress      = onLongPress
        self.features         = features
        _localIsOn         = State(initialValue: room.isOn)
        _localGlowColor    = State(initialValue: Self.resolveGlowColor(for: room))
    }

    /// Resolve the room card's glow color from its dominant light state.
    /// Static so it can be called from init() before self is fully initialised.
    static func resolveGlowColor(for room: RoomDisplayItem) -> Color {
        if let x = room.dominantColorX, let y = room.dominantColorY {
            return HueColorUtils.color(fromX: x, y: y, brightness: max(room.brightness, 50))
        }
        if let mirek = room.dominantMirek {
            return HueColorUtils.color(fromMirek: mirek)
        }
        return Color(red: 1.0, green: 0.76, blue: 0.2)  // warm amber fallback
    }

    var body: some View {
        NavigationLink(value: room) {
            VStack(alignment: .leading, spacing: 0) {
                headerContent
                if localIsOn && features.canAdjust {
                    BrightnessRow(
                        brightness: room.brightness,
                        glowColor: localGlowColor,
                        onCommit: { onBrightness($0) }
                    )
                    .padding(.top, 10)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(localIsOn ? localGlowColor.opacity(0.13) : Color.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .strokeBorder(
                                localIsOn ? localGlowColor.opacity(0.55) : Color.white.opacity(0.08),
                                lineWidth: localIsOn ? 1.5 : 1
                            )
                    )
            )
            .shadow(color: localIsOn ? localGlowColor.opacity(0.25) : .clear,
                    radius: 12, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        // Fire onNavigate simultaneously with the push so the orchestrator can
        // suppress SSE rebuilds for the 450 ms animation window.
        .simultaneousGesture(TapGesture().onEnded { _ in onNavigate?() })
        // Hold the card → room color popup. Simultaneous so the NavigationLink
        // tap keeps working; a completed hold wins because the finger never
        // lifts into a tap. The power toggle sits in an overlay above this
        // gesture's hit area, so it stays a plain tap.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                guard let onLongPress else { return }
                HapticManager.shared.medium()
                onLongPress()
            }
        )
        .overlay(alignment: .topTrailing) {
            // Power toggle — hard-coded to .topTrailing. Hidden when the
            // guest grant lacks onOff (the card is status-only then).
            if features.canPower {
                Button {
                    HapticManager.shared.light()
                    localIsOn.toggle()
                    onToggle(localIsOn)
                } label: {
                    Image(systemName: localIsOn ? "power.circle.fill" : "power.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(localIsOn ? localGlowColor : .white.opacity(0.35))
                        .frame(width: HueHit.min, height: HueHit.min)
                        .contentShape(Rectangle())
                        .symbolEffect(.bounce, value: localIsOn)
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
                .padding(.trailing, 6)
                .accessibilityLabel(Text("Turn \(room.name) \(localIsOn ? "off" : "on")"))
                .accessibilityHint(Text(localIsOn ? "Tap to turn off" : "Tap to turn on"))
            }
        }
        // ··· button — bottom-trailing, only shown if callback provided
        .overlay(alignment: .bottomTrailing) {
            if onEllipsisTap != nil {
                Button {
                    HapticManager.shared.light()
                    onEllipsisTap?()
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(width: HueHit.min, height: HueHit.min)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 4)
                .padding(.trailing, 4)
            }
        }
        // Fill the LazyVGrid column width on compact devices.
        // Without an explicit maxWidth here, NavigationLink can hug its
        // intrinsic label width, causing "half-width" cards on SE portrait.
        .frame(maxWidth: .infinity, minHeight: 76)
        .opacity(localIsOn ? 1.0 : 0.72)
        .scaleEffect(localIsOn ? 1.0 : 0.982)
        .animation(.spring(response: 0.35, dampingFraction: 0.72), value: localIsOn)
        // ── Bridge-truth sync ─────────────────────────────────────────────────
        // Fires when room.isOn changes (SSE, loadAll, pull-to-refresh, API rollback).
        .onChange(of: room.isOn) { _, confirmed in
            if localIsOn != confirmed {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) {
                    localIsOn = confirmed
                }
            }
        }
        // ── Glow color sync — catches ANY room property change ───────────────
        .onChange(of: room) { _, _ in
            withAnimation(.easeInOut(duration: 0.4)) {
                localGlowColor = Self.resolveGlowColor(for: room)
            }
        }
    }

    private var headerContent: some View {
        HStack(alignment: .center, spacing: 8) {
            ZStack {
                Circle()
                    .fill(localIsOn ? localGlowColor.opacity(0.25) : Color.white.opacity(0.07))
                    .frame(width: 36, height: 36)
                Image(systemName: archetypeIcon(for: room.archetype))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(localIsOn ? localGlowColor : .white.opacity(0.4))
                    .symbolEffect(.bounce, value: localIsOn)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(room.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Text("\(room.lightCount) light\(room.lightCount == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer(minLength: 4)
            Spacer().frame(width: 32)   // reserve for power overlay
        }
    }
}

// ── RoomCard Equatable ─────────────────────────────────────────────────────
// Closures (onToggle, onBrightness, onNavigate, onEllipsisTap) are excluded
// from equality — they are stable captures and never change between body calls.
// Only the room data determines whether a re-render is needed, allowing
// .equatable() in the ForEach to skip body evaluation entirely for unchanged cards.
extension RoomCard: Equatable {
    // nonisolated: Equatable's == requirement is nonisolated; `room` is a
    // stored let of RoomDisplayItem (all-value-type, nonisolated ==), so the
    // comparison needs no main-actor state.
    nonisolated static func == (lhs: RoomCard, rhs: RoomCard) -> Bool {
        lhs.room == rhs.room && lhs.features == rhs.features
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
    // NOTE: no sensitivity or dragStart — we use absolute position now.

    init(brightness: Double, glowColor: Color,
         onCommit: @escaping (Double) -> Void) {
        self.brightness = brightness
        self.glowColor  = glowColor
        self.onCommit   = onCommit
        _localBrightness = State(initialValue: brightness)
    }

    // Always display localBrightness — never conditionally switch back to the parent
    // value mid-gesture. .onChange(of: brightness) syncs when finger is off slider.
    private var displayValue: Double { localBrightness }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sun.min.fill")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.35))

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Background track
                    Capsule()
                        .fill(Color.white.opacity(0.10))
                        .frame(height: 4)

                    // Filled portion
                    Capsule()
                        .fill(LinearGradient(
                            colors: [glowColor.opacity(0.6), glowColor],
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .frame(width: max(6, geo.size.width * CGFloat(displayValue / 100)), height: 4)

                    // Thumb
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
                Text("\(Int(displayValue))%")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 28, alignment: .trailing)
                    .contentTransition(isDragging ? .identity : .numericText())
                    .animation(isDragging ? .none : .default, value: displayValue)
            }
        }
        .padding(.top, 4)
        // Sync external value back (SSE update, toggle) only when finger is off slider
        .onChange(of: brightness) { _, new in
            if !isDragging { localBrightness = new }
        }
        // VoiceOver: treat the whole row as an adjustable element.
        // Users can swipe up/down to nudge brightness by 10% steps.
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


// MARK: - Shared value types (file-level for cross-struct access)

struct DashboardLightPreset: Identifiable {
    let id:         String
    let name:       String
    let icon:       String
    let brightness: Double
    let mirek:      Int
    let color:      Color

    /// Behavior (id/name/icon/brightness/mirek) comes from the shared catalog;
    /// only the chip tint is styling that lives at the surface.
    init(_ preset: LightingPreset) {
        id = preset.id
        name = preset.name
        icon = preset.icon
        brightness = preset.brightness
        mirek = preset.mirek
        color = preset.chipColor
    }
}

struct DashboardTimeSuggestion {
    let message:  String
    let subtext:  String
    let preset:   DashboardLightPreset
}

// MARK: - Ambient Background (isolated View — zero @Observable dependencies)

/// Renders the two blur-orb background gradient circles.
///
/// Isolated as its own View struct so SwiftUI's view-identity system treats it
/// as an OPAQUE, STABLE component. It has no @Environment(orchestrator) reads,
/// so SSE events that update allRooms do NOT cause this view to re-evaluate —
/// avoiding repeated off-screen CoreImage/blur render passes on every event.
///
/// Rule of thumb: anything with .blur() or complex gradients should live in its
/// own View with zero observed dependencies.
private struct DashboardAmbientBackground: View {
    let hour: Int   // injected so orb colors shift with time of day

    private var orb1Color: Color {
        switch hour {
        case 5..<10:  return Color(red: 1.0, green: 0.70, blue: 0.15)  // warm gold — morning
        case 10..<15: return Color(red: 0.35, green: 0.65, blue: 1.0)  // cool blue — midday
        case 15..<18: return Color(red: 1.0, green: 0.55, blue: 0.20)  // peach — late afternoon
        case 18..<22: return Color(red: 1.0, green: 0.45, blue: 0.15)  // amber — evening
        default:      return Color(red: 0.40, green: 0.20, blue: 0.95) // vivid indigo — night
        }
    }

    private var orb2Color: Color {
        switch hour {
        case 5..<10:  return Color(red: 0.85, green: 0.50, blue: 1.0)  // lavender — morning
        case 10..<15: return Color(red: 0.30, green: 0.85, blue: 0.85) // teal — midday
        case 15..<18: return Color(red: 0.55, green: 0.35, blue: 1.00) // purple — afternoon
        case 18..<22: return Color(red: 0.55, green: 0.25, blue: 0.90) // violet — evening
        default:      return Color(red: 0.20, green: 0.10, blue: 0.70) // violet — night
        }
    }

    private let orb1Offset = CGPoint(x: -60, y: -320)
    private let orb2Offset = CGPoint(x: 130, y: 80)

    var body: some View {
        ZStack {
            Color(red: 0.055, green: 0.055, blue: 0.08).ignoresSafeArea()
            Circle()
                .fill(RadialGradient(
                    colors: [orb1Color.opacity(0.32), .clear],
                    center: .center, startRadius: 0, endRadius: 200
                ))
                .frame(width: 480)
                .offset(x: orb1Offset.x, y: orb1Offset.y)
                .blur(radius: 24)
                .allowsHitTesting(false)
                .animation(.easeInOut(duration: 2.0), value: hour)
            Circle()
                .fill(RadialGradient(
                    colors: [orb2Color.opacity(0.22), .clear],
                    center: .center, startRadius: 0, endRadius: 160
                ))
                .frame(width: 280)
                .offset(x: orb2Offset.x, y: orb2Offset.y)
                .blur(radius: 20)
                .allowsHitTesting(false)
                .animation(.easeInOut(duration: 2.0), value: hour)
        }
        .ignoresSafeArea()
    }
}

// ══════════════════════════════════════════════════════════
// MARK: - TimeSuggestionBanner
// ══════════════════════════════════════════════════════════

struct TimeSuggestionBanner: View {

    let suggestion: DashboardTimeSuggestion
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            // Colored icon circle
            ZStack {
                Circle()
                    .fill(suggestion.preset.color.opacity(0.22))
                    .frame(width: 44, height: 44)
                Image(systemName: suggestion.preset.icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(suggestion.preset.color)
            }

            // Text
            VStack(alignment: .leading, spacing: 3) {
                Text(suggestion.message)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(suggestion.subtext)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.50))
                    .lineLimit(1)
            }

            Spacer()

            // One-tap CTA
            Button(action: onTap) {
                HStack(spacing: 5) {
                    Image(systemName: suggestion.preset.icon)
                        .font(.system(size: 10, weight: .bold))
                    Text(suggestion.preset.name)
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.black.opacity(0.85))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(suggestion.preset.color))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(suggestion.preset.color.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(suggestion.preset.color.opacity(0.25), lineWidth: 1)
                )
        )
        .shadow(color: suggestion.preset.color.opacity(0.15), radius: 10, x: 0, y: 4)
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
    // 10s cadence (was 1s): the relative label only visibly changes near the final
    // minute, and the ticker is paused entirely while the Home tab is off-screen.
    private let ticker = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    /// Shared formatter — the previous code allocated a new RelativeDateTimeFormatter
    /// on every tick. Accessed only on the main thread; nonisolated(unsafe) matches the
    /// codebase idiom for main-confined shared state.
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
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))

            VStack(alignment: .leading, spacing: 2) {
                Text("Next up")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.40))
                    .textCase(.uppercase)
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                    Text(name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
            }

            Spacer()

            HStack(spacing: 6) {
                Text(timeLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.white.opacity(0.08)))

                // Badge showing how many more automations are scheduled
                if moreCount > 0 {
                    Text("+\(moreCount)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color(red: 1.0, green: 0.76, blue: 0.20)))

                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.40))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onAppear { now = Date() }
        .onReceive(ticker) { newNow in
            // Paused while Home is hidden; resync on reappear/reactivation.
            guard isTabActive else { return }
            now = newNow
        }
        .onChange(of: isTabActive) { _, active in
            if active { now = Date() }
        }
    }
}

// MARK: - UpcomingAutomationsSheet
// ══════════════════════════════════════════════════════════

struct UpcomingAutomationsSheet: View {
    let automations: [(automation: AppAutomation, date: Date)]

    @Environment(\.dismiss) private var dismiss
    private let amber = Color(red: 1.0, green: 0.76, blue: 0.20)

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.055, green: 0.055, blue: 0.08).ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(Array(automations.enumerated()), id: \.offset) { idx, item in
                            HStack(spacing: 14) {
                                // Icon
                                ZStack {
                                    Circle()
                                        .fill(amber.opacity(0.15))
                                        .frame(width: 40, height: 40)
                                    Image(systemName: item.automation.action.icon)
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundStyle(amber)
                                }

                                // Name + time info
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.automation.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    HStack(spacing: 4) {
                                        Text(item.automation.timeLabel)
                                        Text("·")
                                        Text(item.automation.daysLabel)
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.40))
                                }

                                Spacer()

                                // Relative countdown
                                Text(NextAutomationBanner.relativeFormatter.localizedString(for: item.date, relativeTo: Date()))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(amber.opacity(0.85))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Capsule().fill(amber.opacity(0.12)))
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 20)

                            if idx < automations.count - 1 {
                                Divider()
                                    .background(Color.white.opacity(0.07))
                                    .padding(.horizontal, 20)
                            }
                        }
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("Upcoming Schedules")
            .navigationBarTitleDisplayMode(.inline)
            .preferredColorScheme(.dark)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(amber)
                }
            }
        }
    }
}
