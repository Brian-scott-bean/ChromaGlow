// ScenesTabView.swift
// CastChroma — Stage 2B / Scenes Browser (reorganized in the 2026-07 overhaul)
//
// Full cross-bridge scene browser:
//   • Fetches all scenes from all active bridges in parallel
//   • Grouped-by-room collapsible sections (default) with a pinned
//     ★ Favorites shelf, or flat sort modes (A–Z; Recent/Most Used follow
//     with SceneUsageStore) with room filter chips
//   • Full-text search by scene name or room name — flattens to one grid
//   • Active scene indicator + optimistic activate on tap
//   • Shimmer skeleton while loading
//   • Demo mode aware (uses DemoDataProvider.globalScenes)

import SwiftUI

// ══════════════════════════════════════════════════════════
// MARK: - ScenesTabView
// ══════════════════════════════════════════════════════════

struct ScenesTabView: View {

    @Environment(UnifiedOrchestrator.self) private var orchestrator
    @Environment(\.isTabActive) private var isTabActive
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

    // Scene copy/move (CopySceneSheet + undo toast)
    private struct CopySheetContext: Identifiable {
        let id = UUID()
        let scene: GlobalSceneItem
        let mode: CopySceneSheet.Mode
        var preselectedTargetID: String? = nil
    }
    @State private var copySheetContext: CopySheetContext? = nil
    @State private var copyUndo: SceneCopyUndo? = nil
    @State private var copyUndoDismissTask: Task<Void, Never>? = nil

    // ── Studio scenes shelf (scene-like Composer creations) ──
    /// Read-only snapshot of the compositions file, filtered to presets whose
    /// layers make them scenes (static look, no reaction). Studio owns the only
    /// live CompositionStore; this tab re-reads the file per appearance instead
    /// of holding a second mutable store next to it.
    @State private var studioScenePresets: [CompositionPreset] = []
    /// Preset awaiting a room choice (sheet item).
    @State private var studioSceneToAdd: CompositionPreset? = nil
    @State private var studioAddBusy = false
    @AppStorage("castchroma.studioShelfCollapsed") private var studioShelfCollapsed = false
    /// Room section / filter chip a scene drag is hovering (highlight).
    @State private var dropTargetRoomID: String? = nil

    /// Persisted sort/group mode (SceneGrouping.SortMode raw value).
    @AppStorage("castchroma.sceneSortMode") private var sortModeRaw =
        SceneGrouping.SortMode.byRoom.rawValue
    /// Collapsed room-section ids — same CSV helper family as favorites.
    @AppStorage("castchroma.collapsedSceneRoomIDs") private var collapsedRoomIDsRaw = ""
    /// Card density: false = 2-up grid, true = full-width bars. Separate key
    /// from the Dashboard's castchroma.useWideCards so the screens stay
    /// independently configurable.
    @AppStorage("castchroma.sceneWideCards") private var sceneWideCards = false
    // Shared favorites contract: RAW bridge scene UUIDs (bridgeSceneID),
    // the same CSV RoomDetail writes and the Dashboard pills read.
    @AppStorage("favoriteSceneIDs") private var favoriteSceneIDsRaw: String = ""
    private var provenance: SceneProvenanceStore { SceneProvenanceStore.shared }

    private var sortMode: SceneGrouping.SortMode {
        SceneGrouping.SortMode(rawValue: sortModeRaw) ?? .byRoom
    }

    private let availableSortModes = SceneGrouping.SortMode.allCases

    private func isFavorite(_ scene: GlobalSceneItem) -> Bool {
        FavoriteSceneCSV.contains(favoriteSceneIDsRaw, id: scene.bridgeSceneID)
    }

    private func toggleFavorite(_ scene: GlobalSceneItem) {
        favoriteSceneIDsRaw = FavoriteSceneCSV.toggled(favoriteSceneIDsRaw, id: scene.bridgeSceneID)
        HapticManager.shared.light()
    }

