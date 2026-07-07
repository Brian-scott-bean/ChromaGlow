// RoomDetailView.swift
// CastChroma — Epic 3 / Story 3.1
//
// Individual light control drill-down.
// Reuses GlassmorphicCard, BrightnessRow, and archetypeIcon() from the dashboard layer.
// Each bulb card: tap = toggle, brightness scrubber = dimming.

import SwiftUI

// MARK: - RoomDetailView

struct RoomDetailView: View {

    let room: RoomDisplayItem
    @State private var vm: RoomDetailViewModel
    @State private var showLog           = false
    @State private var showCreateScene   = false
    @State private var showBulkScene     = false   // CreateSceneView from BulkActionBar
    @State private var showAddMenu       = false   // + button menu
    @State private var showCreateAutomation = false
    @State private var sceneToRename:    SceneDisplayItem? = nil
    @State private var sceneRenameDraft: String = ""

    // ── Scene Edit Mode ──────────────────────────────────────────────────────
    @State private var sceneToEdit:       SceneDisplayItem? = nil  // drives SceneColorBuilder in edit mode

    // ── Favorite Scenes ──────────────────────────────────────────────────────
    @AppStorage("favoriteSceneIDs") private var favoriteSceneIDsRaw: String = ""
    private var favoriteSceneIDs: Set<String> {
        Set(favoriteSceneIDsRaw.split(separator: ",").map(String.init))
    }
    private func toggleFavorite(_ scene: SceneDisplayItem) {
        var ids = favoriteSceneIDs
        if ids.contains(scene.id) {
            ids.remove(scene.id)
        } else {
            ids.insert(scene.id)
        }
        favoriteSceneIDsRaw = ids.joined(separator: ",")
    }

    // ── Room / Zone CRUD ──────────────────────────────────────────────────────
    @State private var showRoomMenu  = false   // drives the ··· confirmationDialog
    @State private var showEditSheet = false   // drives the EditRoomSheet

    @Environment(UnifiedOrchestrator.self) private var orchestrator
    @Environment(\.dismiss)               private var dismiss

    init(room: RoomDisplayItem) {
        self.room = room
        // vm is placeholder — will be replaced with correct client in .onAppear
        // We use a temp init here; proper injection happens via updateVM()
        _vm = State(initialValue: RoomDetailViewModel(room: room))
    }

