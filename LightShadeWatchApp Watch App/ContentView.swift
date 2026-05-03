// ContentView.swift — LightShadeWatchApp
// Main room list — the home screen of the watch app.
// Shows all rooms with live on/off status, tap to open detail,
// plus All Off and preset shortcuts at the top.

import SwiftUI

struct ContentView: View {
    @StateObject private var store = WatchStore.shared
    @Environment(\.scenePhase) private var scenePhase
    private let amber = Color(red: 1.0, green: 0.76, blue: 0.20)

    var body: some View {
        NavigationStack {
            List {
                // ── Status header ──
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("CastChroma")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(amber)
                            Text(store.rooms.isEmpty
                                 ? "Open iPhone app first"
                                 : "\(store.rooms.filter(\.isOn).count) of \(store.rooms.count) on")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        // All Off button
                        if store.rooms.contains(where: \.isOn) {
                            Button {
                                Task { await store.allOff() }
                            } label: {
                                Image(systemName: "power")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.black)
                                    .padding(6)
                                    .background(Circle().fill(amber))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listRowBackground(Color.clear)
                }

                // ── Preset chips ──
                Section("Presets") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(WatchPreset.allCases, id: \.rawValue) { preset in
                                Button {
                                    Task { await store.applyPreset(preset) }
                                } label: {
                                    VStack(spacing: 3) {
                                        Image(systemName: preset.icon)
                                            .font(.system(size: 13, weight: .semibold))
                                        Text(preset.label)
                                            .font(.system(size: 9, weight: .medium))
                                    }
                                    .foregroundStyle(preset.color)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(Capsule().fill(preset.color.opacity(0.15)))
                                    .overlay(Capsule().strokeBorder(preset.color.opacity(0.4), lineWidth: 0.5))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                // ── Room list ──
                if store.rooms.isEmpty {
                    Section {
                        VStack(spacing: 8) {
                            Image(systemName: "iphone.and.arrow.forward")
                                .font(.system(size: 28))
                                .foregroundStyle(.secondary)
                            Text("Open CastChroma on your iPhone to sync rooms")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .listRowBackground(Color.clear)
                    }
                } else {
                    Section("Rooms") {
                        ForEach(store.rooms) { room in
                            NavigationLink(destination: RoomDetailView(room: room)) {
                                RoomRowView(room: room)
                            }
                        }
                    }
                }

                // ── Zone list ──
                if !store.zones.isEmpty {
                    Section("Zones") {
                        ForEach(store.zones) { zone in
                            NavigationLink(destination: RoomDetailView(room: zone)) {
                                RoomRowView(room: zone, isZone: true)
                            }
                        }
                    }
                }
            }
            .navigationTitle("CastChroma")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear { store.loadFromLocalCache() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { store.loadFromLocalCache() }
        }
        // Poll every 5 s while rooms are empty so we pick up iPhone pushes automatically
        .task(id: store.rooms.isEmpty) {
            guard store.rooms.isEmpty else { return }
            while store.rooms.isEmpty {
                try? await Task.sleep(for: .seconds(5))
                store.loadFromLocalCache()
            }
        }
    }
}

// MARK: - Room Row

struct RoomRowView: View {
    let room: WatchRoom
    var isZone: Bool = false
    @StateObject private var store = WatchStore.shared
    private let amber = Color(red: 1.0, green: 0.76, blue: 0.20)

    var body: some View {
        HStack(spacing: 10) {
            // Icon with glow when on
            ZStack(alignment: .bottomTrailing) {
                ZStack {
                    if room.isOn {
                        Circle()
                            .fill(amber.opacity(0.2))
                            .frame(width: 30, height: 30)
                    }
                    Image(systemName: watchRoomIcon(room.archetype))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(room.isOn ? amber : .secondary)
                        .frame(width: 30, height: 30)
                }
                // Zone badge
                if isZone {
                    Image(systemName: "square.3.layers.3d")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(2)
                        .background(Circle().fill(Color.blue.opacity(0.8)))
                        .offset(x: 3, y: 3)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(room.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(room.isOn ? .primary : .secondary)
                    .lineLimit(1)
                if room.isOn {
                    Text("\(Int(room.brightness))%")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(amber.opacity(0.8))
                } else {
                    Text("Off")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            // Inline toggle
            Button {
                Task { await store.toggleRoom(room) }
            } label: {
                Image(systemName: room.isOn ? "power.circle.fill" : "power.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(room.isOn ? amber : .secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    ContentView()
}
