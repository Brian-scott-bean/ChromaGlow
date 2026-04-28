// RoomDetailView.swift — LightShadeWatchApp
// Per-room control: brightness via Digital Crown, presets, on/off toggle.

import SwiftUI

struct RoomDetailView: View {
    let room: WatchRoom
    @StateObject private var store = WatchStore.shared
    @State private var brightness: Double = 50
    private let amber = Color(red: 1.0, green: 0.76, blue: 0.20)

    var currentRoom: WatchRoom {
        store.rooms.first { $0.id == room.id } ?? room
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                // ── Room icon + status ──
                ZStack {
                    Circle()
                        .fill(currentRoom.isOn
                              ? amber.opacity(0.18)
                              : Color.white.opacity(0.06))
                        .frame(width: 60, height: 60)
                    Image(systemName: watchRoomIcon(room.archetype))
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(currentRoom.isOn ? amber : .secondary)
                }
                .shadow(color: currentRoom.isOn ? amber.opacity(0.4) : .clear, radius: 8)

                Text(room.name)
                    .font(.system(size: 15, weight: .bold))
                    .lineLimit(1)

                Text(currentRoom.isOn
                     ? "\(Int(currentRoom.brightness))% · \(room.lightCount) bulb\(room.lightCount == 1 ? "" : "s")"
                     : "Off")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                // ── On/Off toggle ──
                Button {
                    Task { await store.toggleRoom(currentRoom) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: currentRoom.isOn ? "power.circle.fill" : "power.circle")
                        Text(currentRoom.isOn ? "Turn Off" : "Turn On")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(currentRoom.isOn ? .black : amber)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(currentRoom.isOn ? amber : amber.opacity(0.15)))
                }
                .buttonStyle(.plain)

                // ── Brightness slider (Digital Crown) ──
                if currentRoom.isOn {
                    VStack(spacing: 4) {
                        Text("Brightness")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Slider(value: $brightness, in: 1...100, step: 1) {
                            Text("Brightness")
                        }
                        .tint(amber)
                        .focusable()
                        .digitalCrownRotation($brightness, from: 1, through: 100, by: 1,
                                              sensitivity: .medium, isContinuous: false,
                                              isHapticFeedbackEnabled: true)
                        .onChange(of: brightness) { _, new in
                            Task { await store.setBrightness(new, for: currentRoom) }
                        }
                    }
                    .padding(.horizontal, 4)
                }

                // ── Preset chips ──
                VStack(spacing: 6) {
                    Text("Presets")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    ForEach(WatchPreset.allCases, id: \.rawValue) { preset in
                        Button {
                            Task { await store.applyPreset(preset) }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: preset.icon)
                                    .font(.system(size: 12, weight: .semibold))
                                    .frame(width: 18)
                                Text(preset.label)
                                    .font(.system(size: 13, weight: .medium))
                                Spacer()
                                Text("\(Int(preset.brightness))%")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .foregroundStyle(preset.color)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 10)
                                .fill(preset.color.opacity(0.12)))
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(preset.color.opacity(0.25), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 16)
        }
        .navigationTitle(room.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            brightness = currentRoom.brightness
        }
    }
}