    var body: some View {
        ZStack {
            RoomDetailAmbientBackground()

            Group {
                if vm.isLoading && vm.lights.isEmpty {
                    loadingView
                } else if let error = vm.errorMessage, vm.lights.isEmpty {
                    errorView(error)
                } else {
                    lightScrollView
                }
            }

            // BulkActionBar — slides up when lights are selected.
            // NOTE: RoomDetailAmbientBackground uses .ignoresSafeArea(), which
            // expands the ZStack to the full screen height (inc. home indicator).
            // Spacer() therefore pushes to the raw screen bottom, NOT the safe
            // area bottom. Explicit padding is needed to clear:
            //   home indicator (~34pt) + tab bar bottom pad (8pt) + capsule (56pt) = ~98pt
            if vm.isSelecting {
                VStack {
                    Spacer()
                    BulkActionBar(vm: vm) { showBulkScene = true }
                        .padding(.bottom, 100)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .zIndex(5)
                .animation(.spring(response: 0.35, dampingFraction: 0.75), value: vm.isSelecting)
            }

            // SceneEditBar — slides up when scenes are selected.
            if vm.isSelectingScenes {
                VStack {
                    Spacer()
                    SceneEditBar(vm: vm) { scene in
                        // Edit: activate the scene to seed light states, then open builder
                        vm.activateScene(scene)
                        vm.exitSceneSelectMode()
                        sceneToEdit = scene
                    }
                    .padding(.bottom, 100)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .zIndex(5)
                .animation(.spring(response: 0.35, dampingFraction: 0.75), value: vm.isSelectingScenes)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .scrollContentBackground(.hidden)
        .background(Color(red: 0.055, green: 0.055, blue: 0.08).ignoresSafeArea())
        .toolbar { toolbarItems }
        .sheet(isPresented: $showLog) { logSheet }
        .sheet(isPresented: $showCreateScene) {
            SceneColorBuilderView(
                roomID: room.id,
                roomRType: room.kind == .zone ? "zone" : "room",
                bridgeID: room.bridgeID ?? "",
                existingSceneID: nil,
                existingSceneName: nil,
                initialLights: vm.lights
            ) {
                Task { await vm.loadScenes() }
            }
        }
        // SceneColorBuilderView launched from BulkActionBar — pre-filtered to selection
        .sheet(isPresented: $showBulkScene) {
            let prefiltered = vm.selectedLights
            SceneColorBuilderView(
                roomID: room.id,
                roomRType: room.kind == .zone ? "zone" : "room",
                bridgeID: room.bridgeID ?? "",
                existingSceneID: nil,
                existingSceneName: nil,
                initialLights: prefiltered.isEmpty ? vm.lights : prefiltered
            ) {
                vm.exitSelectMode()
                Task { await vm.loadScenes() }
            }
        }
        // SceneColorBuilderView launched for editing an existing scene
        .sheet(item: $sceneToEdit) { scene in
            SceneColorBuilderView(
                roomID: room.id,
                roomRType: room.kind == .zone ? "zone" : "room",
                bridgeID: room.bridgeID ?? "",
                existingSceneID: scene.id,
                existingSceneName: scene.name,
                initialLights: vm.lights   // lights are already in scene state after activateScene()
            ) {
                Task { await vm.loadScenes() }
            }
        }
        // ── Edit Room / Zone sheet ─────────────────────────────────────────────
        .sheet(isPresented: $showEditSheet) {
            EditRoomSheet(room: room, isZone: room.kind == .zone) { newName, newArchetype in
                Task {
                    if room.kind == .zone {
                        await orchestrator.renameZone(room, name: newName, archetype: newArchetype)
                    } else {
                        await orchestrator.renameRoom(room, name: newName, archetype: newArchetype)
                    }
                }
            }
        }
        // ── Room / Zone CRUD action sheet (··· button) ───────────────────────────
        .confirmationDialog(
            room.kind == .zone ? "Zone: \(room.name)" : "Room: \(room.name)",
            isPresented: $showRoomMenu,
            titleVisibility: .visible
        ) {
            Button(room.kind == .zone ? "Edit Zone" : "Edit Room") {
                showEditSheet = true
            }
            Button(room.kind == .zone ? "Delete Zone" : "Delete Room", role: .destructive) {
                Task {
                    if room.kind == .zone {
                        await orchestrator.deleteZone(room)
                    } else {
                        await orchestrator.deleteRoom(room)
                    }
                    await MainActor.run { dismiss() }   // pop back to dashboard
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Scene", isPresented: Binding(
            get: { sceneToRename != nil },
            set: { if !$0 { sceneToRename = nil } }
        )) {
            TextField("Scene name", text: $sceneRenameDraft)
            Button("Rename") {
                if let scene = sceneToRename {
                    vm.renameScene(scene, to: sceneRenameDraft)
                }
                sceneToRename = nil
            }
            .disabled(sceneRenameDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) { sceneToRename = nil }
        } message: {
            if let scene = sceneToRename {
                Text("Enter a new name for \"\(scene.name)\"")
            }
        }
        .sheet(isPresented: $showCreateAutomation) {
            CreateAutomationView()
        }
        .confirmationDialog("Add", isPresented: $showAddMenu) {
            Button("New Scene") { showCreateScene = true }
            Button("New Schedule") { showCreateAutomation = true }
            Button("Cancel", role: .cancel) {}
        }
        .task {
            // Re-build vm with the right bridge client now that orchestrator is available.
            // This replaces the placeholder vm created in init() with one that has correct credentials.
            vm = RoomDetailViewModel(
                room: room,
                api: orchestrator.hueClient(for: room.bridgeID),
                isDemoMode: orchestrator.isDemoMode
            )
            // Wire the glow-refresh callback so color changes propagate to dashboard cards.
            let bridgeID = room.bridgeID ?? ""
            vm.onColorCommitted = { [weak orchestrator] in
                guard let orchestrator, !bridgeID.isEmpty else { return }
                orchestrator.refreshDominantColors(for: bridgeID)
            }
            // Load data concurrently. SSE runs forever so it must NOT block the group.
            // Instead, launch SSE separately and use the group for finite fetches only.
            async let _: Void = vm.runSSE(eventStream: orchestrator.subscribeToLightEvents())
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await vm.loadLights() }
                group.addTask { await vm.loadScenes() }
                group.addTask { await vm.loadAutomations() }
            }
            // Load room-level state after lights are loaded (needs light data for cross-check)
            await vm.loadRoomState()
        }
        .preferredColorScheme(.dark)
        .overlay(alignment: .top) {
            if let msg = vm.toastMessage {
                HueToastView(message: msg)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(.spring(response: 0.4, dampingFraction: 0.75), value: vm.toastMessage)
                    .allowsHitTesting(false)
                    .zIndex(10)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: vm.toastMessage)
    }

    // ──────────────────────────────────────────────
    // MARK: - Background
    // ──────────────────────────────────────────────
    // ambientBackground moved to RoomDetailAmbientBackground struct (bottom of file).
    // Separated so SSE / vm changes don't trigger blur re-renders.

    // ──────────────────────────────────────────────
    // MARK: - Light Scroll
    // ──────────────────────────────────────────────

    private var lightScrollView: some View {
        ScrollView {
            VStack(spacing: 0) {
                // ── Room Name (custom large title — inline mode has no large title area,
                //    which eliminates the opaque nav bar background on pushed views) ──
                Text(room.name)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                // ── Room Brightness Header ──
                roomBrightnessHeader
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 20)

                // ── SCENES section ──
                if !vm.scenes.isEmpty || !vm.lights.isEmpty {
                    scenesStrip
                        .padding(.bottom, 24)
                }

                // ── LIGHTS section (horizontal scroll strip) ──
                lightsSection
                    .padding(.bottom, 24)

                // ── AUTOMATIONS section (room-scoped) ──
                if !vm.automations.isEmpty {
                    automationsSection
                        .padding(.bottom, 32)
                }
            }   // VStack
        }       // ScrollView
        .navigationDestination(for: LightDisplayItem.self) { light in
            if let binding = vm.lightBinding(for: light) {
                LightControlView(
                    light: binding,
                    onToggle:     { desiredOn in vm.setLight(binding.wrappedValue, isOn: desiredOn) },
                    onBrightness: { vm.setBrightness($0, for: binding.wrappedValue) },
                    onColor:      { x, y in vm.setColor(x: x, y: y, for: binding.wrappedValue) },
                    onColorTemp:  { vm.setColorTemp(mirek: $0, for: binding.wrappedValue) },
                    onIdentify:   {
                        let lightID = binding.wrappedValue.id
                        Task {
                            await SignalingService(orchestrator: orchestrator)
                                .identifyLight(id: lightID, bridgeID: room.bridgeID)
                        }
                    }
                )
            }
        }
        .refreshable {
            await vm.loadLights()
            await vm.loadRoomState()
            await vm.loadAutomations()
        }
        .scrollIndicators(.hidden)
    }

    // ── Lights Section (horizontal strip) ─────────

    private var lightsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color(red: 1.0, green: 0.76, blue: 0.20))
                    Text("LIGHTS")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                    Text("(\(vm.lights.count))")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.25))
                }
                Spacer()
                // Select / Done button for multi-select mode
                Button(vm.isSelecting ? "Done" : "Select") {
                    if vm.isSelecting { vm.exitSelectMode() } else { vm.enterSelectMode() }
                }
                .font(.system(size: 12, weight: vm.isSelecting ? .semibold : .regular))
                .foregroundStyle(vm.isSelecting
                                 ? Color(red: 1.0, green: 0.76, blue: 0.20)
                                 : .white.opacity(0.5))
            }
            .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(vm.lights, id: \.id) { light in
                        let isSelected = vm.selectedLightIDs.contains(light.id)
                        CompactLightCard(
                            light:          light,
                            isSelecting:    vm.isSelecting,
                            isSelected:     isSelected,
                            onToggle:       { desiredOn in vm.setLight(light, isOn: desiredOn) },
                            onToggleSelect: { vm.toggleSelection(id: light.id) },
                            onLongPress:    { vm.enterSelectMode(preselecting: light.id) }
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 2)
            }
        }
    }

    // ── Scene Strip ───────────────────────────────

    private var scenesStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header: label + Select/Done + "＋" button
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color(red: 0.60, green: 0.40, blue: 0.90))
                    Text("SCENES")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                    Text("(\(vm.scenes.count))")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.25))
                }
                Spacer()

                // Select / Done for scene multi-select
                if vm.scenes.count > 1 {
                    Button(vm.isSelectingScenes ? "Done" : "Select") {
                        if vm.isSelectingScenes { vm.exitSceneSelectMode() } else { vm.enterSceneSelectMode() }
                    }
                    .font(.system(size: 12, weight: vm.isSelectingScenes ? .semibold : .regular))
                    .foregroundStyle(vm.isSelectingScenes
                                     ? Color(red: 1.0, green: 0.76, blue: 0.20)
                                     : .white.opacity(0.5))
                }

                if !vm.isSelectingScenes {
                    Button {
                        HapticManager.shared.light()
                        showCreateScene = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                            Text("New")
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(red: 1.0, green: 0.76, blue: 0.20).opacity(0.85))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(vm.scenes) { scene in
                        let isSelected = vm.selectedSceneIDs.contains(scene.id)
                        let isFav = favoriteSceneIDs.contains(scene.id)

                        ZStack(alignment: .topTrailing) {
                            if vm.isSelectingScenes {
                                // Select mode: tap = toggle selection
                                Button {
                                    vm.toggleSceneSelection(id: scene.id)
                                } label: {
                                    RoomSceneChip(
                                        scene: scene,
                                        isActivating: false
                                    ) { /* no-op in select mode */ }
                                    .allowsHitTesting(false)
                                }
                                .buttonStyle(.plain)
                            } else {
                                // Normal mode: tap = activate
                                RoomSceneChip(
                                    scene: scene,
                                    isActivating: vm.activatingSceneID == scene.id
                                ) {
                                    vm.activateScene(scene)
                                }
                                .contextMenu {
                                    Button {
                                        // Edit: activate scene first to seed light colors, then open builder
                                        vm.activateScene(scene)
                                        // Small delay so lights update before builder opens
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                                            sceneToEdit = scene
                                        }
                                    } label: {
                                        Label("Edit Scene", systemImage: "slider.horizontal.3")
                                    }
                                    Button {
                                        toggleFavorite(scene)
                                    } label: {
                                        Label(
                                            isFav ? "Unfavorite" : "Favorite",
                                            systemImage: isFav ? "star.slash" : "star"
                                        )
                                    }
                                    Button {
                                        sceneRenameDraft = scene.name
                                        sceneToRename    = scene
                                    } label: {
                                        Label("Rename", systemImage: "pencil")
                                    }
                                    Divider()
                                    Button(role: .destructive) {
                                        vm.deleteScene(scene)
                                    } label: {
                                        Label("Delete Scene", systemImage: "trash")
                                    }
                                }
                            }

                            // ── Star badge for favorited scenes ──
                            if isFav && !vm.isSelectingScenes {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Color(red: 1.0, green: 0.76, blue: 0.20))
                                    .padding(6)
                                    .transition(.scale(scale: 0.5).combined(with: .opacity))
                            }

                            // ── Checkbox overlay for select mode ──
                            if vm.isSelectingScenes {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundStyle(isSelected
                                                     ? scene.accentColor
                                                     : .white.opacity(0.35))
                                    .padding(6)
                                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                                    .animation(.spring(response: 0.3), value: isSelected)
                            }
                        }
                        .opacity(vm.isSelectingScenes ? (isSelected ? 1.0 : 0.55) : 1.0)
                        .animation(.spring(response: 0.25), value: isSelected)
                        .animation(.spring(response: 0.3), value: vm.isSelectingScenes)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 2)
            }
        }
    }

    // ── Room Brightness Header (replaces summaryHeader) ───────────

    private var roomBrightnessHeader: some View {
        // Derive dominant glow color from the brightest ON light
        let dominantGlow: Color = {
            if let best = vm.lights.filter({ $0.isOn }).max(by: { $0.brightness < $1.brightness }) {
                return LightCard.resolveGlowColor(for: best)
            }
            return Color(red: 1.0, green: 0.76, blue: 0.20)
        }()

        return VStack(spacing: 14) {
            // Status + room toggle
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    let onCount = vm.lights.filter { $0.isOn }.count
                    Text(onCount == 0
                         ? "All lights off"
                         : "\(onCount) of \(vm.lights.count) on")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.9))
                    Text("\(vm.lights.count) bulb\(vm.lights.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.45))
                }
                Spacer()
                // Room-level power button
                Button {
                    HapticManager.shared.medium()
                    vm.toggleRoom(on: !vm.roomIsOn)
                } label: {
                    Image(systemName: vm.roomIsOn ? "power.circle.fill" : "power.circle")
                        .font(.system(size: 28))
                        .foregroundStyle(vm.roomIsOn
                                         ? dominantGlow
                                         : .white.opacity(0.35))
                        .symbolEffect(.bounce, value: vm.roomIsOn)
                }
                .buttonStyle(.plain)
            }

            // Room-level brightness slider
            if vm.roomIsOn {
                BrightnessRow(
                    brightness: vm.roomBrightness,
                    glowColor: dominantGlow,
                    onCommit: { vm.setRoomBrightness($0) }
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(vm.roomIsOn
                      ? dominantGlow.opacity(0.10)
                      : Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(
                            vm.roomIsOn
                                ? dominantGlow.opacity(0.40)
                                : Color.white.opacity(0.08),
                            lineWidth: vm.roomIsOn ? 1.5 : 1
                        )
                )
        )
        .shadow(color: vm.roomIsOn
                ? dominantGlow.opacity(0.20)
                : .clear,
                radius: 12, x: 0, y: 4)
        .animation(.spring(response: 0.35, dampingFraction: 0.72), value: vm.roomIsOn)
    }

    // ── Automations Section (room-scoped) ─────────

    private var automationsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(red: 0.55, green: 0.35, blue: 1.00))
                Text("AUTOMATIONS")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                Text("(\(vm.automations.count))")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.25))
            }
            .padding(.horizontal, 20)

            VStack(spacing: 0) {
                ForEach(Array(vm.automations.enumerated()), id: \.element.id) { idx, item in
                    AutomationRow(
                        item: item,
                        iconColor: automationIconColor(item.category)
                    ) {
                        vm.toggleAutomation(item)
                    }
                    .padding(.horizontal, 16)

                    if idx < vm.automations.count - 1 {
                        Divider()
                            .background(Color.white.opacity(0.07))
                            .padding(.horizontal, 16)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 20)
        }
    }

    private func automationIconColor(_ category: AutomationDisplayItem.AutomationCategory) -> Color {
        switch category.color {
        case "orange":  return .orange
        case "indigo":  return .indigo
        case "yellow":  return Color(red: 1.0, green: 0.76, blue: 0.20)
        case "blue":    return Color(red: 0.4, green: 0.6, blue: 1.0)
        case "teal":    return .teal
        case "purple":  return Color(red: 0.55, green: 0.35, blue: 1.00)
        default:        return Color(red: 1.0, green: 0.76, blue: 0.20)
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Toolbar
    // ──────────────────────────────────────────────

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        // + button — New Scene / New Automation
        ToolbarItem(placement: .navigationBarTrailing) {
            if !vm.isSelecting {
                Button {
                    showAddMenu = true
                    HapticManager.shared.light()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color(red: 1.0, green: 0.76, blue: 0.20).opacity(0.85))
                }
            }
        }
        // ··· (more) button — Edit / Delete room or zone
        // Hidden during multi-select so it doesn't compete with Select/Done.
        ToolbarItem(placement: .navigationBarTrailing) {
            if !vm.isSelecting {
                Button {
                    showRoomMenu = true
                    HapticManager.shared.light()
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button { showLog.toggle() } label: {
                Image(systemName: "terminal")
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            if vm.isLoading {
                ProgressView().progressViewStyle(.circular).tint(.white).scaleEffect(0.8)
            } else {
                Button { Task { await vm.loadLights() } } label: {
                    Image(systemName: "arrow.clockwise").foregroundStyle(.white.opacity(0.7))
                }
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Loading / Error
    // ──────────────────────────────────────────────

    private var loadingView: some View {
        VStack(spacing: 20) {
            ProgressView().progressViewStyle(.circular).tint(.yellow).scaleEffect(1.6)
            Text("Loading lights…").font(.subheadline).foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 44)).foregroundStyle(.orange)
            Text(message).font(.caption).foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center).padding(.horizontal)
            Button("Retry") { Task { await vm.loadLights() } }
                .buttonStyle(.borderedProminent).tint(.orange)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // ──────────────────────────────────────────────
    // MARK: - Console Log Sheet
    // ──────────────────────────────────────────────

    private var logSheet: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.055, green: 0.055, blue: 0.08).ignoresSafeArea()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(vm.logLines.enumerated()), id: \.offset) { idx, line in
                                Text(line)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.8))
                                    .id(idx)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: vm.logLines.count) { _, count in
                        proxy.scrollTo(count - 1, anchor: .bottom)
                    }
                }
            }
            .navigationTitle("Light Console")
            .navigationBarTitleDisplayMode(.inline)
            .preferredColorScheme(.dark)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showLog = false }
                }
            }
        }
    }
}

