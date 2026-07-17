// CreateGlobalSceneView.swift
// CastChroma
//
// Sheet for creating a new scene from the global Scenes tab.
// User picks a room, enters a name, and saves — the orchestrator
// snapshots the current light states and POSTs a scene to the bridge.

import SwiftUI

struct CreateGlobalSceneView: View {

    @Environment(UnifiedOrchestrator.self) private var orchestrator
    @Environment(\.dismiss) private var dismiss

    @State private var selectedRoom: RoomDisplayItem?
    @State private var sceneName:    String = ""
    @State private var isSaving:     Bool   = false
    @State private var errorMessage: String?

    private let glowColor = HuePalette.amber

    var body: some View {
        ZStack {
            // Background
            StagePalette.stage.ignoresSafeArea()

            VStack(spacing: 0) {
                // ── Header ────────────────────────────────────────────────
                HStack {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    Text("New Scene")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Button {
                        guard canSave else { return }
                        save()
                    } label: {
                        if isSaving {
                            ProgressView().tint(glowColor)
                        } else {
                            Text("Save")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(canSave ? glowColor : glowColor.opacity(0.35))
                        }
                    }
                    .disabled(!canSave || isSaving)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)

                Divider().background(.white.opacity(0.08))

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 28) {

                        // ── Scene Name ─────────────────────────────────────
                        sectionCard(header: "SCENE NAME") {
                            TextField("e.g. Movie Night", text: $sceneName)
                                .font(.system(size: 16))
                                .foregroundStyle(.white)
                                .tint(glowColor)
                                .padding(.vertical, 2)
                                // 32-char CLIP v2 name cap (audit L-52).
                                .onChange(of: sceneName) { _, newValue in
                                    if newValue.count > 32 {
                                        sceneName = String(newValue.prefix(32))
                                    }
                                }
                        }

                        // ── Room Picker ────────────────────────────────────
                        VStack(alignment: .leading, spacing: 12) {
                            sectionLabel("ROOM")
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(orchestrator.allRooms + orchestrator.allZones) { room in
                                        roomChip(room)
                                    }
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 4)
                            }
                        }

                        // ── Info card ──────────────────────────────────────
                        if let room = selectedRoom {
                            infoCard(room: room)
                        }

                        // ── Error ──────────────────────────────────────────
                        if let error = errorMessage {
                            Text(error)
                                .font(.subheadline)
                                .foregroundStyle(.red.opacity(0.85))
                                .padding(.horizontal, 20)
                        }
                    }
                    .padding(.top, 24)
                    .padding(.bottom, 40)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Sub-views

    private func roomChip(_ room: RoomDisplayItem) -> some View {
        let selected = selectedRoom?.id == room.id
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                selectedRoom = selected ? nil : room
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: archetypeIcon(room.archetype))
                    .font(.system(size: 12, weight: .medium))
                Text(room.name)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? .black : .white.opacity(0.75))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Capsule().fill(selected ? glowColor : Color.white.opacity(0.10)))
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: selected)
    }

    private func infoCard(room: RoomDisplayItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "info.circle")
                .font(.system(size: 14))
                .foregroundStyle(glowColor)
            Text("The scene will snapshot the current light settings in **\(room.name)**. Make sure the lights are set how you want them before saving.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.65))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(glowColor.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(glowColor.opacity(0.2), lineWidth: 1))
        )
        .padding(.horizontal, 20)
    }

    private func sectionCard<Content: View>(header: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel(header)
            content()
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.white.opacity(0.06))
                        .overlay(RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(.white.opacity(0.08), lineWidth: 1))
                )
        }
        .padding(.horizontal, 20)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.45))
            .tracking(0.8)
            .padding(.horizontal, 20)
    }

    // MARK: - Helpers

    private var canSave: Bool {
        !sceneName.trimmingCharacters(in: .whitespaces).isEmpty && selectedRoom != nil
    }

    private func save() {
        guard let room = selectedRoom else { return }
        let trimmed = sceneName.trimmingCharacters(in: .whitespaces)
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await orchestrator.createSceneFromRoom(name: trimmed, room: room)
                await MainActor.run { dismiss() }
            } catch {
                await MainActor.run {
                    errorMessage = "Failed to create scene: \(error.localizedDescription)"
                    isSaving = false
                }
            }
        }
    }

    private func archetypeIcon(_ archetype: String?) -> String {
        switch archetype {
        case "living_room": return "sofa.fill"
        case "kitchen":     return "refrigerator.fill"
        case "bedroom":     return "bed.double.fill"
        case "bathroom":    return "shower.fill"
        case "office":      return "desktopcomputer"
        case "dining":      return "fork.knife"
        case "garage":      return "car.fill"
        case "garden":      return "leaf.fill"
        default:            return "lightbulb.fill"
        }
    }
}
