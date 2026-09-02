// StageColorEditor.swift
// CastChroma — Slice 2 inline B+ color editor (spec §7).
//
// At rest: the current color, the preset swatches, and My Colors. Tapping a
// swatch applies immediately. Tapping the current-color chip expands the full
// hue/saturation pad INLINE in the same board — no sheet, no Apply/Done.
// Expansion state is owned by the caller (session working memory), keyed by
// control, so it survives target switches per spec §14.4 and never lives in
// a local `isExpanded` (Guard 13(b)).
//
// Honesty: the pad clamps into the target's ACTUAL gamut when known. For
// mixed/unknown targets the caller passes the widest authoring gamut and the
// coverage chip states the truth locally (spec §13) — per-target clamping at
// send time stays with the existing color-science seams.

import SwiftUI

/// What the editor may honestly claim about the target's color capability.
struct ColorCapabilityContext {
    /// The authoring gamut for the pad. `.c` is the widest authoring space —
    /// pass the known gamut when there is exactly one.
    var gamut: HueColorUtils.Gamut = .c
    /// Color coverage across the target, for the local truth chip.
    var coverage: CapabilityCoverage? = nil
}

struct StageColorEditor: View {
    let title: String
    /// The currently applied color, if any.
    let current: Color?
    var swatches: [Color] = StudioViewModel.presetColors
    var context: ColorCapabilityContext = ColorCapabilityContext()
    /// May the user touch this editor at all (the board's availability funnel
    /// decides)? The caller's `.disabled` is the gate; this is the floor.
    /// `HueSaturationPad`'s drag and `SavedColorStrip`'s tap/drag/context menu
    /// are raw gestures rather than `Control`s, so each write path is closed
    /// here too — and the pad, a drag surface with nothing else to say, does
    /// not render at all.
    var isInteractive: Bool = true
    /// Caller-owned inline expansion (session working memory).
    @Binding var isExpanded: Bool
    let onApply: (Color) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                // Current color chip — tap to expand/collapse the pad inline.
                Button {
                    guard isInteractive else { return }
                    withAnimation(HueAnimation.fast) { isExpanded.toggle() }
                    HapticManager.shared.light()
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(current ?? Color.white.opacity(0.12))
                            .frame(width: 22, height: 22)
                            .overlay(Circle().strokeBorder(StagePalette.line, lineWidth: 1))
                        Image(systemName: isExpanded ? "chevron.up" : "slider.horizontal.3")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.07)))
                }
                .buttonStyle(.plain)
                .stageTapTarget(visual: 32)
                .accessibilityLabel("\(title): \(isExpanded ? "collapse" : "expand") precise color editor")

                // Local capability truth, only when it materially matters.
                if let coverage = context.coverage, coverage.isPartial {
                    StageBadge(text: "\(coverage.supported) OF \(coverage.total) LIGHTS",
                               style: .muted)
                }
            }

            StageColorSwatchRow(
                title: title,
                swatches: swatches,
                selected: current,
                onSelect: { color in
                    guard isInteractive else { return }
                    withAnimation(HueAnimation.fast) { onApply(color) }
                }
            )

            if !SavedColorStore.shared.colors.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("MY COLORS")
                        .font(HueFont.stageTag)
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.45))
                    SavedColorStrip { saved in
                        guard isInteractive else { return }
                        // Mirek-only swatches carry no xy; skip rather than guess.
                        guard let x = saved.x, let y = saved.y else { return }
                        let hsb = HueColorUtils.hsb(fromX: x, y: y, brightness: 100)
                        onApply(Color(hue: hsb.h, saturation: hsb.s, brightness: 1.0))
                        HapticManager.shared.selection()
                    }
                    .padding(.horizontal, -16)   // strip has its own margins
                }
            }

            if isExpanded && isInteractive {
                HueSaturationPad(
                    title: "Fine Tune",
                    hue: currentHueSat.hue,
                    saturation: currentHueSat.saturation,
                    gamut: context.gamut,
                    height: 132,
                    onChanged: { hue, sat, _ in
                        onApply(Color(hue: hue, saturation: sat, brightness: 1.0))
                    }
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var currentHueSat: (hue: Double, saturation: Double) {
        guard let current else { return (0, 1) }
        let ui = UIColor(current)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
        ui.getHue(&h, saturation: &s, brightness: &b, alpha: nil)
        return (Double(h), Double(s))
    }
}