// MARK: - LightCard
//
// Individual bulb card.
// Normal mode: tap = NavigationLink → LightControlView; long-press = enter select mode.
// Select mode:  tap = toggle checkbox; no navigation; power button hidden.

struct LightCard: View {

    let light:          LightDisplayItem
    let isSelecting:    Bool
    let isSelected:     Bool
    let onToggle:       (Bool)   -> Void
    let onBrightness:   (Double) -> Void
    let onToggleSelect: ()       -> Void
    let onLongPress:    ()       -> Void

    @State private var localIsOn: Bool

    init(
        light:          LightDisplayItem,
        isSelecting:    Bool             = false,
        isSelected:     Bool             = false,
        onToggle:       @escaping (Bool)   -> Void,
        onBrightness:   @escaping (Double) -> Void,
        onToggleSelect: @escaping ()       -> Void = {},
        onLongPress:    @escaping ()       -> Void = {}
    ) {
        self.light          = light
        self.isSelecting    = isSelecting
        self.isSelected     = isSelected
        self.onToggle       = onToggle
        self.onBrightness   = onBrightness
        self.onToggleSelect = onToggleSelect
        self.onLongPress    = onLongPress
        _localIsOn          = State(initialValue: light.isOn)
    }

    /// Glow color computed directly from light — always current.
    private var glowColor: Color {
        Self.resolveGlowColor(for: light)
    }

