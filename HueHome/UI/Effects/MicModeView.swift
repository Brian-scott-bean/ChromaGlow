// MicModeView.swift
// HueHome Pro — Mic Mode UI
//
// Full-screen reactive lighting experience.
// Equalizer bar visualizer, color mode chips, sensitivity, room selector.

import SwiftUI

struct MicModeView: View {
    @Environment(UnifiedOrchestrator.self) private var orchestrator
    @State private var engine: MicModeEngine?
    @State private var showSettings = false

    var body: some View {
        ZStack {
            background
            if let engine {
                content(engine: engine)
            } else {
                ProgressView().tint(.white)
            }
        }
        .navigationTitle("Mic")
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
        .onAppear  { engine = MicModeEngine(orchestrator: orchestrator) }
        .onDisappear { engine?.stop() }
    }

    // MARK: - Background

    private var background: some View {
        ZStack {
            Color(red: 0.04, green: 0.04, blue: 0.10).ignoresSafeArea()

            // Reactive ambient glow behind visualizer
            if let e = engine {
                RadialGradient(
                    colors: [
                        glowColor(engine: e).opacity(Double(e.overallLevel) * 0.55),
                        Color.clear
                    ],
                    center: .center,
                    startRadius: 10,
                    endRadius: 280
                )
                .ignoresSafeArea()
                .animation(.easeOut(duration: 0.12), value: e.overallLevel)
            }
        }
    }

    private func glowColor(engine: MicModeEngine) -> Color {
        switch engine.colorMode {
        case .reactive:
            let b = Double(engine.bassLevel), h = Double(engine.highLevel)
            return b > h ? .orange : .purple
        case .pulse:    return Color(hue: 0.11, saturation: 0.9, brightness: 0.95)
        case .warm:     return .orange
        case .cool:     return .cyan
        }
    }

    // MARK: - Content

    private func content(engine: MicModeEngine) -> some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 16)

            Spacer(minLength: 0)

            // Equalizer visualizer
            EqualizerView(bars: engine.barHeights, colorMode: engine.colorMode)
                .frame(height: 160)
                .padding(.horizontal, 24)

            Spacer(minLength: 0)

            // Big start/stop button
            StartStopButton(engine: engine)
                .padding(.bottom, 12)

            // Level meters
            LevelMeterRow(engine: engine)
                .padding(.horizontal, 24)
                .padding(.bottom, 20)

            // Controls card
            controlsCard(engine: engine)
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 4) {
            Text("Mic Mode")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)
            Text("Lights react to your music in real time")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(.bottom, 8)
    }

    // MARK: - Controls Card

    private func controlsCard(engine: MicModeEngine) -> some View {
        VStack(spacing: 20) {
            // Color mode
            VStack(alignment: .leading, spacing: 10) {
                label("Color Mode")
                HStack(spacing: 10) {
                    ForEach(MicColorMode.allCases) { mode in
                        ColorModeChip(mode: mode, isSelected: engine.colorMode == mode) {
                            withAnimation(.spring(response: 0.3)) { engine.colorMode = mode }
                        }
                    }
                }
            }

            Divider().background(.white.opacity(0.08))

            // Sensitivity
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    label("Sensitivity")
                    Spacer()
                    Text(String(format: "%.0f%%", engine.sensitivity * 100))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                }
                Slider(value: Binding(
                    get: { engine.sensitivity },
                    set: { engine.sensitivity = $0 }
                ), in: 0.3...3.0)
                .tint(Color(hue: 0.11, saturation: 0.9, brightness: 0.95))
            }

            Divider().background(.white.opacity(0.08))

            // Room picker
            RoomPickerSection(engine: engine, rooms: orchestrator.allRooms)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1))
        )
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.45))
            .textCase(.uppercase)
            .tracking(0.8)
    }
}

// MARK: - Equalizer Bars

struct EqualizerView: View {
    let bars: [Float]
    let colorMode: MicColorMode

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<bars.count, id: \.self) { i in
                BarView(height: bars[i], index: i, count: bars.count, colorMode: colorMode)
            }
        }
    }
}

