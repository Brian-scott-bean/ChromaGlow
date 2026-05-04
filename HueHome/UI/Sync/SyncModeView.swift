// SyncModeView.swift
// CastChroma — Sync Mode UI
//
// Full-screen reactive lighting experience. Premium glassmorphic design
// matching the rest of CastChroma's aesthetic.
// Adaptive layout: uses GeometryReader to scale visualizer area
// proportionally, ensuring it fits all iOS device sizes (SE → Pro Max).

import SwiftUI

struct SyncModeView: View {
    @Environment(UnifiedOrchestrator.self) private var orchestrator
    @State private var engine: SyncModeEngine?
    @State private var showSettings = false

    private let amber = Color(red: 1.0, green: 0.76, blue: 0.20)

    var body: some View {
        ZStack {
            background
            if let engine {
                content(engine: engine)
            } else {
                ProgressView().tint(.white)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showSettings = true } label: {
                    Image(systemName: "gear")
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsView(onForget: { showSettings = false }) }
        }
        .preferredColorScheme(.dark)
        .onAppear  { engine = SyncModeEngine(orchestrator: orchestrator) }
        .onDisappear { engine?.stop() }
    }

    // ══════════════════════════════════════════════════════════════
    // MARK: - Background
    // ══════════════════════════════════════════════════════════════

    private var background: some View {
        ZStack {
            Color(red: 0.04, green: 0.04, blue: 0.07).ignoresSafeArea()

            let hour = Calendar.current.component(.hour, from: Date())
            let isNight = hour >= 20 || hour < 6
            Circle()
                .fill(RadialGradient(
                    colors: [
                        (isNight
                            ? Color(hue: 0.65, saturation: 0.4, brightness: 0.5)
                            : Color(hue: 0.08, saturation: 0.35, brightness: 0.6)
                        ).opacity(0.10),
                        .clear
                    ],
                    center: .center, startRadius: 0, endRadius: 300
                ))
                .frame(width: 500)
                .offset(y: -60)
                .blur(radius: 50)

            // Reactive glow from engine
            if let e = engine, e.isRunning {
                RadialGradient(
                    colors: [
                        e.visualizer.glowColor.opacity(Double(e.visualizer.overallLevel) * 0.55),
                        Color.clear
                    ],
                    center: .center,
                    startRadius: 10,
                    endRadius: 280
                )
                .ignoresSafeArea()
                .animation(.easeOut(duration: 0.12), value: e.visualizer.overallLevel)
            }
        }
    }

    // ══════════════════════════════════════════════════════════════
    // MARK: - Content
    // ══════════════════════════════════════════════════════════════

    private func content(engine: SyncModeEngine) -> some View {
        GeometryReader { geo in
            let isCompact = geo.size.height < 700  // iPhone SE / small screens
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    // ── Header row ──
                    headerRow(engine: engine)
                        .padding(.top, 4)

                    // ── Start / Stop orb ──
                    SyncStartStopButton(engine: engine, compact: isCompact)
                        .padding(.top, isCompact ? 12 : 16)
                        .padding(.bottom, isCompact ? 4 : 8)

                    // ── Equalizer bars ──
                    SyncEqualizerView(
                        bars: engine.visualizer.barHeights,
                        colorMode: engine.visualizer.colorMode
                    )
                    .frame(height: isCompact ? 80 : 100)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 4)

                    // ── Level meters ──
                    SyncLevelMeterRow(visualizer: engine.visualizer)
                        .padding(.horizontal, 24)
                        .padding(.bottom, isCompact ? 10 : 14)

                    // ── Controls card ──
                    controlsCard(engine: engine, compact: isCompact)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)

