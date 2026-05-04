// SceneEditBar.swift
// CastChroma — Priority 1 (scene multi-select toolbar)
//
// Floating glassmorphic action bar that slides up from the bottom
// of RoomDetailView when one or more scenes are selected.
//
// Actions: Edit (single selection) · Delete (with confirmation)

import SwiftUI

struct SceneEditBar: View {

    @Bindable var vm: RoomDetailViewModel
    /// Triggers SceneColorBuilderView for the single selected scene.
    var onEditScene: (SceneDisplayItem) -> Void

    @State private var showDeleteConfirm = false

    private let amber = Color(red: 1.0, green: 0.76, blue: 0.20)

    var body: some View {
        VStack(spacing: 0) {
            // Selection count label
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(amber)
                Text("\(vm.selectedSceneIDs.count) scene\(vm.selectedSceneIDs.count == 1 ? "" : "s") selected")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                Spacer()
                // Select All / None
                Button(vm.selectedSceneIDs.count == vm.scenes.count ? "None" : "All") {
                    if vm.selectedSceneIDs.count == vm.scenes.count {
                        vm.clearSceneSelection()
                    } else {
                        vm.selectAllScenes()
                    }
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(amber)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Divider()
                .background(Color.white.opacity(0.08))

            // Action buttons
            HStack(spacing: 0) {
                // Edit — only enabled when exactly 1 scene is selected
                actionButton(
                    icon: "pencil",
                    label: "Edit",
                    color: vm.selectedSceneIDs.count == 1 ? amber : .white.opacity(0.25)
                ) {
                    guard vm.selectedSceneIDs.count == 1,
                          let scene = vm.selectedScenes.first else { return }
                    onEditScene(scene)
                }
                .disabled(vm.selectedSceneIDs.count != 1)

                divider

                // Delete
                actionButton(
                    icon: "trash",
                    label: "Delete",
                    color: Color(red: 1.0, green: 0.35, blue: 0.35)
                ) {
                    showDeleteConfirm = true
                }
            }
            .padding(.bottom, 4)
        }
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(amber.opacity(0.06))
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [amber.opacity(0.45), amber.opacity(0.08)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(color: .black.opacity(0.35), radius: 20, y: -4)
        }
        .padding(.horizontal, 16)
        .alert(
            "Delete \(vm.selectedSceneIDs.count) Scene\(vm.selectedSceneIDs.count == 1 ? "" : "s")?",
            isPresented: $showDeleteConfirm
        ) {
            Button("Delete", role: .destructive) {
                vm.deleteSelectedScenes()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove the selected scene\(vm.selectedSceneIDs.count == 1 ? "" : "s") from your bridge.")
        }
    }

    // MARK: - Helpers

    private func actionButton(
        icon: String,
        label: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(color)
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(color.opacity(0.75))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(width: 1, height: 36)
    }
}