struct BarView: View {
    let height: Float
    let index:  Int
    let count:  Int
    let colorMode: MicColorMode

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
            .frame(height: max(4, CGFloat(height) * 160))
            .animation(.spring(response: 0.08, dampingFraction: 0.7), value: height)
    }
}

// MARK: - Start/Stop Button

struct StartStopButton: View {
    let engine: MicModeEngine
    @State private var pulsing = false

    var body: some View {
        Button {
            if engine.isRunning { engine.stop() } else { engine.start() }
        } label: {
            ZStack {
                // Pulse ring
                Circle()
                    .strokeBorder(
                        engine.isRunning
                            ? Color(hue: 0.11, saturation: 0.9, brightness: 0.95).opacity(pulsing ? 0 : 0.4)
                            : Color.clear,
                        lineWidth: 2
                    )
                    .frame(width: 100, height: 100)
                    .scaleEffect(pulsing ? 1.4 : 1.0)

                // Background disc
                Circle()
                    .fill(
                        engine.isRunning
                            ? Color(hue: 0.11, saturation: 0.9, brightness: 0.95)
                            : Color.white.opacity(0.10)
                    )
                    .frame(width: 76, height: 76)
                    .shadow(
                        color: engine.isRunning
                            ? Color(hue: 0.11, saturation: 0.9, brightness: 0.95).opacity(0.5)
                            : .clear,
                        radius: 20
                    )

                Image(systemName: engine.isRunning ? "mic.fill" : "mic.slash.fill")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(engine.isRunning ? Color(red: 0.05, green: 0.05, blue: 0.12) : .white.opacity(0.6))
                    .symbolEffect(.bounce, value: engine.isRunning)
            }
        }
        .buttonStyle(.plain)
        .onChange(of: engine.isRunning) { _, running in
            if running {
                withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { pulsing = true }
            } else {
                pulsing = false
            }
        }

        // Permission denied hint
        if engine.permissionDenied {
            Text("Microphone access denied — enable in Settings")
                .font(.system(size: 12))
                .foregroundStyle(.red.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }
}

// MARK: - Level Meters

struct LevelMeterRow: View {
    let engine: MicModeEngine

    var body: some View {
        HStack(spacing: 16) {
            LevelPill(label: "BASS",     value: engine.bassLevel,    color: .orange)
            LevelPill(label: "MID",      value: engine.midLevel,     color: .yellow)
            LevelPill(label: "HIGH",     value: engine.highLevel,    color: .cyan)
            LevelPill(label: "OVERALL",  value: engine.overallLevel, color: .white)
        }
    }
}

struct LevelPill: View {
    let label:  String
    let value:  Float
    let color:  Color

    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
                .tracking(0.6)

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
            .frame(height: 32)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Color Mode Chip

struct ColorModeChip: View {
    let mode:       MicColorMode
    let isSelected: Bool
    let action:     () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: mode.icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(mode.rawValue)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(isSelected ? Color(red: 0.05, green: 0.05, blue: 0.12) : .white.opacity(0.55))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(
                Capsule().fill(isSelected ? mode.color : .white.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Room Picker

struct RoomPickerSection: View {
    let engine: MicModeEngine
    let rooms:  [RoomDisplayItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("ROOMS")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .tracking(0.8)
                Spacer()
                if !engine.selectedRoomIDs.isEmpty {
                    Text("\(engine.selectedRoomIDs.count) selected")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }

            if rooms.isEmpty {
                Text("No rooms loaded — open the Home tab first")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.35))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        // All button
                        let allSelected = rooms.allSatisfy { engine.selectedRoomIDs.contains($0.id) }
                        roomChip(
                            name: "All",
                            icon: "house.fill",
                            selected: allSelected
                        ) {
                            withAnimation(.spring(response: 0.25)) {
                                if allSelected {
                                    engine.selectedRoomIDs.removeAll()
                                } else {
                                    engine.selectedRoomIDs = Set(rooms.map(\.id))
                                }
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
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func roomChip(name: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11))
                Text(name).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(selected ? Color(red: 0.05, green: 0.05, blue: 0.12) : .white.opacity(0.6))
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(
                Capsule().fill(selected
                    ? Color(hue: 0.11, saturation: 0.9, brightness: 0.95)
                    : .white.opacity(0.08))
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
