// RoomDetailView.swift — LightShadeWatchApp
// Per-room control: brightness via ⊖/⊕ (tap ±10%, hold to ramp) or the
// Digital Crown (fine 1%), plus presets, scenes, and an on/off toggle.

import SwiftUI
#if os(watchOS)
import WatchKit
#endif

struct RoomDetailView: View {
    let room: WatchRoom
    @StateObject private var store = WatchStore.shared
    @State private var brightness: Double = 50
    private let amber = Color(red: 1.0, green: 0.76, blue: 0.20)

    /// One tap of ⊖/⊕. The Crown still moves in 1% increments for fine trim.
    private static let tapStep: Double = 10
    /// Cadence of a held ⊖/⊕. WatchStore coalesces the PUTs these produce.
    private static let holdInterval: Duration = .milliseconds(150)

    @State private var repeatTask: Task<Void, Never>?
    /// Set when a hold begins so the trailing tap gesture doesn't add an extra step.
    @State private var didRepeat = false

    var currentRoom: WatchRoom {
        store.allGroups.first { $0.id == room.id } ?? room
    }

    var roomScenes: [WatchScene] {
        store.scenes(forGroup: room.id)
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

                // ── Brightness: tap ±10%, hold to ramp, Crown for fine 1% ──
                if currentRoom.isOn {
                    VStack(spacing: 6) {
                        Text("Brightness")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            brightnessStepper("minus", delta: -Self.tapStep)
                            Text("\(Int(brightness))%")
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .frame(maxWidth: .infinity)
                            brightnessStepper("plus", delta: Self.tapStep)
                        }

                        // The Crown needs a focusable target; this bar is it.
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.12))
                                Capsule()
                                    .fill(amber)
                                    .frame(width: max(4, geo.size.width * CGFloat(brightness / 100)))
                            }
                        }
                        .frame(height: 6)
                        #if os(watchOS)
                        .focusable()
                        .digitalCrownRotation($brightness, from: 1, through: 100, by: 1,
                                              sensitivity: .medium, isContinuous: false,
                                              isHapticFeedbackEnabled: true)
                        #endif
                    }
                    .padding(.horizontal, 4)
                    // Single write path: every input (tap, hold, Crown) mutates
                    // `brightness`; the store coalesces the resulting PUTs.
                    .onChange(of: brightness) { _, new in
                        store.setBrightness(new, for: currentRoom)
                    }
                }

                // ── Scenes (this room/zone) ──
                if !roomScenes.isEmpty {
                    VStack(spacing: 6) {
                        Text("Scenes")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        ForEach(roomScenes) { scene in
                            Button {
                                Task { await store.recallScene(scene) }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "wand.and.stars")
                                        .font(.system(size: 12, weight: .semibold))
                                        .frame(width: 18)
                                    Text(scene.name)
                                        .font(.system(size: 13, weight: .medium))
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .foregroundStyle(amber)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 10).fill(amber.opacity(0.12)))
                                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(amber.opacity(0.25), lineWidth: 0.5))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // ── Preset chips ──
                VStack(spacing: 6) {
                    Text("Presets")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    ForEach(WatchPreset.allCases, id: \.rawValue) { preset in
                        Button {
                            Task { await store.applyPreset(preset, to: room) }
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
        .onDisappear { stopRepeating() }
    }

    // MARK: - Brightness stepper

    /// Tap = one `delta` step. Press-and-hold = repeat every `holdInterval`
    /// until release or a rail. Not a `Button`: pairing a Button action with a
    /// long-press gesture fires the action again on release.
    private func brightnessStepper(_ symbol: String, delta: Double) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(amber)
            .frame(width: 44, height: 40)
            .background(Capsule().fill(amber.opacity(0.15)))
            .contentShape(Capsule())
            .onTapGesture {
                guard !didRepeat else { return }
                step(by: delta)
            }
            .onLongPressGesture(
                minimumDuration: 0.35,
                pressing: { isPressing in
                    if isPressing { didRepeat = false } else { stopRepeating() }
                },
                perform: { startRepeating(delta) }
            )
    }

    private func step(by delta: Double) {
        let next = min(100, max(1, (brightness + delta).rounded()))
        guard next != brightness else { return }
        brightness = next
        #if os(watchOS)
        WKInterfaceDevice.current().play(.click)
        #endif
    }

    private func startRepeating(_ delta: Double) {
        didRepeat = true
        repeatTask?.cancel()
        repeatTask = Task { @MainActor in
            while !Task.isCancelled {
                let before = brightness
                step(by: delta)
                if brightness == before { break }   // hit 1% or 100%
                try? await Task.sleep(for: Self.holdInterval)
            }
        }
    }

    private func stopRepeating() {
        repeatTask?.cancel()
        repeatTask = nil
    }
}
