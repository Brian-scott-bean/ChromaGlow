    // DashboardView.swift
// HueHome Pro — Epic 2 / Story 2.1
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
    @State private var showLog         = false
    @State private var showSettings    = false
    @Environment(\.modelContext)         private var modelContext
    @Environment(\.scenePhase)           private var scenePhase
    @Environment(\.horizontalSizeClass)  private var sizeClass
    /// Persist zones section open/closed state across launches.
    @AppStorage("dashboard.zonesExpanded") private var zonesExpanded: Bool = true
    @State private var presetToast:         String?  = nil
    @State private var activePreset:        String?  = nil
    @State private var currentHour:         Int      = Calendar.current.component(.hour, from: Date())
    @State private var allOffWorking:       Bool     = false
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
        .sheet(isPresented: $showSettings) {
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
                    .padding(.bottom, 12)

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

                // Adaptive layout: 1-column on iPhone, 2-column grid on iPad.
                // LazyVGrid with a single flexible column is functionally identical to
                // LazyVStack but lets us switch columns without restructuring the ForEach.
                let columns: [GridItem] = sizeClass == .regular
                    ? [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
                    : [GridItem(.flexible())]

                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(orchestrator.allRooms, id: \.id) { room in
                        RoomCard(
                            room: room,
                            onToggle: { desiredOn in
                                // desiredOn is passed from RoomCard's localIsOn (post-flip),
                                // avoiding stale room.isOn captured from ForEach closure.
                                orchestrator.setRoom(room, isOn: desiredOn)
                            },
                            onBrightness: { newBrightness in
                                // Fires once at drag END — not during drag.
                                orchestrator.setBrightness(newBrightness, for: room)
                            }
                        )
                        .padding(.horizontal, sizeClass == .regular ? 0 : 20)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .bottom)),
                            removal:   .opacity
                        ))
                    }
                }
                .padding(.horizontal, sizeClass == .regular ? 20 : 0)
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
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(orchestrator.allZones, id: \.id) { zone in
                                RoomCard(
                                    room: zone,
                                    onToggle: { desiredOn in
                                        orchestrator.setRoom(zone, isOn: desiredOn)
                                    },
                                    onBrightness: { newBrightness in
                                        orchestrator.setBrightness(newBrightness, for: zone)
                                    }
                                )
                                .padding(.horizontal, sizeClass == .regular ? 0 : 20)
                                .transition(.asymmetric(
                                    insertion: .opacity.combined(with: .move(edge: .bottom)),
                                    removal:   .opacity
                                ))
                            }
                        }
                        .padding(.horizontal, sizeClass == .regular ? 20 : 0)
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
        HStack(spacing: 12) {
            // Pulsing indicator dot
            Circle()
                .fill(orchestrator.activeEffectIsAppDriven ? Color.cyan : Color.green)
                .frame(width: 8, height: 8)
                .overlay(
                    Circle()
                        .fill(orchestrator.activeEffectIsAppDriven ? Color.cyan.opacity(0.35) : Color.green.opacity(0.35))
                        .frame(width: 16)
                )

            if let icon = orchestrator.activeEffectIcon {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
            }

            Text(orchestrator.activeEffectName ?? "")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)

            if orchestrator.activeEffectIsAppDriven {
                Text("— keep app open")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer()

            Button {
                stopActiveEffect()
            } label: {
                Text("Stop")
                    .font(.system(size: 13, weight: .semibold))
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
    }

    private func stopActiveEffect() {
        HapticManager.shared.medium()
        Task {
            guard let api = orchestrator.primaryAPIClient else { return }
            // Clear bridge-native effects from all lights in all rooms
            let allLightIDs = orchestrator.allRooms.compactMap(\.groupedLightID)
            await withTaskGroup(of: Void.self) { group in
                for id in allLightIDs {
                    group.addTask {
                        try? await api.setGroupedLight(id: id, on: true) // keeps lights on but stops effect
                    }
                }
            }
            await MainActor.run {
                orchestrator.activeEffectName       = nil
                orchestrator.activeEffectIcon       = nil
                orchestrator.activeEffectIsAppDriven = false
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Presets Bar

    // Each preset gets a stable id — ready for future drag-to-reorder / add-remove customization
    private struct LightPreset: Identifiable {
        let id:         String
        let name:       String
        let icon:       String
        let brightness: Double
        let mirek:      Int
        let color:      Color
    }

    private let presets: [LightPreset] = [
        LightPreset(id: "energize", name: "Energize", icon: "bolt.fill",       brightness: 100, mirek: 156, color: Color(hue: 0.58, saturation: 0.7,  brightness: 1.0)),
        LightPreset(id: "read",     name: "Read",     icon: "book.fill",       brightness: 75,  mirek: 280, color: Color(hue: 0.12, saturation: 0.6,  brightness: 1.0)),
        LightPreset(id: "relax",    name: "Relax",    icon: "moon.stars.fill", brightness: 40,  mirek: 420, color: Color(hue: 0.09, saturation: 0.8,  brightness: 0.9)),
        LightPreset(id: "sleep",    name: "Sleep",    icon: "zzz",             brightness: 6,   mirek: 490, color: Color(hue: 0.07, saturation: 0.7,  brightness: 0.7)),
    ]

    private var presetsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
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
            }
            .padding(.horizontal, 1) // prevents clip of stroke at edge
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
            // All Off button — only shows when at least one room is on
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
    let onToggle:     (Bool) -> Void   // Bool = desired new on-state
    let onBrightness: (Double) -> Void   // called ONCE on drag end with final value

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
         onBrightness: @escaping (Double) -> Void) {
        self.room         = room
        self.onToggle     = onToggle
        self.onBrightness = onBrightness
        _localIsOn       = State(initialValue: room.isOn)
        _localGlowColor  = State(initialValue: Self.resolveGlowColor(for: room))
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
            .padding(16)
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
        .overlay(alignment: .topTrailing) {
            Button {
                HapticManager.shared.light()
                localIsOn.toggle()
                onToggle(localIsOn)
            } label: {
                Image(systemName: localIsOn ? "power.circle.fill" : "power.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(localIsOn ? localGlowColor : .white.opacity(0.35))
                    .frame(width: 48, height: 48)
                    .contentShape(Rectangle())
                    .symbolEffect(.bounce, value: localIsOn)
            }
            .buttonStyle(.plain)
            .padding(.top, 10)
            .padding(.trailing, 8)
            .accessibilityLabel(Text("Turn \(room.name) \(localIsOn ? "off" : "on")"))
            .accessibilityHint(Text(localIsOn ? "Tap to turn off" : "Tap to turn on"))
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
        // ── Glow color sync (same pattern as isOn above) ─────────────────────
        // Watch both CIE components: a scene can shift Y without changing X.
        // dominantMirek fires for warm/cool-only rooms (no colour capable lights).
        .onChange(of: room.dominantColorX) { _, _ in
            withAnimation(.easeInOut(duration: 0.4)) {
                localGlowColor = Self.resolveGlowColor(for: room)
            }
        }
        .onChange(of: room.dominantColorY) { _, _ in
            withAnimation(.easeInOut(duration: 0.4)) {
                localGlowColor = Self.resolveGlowColor(for: room)
            }
        }
        .onChange(of: room.dominantMirek) { _, _ in
            withAnimation(.easeInOut(duration: 0.4)) {
                localGlowColor = Self.resolveGlowColor(for: room)
            }
        }
    }

    private var headerContent: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(localIsOn ? localGlowColor.opacity(0.25) : Color.white.opacity(0.07))
                    .frame(width: 44, height: 44)
                Image(systemName: archetypeIcon(for: room.archetype))
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(localIsOn ? localGlowColor : .white.opacity(0.4))
                    .symbolEffect(.bounce, value: localIsOn)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(room.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(room.lightCount) light\(room.lightCount == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            Spacer().frame(width: 40)   // reserve for power overlay
        }
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
    @State private var dragStart:   Double = 0
    @State private var lastNotch:   Int    = 0
    private let sensitivity: CGFloat = 2.0

    init(brightness: Double, glowColor: Color, onCommit: @escaping (Double) -> Void) {
        self.brightness = brightness
        self.glowColor  = glowColor
        self.onCommit   = onCommit
        // Seed local state — only used while dragging; see displayValue below.
        _localBrightness = State(initialValue: brightness)
    }

    // Always display localBrightness — never conditionally switch back to the parent
    // value mid-gesture. The snap-back bug was caused by setting isDragging=false
    // in onEnded (switching display to parent's stale value) before the parent
    // re-rendered with the committed value. onChange(of: brightness) syncs
    // localBrightness from SSE/parent updates when finger is off the slider.
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
                    DragGesture(minimumDistance: 4, coordinateSpace: .local)
                        .onChanged { value in
                            if !isDragging {
                                isDragging  = true
                                dragStart   = localBrightness  // use live local value, not stale parent prop
                                lastNotch   = Int(localBrightness / 10)
                                HapticManager.shared.medium()
                            }
                            let delta  = Double(value.translation.width / sensitivity)
                            let newVal = min(100, max(1, dragStart + delta))
                            localBrightness = newVal   // ← pure @State, no Observable cascade

                            let notch = Int(newVal / 10)
                            if notch != lastNotch {
                                HapticManager.shared.soft()
                                lastNotch = notch
                            }
                        }
                        .onEnded { _ in
                            isDragging = false
                            HapticManager.shared.heavy()
                            onCommit(localBrightness)   // ← ONE write to orchestrator after release
                        }
                )
            }
            .frame(height: 16)

            HStack(spacing: 4) {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.35))
                Text("\(Int(displayValue))%")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 30, alignment: .trailing)
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
