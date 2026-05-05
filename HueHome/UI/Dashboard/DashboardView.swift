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
    @State private var showLog           = false
    @State private var showSettings      = false
    @State private var showEffectsMenu   = false   // multi-effect stop dropdown
    @State private var showScheduleSheet = false   // upcoming automations dropdown

    @Query(sort: \AppAutomation.createdAt, order: .forward)
    private var appAutomations: [AppAutomation]
    @Environment(\.modelContext)         private var modelContext
    @Environment(\.scenePhase)           private var scenePhase
    @Environment(\.horizontalSizeClass)  private var sizeClass
    /// Persist zones section open/closed state across launches.
    @AppStorage("dashboard.zonesExpanded")  private var zonesExpanded: Bool  = true
    @AppStorage("castchroma.useWideCards")  private var useWideCards: Bool   = false

    /// Switches between 1-col (full-width) and 2-col (compact) layout.
    private var gridColumns: [GridItem] {
        useWideCards
            ? [GridItem(.flexible())]
            : [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
    }

    @State private var presetToast:         String?  = nil
    @State private var activePreset:        String?  = nil
    @State private var currentHour:         Int      = Calendar.current.component(.hour, from: Date())
    @State private var allOffWorking:       Bool     = false
    @State private var activatingFavID:     String?  = nil  // tracks which fav scene pill is activating

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

    var body: some View {
        ZStack {
            DashboardAmbientBackground(hour: currentHour)

            Group {
                if orchestrator.allRooms.isEmpty {
                    if orchestrator.isLoading {
                        shimmerView
                    } else {
                        emptyState
                    }
                } else {
                    roomScrollView
                }
            }

            // ── Preset toast ───────────────────────────────────────
            if let msg = presetToast {
                VStack {
                    Spacer()
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
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: presetToast)
            }
        }
        .navigationTitle(orchestrator.isDemoMode ? "My Lights  ✦ Demo" : "My Lights")
        .navigationBarTitleDisplayMode(.large)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar { toolbarItems }
        .fullScreenCover(isPresented: $showSettings) {
            NavigationStack {
                SettingsView(onForget: { showSettings = false })
            }
        }
        .onReceive(clockTimer) { _ in
            currentHour = Calendar.current.component(.hour, from: Date())
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
        .preferredColorScheme(.dark)
    }

    // ──────────────────────────────────────────────
    // MARK: - Room Scroll
    // ──────────────────────────────────────────────

    // NOTE: No @Bindable here. RoomCard takes a plain value-type RoomDisplayItem,
    // so ForEach never needs a Binding. This is intentional — see file header.
    private var roomScrollView: some View {
        ScrollView {
            VStack(spacing: 0) {
                summaryHeader
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 10)

                // ── Time-aware suggestion banner ─────────────────────────
                if let suggestion = timeSuggestion {
                    TimeSuggestionBanner(suggestion: suggestion) {
                        applyPreset(suggestion.preset)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                // ── Next automation banner ────────────────────────────
                if let next = nextAutomation {
                    let upcomingCount = allUpcomingAutomations.count
                    NextAutomationBanner(name: next.automation.name,
                                        icon: next.automation.action.icon,
                                        fireDate: next.date,
                                        moreCount: max(0, upcomingCount - 1))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { if upcomingCount > 1 { showScheduleSheet = true } }
                    .sheet(isPresented: $showScheduleSheet) {
                        UpcomingAutomationsSheet(automations: allUpcomingAutomations)
                    }
                }

                presetsBar
                    .padding(.leading, 20)
                    .padding(.bottom, orchestrator.activeEffectName != nil ? 10 : 16)

                // ── Now Playing strip ────────────────────────────
                if orchestrator.activeEffectName != nil {
                    nowPlayingBar
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                // Room grid — 1-col (wide) or 2-col (compact) based on user preference.
                LazyVGrid(columns: gridColumns, spacing: 14) {
                    ForEach(orchestrator.allRooms, id: \.id) { room in
                        RoomCard(
                            room: room,
                            onToggle: { desiredOn in
                                orchestrator.setRoom(room, isOn: desiredOn)
                            },
                            onBrightness: { newBrightness in
                                orchestrator.setBrightness(newBrightness, for: room)
                            },
                            onNavigate: {
                                orchestrator.signalNavigationStarted()
                            }
                        )
                        .equatable()
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .bottom)),
                            removal:   .opacity
                        ))
                    }
                }
                .padding(.horizontal, 20)
                .animation(.spring(response: 0.45, dampingFraction: 0.8), value: orchestrator.allRooms.count)

                // ── Zones section ─────────────────────────────────────────────
                // Zones share RoomCard / RoomDetailView / LightCard with rooms.
                // Only rendered when the bridge reports at least one zone.
                if !orchestrator.allZones.isEmpty {
                    zonesSectionHeader
                        .padding(.horizontal, 20)
                        .padding(.top, 24)
                        .padding(.bottom, 8)

                    if zonesExpanded {
                        LazyVGrid(columns: gridColumns, spacing: 14) {
                            ForEach(orchestrator.allZones, id: \.id) { zone in
                                RoomCard(
                                    room: zone,
                                    onToggle: { desiredOn in
                                        orchestrator.setRoom(zone, isOn: desiredOn)
                                    },
                                    onBrightness: { newBrightness in
                                        orchestrator.setBrightness(newBrightness, for: zone)
                                    },
                                    onNavigate: {
                                        orchestrator.signalNavigationStarted()
                                    }
                                )
                                .equatable()
                                .transition(.asymmetric(
                                    insertion: .opacity.combined(with: .move(edge: .bottom)),
                                    removal:   .opacity
                                ))
                            }
                        }
                        .padding(.horizontal, 20)
                        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: orchestrator.allZones.count)
                    }
                }

                Color.clear.frame(height: 100)  // clear custom tab bar
            }
        }
        .overlay(alignment: .top) {
            if let msg = orchestrator.toastMessage {
                HueToastView(message: msg)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(.spring(response: 0.4, dampingFraction: 0.75), value: orchestrator.toastMessage)
                    .allowsHitTesting(false)
                    .zIndex(10)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: orchestrator.toastMessage)
        .navigationDestination(for: RoomDisplayItem.self) { room in
            RoomDetailView(room: room)
        }
        .refreshable {
            await orchestrator.loadAll(cacheContext: modelContext)
        }
        .scrollIndicators(.hidden)
    }


    // ──────────────────────────────────────────────
    // MARK: - Now Playing Bar

    private var nowPlayingBar: some View {
        let entries = orchestrator.activeEffectEntries
        let first   = entries.first

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

            if let icon = first?.effectIcon {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(first?.effectName ?? "")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let roomName = first?.roomName {
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

            Button {
                if entries.count > 1 {
                    showEffectsMenu = true
                } else {
                    stopEffect(entries.first)
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
            guard let api = orchestrator.primaryAPIClient else { return }
            // Stop the native bridge effect for this room only
            if let glID = entry.groupedLightID {
                try? await api.setGroupedLight(id: glID, on: true)
            }
            await MainActor.run {
                orchestrator.removeActiveEffect(roomID: entry.id)
            }
        }
    }

    private func stopAllEffects() {
        HapticManager.shared.medium()
        Task {
            guard let api = orchestrator.primaryAPIClient else { return }
            let entries = orchestrator.activeEffectEntries
            await withTaskGroup(of: Void.self) { group in
                for entry in entries {
                    if let glID = entry.groupedLightID {
                        group.addTask { try? await api.setGroupedLight(id: glID, on: true) }
                    }
                }
            }
            await MainActor.run {
                orchestrator.removeAllActiveEffects()
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Presets Bar

    // Each preset gets a stable id — ready for future drag-to-reorder / add-remove customization
    // NOTE: LightPreset is file-level (see bottom of file) for access by TimeSuggestionBanner
    private typealias LightPreset = DashboardLightPreset

    private let presets: [LightPreset] = [
        LightPreset(id: "energize", name: "Energize", icon: "bolt.fill",       brightness: 100, mirek: 156, color: Color(hue: 0.58, saturation: 0.7,  brightness: 1.0)),
        LightPreset(id: "read",     name: "Read",     icon: "book.fill",       brightness: 75,  mirek: 280, color: Color(hue: 0.12, saturation: 0.6,  brightness: 1.0)),
        LightPreset(id: "relax",    name: "Relax",    icon: "moon.stars.fill", brightness: 40,  mirek: 420, color: Color(hue: 0.09, saturation: 0.8,  brightness: 0.9)),
        LightPreset(id: "sleep",    name: "Sleep",    icon: "zzz",             brightness: 6,   mirek: 490, color: Color(hue: 0.07, saturation: 0.7,  brightness: 0.7)),
    ]

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
            guard let api = orchestrator.primaryAPIClient else {
                presetToast = "⚠ No bridge connection"
                return
            }
            let rooms = orchestrator.allRooms.compactMap(\.groupedLightID)
            await withTaskGroup(of: Void.self) { group in
                for id in rooms {
                    group.addTask {
                        try? await api.setGroupedLightEffect(
                            id: id, on: true,
                            brightness: preset.brightness,
                            xy: nil, mirek: preset.mirek,
                            duration: 800
                        )
                    }
                }
            }
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
        let descriptor = FetchDescriptor<AppAutomation>()
        guard let allAutomations = try? modelContext.fetch(descriptor) else { return nil }
        let automations = allAutomations.filter(\.isEnabled)
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
        LazyVStack(spacing: 14) {
            ForEach(0..<4, id: \.self) { _ in
                ShimmerCard()
                    .padding(.horizontal, 20)
            }
        }
        .padding(.top, 24)
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
        ToolbarItem(placement: .navigationBarTrailing) {
            Button { showSettings = true } label: {
                Image(systemName: "gear")
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    private func turnAllOff() {
        HapticManager.shared.heavy()
        allOffWorking = true
        Task {
            guard let api = orchestrator.primaryAPIClient else { allOffWorking = false; return }
            let rooms = orchestrator.allRooms.compactMap(\.groupedLightID)
            await withTaskGroup(of: Void.self) { group in
                for id in rooms {
                    group.addTask { try? await api.setGroupedLight(id: id, on: false) }
                }
            }
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
    let onToggle:      (Bool)   -> Void   // Bool = desired new on-state
    let onBrightness:  (Double) -> Void   // called ONCE on drag end with final value
    var onEllipsisTap: (() -> Void)? = nil  // nil = no ··· button shown
    var onNavigate:    (() -> Void)? = nil  // fired when the card body tap triggers navigation

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
         onNavigate: (() -> Void)? = nil) {
        self.room          = room
        self.onToggle      = onToggle
        self.onBrightness  = onBrightness
        self.onEllipsisTap = onEllipsisTap
        self.onNavigate    = onNavigate
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
                if localIsOn {
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
        .overlay(alignment: .topTrailing) {
            // Power toggle — hard-coded to .topTrailing
            Button {
                HapticManager.shared.light()
                localIsOn.toggle()
                onToggle(localIsOn)
            } label: {
                Image(systemName: localIsOn ? "power.circle.fill" : "power.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(localIsOn ? localGlowColor : .white.opacity(0.35))
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
                    .symbolEffect(.bounce, value: localIsOn)
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
            .padding(.trailing, 6)
            .accessibilityLabel(Text("Turn \(room.name) \(localIsOn ? "off" : "on")"))
            .accessibilityHint(Text(localIsOn ? "Tap to turn off" : "Tap to turn on"))
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
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 4)
                .padding(.trailing, 4)
            }
        }
        .frame(minHeight: 76)
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
    static func == (lhs: RoomCard, rhs: RoomCard) -> Bool {
        lhs.room == rhs.room
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
    let onCommit:   (Double) -> Void   // fires once at gesture end

    // ── Local drag state — NEVER propagated to parent during drag ─────
    @State private var localBrightness: Double
    @State private var isDragging:  Bool   = false
    @State private var lastNotch:   Int    = 0
    // NOTE: no sensitivity or dragStart — we use absolute position now.

    init(brightness: Double, glowColor: Color, onCommit: @escaping (Double) -> Void) {
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
                    // minimumDistance:1 — starts on first movement, avoids conflict
                    // with the parent scroll view, while still feeling instantaneous.
                    // Absolute position: value.location.x ÷ track width → 0–100%
                    // This means wherever the finger lands, the fill goes there.
                    DragGesture(minimumDistance: 1, coordinateSpace: .local)
                        .onChanged { value in
                            if !isDragging {
                                isDragging = true
                                lastNotch  = Int(localBrightness / 10)
                                HapticManager.shared.medium()
                            }
                            // Absolute mapping — no sensitivity, no dragStart needed
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
                    // numericText transition only runs when NOT dragging (too expensive at 60fps)
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
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var timeLabel: String {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        let rel = fmt.localizedString(for: fireDate, relativeTo: now)
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
        .onReceive(ticker) { now = $0 }
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
                                Text(RelativeDateTimeFormatter().localizedString(for: item.date, relativeTo: Date()))
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