    static func resolveGlowColor(for light: LightDisplayItem) -> Color {
        if light.supportsColor, let x = light.colorX, let y = light.colorY {
            return HueColorUtils.color(fromX: x, y: y, brightness: max(light.brightness, 50))
        }
        if light.supportsColorTemp, let mirek = light.colorTempMirek {
            return HueColorUtils.color(fromMirek: mirek)
        }
        return Color(red: 1.0, green: 0.76, blue: 0.2)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // ── Card content (NavigationLink in normal mode, plain tap in select mode) ──
            if isSelecting {
                Button { onToggleSelect() } label: { cardContent }
                    .buttonStyle(.plain)
            } else {
                NavigationLink(value: light) { cardContent }
                    .buttonStyle(.plain)
                    .onLongPressGesture(minimumDuration: 0.45) { onLongPress() }
            }

            // ── Checkbox overlay (top-leading, animated in/out) ──────────────────────
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(isSelected ? glowColor : .white.opacity(0.35))
                    .padding(14)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                    .animation(.spring(response: 0.3), value: isSelected)
            }
        }
        // ── Power button (hidden in select mode) ────────────────────────────────────
        .overlay(alignment: .topTrailing) {
            if !isSelecting {
                Button {
                    HapticManager.shared.light()
                    localIsOn.toggle()
                    onToggle(localIsOn)
                } label: {
                    Image(systemName: localIsOn ? "power.circle.fill" : "power.circle")
                        .font(.system(size: 22))
                        .foregroundStyle(localIsOn ? glowColor : .white.opacity(0.35))
                        .frame(width: 52, height: 52)
                        .contentShape(Rectangle())
                        .symbolEffect(.bounce, value: localIsOn)
                }
                .buttonStyle(.plain)
                .padding(.top, 18)
                .padding(.trailing, 14)
                .accessibilityLabel(Text("Turn \(light.name) \(localIsOn ? "off" : "on")"))
                .accessibilityHint(Text(localIsOn ? "Tap to turn off" : "Tap to turn on"))
            }
        }
        .frame(minHeight: 80)
        .opacity(isSelecting ? (isSelected ? 1.0 : 0.58) : (localIsOn ? 1.0 : 0.72))
        .scaleEffect(localIsOn && !isSelecting ? 1.0 : 0.982)
        .animation(.spring(response: 0.35, dampingFraction: 0.72), value: localIsOn)
        .animation(.spring(response: 0.3), value: isSelecting)
        .animation(.spring(response: 0.25), value: isSelected)
        .onChange(of: light.isOn) { _, confirmed in
            if localIsOn != confirmed {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) { localIsOn = confirmed }
            }
        }
    }

    private var cardContent: some View {
        GlassmorphicCard(isActive: localIsOn, glowColor: glowColor) {
            VStack(spacing: 0) {
                lightHeaderContent
                if localIsOn && !isSelecting {
                    BrightnessRow(
                        brightness: light.brightness,
                        glowColor:  glowColor,
                        onCommit:   { onBrightness($0) }
                    )
                    .padding(.top, 6)
                }
            }
        }
    }

    private var lightHeaderContent: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(localIsOn ? glowColor.opacity(0.22) : Color.white.opacity(0.07))
                    .frame(width: 44, height: 44)
                Image(systemName: archetypeIcon(for: light.archetype))
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(localIsOn ? glowColor : .white.opacity(0.4))
                    .symbolEffect(.bounce, value: localIsOn)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(light.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(localIsOn ? "\(Int(light.brightness))%" : "Off")
                    .font(.caption)
                    .foregroundStyle(localIsOn ? glowColor.opacity(0.8) : .white.opacity(0.40))
            }
            Spacer()
            // Reserve space for power button overlay in normal mode
            if !isSelecting { Spacer().frame(width: 44) }
        }
    }
}

