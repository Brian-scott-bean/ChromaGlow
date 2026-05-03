// RoomDetailView.swift
// HueHome Pro — Epic 3 / Story 3.1
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
    @State private var sceneToRename:    SceneDisplayItem? = nil
    @State private var sceneRenameDraft: String = ""
    @Environment(UnifiedOrchestrator.self) private var orchestrator

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
        }
        .navigationTitle(room.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar { toolbarItems }
        .sheet(isPresented: $showLog) { logSheet }
        .sheet(isPresented: $showCreateScene) {
            CreateSceneView(lights: vm.lights) { name, selectedLights in
                await vm.createScene(name: name, lights: selectedLights)
            }
        }
        // CreateSceneView launched from BulkActionBar — pre-filtered to selection
        .sheet(isPresented: $showBulkScene) {
            let prefiltered = vm.selectedLights
            CreateSceneView(lights: prefiltered.isEmpty ? vm.lights : prefiltered) { name, selectedLights in
                let success = await vm.createScene(name: name, lights: selectedLights)
                if success { vm.exitSelectMode() }
                return success
            }
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
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await vm.loadLights() }
                group.addTask { await vm.loadScenes() }
                // Subscribe to orchestrator's event bus instead of opening a new SSE
                // connection — eliminates dual-SSE stream to the same bridge.
                group.addTask { await vm.runSSE(eventStream: orchestrator.subscribeToLightEvents()) }
            }
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
                summaryHeader
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 16)

                // ── Scene strip (always shown when lights are loaded) ──
                if !vm.scenes.isEmpty || !vm.lights.isEmpty {
                    scenesStrip
                        .padding(.bottom, 20)
                }

                LazyVStack(spacing: 14) {
                    ForEach(vm.lights, id: \.id) { light in
                        let isSelected = vm.selectedLightIDs.contains(light.id)
                        LightCard(
                            light:          light,
                            isSelecting:    vm.isSelecting,
                            isSelected:     isSelected,
                            onToggle:       { desiredOn in vm.setLight(light, isOn: desiredOn) },
                            onBrightness:   { brightness in vm.setBrightness(brightness, for: light) },
                            onToggleSelect: { vm.toggleSelection(id: light.id) },
                            onLongPress:    { vm.enterSelectMode(preselecting: light.id) }
                        )
                        .padding(.horizontal, 20)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .bottom)),
                            removal: .opacity
                        ))
                    }
                }
                .animation(.spring(response: 0.45, dampingFraction: 0.8), value: vm.lights.count)
                .padding(.bottom, 32)
            }   // VStack
        }       // ScrollView
        .navigationDestination(for: LightDisplayItem.self) { light in
            if let binding = vm.lightBinding(for: light) {
                LightControlView(
                    light: binding,
                    // Read binding.wrappedValue at call time — never a stale snapshot.
                    onToggle:     { desiredOn in vm.setLight(binding.wrappedValue, isOn: desiredOn) },
                    onBrightness: { vm.setBrightness($0, for: binding.wrappedValue) },
                    onColor:      { x, y in vm.setColor(x: x, y: y, for: binding.wrappedValue) },
                    onColorTemp:  { vm.setColorTemp(mirek: $0, for: binding.wrappedValue) }
                )
            }
        }
        .refreshable { await vm.loadLights() }
        .scrollIndicators(.hidden)
    }

    // ── Scene Strip ───────────────────────────────

    private var scenesStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header: label + "＋" button
            HStack {
                Text("SCENES")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
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
            .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(vm.scenes) { scene in
                        RoomSceneChip(
                            scene: scene,
                            isActivating: vm.activatingSceneID == scene.id
                        ) {
                            vm.activateScene(scene)
                        }
                        .contextMenu {
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
                .padding(.horizontal, 20)
                .padding(.vertical, 2)
            }
        }
    }

    // ── Summary Header ────────────────────────────

    private var summaryHeader: some View {
        HStack(alignment: .firstTextBaseline) {
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
            let anyOn = vm.lights.contains { $0.isOn }
            Circle()
                .fill(anyOn ? Color.yellow : Color.white.opacity(0.2))
                .frame(width: 9, height: 9)
                .shadow(color: anyOn ? .yellow.opacity(0.9) : .clear, radius: 8)
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Toolbar
    // ──────────────────────────────────────────────

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
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
        // Select / Done button
        ToolbarItem(placement: .navigationBarTrailing) {
            Button(vm.isSelecting ? "Done" : "Select") {
                if vm.isSelecting { vm.exitSelectMode() } else { vm.enterSelectMode() }
            }
            .font(.system(size: 14, weight: vm.isSelecting ? .semibold : .regular))
            .foregroundStyle(vm.isSelecting
                             ? Color(red: 1.0, green: 0.76, blue: 0.20)
                             : .white.opacity(0.7))
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

    @State private var localIsOn:      Bool
    @State private var localGlowColor: Color

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
        _localGlowColor     = State(initialValue: Self.resolveGlowColor(for: light))
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
                    .foregroundStyle(isSelected ? localGlowColor : .white.opacity(0.35))
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
                        .foregroundStyle(localIsOn ? localGlowColor : .white.opacity(0.35))
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
        .onChange(of: light.colorX) { _, _ in
            withAnimation(.easeInOut(duration: 0.4)) { localGlowColor = Self.resolveGlowColor(for: light) }
        }
        .onChange(of: light.colorTempMirek) { _, _ in
            withAnimation(.easeInOut(duration: 0.4)) { localGlowColor = Self.resolveGlowColor(for: light) }
        }
    }

    private var cardContent: some View {
        GlassmorphicCard(isActive: localIsOn, glowColor: localGlowColor) {
            VStack(spacing: 0) {
                lightHeaderContent
                if localIsOn && !isSelecting {
                    BrightnessRow(
                        brightness: light.brightness,
                        glowColor:  localGlowColor,
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
                    .fill(localIsOn ? localGlowColor.opacity(0.22) : Color.white.opacity(0.07))
                    .frame(width: 44, height: 44)
                Image(systemName: archetypeIcon(for: light.archetype))
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(localIsOn ? localGlowColor : .white.opacity(0.4))
                    .symbolEffect(.bounce, value: localIsOn)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(light.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(localIsOn ? "\(Int(light.brightness))%" : "Off")
                    .font(.caption)
                    .foregroundStyle(localIsOn ? localGlowColor.opacity(0.8) : .white.opacity(0.40))
            }
            Spacer()
            // Reserve space for power button overlay in normal mode
            if !isSelecting { Spacer().frame(width: 44) }
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
