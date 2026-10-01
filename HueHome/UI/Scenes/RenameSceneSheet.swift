// RenameSceneSheet.swift
// ChromaGlow — Scenes (Luminous)
//
// Rename a scene (metadata.name PUT via the orchestrator). The bridge caps
// scene names at 32 characters, like every other scene-name field.

import SwiftUI

struct RenameSceneSheet: View {
    let scene:       GlobalSceneItem
    let initialName: String
    let onRename:    (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(scene: GlobalSceneItem, initialName: String, onRename: @escaping (String) -> Void) {
        self.scene       = scene
        self.initialName = initialName
        self.onRename    = onRename
        _text            = State(initialValue: initialName)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                LuminousScreenTitle(title: "Rename",
                                    eyebrow: scene.name,
                                    eyebrowSymbol: scene.icon,
                                    eyebrowTint: LuminousScenePalette.accent(for: scene))
                LuminousTextField(placeholder: "Scene name", text: $text, symbol: "pencil",
                                  tint: LuminousScenePalette.accent(for: scene), limit: 32,
                                  autofocus: true, onSubmit: save)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, HueSpacing.screenH)
            .padding(.top, 8)
            .background { LuminousAmbience(colors: LuminousScenePalette.colors(for: scene)) }
            .luminousNavigationChrome()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(LuminousPalette.ink.opacity(0.75))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .fontWeight(.bold)
                        .foregroundStyle(trimmed.isEmpty ? LuminousPalette.inkTertiary : LuminousPalette.cyan)
                        .disabled(trimmed.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
        .luminousSheet()
    }

    private func save() {
        let name = String(trimmed.prefix(32))
        guard !name.isEmpty else { return }
        onRename(name)
        dismiss()
    }
}