    private var gridColumns: [GridItem] {
        // SceneMoodCard is already a full-width bar internally (maxWidth
        // .infinity) — one column IS the full-bar layout. Every grid on the
        // page (grouped sections, favorites shelf, flat/search, skeleton)
        // routes through this property.
        if sceneWideCards {
            return [GridItem(.flexible(), spacing: 14)]
        }
        return [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
    }

    // ── Derived data ──────────────────────────────────────

    /// Name/archetype lookup across rooms AND zones — zone scenes previously
    /// resolved as "Other" because only allRooms was searched.
    private var roomIndex: [String: SceneGrouping.RoomInfo] {
        SceneGrouping.roomIndex(groups: orchestrator.allRooms + orchestrator.allZones)
    }

    private func roomName(for scene: GlobalSceneItem) -> String {
        SceneGrouping.roomName(for: scene, index: roomIndex)
    }

    /// Rooms that actually have scenes, sorted alphabetically (chip row).
    private var uniqueRooms: [(id: String, name: String)] {
        var seen = Set<String>()
        return orchestrator.globalScenes.compactMap { scene in
            guard !seen.contains(scene.roomID) else { return nil }
            seen.insert(scene.roomID)
            return (id: scene.roomID, name: roomName(for: scene))
        }.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    private var isSearching: Bool { !searchText.isEmpty }

    private var filteredScenes: [GlobalSceneItem] {
        orchestrator.globalScenes.filter { scene in
            let matchesSearch = searchText.isEmpty
                || scene.name.localizedCaseInsensitiveContains(searchText)
                || roomName(for: scene).localizedCaseInsensitiveContains(searchText)
            let matchesRoom   = selectedRoomID == nil || scene.roomID == selectedRoomID
            return matchesSearch && matchesRoom
        }
    }

    /// Scenes the current mode actually displays (drives the count badges).
    private var displayedScenes: [GlobalSceneItem] {
        (sortMode.isGrouped && !isSearching) ? orchestrator.globalScenes : filteredScenes
    }

    private var activeCount: Int {
        displayedScenes.filter { $0.isActive }.count
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
        .sheet(item: $studioSceneToAdd) { preset in
            studioSceneRoomPicker(preset: preset)
        }
        // Fresh read-only snapshot each visit — Studio may have saved new
        // creations since the last one.
        .task { refreshStudioScenePresets() }
        .onChange(of: isTabActive) { _, active in
            if active { refreshStudioScenePresets() }
        }
        .sheet(item: $copySheetContext) { ctx in
            CopySceneSheet(
                scene: ctx.scene,
                mode: ctx.mode,
                preselectedTargetID: ctx.preselectedTargetID
            ) { undo in
                if undo.mode == .move {
                    // The move minted a new bridge scene id — carry the ★ and
                    // the usage history across, or the scene silently loses
                    // both (favorites/usage key on RAW bridgeSceneID).
                    favoriteSceneIDsRaw = FavoriteSceneCSV.replacing(
                        favoriteSceneIDsRaw,
                        old: undo.sourceScene.bridgeSceneID,
                        new: undo.newSceneID
                    )
                    SceneUsageStore.shared.transfer(
                        from: undo.sourceScene.bridgeSceneID,
                        to: undo.newSceneID
                    )
                }
                showCopyUndo(undo)
            }
        }
        .overlay(alignment: .top) {
            if let undo = copyUndo {
                HueActionToast(
                    message: "\(undo.mode == .move ? "Moved" : "Copied") to \(undo.targetRoomName)",
                    actionTitle: "Undo"
                ) {
                    performCopyUndo(undo)
                }
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(10)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: copyUndo == nil)
        .sheet(item: $sceneToRename) { scene in
            RenameSceneSheet(scene: scene, initialName: scene.name) { newName in
                Task { await orchestrator.renameGlobalScene(scene, to: newName) }
            }
        }
        // Delete confirmation — uses presenting: so the scene name is always available
        .alert("Delete Scene", isPresented: $showDeleteAlert, presenting: sceneToDelete) { scene in
            Button("Delete \"\(scene.name)\"", role: .destructive) {
                orchestrator.deleteGlobalScene(scene)
                // Hygiene: a deleted scene leaves no provenance badge key,
                // dangling favorite, or usage history behind.
                provenance.remove(key: scene.id)
                favoriteSceneIDsRaw = FavoriteSceneCSV.removing(favoriteSceneIDsRaw,
                                                                id: scene.bridgeSceneID)
                SceneUsageStore.shared.remove(bridgeSceneID: scene.bridgeSceneID)
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

                // Room filter chips — flat modes only (sections replace them
                // in grouped mode, and later double as drag-drop targets).
                if !sortMode.isGrouped {
                    chipRow
                }

                // Scene count + active badge
                HStack(spacing: 8) {
                    StageBadge(text: "\(displayedScenes.count) SCENE\(displayedScenes.count == 1 ? "" : "S")",
                               style: .muted)
                    if activeCount > 0 {
                        StageBadge(text: "\(activeCount) ACTIVE", style: .live)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, sortMode.isGrouped ? 12 : 0)
                .padding(.bottom, 8)

                // Studio scenes — Composer creations whose layers make them
                // scenes. Tapping one creates a REAL bridge scene in a room
                // you pick, so it joins that room's list right here.
                if !studioScenePresets.isEmpty {
                    studioScenesShelf
                        .padding(.bottom, 8)
                }

                if sortMode.isGrouped && !isSearching {
                    groupedContent
                } else {
                    flatGrid
                }
            }
        }
        .scrollIndicators(.hidden)
        .refreshable {
            await orchestrator.loadAllScenes()
        }
    }

    // ── Studio scenes shelf ───────────────────────────────

    /// Fresh read-only snapshot of scene-like Composer creations. Off-main
    /// read, filtered by the same classifier the Studio decks use; the hidden
    /// starter draft never shows.
    private func refreshStudioScenePresets() {
        Task.detached(priority: .userInitiated) {
            let presets = CompositionStore.readPresets(from: CompositionStore.defaultFileURL).presets
                .filter {
                    $0.id != StudioViewModel.composerStarterDraftPresetID
                        && PresetSurfaceClassifier.surface(for: $0) == .scene
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            await MainActor.run { studioScenePresets = presets }
        }
    }

    private var studioScenesShelf: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(HueAnimation.fast) { studioShelfCollapsed.toggle() }
                HapticManager.shared.selection()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(HuePalette.amber.opacity(0.8))
                    Text("STUDIO SCENES")
                        .font(HueFont.stageTag)
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.55))
                    Text("\(studioScenePresets.count)")
                        .font(HueFont.stageTag)
                        .foregroundStyle(.white.opacity(0.30))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.4))
                        .rotationEffect(.degrees(studioShelfCollapsed ? -90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .accessibilityLabel("Studio scenes, \(studioScenePresets.count), \(studioShelfCollapsed ? "collapsed" : "expanded")")

            if !studioShelfCollapsed {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(studioScenePresets) { preset in
                            Button {
                                studioSceneToAdd = preset
                                HapticManager.shared.light()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: preset.icon)
                                        .font(.system(size: 11, weight: .semibold))
                                    Text(preset.name)
                                        .font(.system(size: 13, weight: .semibold))
                                        .lineLimit(1)
                                    Image(systemName: "plus.circle.fill")
                                        .font(.system(size: 11))
                                        .opacity(0.6)
                                }
                                .foregroundStyle(Color(hex: preset.accentColorHex))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(Color(hex: preset.accentColorHex).opacity(0.13)))
                                .overlay(Capsule().strokeBorder(Color(hex: preset.accentColorHex).opacity(0.3), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Add \(preset.name) to a room as a scene")
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
    }

    /// Pick the room the Studio scene lands in — it becomes a real bridge
    /// scene there, provenance-badged STUDIO like the Composer's own export.
    private func studioSceneRoomPicker(preset: CompositionPreset) -> some View {
        NavigationStack {
            List {
                Section {
                    ForEach(orchestrator.allRooms + orchestrator.allZones) { room in
                        Button {
                            guard !studioAddBusy else { return }
                            studioAddBusy = true
                            Task {
                                let sceneID = await orchestrator.addStudioSceneToRoom(preset: preset, room: room)
                                studioAddBusy = false
                                studioSceneToAdd = nil
                                if sceneID != nil { HapticManager.shared.medium() }
                            }
                        } label: {
                            HStack {
                                Text(room.name).foregroundStyle(.white)
                                if room.kind == .zone {
                                    Text("Zone")
                                        .font(.caption2)
                                        .foregroundStyle(.white.opacity(0.4))
                                }
                                Spacer()
                                if studioAddBusy { ProgressView() }
                            }
                        }
                        .disabled(studioAddBusy)
                    }
                } header: {
                    Text("Add \"\(preset.name)\" to…")
                } footer: {
                    Text("Creates a real Hue scene in that room — it runs from the bridge like any other scene.")
                }
            }
            .navigationTitle(preset.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { studioSceneToAdd = nil }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }

    private var chipRow: some View {
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
                        icon: archetypeIcon(for: roomIndex[room.id]?.archetype),
                        isSelected: selectedRoomID == room.id || dropTargetRoomID == room.id,
                        accentColor: HuePalette.amber
                    ) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            selectedRoomID = (selectedRoomID == room.id) ? nil : room.id
                        }
                    }
                    // Flat modes: the chips double as scene-drop targets.
                    .dropDestination(for: SceneDragPayload.self) { items, _ in
                        handleSceneDrop(items, targetRoomID: room.id)
                    } isTargeted: { targeting in
                        if targeting {
                            dropTargetRoomID = room.id
                        } else if dropTargetRoomID == room.id {
                            dropTargetRoomID = nil
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    // ── Grouped mode: Favorites shelf + room sections ─────

    private var groupedContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            let favorites = SceneGrouping.favorites(
                scenes: orchestrator.globalScenes,
                favoriteIDsCSV: favoriteSceneIDsRaw
            )
            if !favorites.isEmpty {
                favoritesShelf(favorites)
            }

            ForEach(SceneGrouping.sections(
                scenes: orchestrator.globalScenes,
                index: roomIndex
            )) { section in
                SceneRoomSectionView(
                    section: section,
                    isCollapsed: FavoriteSceneCSV.contains(collapsedRoomIDsRaw, id: section.id),
                    onToggleCollapse: {
                        collapsedRoomIDsRaw = FavoriteSceneCSV.toggled(collapsedRoomIDsRaw,
                                                                       id: section.id)
                        HapticManager.shared.light()
                    }
                ) {
                    // Room label is redundant inside a room's own section.
                    sceneGrid(section.scenes, showsRoomLabel: false)
                }
                // A whole section is a drop target for a dragged scene card —
                // dropping opens the copy sheet pre-targeted to that room.
                .overlay {
                    if dropTargetRoomID == section.id {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(HuePalette.amber, lineWidth: 2)
                            .padding(-6)
                            .allowsHitTesting(false)
                    }
                }
                .dropDestination(for: SceneDragPayload.self) { items, _ in
                    handleSceneDrop(items, targetRoomID: section.id)
                } isTargeted: { targeting in
                    guard section.id != SceneGrouping.otherSectionID else { return }
                    if targeting {
                        dropTargetRoomID = section.id
                    } else if dropTargetRoomID == section.id {
                        dropTargetRoomID = nil
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 108)   // clear custom tab bar
    }

    private func favoritesShelf(_ favorites: [GlobalSceneItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "star.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(HuePalette.amber)
                Text("FAVORITES")
                    .font(.system(size: 13, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(StagePalette.ink)
                Spacer()
            }
            .padding(.vertical, 10)

            // Cross-room shelf — keep the room label on each card.
            sceneGrid(favorites, showsRoomLabel: true)
                .padding(.bottom, 6)
        }
    }

    // ── Flat modes + search results ───────────────────────

    private var flatGrid: some View {
        let usage = SceneUsageStore.shared
        return sceneGrid(
            SceneGrouping.flatSorted(
                scenes: filteredScenes,
                mode: sortMode,
                lastUsed: { usage.lastUsed(bridgeSceneID: $0.bridgeSceneID) },
                useCount: { usage.useCount(bridgeSceneID: $0.bridgeSceneID) }
            ),
            showsRoomLabel: true
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 108)   // clear custom tab bar
    }

    // ── Shared card grid ──────────────────────────────────

    private func sceneGrid(_ scenes: [GlobalSceneItem], showsRoomLabel: Bool) -> some View {
        LazyVGrid(columns: gridColumns, spacing: 14) {
            ForEach(scenes) { scene in
                sceneCard(scene, showsRoomLabel: showsRoomLabel)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: scenes.map { $0.id })
    }

    private func sceneCard(_ scene: GlobalSceneItem, showsRoomLabel: Bool) -> some View {
        SceneMoodCard(
            scene: scene,
            roomName: roomName(for: scene),
            showsRoomLabel: showsRoomLabel,
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
            if !orchestrator.isDemoMode {
                Button {
                    copySheetContext = CopySheetContext(scene: scene, mode: .copy)
                } label: {
                    Label("Copy to Room…", systemImage: "doc.on.doc")
                }
                Button {
                    copySheetContext = CopySheetContext(scene: scene, mode: .move)
                } label: {
                    Label("Move to Room…", systemImage: "arrow.turn.up.right")
                }
            }
            Divider()
            Button(role: .destructive) {
                sceneToDelete  = scene
                showDeleteAlert = true
            } label: {
                Label("Delete Scene", systemImage: "trash")
            }
        }
        // Drag the card onto a room section (grouped mode) or filter chip
        // (flat modes) to copy it there — lands in CopySceneSheet
        // pre-targeted, never a blind copy.
        .draggable(SceneDragPayload(sceneID: scene.id))
    }

    /// Shared handler for section/chip drops: resolve the payload back to a
    /// live scene and open the copy sheet pre-targeted at the drop room.
    private func handleSceneDrop(_ items: [SceneDragPayload], targetRoomID: String) -> Bool {
        dropTargetRoomID = nil
        guard !orchestrator.isDemoMode,
              targetRoomID != SceneGrouping.otherSectionID,
              let payload = items.first,
              let scene = orchestrator.globalScenes.first(where: { $0.id == payload.sceneID })
        else { return false }
        HapticManager.shared.medium()
        copySheetContext = CopySheetContext(
            scene: scene, mode: .copy, preselectedTargetID: targetRoomID
        )
        return true
    }

    // ── Copy/Move undo toast ──────────────────────────────

    private func showCopyUndo(_ undo: SceneCopyUndo) {
        withAnimation { copyUndo = undo }
        copyUndoDismissTask?.cancel()
        copyUndoDismissTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { copyUndo = nil }
        }
    }

    /// Copy-undo deletes the created scene; move-undo also re-POSTs the
    /// retained original verbatim (its actions still target its own room).
    private func performCopyUndo(_ undo: SceneCopyUndo) {
        copyUndoDismissTask?.cancel()
        withAnimation { copyUndo = nil }
        HapticManager.shared.light()
        Task {
            if let targetClient = orchestrator.hueClient(for: undo.targetBridgeID) {
                try? await targetClient.deleteScene(id: undo.newSceneID)
            }
            SceneProvenanceStore.shared.remove(key: "\(undo.targetBridgeID):\(undo.newSceneID)")
            if undo.mode == .move {
                // The ★/usage moved onto the (just-deleted) move target — follow
                // them back onto the recreated original, or scrub if the
                // re-POST failed (never leave a favorite on a dead id).
                var recreatedID: String?
                if let sourceClient = orchestrator.hueClient(for: undo.sourceScene.bridgeID) {
                    recreatedID = try? await sourceClient.createSceneReturningID(
                        SceneCopyEngine.recreateRequest(detail: undo.sourceDetail)
                    )
                }
                if let recreatedID {
                    favoriteSceneIDsRaw = FavoriteSceneCSV.replacing(
                        favoriteSceneIDsRaw, old: undo.newSceneID, new: recreatedID)
                    SceneUsageStore.shared.transfer(from: undo.newSceneID, to: recreatedID)
                } else {
                    favoriteSceneIDsRaw = FavoriteSceneCSV.removing(
                        favoriteSceneIDsRaw, id: undo.newSceneID)
                    SceneUsageStore.shared.remove(bridgeSceneID: undo.newSceneID)
                }
            }
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
            // Grid ↔ full-bar density toggle (Dashboard useWideCards precedent).
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    sceneWideCards.toggle()
                }
                HapticManager.shared.light()
            } label: {
                Image(systemName: sceneWideCards ? "rectangle.grid.1x2.fill" : "square.grid.2x2")
                    .foregroundStyle(.white.opacity(0.7))
            }
            .accessibilityLabel(sceneWideCards ? "Switch to grid layout" : "Switch to full-width layout")
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Picker("Sort", selection: Binding(
                    get: { sortMode },
                    set: { newMode in
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            sortModeRaw = newMode.rawValue
                            // Chips are hidden in grouped mode — drop any
                            // invisible filter so nothing is silently hidden.
                            if newMode.isGrouped { selectedRoomID = nil }
                        }
                        HapticManager.shared.light()
                    }
                )) {
                    ForEach(availableSortModes) { mode in
                        Label(mode.label, systemImage: mode.icon).tag(mode)
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .foregroundStyle(.white.opacity(0.7))
            }
            .accessibilityLabel("Sort scenes")
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
