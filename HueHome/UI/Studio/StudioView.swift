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

    private enum CompositionLayerTab: String, CaseIterable, Identifiable {
        case palette = "🎨 Palette"
        case motion = "🌊 Motion"
        case envelope = "📈 Envelope"
        case reaction = "🎤 React"
        var id: String { rawValue }
    }

    @Environment(UnifiedOrchestrator.self) private var orchestrator
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
    @State private var isAIPromptExpanded = false
    @State private var aiPromptText = ""
    @FocusState private var aiPromptFocused: Bool

    // ── Param sheet ───────────────────────────────────────
    @State private var showParamSheet = false

    // ── Performance ───────────────────────────────────────
    @State private var blurReady = false  // deferred to avoid first-frame GPU hitch

    var body: some View {
        let mixerVisible = vm.currentRoomEffect != nil
        let mixerHeight: CGFloat = mixerVisible ? computeMixerHeight() : 0

        ZStack {
            ambientBackground

            VStack(spacing: 0) {
                // Zone A is now the nav title (no pill strip needed)

                // ── Zone B: Living Card Grid ──────────────────
                cardGrid
                    .frame(maxHeight: .infinity)

                // ── Deck page indicator ───────────────────────
                deckDots
                    .padding(.bottom, HueSpacing.sm)

                // ── Zone C: Mixer Tray ────────────────────────
                if mixerVisible {
                    mixerTray
                        .frame(height: mixerHeight)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Tab bar clearance
                Color.clear.frame(height: 80)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
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
    }

    // Combined rooms + zones
    private var allPickerItems: [RoomDisplayItem] {
        orchestrator.allRooms + orchestrator.allZones
    }

    private func computeMixerHeight() -> CGFloat {
        guard let effect = vm.currentRoomEffect else { return 0 }
        if case .composition = effect.card.strategy {
            return 380
        }
        let essentialCount = effect.card.params.filter { $0.tier == .essential }.count
        // Header (60) + essential sliders (56 each) + chevron row (36) + padding
        return CGFloat(60 + essentialCount * 56 + 36 + 16)
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
    // Swipe L/R = rooms, U/D = zones, tap = sheet
    // ──────────────────────────────────────────────

    private var swipeableRoomTitle: some View {
        let displayName = vm.selectedRoom?.name ?? "Select a room"
        let hasRoom = vm.selectedRoom != nil

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
                HStack(spacing: 5) {
                    Text(displayName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(hasRoom ? .white : .white.opacity(0.45))
                        .id(displayName)
                        .transition(.asymmetric(
                            insertion: .move(edge: slideDirection).combined(with: .opacity),
                            removal: .move(edge: slideDirection == .trailing ? .leading : .trailing).combined(with: .opacity)
                        ))

                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
        }
        .contentShape(Rectangle())
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
                            ? orchestrator.allRooms
                            : orchestrator.allZones
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
        .animation(HueAnimation.card, value: currentDeck)
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
                        let roomSnapshot = vm.selectedRoom
                        if vm.runningCardID == card.id {
                            Task { await vm.explicitStop(card) }
                        } else {
                            Task { await vm.apply(card, roomOverride: roomSnapshot) }
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
                                let roomSnapshot = vm.selectedRoom
                                Task {
                                    if let preset = await vm.generateCompositionFromPrompt(aiPromptText) {
                                        await vm.apply(vm.studioCard(for: preset), roomOverride: roomSnapshot)
                                        aiPromptText = ""
                                        isAIPromptExpanded = false
                                        aiPromptFocused = false
                                        HapticManager.shared.medium()
                                    } else {
                                        HapticManager.shared.light()
                                    }
                                }
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
            VStack(alignment: .leading, spacing: HueSpacing.md) {
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
                        StudioCardView(
                            card: card,
                            isRunning: vm.runningCardID == card.id,
                            roomSelected: vm.selectedRoom != nil,
                            isVisible: visible
                        ) {
                            let roomSnapshot = vm.selectedRoom
                            if vm.runningCardID == card.id {
                                Task { await vm.explicitStop(card) }
                            } else {
                                Task { await vm.apply(card, roomOverride: roomSnapshot) }
                            }
                        }
                        .contextMenu {
                            Button {
                                let roomSnapshot = vm.selectedRoom
                                Task { await vm.apply(vm.studioCard(for: preset), roomOverride: roomSnapshot) }
                                HapticManager.shared.light()
                            } label: {
                                Label("Edit", systemImage: "slider.horizontal.3")
                            }
                            Button {
                                renameCompositionText = preset.name
                                renameCompositionTarget = preset
                                HapticManager.shared.light()
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            Button {
                                vm.duplicateCompositionPreset(preset)
                                HapticManager.shared.light()
                            } label: {
                                Label("Duplicate", systemImage: "doc.on.doc")
                            }
                            Divider()
                            Button(role: .destructive) {
                                Task { await vm.deleteCompositionPreset(preset) }
                                HapticManager.shared.light()
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, HueSpacing.screenH)
            .padding(.vertical, HueSpacing.sm)
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
                        Text(effect.isEntertainment ? "COMPOSER: ENT AREA" : "COMPOSER: ROOM (REST)")
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
                    compositionMixerBody
                        .padding(.horizontal, HueSpacing.screenH)
                        .padding(.top, HueSpacing.md)
                } else {
                    // ── Essential parameter sliders ──────────────
                    let essentialParams = card.params.filter { $0.tier == .essential }
                    if !essentialParams.isEmpty {
                        VStack(spacing: HueSpacing.md) {
                            ForEach(essentialParams) { param in
                                StudioParamRow(param: param, cardID: card.id, vm: vm)
                            }
                        }
                        .padding(.horizontal, HueSpacing.screenH)
                        .padding(.top, HueSpacing.md)
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

    private var compositionMixerBody: some View {
        VStack(alignment: .leading, spacing: HueSpacing.md) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(CompositionLayerTab.allCases) { tab in
                        let selected = activeCompositionTab == tab
                        Button {
                            activeCompositionTab = tab
                            HapticManager.shared.selection()
                        } label: {
                            Text(tab.rawValue)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(selected ? HuePalette.amber : .white.opacity(0.75))
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
            }

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
            Picker("Mode", selection: Binding(
                get: { vm.activeCompositionBox?.palette.mode ?? .gradient },
                set: { vm.activeCompositionBox?.palette.mode = $0 }
            )) {
                ForEach(PaletteConfig.Mode.allCases, id: \.self) { mode in
                    Text(mode.rawValue.capitalized).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 8) {
                ForEach(StudioViewModel.presetColors, id: \.self) { color in
                    Circle()
                        .fill(color)
                        .frame(width: 24, height: 24)
                        .onTapGesture {
                            vm.activeCompositionBox?.palette.color1 = CodableColor.from(color: color)
                            HapticManager.shared.selection()
                        }
                        .onLongPressGesture {
                            vm.activeCompositionBox?.palette.color2 = CodableColor.from(color: color)
                            HapticManager.shared.selection()
                        }
                }
            }

            compositionSlider(
                title: "Saturation",
                value: Binding(
                    get: { vm.activeCompositionBox?.palette.saturation ?? 100 },
                    set: { vm.activeCompositionBox?.palette.saturation = $0 }
                ),
                range: 0...100
            )

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

    private var compositionMotionControls: some View {
        VStack(spacing: HueSpacing.sm) {
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
            Picker("Source", selection: Binding(
                get: { vm.activeCompositionBox?.reaction.source ?? .none },
                set: { vm.activeCompositionBox?.reaction.source = $0 }
            )) {
                ForEach(ReactionConfig.Source.allCases, id: \.self) { source in
                    Text(source.rawValue.replacingOccurrences(of: "_", with: " ").capitalized).tag(source)
                }
            }
            .pickerStyle(.menu)

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
            }
            .navigationTitle("Save Composition")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showCompositionSaveSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        _ = vm.saveActiveComposition(name: compositionSaveName, icon: compositionSaveIcon)
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
                            layerChip("🎨", isActive: activity.palette)
                            layerChip("🌊", isActive: activity.motion)
                            layerChip("📈", isActive: activity.envelope)
                            layerChip("🎤", isActive: activity.reaction)
                        }
                        .padding(.top, 5)
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