                    // Tab bar clearance
                    Color.clear.frame(height: 80)
                }
            }
        }
    }

    // ══════════════════════════════════════════════════════════════
    // MARK: - Header Row
    // ══════════════════════════════════════════════════════════════

    private func headerRow(engine: SyncModeEngine) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(amber)
            Text("Sync")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)

            Spacer(minLength: 8)

            // Engine selector pills
            ForEach(SyncEngineType.allCases) { type in
                let isActive = engine.activeEngineType == type
                Button {
                    engine.switchEngine(to: type)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: type.icon)
                            .font(.system(size: 10, weight: .semibold))
                        Text(type.rawValue)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(isActive ? Color(red: 0.05, green: 0.05, blue: 0.10) : .white.opacity(0.65))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(isActive ? amber : Color.white.opacity(0.06))
                    )
                    .overlay(
                        Capsule().strokeBorder(isActive ? .clear : .white.opacity(0.08), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
    }

    // ══════════════════════════════════════════════════════════════
    // MARK: - Controls Card
    // ══════════════════════════════════════════════════════════════

    private func controlsCard(engine: SyncModeEngine, compact: Bool) -> some View {
        VStack(spacing: compact ? 12 : 16) {
            // Engine-specific controls
            switch engine.activeEngineType {
            case .visualizer:
                visualizerControls(engine: engine)
            }

            Divider().background(.white.opacity(0.08))

            // Master intensity
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    sectionLabel("Intensity")
                    Spacer()
                    Text(String(format: "%.0f%%", engine.masterIntensity * 100))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(amber.opacity(0.7))
                }
                Slider(value: Binding(
                    get: { engine.masterIntensity },
                    set: { engine.masterIntensity = $0 }
                ), in: 0.1...1.0)
                .tint(amber)
            }

            Divider().background(.white.opacity(0.08))

            // Room picker
            SyncRoomPicker(engine: engine, rooms: orchestrator.allRooms)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.white.opacity(0.03))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.12), .white.opacity(0.04)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
        )
    }

    private func visualizerControls(engine: SyncModeEngine) -> some View {
        VStack(spacing: 14) {
            // Color mode
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Color Mode")
                // Flexible wrap layout for color mode chips
                HStack(spacing: 8) {
                    ForEach(VisualizerColorMode.allCases) { mode in
                        SyncColorModeChip(
                            mode: mode,
                            isSelected: engine.visualizer.colorMode == mode
                        ) {
                            withAnimation(.spring(response: 0.3)) {
                                engine.visualizer.colorMode = mode
                            }
                        }
                    }
                }
            }

            Divider().background(.white.opacity(0.08))

            // Sensitivity
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    sectionLabel("Sensitivity")
                    Spacer()
                    Text(String(format: "%.0f%%", engine.visualizer.sensitivity * 100))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                }
                Slider(value: Binding(
                    get: { engine.visualizer.sensitivity },
                    set: { engine.visualizer.sensitivity = $0 }
                ), in: 0.3...3.0)
                .tint(amber)
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white.opacity(0.45))
            .textCase(.uppercase)
            .tracking(0.8)
    }
}

// ══════════════════════════════════════════════════════════════════
// MARK: - Equalizer Bars
// ══════════════════════════════════════════════════════════════════

struct SyncEqualizerView: View {
    let bars: [Float]
    let colorMode: VisualizerColorMode

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<bars.count, id: \.self) { i in
                    SyncBarView(
                        height: bars[i],
                        maxHeight: geo.size.height,
                        index: i,
                        count: bars.count,
                        colorMode: colorMode
                    )
                }
            }
        }
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

// ══════════════════════════════════════════════════════════════════
// MARK: - Start / Stop Button
// ══════════════════════════════════════════════════════════════════

struct SyncStartStopButton: View {
    let engine: SyncModeEngine
    var compact: Bool = false
    @State private var pulsing = false

    private let amber = Color(red: 1.0, green: 0.76, blue: 0.20)

    private var discSize: CGFloat { compact ? 56 : 64 }
    private var ringSize: CGFloat { compact ? 76 : 84 }

