// CreateGlobalSceneView.swift
// ChromaGlow — Scenes (Luminous): Capture Room Look.
//
// Sheet for creating a new scene from the Scenes tab. The user names it,
// picks a room, and saves — the orchestrator snapshots the room's current
// light states and POSTs a scene to the bridge.

import SwiftUI

struct CreateGlobalSceneView: View {

    @Environment(UnifiedOrchestrator.self) private var orchestrator
    @Environment(\.dismiss) private var dismiss

    @State private var selectedRoom: RoomDisplayItem?
    @State private var sceneName:    String = ""
    @State private var isSaving:     Bool   = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    LuminousScreenTitle(title: "Capture a room",
                                        eyebrow: "New scene",
                                        eyebrowSymbol: "camera.viewfinder",
                                        eyebrowTint: LuminousPalette.cyan,
                                        subtitle: "Saves a room exactly as its lights are now, as a scene you can bring back any time.")

                    // ── Scene Name ─────────────────────────────────────
                    VStack(alignment: .leading, spacing: 10) {
                        LuminousEyebrow(text: "Scene name").padding(.horizontal, 6)
                        // 32-char CLIP v2 name cap (audit L-52).
                        LuminousTextField(placeholder: "e.g. Movie Night", text: $sceneName,
                                          symbol: "sparkles", limit: 32)
                    }

                    // ── Room Picker ────────────────────────────────────
                    VStack(alignment: .leading, spacing: 10) {
                        LuminousEyebrow(text: "Room").padding(.horizontal, 6)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                // Capturing creates a bridge scene — granted
                                // (guest) bridges' rooms are never offered.
                                ForEach((orchestrator.allRooms + orchestrator.allZones)
                                    .filter { !orchestrator.isGuestGrantedBridge($0.bridgeID) }) { room in
                                    LuminousChip(title: room.name, symbol: archetypeIcon(room.archetype),
                                                 selected: selectedRoom?.id == room.id) {
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                            selectedRoom = selectedRoom?.id == room.id ? nil : room
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .scrollClipDisabled()
                    }

                    // ── What happens ───────────────────────────────────
                    if let room = selectedRoom {
                        LuminousNotice(text: "The scene will snapshot the current light settings in \(room.name). Set the lights how you want them before saving.",
                                       symbol: "info.circle.fill")
                            .transition(.opacity)
                    }

                    // ── Error ──────────────────────────────────────────
                    if let error = errorMessage {
                        LuminousNotice(text: error, symbol: "exclamationmark.triangle.fill", tint: LuminousPalette.danger)
                    }

                    LuminousPrimaryButton(title: "Save Scene", symbol: "camera.fill", busy: isSaving) {
                        guard canSave else { return }
                        save()
                    }
                    .disabled(!canSave || isSaving)
                }
                .padding(.horizontal, HueSpacing.screenH)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
            .background { LuminousAmbience(colors: [LuminousPalette.cyan, LuminousPalette.violet]) }
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
