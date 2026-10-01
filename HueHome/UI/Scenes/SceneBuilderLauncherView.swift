// SceneBuilderLauncherView.swift
// ChromaGlow — Scenes (Luminous): Build Colors… (unified creation entry).
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

    // ── Phase 1: the room/zone picker ──

    /// The builder POSTs a new bridge scene — granted (guest) bridges'
    /// rooms are never offered.
    private var targets: [RoomDisplayItem] {
        (orchestrator.allRooms + orchestrator.allZones)
            .filter { !orchestrator.isGuestGrantedBridge($0.bridgeID) }
    }

    private var roomPicker: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
                        LuminousScreenTitle(title: "Build colors",
                                            eyebrow: "New scene",
                                            eyebrowSymbol: "paintpalette.fill",
                                            eyebrowTint: LuminousPalette.magenta,
                                            subtitle: "Paint each light its own color, watch the room change as you go, then save it as a scene.")
                        VStack(alignment: .leading, spacing: 10) {
                            LuminousEyebrow(text: "Pick a room").padding(.horizontal, 6)
                            LuminousGroup {
                                ForEach(Array(targets.enumerated()), id: \.element.id) { index, room in
                                    roomChip(room)
                                    if index < targets.count - 1 { LuminousRowDivider() }
                                }
                            }
                        }
                        if let errorMessage {
                            LuminousNotice(text: errorMessage, symbol: "exclamationmark.triangle.fill",
                                           tint: LuminousPalette.danger)
                        }
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                }

                LuminousPrimaryButton(title: "Continue", symbol: "arrow.right", busy: isLoading) {
                    guard let room = selectedRoom else { return }
                    Task { await openBuilder(for: room) }
                }
                .disabled(selectedRoom == nil || isLoading)
            }
            .padding(.horizontal, HueSpacing.screenH)
            .padding(.bottom, 16)
            .background { LuminousAmbience(colors: [LuminousPalette.magenta, LuminousPalette.violet]) }
            .luminousNavigationChrome()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(LuminousPalette.ink.opacity(0.75))
                }
            }
        }
        .luminousSheet()
    }

    private func roomChip(_ room: RoomDisplayItem) -> some View {
        Button {
            selectedRoom = room
            errorMessage = nil
            HapticManager.shared.selection()
        } label: {
            LuminousChoiceRow(symbol: room.kind == .zone ? "square.stack.3d.up" : archetypeIcon(for: room.archetype),
                              title: room.name,
                              subtitle: "\(room.lightCount) light\(room.lightCount == 1 ? "" : "s")",
                              selected: selectedRoom?.id == room.id,
                              tint: LuminousPalette.magenta)
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
