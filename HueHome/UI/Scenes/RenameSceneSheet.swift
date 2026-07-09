// RenameSceneSheet.swift
// ChromaGlow — Scenes Browser
//
// Rename sheet for a scene (metadata.name PUT via the orchestrator).
// Extracted verbatim from ScenesTabView.swift (Phase 0 of the Scenes
// overhaul) — no behavior change.

import SwiftUI

struct RenameSceneSheet: View {
    let scene:       GlobalSceneItem
    let initialName: String
    let onRename:    (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    private let glowColor = HuePalette.amber

    init(scene: GlobalSceneItem, initialName: String, onRename: @escaping (String) -> Void) {
        self.scene       = scene
        self.initialName = initialName
        self.onRename    = onRename
        _text            = State(initialValue: initialName)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                StagePalette.stage.ignoresSafeArea()
                VStack(spacing: 24) {
                    TextField("Scene name", text: $text)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                        .tint(glowColor)
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(.white.opacity(0.07))
                                .overlay(RoundedRectangle(cornerRadius: 14)
                                    .strokeBorder(.white.opacity(0.12), lineWidth: 1))
                        )
                        .padding(.horizontal, 24)
                    Spacer()
                }
                .padding(.top, 32)
            }
            .navigationTitle("Rename Scene")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(.white.opacity(0.65))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmed = text.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty { onRename(trimmed) }
                        dismiss()
                    }
                    .foregroundStyle(text.trimmingCharacters(in: .whitespaces).isEmpty
                        ? glowColor.opacity(0.35) : glowColor)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .preferredColorScheme(.dark)
        }
    }
}
