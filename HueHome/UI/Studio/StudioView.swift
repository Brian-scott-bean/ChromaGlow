// StudioView.swift
// CastChroma — v0.17.0 Studio + Composer Deck 3
//
// Layout: Three fixed zones (no root scroll)
//   Zone A: Rolodex room selector (36pt capsule, expands on tap)
//   Zone B: 2-column living card grid (paged: Effects / Live / Composer decks)
//   Zone C: Mixer Tray (springs from bottom when an effect runs)
//
// Performance contract:
//   - Canvas views isolated: receive value types only
//   - Sliders: local @State, commit on drag end
//   - Cards: receive Bool isRunning, never the ViewModel
//   - All colors/spacing/animation via HueTokens

import SwiftUI

// MARK: - StudioView

struct StudioView: View {
    private enum CompositionSaveTransportOption: String, CaseIterable, Identifiable {
        case entertainmentArea
        case roomOnly

        var id: String { rawValue }
        var label: String {
            switch self {
            case .entertainmentArea: return "Entertainment Area"
            case .roomOnly: return "Room Only"
            }
        }

        var subtitle: String {
            switch self {
            case .entertainmentArea: return "Streaming"
            case .roomOnly: return "REST"
            }
        }

        var presetValue: CompositionPreferredTransport {
            switch self {
            case .entertainmentArea: return .entertainmentArea
            case .roomOnly: return .roomOnly
            }
        }

        /// Short titles for segmented controls on narrow widths.
        var segmentTitle: String {
            switch self {
            case .entertainmentArea: return "Streaming"
            case .roomOnly: return "REST"
            }
        }
    }


    private enum CompositionLayerTab: String, CaseIterable, Identifiable, Hashable {
        case palette
        case motion
        case envelope
        case reaction

        var id: String { rawValue }

        var title: String {
            switch self {
            case .palette: return "Palette"
            case .motion: return "Motion"
            case .envelope: return "Envelope"
            case .reaction: return "React"
            }
        }

        var symbolName: String {
            switch self {
            case .palette: return "paintpalette.fill"
            case .motion: return "wind"
            case .envelope: return "chart.xyaxis.line"
            case .reaction: return "mic.fill"
            }
        }
    }

    @Environment(UnifiedOrchestrator.self) private var orchestrator
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var vm = StudioViewModel()
    @State private var showSettings = false

    // ── Room picker ────────────────────────────────────────
    @State private var showRoomSheet = false
    @State private var dragAxisLocked: Axis? = nil
    @State private var dragRoomSteps: Int = 0
    @State private var slideDirection: Edge = .trailing

    // ── Deck paging ───────────────────────────────────────
    @State private var currentDeck: Int = 0  // 0 = Effects, 1 = Live, 2 = Composer

    // ── Composer (Deck 3) ──────────────────────────────────
    @State private var composerCategory: PresetCategory = .all
    @State private var renameCompositionTarget: CompositionPreset?
    @State private var renameCompositionText = ""
    @State private var composerCreateBorderPhase: CGFloat = 0
    @State private var activeCompositionTab: CompositionLayerTab = .palette
    @State private var showCompositionSaveSheet = false
    @State private var compositionSaveName = ""
    @State private var compositionSaveIcon = "sparkles"
    @State private var compositionSaveTransport: CompositionSaveTransportOption = .entertainmentArea
    @State private var isAIPromptExpanded = false
    @State private var aiPromptText = ""
    @State private var isHuePadDragging = false
    @State private var huePadLiveHue: Double = 0
    @State private var huePadLiveSaturation: Double = 1
    @State private var lastHuePadHapticAt: CFAbsoluteTime = 0
    @State private var mixerDragOffset: CGFloat = 0
    @State private var isMixerCollapsed = false
    @State private var showCompositionTransportPrompt = false
    @State private var pendingCompositionCard: StudioCard?
    @State private var pendingCompositionRoom: RoomDisplayItem?
    @State private var transportSwitchInFlightRoomIDs: Set<String> = []
    @State private var compositionDeleteTarget: CompositionPreset?
    @FocusState private var aiPromptFocused: Bool

    // ── Param sheet ───────────────────────────────────────
    @State private var showParamSheet = false

    // ── Performance ───────────────────────────────────────
    @State private var blurReady = false  // deferred to avoid first-frame GPU hitch

    var body: some View {
        GeometryReader { geo in
            let hasCurrentRoomEffect = vm.currentRoomEffect != nil
            let mixerVisible = hasCurrentRoomEffect && !isMixerCollapsed
            let mixerHeight: CGFloat = mixerVisible ? resolvedMixerHeight(proxy: geo) : 0

            ZStack {
                ambientBackground

                if mixerVisible {
                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            hideKeyboard()
                            collapseMixer()
                            HapticManager.shared.light()
                        }
                }

                VStack(spacing: 0) {
                    // ── Zone B: Living Card Grid ──────────────────
                    cardGrid
                        .frame(maxHeight: .infinity)

                    // ── Deck page indicator ───────────────────────
                    deckDots
                        .padding(.bottom, HueSpacing.sm)

                    if hasCurrentRoomEffect && isMixerCollapsed {
                        Button {
                            expandMixer()
                            HapticManager.shared.selection()
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(HuePalette.Noir.success)
                                    .frame(width: 6, height: 6)
                                Text("Live Controls")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.9))
                                Image(systemName: "chevron.up")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(HuePalette.amber.opacity(0.9))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                Capsule().fill(Color.white.opacity(0.10))
                            )
                            .overlay(
                                Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 6)
                    }

                    // Tab bar clearance
                    Color.clear.frame(height: 80)
                }

