// ScenesTabView.swift
// CastChroma — Stage 2B / Scenes Browser
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

    // Scene CRUD
    @State private var sceneToDelete:  GlobalSceneItem? = nil
    @State private var showDeleteAlert = false
    @State private var sceneToRename:  GlobalSceneItem? = nil
    @State private var renameText:     String           = ""
    @State private var showCreateScene = false
    @State private var showBuildScene  = false

    @AppStorage("castchroma.useWideCards") private var useWideCards = false
    // Shared favorites contract: RAW bridge scene UUIDs (bridgeSceneID),
    // the same CSV RoomDetail writes and the Dashboard pills read.
    @AppStorage("favoriteSceneIDs") private var favoriteSceneIDsRaw: String = ""
    private var provenance: SceneProvenanceStore { SceneProvenanceStore.shared }

    private func isFavorite(_ scene: GlobalSceneItem) -> Bool {
        FavoriteSceneCSV.contains(favoriteSceneIDsRaw, id: scene.bridgeSceneID)
    }

    private func toggleFavorite(_ scene: GlobalSceneItem) {
        favoriteSceneIDsRaw = FavoriteSceneCSV.toggled(favoriteSceneIDsRaw, id: scene.bridgeSceneID)
        HapticManager.shared.light()
    }

    private var gridColumns: [GridItem] {
        useWideCards
            ? [GridItem(.flexible())]
            : [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
    }

    // ── Derived data ──────────────────────────────────────

    private func roomName(for scene: GlobalSceneItem) -> String {
        orchestrator.allRooms.first(where: { $0.id == scene.roomID })?.name ?? "Other"
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
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("SCENES")
                    .font(.system(size: 14, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(StagePalette.ink)
            }
        }
        .sheet(isPresented: $showCreateScene) {
            CreateGlobalSceneView()
        }
        .sheet(isPresented: $showBuildScene) {
            SceneBuilderLauncherView()
        }
        .sheet(item: $sceneToRename) { scene in
            RenameSceneSheet(scene: scene, initialName: scene.name) { newName in
                Task { await orchestrator.renameGlobalScene(scene, to: newName) }
            }
        }
        // Delete confirmation — uses presenting: so the scene name is always available
        .alert("Delete Scene", isPresented: $showDeleteAlert, presenting: sceneToDelete) { scene in
            Button("Delete \"\(scene.name)\"", role: .destructive) {
                orchestrator.deleteGlobalScene(scene)
                // Hygiene: a deleted scene leaves no provenance badge key or
                // dangling favorite behind.
                provenance.remove(key: scene.id)
                favoriteSceneIDsRaw = FavoriteSceneCSV.removing(favoriteSceneIDsRaw,
                                                                id: scene.bridgeSceneID)
                sceneToDelete  = nil
                showDeleteAlert = false
            }
            Button("Cancel", role: .cancel) {
                sceneToDelete  = nil
                showDeleteAlert = false
            }
        } message: { scene in
            Text("\"\(scene.name)\" will be permanently removed from your bridge.")
        }
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
                            accentColor: HuePalette.amber
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
                                accentColor: HuePalette.amber
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
                    StageBadge(text: "\(filteredScenes.count) SCENE\(filteredScenes.count == 1 ? "" : "S")",
                               style: .muted)
                    if activeCount > 0 {
                        StageBadge(text: "\(activeCount) ACTIVE", style: .live)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 14)

                // Scene mood grid — with context menu for rename / delete
                LazyVGrid(columns: gridColumns, spacing: 14) {
                    ForEach(filteredScenes) { scene in
                        SceneMoodCard(
                            scene: scene,
                            roomName: roomName(for: scene),
                            isFavorite: isFavorite(scene),
                            isStudio: provenance.isStudioScene(key: scene.id)
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
                        .contextMenu {
                            Button {
                                toggleFavorite(scene)
                            } label: {
                                Label(isFavorite(scene) ? "Unfavorite" : "Favorite",
                                      systemImage: isFavorite(scene) ? "star.slash" : "star")
                            }
                            Button {
                                renameText    = scene.name
                                sceneToRename = scene
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            Divider()
                            Button(role: .destructive) {
                                sceneToDelete  = scene
                                showDeleteAlert = true
                            } label: {
                                Label("Delete Scene", systemImage: "trash")
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
            LazyVGrid(columns: gridColumns, spacing: 14) {
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
            StagePalette.stage.ignoresSafeArea()
            // One subdued amber glow — the stage language's single warm accent.
            Circle()
                .fill(RadialGradient(
                    colors: [HuePalette.amber.opacity(0.10), .clear],
                    center: .center, startRadius: 0, endRadius: 170
                ))
                .frame(width: 340)
                .offset(x: 90, y: -170)
                .blur(radius: 30)
                .allowsHitTesting(false)
        }
        .clipped()          // prevents the glow from pushing ZStack wider than screen
        .ignoresSafeArea()
    }

    // ── Toolbar ───────────────────────────────────────────

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            // Unified creation entry (R4): capture the room's current look,
            // or build per-light colors — both existing flows, one door.
            Menu {
                Button {
                    showCreateScene = true
                    HapticManager.shared.light()
                } label: {
                    Label("Capture Room Look", systemImage: "camera.viewfinder")
                }
                Button {
                    showBuildScene = true
                    HapticManager.shared.light()
                } label: {
                    Label("Build Colors…", systemImage: "paintpalette")
                }
            } label: {
                Image(systemName: "plus")
                    .foregroundStyle(.white.opacity(0.8))
            }
            .accessibilityLabel("New scene")
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { useWideCards.toggle() }
                HapticManager.shared.light()
            } label: {
                Image(systemName: useWideCards ? "rectangle.grid.1x2.fill" : "square.grid.2x2")
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
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
            .foregroundStyle(isSelected ? accentColor : StagePalette.muted)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(isSelected ? accentColor.opacity(0.16) : Color.white.opacity(0.06))
                    .overlay(
                        Capsule()
                            .stroke(
                                isSelected ? accentColor.opacity(0.55) : StagePalette.line,
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isSelected)
    }
}

// SceneMoodCard, SceneShimmerCard → SceneMoodCard.swift
// SceneSpeedSheet → SceneSpeedSheet.swift
// RenameSceneSheet → RenameSceneSheet.swift
// (extracted in the Scenes overhaul Phase 0 decomposition)
