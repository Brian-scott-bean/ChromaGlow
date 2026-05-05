// StudioView.swift
// CastChroma — v0.15.1 Studio Tab
//
// Layout:
//   1. Room wheel picker (inline, no extra tap)
//   2. EFFECTS carousel  — tap card = apply immediately
//   3. EFFECTS inline controls (visible when an effect card is running)
//   4. LIVE MODES carousel
//   5. LIVE MODES inline controls (visible when a live card is running)

import SwiftUI

// MARK: - StudioView

struct StudioView: View {

    @Environment(UnifiedOrchestrator.self) private var orchestrator
    @State private var vm = StudioViewModel()
    @State private var showSettings = false

    // ── Accent colors (from design token system) ────────────
    private let pink   = Color(hex: "#FF4D8C")  // no token yet — Studio-specific

    var body: some View {
        ZStack {
            ambientBackground

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {

                    // 1. Room wheel picker
                    roomWheelPicker
                        .padding(.horizontal, HueSpacing.screenH)
                        .padding(.top, HueSpacing.sm)
                        .padding(.bottom, HueSpacing.md)

                    // 2. Effects
                    carouselSection(
                        title: "EFFECTS",
                        subtitle: "Persist after closing app",
                        subtitleColor: .white.opacity(0.35),
                        cards: vm.effectCards
                    )

                    // 2b. Effects inline controls
                    inlineControls(for: vm.effectCards)
                        .padding(.bottom, HueSpacing.xxl)

                    // 3. Live Modes
                    carouselSection(
                        title: "LIVE MODES",
                        subtitle: "Requires app open",
                        subtitleColor: pink,
                        cards: vm.liveModeCards
                    )

                    // 3b. Live Modes inline controls
                    inlineControls(for: vm.liveModeCards)
                        .padding(.bottom, HueSpacing.xxl + HueSpacing.xs)

                    Color.clear.frame(height: 90)
                }
            }
        }
        .navigationTitle("Studio")
        .navigationBarTitleDisplayMode(.large)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showSettings = true } label: {
                    Image(systemName: "gear").foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsView(onForget: { showSettings = false }) }
        }
        .preferredColorScheme(.dark)
        .onAppear { vm.configure(orchestrator: orchestrator) }
        .animation(HueAnimation.card, value: vm.runningCardID)
    }

    // Combined rooms + zones for the wheel
    private var allPickerItems: [RoomDisplayItem] {
        orchestrator.allRooms + orchestrator.allZones
    }

    // ──────────────────────────────────────────────
    // MARK: - Background
    // ──────────────────────────────────────────────

    private var ambientBackground: some View {
        GeometryReader { geo in
            ZStack {
                HuePalette.Noir.background
                // Amber orb — top right
                Circle()
                    .fill(RadialGradient(
                        colors: [HuePalette.amber.opacity(0.20), .clear],
                        center: .center, startRadius: 0, endRadius: 180
                    ))
                    .frame(width: 360)
                    .position(x: geo.size.width * 0.85, y: 120)
                    .blur(radius: 30)
                // Purple orb — bottom left
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
    // MARK: - Room Wheel Picker
    // ──────────────────────────────────────────────

    private var roomWheelPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("ROOM / ZONE")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .tracking(0.8)
                Spacer()
                if vm.selectedRoom != nil {
                    Text(vm.selectedRoom!.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(HuePalette.amber)
                }
            }

            Picker("", selection: Binding(
                get: { vm.selectedRoom?.id ?? "" },
                set: { id in
                    if let match = allPickerItems.first(where: { $0.id == id }) {
                        vm.selectedRoom = match
                    }
                }
            )) {
                Text("Select a room…").tag("")
                ForEach(orchestrator.allRooms, id: \.id) { room in
                    Text(room.name).tag(room.id)
                }
                ForEach(orchestrator.allZones, id: \.id) { zone in
                    Text("⧡ " + zone.name).tag(zone.id)
                }
            }
            .pickerStyle(.wheel)
            .frame(height: 110)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }


    // ──────────────────────────────────────────────
    // MARK: - Carousel Section
    // Tap = apply immediately. Tap running card = stop.
    // ──────────────────────────────────────────────

    private func carouselSection(
        title: String,
        subtitle: String,
        subtitleColor: Color,
        cards: [StudioCard]
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .tracking(0.8)
                Text(subtitle)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(subtitleColor)
            }
            .padding(.horizontal, HueSpacing.screenH)

            GeometryReader { geo in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: HueSpacing.md + 2) {
                        ForEach(cards) { card in
                            StudioCardView(
                                card: card,
                                isSelected: vm.runningCardID == card.id,
                                isRunning: vm.runningCardID == card.id,
                                roomSelected: vm.selectedRoom != nil
                            ) {
                                // TAP = apply immediately (or stop if already running)
                                if vm.runningCardID == card.id {
                                    Task { await vm.stop(card) }
                                } else {
                                    Task { await vm.apply(card) }
                                }
                            } onApply: {
                                Task { await vm.apply(card) }
                            } onStop: {
                                Task { await vm.stop(card) }
                            }
                            .frame(width: geo.size.width * 0.78)
                        }
                    }
                    .padding(.horizontal, HueSpacing.screenH)
                    .padding(.vertical, HueSpacing.xs)
                }
            }
            .frame(height: 200)
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Inline Controls
    // Shown below a carousel when a card from that
    // carousel is running. No sheet, no extra tap.
    // ──────────────────────────────────────────────

    @ViewBuilder
    private func inlineControls(for cards: [StudioCard]) -> some View {
        let running = cards.first { $0.id == vm.runningCardID }
        if let card = running, !card.params.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: card.icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(card.accentColor)
                    Text(card.name.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                        .tracking(0.8)
                    Spacer()
                    // Live running indicator
                    HStack(spacing: 5) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                            .symbolEffect(.pulse, isActive: true)
                        Text("LIVE")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.green)
                    }
                }
                .padding(.horizontal, HueSpacing.screenH)

                GlassmorphicCard(isActive: true, glowColor: card.accentColor, padding: HueSpacing.lg) {
                    VStack(spacing: HueSpacing.lg) {
                        ForEach(card.params) { param in
                            StudioParamRow(param: param, vm: vm)
                        }
                    }
                }
                .padding(.horizontal, HueSpacing.screenH)
            }
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(HueAnimation.card, value: vm.runningCardID)
        }
    }

}

