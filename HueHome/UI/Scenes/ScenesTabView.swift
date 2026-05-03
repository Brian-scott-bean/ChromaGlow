// ScenesTabView.swift
// HueHome Pro — Stage 2B / Scenes Browser
//
// Full cross-bridge scene browser:
//   • Fetches all scenes from all active bridges in parallel
//   • Room filter chips — tap to narrow by room
//   • Full-text search by scene name or room name
//   • 2-column glassmorphic mood card grid
//   • Active scene indicator + optimistic activate on tap
//   • Shimmer skeleton while loading
//   • Demo mode aware (uses DemoDataProvider.globalScenes)

import SwiftUI

// ══════════════════════════════════════════════════════════
// MARK: - ScenesTabView
// ══════════════════════════════════════════════════════════

struct ScenesTabView: View {

    @Environment(UnifiedOrchestrator.self) private var orchestrator
    @State private var searchText:     String            = ""
    @State private var selectedRoomID: String?           = nil
    @State private var speedSheetScene: GlobalSceneItem? = nil   // non-nil = sheet open

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
    ]

    // ── Derived data ──────────────────────────────────────

    private func roomName(for scene: GlobalSceneItem) -> String {
        orchestrator.allRooms.first(where: { $0.id == scene.roomID })?.name ?? "Unknown"
    }

    private func roomArchetype(for roomID: String) -> String? {
        orchestrator.allRooms.first(where: { $0.id == roomID })?.archetype
    }

    /// Rooms that actually have scenes, sorted alphabetically.
    private var uniqueRooms: [(id: String, name: String)] {
        var seen = Set<String>()
        return orchestrator.globalScenes.compactMap { scene in
            guard !seen.contains(scene.roomID) else { return nil }
            seen.insert(scene.roomID)
            return (id: scene.roomID, name: roomName(for: scene))
        }.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    private var filteredScenes: [GlobalSceneItem] {
        orchestrator.globalScenes.filter { scene in
            let matchesSearch = searchText.isEmpty
                || scene.name.localizedCaseInsensitiveContains(searchText)
                || roomName(for: scene).localizedCaseInsensitiveContains(searchText)
            let matchesRoom   = selectedRoomID == nil || scene.roomID == selectedRoomID
            return matchesSearch && matchesRoom
        }
    }

    private var activeCount: Int {
        filteredScenes.filter { $0.isActive }.count
    }

    // ── Body ──────────────────────────────────────────────

    var body: some View {
        ZStack {
            ambientBackground

            Group {
                if orchestrator.isLoadingScenes && orchestrator.globalScenes.isEmpty {
                    loadingGrid
                } else if orchestrator.globalScenes.isEmpty {
                    emptyState
                } else {
                    contentView
                }
            }
        }
        .navigationTitle("Scenes")
        .navigationBarTitleDisplayMode(.large)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar { toolbarItems }
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search scenes or rooms")
        .preferredColorScheme(.dark)
        .sheet(item: $speedSheetScene) { scene in
            SceneSpeedSheet(
                scene:      scene,
                onSpeedChange: { orchestrator.setSceneSpeed(scene, speed: $0) },
                onActivate: {
                    speedSheetScene = nil
                    HapticManager.shared.medium()
                    orchestrator.activateGlobalScene(scene)
                }
            )
        }
        .task {
            if orchestrator.globalScenes.isEmpty {
                await orchestrator.loadAllScenes()
            }
        }
    }

    // ── Content ───────────────────────────────────────────

    private var contentView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // Room filter chips
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        SceneFilterChip(
                            title: "All",
                            icon: "sparkles",
                            isSelected: selectedRoomID == nil,
                            accentColor: Color(red: 0.6, green: 0.4, blue: 0.9)
                        ) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                selectedRoomID = nil
                            }
                        }
                        ForEach(uniqueRooms, id: \.id) { room in
                            SceneFilterChip(
                                title: room.name,
                                icon: archetypeIcon(for: roomArchetype(for: room.id)),
                                isSelected: selectedRoomID == room.id,
                                accentColor: Color(red: 1.0, green: 0.76, blue: 0.2)
                            ) {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    selectedRoomID = (selectedRoomID == room.id) ? nil : room.id
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.top, 12)
                .padding(.bottom, 10)

                // Scene count + active badge
                HStack(spacing: 8) {
                    Text("\(filteredScenes.count) scene\(filteredScenes.count == 1 ? "" : "s")")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.40))

                    if activeCount > 0 {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.yellow)
                                .frame(width: 6, height: 6)
                                .shadow(color: .yellow.opacity(0.9), radius: 4)
                            Text("\(activeCount) active")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.yellow)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 14)

                // Scene mood grid
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(filteredScenes) { scene in
                        SceneMoodCard(
                            scene: scene,
                            roomName: roomName(for: scene)
                        ) {
                            // Tap: activate immediately
                            HapticManager.shared.medium()
                            orchestrator.activateGlobalScene(scene)
                        } onLongPress: {
                            // Long-press: open speed sheet (dynamic) or activate with haptic
                            HapticManager.shared.heavy()
                            if scene.isDynamic {
                                speedSheetScene = scene
                            } else {
                                orchestrator.activateGlobalScene(scene)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 108)   // clear custom tab bar
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: filteredScenes.map { $0.id })
            }
        }
        .scrollIndicators(.hidden)
        .refreshable {
            await orchestrator.loadAllScenes()
        }
    }

    // ── Loading ───────────────────────────────────────────

    private var loadingGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(0..<8, id: \.self) { _ in
                    SceneShimmerCard()
                }
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
    }

    // ── Empty ─────────────────────────────────────────────

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(.white.opacity(0.22))
                .symbolEffect(.pulse)

            Text("No Scenes Found")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))

            Text("Connect to a bridge with scenes\nconfigured to see them here.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.35))
                .multilineTextAlignment(.center)

            Button {
                Task { await orchestrator.loadAllScenes() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(
                        Capsule().fill(Color.white.opacity(0.08))
                            .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
                    )
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // ── Background ────────────────────────────────────────

    private var ambientBackground: some View {
        ZStack {
            Color(red: 0.055, green: 0.055, blue: 0.08).ignoresSafeArea()
            // Purple orb — reinforces scene/mood vibe
            Circle()
                .fill(RadialGradient(
                    colors: [Color(red: 0.5, green: 0.2, blue: 0.95).opacity(0.25), .clear],
                    center: .center, startRadius: 0, endRadius: 200
                ))
                .frame(width: 380)
                .offset(x: 80, y: -160)
                .blur(radius: 28)
                .allowsHitTesting(false)
            // Warm accent orb
            Circle()
                .fill(RadialGradient(
                    colors: [Color(red: 1, green: 0.5, blue: 0.2).opacity(0.16), .clear],
                    center: .center, startRadius: 0, endRadius: 160
                ))
                .frame(width: 280)
                .offset(x: -100, y: 120)
                .blur(radius: 22)
                .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }

    // ── Toolbar ───────────────────────────────────────────

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                Task { await orchestrator.loadAllScenes() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(.white.opacity(orchestrator.isLoadingScenes ? 0.4 : 0.8))
                    .rotationEffect(.degrees(orchestrator.isLoadingScenes ? 360 : 0))
                    .animation(
                        orchestrator.isLoadingScenes
                            ? .linear(duration: 1).repeatForever(autoreverses: false)
                            : .default,
                        value: orchestrator.isLoadingScenes
                    )
            }
            .disabled(orchestrator.isLoadingScenes)
        }
    }
}

// ══════════════════════════════════════════════════════════
// MARK: - SceneMoodCard
// ══════════════════════════════════════════════════════════

struct SceneMoodCard: View {

    let scene:       GlobalSceneItem
    let roomName:    String
    let onActivate:  () -> Void
    let onLongPress: () -> Void

    var body: some View {
        Button(action: onActivate) {
            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(.ultraThinMaterial)
                    .overlay(scene.accentColor.opacity(0.12))

                if scene.isActive {
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(scene.accentColor.opacity(0.6), lineWidth: 2)
                } else {
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                }

                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 4) {
                        Text(roomName)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.white.opacity(0.1)))

                        Spacer()

                        if scene.isDynamic {
                            Button(action: onLongPress) {
                                HStack(spacing: 3) {
                                    Image(systemName: "bolt.fill")
                                        .font(.system(size: 7, weight: .bold))
                                    Text("SPEED")
                                        .font(.system(size: 7, weight: .bold))
                                }
                                .foregroundStyle(.black.opacity(0.85))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(scene.accentColor))
                            }
                            .buttonStyle(.plain)
                        }

                        if scene.isActive {
                            Circle()
                                .fill(scene.accentColor)
                                .frame(width: 8, height: 8)
                                .shadow(color: scene.accentColor, radius: 6)
                                .symbolEffect(.pulse)
                        }
                    }

                    Spacer()

                    Image(systemName: scene.icon)
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(scene.accentColor)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 10)

                    Text(scene.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
            }
            .aspectRatio(0.88, contentMode: .fit)
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(SceneCardPressStyle())
        .animation(.spring(response: 0.35, dampingFraction: 0.72), value: scene.isActive)
    }
}