                if mixerVisible {
                    VStack {
                        Spacer()
                        mixerTray
                            .frame(height: mixerHeight)
                            .offset(y: mixerDragOffset)
                            .gesture(mixerDismissDragGesture)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    .padding(.bottom, studioTabBarClearance(bottomInset: geo.safeAreaInsets.bottom))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if vm.hasAnyRunningEffect {
                    Button {
                        Task { await vm.stopAll() }
                        HapticManager.shared.medium()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .foregroundStyle(HuePalette.Noir.destructive)
                    }
                    .accessibilityLabel("Stop all running effects")
                }
            }
            ToolbarItem(placement: .principal) {
                swipeableRoomTitle
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showSettings = true } label: {
                    Image(systemName: "gear").foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsView(onForget: { showSettings = false }) }
        }
        .sheet(isPresented: $showRoomSheet) {
            roomPickerSheet
        }
        .preferredColorScheme(.dark)
        .onAppear {
            vm.configure(orchestrator: orchestrator)
            // Defer blur to avoid ~2ms GPU hitch on first frame
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.easeIn(duration: 0.4)) { blurReady = true }
            }
        }
        .onChange(of: vm.selectedRoom?.id) { _, _ in
            isMixerCollapsed = false
        }
        .onChange(of: vm.runningCardID) { _, newValue in
            if newValue == nil { isMixerCollapsed = false }
        }
        .animation(HueAnimation.slow, value: vm.currentRoomEffect != nil)
        .animation(HueAnimation.card, value: vm.runningCardID)
        .alert("Rename Composition", isPresented: Binding(
            get: { renameCompositionTarget != nil },
            set: { if !$0 { renameCompositionTarget = nil } }
        )) {
            TextField("Name", text: $renameCompositionText)
            Button("Cancel", role: .cancel) {
                renameCompositionTarget = nil
            }
            Button("Save") {
                if let preset = renameCompositionTarget {
                    vm.renameCompositionPreset(id: preset.id, to: renameCompositionText)
                }
                renameCompositionTarget = nil
            }
        } message: {
            Text("This name appears on the Composer deck.")
        }
        .confirmationDialog(
            "Choose Composer Transport",
            isPresented: $showCompositionTransportPrompt,
            titleVisibility: .visible
        ) {
            Button("Room Only (REST)") {
                guard let card = pendingCompositionCard else { return }
                let room = pendingCompositionRoom
                Task { await vm.apply(card, roomOverride: room, preferEntertainmentOverride: false) }
                clearPendingCompositionTransportPrompt()
            }
            Button("Entertainment Area (Streaming)") {
                guard let card = pendingCompositionCard else { return }
                let room = pendingCompositionRoom
                Task { await vm.apply(card, roomOverride: room, preferEntertainmentOverride: true) }
                clearPendingCompositionTransportPrompt()
            }
            Divider()
            Button("Always Room Only") {
                vm.compositionTransportPreference = .roomOnly
                vm.isCompositionTransportPromptEnabled = false
                guard let card = pendingCompositionCard else { return }
                let room = pendingCompositionRoom
                Task { await vm.apply(card, roomOverride: room, preferEntertainmentOverride: false) }
                clearPendingCompositionTransportPrompt()
            }
            Button("Always Entertainment Area") {
                vm.compositionTransportPreference = .entertainmentArea
                vm.isCompositionTransportPromptEnabled = false
                guard let card = pendingCompositionCard else { return }
                let room = pendingCompositionRoom
                Task { await vm.apply(card, roomOverride: room, preferEntertainmentOverride: true) }
                clearPendingCompositionTransportPrompt()
            }
            Button("Cancel", role: .cancel) {
                clearPendingCompositionTransportPrompt()
            }
        } message: {
            Text("Entertainment is smoother but controls the whole entertainment area. Room Only keeps scope local with REST pacing.")
        }
        .confirmationDialog(
            "Delete composition?",
            isPresented: Binding(
                get: { compositionDeleteTarget != nil },
                set: { if !$0 { compositionDeleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let preset = compositionDeleteTarget {
                    Task { await vm.deleteCompositionPreset(preset) }
                }
                compositionDeleteTarget = nil
            }
            Button("Cancel", role: .cancel) {
                compositionDeleteTarget = nil
            }
        } message: {
            Text("Saved presets are removed from My Creations. Built-in presets reset to their defaults.")
        }
    }

    /// Floating tab bar + home indicator — keeps mixer aligned above the bar on all phones.
    private func studioTabBarClearance(bottomInset: CGFloat) -> CGFloat {
        max(72, 56 + bottomInset)
    }

    private var isCompactStudio: Bool {
        UIScreen.main.bounds.height <= 700 || dynamicTypeSize.isAccessibilitySize
    }

    /// Caps tray height to available tab content so the mixer can use most of the screen on SE while keeping the deck visible.
    private func resolvedMixerHeight(proxy: GeometryProxy) -> CGFloat {
        let base = computeMixerHeight()
        let maxTray = max(300, proxy.size.height * 0.88)
        return min(base, maxTray)
    }

    private func computeMixerHeight() -> CGFloat {
        guard let effect = vm.currentRoomEffect else { return 0 }
        if case .composition = effect.card.strategy {
            // Taller tray on small phones; inner `ScrollView` fills remaining space below header.
            return isCompactStudio ? 390 : 420
        }
        let essentialCount = effect.card.params.filter { $0.tier == .essential }.count
        // Header (60) + essential sliders (56 each) + chevron row (36) + padding
        let calculated = CGFloat(60 + essentialCount * 56 + 36 + 16)
        return isCompactStudio ? min(calculated, 360) : calculated
    }

    private var allCards: [StudioCard] {
        vm.effectCards + vm.liveModeCards
    }

    // ──────────────────────────────────────────────
    // MARK: - Background
    // ──────────────────────────────────────────────

    private var ambientBackground: some View {
        GeometryReader { geo in
            ZStack {
                HuePalette.Noir.background

                if blurReady {
                    Circle()
                        .fill(RadialGradient(
                            colors: [HuePalette.amber.opacity(0.20), .clear],
                            center: .center, startRadius: 0, endRadius: 180
                        ))
                        .frame(width: 360)
                        .position(x: geo.size.width * 0.85, y: 120)
                        .blur(radius: 30)

                    Circle()
                        .fill(RadialGradient(
                            colors: [Color(hex: "#8C59FF").opacity(0.18), .clear],
                            center: .center, startRadius: 0, endRadius: 150
                        ))
                        .frame(width: 300)
                        .position(x: geo.size.width * 0.15, y: geo.size.height * 0.65)
                        .blur(radius: 24)
                }
            }
        }
        .ignoresSafeArea()
    }

    // ──────────────────────────────────────────────
    // MARK: - Zone A: Swipeable Room Title
    // Swipe L/R = zones, U/D = rooms, tap = sheet
    // ──────────────────────────────────────────────

    private var swipeableRoomTitle: some View {
        let displayName = vm.selectedRoom?.name ?? "Select a room"
        let hasRoom = vm.selectedRoom != nil
        let peek = sidePeekNames()

        // Check if the running card is entertainment-scoped
        let isEntRunning: Bool = {
            guard let effect = vm.currentRoomEffect else { return false }
            return effect.card.isEntertainmentScoped
        }()

        return VStack(spacing: 1) {
            Text("Studio")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.35))
                .tracking(0.5)

            if isEntRunning {
                // Entertainment mode — show area indicator instead of room picker
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Entertainment Area")
                        .font(.system(size: 16, weight: .semibold))
                }
                .foregroundStyle(vm.currentRoomEffect?.card.accentColor ?? .white)
            } else {
                ZStack {
                    HStack {
                        if let left = peek.left {
                            Text(left)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.26))
                                .lineLimit(1)
                                .frame(width: 52, alignment: .leading)
                        } else {
                            Color.clear.frame(width: 52)
                        }
                        Spacer()
                        if let right = peek.right {
                            Text(right)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.26))
                                .lineLimit(1)
                                .frame(width: 52, alignment: .trailing)
                        } else {
                            Color.clear.frame(width: 52)
                        }
                    }

                    Text(displayName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(hasRoom ? .white : .white.opacity(0.45))
                        .lineLimit(1)
                        .id(displayName)
                        .transition(.asymmetric(
                            insertion: .move(edge: slideDirection).combined(with: .opacity),
                            removal: .move(edge: slideDirection == .trailing ? .leading : .trailing).combined(with: .opacity)
                        ))
                }
                .frame(width: 180)
                .clipped()
            }
        }
        .contentShape(Rectangle())
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens room and zone search. Swipe horizontally for zones and vertically for rooms.")
        .onTapGesture {
            guard !isEntRunning else { return }  // Disable picker during entertainment
            showRoomSheet = true
            HapticManager.shared.light()
        }
        .gesture(
            DragGesture(minimumDistance: 10)
                .onChanged { value in
                    let dx = value.translation.width
                    let dy = value.translation.height

                    // Lock axis on first significant movement
                    if dragAxisLocked == nil {
                        if abs(dx) > 15 || abs(dy) > 15 {
                            dragAxisLocked = abs(dx) > abs(dy) ? .horizontal : .vertical
                        }
                        return
                    }

                    // Calculate steps (40pt per room change)
                    let stepSize: CGFloat = 40
                    let steps: Int
                    if dragAxisLocked == .horizontal {
                        steps = -Int(dx / stepSize)  // swipe left = next
                    } else {
                        steps = -Int(dy / stepSize)  // swipe up = next
                    }

                    if steps != dragRoomSteps {
                        let items = dragAxisLocked == .horizontal
                            ? orchestrator.allZones
                            : orchestrator.allRooms
                        guard !items.isEmpty else { return }

                        let delta = steps - dragRoomSteps
                        dragRoomSteps = steps

                        // Determine new index
                        let currentIndex = items.firstIndex(where: { $0.id == vm.selectedRoom?.id }) ?? 0
                        let newIndex = (currentIndex + delta + items.count * 100) % items.count
                        let newRoom = items[newIndex]

                        withAnimation(HueAnimation.fast) {
                            slideDirection = delta > 0 ? .trailing : .leading
                            vm.selectedRoom = newRoom
                        }
                        HapticManager.shared.selection()
                    }
                }
                .onEnded { _ in
                    dragAxisLocked = nil
                    dragRoomSteps = 0
                }
        )
        .animation(HueAnimation.fast, value: displayName)
    }

    private func sidePeekNames() -> (left: String?, right: String?) {
        let zones = orchestrator.allZones
        guard !zones.isEmpty else { return (nil, nil) }
        let currentIndex = zones.firstIndex(where: { $0.id == vm.selectedRoom?.id }) ?? 0
        let leftIndex = (currentIndex - 1 + zones.count) % zones.count
        let rightIndex = (currentIndex + 1) % zones.count
        return (
            zones[leftIndex].name,
            zones[rightIndex].name
        )
    }

    // ──────────────────────────────────────────────
    // MARK: - Room Picker Sheet
    // Searchable half-sheet, grouped by Rooms / Zones
    // ──────────────────────────────────────────────

    private var roomPickerSheet: some View {
        RoomPickerSheetView(
            rooms: orchestrator.allRooms,
            zones: orchestrator.allZones,
            selectedRoom: vm.selectedRoom,
            runningEffects: vm.runningEffects,
            onSelect: { room in
                withAnimation(HueAnimation.fast) {
                    vm.selectedRoom = room
                }
                showRoomSheet = false
                HapticManager.shared.selection()
            }
        )
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.ultraThinMaterial)
    }

    // ──────────────────────────────────────────────
    // MARK: - Zone B: Card Grid (paged)
    // ──────────────────────────────────────────────

    private var cardGrid: some View {
        TabView(selection: $currentDeck) {
            // Deck 0: Effects
            deckGrid(cards: vm.effectCards, deckIndex: 0)
                .tag(0)

            // Deck 1: Live Modes
            deckGrid(cards: vm.liveModeCards, deckIndex: 1)
                .tag(1)

            // Deck 2: Composer (presets + Create)
            composerGrid(deckIndex: 2)
                .tag(2)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        // Avoid animating the entire deck subtree — reduces hitch when paging to Composer.
    }

    private func deckGrid(cards: [StudioCard], deckIndex: Int) -> some View {
        let columns = [
            GridItem(.flexible(), spacing: HueSpacing.md),
            GridItem(.flexible(), spacing: HueSpacing.md)
        ]
        let visible = currentDeck == deckIndex

        return ScrollView(showsIndicators: false) {
            LazyVGrid(columns: columns, spacing: HueSpacing.md) {
                ForEach(cards) { card in
                    StudioCardView(
                        card: card,
                        isRunning: vm.runningCardID == card.id,
                        roomSelected: vm.selectedRoom != nil,
                        isVisible: visible
                    ) {
                        if vm.runningCardID == card.id {
                            if isMixerCollapsed {
                                expandMixer()
                                HapticManager.shared.selection()
                            } else {
                                Task { await vm.explicitStop(card) }
                            }
                        } else {
                            isMixerCollapsed = false
                            applyCardWithTransportPrompt(card)
                        }
                    }
                }
            }
            .padding(.horizontal, HueSpacing.screenH)
            .padding(.vertical, HueSpacing.sm)
        }
    }

    // ── Deck 3: Composer ─────────────────────────────────────

    private var composerCategoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(PresetCategory.allCases) { category in
                    composerCategoryChip(category)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func composerCategoryChip(_ category: PresetCategory) -> some View {
        let selected = composerCategory == category
        let holidayHot = category == .holiday && vm.hasSeasonalCompositionPreset

        return Button {
            composerCategory = category
            HapticManager.shared.selection()
        } label: {
            Text(category.rawValue)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? HuePalette.amber : .white.opacity(0.75))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(selected
                              ? HuePalette.amber.opacity(0.18)
                              : Color.white.opacity(0.06))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(
                            holidayHot ? HuePalette.amber.opacity(selected ? 0.55 : 0.42) : Color.white.opacity(selected ? 0.18 : 0.08),
                            lineWidth: holidayHot ? (selected ? 1.5 : 1.0) : 1
                        )
                )
        }
        .buttonStyle(.plain)
    }

    private func composerCreateHero(visible: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: HueRadius.xl)
                .fill(Color.white.opacity(0.06))

            RoundedRectangle(cornerRadius: HueRadius.xl)
                .strokeBorder(
                    AngularGradient(
                        colors: [
                            HuePalette.amber,
                            Color(hex: "#8C59FF"),
                            HuePalette.amber.opacity(0.35),
                            HuePalette.amber
                        ],
                        center: .center,
                        angle: .degrees(composerCreateBorderPhase * 360)
                    ),
                    lineWidth: 2
                )

            Group {
                if isAIPromptExpanded {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(HuePalette.amber)
                            Text("Generate with AI")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                            Spacer()
                            if vm.isGeneratingAIComposition {
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .tint(HuePalette.amber)
                            }
                        }

                        TextField("Describe the vibe (e.g. ocean calm with soft pulse)", text: $aiPromptText, axis: .vertical)
                            .focused($aiPromptFocused)
                            .lineLimit(1...2)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                            .textInputAutocapitalization(.sentences)
                            .autocorrectionDisabled(false)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.black.opacity(0.22))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                            )

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(vm.suggestedAIPrompts, id: \.self) { suggestion in
                                    Button {
                                        aiPromptText = suggestion
                                        triggerAIGeneration(with: suggestion)
                                        HapticManager.shared.selection()
                                    } label: {
                                        Text(suggestion)
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(.white.opacity(0.9))
                                            .lineLimit(1)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .background(
                                                Capsule().fill(Color.white.opacity(0.08))
                                            )
                                            .overlay(
                                                Capsule()
                                                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(vm.isGeneratingAIComposition)
                                }
                            }
                        }

                        HStack(spacing: 8) {
                            Button("Cancel") {
                                isAIPromptExpanded = false
                                aiPromptText = ""
                                aiPromptFocused = false
                                vm.aiGenerationErrorMessage = nil
                                HapticManager.shared.light()
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.75))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                Capsule().fill(Color.white.opacity(0.08))
                            )
                            .buttonStyle(.plain)
                            .disabled(vm.isGeneratingAIComposition)

                            Spacer()

                            Button {
                                triggerAIGeneration(with: aiPromptText)
                            } label: {
                                Text(vm.isGeneratingAIComposition ? "Generating..." : "Generate")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.black.opacity(vm.isGeneratingAIComposition ? 0.5 : 0.9))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 7)
                                    .background(
                                        Capsule().fill(HuePalette.amber.opacity(vm.isGeneratingAIComposition ? 0.45 : 0.95))
                                    )
                            }
                            .buttonStyle(.plain)
                            .disabled(vm.isGeneratingAIComposition || aiPromptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding(HueSpacing.lg)
                } else {
                    HStack(spacing: HueSpacing.md) {
                        Button {
                            Task { await vm.applyStarterComposition() }
                            HapticManager.shared.medium()
                        } label: {
                            HStack(spacing: HueSpacing.md) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(HuePalette.amber)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("+ Create")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(.white)
                                    Text("Build your own effect")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.42))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)

                        Button {
                            withAnimation(HueAnimation.fast) {
                                isAIPromptExpanded = true
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                aiPromptFocused = true
                            }
                            vm.aiGenerationErrorMessage = nil
                            HapticManager.shared.selection()
                        } label: {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(HuePalette.amber)
                                .padding(10)
                                .background(
                                    Circle().fill(HuePalette.amber.opacity(0.14))
                                )
                                .overlay(
                                    Circle().strokeBorder(HuePalette.amber.opacity(0.35), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Generate with AI")
                    }
                    .padding(HueSpacing.lg)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: isAIPromptExpanded ? 146 : 76)
        .animation(HueAnimation.fast, value: isAIPromptExpanded)
        .opacity(visible ? 1 : 0.999)
        .onAppear {
            composerCreateBorderPhase = 0
            withAnimation(.linear(duration: 3.0).repeatForever(autoreverses: false)) {
                composerCreateBorderPhase = 1
            }
        }
    }

    private func composerGrid(deckIndex: Int) -> some View {
        let columns = [
            GridItem(.flexible(), spacing: HueSpacing.md),
            GridItem(.flexible(), spacing: HueSpacing.md)
        ]
        let visible = currentDeck == deckIndex
        let presets = vm.composerPresets(for: composerCategory)

        return ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: isCompactStudio ? HueSpacing.sm : HueSpacing.md) {
                composerCategoryChips

                if vm.hasSeasonalCompositionPreset {
                    HStack(spacing: 8) {
                        Text("Seasonal picks are live")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(HuePalette.amber)
                        Spacer()
                        Text("Holiday")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(HuePalette.amber)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule().fill(HuePalette.amber.opacity(0.16))
                            )
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.white.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(HuePalette.amber.opacity(0.20), lineWidth: 1)
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                composerCreateHero(visible: visible)

                if let error = vm.aiGenerationErrorMessage, !error.isEmpty {
                    Text(error)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(HuePalette.Noir.destructive)
                        .padding(.horizontal, 4)
                }

                if presets.isEmpty {
                    Text("No presets in this category.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.38))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, HueSpacing.lg)
                }

                LazyVGrid(columns: columns, spacing: HueSpacing.md) {
                    ForEach(presets) { preset in
                        let card = vm.studioCard(for: preset)
                        ZStack(alignment: .topTrailing) {
                            StudioCardView(
                                card: card,
                                isRunning: vm.runningCardID == card.id,
                                roomSelected: vm.selectedRoom != nil,
                                isVisible: visible
                            ) {
                                if vm.runningCardID == card.id {
                                    if isMixerCollapsed {
                                        expandMixer()
                                        HapticManager.shared.selection()
                                    } else {
                                        Task { await vm.explicitStop(card) }
                                    }
                                } else {
                                    isMixerCollapsed = false
                                    applyCardWithTransportPrompt(card)
                                }
                            }

                            Menu {
                                composerPresetOverflowActions(preset: preset, card: card)
                            } label: {
                                Image(systemName: "ellipsis.circle.fill")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.72))
                                    .padding(8)
                                    .background(Circle().fill(Color.black.opacity(0.38)))
                            }
                            .menuStyle(.button)
                            .padding(6)
                            .accessibilityLabel("Composition actions")
                        }
                        .contextMenu {
                            composerPresetOverflowActions(preset: preset, card: card)
                        }
                    }
                }
            }
            .padding(.horizontal, HueSpacing.screenH)
            .padding(.vertical, isCompactStudio ? 6 : HueSpacing.sm)
        }
    }

    // ── Deck page dots ───────────────────────────────────────

    private var deckDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(currentDeck == i ? .white : .white.opacity(0.25))
                    .frame(width: 6, height: 6)
                    .animation(HueAnimation.fast, value: currentDeck)
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Zone C: Mixer Tray
    // ──────────────────────────────────────────────

    private var mixerTray: some View {
        let effect = vm.currentRoomEffect

        return VStack(spacing: 0) {
            if let effect {
                let card = effect.card

                Capsule()
                    .fill(Color.white.opacity(0.28))
                    .frame(width: 36, height: 4)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        collapseMixer()
                        HapticManager.shared.light()
                    }

                // ── Header ───────────────────────────────────
                HStack(spacing: 10) {
                    // Effect icon
                    ZStack {
                        Circle()
                            .fill(card.accentColor.opacity(0.20))
                            .frame(width: 32, height: 32)
                        Image(systemName: card.icon)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(card.accentColor)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text(card.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(effect.room.name)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.4))
                    }

                    // Live indicator
                    HStack(spacing: 4) {
                        Circle().fill(HuePalette.Noir.success)
                            .frame(width: 5, height: 5)
                        Text("LIVE")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(HuePalette.Noir.success)
                    }

                    // Scope / transport badge for Studio engine cards
                    if case .appDriven = card.strategy {
                        Text(effect.isEntertainment ? "ENT AREA" : "ROOM")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(effect.isEntertainment ? HuePalette.amber : .white.opacity(0.75))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(
                                    effect.isEntertainment
                                        ? HuePalette.amber.opacity(0.15)
                                        : Color.white.opacity(0.10)
                                )
                            )
                    } else if case .composition = card.strategy {
                        VStack(alignment: .leading, spacing: 2) {
                            Menu {
                                Button {
                                    switchRunningCompositionTransport(effect, preferEntertainment: true)
                                } label: {
                                    Label("Entertainment Area (Streaming)", systemImage: "bolt.fill")
                                }

                                Button {
                                    switchRunningCompositionTransport(effect, preferEntertainment: false)
                                } label: {
                                    Label("Room Only (REST)", systemImage: "iphone")
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(composerTransportBadgeText(for: effect))
                                        .font(.system(size: 9, weight: .bold))
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.system(size: 7, weight: .bold))
                                        .opacity(0.82)
                                }
                                .foregroundStyle(effect.isEntertainment ? HuePalette.amber : .white.opacity(0.75))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(
                                        effect.isEntertainment
                                            ? HuePalette.amber.opacity(0.15)
                                            : Color.white.opacity(0.10)
                                    )
                                )
                            }
                            .buttonStyle(.plain)

                            if effect.transportFallback {
                                Text("Streaming unavailable on this bridge/session, using REST")
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundStyle(HuePalette.amber.opacity(0.75))
                            } else if !effect.isEntertainment, card.compositionTier == .runtimeOnly {
                                Text(runtimeOnlyCadenceText())
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.48))
                            }
                        }
                    }

                    // Active rooms count badge
                    if vm.runningEffects.count > 1 {
                        Text("\(vm.runningEffects.count) rooms")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(HuePalette.amber)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(HuePalette.amber.opacity(0.15)))
                    }

                    Spacer()

                    if case .composition = card.strategy {
                        Button {
                            compositionSaveName = card.name == "New Composition" ? "" : card.name
                            compositionSaveIcon = card.icon
                            compositionSaveTransport = vm.compositionTransportPreference == .roomOnly ? .roomOnly : .entertainmentArea
                            showCompositionSaveSheet = true
                            HapticManager.shared.light()
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 12))
                                .foregroundStyle(HuePalette.amber)
                                .padding(8)
                                .background(
                                    Circle()
                                        .fill(HuePalette.amber.opacity(0.15))
                                )
                        }
                        .buttonStyle(.plain)
                    }

                    // Stop control
                    Button {
                        Task { await vm.explicitStop(card) }
                        HapticManager.shared.light()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(HuePalette.Noir.destructive)
                            .padding(8)
                            .background(
                                Circle()
                                    .fill(HuePalette.Noir.destructive.opacity(0.15))
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, HueSpacing.screenH)
                .padding(.top, HueSpacing.md)
                .padding(.bottom, HueSpacing.sm)

                // ── Separator ────────────────────────────────
                Rectangle()
                    .fill(HuePalette.Noir.separator)
                    .frame(height: 0.5)
                    .padding(.horizontal, HueSpacing.screenH)

                if case .composition = card.strategy {
                    GeometryReader { scrollGeo in
                        ScrollView(showsIndicators: false) {
                            compositionMixerBody
                                .padding(.horizontal, HueSpacing.screenH)
                                .padding(.top, HueSpacing.md)
                                .padding(.bottom, HueSpacing.md)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(height: scrollGeo.size.height)
                    }
                } else {
                    // ── Essential parameter sliders ──────────────
                    let essentialParams = card.params.filter { $0.tier == .essential }
                    if !essentialParams.isEmpty {
                        GeometryReader { scrollGeo in
                            ScrollView(showsIndicators: false) {
                                VStack(spacing: HueSpacing.md) {
                                    ForEach(essentialParams) { param in
                                        StudioParamRow(param: param, cardID: card.id, vm: vm)
                                    }
                                }
                                .padding(.horizontal, HueSpacing.screenH)
                                .padding(.top, HueSpacing.md)
                                .padding(.bottom, HueSpacing.md)
                            }
                            .scrollBounceBehavior(.basedOnSize)
                            .frame(height: scrollGeo.size.height)
                        }
                    }

                    // ── More params chevron ──────────────────────
                    let advancedCount = card.params.filter { $0.tier != .essential }.count
                    if advancedCount > 0 {
                        Button {
                            showParamSheet = true
                            HapticManager.shared.light()
                        } label: {
                            HStack(spacing: 4) {
                                Text("\(advancedCount) more")
                                    .font(.system(size: 11, weight: .medium))
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            .foregroundStyle(.white.opacity(0.45))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // ── Param sheet (inside if-let for unwrapped card) ──
                Color.clear.frame(height: 0)
                    .sheet(isPresented: $showParamSheet) {
                        StudioParamSheet(card: card, vm: vm)
                            .presentationDetents([.medium, .large])
                            .presentationDragIndicator(.visible)
                            .presentationBackgroundInteraction(.enabled)
                    }
                    .sheet(isPresented: $showCompositionSaveSheet) {
                        compositionSaveSheet
                    }
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: HueRadius.xl))
        .padding(.horizontal, HueSpacing.sm)
        .id(vm.currentRoomEffect?.cardID ?? vm.selectedRoom?.id)
        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
    }

    private var mixerDismissDragGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                // Only capture drags that begin near the tray header so child controls
                // (like the hue/saturation pad) keep their own drag semantics.
                guard value.startLocation.y <= 56 else { return }
                let downward = max(0, value.translation.height)
                mixerDragOffset = downward
            }
            .onEnded { value in
                guard value.startLocation.y <= 56 else {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                        mixerDragOffset = 0
                    }
                    return
                }
                let dragDistance = value.translation.height
                let predictedDistance = value.predictedEndTranslation.height
                let shouldDismiss = dragDistance > 100 || predictedDistance > 160
                if shouldDismiss {
                    hideKeyboard()
                    collapseMixer()
                    HapticManager.shared.medium()
                }
                withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                    mixerDragOffset = 0
                }
            }
    }

    private func collapseMixer() {
        withAnimation(HueAnimation.fast) {
            isMixerCollapsed = true
        }
    }

    private func expandMixer() {
        withAnimation(HueAnimation.fast) {
            isMixerCollapsed = false
        }
    }

    private func triggerAIGeneration(with prompt: String) {
        let roomSnapshot = vm.selectedRoom
        Task {
            if let preset = await vm.generateCompositionFromPrompt(prompt) {
                await vm.apply(vm.studioCard(for: preset), roomOverride: roomSnapshot, preferEntertainmentOverride: nil)
                aiPromptText = ""
                isAIPromptExpanded = false
                aiPromptFocused = false
                HapticManager.shared.medium()
            } else {
                HapticManager.shared.light()
            }
        }
    }

    private func runtimeOnlyCadenceText() -> String {
        guard let cadence = vm.activeRESTCadenceForSelectedRoom else {
            return "Runtime-only REST is rate-capped"
        }
        return "Runtime-only REST is rate-capped (Live: ~\(String(format: "%.1f", cadence))s)"
    }

    private func applyCardWithTransportPrompt(_ card: StudioCard) {
        let roomSnapshot = vm.selectedRoom
        guard case .composition = card.strategy else {
            Task { await vm.apply(card, roomOverride: roomSnapshot, preferEntertainmentOverride: nil) }
            return
        }
        if card.compositionTier == .bridgeOptimized || !vm.isCompositionTransportPromptEnabled {
            Task { await vm.apply(card, roomOverride: roomSnapshot, preferEntertainmentOverride: nil) }
            return
        }
        pendingCompositionCard = card
        pendingCompositionRoom = roomSnapshot
        showCompositionTransportPrompt = true
    }

    private func clearPendingCompositionTransportPrompt() {
        pendingCompositionCard = nil
        pendingCompositionRoom = nil
    }

    private func composerTransportBadgeText(for effect: RunningEffect) -> String {
        if effect.transportFallback {
            return "COMPOSER: ROOM (REST FALLBACK)"
        }
        return effect.isEntertainment ? "COMPOSER: ENT AREA" : "COMPOSER: ROOM (REST)"
    }

    private func switchRunningCompositionTransport(_ effect: RunningEffect, preferEntertainment: Bool) {
        guard case .composition = effect.card.strategy else { return }
        let roomID = effect.room.id
        if transportSwitchInFlightRoomIDs.contains(roomID) { return }
        if preferEntertainment == effect.isEntertainment {
            HapticManager.shared.selection()
            return
        }
        isMixerCollapsed = false
        transportSwitchInFlightRoomIDs.insert(roomID)
        Task {
            await vm.apply(
                effect.card,
                roomOverride: effect.room,
                preferEntertainmentOverride: preferEntertainment
            )
            transportSwitchInFlightRoomIDs.remove(roomID)
        }
        HapticManager.shared.light()
    }

    private enum CompositionQuickApply {
        case defaultStudioRules
        case streaming
        case roomREST
        case matchSavedPreset
    }

    /// Applies a composition card with an explicit transport choice (skips the transport confirmation sheet).
    private func applyCompositionQuick(_ card: StudioCard, mode: CompositionQuickApply) {
        let roomSnapshot = vm.selectedRoom
        guard case .composition = card.strategy else { return }
        switch mode {
        case .defaultStudioRules:
            applyCardWithTransportPrompt(card)
        case .streaming:
            isMixerCollapsed = false
            Task { await vm.apply(card, roomOverride: roomSnapshot, preferEntertainmentOverride: true) }
        case .roomREST:
            isMixerCollapsed = false
            Task { await vm.apply(card, roomOverride: roomSnapshot, preferEntertainmentOverride: false) }
        case .matchSavedPreset:
            isMixerCollapsed = false
            Task { await vm.apply(card, roomOverride: roomSnapshot, preferEntertainmentOverride: nil) }
        }
    }

    @ViewBuilder
    private func composerPresetOverflowActions(preset: CompositionPreset, card: StudioCard) -> some View {
        Button {
            applyCompositionQuick(card, mode: .defaultStudioRules)
            HapticManager.shared.light()
        } label: {
            Label("Apply to Current Room", systemImage: "play.fill")
        }

        Menu {
            Button {
                applyCompositionQuick(card, mode: .streaming)
                HapticManager.shared.light()
            } label: {
                Label("Entertainment Area (Streaming)", systemImage: "bolt.fill")
            }
            Button {
                applyCompositionQuick(card, mode: .roomREST)
                HapticManager.shared.light()
            } label: {
                Label("Room Only (REST)", systemImage: "iphone")
            }
            Button {
                applyCompositionQuick(card, mode: .matchSavedPreset)
                HapticManager.shared.light()
            } label: {
                Label("Match Saved Preset", systemImage: "bookmark.fill")
            }
        } label: {
            Label("Apply with Transport…", systemImage: "arrow.triangle.branch")
        }

        Divider()

        Button {
            renameCompositionText = preset.name
            renameCompositionTarget = preset
            HapticManager.shared.light()
        } label: {
            Label("Rename…", systemImage: "pencil")
        }

        Button {
            vm.duplicateCompositionPreset(preset)
            HapticManager.shared.light()
        } label: {
            Label("Duplicate", systemImage: "doc.on.doc")
        }

        Divider()

        Button(role: .destructive) {
            compositionDeleteTarget = preset
            HapticManager.shared.light()
        } label: {
            Label("Delete…", systemImage: "trash")
        }
    }

    private func compositionSectionHeader(_ title: String, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.38))
                .tracking(0.6)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func reactionTargetLabel(_ target: ReactionConfig.Target) -> String {
        switch target {
        case .brightness: return "Brightness"
        case .color: return "Color"
        case .speed: return "Speed"
        }
    }

    private func reactionTargetToggleBinding(_ target: ReactionConfig.Target) -> Binding<Bool> {
        Binding(
            get: { vm.activeCompositionBox?.reaction.targets.contains(target) ?? false },
            set: { on in
                guard let box = vm.activeCompositionBox else { return }
                var targets = box.reaction.targets
                if on {
                    if !targets.contains(target) { targets.append(target) }
                } else {
                    targets.removeAll { $0 == target }
                }
                if targets.isEmpty { targets = [.brightness] }
                box.reaction.targets = targets
            }
        )
    }

    private var compositionMixerBody: some View {
        VStack(alignment: .leading, spacing: HueSpacing.md) {
            compositionSectionHeader("Layers", subtitle: "Choose a layer to edit live.")
                .padding(.bottom, -2)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(CompositionLayerTab.allCases) { tab in
                        let selected = activeCompositionTab == tab
                        Button {
                            activeCompositionTab = tab
                            HapticManager.shared.selection()
                        } label: {
                            Label(tab.title, systemImage: tab.symbolName)
                                .font(.system(size: 12, weight: .semibold))
                                .labelStyle(.titleAndIcon)
                                .foregroundStyle(selected ? HuePalette.amber : .white.opacity(0.78))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule()
                                        .fill(selected ? HuePalette.amber.opacity(0.18) : Color.white.opacity(0.06))
                                )
                                .overlay(
                                    Capsule()
                                        .strokeBorder(selected ? HuePalette.amber.opacity(0.55) : Color.white.opacity(0.10), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 12, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)

            Group {
                switch activeCompositionTab {
                case .palette: compositionPaletteControls
                case .motion: compositionMotionControls
                case .envelope: compositionEnvelopeControls
                case .reaction: compositionReactionControls
                }
            }
            .id(activeCompositionTab)
            .transition(.opacity.combined(with: .scale(scale: 0.985)))
            .animation(HueAnimation.fast, value: activeCompositionTab)
        }
    }

    private var compositionPaletteControls: some View {
        VStack(spacing: HueSpacing.sm) {
            compositionSectionHeader("Color", subtitle: "Palette every light reads before motion and envelope.")

            Picker("Mode", selection: Binding(
                get: { vm.activeCompositionBox?.palette.mode ?? .gradient },
                set: { vm.activeCompositionBox?.palette.mode = $0 }
            )) {
                ForEach(PaletteConfig.Mode.allCases, id: \.self) { mode in
                    Text(mode.rawValue.capitalized).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            hueSaturationPad

            if (vm.activeCompositionBox?.palette.mode ?? .gradient) == .spectrum {
                compositionSlider(
                    title: "Hue Shift",
                    value: Binding(
                        get: { vm.activeCompositionBox?.palette.hueShift ?? 0 },
                        set: { vm.activeCompositionBox?.palette.hueShift = $0 }
                    ),
                    range: -180...180
                )
            }
        }
    }

    private var hueSaturationPad: some View {
        let canonicalHSB: (h: Double, s: Double) = {
            guard let c = vm.activeCompositionBox?.palette.color1 else { return (0.0, 1.0) }
            let clampedXY = HueColorUtils.clampXYToGamut(
                x: c.x,
                y: c.y,
                gamut: vm.activeCompositionGamut
            )
            let hsb = HueColorUtils.hsb(fromX: clampedXY.x, y: clampedXY.y, brightness: 100)
            return (h: hsb.h, s: hsb.s)
        }()
        let currentHue: Double = canonicalHSB.h
        let currentSat: Double = canonicalHSB.s
        let displayHue = isHuePadDragging ? huePadLiveHue : currentHue
        let displaySat = isHuePadDragging ? huePadLiveSaturation : currentSat
        let thumbColor = Color(hue: displayHue, saturation: displaySat, brightness: 1.0)

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Hue + Saturation")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.60))
                Spacer()
                Circle()
                    .fill(thumbColor)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1))
                Text("\(Int((displayHue * 360).rounded()))° • \(Int((displaySat * 100).rounded()))%")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.42))
            }

            GeometryReader { geo in
                let w = max(1, geo.size.width)
                let h = max(1, geo.size.height)
                let thumbX = CGFloat(displayHue) * w
                let thumbY = (1.0 - CGFloat(displaySat)) * h

                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            LinearGradient(
                                colors: [
                                    .red, .orange, .yellow, .green, .cyan, .blue, .purple, .red
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            LinearGradient(
                                colors: [
                                    .white, .white.opacity(0.0)
                                ],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)

                    Circle()
                        .fill(thumbColor)
                        .frame(width: 22, height: 22)
                        .overlay(Circle().strokeBorder(Color.white, lineWidth: 2))
                        .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1)
                        .position(x: thumbX, y: thumbY)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            let clampedX = min(max(gesture.location.x, 0), w)
                            let clampedY = min(max(gesture.location.y, 0), h)
                            let hue = Double(clampedX / w)
                            let sat = Double(1.0 - (clampedY / h))
                            let clampedSat = min(1.0, max(0.0, sat))
                            isHuePadDragging = true
                            vm.activeCompositionBox?.isColorPadInteracting = true
                            vm.activeCompositionBox?.triggerRESTBurst()
                            huePadLiveHue = hue
                            huePadLiveSaturation = clampedSat
                            let now = CFAbsoluteTimeGetCurrent()
                            if now - lastHuePadHapticAt >= 0.08 {
                                HapticManager.shared.selection()
                                lastHuePadHapticAt = now
                            }
                            let xy = HueColorUtils.xyFrom(hue: hue, saturation: clampedSat, brightness: 1.0)
                            let clampedXY = HueColorUtils.clampXYToGamut(
                                x: xy.x,
                                y: xy.y,
                                gamut: vm.activeCompositionGamut
                            )
                            let clampedHSB = HueColorUtils.hsb(
                                fromX: clampedXY.x,
                                y: clampedXY.y,
                                brightness: 100
                            )
                            huePadLiveHue = clampedHSB.h
                            huePadLiveSaturation = clampedHSB.s
                            vm.activeCompositionBox?.palette.color1 = CodableColor(x: clampedXY.x, y: clampedXY.y)
                            vm.activeCompositionBox?.palette.saturation = clampedHSB.s * 100
                        }
                        .onEnded { _ in
                            isHuePadDragging = false
                            vm.activeCompositionBox?.isColorPadInteracting = false
                            vm.activeCompositionBox?.triggerRESTBurst()
                            lastHuePadHapticAt = 0
                            HapticManager.shared.selection()
                        }
                )
            }
            .frame(height: isCompactStudio ? 118 : 156)
        }
    }

    private var compositionMotionControls: some View {
        VStack(spacing: HueSpacing.sm) {
            compositionSectionHeader("Motion", subtitle: "How color travels across lights over time.")

            Picker("Pattern", selection: Binding(
                get: { vm.activeCompositionBox?.motion.pattern ?? .cascade },
                set: { vm.activeCompositionBox?.motion.pattern = $0 }
            )) {
                ForEach(MotionConfig.Pattern.allCases, id: \.self) { pattern in
                    Text(pattern.rawValue.capitalized).tag(pattern)
                }
            }
            .pickerStyle(.menu)

            compositionSlider(
                title: "Speed",
                value: Binding(
                    get: { vm.activeCompositionBox?.motion.speed ?? 40 },
                    set: { vm.activeCompositionBox?.motion.speed = $0 }
                ),
                range: 0...100
            )

            Toggle("Forward", isOn: Binding(
                get: { vm.activeCompositionBox?.motion.forward ?? true },
                set: { vm.activeCompositionBox?.motion.forward = $0 }
            ))
            .tint(HuePalette.amber)

            compositionSlider(
                title: "Offset",
                value: Binding(
                    get: { vm.activeCompositionBox?.motion.offset ?? 50 },
                    set: { vm.activeCompositionBox?.motion.offset = $0 }
                ),
                range: 0...100
            )
        }
    }

    private var compositionEnvelopeControls: some View {
        VStack(spacing: HueSpacing.sm) {
            compositionSectionHeader("Envelope", subtitle: "Brightness shape over time.")

            Picker("Shape", selection: Binding(
                get: { vm.activeCompositionBox?.envelope.shape ?? .breathe },
                set: { vm.activeCompositionBox?.envelope.shape = $0 }
            )) {
                ForEach(EnvelopeConfig.Shape.allCases, id: \.self) { shape in
                    Text(shape.rawValue.capitalized).tag(shape)
                }
            }
            .pickerStyle(.menu)

            compositionSlider(
                title: "BPM",
                value: Binding(
                    get: { vm.activeCompositionBox?.envelope.bpm ?? 60 },
                    set: { vm.activeCompositionBox?.envelope.bpm = $0 }
                ),
                range: 20...240
            )

            compositionSlider(
                title: "Depth",
                value: Binding(
                    get: { vm.activeCompositionBox?.envelope.depth ?? 50 },
                    set: { vm.activeCompositionBox?.envelope.depth = $0 }
                ),
                range: 0...100
            )

            compositionSlider(
                title: "Min Brightness",
                value: Binding(
                    get: { vm.activeCompositionBox?.envelope.minBrightness ?? 10 },
                    set: { vm.activeCompositionBox?.envelope.minBrightness = $0 }
                ),
                range: 0...50
            )
            compositionSlider(
                title: "Max Brightness",
                value: Binding(
                    get: { vm.activeCompositionBox?.envelope.maxBrightness ?? 100 },
                    set: { vm.activeCompositionBox?.envelope.maxBrightness = $0 }
                ),
                range: 50...100
            )
        }
    }

    private var compositionReactionControls: some View {
        VStack(spacing: HueSpacing.sm) {
            compositionSectionHeader("Reaction", subtitle: "Audio and responsiveness layered on top.")

            Picker("Source", selection: Binding(
                get: { vm.activeCompositionBox?.reaction.source ?? .none },
                set: { vm.activeCompositionBox?.reaction.source = $0 }
            )) {
                ForEach(ReactionConfig.Source.allCases, id: \.self) { source in
                    Text(source.rawValue.replacingOccurrences(of: "_", with: " ").capitalized).tag(source)
                }
            }
            .pickerStyle(.menu)

            if (vm.activeCompositionBox?.reaction.source ?? .none) != .none {
                VStack(alignment: .leading, spacing: 8) {
                    compositionSectionHeader("Targets", subtitle: "Which outputs the reaction modulates.")
                    ForEach(ReactionConfig.Target.allCases, id: \.self) { target in
                        Toggle(reactionTargetLabel(target), isOn: reactionTargetToggleBinding(target))
                            .tint(HuePalette.amber)
                    }
                }
            }

            compositionSlider(
                title: "Sensitivity",
                value: Binding(
                    get: { vm.activeCompositionBox?.reaction.sensitivity ?? 70 },
                    set: { vm.activeCompositionBox?.reaction.sensitivity = $0 }
                ),
                range: 0...100
            )
            compositionSlider(
                title: "Threshold",
                value: Binding(
                    get: { vm.activeCompositionBox?.reaction.threshold ?? 10 },
                    set: { vm.activeCompositionBox?.reaction.threshold = $0 }
                ),
                range: 0...100
            )
            compositionSlider(
                title: "Intensity",
                value: Binding(
                    get: { vm.activeCompositionBox?.reaction.intensity ?? 70 },
                    set: { vm.activeCompositionBox?.reaction.intensity = $0 }
                ),
                range: 0...100
            )
        }
    }

    private func compositionSlider(title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.60))
                Spacer()
                Text("\(Int(value.wrappedValue.rounded()))")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.40))
            }
            Slider(value: value, in: range)
                .tint(HuePalette.amber)
        }
    }

    private var compositionSaveSheet: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("My Composition", text: $compositionSaveName)
                }
                Section("Icon") {
                    let icons = ["sparkles", "sun.max.fill", "moon.stars.fill", "waveform.path.ecg", "flame.fill", "bolt.fill", "music.note", "wand.and.stars"]
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                        ForEach(icons, id: \.self) { icon in
                            Button {
                                compositionSaveIcon = icon
                                HapticManager.shared.selection()
                            } label: {
                                Image(systemName: icon)
                                    .frame(maxWidth: .infinity)
                                    .padding(10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(icon == compositionSaveIcon ? HuePalette.amber.opacity(0.2) : Color.white.opacity(0.08))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Section("Transport") {
                    Picker("Target", selection: $compositionSaveTransport) {
                        ForEach(CompositionSaveTransportOption.allCases) { option in
                            Text(option.segmentTitle).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text("Streaming uses the entertainment area when available. REST stays on this room’s grouped light.")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                hideKeyboard()
            }
            .navigationTitle("Save Composition")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showCompositionSaveSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        _ = vm.saveActiveComposition(
                            name: compositionSaveName,
                            icon: compositionSaveIcon,
                            preferredTransport: compositionSaveTransport.presetValue
                        )
                        showCompositionSaveSheet = false
                        HapticManager.shared.medium()
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

private extension View {
    func hideKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }
}

// MARK: - StudioCardView (Living Cards)
//
// Performance: receives value types only. Never sees the ViewModel.
// The card IS the button — tap to apply/stop. No Apply/Stop sub-buttons.
// Canvas animation plays behind content — unique per card ID.

struct StudioCardView: View, Equatable {

    static func == (lhs: StudioCardView, rhs: StudioCardView) -> Bool {
        lhs.card.id == rhs.card.id && lhs.isRunning == rhs.isRunning && lhs.roomSelected == rhs.roomSelected && lhs.isVisible == rhs.isVisible
    }

    let card: StudioCard
    let isRunning: Bool
    let roomSelected: Bool
    let isVisible: Bool
    let onTap: () -> Void

    private var accentColor: Color { card.accentColor }

    var body: some View {
        Button {
            onTap()
            HapticManager.shared.medium()
        } label: {
            ZStack(alignment: .bottomLeading) {
                // ── Card background ─────────────────────────────
                RoundedRectangle(cornerRadius: HueRadius.xl)
                    .fill(isRunning
                          ? accentColor.opacity(0.13)
                          : Color.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: HueRadius.xl)
                            .strokeBorder(
                                isRunning ? accentColor.opacity(0.55) : Color.white.opacity(0.08),
                                lineWidth: isRunning ? 1.5 : 1
                            )
                    )

                // ── Living Canvas animation ─────────────────────
                StudioCardCanvas(
                    cardID: card.id,
                    accentColor: accentColor,
                    isRunning: isRunning,
                    isVisible: isVisible
                )
                .clipShape(RoundedRectangle(cornerRadius: HueRadius.xl))
                .allowsHitTesting(false)

                // ── Content ─────────────────────────────────────
                VStack(alignment: .leading, spacing: 0) {
                    // Icon
                    ZStack {
                        Circle()
                            .fill(accentColor.opacity(isRunning ? 0.28 : 0.15))
                            .frame(width: 40, height: 40)
                        Image(systemName: card.icon)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(accentColor)
                            .symbolEffect(.pulse.byLayer, isActive: isRunning)
                    }

                    Spacer(minLength: HueSpacing.sm)

                    // Name
                    HStack(spacing: 5) {
                        Text(card.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        if isRunning {
                            Circle()
                                .fill(HuePalette.Noir.success)
                                .frame(width: 6, height: 6)
                        }
                    }

                    // Tagline
                    Text(card.tagline)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.40))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if let activity = card.compositionLayerActivity {
                        HStack(spacing: 4) {
                            if card.isAIGenerated {
                                Image(systemName: "wand.and.stars")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(HuePalette.amber.opacity(0.95))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 3)
                                    .background(
                                        Capsule().fill(HuePalette.amber.opacity(0.14))
                                    )
                                    .overlay(
                                        Capsule().strokeBorder(HuePalette.amber.opacity(0.30), lineWidth: 1)
                                    )
                            }
                            layerChip("🎨", isActive: activity.palette)
                            layerChip("🌊", isActive: activity.motion)
                            layerChip("📈", isActive: activity.envelope)
                            layerChip("🎤", isActive: activity.reaction)
                        }
                        .padding(.top, 5)
                    }

                    if let tier = card.compositionTier {
                        HStack(spacing: 4) {
                            compactTierBadge(tier)
                            Spacer(minLength: 0)
                        }
                        .padding(.top, 4)
                    }

                    // Entertainment Area badge
                    if card.isEntertainmentScoped {
                        HStack(spacing: 3) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 8))
                            Text("Entertainment Area")
                                .font(.system(size: 9, weight: .medium))
                        }
                        .foregroundStyle(accentColor.opacity(0.7))
                        .padding(.top, 4)
                    }
                }
                .padding(HueSpacing.lg)
            }
            .aspectRatio(0.9, contentMode: .fit)
        }
        .buttonStyle(StudioCardButtonStyle())
        .animation(HueAnimation.normal, value: isRunning)
    }
}