// MARK: - StudioCardView

struct StudioCardView: View {

    let card: StudioCard
    let isSelected: Bool
    let isRunning: Bool
    let roomSelected: Bool
    let onSelect: () -> Void
    let onApply: () -> Void
    let onStop: () -> Void

    @State private var pressing = false

    private var accentColor: Color { card.accentColor }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Card background
            RoundedRectangle(cornerRadius: 20)
                .fill(isSelected
                      ? accentColor.opacity(0.13)
                      : Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(
                            isSelected ? accentColor.opacity(0.55) : Color.white.opacity(0.08),
                            lineWidth: isSelected ? 1.5 : 1
                        )
                )
                .shadow(
                    color: isRunning ? accentColor.opacity(0.35) : .clear,
                    radius: 16, x: 0, y: 5
                )

            // Content
            VStack(alignment: .leading, spacing: 0) {
                // Top row: icon + foreground badge
                HStack(alignment: .top) {
                    // Icon circle
                    ZStack {
                        Circle()
                            .fill(accentColor.opacity(isSelected ? 0.28 : 0.15))
                            .frame(width: 52, height: 52)
                        Image(systemName: card.icon)
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(accentColor)
                            .symbolEffect(.pulse.byLayer, isActive: isRunning)
                    }

                    Spacer()

                    // Foreground-only badge for live modes
                    if card.requiresForeground {
                        HStack(spacing: 4) {
                            Image(systemName: "iphone")
                                .font(.system(size: 9, weight: .medium))
                            Text("App open")
                                .font(.system(size: 9, weight: .medium))
                        }
                        .foregroundStyle(.white.opacity(0.30))
                        .padding(.top, 4)
                    }
                }
                .padding(.bottom, 14)

                // Name
                Text(card.name)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.bottom, 6)

                // Tagline
                Text(card.tagline)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 18)

                Spacer(minLength: 0)

                // Action button
                if isRunning {
                    // Running state
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 7, height: 7)
                        Text("Running")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.green)
                        Spacer()
                        Button(action: onStop) {
                            Text("Stop")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.red)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(Capsule().fill(Color.red.opacity(0.15)))
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    // Apply / Start button
                    Button(action: onApply) {
                        Text(card.requiresForeground ? "Start" : "Apply")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(roomSelected ? .black : .white.opacity(0.35))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(
                                Capsule()
                                    .fill(roomSelected
                                          ? accentColor
                                          : Color.white.opacity(0.10))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!roomSelected)
                }
            }
            .padding(20)
        }
        .scaleEffect(pressing ? 0.97 : 1.0)
        .onTapGesture { onSelect() }
        .onLongPressGesture(
            minimumDuration: 0,
            pressing: { isPressing in
                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                    pressing = isPressing
                }
            },
            perform: {}
        )
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: isSelected)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: isRunning)
    }
}

// MARK: - StudioParamRow

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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(param.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.60))
                Spacer()
                // Show live value from paramValues, fallback to defaultValue
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
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
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

