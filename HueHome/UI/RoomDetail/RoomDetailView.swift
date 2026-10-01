// RoomDetailView.swift
// ChromaGlow — Room (Luminous).
//
// A room is a stage. The hero is the Composer's stage painter fed with what
// the lamps are doing right now (tap a lamp to open it); under it the room's
// name, its power and brightness, then three views of the room —
// Lights · Scenes · Looks — the way the Composer has Looks · Tune · Layers.
// The background glows in the colours the room's lamps are showing.
//
// Contracts kept from the previous Room screen:
//   • `.task` replaces the placeholder VM with one seeded from the
//     orchestrator's light cache; a fresh seed (< 30 s) skips the refetch;
//     ONE SSE subscriber is held for the view's lifetime; colour commits
//     refresh the dashboard glows; scene edits reload the global list.
//   • Paint mode is sticky (Done pill / re-tap the armed swatch / leave the
//     room) and excludes select mode.
//   • Guest gates: power (canPower), brightness/colour/moods/My Colors
//     (canAdjust), scenes (canRecallScenes), every create/edit/delete and
//     multi-select (never on a granted bridge). No Looks on a guest-only
//     shell or a granted bridge (the Composer isn't part of shared access).
//   • Light writes go through the view model, which owns optimistic state
//     and rollback.

import SwiftUI

// MARK: - RoomDetailView

struct RoomDetailView: View {

    /// The three views of a room.
    enum Segment: String, CaseIterable, Hashable {
        case lights, scenes, looks

        var title: String {
            switch self {
            case .lights: return "Lights"
            case .scenes: return "Scenes"
            case .looks:  return "Looks"
            }
        }

        var symbol: String {
            switch self {
            case .lights: return "lightbulb.2.fill"
            case .scenes: return "swatchpalette.fill"
            case .looks:  return "sparkles"
            }
        }
    }