private func layerChip(_ symbol: String, isActive: Bool) -> some View {
    Text(symbol)
        .font(.system(size: 10, weight: .semibold))
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .foregroundStyle(isActive ? HuePalette.amber : .white.opacity(0.45))
        .background(
            Capsule().fill(
                isActive ? HuePalette.amber.opacity(0.16) : Color.white.opacity(0.06)
            )
        )
        .overlay(
            Capsule().strokeBorder(
                isActive ? HuePalette.amber.opacity(0.35) : Color.white.opacity(0.10),
                lineWidth: 1
            )
        )
}

private func compactTierBadge(_ tier: CompositionTier) -> some View {
    let title: String
    let icon: String
    let tint: Color
    switch tier {
    case .bridgeOptimized:
        title = "Bridge"
        icon = "bolt.fill"
        tint = HuePalette.amber
    case .hybrid:
        title = "Hybrid"
        icon = "arrow.triangle.merge"
        tint = HuePalette.amber
    case .runtimeOnly:
        title = "App Driven"
        icon = "iphone"
        tint = Color.white.opacity(0.78)
    }

    return HStack(spacing: 3) {
        Image(systemName: icon)
            .font(.system(size: 8, weight: .bold))
        Text(title)
            .font(.system(size: 9, weight: .bold))
            .lineLimit(1)
    }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .foregroundStyle(tint)
        .background(Capsule().fill(tint.opacity(0.14)))
        .overlay(
            Capsule()
                .strokeBorder(tint.opacity(0.30), lineWidth: 1)
        )
}

