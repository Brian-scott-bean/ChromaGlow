// Composer2SpaceEditor.swift
// ChromaGlow — Composer 2 lab (experimental).
//
// Which lights a behavior touches, and how the room is ordered. Tap the
// nodes to pick lights; positions are real when the Entertainment Area gave
// them and clearly estimated otherwise.

import SwiftUI

struct Composer2SpaceEditorContent: View {
    let document: Composer2Document

    private var layer: Composer2Layer { document.selectedLayer }
    private var layout: Composer2SlotLayout { document.roomContext.layout }

    var body: some View {
        VStack(spacing: HueSpacing.md) {
            Composer2EditorSection(title: "Lights",
                                   subtitle: layout.positionsAreEstimated ? Composer2Copy.positionsEstimated : Composer2Copy.positionsReal) {
                Composer2LightPicker(document: document)
                    .frame(height: 170)
                HStack(spacing: 8) {
                    Button("Whole room") {
                        HapticManager.shared.selection()
                        document.selectedSlots = []
                        document.editSelectedLayer { $0.mask = .wholeRoom }
                    }
                    Button("Select all") {
                        HapticManager.shared.selection()
                        document.selectedSlots = Set(0..<layout.count)
                        document.applySelectionToMask()
                    }
                    Button("Clear") {
                        HapticManager.shared.selection()
                        document.selectedSlots = []
                        document.applySelectionToMask()
                    }
                    Spacer(minLength: 0)
                }
                .font(HueFont.stageChip)
                .foregroundStyle(Composer2Theme.cyan)
                .buttonStyle(.plain)
                Text(Composer2Copy.summary(mask: layer.mask, total: layout.count, direction: layer.motion))
                    .font(HueFont.captionMedium)
                    .foregroundStyle(Composer2Theme.ink.opacity(0.8))
            }
            Composer2EditorSection(title: "Selection rule") {
                Composer2ChipRow(title: "Target", options: [
                    ("Whole room", Composer2LayerMask.Kind.wholeRoom, "house"),
                    ("Chosen lights", .slots, "hand.tap"),
                    ("Random subset", .randomSubset, "dice"),
                    ("Region", .region, "rectangle.dashed")
                ], selection: document.layerBinding(\.mask.kind))
                if layer.mask.kind == .randomSubset {
                    Composer2StepperRow(title: "How many", value: Binding(
                        get: { layer.mask.count ?? Composer2LayerMask.subsetCount(total: max(1, layout.count), fraction: layer.mask.fraction, count: nil) },
                        set: { v in document.editSelectedLayer { $0.mask.count = v } }
                    ), range: 1...max(1, layout.count))
                }
                if layer.mask.kind == .region {
                    Composer2SliderRow(title: "Left edge", value: document.layerBinding(\.mask.regionX0), range: 0...1)
                    Composer2SliderRow(title: "Right edge", value: document.layerBinding(\.mask.regionX1), range: 0...1)
                    Composer2SliderRow(title: "Back edge", value: document.layerBinding(\.mask.regionZ0), range: 0...1)
                    Composer2SliderRow(title: "Front edge", value: document.layerBinding(\.mask.regionZ1), range: 0...1)
                    Composer2SliderRow(title: "Soft edges", value: document.layerBinding(\.mask.feather), range: 0...1)
                }
                StageToggleRow(title: "Invert selection", isOn: document.layerBinding(\.mask.invert))
            }
            Composer2EditorSection(title: "Ordering") {
                Composer2ChipRow(title: "Direction", options: [
                    ("Along the room", Composer2Motion.AxisKind.principal, "arrow.left.and.right"),
                    ("Angle", .angle, "location.north.line"),
                    ("From the centre", .radial, "circle.circle"),
                    ("Around", .angular, "arrow.triangle.2.circlepath")
                ], selection: document.layerBinding(\.motion.axisKind))
                if layer.motion.axisKind == .angle {
                    Composer2SliderRow(title: "Angle", value: document.layerBinding(\.motion.angleDegrees), range: 0...360,
                                       format: { "\(Int($0.rounded()))°" })
                }
                StageToggleRow(title: "Invert ordering", isOn: document.layerBinding(\.motion.reverse))
                StageToggleRow(title: "Mirror around the centre", isOn: document.layerBinding(\.motion.mirror))
            }
        }
    }
}

// MARK: - Tap-to-select picker

struct Composer2LightPicker: View {
    let document: Composer2Document

    private var layout: Composer2SlotLayout { document.roomContext.layout }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let points = nodePoints(in: size)
            let weights = document.selectedLayer.mask.weights(
                geometry: layout.geometry,
                seed: Composer2Engine.maskSeed(composition: document.composition, layer: document.selectedLayer))
            ZStack {
                Canvas { ctx, _ in
                    ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 12),
                             with: .color(Composer2Theme.navy.opacity(0.6)))
                    for slot in layout.slots {
                        let p = points[slot.index]
                        let included = slot.index < weights.count ? weights[slot.index] > 0.5 : true
                        let selected = document.selectedSlots.contains(slot.index)
                        let r: CGFloat = 11
                        if selected {
                            ctx.fill(Path(ellipseIn: CGRect(x: p.x - r * 2, y: p.y - r * 2, width: r * 4, height: r * 4)),
                                     with: .radialGradient(Gradient(colors: [Composer2Theme.cyan.opacity(0.35), .clear]),
                                                           center: p, startRadius: r, endRadius: r * 2))
                        }
                        ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                                 with: .color(included ? Composer2Theme.blue.opacity(0.9) : Composer2Theme.muted.opacity(0.35)))
                        ctx.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                                   with: .color(selected ? Composer2Theme.cyan : Color.white.opacity(0.25)), lineWidth: selected ? 2 : 1)
                        let label = Text(slot.name).font(.system(size: 9, weight: .medium)).foregroundStyle(Composer2Theme.muted)
                        ctx.draw(label, at: CGPoint(x: p.x, y: p.y + r + 9))
                    }
                    if layout.isEmpty {
                        ctx.draw(Text("No lights in this room yet").font(.system(size: 12)).foregroundStyle(Composer2Theme.muted),
                                 at: CGPoint(x: size.width / 2, y: size.height / 2))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { location in
                    guard let nearest = points.enumerated().min(by: { hypot($0.element.x - location.x, $0.element.y - location.y) < hypot($1.element.x - location.x, $1.element.y - location.y) }),
                          hypot(nearest.element.x - location.x, nearest.element.y - location.y) < 26 else { return }
                    HapticManager.shared.selection()
                    document.toggleSlot(nearest.offset)
                }
                // Accessible mirror of the nodes.
                HStack(spacing: 0) {
                    ForEach(layout.slots) { slot in
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityElement()
                            .accessibilityLabel("\(slot.name), \(document.selectedSlots.contains(slot.index) ? "selected" : "not selected")")
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { document.toggleSlot(slot.index) }
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Lights in the room")
    }

    private func nodePoints(in size: CGSize) -> [CGPoint] {
        let g = layout.geometry
        return layout.slots.map { slot in
            let x = slot.x ?? g.linearIndex[min(slot.index, max(0, g.linearIndex.count - 1))]
            let z = slot.z ?? 0.5
            return CGPoint(x: 24 + x * (size.width - 48), y: 22 + z * (size.height - 56))
        }
    }
}