/// ButtonStyle that applies a 4% scale-down on press.
/// Using ButtonStyle (rather than DragGesture) lets SwiftUI properly
/// coordinate with parent ScrollViews so scrolling is never blocked.
private struct SceneCardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.65),
                       value: configuration.isPressed)
    }
}


// ══════════════════════════════════════════════════════════
// MARK: - SceneFilterChip
// ══════════════════════════════════════════════════════════

struct SceneFilterChip: View {

    let title:       String
    let icon:        String
    let isSelected:  Bool
    let accentColor: Color
    let action:      () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? accentColor : .white.opacity(0.6))
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(isSelected ? accentColor.opacity(0.18) : Color.white.opacity(0.07))
                    .overlay(
                        Capsule()
                            .stroke(
                                isSelected ? accentColor.opacity(0.55) : Color.white.opacity(0.12),
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isSelected)
    }
}

// ══════════════════════════════════════════════════════════
// MARK: - SceneShimmerCard
// ══════════════════════════════════════════════════════════

struct SceneShimmerCard: View {

    @State private var shimmerPhase: CGFloat = -1

    var body: some View {
        RoundedRectangle(cornerRadius: 20)
            .fill(Color.white.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .fill(
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.07), .clear],
                            startPoint: .init(x: shimmerPhase, y: 0),
                            endPoint:   .init(x: shimmerPhase + 0.5, y: 1)
                        )
                    )
            )
            .aspectRatio(0.88, contentMode: .fit)
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    shimmerPhase = 1.5
                }
            }
    }
}