// MARK: - StudioCardButtonStyle
// ButtonStyle cooperates with parent TabView(.page) gestures.
// DragGesture(minimumDistance: 0) was eating horizontal swipes.

struct StudioCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(HueAnimation.fast, value: configuration.isPressed)
    }
}

// MARK: - StudioParamRow
//
// Performance note: slider still uses @Bindable vm for now.
// Phase 1 priority is layout. Phase 3 will convert to local @State + onCommit.

struct StudioParamRow: View {

    let param: StudioParam
    let cardID: String
    @Bindable var vm: StudioViewModel

    var body: some View {
        switch param.kind {
        case .slider(let min, let max):
            sliderRow(param: param, min: min, max: max)
        case .colorPicker:
            colorPickerRow(param: param)
        case .toggle:
            toggleRow(param: param)
        }
    }

    private func sliderRow(param: StudioParam, min: Double, max: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(param.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.60))
                Spacer()
                Text("\(Int(vm.paramValue(for: cardID, paramID: param.id, default: param.defaultValue)))")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.40))
            }
            Slider(
                value: Binding(
                    get: { vm.paramValue(for: cardID, paramID: param.id, default: param.defaultValue) },
                    set: { vm.setParamValue(for: cardID, paramID: param.id, value: $0) }
                ),
                in: min...max
            )
            .tint(HuePalette.amber)
            .onChange(of: vm.paramValues[cardID]?[param.id]) { _, newValue in
                guard let value = newValue else { return }
                // Send live updates for bridge-controllable params
                vm.sendParam(cardID: cardID, paramID: param.id, value: value)
            }
        }
    }

    private func colorPickerRow(param: StudioParam) -> some View {
        HStack {
            Text(param.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.60))
            Spacer()
            HStack(spacing: 8) {
                ForEach(StudioViewModel.presetColors, id: \.self) { color in
                    let isActive = vm.paramColor(for: cardID, paramID: param.id) == color
                    Circle()
                        .fill(color)
                        .frame(width: 26, height: 26)
                        .overlay(Circle().strokeBorder(.white, lineWidth: isActive ? 2 : 0))
                        .onTapGesture {
                            withAnimation(HueAnimation.fast) {
                                vm.setParamColor(for: cardID, paramID: param.id, color: color)
                            }
                        }
                }
            }
        }
    }

    private func toggleRow(param: StudioParam) -> some View {
        HStack {
            Text(param.label)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.white)
            Spacer()
            Toggle("", isOn: Binding(
                get: { vm.paramValue(for: cardID, paramID: param.id, default: 0) > 0.5 },
                set: { vm.setParamValue(for: cardID, paramID: param.id, value: $0 ? 1 : 0) }
            ))
            .tint(HuePalette.amber)
            .labelsHidden()
        }
    }
}

