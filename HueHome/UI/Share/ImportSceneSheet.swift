// ImportSceneSheet.swift
// ChromaGlow — scene sharing
//
// The receiving half of a share. A link or a scanned QR never writes straight
// into the library: the user sees what arrived — its name, palette, motion, and
// whether it wants an entertainment area — and decides.
//
// Imported scenes are always the receiver's own creation (fresh id, not
// built-in), so accepting one can never overwrite a preset they already have,
// even a built-in of the same name.

import SwiftUI

struct ImportSceneSheet: View {

    let scene: SharedScene
    let store: CompositionStore
    /// Called with the saved preset once the user accepts.
    var onImported: (CompositionPreset) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var didImport = false

    private var collides: Bool {
        store.presets.contains { $0.name.caseInsensitiveCompare(scene.name) == .orderedSame }
    }

    var body: some View {
        StageSheetScaffold(title: "Add \(scene.name)") {
            StageCard(icon: scene.icon, title: scene.name, subtitle: scene.category.rawValue) {
                VStack(alignment: .leading, spacing: HueSpacing.md) {
                    ScenePaletteRibbon(palette: scene.palette)

                    factRow("Palette", value: Self.humanized(scene.palette.mode.rawValue))
                    factRow("Motion", value: Self.humanized(scene.motion.pattern.rawValue))
                    factRow("Envelope", value: Self.humanized(scene.envelope.shape.rawValue))
                    if scene.reaction.source != .none {
                        factRow("Reacts to", value: Self.humanized(scene.reaction.source.rawValue))
                    }
                    if let sequence = scene.sequence, !sequence.steps.isEmpty {
                        factRow("Sequence", value: "\(sequence.steps.count) steps")
                    }
                    if scene.preferredTransport == .entertainmentArea {
                        factRow("Best with", value: "An entertainment area")
                    }
                }
            }

            if collides {
                // Not a blocker — the import gets its own id, so both can coexist.
                // But the user should not be surprised by two identical names.
                Text("You already have a scene called \"\(scene.name)\". This one will be added alongside it.")
                    .font(HueFont.stageStatus)
                    .foregroundStyle(HuePalette.amber.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, HueSpacing.xs)
            }

            Button {
                guard !didImport else { return }
                didImport = true
                let preset = scene.makePreset()
                store.save(preset)
                HapticManager.shared.medium()
                onImported(preset)
                dismiss()
            } label: {
                Label("Add to My Scenes", systemImage: "plus.circle.fill")
                    .font(HueFont.stageChip)
                    .foregroundStyle(Color.black.opacity(0.85))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: HueRadius.lg).fill(HuePalette.amber))
            }
            .buttonStyle(.plain)
            .disabled(didImport)
            .padding(.top, HueSpacing.sm)
        }
    }

    /// Wire raw values are snake_case ("pulse_center", "mic_amplitude").
    private static func humanized(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func factRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(HueFont.stageControl)
                .foregroundStyle(StagePalette.muted)
            Spacer(minLength: HueSpacing.sm)
            Text(value)
                .font(HueFont.stageValue)
                .foregroundStyle(StagePalette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

// MARK: - Failure

/// Shown when a link or scan cannot become a scene. Says why, in the codec's
/// own words — "damaged", "from a newer version" — rather than a generic error.
struct ImportSceneFailureSheet: View {
    let error: Error
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        StageSheetScaffold(title: "Can't add scene") {
            StageCard(icon: "exclamationmark.triangle", title: "Scene not added") {
                Text(error.localizedDescription)
                    .font(HueFont.stageControl)
                    .foregroundStyle(StagePalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