    let room: RoomDisplayItem
    @State private var vm: RoomDetailViewModel
    @State private var segment: Segment
    @State private var showLog           = false
    @State private var showCreateScene   = false
    @State private var showBulkScene     = false   // builder from the bulk dock
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
        // Order-preserving toggle — the Dashboard renders favourites in
        // stored order.
        favoriteSceneIDsRaw = FavoriteSceneCSV.toggled(favoriteSceneIDsRaw, id: scene.id)
    }

    // ── Room / Zone CRUD ──────────────────────────────────────────────────────
    @State private var showEditSheet     = false
    @State private var showDeleteConfirm = false

    /// Saved swatch armed for tap-to-apply — non-nil turns light tiles (and
    /// the stage's lamps) into paint targets.
    @State private var armedColor: SavedColor? = nil
    /// Light tile a swatch drag is currently hovering (drop-target ring).
    @State private var dropTargetLightID: String? = nil
    /// A lamp tapped on the stage — pushes its control.
    @State private var stageLight: LightDisplayItem? = nil
    /// The room brightness slider's drag state (commits once on release).
    @State private var roomLevel: Double
    @State private var draggingRoomLevel = false

    @Environment(UnifiedOrchestrator.self) private var orchestrator
    @Environment(\.dismiss)               private var dismiss

    // ── Family Sharing gates ──────────────────────────────────────────────────
    /// What a guest grant allows on this room's bridge (.unrestricted for
    /// the owner's own bridges and demo mode).
    private var guestFeatures: GuestFeatureSet { orchestrator.guestFeatures(for: room.bridgeID) }
    /// Granted bridges never offer creation/edit surfaces (scenes,
    /// automations) regardless of features.
    private var isGrantedBridge: Bool { orchestrator.isGuestGrantedBridge(room.bridgeID) }
    /// A guest-only device has no Composer (its tabs are hidden).
    private var isGuestOnlyShell: Bool { orchestrator.guestAccessInfo.isGuestOnly && !orchestrator.isDemoMode }

    init(room: RoomDisplayItem, initialSegment: Segment = .lights) {
        self.room = room
        // Placeholder VM — replaced in .task with one that has the bridge
        // client, the demo flag, the seeded cache and the pacing gate.
        _vm = State(initialValue: RoomDetailViewModel(room: room))
        _segment = State(initialValue: initialSegment)
        _roomLevel = State(initialValue: max(1, room.brightness))
    }

    /// The room as the orchestrator knows it now (a rename lands here); the
    /// pushed snapshot is the fallback.
    private var liveRoom: RoomDisplayItem {
        (orchestrator.allRooms + orchestrator.allZones).first { $0.id == room.id } ?? room
    }

    /// What is playing in this room right now, if anything.
    private var liveEntry: ActiveEffectEntry? {
        orchestrator.activeEffectEntries.last { $0.roomID == room.id }
    }

    /// The colour the room is showing — the same dominant colour its Home
    /// card glows in, so the two screens agree.
    private var roomColor: Color { liveRoom.luminousColor }

    /// The lamps as the stage draws them: an off lamp has no colour, so it
    /// is drawn as neutral dark glass rather than tinted by its last colour.
    private var stageLights: [LightDisplayItem] {
        vm.lights.map { light in
            guard !light.isOn else { return light }
            var dark = light
            dark.colorTempMirek = nil
            dark.colorX = 0.3127
            dark.colorY = 0.3290
            return dark
        }
    }

    private var ambienceColors: [Color] {
        let lit = LuminousLight.palette(of: vm.lights, max: 3)
        return lit.isEmpty ? [LuminousPalette.night] : lit
    }

    // ── Segments ──────────────────────────────────────────────────────────────

    private var showsScenesSegment: Bool {
        guestFeatures.canAdjust || guestFeatures.canRecallScenes || (!isGrantedBridge && !vm.automations.isEmpty)
    }

    private var showsLooksSegment: Bool { !isGuestOnlyShell && !isGrantedBridge }

    private var segments: [Segment] {
        var out: [Segment] = [.lights]
        if showsScenesSegment { out.append(.scenes) }
        if showsLooksSegment { out.append(.looks) }
        return out
    }

    /// The segment on screen — falls back to Lights when the chosen one isn't
    /// offered here (a guest shell never shows Looks).
    private var activeSegment: Segment {
        segments.contains(segment) ? segment : .lights
    }

    // MARK: - Body

    var body: some View {
        Group {
            if vm.isLoading && vm.lights.isEmpty {
                loadingView
            } else if let error = vm.errorMessage, vm.lights.isEmpty {
                errorView(error)
            } else {
                scrollContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { LuminousAmbience(colors: ambienceColors) }
        // Contextual docks float above the tab bar and inset the scroll
        // content, so the last tiles are never hidden behind them.
        .safeAreaInset(edge: .bottom, spacing: 0) { docks }
        .animation(.spring(response: 0.35, dampingFraction: 0.78), value: vm.isSelecting)
        .animation(.spring(response: 0.35, dampingFraction: 0.78), value: vm.isSelectingScenes)
        .luminousNavigationChrome()
        .toolbar { toolbarItems }
        .navigationDestination(for: LightDisplayItem.self) { light in
            lightDestination(light)
        }
        .navigationDestination(item: $stageLight) { light in
            lightDestination(light)
        }
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
        // Builder launched from the bulk dock — pre-filtered to the selection.
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
        // Builder launched to edit an existing scene.
        .sheet(item: $sceneToEdit) { scene in
            SceneColorBuilderView(
                roomID: room.id,
                roomRType: room.kind == .zone ? "zone" : "room",
                bridgeID: room.bridgeID ?? "",
                existingSceneID: scene.id,
                existingSceneName: scene.name,
                // Live lights (capabilities + fallback for lights the scene
                // doesn't name). The builder overwrites each light from the
                // scene's own stored actions before anything is editable.
                initialLights: vm.lights
            ) {
                Task { await vm.loadScenes() }
            }
        }
        // ── Edit Room / Zone sheet ─────────────────────────────────────────────
        .sheet(isPresented: $showEditSheet) {
            EditRoomSheet(room: liveRoom, isZone: room.kind == .zone) { newName, newArchetype in
                Task {
                    if room.kind == .zone {
                        await orchestrator.renameZone(room, name: newName, archetype: newArchetype)
                    } else {
                        await orchestrator.renameRoom(room, name: newName, archetype: newArchetype)
                    }
                }
            }
        }
        // ── Delete Room / Zone ────────────────────────────────────────────────
        .confirmationDialog(
            room.kind == .zone ? "Delete \(liveRoom.name)?" : "Delete \(liveRoom.name)?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(room.kind == .zone ? "Delete Zone" : "Delete Room", role: .destructive) {
                Task {
                    if room.kind == .zone {
                        await orchestrator.deleteZone(room)
                    } else {
                        await orchestrator.deleteRoom(room)
                    }
                    await MainActor.run { dismiss() }   // back to Home
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes \"\(liveRoom.name)\" from your bridge.")
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
        .task {
            let seed = orchestrator.cachedLightItems(for: room)
            // Rebuild the VM with the right bridge client now that the
            // orchestrator is available. Every call below goes to THIS model.
            let model = RoomDetailViewModel(
                room: room,
                api: orchestrator.hueClient(for: room.bridgeID),
                isDemoMode: orchestrator.isDemoMode,
                initialLights: seed,
                // Bulk (multi-select) writes share the bridge's pacing gate
                // with every other bulk writer (M-08).
                commandGate: orchestrator.commandGate(for: room.bridgeID)
            )
            vm = model
            // Colour changes propagate to the Home cards' glows.
            let bridgeID = room.bridgeID ?? ""
            model.onColorCommitted = { [weak orchestrator] in
                guard let orchestrator, !bridgeID.isEmpty else { return }
                orchestrator.refreshDominantColors(for: bridgeID)
            }
            // Scene renames/deletes made here must reach the global list
            // (Scenes tab, Home favourites, widgets/watch/Siri publish).
            model.onScenesChanged = { [weak orchestrator] in
                guard let orchestrator else { return }
                Task { await orchestrator.loadAllScenes() }
            }
            // The seed came from the same fetchLights that loadAll ran moments
            // ago — a re-fetch would return identical data and queue behind the
            // post-pairing storm on rate-limited bridges. SSE (subscribed
            // below) keeps the seeded list live; a stale or empty seed refetches.
            let seedIsFresh = !seed.isEmpty
                && Date().timeIntervalSince(orchestrator.lastLoadedAt) < 30

            // SSE runs forever, so it must NOT block the group of finite loads.
            async let sse: Void = model.runSSE(eventStream: orchestrator.subscribeToLightEvents())
            await withTaskGroup(of: Void.self) { group in
                if !seedIsFresh { group.addTask { await model.loadLights() } }
                group.addTask { await model.loadScenes() }
                group.addTask { await model.loadAutomations() }
            }
            // Room-level state after the lights (it cross-checks them).
            await model.loadRoomState()
            // Hold the SSE child for the view's lifetime: an async let that is
            // never awaited is CANCELLED when this scope exits. `.task`
            // cancellation (the view going away) still ends it.
            await sse
        }
        .onChange(of: vm.roomBrightness) { _, new in
            if !draggingRoomLevel { roomLevel = max(1, new) }
        }
        .preferredColorScheme(.dark)
        .overlay(alignment: .top) {
            if let msg = vm.toastMessage {
                LuminousToastCapsule(text: msg)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
                    .zIndex(10)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: vm.toastMessage)
    }

    // MARK: - Scroll content

    private var scrollContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                hero
                titleBlock
                powerPanel
                if segments.count > 1 {
                    LuminousSegmented(options: segments,
                                      selection: $segment,
                                      title: { $0.title },
                                      symbol: { $0.symbol },
                                      accessibilityLabel: "\(liveRoom.name) sections")
                }
                segmentContent
                    .id(activeSegment)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 12)), removal: .opacity))
            }
            .padding(.horizontal, HueSpacing.screenH)
            .padding(.top, 4)
            .padding(.bottom, 28)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: activeSegment)
        }
        .scrollIndicators(.hidden)
        .refreshable {
            await vm.loadLights()
            await vm.loadRoomState()
            await vm.loadAutomations()
        }
    }

    // MARK: - Hero

    private var hero: some View {
        LuminousRoomStage(lights: stageLights,
                          isLive: liveEntry != nil,
                          height: 220,
                          badge: AnyView(heroBadges),
                          onTapLight: tapLamp)
    }

    private var heroBadges: some View {
        HStack(spacing: 6) {
            if let entry = liveEntry {
                LuminousLiveBadge(state: .live)
                LuminousFactBadge(text: entry.effectName, symbol: entry.effectIcon)
            }
            Spacer(minLength: 0)
            LuminousFactBadge(text: "\(vm.lights.count) light\(vm.lights.count == 1 ? "" : "s")",
                              symbol: "lightbulb.fill")
        }
    }

    /// A lamp tapped on the stage: paints it while a colour is armed, picks it
    /// in select mode, otherwise opens it.
    private func tapLamp(_ tapped: LightDisplayItem) {
        // The stage draws display copies (off lamps neutralised) — act on the
        // real lamp, whose capabilities decide how a colour applies.
        let light = vm.lights.first { $0.id == tapped.id } ?? tapped
        if let armed = armedColor {
            applySavedColor(armed, to: light)
        } else if vm.isSelecting {
            vm.toggleSelection(id: light.id)
        } else {
            stageLight = light
        }
    }

    // MARK: - Title & power

    private var titleBlock: some View {
        let onCount = vm.lights.filter(\.isOn).count
        let total = vm.lights.count
        var subtitle: String
        if total == 0 {
            subtitle = "No lights here yet"
        } else if onCount == 0 {
            subtitle = total == 1 ? "The light is off" : "All \(total) lights off"
        } else {
            subtitle = "\(onCount) of \(total) on · \(BrightnessDisplay.percent(vm.roomBrightness))%"
        }
        if orchestrator.isDemoMode { subtitle += " · Demo home" }
        return LuminousScreenTitle(title: liveRoom.name,
                                   eyebrow: room.kind == .zone ? "Zone" : "Room",
                                   eyebrowSymbol: archetypeIcon(for: liveRoom.archetype),
                                   eyebrowTint: vm.roomIsOn ? roomColor : LuminousPalette.inkSecondary,
                                   subtitle: subtitle)
    }

    @ViewBuilder
    private var powerPanel: some View {
        if guestFeatures.canPower || guestFeatures.canAdjust {
            HStack(spacing: 14) {
                // Room power — hidden without the onOff grant.
                if guestFeatures.canPower {
                    LuminousPowerButton(isOn: vm.roomIsOn, tint: roomColor, size: 52,
                                        label: "Turn \(liveRoom.name) \(vm.roomIsOn ? "off" : "on")") {
                        HapticManager.shared.medium()
                        vm.toggleRoom(on: !vm.roomIsOn)
                    }
                }
                // Room brightness — hidden without the brightness grant.
                if vm.roomIsOn && guestFeatures.canAdjust {
                    LuminousGlowSlider(title: "Brightness",
                                       symbol: "sun.max.fill",
                                       value: $roomLevel,
                                       range: 1...100,
                                       colors: [roomColor.opacity(0.5), roomColor],
                                       format: { "\(BrightnessDisplay.percent($0))%" },
                                       accessibilityName: "\(liveRoom.name) brightness",
                                       onEditingChanged: { editing in
                                           draggingRoomLevel = editing
                                           if !editing { vm.setRoomBrightness(roomLevel) }
                                       })
                        .transition(.opacity)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(vm.roomIsOn ? "On" : "Off")
                            .font(LuminousType.cardTitle)
                            .foregroundStyle(LuminousPalette.ink)
                        Text(powerHint)
                            .font(.footnote)
                            .foregroundStyle(LuminousPalette.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(14)
            .luminousPanel(glow: vm.roomIsOn ? roomColor : nil,
                           glowStrength: vm.roomIsOn ? 0.3 + 0.7 * (vm.roomBrightness / 100) : 0)
            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: vm.roomIsOn)
        }
    }

    private var powerHint: String {
        if !guestFeatures.canPower { return "Power isn't part of your shared access." }
        if vm.roomIsOn { return "Brightness isn't part of your shared access." }
        return "Tap the power button to light the room."
    }

    // MARK: - Segments

    @ViewBuilder
    private var segmentContent: some View {
        switch activeSegment {
        case .lights: lightsSegment
        case .scenes: scenesSegment
        case .looks:  ComposerRoomLooks(room: liveRoom)
        }
    }

    // ── Lights ────────────────────────────────────────────────────────────────

    private var lightsSegment: some View {
        VStack(alignment: .leading, spacing: 16) {
            // My Colors (saved palette → tap a light to apply).
            if !SavedColorStore.shared.colors.isEmpty && guestFeatures.canAdjust {
                myColorsSection
            }
            LuminousSectionHeader(title: "Lights", subtitle: lightsSubtitle) {
                lightsHeaderAction
            }
            if vm.lights.isEmpty {
                LuminousEmptyState(symbol: "lightbulb", title: "No lights here yet",
                                   message: "Pull down to refresh once lights are added to this room.")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(vm.lights, id: \.id) { light in
                        lightTile(light)
                    }
                }
            }
        }
    }

    private var lightsSubtitle: String {
        if armedColor != nil { return "Tap a light to paint it." }
        if vm.isSelecting { return "Choose lights to change together." }
        return "Tap a light for color and warmth. Hold one for more."
    }

    @ViewBuilder
    private var lightsHeaderAction: some View {
        if let armed = armedColor {
            // Paint mode swaps in for Select (same row — no layout shift).
            paintModePill(for: armed)
        } else if !isGrantedBridge {
            // Multi-select exists to bulk-edit and save scenes — owner surface.
            LuminousTextPill(title: vm.isSelecting ? "Done" : "Select",
                             symbol: vm.isSelecting ? nil : "checklist",
                             tint: LuminousPalette.cyan,
                             active: vm.isSelecting) {
                if vm.isSelecting { vm.exitSelectMode() } else { vm.enterSelectMode() }
            }
        }
    }

    private func lightTile(_ light: LightDisplayItem) -> some View {
        let isSelected = vm.selectedLightIDs.contains(light.id)
        return RoomLightTile(
            light: light,
            isSelecting: vm.isSelecting,
            isSelected: isSelected,
            showsPowerToggle: guestFeatures.canPower,
            onToggle: { desiredOn in vm.setLight(light, isOn: desiredOn) },
            onToggleSelect: { vm.toggleSelection(id: light.id) }
        )
        // Armed-swatch paint target: while a My Colors swatch is armed, a tap
        // anywhere on the tile applies it (over the tile's own controls).
        .overlay {
            if let armed = armedColor {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(armed.displayColor.opacity(0.9), lineWidth: 2)
                    .background(RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(armed.displayColor.opacity(0.08)))
                    .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .onTapGesture { applySavedColor(armed, to: light) }
                    .transition(.opacity)
                    .accessibilityElement()
                    .accessibilityLabel("Paint \(light.name)")
                    .accessibilityAddTraits(.isButton)
            }
        }
        // Drop target for a dragged My Colors swatch.
        .overlay {
            if dropTargetLightID == light.id {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(LuminousPalette.cyan, lineWidth: 2.5)
                    .shadow(color: LuminousPalette.cyan.opacity(0.6), radius: 8)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: SavedColor.self) { items, _ in
            guard let saved = items.first else { return false }
            applySavedColor(saved, to: light)
            return true
        } isTargeted: { targeting in
            if targeting {
                dropTargetLightID = light.id
            } else if dropTargetLightID == light.id {
                dropTargetLightID = nil
            }
        }
        .contextMenu { lightContextMenu(for: light) }
    }

    /// Tap a swatch to ARM it, then tap any light to apply — the same
    /// select-then-paint model as the scene builder. Tapping the armed swatch
    /// again disarms.
    private var myColorsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                LuminousEyebrow(text: "My Colors")
                Spacer()
                if armedColor != nil {
                    Text("Tap a light to apply")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LuminousPalette.amber)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 16)
            SavedColorStrip(
                armedColorID: armedColor?.id,
                onTapSwatch: { saved in
                    armPaintMode(with: (armedColor?.id == saved.id) ? nil : saved)
                    HapticManager.shared.light()
                }
            )
        }
        .padding(.vertical, 12)
        .luminousGlass(radius: 20)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: armedColor)
    }

    /// Send an armed swatch to one light, honouring its capabilities
    /// (colour → xy; CT-only → mirek; dimmable → brightness). Brightness rides
    /// along so the saved look reproduces fully.
    private func applySavedColor(_ saved: SavedColor, to light: LightDisplayItem) {
        switch saved.application(
            supportsColor: light.supportsColor,
            supportsColorTemp: light.supportsColorTemp,
            mirekMin: light.mirekMin,
            mirekMax: light.mirekMax
        ) {
        case .color(let x, let y, let brightness):
            vm.setColor(x: x, y: y, for: light)
            vm.setBrightness(brightness, for: light)
        case .colorTemp(let mirek, let brightness):
            vm.setColorTemp(mirek: mirek, for: light)
            vm.setBrightness(brightness, for: light)
        case .brightnessOnly(let brightness):
            vm.setBrightness(brightness, for: light)
        }
        HapticManager.shared.success()
        // Deliberately stays armed: an armed colour paints until the person
        // says Done (paint pill / tap the armed swatch / leave the room).
    }

    /// Armed-state chrome in the Lights header: the swatch, "Painting", Done.
    private func paintModePill(for armed: SavedColor) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(armed.displayColor)
                .frame(width: 14, height: 14)
                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                .shadow(color: armed.displayColor.opacity(0.8), radius: 5)
            Text("Painting")
                .font(.footnote.weight(.bold))
                .foregroundStyle(LuminousPalette.amber)
            LuminousTextPill(title: "Done", tint: LuminousPalette.amber, active: true) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    armedColor = nil
                }
            }
        }
        .transition(.opacity)
        .accessibilityElement(children: .contain)
    }

    /// Arm a colour for paint mode. Select mode and paint mode are mutually
    /// exclusive — an armed overlay would fight the selection buttons for the
    /// same taps.
    private func armPaintMode(with color: SavedColor?) {
        if vm.isSelecting { vm.exitSelectMode() }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            armedColor = color
        }
    }

    /// Long-press menu on a light tile. Copy/Save hide (rather than no-op) on
    /// dimmable-only lights, where there is no colour to capture; Paste hides
    /// until something has been copied.
    @ViewBuilder
    private func lightContextMenu(for light: LightDisplayItem) -> some View {
        if let captured = ColorClipboard.capture(from: light) {
            Button {
                // Copy arms paint mode immediately — tap lights to paste. The
                // clipboard is app-wide, so the menu Paste also works in any
                // other room until something else is copied.
                ColorClipboard.shared.copy(captured)
                armPaintMode(with: captured)
                HapticManager.shared.light()
            } label: {
                Label("Copy Color", systemImage: "eyedropper")
            }
        }
        if let copied = ColorClipboard.shared.copied {
            Button {
                applySavedColor(copied, to: light)   // one-off, no arming
            } label: {
                Label("Paste Color", systemImage: "paintbrush.fill")
            }
        }
        if let captured = ColorClipboard.capture(from: light) {
            Button {
                SavedColorStore.shared.add(captured)
                HapticManager.shared.success()
            } label: {
                Label("Save to My Colors", systemImage: "paintpalette")
            }
        }
        Divider()
        Button {
            Task {
                await SignalingService(orchestrator: orchestrator)
                    .identifyLight(id: light.id, bridgeID: room.bridgeID)
            }
        } label: {
            Label("Identify", systemImage: "rays")
        }
        // Multi-select exists to bulk-edit and save scenes — owner surface,
        // same gate as the Lights header's Select button.
        if !vm.isSelecting && !isGrantedBridge {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    armedColor = nil   // paint mode and select mode are exclusive
                }
                vm.enterSelectMode(preselecting: light.id)
            } label: {
                Label("Select Lights", systemImage: "checklist")
            }
        }
    }

    // ── Scenes ────────────────────────────────────────────────────────────────

    private var scenesSegment: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Moods recolour + re-dim THIS room: adjust-level access.
            if guestFeatures.canAdjust {
                moodsRow
            }
            if (!vm.scenes.isEmpty || !vm.lights.isEmpty) && guestFeatures.canRecallScenes {
                scenesSection
            }
            // Schedules write bridge behaviours — owner surface only.
            if !vm.automations.isEmpty && !isGrantedBridge {
                schedulesSection
            }
        }
    }

    /// The same four moods as Home, scoped: Energize here lights THIS room.
    private var moodsRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            LuminousSectionHeader(title: "Moods", subtitle: "For this room only.")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(LightingPreset.all) { preset in
                        HomeMoodTile(title: preset.name,
                                     symbol: preset.icon,
                                     detail: "\(BrightnessDisplay.percent(preset.brightness))% · \(HueColorUtils.kelvin(from: preset.mirek))K",
                                     colors: [preset.luminousColor],
                                     level: preset.brightness / 100) {
                            HapticManager.shared.light()
                            vm.applyPreset(preset)
                        }
                        .accessibilityLabel("\(preset.name), this room only")
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollClipDisabled()
        }
    }

    private var scenesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LuminousSectionHeader(title: "Scenes",
                                  subtitle: vm.scenes.isEmpty
                                    ? "Save how this room looks and it's one tap away."
                                    : "\(vm.scenes.count) saved for this room.") {
                HStack(spacing: 6) {
                    // Select / Done for scene multi-select (bulk delete/edit —
                    // never on a granted bridge: guests recall, they don't edit).
                    if vm.scenes.count > 1 && !isGrantedBridge {
                        LuminousTextPill(title: vm.isSelectingScenes ? "Done" : "Select",
                                         tint: LuminousPalette.cyan,
                                         active: vm.isSelectingScenes) {
                            if vm.isSelectingScenes { vm.exitSceneSelectMode() } else { vm.enterSceneSelectMode() }
                        }
                    }
                    if !vm.isSelectingScenes && !isGrantedBridge {
                        LuminousTextPill(title: "New", symbol: "plus", tint: LuminousPalette.cyan) {
                            showCreateScene = true
                        }
                        .accessibilityLabel("New scene")
                    }
                }
            }
            if !vm.scenes.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(vm.scenes) { scene in
                        sceneTile(scene)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sceneTile(_ scene: SceneDisplayItem) -> some View {
        let isSelected = vm.selectedSceneIDs.contains(scene.id)
        let isFav = favoriteSceneIDs.contains(scene.id)
        Group {
            if vm.isSelectingScenes {
                // Select mode: tap toggles the selection.
                Button {
                    vm.toggleSceneSelection(id: scene.id)
                } label: {
                    RoomSceneTile(scene: scene, isActivating: false, isFavorite: false) { /* no-op in select mode */ }
                        .allowsHitTesting(false)
                }
                .buttonStyle(.plain)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(isSelected ? LuminousPalette.cyan : LuminousPalette.inkTertiary)
                        .padding(8)
                        .allowsHitTesting(false)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            } else {
                // Normal mode: tap recalls the scene.
                RoomSceneTile(scene: scene,
                              isActivating: vm.activatingSceneID == scene.id,
                              isFavorite: isFav) {
                    vm.activateScene(scene)
                }
                .contextMenu {
                    // Edit/Rename/Delete write the owner's bridge scenes —
                    // never offered on a granted bridge. Favourite is local.
                    if !isGrantedBridge {
                        Button {
                            // Recall the scene so the room previews it, then
                            // open the builder — which seeds from the scene's
                            // own stored actions.
                            vm.activateScene(scene)
                            sceneToEdit = scene
                        } label: {
                            Label("Edit Scene", systemImage: "slider.horizontal.3")
                        }
                    }
                    Button {
                        toggleFavorite(scene)
                    } label: {
                        Label(isFav ? "Unfavorite" : "Favorite",
                              systemImage: isFav ? "star.slash" : "star")
                    }
                    if !isGrantedBridge {
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
            }
        }
        .opacity(vm.isSelectingScenes ? (isSelected ? 1.0 : 0.55) : 1.0)
        .animation(.spring(response: 0.25), value: isSelected)
        .animation(.spring(response: 0.3), value: vm.isSelectingScenes)
    }

    private var schedulesSection: some View {
        LuminousGroup(title: "Schedules for this room") {
            ForEach(Array(vm.automations.enumerated()), id: \.element.id) { idx, item in
                AutomationRow(item: item, iconColor: automationIconColor(item.category)) {
                    vm.toggleAutomation(item)
                }
                .padding(.horizontal, 14)
                if idx < vm.automations.count - 1 {
                    LuminousRowDivider(inset: 16)
                }
            }
        }
    }

    private func automationIconColor(_ category: AutomationDisplayItem.AutomationCategory) -> Color {
        switch category.color {
        case "orange":  return .orange
        case "indigo":  return .indigo
        case "yellow":  return LuminousPalette.amber
        case "blue":    return Color(red: 0.4, green: 0.6, blue: 1.0)
        case "teal":    return .teal
        case "purple":  return LuminousPalette.violet
        default:        return LuminousPalette.amber
        }
    }

    // MARK: - Docks

    @ViewBuilder
    private var docks: some View {
        VStack(spacing: 8) {
            if vm.isSelecting {
                // The bulk "Scene" button creates a bridge scene — owner only.
                BulkActionBar(vm: vm) { if !isGrantedBridge { showBulkScene = true } }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            // Never on a granted bridge: guests can't edit scenes.
            if vm.isSelectingScenes && !isGrantedBridge {
                SceneEditBar(vm: vm) { scene in
                    // Edit: recall the scene as a live preview, then open the
                    // builder (it seeds from the scene's stored actions).
                    vm.activateScene(scene)
                    vm.exitSceneSelectMode()
                    sceneToEdit = scene
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, vm.isSelecting || vm.isSelectingScenes ? 8 : 0)
    }

    // MARK: - Light destination

    @ViewBuilder
    private func lightDestination(_ light: LightDisplayItem) -> some View {
        if let binding = vm.lightBinding(for: light) {
            if guestFeatures.canAdjust {
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
            } else {
                // Guest without the brightness grant: the full control surface
                // (wheel, sliders) would be dishonest — status and, when
                // granted, power only.
                guestLightSummary(binding.wrappedValue)
            }
        }
    }

    private func guestLightSummary(_ light: LightDisplayItem) -> some View {
        let color = LuminousLight.color(of: light)
        return ScrollView {
            VStack(spacing: 18) {
                LuminousLampOrb(color: color, level: LuminousLight.level(of: light), size: 64, showsFloor: true)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .luminousStageFrame()
                LuminousScreenTitle(title: light.name,
                                    eyebrow: "Light",
                                    eyebrowSymbol: archetypeIcon(for: light.archetype),
                                    eyebrowTint: light.isOn ? color : LuminousPalette.inkSecondary,
                                    subtitle: light.isOn ? "On · \(BrightnessDisplay.percent(light.brightness))%" : "Off")
                if guestFeatures.canPower {
                    LuminousPrimaryButton(title: light.isOn ? "Turn Off" : "Turn On", symbol: "power") {
                        HapticManager.shared.medium()
                        vm.setLight(light, isOn: !light.isOn)
                    }
                }
                LuminousNotice(text: "Brightness and color aren't part of your shared access.",
                               symbol: "person.2.fill", tint: LuminousPalette.inkSecondary)
            }
            .padding(.horizontal, HueSpacing.screenH)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
        .background { LuminousAmbience(colors: light.isOn ? [color] : [LuminousPalette.night]) }
        .luminousNavigationChrome()
        .preferredColorScheme(.dark)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if vm.isLoading && !vm.lights.isEmpty {
                ProgressView().tint(LuminousPalette.ink)
                    .accessibilityLabel("Refreshing")
            }
            // New Scene / New Schedule — both write the owner's bridge, never
            // on a granted bridge.
            if !vm.isSelecting && !isGrantedBridge {
                Menu {
                    Button {
                        showCreateScene = true
                    } label: {
                        Label("New Scene", systemImage: "camera.aperture")
                    }
                    Button {
                        showCreateAutomation = true
                    } label: {
                        Label("New Schedule", systemImage: "calendar.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add to \(liveRoom.name)")
            }
            Menu {
                // Owner surfaces: never on a granted bridge, and out of the way
                // during multi-select.
                if !vm.isSelecting && !isGrantedBridge {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { armedColor = nil }
                        segment = .lights
                        vm.enterSelectMode()
                    } label: {
                        Label("Select Lights", systemImage: "checklist")
                    }
                    Button {
                        showEditSheet = true
                    } label: {
                        Label(room.kind == .zone ? "Edit Zone" : "Edit Room", systemImage: "pencil")
                    }
                }
                Button {
                    Task {
                        await vm.loadLights()
                        await vm.loadRoomState()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                #if DEBUG
                Button {
                    showLog = true
                } label: {
                    Label("Light Console", systemImage: "terminal")
                }
                #endif
                if !vm.isSelecting && !isGrantedBridge {
                    Divider()
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label(room.kind == .zone ? "Delete Zone…" : "Delete Room…", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("More for \(liveRoom.name)")
        }
    }

    // MARK: - Loading / Error

    private var loadingView: some View {
        VStack(spacing: 18) {
            ProgressView().tint(LuminousPalette.cyan).scaleEffect(1.4)
            Text("Finding the lights in \(liveRoom.name)…")
                .font(.subheadline)
                .foregroundStyle(LuminousPalette.inkSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack {
            LuminousEmptyState(symbol: "exclamationmark.triangle.fill",
                               title: "Couldn't reach this room",
                               message: message,
                               actionTitle: "Try again") {
                Task { await vm.loadLights() }
            }
        }
        .padding(.horizontal, HueSpacing.screenH)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Console Log Sheet

    private var logSheet: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(vm.logLines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(LuminousPalette.ink.opacity(0.8))
                                .id(idx)
                        }
                    }
                    .padding()
                }
                .onChange(of: vm.logLines.count) { _, count in
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
            }
            .background(LuminousPalette.void)
            .navigationTitle("Light Console")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showLog = false }
                        .foregroundStyle(LuminousPalette.cyan)
                }
            }
        }
        .luminousSheet()
    }
}