// MARK: - StudioParamSheet
//
// Full parameter sheet with sections: Essential, Color, Advanced.
// Presented as a half-sheet from the mixer tray chevron.

struct StudioParamSheet: View {

    let card: StudioCard
    @Bindable var vm: StudioViewModel

    private var essentialParams: [StudioParam] { card.params.filter { $0.tier == .essential } }
    private var colorParams: [StudioParam]     { card.params.filter { $0.tier == .color } }
    private var advancedParams: [StudioParam]   { card.params.filter { $0.tier == .advanced } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: HueSpacing.lg) {
                    // ── Essential ─────────────────────────────
                    if !essentialParams.isEmpty {
                        paramSection(title: "ESSENTIAL", params: essentialParams)
                    }

                    // ── Color ────────────────────────────────
                    if !colorParams.isEmpty {
                        paramSection(title: "COLOR", params: colorParams)
                    }

                    // ── Advanced ─────────────────────────────
                    if !advancedParams.isEmpty {
                        paramSection(title: "ADVANCED", params: advancedParams)
                    }

                    // ── Stop button ──────────────────────────
                    Button {
                        Task { await vm.explicitStop(card) }
                        HapticManager.shared.medium()
                    } label: {
                        HStack {
                            Image(systemName: "stop.fill")
                            Text("Stop \(card.name)")
                                .fontWeight(.semibold)
                        }
                        .foregroundStyle(HuePalette.Noir.destructive)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: HueRadius.lg)
                                .fill(HuePalette.Noir.destructive.opacity(0.12))
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.top, HueSpacing.sm)
                }
                .padding(HueSpacing.screenH)
            }
            .navigationTitle(card.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }

    private func paramSection(title: String, params: [StudioParam]) -> some View {
        VStack(alignment: .leading, spacing: HueSpacing.md) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
                .tracking(0.8)

            ForEach(params) { param in
                StudioParamRow(param: param, cardID: card.id, vm: vm)
            }
        }
    }
}
