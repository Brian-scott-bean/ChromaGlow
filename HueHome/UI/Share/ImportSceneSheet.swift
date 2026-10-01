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
        ShareSheetScaffold(eyebrow: "Add a scene",
                           symbol: scene.icon,
                           tint: LuminousPalette.cyan,
                           title: scene.name,
                           subtitle: "\(scene.category.rawValue). Someone shared it with you — see what it is, then decide.",
                           colors: scene.palette.sampleColors()) {
            VStack(alignment: .leading, spacing: HueSpacing.md) {
                ScenePaletteRibbon(palette: scene.palette)
                VStack(spacing: 10) {
                    factRow("Palette", value: Self.humanized(scene.palette.mode.rawValue))
                    factRow("Motion", value: Self.humanized(scene.motion.pattern.rawValue))
                    factRow("Brightness Shape", value: Self.humanized(scene.envelope.shape.rawValue))
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
            .padding(16)
            .luminousGlass()

            if collides {
                // Not a blocker — the import gets its own id, so both can coexist.
                // But the user should not be surprised by two identical names.
                LuminousNotice(text: "You already have a scene called \"\(scene.name)\". This one will be added alongside it.",
                               symbol: "exclamationmark.circle.fill", tint: LuminousPalette.amber)
            }

            LuminousPrimaryButton(title: "Add to My Scenes", symbol: "plus.circle.fill") {
                guard !didImport else { return }
                didImport = true
                let preset = scene.makePreset()
                store.save(preset)
                HapticManager.shared.medium()
                onImported(preset)
                dismiss()
            }
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
                .font(.subheadline)
                .foregroundStyle(LuminousPalette.inkSecondary)
            Spacer(minLength: HueSpacing.sm)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LuminousPalette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Failure

/// Shown when a link or scan cannot become a scene. Says why, in the codec's
/// own words — "damaged", "from a newer version" — rather than a generic error.
struct ImportSceneFailureSheet: View {
    let error: Error
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ShareSheetScaffold(eyebrow: "Can't add scene",
                           symbol: "exclamationmark.triangle.fill",
                           tint: LuminousPalette.amber,
                           title: "Scene not added",
                           colors: [LuminousPalette.amber]) {
            LuminousNotice(text: error.localizedDescription, symbol: "exclamationmark.triangle.fill",
                           tint: LuminousPalette.amber)
        }
    }
}