    var body: some View {
        VStack(spacing: 8) {
            Button {
                if engine.isRunning { engine.stop() } else { engine.start() }
                HapticManager.shared.medium()
            } label: {
                ZStack {
                    // Outer pulse ring
                    Circle()
                        .strokeBorder(
                            engine.isRunning
                                ? amber.opacity(pulsing ? 0 : 0.4)
                                : Color.clear,
                            lineWidth: 2
                        )
                        .frame(width: ringSize, height: ringSize)
                        .scaleEffect(pulsing ? 1.35 : 1.0)

                    // Background disc
                    Circle()
                        .fill(
                            engine.isRunning
                                ? LinearGradient(
                                    colors: [amber.opacity(0.9), amber],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                  )
                                : LinearGradient(
                                    colors: [Color.white.opacity(0.10), Color.white.opacity(0.06)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                  )
                        )
                        .frame(width: discSize, height: discSize)
                        .shadow(
                            color: engine.isRunning ? amber.opacity(0.5) : .clear,
                            radius: 16
                        )

                    // Icon
                    Image(systemName: "waveform")
                        .font(.system(size: compact ? 22 : 24, weight: .medium))
                        .foregroundStyle(
                            engine.isRunning
                                ? Color(red: 0.05, green: 0.05, blue: 0.10)
                                : .white.opacity(0.6)
                        )
                        .symbolEffect(.bounce, value: engine.isRunning)
                }
            }
            .buttonStyle(.plain)
            .onChange(of: engine.isRunning) { _, running in
                if running {
                    withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                        pulsing = true
                    }
                } else {
                    pulsing = false
                }
            }

            // Status label
            Text(engine.isRunning ? "Listening…" : "Tap to start")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(engine.isRunning ? 0.6 : 0.35))

            // Permission denied hint
            if engine.permissionDenied {
                Text("Microphone access denied — enable in Settings")
                    .font(.system(size: 11))
                    .foregroundStyle(.red.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
    }
}

// ══════════════════════════════════════════════════════════════════
// MARK: - Level Meters
// ══════════════════════════════════════════════════════════════════

struct SyncLevelMeterRow: View {
    let visualizer: VisualizerEngine

    var body: some View {
        HStack(spacing: 14) {
            SyncLevelPill(label: "BASS",     value: visualizer.bassLevel,    color: .orange)
            SyncLevelPill(label: "MID",      value: visualizer.midLevel,     color: .yellow)
            SyncLevelPill(label: "HIGH",     value: visualizer.highLevel,    color: .cyan)
            SyncLevelPill(label: "OVERALL",  value: visualizer.overallLevel, color: .white)
        }
    }
}

struct SyncLevelPill: View {
    let label:  String
    let value:  Float
    let color:  Color

    var body: some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.system(size: 8, weight: .semibold))
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
            .frame(height: 28)
        }
        .frame(maxWidth: .infinity)
    }
}

// ══════════════════════════════════════════════════════════════════
// MARK: - Color Mode Chip
// ══════════════════════════════════════════════════════════════════

struct SyncColorModeChip: View {
    let mode: VisualizerColorMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: mode.icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(mode.rawValue)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(isSelected ? Color(red: 0.05, green: 0.05, blue: 0.10) : .white.opacity(0.55))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(
                Capsule().fill(isSelected ? mode.color : .white.opacity(0.06))
            )
            .overlay(
                Capsule().strokeBorder(isSelected ? .clear : .white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// ══════════════════════════════════════════════════════════════════
// MARK: - Room Picker
// ══════════════════════════════════════════════════════════════════

struct SyncRoomPicker: View {
    let engine: SyncModeEngine
    let rooms:  [RoomDisplayItem]

    private let amber = Color(red: 1.0, green: 0.76, blue: 0.20)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("ROOMS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .tracking(0.8)
                Spacer()
                if !engine.selectedRoomIDs.isEmpty {
                    Text("\(engine.selectedRoomIDs.count) selected")
                        .font(.system(size: 10))
                        .foregroundStyle(amber.opacity(0.65))
                }
            }

            if rooms.isEmpty {
                Text("No rooms loaded — open the Home tab first")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.35))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        let allSelected = rooms.allSatisfy { engine.selectedRoomIDs.contains($0.id) }
                        syncRoomChip(name: "All", icon: "house.fill", selected: allSelected) {
                            withAnimation(.spring(response: 0.25)) {
                                if allSelected { engine.selectedRoomIDs.removeAll() }
                                else { engine.selectedRoomIDs = Set(rooms.map(\.id)) }
                            }
                        }

                        ForEach(rooms) { room in
                            let sel = engine.selectedRoomIDs.contains(room.id)
                            syncRoomChip(
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

    private func syncRoomChip(name: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10))
                Text(name).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(selected ? Color(red: 0.05, green: 0.05, blue: 0.10) : .white.opacity(0.6))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(
                Capsule().fill(selected ? amber : .white.opacity(0.06))
            )
            .overlay(
                Capsule().strokeBorder(selected ? .clear : .white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
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
