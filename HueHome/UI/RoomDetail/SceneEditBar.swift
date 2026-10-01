// SceneEditBar.swift
// ChromaGlow — Room (Luminous): the dock for selected scenes.
//
// Floats above the tab bar while scenes are selected: a count and All/None,
// then Edit (exactly one scene) and Delete (asks first).

import SwiftUI

struct SceneEditBar: View {

    @Bindable var vm: RoomDetailViewModel
    /// Opens the scene builder for the single selected scene.
    var onEditScene: (SceneDisplayItem) -> Void

    @State private var showDeleteConfirm = false

    private var count: Int { vm.selectedSceneIDs.count }
    private var allSelected: Bool { count == vm.scenes.count }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(LuminousPalette.cyan)
                Text("\(count) scene\(count == 1 ? "" : "s") selected")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LuminousPalette.ink)
                    .contentTransition(.numericText())
                Spacer(minLength: 0)
                LuminousTextPill(title: allSelected ? "None" : "All", tint: LuminousPalette.cyan) {
                    if allSelected { vm.clearSceneSelection() } else { vm.selectAllScenes() }
                }
                .accessibilityLabel(allSelected ? "Select none" : "Select all")
            }
            HStack(spacing: 8) {
                // Edit — exactly one scene.
                LuminousDockButton(title: "Edit", symbol: "pencil", tint: LuminousPalette.cyan,
                                   highlighted: count == 1) {
                    guard count == 1, let scene = vm.selectedScenes.first else { return }
                    onEditScene(scene)
                }
                .disabled(count != 1)
                LuminousDockButton(title: "Delete", symbol: "trash", tint: LuminousPalette.danger) {
                    showDeleteConfirm = true
                }
                .disabled(count == 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .luminousDock()
        .alert(
            "Delete \(count) Scene\(count == 1 ? "" : "s")?",
            isPresented: $showDeleteConfirm
        ) {
            Button("Delete", role: .destructive) {
                vm.deleteSelectedScenes()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove the selected scene\(count == 1 ? "" : "s") from your bridge.")
        }
    }
}
