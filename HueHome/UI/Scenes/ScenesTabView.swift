// ScenesTabView.swift
// ChromaGlow — Scenes (Luminous).
//
// Every saved mood in the house, drawn as the light it makes. A tab root in
// the Composer's language: its own glass header (what's on now, sort, new
// scene), the title block, an always-there search field, and a background
// that glows in the colours of the scenes that are on. Then: On now · your
// favorites · each room's scenes (collapsible), or one flat grid in the
// A–Z / Recent / Most Used modes with room chips that double as drop
// targets · Studio Classic looks that can be saved to a room.
//
// Behaviour is unchanged from the 2026-07 overhaul:
//   • Tap activates (orchestrator.activateGlobalScene); dynamic scenes have
//     a Speed sheet that activates the CURRENT globalScenes item.
//   • Favorites/usage key on the RAW bridgeSceneID; a move carries both to
//     the new id, its undo carries them back (or scrubs on failure).
//   • Delete scrubs provenance, ★ and usage only after the bridge confirms.
//   • Drag a card onto a room section / chip → a pre-targeted copy sheet,
//     never a blind copy.
//   • Granted (guest) bridges never offer rename/copy/move/delete/create.
//   • The tab never holds a live CompositionStore — Studio scenes come from
//     a read-only snapshot of the compositions file.
//   • Demo mode: local-only activate/rename/delete, no copy/move/drop.

import SwiftUI

// ══════════════════════════════════════════════════════════
// MARK: - ScenesTabView
// ══════════════════════════════════════════════════════════

struct ScenesTabView: View {

    @Environment(UnifiedOrchestrator.self) private var orchestrator
    @Environment(\.isTabActive) private var isTabActive
    @State private var searchText:     String
    @State private var selectedRoomID: String?           = nil
    @State private var speedSheetScene: GlobalSceneItem? = nil   // non-nil = sheet open
    @FocusState private var searchFocused: Bool

    // Scene CRUD
    @State private var sceneToDelete:  GlobalSceneItem? = nil
    @State private var showDeleteAlert = false
    @State private var sceneToRename:  GlobalSceneItem? = nil
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

    // ── Studio scenes shelf (scene-like Studio Classic creations) ──
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
    /// Card density: false = 2-up grid, true = full-width cards. Separate key
    /// from the Dashboard's so the screens stay independently configurable.
    @AppStorage("castchroma.sceneWideCards") private var sceneWideCards = false
    // Shared favorites contract: RAW bridge scene UUIDs (bridgeSceneID),
    // the same CSV RoomDetail writes and Home's mood row reads.
    @AppStorage("favoriteSceneIDs") private var favoriteSceneIDsRaw: String = ""
    private var provenance: SceneProvenanceStore { SceneProvenanceStore.shared }

    /// - Parameter initialSearchText: opens the tab already filtered (the
    ///   gallery renders a search; the tab itself always starts empty).
    init(initialSearchText: String = "") {
        _searchText = State(initialValue: initialSearchText)
    }

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
        // Every grid on the page (sections, flat/search, skeleton) routes
        // through this property; one column IS the full-width layout.
        if sceneWideCards {
            return [GridItem(.flexible(), spacing: 12)]
        }
        return [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    }

    // ── Derived data ──────────────────────────────────────

    /// Name/archetype lookup across rooms AND zones — zone scenes resolve
    /// as "Other" if only allRooms is searched.
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

    /// Scenes the current mode actually displays (drives the counts).
    private var displayedScenes: [GlobalSceneItem] {
        (sortMode.isGrouped && !isSearching) ? orchestrator.globalScenes : filteredScenes
    }

    private var activeCount: Int {
        displayedScenes.filter { $0.isActive }.count
    }

    private var activeScenes: [GlobalSceneItem] {
        orchestrator.globalScenes.filter(\.isActive)
    }

    private var favoriteScenes: [GlobalSceneItem] {
        SceneGrouping.favorites(scenes: orchestrator.globalScenes, favoriteIDsCSV: favoriteSceneIDsRaw)
    }

