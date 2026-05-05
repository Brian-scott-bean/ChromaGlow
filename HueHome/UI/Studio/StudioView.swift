// StudioView.swift
// CastChroma — v0.15.0 Studio Tab
//
// Unified Effects + Sync screen.
// Layout:
//   1. Room dropdown (explicit selection required)
//   2. EFFECTS carousel (bridge-native, persist after closing)
//   3. LIVE MODES carousel (app-driven, foreground required)
//   4. Controls panel (slides up when a card is selected)

import SwiftUI

// MARK: - StudioView

struct StudioView: View {

    @Environment(UnifiedOrchestrator.self) private var orchestrator
    @State private var vm = StudioViewModel()
    @State private var showSettings = false

    // ── Accent colors ─────────────────────────────────────────
    private let amber  = Color(hex: "#FFC107")
    private let pink   = Color(hex: "#FF4D8C")
    private let purple = Color(hex: "#8C59FF")

    var body: some View {
        ZStack {
            ambientBackground

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {

                    // 1. Room picker
                    roomDropdown
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                        .padding(.bottom, 20)

                    // 2. Bridge-native effects
                    carouselSection(
                        title: "EFFECTS",
                        subtitle: "Persist after closing app",
                        subtitleColor: .white.opacity(0.35),
                        cards: vm.effectCards
                    )
                    .padding(.bottom, 28)

                    // 3. App-driven live modes
                    carouselSection(
                        title: "LIVE MODES",
                        subtitle: "Requires app open",
                        subtitleColor: pink,
                        cards: vm.liveModeCards
                    )
                    .padding(.bottom, 28)

                    // 4. Controls panel (only when a card is selected)
                    if vm.selectedCard != nil {
                        controlsPanel
                            .padding(.horizontal, 20)
                            .padding(.bottom, 32)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
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
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: vm.selectedCard?.id)
    }

    // ──────────────────────────────────────────────
    // MARK: - Background
    // ──────────────────────────────────────────────

    private var ambientBackground: some View {
        GeometryReader { geo in
            ZStack {
                Color(hex: "#0E0E14")
                // Amber orb — top right
                Circle()
                    .fill(RadialGradient(
                        colors: [amber.opacity(0.20), .clear],
                        center: .center, startRadius: 0, endRadius: 180
                    ))
                    .frame(width: 360)
                    .position(x: geo.size.width * 0.85, y: 120)
                    .blur(radius: 30)
                // Purple orb — bottom left
                Circle()
                    .fill(RadialGradient(
                        colors: [purple.opacity(0.18), .clear],
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
    // MARK: - Room Dropdown
    // ──────────────────────────────────────────────

    private var roomDropdown: some View {
        Menu {
            // ── Rooms ─────────────────────────────────────────────
            if !orchestrator.allRooms.isEmpty {
                Section("ROOMS") {
                    ForEach(orchestrator.allRooms, id: \.id) { room in
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                vm.selectedRoom = room
                            }
                        } label: {
                            Label(room.name, systemImage: archetypeIcon(for: room.archetype))
                        }
                    }
                }
            }
            // ── Zones ─────────────────────────────────────────────
            if !orchestrator.allZones.isEmpty {
                Section("ZONES") {
                    ForEach(orchestrator.allZones, id: \.id) { zone in
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                vm.selectedRoom = zone
                            }
                        } label: {
                            Label(zone.name, systemImage: "square.3.layers.3d")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 12) {
                if let room = vm.selectedRoom {
                    Image(systemName: archetypeIcon(for: room.archetype))
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(amber)
                    Text(room.name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: "house.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                    Text("Select a room or zone…")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.40))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                    )
            )
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Carousel Section
    // ──────────────────────────────────────────────

    private func carouselSection(
        title: String,
        subtitle: String,
        subtitleColor: Color,
        cards: [StudioCard]
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .tracking(0.8)
                Text(subtitle)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(subtitleColor)
            }
            .padding(.horizontal, 20)

            // Cards — peek of next card visible on right
            GeometryReader { geo in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(cards) { card in
                            StudioCardView(
                                card: card,
                                isSelected: vm.selectedCard?.id == card.id,
                                isRunning: vm.runningCardID == card.id,
                                roomSelected: vm.selectedRoom != nil
                            ) {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                    if vm.selectedCard?.id == card.id {
                                        vm.selectedCard = nil
                                    } else {
                                        vm.selectedCard = card
                                    }
                                }
                            } onApply: {
                                Task { await vm.apply(card) }
                            } onStop: {
                                Task { await vm.stop(card) }
                            }
                            .frame(width: geo.size.width * 0.78)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 4)
                }
            }
            .frame(height: 230)
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Controls Panel
    // ──────────────────────────────────────────────

    private var controlsPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("CONTROLS")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .tracking(0.8)

            GlassmorphicCard(isActive: false, glowColor: amber, padding: 16) {
                VStack(spacing: 16) {
                    if let card = vm.selectedCard {
                        ForEach(card.params) { param in
                            StudioParamRow(param: param, vm: vm)
                        }
                    }
                }
            }
        }
        // Extra bottom padding so the panel is fully visible above the tab bar.
        // Tab bar height: 64pt + home indicator: 34pt + gap: 24pt = 122pt
        .padding(.bottom, 122)
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
            .tint(Color(hex: "#FFC107"))
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
            .tint(Color(hex: "#FFC107"))
            .labelsHidden()
        }
    }
}
