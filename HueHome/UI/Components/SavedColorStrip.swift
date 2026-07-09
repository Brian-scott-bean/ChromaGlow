// SavedColorStrip.swift
// ChromaGlow — Scenes overhaul Phase 3
//
// Horizontal "My Colors" swatch strip, shared by LightControlView,
// SceneColorBuilderView, and RoomDetailView. The host decides what a tap
// means (apply immediately, or arm-then-apply) and whether a save chip is
// shown. Rename/Delete live on each swatch's context menu.

import SwiftUI

struct SavedColorStrip: View {

    /// Swatch currently "armed" for tap-to-apply (RoomDetail) — drawn with
    /// a highlight ring. nil hosts (LightControl/SceneBuilder) never arm.
    var armedColorID: UUID? = nil
    /// Non-nil shows the leading ＋ chip that captures the host's current color.
    var onSave: (() -> Void)? = nil
    let onTapSwatch: (SavedColor) -> Void

    @State private var colorToRename: SavedColor? = nil
    @State private var renameText = ""

    private var store: SavedColorStore { SavedColorStore.shared }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                if let onSave {
                    saveChip(onSave)
                }
                ForEach(store.colors) { saved in
                    swatchButton(saved)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
        .alert("Name Color", isPresented: Binding(
            get: { colorToRename != nil },
            set: { if !$0 { colorToRename = nil } }
        ), presenting: colorToRename) { saved in
            TextField("Name", text: $renameText)
            Button("Save") {
                store.rename(id: saved.id, to: renameText)
                colorToRename = nil
            }
            Button("Cancel", role: .cancel) { colorToRename = nil }
        } message: { _ in
            Text("Give this color a name.")
        }
    }

    private func saveChip(_ onSave: @escaping () -> Void) -> some View {
        Button {
            HapticManager.shared.light()
            onSave()
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(Color.white.opacity(0.35),
                                  style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .frame(width: 32, height: 32)
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Save current color")
    }

    private func swatchButton(_ saved: SavedColor) -> some View {
        let isArmed = saved.id == armedColorID
        return Button {
            onTapSwatch(saved)
        } label: {
            ZStack {
                Circle()
                    .fill(saved.displayColor)
                    .frame(width: 32, height: 32)
                    .shadow(color: saved.displayColor.opacity(isArmed ? 0.9 : 0.5),
                            radius: isArmed ? 8 : 4)
                if isArmed {
                    Circle()
                        .stroke(.white, lineWidth: 2.5)
                        .frame(width: 38, height: 38)
                }
            }
            .frame(width: 40, height: 40)
            .scaleEffect(isArmed ? 1.1 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isArmed)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(saved.accessibilityName)
        .accessibilityHint(isArmed ? "Armed — tap a light to apply, or tap again to cancel"
                                   : "Tap to use this color")
        .contextMenu {
            Button {
                renameText = saved.name ?? ""
                colorToRename = saved
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) {
                SavedColorStore.shared.remove(id: saved.id)
                HapticManager.shared.light()
            } label: {
                Label("Delete Color", systemImage: "trash")
            }
        }
    }
}
