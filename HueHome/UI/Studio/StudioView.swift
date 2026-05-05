// StudioView.swift
// CastChroma — v0.16.0 Studio DJ Redesign
//
// Layout: Three fixed zones (no root scroll)
//   Zone A: Rolodex room selector (36pt capsule, expands on tap)
//   Zone B: 2-column living card grid (paged between Effects / Live decks)
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

    @Environment(UnifiedOrchestrator.self) private var orchestrator
    @State private var vm = StudioViewModel()
    @State private var showSettings = false

    // ── Room picker ────────────────────────────────────────
    @State private var showRoomSheet = false
    @State private var dragAxisLocked: Axis? = nil
    @State private var dragRoomSteps: Int = 0        // accumulated steps during drag
    @State private var slideDirection: Edge = .trailing

    // ── Deck paging ───────────────────────────────────────
    @State private var currentDeck: Int = 0  // 0 = Effects, 1 = Live

    var body: some View {
        GeometryReader { geo in
            let mixerVisible = vm.runningCardID != nil
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
        .onAppear { vm.configure(orchestrator: orchestrator) }
        .animation(HueAnimation.slow, value: vm.runningCardID != nil)
        .animation(HueAnimation.card, value: vm.runningCardID)
    }

    // Combined rooms + zones
    private var allPickerItems: [RoomDisplayItem] {
        orchestrator.allRooms + orchestrator.allZones
    }

    private func computeMixerHeight() -> CGFloat {
        guard let card = allCards.first(where: { $0.id == vm.runningCardID }) else { return 0 }
        return CGFloat(80 + card.params.count * 56)
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
        .ignoresSafeArea()
    }

    // ──────────────────────────────────────────────
    // MARK: - Zone A: Swipeable Room Title
    // Swipe L/R = rooms, U/D = zones, tap = sheet
    // ──────────────────────────────────────────────

    private var swipeableRoomTitle: some View {
        let displayName = vm.selectedRoom?.name ?? "Select a room"
        let hasRoom = vm.selectedRoom != nil

        return VStack(spacing: 1) {
            Text("Studio")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.35))
                .tracking(0.5)

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
        .contentShape(Rectangle())
        .onTapGesture {
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
            deckGrid(cards: vm.effectCards)
                .tag(0)

            // Deck 1: Live Modes
            deckGrid(cards: vm.liveModeCards)
                .tag(1)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .animation(HueAnimation.card, value: currentDeck)
    }

    private func deckGrid(cards: [StudioCard]) -> some View {
        let columns = [
            GridItem(.flexible(), spacing: HueSpacing.md),
            GridItem(.flexible(), spacing: HueSpacing.md)
        ]

        return ScrollView(showsIndicators: false) {
            LazyVGrid(columns: columns, spacing: HueSpacing.md) {
                ForEach(cards) { card in
                    StudioCardView(
                        card: card,
                        isRunning: vm.runningCardID == card.id,
                        roomSelected: vm.selectedRoom != nil
                    ) {
                        if vm.runningCardID == card.id {
                            Task { await vm.stop(card) }
                        } else {
                            Task { await vm.apply(card) }
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
            ForEach(0..<2) { i in
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
        let card = allCards.first(where: { $0.id == vm.runningCardID })

        return VStack(spacing: 0) {
            if let card {
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

                    Text(card.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)

                    // Live indicator
                    HStack(spacing: 4) {
                        Circle().fill(HuePalette.Noir.success)
                            .frame(width: 5, height: 5)
                        Text("LIVE")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(HuePalette.Noir.success)
                    }

                    Spacer()

                    // Stop control
                    Button {
                        Task { await vm.stop(card) }
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

                // ── Parameter sliders ────────────────────────
                if !card.params.isEmpty {
                    VStack(spacing: HueSpacing.md) {
                        ForEach(card.params) { param in
                            StudioParamRow(param: param, vm: vm)
                        }
                    }
                    .padding(.horizontal, HueSpacing.screenH)
                    .padding(.top, HueSpacing.md)
                    .padding(.bottom, HueSpacing.sm)
                }
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: HueRadius.xl))
        .padding(.horizontal, HueSpacing.sm)
        .id(vm.runningCardID)  // forces cross-fade on effect switch
        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
    }
}

// MARK: - StudioCardView (Phase 1)
//
// Performance: receives value types only. Never sees the ViewModel.
// The card IS the button — tap to apply/stop. No Apply/Stop sub-buttons.

struct StudioCardView: View {

    let card: StudioCard       // value type (struct)
    let isRunning: Bool        // value type
    let roomSelected: Bool     // value type
    let onTap: () -> Void      // closure

    @State private var pressing = false

    private var accentColor: Color { card.accentColor }

    var body: some View {
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

                // Tagline (Phase 1 — removed in Phase 2 when animations arrive)
                Text(card.tagline)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.40))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(HueSpacing.lg)
        }
        .aspectRatio(0.9, contentMode: .fit)
        .scaleEffect(pressing ? 0.96 : 1.0)
        .contentShape(RoundedRectangle(cornerRadius: HueRadius.xl))
        .onTapGesture {
            onTap()
            HapticManager.shared.medium()
        }
        .onLongPressGesture(
            minimumDuration: 0,
            pressing: { isPressing in
                withAnimation(HueAnimation.fast) {
                    pressing = isPressing
                }
            },
            perform: {}
        )
        .animation(HueAnimation.normal, value: isRunning)
    }
}

// MARK: - StudioParamRow
//
// Performance note: slider still uses @Bindable vm for now.
// Phase 1 priority is layout. Phase 3 will convert to local @State + onCommit.

struct StudioParamRow: View {

    let param: StudioParam
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
                Text("\(Int(vm.paramValues[param.id] ?? param.defaultValue))")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.40))
            }
            Slider(
                value: Binding(
                    get: { vm.paramValues[param.id] ?? param.defaultValue },
                    set: { vm.paramValues[param.id] = $0 }
                ),
                in: min...max
            )
            .tint(HuePalette.amber)
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
                    let isActive = vm.paramColors[param.id] == color
                    Circle()
                        .fill(color)
                        .frame(width: 26, height: 26)
                        .overlay(Circle().strokeBorder(.white, lineWidth: isActive ? 2 : 0))
                        .onTapGesture {
                            withAnimation(HueAnimation.fast) {
                                vm.paramColors[param.id] = color
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
                get: { vm.paramValues[param.id].map { $0 > 0.5 } ?? false },
                set: { vm.paramValues[param.id] = $0 ? 1 : 0 }
            ))
            .tint(HuePalette.amber)
            .labelsHidden()
        }
    }
}