// MARK: - CompactLightCard
//
// Narrower card for the horizontal lights strip.
// Shows: icon circle + name + brightness% + power button.
// Tap = NavigationLink to LightControlView; long-press = enter select mode.

struct CompactLightCard: View {

    let light:          LightDisplayItem
    let isSelecting:    Bool
    let isSelected:     Bool
    let onToggle:       (Bool)   -> Void
    let onToggleSelect: ()       -> Void
    let onLongPress:    ()       -> Void

    @State private var localIsOn: Bool

    init(
        light:          LightDisplayItem,
        isSelecting:    Bool             = false,
        isSelected:     Bool             = false,
        onToggle:       @escaping (Bool)   -> Void,
        onToggleSelect: @escaping ()       -> Void = {},
        onLongPress:    @escaping ()       -> Void = {}
    ) {
        self.light          = light
        self.isSelecting    = isSelecting
        self.isSelected     = isSelected
        self.onToggle       = onToggle
        self.onToggleSelect = onToggleSelect
        self.onLongPress    = onLongPress
        _localIsOn          = State(initialValue: light.isOn)
    }

    /// Glow color computed directly from light — always current, no @State lag.
    private var glowColor: Color {
        LightCard.resolveGlowColor(for: light)
    }

    var body: some View {
        let content = VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(localIsOn ? glowColor.opacity(0.22) : Color.white.opacity(0.07))
                    .frame(width: 44, height: 44)
                Image(systemName: archetypeIcon(for: light.archetype))
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(localIsOn ? glowColor : .white.opacity(0.4))
                    .symbolEffect(.bounce, value: localIsOn)
            }