// ══════════════════════════════════════════════════════════
// MARK: - SceneSpeedSheet
//
// Bottom sheet for setting dynamic scene speed.
// Shown on long-press of any scene card where isDynamic == true.
// ══════════════════════════════════════════════════════════

struct SceneSpeedSheet: View {

    let scene:         GlobalSceneItem
    let onSpeedChange: (Double) -> Void
    let onActivate:    () -> Void

    @State private var localSpeed: Double

    init(scene: GlobalSceneItem,
         onSpeedChange: @escaping (Double) -> Void,
         onActivate: @escaping () -> Void) {
        self.scene         = scene
        self.onSpeedChange = onSpeedChange
        self.onActivate    = onActivate
        _localSpeed        = State(initialValue: scene.speed)
    }

    private var speedLabel: String {
        let pct = Int(localSpeed * 100)
        switch pct {
        case 0..<20:  return "Very Slow"
        case 20..<40: return "Slow"
        case 40..<60: return "Medium"
        case 60..<80: return "Fast"
        default:      return "Very Fast"
        }
    }

    var body: some View {
        ZStack {
            Color(red: 0.06, green: 0.06, blue: 0.10).ignoresSafeArea()

            // Faint accent orb behind content
            Circle()
                .fill(RadialGradient(
                    colors: [scene.accentColor.opacity(0.22), .clear],
                    center: .center, startRadius: 0, endRadius: 180
                ))
                .frame(width: 360)
                .offset(y: -60)
                .blur(radius: 30)
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                // Drag handle
                Capsule()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 36, height: 4)
                    .padding(.top, 12)
                    .padding(.bottom, 24)

                // Scene icon + name
                Image(systemName: scene.icon)
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(scene.accentColor)
                    .symbolEffect(.pulse)

                Text(scene.name)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.top, 10)

                Text("Dynamic Scene · \(speedLabel)")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.top, 4)
                    .animation(.easeInOut(duration: 0.2), value: speedLabel)

                // ── Speed slider ──────────────────────────────
                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        Image(systemName: "tortoise.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.white.opacity(0.45))

                        Slider(value: $localSpeed, in: 0...1, step: 0.01)
                            .tint(scene.accentColor)
                            .onChange(of: localSpeed) { _, newVal in
                                onSpeedChange(newVal)
                            }

                        Image(systemName: "hare.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.white.opacity(0.45))
                    }

                    Text("\(Int(localSpeed * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(scene.accentColor)
                        .animation(.none, value: localSpeed)
                }
                .padding(.horizontal, 28)
                .padding(.top, 32)

                Spacer()

                // ── Activate button ───────────────────────────
                Button(action: onActivate) {
                    Label("Activate Scene", systemImage: "play.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.black.opacity(0.85))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(scene.accentColor)
                        )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
                .padding(.bottom, 36)
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
        .presentationBackground(.clear)
        .preferredColorScheme(.dark)
    }
}
