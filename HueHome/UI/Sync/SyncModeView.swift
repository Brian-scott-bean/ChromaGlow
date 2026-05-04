// SyncModeView.swift
// CastChroma — Sync Mode Tab
//
// Rebuilt from scratch to match the proven EffectsView / DashboardView
// layout scaffold: system .navigationTitle(.large), ZStack background,
// simple ScrollView > VStack(spacing: 0), consistent .padding(.horizontal, 20).

import SwiftUI

// MARK: - SyncModeView

struct SyncModeView: View {

    @Environment(UnifiedOrchestrator.self) private var orchestrator
    @State private var engine: SyncModeEngine?
    @State private var showSettings = false
    @State private var showCreateArea = false

    private let amber = Color(red: 1.0, green: 0.76, blue: 0.20)

    var body: some View {
        ZStack {
            ambientBackground

            if let engine {
                mainScrollContent(engine: engine)
            } else {
                ProgressView().tint(.white)
            }
        }
        .navigationTitle("Sync")
        .navigationBarTitleDisplayMode(.large)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar { toolbarItems }
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsView(onForget: { showSettings = false }) }
        }
        .preferredColorScheme(.dark)
        .onAppear  { if engine == nil { engine = SyncModeEngine(orchestrator: orchestrator) } }
        .onDisappear { engine?.stop() }
        .sheet(isPresented: $showCreateArea) {
            EntertainmentConfigBuilderView { newConfig in
                engine?.selectedEntertainmentConfig = newConfig
                Task { await engine?.loadEntertainmentConfigs() }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Button { showSettings = true } label: {
                Image(systemName: "gear")
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    // MARK: - Background (same pattern as EffectsView)

    private var ambientBackground: some View {
        ZStack {
            Color(red: 0.055, green: 0.055, blue: 0.08).ignoresSafeArea()

            // Reactive glow when running
            if let e = engine, e.isRunning {
                Circle()
                    .fill(RadialGradient(
                        colors: [
                            e.visualizer.glowColor.opacity(Double(e.visualizer.overallLevel) * 0.45),
                            .clear
                        ],
                        center: .center, startRadius: 0, endRadius: 240
                    ))
                    .frame(width: 400)
                    .offset(x: 80, y: -180)
                    .blur(radius: 30)
                    .animation(.easeOut(duration: 0.12), value: e.visualizer.overallLevel)

                // Gaming transient flash
                if e.activeEngineType == .gaming && e.gaming.isTransient {
                    Circle()
                        .fill(RadialGradient(
                            colors: [e.gaming.flashColor.accentColor.opacity(Double(e.gaming.transientIntensity) * 0.6), .clear],
                            center: .center, startRadius: 0, endRadius: 300
                        ))
                        .frame(width: 600)
                        .blur(radius: 40)
                        .animation(.easeOut(duration: 0.08), value: e.gaming.transientIntensity)
                }
            }

            // Static ambient orb
            Circle()
                .fill(RadialGradient(
                    colors: [amber.opacity(0.08), .clear],
                    center: .center, startRadius: 0, endRadius: 160
                ))
                .frame(width: 280)
                .offset(x: -120, y: 200)
                .blur(radius: 24)
        }
        .ignoresSafeArea()
    }

    // MARK: - Main Scroll Content

    private func mainScrollContent(engine: SyncModeEngine) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {

                // ── Engine selector ─────────────────────────────
                engineSelector(engine: engine)
                    .padding(.top, 4)
                    .padding(.bottom, 12)

                // ── Start / Stop orb ────────────────────────────
                startStopSection(engine: engine)
                    .padding(.bottom, 16)

                // ── Equalizer bars ──────────────────────────────
                SyncEqualizerView(
                    bars: engine.visualizer.barHeights,
                    colorMode: engine.visualizer.colorMode
                )
                .frame(height: 100)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

                // ── Level meters ────────────────────────────────
                levelMeters(engine: engine)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)

                // ── Controls card ───────────────────────────────
                controlsCard(engine: engine)
                    .padding(.horizontal, 20)

                // Bottom pad for tab bar
                Color.clear.frame(height: 120)
            }
        }
    }

    // MARK: - Engine Selector

    private func engineSelector(engine: SyncModeEngine) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(SyncEngineType.allCases) { type in
                    let isActive = engine.activeEngineType == type
                    Button {
                        engine.switchEngine(to: type)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: type.icon)
                                .font(.system(size: 12, weight: .medium))
                            Text(type.rawValue)
                                .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                        }
                        .foregroundStyle(isActive ? .black : .white.opacity(0.75))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(
                            Capsule().fill(isActive ? amber : Color.white.opacity(0.10))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Start / Stop

    private func startStopSection(engine: SyncModeEngine) -> some View {
        VStack(spacing: 10) {
            Button {
                if engine.isRunning { engine.stop() } else { engine.start() }
                HapticManager.shared.medium()
            } label: {
                ZStack {
                    // Outer pulse ring (only visible when running)
                    if engine.isRunning {
                        Circle()
                            .strokeBorder(amber.opacity(0.3), lineWidth: 2)
                            .frame(width: 84, height: 84)
                    }

                    // Disc
                    Circle()
                        .fill(
                            engine.isRunning
                            ? LinearGradient(colors: [amber.opacity(0.9), amber],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)
                            : LinearGradient(colors: [Color.white.opacity(0.10), Color.white.opacity(0.06)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .frame(width: 64, height: 64)
                        .shadow(color: engine.isRunning ? amber.opacity(0.5) : .clear, radius: 16)

                    // Icon
                    Image(systemName: "waveform")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(engine.isRunning ? Color(red: 0.05, green: 0.05, blue: 0.10) : .white.opacity(0.6))
                        .symbolEffect(.bounce, value: engine.isRunning)
                }
            }
            .buttonStyle(.plain)

            Text(engine.isRunning ? "Listening…" : "Tap to start")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(engine.isRunning ? 0.6 : 0.35))

            // Transport mode badge
            if engine.isRunning {
                HStack(spacing: 5) {
                    Image(systemName: engine.transportMode == .entertainment ? "bolt.fill" : "antenna.radiowaves.left.and.right")
                        .font(.system(size: 9, weight: .bold))
                    Text(engine.transportMode.rawValue)
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(engine.transportMode == .entertainment ? amber : .white.opacity(0.5))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(
                    Capsule().fill(
                        engine.transportMode == .entertainment
                        ? amber.opacity(0.15)
                        : .white.opacity(0.06)
                    )
                )
                .transition(.opacity)
            }

            if engine.permissionDenied {
                Text("Microphone access denied — enable in Settings")
                    .font(.system(size: 12))
                    .foregroundStyle(.red.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
    }

    // MARK: - Level Meters

    private func levelMeters(engine: SyncModeEngine) -> some View {
        HStack(spacing: 14) {
            levelPill("BASS",    engine.visualizer.bassLevel,    .orange)
            levelPill("MID",     engine.visualizer.midLevel,     .yellow)
            levelPill("HIGH",    engine.visualizer.highLevel,    .cyan)
            levelPill("OVERALL", engine.visualizer.overallLevel, .white)
        }
    }

    private func levelPill(_ label: String, _ value: Float, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
                .tracking(0.5)

            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.white.opacity(0.08))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.opacity(0.85))
                        .frame(height: geo.size.height * CGFloat(value))
                        .animation(.spring(response: 0.1), value: value)
                }
            }
            .frame(height: 30)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Controls Card (same card style as app-wide pattern)

    private func controlsCard(engine: SyncModeEngine) -> some View {
        VStack(spacing: 16) {

            // ── Color Mode (Visualizer only) ──────────────────
            if engine.activeEngineType == .visualizer {
                VStack(alignment: .leading, spacing: 10) {
                    sectionLabel("Color Mode")
                    HStack(spacing: 8) {
                        ForEach(VisualizerColorMode.allCases) { mode in
                            colorModeChip(mode: mode, isSelected: engine.visualizer.colorMode == mode) {
                                withAnimation(.spring(response: 0.3)) {
                                    engine.visualizer.colorMode = mode
                                }
                            }
                        }
                    }
                }
                Divider().background(.white.opacity(0.08))
            }

            // ── Gaming Controls ───────────────────────────────
            if engine.activeEngineType == .gaming {
                gamingControls(engine: engine)
                Divider().background(.white.opacity(0.08))
            }

            // ── Sensitivity ─────────────────────────────────
            sliderRow(
                label: "Sensitivity",
                value: Binding(get: { engine.visualizer.sensitivity }, set: { engine.visualizer.sensitivity = $0 }),
                range: 0.3...3.0,
                displayValue: String(format: "%.0f%%", engine.visualizer.sensitivity * 100),
                tint: amber
            )

            Divider().background(.white.opacity(0.08))

            // ── Intensity ───────────────────────────────────
            sliderRow(
                label: "Intensity",
                value: Binding(get: { engine.masterIntensity }, set: { engine.masterIntensity = $0 }),
                range: 0.1...1.0,
                displayValue: String(format: "%.0f%%", engine.masterIntensity * 100),
                tint: amber
            )

            Divider().background(.white.opacity(0.08))

            // ── Room Picker ─────────────────────────────────
            roomPicker(engine: engine)

            // ── Entertainment Config ────────────────────────
            Divider().background(.white.opacity(0.08))
            entertainmentPicker(engine: engine)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    // MARK: - Gaming Controls

    private func gamingControls(engine: SyncModeEngine) -> some View {
        VStack(spacing: 16) {

            // Flash Color
            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("Flash Color")
                HStack(spacing: 8) {
                    ForEach(GamingFlashColor.allCases) { color in
                        let sel = engine.gaming.flashColor == color
                        Button { engine.gaming.flashColor = color } label: {
                            HStack(spacing: 5) {
                                Circle().fill(color.accentColor).frame(width: 10, height: 10)
                                Text(color.rawValue).font(.system(size: 12, weight: sel ? .semibold : .regular))
                            }
                            .foregroundStyle(sel ? .black : .white.opacity(0.6))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Capsule().fill(sel ? color.accentColor : .white.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider().background(.white.opacity(0.08))

            // Ambient Color
            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("Ambient")
                HStack(spacing: 8) {
                    ForEach(GamingAmbientColor.allCases) { color in
                        let sel = engine.gaming.ambientColor == color
                        Button { engine.gaming.ambientColor = color } label: {
                            Text(color.rawValue).font(.system(size: 12, weight: sel ? .semibold : .regular))
                                .foregroundStyle(sel ? .black : .white.opacity(0.6))
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(Capsule().fill(sel ? color.accentColor : .white.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider().background(.white.opacity(0.08))

            // Spike Sensitivity
            sliderRow(
                label: "Spike Sensitivity",
                value: Binding(get: { engine.gaming.sensitivity }, set: { engine.gaming.sensitivity = $0 }),
                range: 1.2...3.0,
                displayValue: String(format: "%.1fx", engine.gaming.sensitivity),
                tint: Color(hue: 0.08, saturation: 0.9, brightness: 0.95)
            )
        }
    }

    // MARK: - Entertainment Config Picker

    private func entertainmentPicker(engine: SyncModeEngine) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("Entertainment Area")
                Spacer()
                if engine.selectedEntertainmentConfig != nil {
                    HStack(spacing: 3) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 8))
                        Text("Low Latency")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(amber.opacity(0.7))
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // "None" option (REST fallback)
                    entertainmentChip(
                        name: "None",
                        icon: "antenna.radiowaves.left.and.right",
                        selected: engine.selectedEntertainmentConfig == nil
                    ) {
                        withAnimation(.spring(response: 0.25)) {
                            engine.selectedEntertainmentConfig = nil
                        }
                    }

                    ForEach(engine.availableEntertainmentConfigs) { config in
                        let sel = engine.selectedEntertainmentConfig?.id == config.id
                        entertainmentChip(
                            name: config.name,
                            icon: "bolt.fill",
                            selected: sel
                        ) {
                            withAnimation(.spring(response: 0.25)) {
                                engine.selectedEntertainmentConfig = sel ? nil : config
                            }
                        }
                    }
                }
            }

            if let error = engine.entertainmentError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red.opacity(0.7))
                    .lineLimit(2)
            }

            // Create Area button
            Button {
                showCreateArea = true
                HapticManager.shared.light()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                    Text(engine.availableEntertainmentConfigs.isEmpty ? "Create Entertainment Area" : "New Area")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(amber.opacity(0.7))
                .padding(.top, 4)
            }
            .buttonStyle(.plain)
        }
    }

    private func entertainmentChip(name: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .medium))
                Text(name).font(.system(size: 12, weight: selected ? .semibold : .regular))
            }
            .foregroundStyle(selected ? .black : .white.opacity(0.7))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(
                Capsule().fill(selected ? amber : .white.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Slider Row (reusable)

    private func sliderRow(label: String, value: Binding<Double>, range: ClosedRange<Double>, displayValue: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionLabel(label)
                Spacer()
                Text(displayValue)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Slider(value: value, in: range).tint(tint)
        }
    }

    // MARK: - Color Mode Chip

    private func colorModeChip(mode: VisualizerColorMode, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: mode.icon).font(.system(size: 10, weight: .semibold))
                Text(mode.rawValue).font(.system(size: 12, weight: isSelected ? .semibold : .regular))
            }
            .foregroundStyle(isSelected ? .black : .white.opacity(0.55))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(
                Capsule().fill(isSelected ? mode.color : .white.opacity(0.06))
            )
            .overlay(
                Capsule().strokeBorder(isSelected ? .clear : .white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Room Picker

    private func roomPicker(engine: SyncModeEngine) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("Rooms")
                Spacer()
                if !engine.selectedRoomIDs.isEmpty {
                    Text("\(engine.selectedRoomIDs.count) selected")
                        .font(.system(size: 11))
                        .foregroundStyle(amber.opacity(0.65))
                }
            }

            let rooms = orchestrator.allRooms
            if rooms.isEmpty {
                Text("No rooms loaded — open the Home tab first")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.35))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        let allSelected = rooms.allSatisfy { engine.selectedRoomIDs.contains($0.id) }
                        roomChip(name: "All", icon: "house.fill", selected: allSelected) {
                            withAnimation(.spring(response: 0.25)) {
                                if allSelected { engine.selectedRoomIDs.removeAll() }
                                else { engine.selectedRoomIDs = Set(rooms.map(\.id)) }
                            }
                        }

                        ForEach(rooms) { room in
                            let sel = engine.selectedRoomIDs.contains(room.id)
                            roomChip(
                                name: room.name,
                                icon: archetypeIcon(room.archetype),
                                selected: sel
                            ) {
                                withAnimation(.spring(response: 0.25)) {
                                    if sel { engine.selectedRoomIDs.remove(room.id) }
                                    else   { engine.selectedRoomIDs.insert(room.id) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func roomChip(name: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12, weight: .medium))
                Text(name).font(.system(size: 13, weight: selected ? .semibold : .regular))
            }
            .foregroundStyle(selected ? .black : .white.opacity(0.75))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(
                Capsule().fill(selected ? amber : Color.white.opacity(0.10))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.45))
            .tracking(0.8)
    }

    private func archetypeIcon(_ archetype: String?) -> String {
        switch archetype {
        case "living_room":  return "sofa.fill"
        case "kitchen":      return "refrigerator.fill"
        case "bedroom":      return "bed.double.fill"
        case "bathroom":     return "shower.fill"
        case "office":       return "desktopcomputer"
        case "dining":       return "fork.knife"
        case "garage":       return "car.fill"
        case "garden":       return "leaf.fill"
        default:             return "lightbulb.fill"
        }
    }
}

// MARK: - Equalizer Bars

struct SyncEqualizerView: View {
    let bars: [Float]
    let colorMode: VisualizerColorMode

    private let maxBarHeight: CGFloat = 100

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<bars.count, id: \.self) { i in
                SyncBarView(
                    height: bars[i],
                    maxHeight: maxBarHeight,
                    index: i,
                    count: bars.count,
                    colorMode: colorMode
                )
            }
        }
        .frame(height: maxBarHeight, alignment: .bottom)
        .clipped()
    }
}

struct SyncBarView: View {
    let height: Float
    let maxHeight: CGFloat
    let index:  Int
    let count:  Int
    let colorMode: VisualizerColorMode

    private var barColor: Color {
        let t = Double(index) / Double(max(count - 1, 1))
        switch colorMode {
        case .reactive:
            return Color(hue: 0.75 - t * 0.55, saturation: 0.9, brightness: 0.95)
        case .pulse:
            return Color(hue: 0.11, saturation: 0.9, brightness: 0.95)
        case .warm:
            return Color(hue: 0.08 - t * 0.04, saturation: 0.95, brightness: 0.95)
        case .cool:
            return Color(hue: 0.58 + t * 0.08, saturation: 0.85, brightness: 0.95)
        }
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(
                LinearGradient(
                    colors: [barColor, barColor.opacity(0.3)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .frame(maxWidth: .infinity)
            .frame(height: max(3, CGFloat(height) * maxHeight))
            .animation(.spring(response: 0.08, dampingFraction: 0.7), value: height)
    }
}