            Text(light.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text(localIsOn ? "\(Int(light.brightness))%" : "Off")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(localIsOn ? glowColor.opacity(0.8) : .white.opacity(0.40))

            Button {
                HapticManager.shared.light()
                localIsOn.toggle()
                onToggle(localIsOn)
            } label: {
                Image(systemName: localIsOn ? "power.circle.fill" : "power.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(localIsOn ? glowColor : .white.opacity(0.35))
                    .symbolEffect(.bounce, value: localIsOn)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 110)
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        .background {
            RoundedRectangle(cornerRadius: 18)
                .fill(localIsOn ? glowColor.opacity(0.10) : Color.white.opacity(0.06))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(
                    isSelecting && isSelected
                        ? glowColor.opacity(0.70)
                        : localIsOn
                            ? glowColor.opacity(0.40)
                            : Color.white.opacity(0.08),
                    lineWidth: isSelecting && isSelected ? 2 : (localIsOn ? 1.5 : 1)
                )
        }
        .shadow(
            color: localIsOn ? glowColor.opacity(0.25) : .clear,
            radius: 10, x: 0, y: 4
        )

        Group {
            if isSelecting {
                Button { onToggleSelect() } label: { content }
                    .buttonStyle(.plain)
            } else {
                NavigationLink(value: light) { content }
                    .buttonStyle(.plain)
                    .onLongPressGesture(minimumDuration: 0.45) { onLongPress() }
            }
        }
        .opacity(isSelecting ? (isSelected ? 1.0 : 0.58) : (localIsOn ? 1.0 : 0.55))
        .animation(.spring(response: 0.35, dampingFraction: 0.72), value: localIsOn)
        .animation(.spring(response: 0.3), value: isSelecting)
        .animation(.spring(response: 0.25), value: isSelected)
        .onChange(of: light.isOn) { _, confirmed in
            if localIsOn != confirmed {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) { localIsOn = confirmed }
            }
        }
    }
}


// MARK: - Ambient Background (isolated — zero @Observable dependencies)

/// Same reasoning as DashboardAmbientBackground: extracting the blur-orb
/// background into its own View struct prevents vm.lights / vm.scenes
/// changes from triggering repeated CoreImage blur passes.
private struct RoomDetailAmbientBackground: View {
    var body: some View {
        ZStack {
            Color(red: 0.055, green: 0.055, blue: 0.08).ignoresSafeArea()
            Circle()
                .fill(RadialGradient(
                    colors: [Color(red: 1, green: 0.75, blue: 0.2).opacity(0.18), .clear],
                    center: .center, startRadius: 0, endRadius: 200
                ))
                .frame(width: 340)
                .offset(x: 80, y: -160)
                .blur(radius: 20)
            Circle()
                .fill(RadialGradient(
                    colors: [Color(red: 0.4, green: 0.3, blue: 1).opacity(0.14), .clear],
                    center: .center, startRadius: 0, endRadius: 160
                ))
                .frame(width: 260)
                .offset(x: -100, y: 120)
                .blur(radius: 20)
        }
        .ignoresSafeArea()
        .drawingGroup()   // rasterizes into a single Metal texture after first render
    }
}
