// SceneBuilderLauncherView.swift
// CastChroma — Round 4 Scenes block (unified creation entry).
//
// A routing step, not a third creation UI: pick a room or zone, then the
// existing per-light SceneColorBuilderView opens seeded with that group's
// lights (the proven groupedLightID fetch path from the Studio export —
// works for rooms AND zones). Demo mode seeds from DemoDataProvider.

import SwiftUI

struct SceneBuilderLauncherView: View {
    @Environment(UnifiedOrchestrator.self) private var orchestrator
    @Environment(\.dismiss) private var dismiss

    private struct BuilderContext: Identifiable {
        let id = UUID()
        let roomID: String
        let roomRType: String
        let bridgeID: String
        let lights: [LightDisplayItem]
    }

    @State private var selectedRoom: RoomDisplayItem?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var builderContext: BuilderContext?

    var body: some View {
        if let ctx = builderContext {
            // Phase 2: the existing builder, in-place (no sheet-over-sheet).
            SceneColorBuilderView(
                roomID: ctx.roomID,
                roomRType: ctx.roomRType,
                bridgeID: ctx.bridgeID,
                existingSceneID: nil,
                existingSceneName: nil,
                initialLights: ctx.lights,
                onSave: { dismiss() }
            )
            .environment(orchestrator)
        } else {
            roomPicker
        }
    }

    // ── Phase 1: stage-styled room/zone picker ──

    private var roomPicker: some View {
        NavigationStack {
            ZStack {
                StagePalette.stage.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 18) {
                    Text("PICK A ROOM")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.38))
                        .padding(.top, 8)

                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 8) {
                            ForEach(orchestrator.allRooms + orchestrator.allZones) { room in
                                roomChip(room)
                            }
                        }
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(HuePalette.Noir.destructive)
                    }

                    Button {
                        guard let room = selectedRoom else { return }
                        Task { await openBuilder(for: room) }
                    } label: {
                        HStack {
                            if isLoading {
                                ProgressView().tint(.black)
                            } else {
                                Text("Continue")
                                    .font(.system(size: 15, weight: .bold))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(selectedRoom == nil
                                      ? HuePalette.amber.opacity(0.25)
                                      : HuePalette.amber)
                        )
                        .foregroundStyle(Color.black.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedRoom == nil || isLoading)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            .navigationTitle("Build Colors")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    private func roomChip(_ room: RoomDisplayItem) -> some View {
        let isSelected = selectedRoom?.id == room.id
        return Button {
            selectedRoom = room
            errorMessage = nil
            HapticManager.shared.selection()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: room.kind == .zone ? "square.split.bottomrightquarter" : "lamp.floor")
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? HuePalette.amber : StagePalette.muted)
                Text(room.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.75))
                Spacer()
                Text("\(room.lightCount)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(StagePalette.muted)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(HuePalette.amber)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? HuePalette.amber.opacity(0.12) : Color.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(isSelected ? HuePalette.amber.opacity(0.5) : StagePalette.line,
                                          lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // ── Light fetch (rooms AND zones — the Studio-export path) ──

    private func openBuilder(for room: RoomDisplayItem) async {
        if orchestrator.isDemoMode {
            let lights = DemoDataProvider.lights(for: room.id)
            guard !lights.isEmpty else {
                errorMessage = "No lights found in '\(room.name)'"
                return
            }
            builderContext = BuilderContext(
                roomID: room.id,
                roomRType: room.kind == .zone ? "zone" : "room",
                bridgeID: room.bridgeID ?? "demo-bridge",
                lights: lights
            )
            return
        }

        guard let bridgeID = room.bridgeID,
              let api = orchestrator.hueClient(for: bridgeID),
              let groupedLightID = room.groupedLightID else {
            errorMessage = "Couldn't reach '\(room.name)' — check the bridge connection"
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let ids = Set(try await api.fetchLightIDsForGroup(groupedLightID: groupedLightID))
            let lights = try await api.fetchLights()
                .filter { ids.contains($0.id) }
                .map(LightDisplayItem.init(from:))
                .sorted { $0.name < $1.name }
            guard !lights.isEmpty else {
                errorMessage = "No lights found in '\(room.name)'"
                return
            }
            builderContext = BuilderContext(
                roomID: room.id,
                roomRType: room.kind == .zone ? "zone" : "room",
                bridgeID: bridgeID,
                lights: lights
            )
        } catch {
            errorMessage = "Couldn't load lights — \(error.localizedDescription)"
        }
    }
}
