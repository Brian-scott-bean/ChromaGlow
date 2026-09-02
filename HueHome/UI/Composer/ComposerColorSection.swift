// ComposerColorSection.swift
// CastChroma — Slice 3 (S3-3): the Composer's inline colour editing.
//
// The three harmony swatches used to open a `.popover` (a sheet on iPhone)
// holding a colour wheel — the last detached colour-editing surface in the
// app, carried by Guard 13 as anchored accepted debt. They now converge on
// the inline B+ grammar the Studio board established (spec §7): the swatch
// row stays as the compact preview, and tapping a swatch expands the SHARED
// `StageColorEditor` for that slot in place — current colour, preset
// swatches, My Colors, and the hue/saturation pad — with no Apply, no Done,
// no popover. Every colour path applies immediately.
//
// Expansion is per-target SESSION working memory (`expandedColorControlID`,
// spec §14.4), keyed by the exact running identity: one slot open at a time,
// two rooms editing the same preset keep their own, a stopped target's
// expansion dies with it, and a non-interactive control reads collapsed
// without erasing what the user left open. This file is deliberately
// separate from `CompositionEditorPanel`: Guard 13(b) bans the `isExpanded`
// spelling on the host and the panel, and the editor's caller-bound
// `isExpanded` is the one legitimate owner of that word — the same split the
// board makes.
//
// The harmony echo chain (StudioView's `activeHarmonyRule` onChange, the pad's
// per-sample recompute) is untouched: a per-swatch edit writes ONE slot,
// exactly as the popover did.

import SwiftUI

struct ComposerHarmonySwatches: View {
    let vm: StudioViewModel
    let availability: ComposerAvailabilityContext
    /// The funnel's verdict for the harmony row, carried in.
    let isInteractive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The control id of one harmony slot, in the same `card.param` notation
    /// every other control on the page uses.
    static func controlID(cardID: String, slot: Int) -> CustomizationControlID {
        CustomizationControlID(cardID: cardID, paramID: "palette.color\(slot + 1)")
    }

    /// The xy a slot receives for a hue/saturation pair, clamped into the
    /// target's gamut — the popover's write, unchanged.
    static func slotColor(hue: Double, saturation: Double,
                          gamut: HueColorUtils.Gamut) -> CodableColor {
        let xy = HueColorUtils.xyFrom(hue: hue, saturation: saturation, brightness: 1.0)
        let clamped = HueColorUtils.clampXYToGamut(x: xy.x, y: xy.y, gamut: gamut)
        return CodableColor(x: clamped.x, y: clamped.y)
    }

    /// Write ONE slot of the palette through the edit session.
    @discardableResult
    static func commit(slot: Int, hue: Double, saturation: Double,
                       gamut: HueColorUtils.Gamut,
                       session: ComposerEditSession,
                       vm: StudioViewModel) -> CustomizationFenceVerdict {
        let color = slotColor(hue: hue, saturation: saturation, gamut: gamut)
        return vm.commitComposerEdit(session) { box in
            switch slot {
            case 0: box.palette.color1 = color
            case 1: box.palette.color2 = color
            case 2: box.palette.color3 = color
            default: break
            }
            box.triggerRESTBurst()
        }
    }

    private var expandedSlot: Int? {
        guard let cardID = availability.cardID,
              let session = availability.session,
              let expanded = vm.sessionMemory.state(for: session.identity.targetKey).expandedColorControlID
        else { return nil }
        return (0..<3).first { Self.controlID(cardID: cardID, slot: $0) == expanded }
    }

    private func slotColor(_ slot: Int) -> Color {
        guard let box = availability.session?.box else { return .gray }
        let c: CodableColor
        switch slot {
        case 0: c = box.palette.color1
        case 1: c = box.palette.color2
        case 2: c = box.palette.color3 ?? box.palette.color2
        default: c = box.palette.color1
        }
        return HueColorUtils.color(fromX: c.x, y: c.y, brightness: 100)
    }

    /// Expansion into session memory (spec §14.4). A non-interactive row
    /// reads COLLAPSED and refuses to expand without erasing the stored
    /// value — the editor the user left open is open again the moment the
    /// inventory arrives.
    private func expansionBinding(slot: Int) -> Binding<Bool> {
        Binding(
            get: { isInteractive && expandedSlot == slot },
            set: { expanded in
                guard isInteractive, let cardID = availability.cardID,
                      let session = availability.session else { return }
                let id = Self.controlID(cardID: cardID, slot: slot)
                vm.sessionMemory.update(session.identity.targetKey) {
                    $0.expandedColorControlID = expanded ? id : nil
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Spacing 0: each swatch sits centered in its own 44pt hit frame,
            // so the hit boxes tile edge-to-edge without overlapping.
            HStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { slot in
                    let color = slotColor(slot)
                    let isEditing = expandedSlot == slot
                    Circle()
                        .fill(color)
                        .frame(width: 28, height: 28)
                        .overlay(Circle().strokeBorder(.white.opacity(isEditing ? 0.9 : 0.5),
                                                       lineWidth: isEditing ? 2.5 : 1.5))
                        .shadow(color: color.opacity(isEditing ? 0.7 : 0.4), radius: isEditing ? 8 : 4)
                        .frame(width: HueHit.min, height: HueHit.min)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // A tap gesture is not a Control: `.disabled` does
                            // not close it, so the verdict is applied here.
                            guard isInteractive else { return }
                            withAnimation(reduceMotion ? nil : HueAnimation.fast) {
                                expansionBinding(slot: slot).wrappedValue.toggle()
                            }
                            HapticManager.shared.selection()
                        }
                        .accessibilityLabel("Color \(slot + 1): \(isEditing ? "collapse" : "expand") precise color editor")
                        .accessibilityAddTraits(isEditing ? .isSelected : [])
                        .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7), value: isEditing)
                }
                Spacer()
                Text("Tap to fine-tune")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.30))
            }

            if let slot = expandedSlot, isInteractive {
                // The SHARED inline editor for the open slot — the same
                // instrument the Studio board's colour controls use.
                let context: ColorCapabilityContext = {
                    var context = ColorCapabilityContext()
                    context.gamut = vm.activeCompositionGamut
                    context.coverage = StudioBoardAvailability.editorCoverage(
                        resolution: availability.resolve("harmony"),
                        snapshotColor: availability.snapshot?.color)
                    return context
                }()
                StageColorEditor(
                    title: "Color \(slot + 1)",
                    current: slotColor(slot),
                    context: context,
                    isInteractive: isInteractive,
                    isExpanded: expansionBinding(slot: slot),
                    onApply: { color in
                        guard isInteractive, let session = availability.session else { return }
                        let ui = UIColor(color)
                        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
                        ui.getHue(&h, saturation: &s, brightness: &b, alpha: nil)
                        Self.commit(slot: slot, hue: Double(h), saturation: Double(s),
                                    gamut: vm.activeCompositionGamut, session: session, vm: vm)
                    }
                )
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