    /// The background glows in what's on, else in your favorites.
    private var ambienceColors: [Color] {
        let source = activeScenes.isEmpty ? favoriteScenes : activeScenes
        let colors = source.prefix(3).map { LuminousScenePalette.accent(for: $0) }
        return colors.isEmpty ? [LuminousPalette.violet] : Array(colors)
    }

    // ── Body ──────────────────────────────────────────────

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                titleBlock
                if orchestrator.isLoadingScenes && orchestrator.globalScenes.isEmpty {
                    loadingGrid
                } else if orchestrator.globalScenes.isEmpty {
                    LuminousEmptyState(symbol: "swatchpalette",
                                       title: "No scenes yet",
                                       message: "Scenes saved on your bridge appear here. Connect a bridge that has scenes, or capture one from a room with the + button.",
                                       actionTitle: "Refresh") {
                        Task { await orchestrator.loadAllScenes() }
                    }
                } else {
                    searchField
                    contentSections
                }
            }
            .padding(.horizontal, HueSpacing.screenH)
            .padding(.top, 8)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .refreshable {
            await orchestrator.loadAllScenes()
        }
        .background { LuminousAmbience(colors: ambienceColors) }
        .toolbar(.hidden, for: .navigationBar)
        .navigationTitle("Scenes")
        .sheet(isPresented: $showCreateScene) {
            CreateGlobalSceneView()
        }
        .sheet(isPresented: $showBuildScene) {
            SceneBuilderLauncherView()
        }
        .sheet(item: $studioSceneToAdd) { preset in
            studioSceneRoomPicker(preset: preset)
        }
        // Fresh read-only snapshot each visit — Studio Classic may have saved
        // new creations since the last one.
        .task { refreshStudioScenePresets() }
        .onChange(of: isTabActive) { _, active in
            if active { refreshStudioScenePresets() }
        }
        // Copy / Move / Rename / Speed take over the screen — let go of the
        // search field. It stayed focused behind them and, once back, every
        // layout change scrolled the list toward it — during testing a
        // long-press landed on a different "Test 1" (build-60 M-10).
        .onChange(of: copySheetContext != nil || sceneToRename != nil || speedSheetScene != nil) { _, presenting in
            if presenting { searchFocused = false }
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
                sceneToDelete  = nil
                showDeleteAlert = false
                Task {
                    // Hygiene: a deleted scene leaves no provenance badge key,
                    // dangling favorite, or usage history behind — but only
                    // once the bridge confirmed. A failed delete restores the
                    // scene, which must come back with its ★ and history.
                    guard await orchestrator.deleteGlobalScene(scene) else { return }
                    provenance.remove(key: scene.id)
                    favoriteSceneIDsRaw = FavoriteSceneCSV.removing(favoriteSceneIDsRaw,
                                                                    id: scene.bridgeSceneID)
                    SceneUsageStore.shared.remove(bridgeSceneID: scene.bridgeSceneID)
                }
            }
            Button("Cancel", role: .cancel) {
                sceneToDelete  = nil
                showDeleteAlert = false
            }
        } message: { scene in
            Text("\"\(scene.name)\" will be permanently removed from your bridge.")
        }
        .preferredColorScheme(.dark)
        .sheet(item: $speedSheetScene) { scene in
            SceneSpeedSheet(
                scene:      scene,
                onSpeedChange: { orchestrator.setSceneSpeed(scene, speed: $0) },
                onActivate: {
                    speedSheetScene = nil
                    HapticManager.shared.medium()
                    // `scene` is the snapshot taken when the sheet opened;
                    // the slider has since written the chosen speed into
                    // globalScenes (setSceneSpeed). Activate THAT, or the
                    // recall goes out at the old speed.
                    let current = orchestrator.globalScenes.first { $0.id == scene.id } ?? scene
                    orchestrator.activateGlobalScene(current)
                }
            )
        }
        .task {
            if orchestrator.globalScenes.isEmpty {
                await orchestrator.loadAllScenes()
            }
        }
    }

    // ── Header ────────────────────────────────────────────

    private var header: some View {
        HStack(spacing: 10) {
            stateChip
            Spacer(minLength: 0)
            if orchestrator.isLoadingScenes && !orchestrator.globalScenes.isEmpty {
                ProgressView().tint(LuminousPalette.ink).scaleEffect(0.85)
                    .accessibilityLabel("Refreshing scenes")
            }
            sortMenu
            // Unified creation entry: capture the room's current look, or
            // build per-light colors — both existing flows, one door.
            // Guest-only devices have no bridge they may create scenes on.
            if !orchestrator.guestAccessInfo.isGuestOnly {
                createMenu
            }
        }
    }

    @ViewBuilder
    private var stateChip: some View {
        if orchestrator.isLoadingScenes && orchestrator.globalScenes.isEmpty {
            LuminousStateChip(text: "Finding scenes…", dot: LuminousPalette.cyan, glowing: true)
        } else if orchestrator.globalScenes.isEmpty {
            LuminousStateChip(text: "No scenes")
        } else if activeCount > 0 {
            LuminousStateChip(text: "\(activeCount) on now", dot: LuminousPalette.live, glowing: true)
        } else {
            let n = displayedScenes.count
            LuminousStateChip(text: "\(n) scene\(n == 1 ? "" : "s")", dot: LuminousPalette.violet)
        }
    }

    private var sortMenu: some View {
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
            Section {
                Toggle(isOn: Binding(
                    get: { sceneWideCards },
                    set: { wide in
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { sceneWideCards = wide }
                        HapticManager.shared.light()
                    }
                )) {
                    Label("Full-Width Cards", systemImage: "rectangle.grid.1x2")
                }
            }
        } label: {
            LuminousRoundGlyph(symbol: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Sort scenes")
    }

    private var createMenu: some View {
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
            LuminousRoundGlyph(symbol: "plus")
        }
        .accessibilityLabel("New scene")
    }

    private var titleBlock: some View {
        let total = orchestrator.globalScenes.count
        let rooms = uniqueRooms.count
        let subtitle = total == 0
            ? "Saved moods from your bridge, one tap away."
            : "\(total) scene\(total == 1 ? "" : "s") across \(rooms) room\(rooms == 1 ? "" : "s"). Tap one to bring it back."
        return LuminousScreenTitle(title: "Scenes",
                                   eyebrow: "Still moods",
                                   eyebrowSymbol: "swatchpalette.fill",
                                   eyebrowTint: LuminousPalette.magenta,
                                   subtitle: subtitle)
    }

    // ── Search ────────────────────────────────────────────

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(searchFocused || isSearching ? LuminousPalette.cyan : LuminousPalette.inkSecondary)
            TextField("Search scenes or rooms", text: $searchText)
                .font(.body)
                .foregroundStyle(LuminousPalette.ink)
                .tint(LuminousPalette.cyan)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFocused)
            if isSearching {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { searchText = "" }
                    HapticManager.shared.light()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(LuminousPalette.inkSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, isSearching ? 0 : 14)
        .frame(minHeight: 48)
        .luminousGlass(radius: 16, accent: LuminousPalette.cyan, selected: searchFocused)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: searchFocused)
    }

    // ── Content ───────────────────────────────────────────

    private var contentSections: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Room filter chips — flat modes only (sections replace them in
            // grouped mode). They double as drag-drop targets.
            if !sortMode.isGrouped {
                chipRow
            }

            if sortMode.isGrouped && !isSearching {
                if !activeScenes.isEmpty {
                    shelf(title: "On now", subtitle: "What your rooms are showing.",
                          symbol: "light.max", tint: LuminousPalette.live, scenes: activeScenes)
                }
                if !favoriteScenes.isEmpty {
                    shelf(title: "Favorites", subtitle: "Your starred scenes, from every room.",
                          symbol: "star.fill", tint: LuminousPalette.amber, scenes: favoriteScenes)
                }
                roomSections
            } else {
                flatGrid
            }

            // Studio Classic looks that save as real bridge scenes. Tapping
            // one creates a scene in a room you pick, so it joins that
            // room's list right here.
            if !studioScenePresets.isEmpty && !studioSceneTargetRooms.isEmpty {
                studioScenesShelf
            }
        }
    }

    /// A horizontal shelf of cross-room cards (room label kept on each).
    private func shelf(title: String, subtitle: String, symbol: String, tint: Color,
                       scenes: [GlobalSceneItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            LuminousSectionHeader(title: title, subtitle: subtitle, symbol: symbol, tint: tint)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(scenes) { scene in
                        sceneCard(scene, showsRoomLabel: true)
                            .frame(width: 168)
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollClipDisabled()
        }
    }

    // ── Grouped mode: room sections ───────────────────────

    private var roomSections: some View {
        VStack(alignment: .leading, spacing: 18) {
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
                        RoundedRectangle(cornerRadius: LuminousPalette.panelRadius, style: .continuous)
                            .strokeBorder(LuminousPalette.signalGradient, lineWidth: 2)
                            .shadow(color: LuminousPalette.cyan.opacity(0.5), radius: 10)
                            .padding(-8)
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
    }

    // ── Flat modes + search results ───────────────────────

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                LuminousChip(title: "All", symbol: "sparkles", selected: selectedRoomID == nil) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        selectedRoomID = nil
                    }
                }
                ForEach(uniqueRooms, id: \.id) { room in
                    LuminousChip(title: room.name,
                                 symbol: archetypeIcon(for: roomIndex[room.id]?.archetype),
                                 selected: selectedRoomID == room.id || dropTargetRoomID == room.id) {
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
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }

    private var flatGrid: some View {
        let usage = SceneUsageStore.shared
        let scenes = SceneGrouping.flatSorted(
            scenes: filteredScenes,
            mode: sortMode,
            lastUsed: { usage.lastUsed(bridgeSceneID: $0.bridgeSceneID) },
            useCount: { usage.useCount(bridgeSceneID: $0.bridgeSceneID) }
        )
        return VStack(alignment: .leading, spacing: 12) {
            LuminousSectionHeader(title: flatTitle,
                                  subtitle: "\(scenes.count) scene\(scenes.count == 1 ? "" : "s")")
            if scenes.isEmpty {
                Text(isSearching ? "Nothing matches “\(searchText)”." : "No scenes in this room yet.")
                    .font(.subheadline)
                    .foregroundStyle(LuminousPalette.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                sceneGrid(scenes, showsRoomLabel: true)
            }
        }
    }

    private var flatTitle: String {
        if isSearching { return "Results" }
        switch sortMode {
        case .byRoom:       return "Scenes"
        case .alphabetical: return "All scenes"
        case .recent:       return "Recently used"
        case .mostUsed:     return "Most used"
        }
    }

    // ── Shared card grid ──────────────────────────────────

    private func sceneGrid(_ scenes: [GlobalSceneItem], showsRoomLabel: Bool) -> some View {
        LazyVGrid(columns: gridColumns, spacing: 12) {
            ForEach(scenes) { scene in
                sceneCard(scene, showsRoomLabel: showsRoomLabel)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: scenes.map { $0.id })
    }

    private func sceneCard(_ scene: GlobalSceneItem, showsRoomLabel: Bool) -> some View {
        LuminousSceneCard(
            scene: scene,
            roomName: roomName(for: scene),
            showsRoomLabel: showsRoomLabel,
            isFavorite: isFavorite(scene),
            isStudio: provenance.isStudioScene(key: scene.id)
        ) {
            // Tap: activate immediately.
            HapticManager.shared.medium()
            orchestrator.activateGlobalScene(scene)
        } onSpeed: {
            // The Speed button exists only on dynamic scenes.
            HapticManager.shared.heavy()
            speedSheetScene = scene
        }
        .contextMenu {
            Button {
                toggleFavorite(scene)
            } label: {
                Label(isFavorite(scene) ? "Unfavorite" : "Favorite",
                      systemImage: isFavorite(scene) ? "star.slash" : "star")
            }
            // Mutating actions never appear for a granted bridge's scenes —
            // guests recall, favorites stay local-only (design §5).
            if !orchestrator.isGuestGrantedBridge(scene.bridgeID) {
                Button {
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

    // ── Studio scenes shelf ───────────────────────────────

    /// Rooms/zones a Studio scene may be added to. Adding one POSTs a new
    /// bridge scene, so a granted (guest) bridge's rooms are never offered —
    /// on a guest-only phone that empties the list and hides the shelf.
    private var studioSceneTargetRooms: [RoomDisplayItem] {
        (orchestrator.allRooms + orchestrator.allZones)
            .filter { !orchestrator.isGuestGrantedBridge($0.bridgeID) }
    }

    /// Fresh read-only snapshot of scene-like Studio creations. Off-main
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
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(HueAnimation.fast) { studioShelfCollapsed.toggle() }
                HapticManager.shared.selection()
            } label: {
                LuminousSectionHeader(title: "From Studio Classic",
                                      subtitle: "Still looks you made there. Add one to a room and it becomes a real scene.",
                                      symbol: "wand.and.stars",
                                      tint: LuminousPalette.lime) {
                    HStack(spacing: 8) {
                        Text("\(studioScenePresets.count)")
                            .font(LuminousType.value)
                            .foregroundStyle(LuminousPalette.inkSecondary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(LuminousPalette.inkSecondary)
                            .rotationEffect(.degrees(studioShelfCollapsed ? -90 : 0))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Studio scenes, \(studioScenePresets.count), \(studioShelfCollapsed ? "collapsed" : "expanded")")

            if !studioShelfCollapsed {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(studioScenePresets) { preset in
                            studioPresetTile(preset)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollClipDisabled()
            }
        }
    }

    private func studioPresetTile(_ preset: CompositionPreset) -> some View {
        let accent = Color(hex: preset.accentColorHex)
        return Button {
            studioSceneToAdd = preset
            HapticManager.shared.light()
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                // Static real-palette strip — no clock in a horizontal scroller.
                LookPreviewStrip(spec: LookPreviewSpec(preset: preset), animated: false, height: 8)
                HStack(spacing: 6) {
                    Image(systemName: preset.icon)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(accent)
                    Text(preset.name)
                        .font(LuminousType.cardTitleSmall)
                        .foregroundStyle(LuminousPalette.ink)
                        .lineLimit(1)
                }
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle.fill").font(.system(size: 11, weight: .bold))
                    Text("Add to a room").font(.caption.weight(.semibold))
                }
                .foregroundStyle(LuminousPalette.cyan)
            }
            .padding(12)
            .frame(width: 168, alignment: .leading)
            .luminousPanel(radius: 18, glow: accent, glowStrength: 0.45)
        }
        .buttonStyle(LuminousPressStyle(scale: 0.95))
        .accessibilityLabel("Add \(preset.name) to a room as a scene")
    }

    /// Pick the room the Studio scene lands in — it becomes a real bridge
    /// scene there, provenance-badged like the Composer's own export.
    private func studioSceneRoomPicker(preset: CompositionPreset) -> some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    LuminousScreenTitle(title: preset.name,
                                        eyebrow: "Add to a room",
                                        eyebrowSymbol: "plus.circle.fill",
                                        eyebrowTint: LuminousPalette.cyan,
                                        subtitle: "Creates a real Hue scene in that room — it runs from the bridge like any other scene.")
                    LuminousGroup {
                        ForEach(Array(studioSceneTargetRooms.enumerated()), id: \.element.id) { index, room in
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
                                LuminousRow(symbol: room.kind == .zone ? "square.stack.3d.up" : archetypeIcon(for: room.archetype),
                                            tint: LuminousPalette.cyan,
                                            title: room.name,
                                            subtitle: room.kind == .zone ? "Zone" : "\(room.lightCount) light\(room.lightCount == 1 ? "" : "s")") {
                                    if studioAddBusy {
                                        ProgressView().tint(LuminousPalette.ink)
                                    } else {
                                        LuminousChevron()
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(studioAddBusy)
                            if index < studioSceneTargetRooms.count - 1 { LuminousRowDivider() }
                        }
                    }
                }
                .padding(.horizontal, HueSpacing.screenH)
                .padding(.vertical, 16)
            }
            .background { LuminousAmbience(colors: [Color(hex: preset.accentColorHex)]) }
            .luminousNavigationChrome()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { studioSceneToAdd = nil }
                        .foregroundStyle(LuminousPalette.ink.opacity(0.75))
                }
            }
        }
        .presentationDetents([.medium, .large])
        .luminousSheet()
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
        LazyVGrid(columns: gridColumns, spacing: 12) {
            ForEach(0..<6, id: \.self) { _ in
                LuminousSceneSkeleton()
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Loading scenes")
    }
}
