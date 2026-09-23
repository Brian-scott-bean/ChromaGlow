// Composer2PaletteEditor.swift
// ChromaGlow — Composer 2 lab (experimental).
//
// Arbitrary colours: up to eight stops, reorderable, each edited on the
// shared hue/saturation pad (gamut-safe), plus how the palette is traversed.

import SwiftUI

struct Composer2PaletteEditorContent: View {
    let document: Composer2Document
    @State private var selectedStop = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var color: Composer2ColorSource { document.selectedLayer.color }
    private var stops: [Composer2PaletteStop] { color.sanitizedStops }

    var body: some View {
        VStack(spacing: HueSpacing.md) {
            Composer2EditorSection(title: "Colours", subtitle: "Up to eight. Tap a colour to edit it, use the arrows to reorder.") {
                stopRow
                if selectedStop < stops.count {
                    pad(for: selectedStop)
                    presets
                }
            }
            Composer2EditorSection(title: "Harmony", subtitle: "Build a set of colours from the selected one.") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(HarmonyRule.allCases.filter { $0 != .none }) { rule in
                            Button {
                                applyHarmony(rule)
                            } label: {
                                Label(Self.harmonyName(rule), systemImage: rule.icon)
                                    .font(HueFont.stageChip)
                                    .foregroundStyle(Composer2Theme.ink)
                                    .padding(.horizontal, 12)
                                    .frame(minHeight: 36)
                                    .background(Capsule().fill(Color.white.opacity(0.08)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(Self.harmonyName(rule)) harmony")
                            .accessibilityHint("Replaces the colours with a \(Self.harmonyName(rule).lowercased()) set around colour \(selectedStop + 1)")
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            Composer2EditorSection(title: "Blend") {
                Composer2ChipRow(title: "Between colours", options: [
                    ("Hue blend", Composer2ColorSource.Interpolation.hueArc, "circle.lefthalf.filled"),
                    ("Smooth", .linear, "circle.and.line.horizontal"),
                    ("Stepped", .stepped, "square.grid.3x1.below.line.grid.1x2"),
                    ("Soft steps", .softStepped, "square.split.2x1")
                ], selection: document.layerBinding(\.color.interpolation))
                Composer2ChipRow(title: "Spread across lights", options: [
                    ("With motion", Composer2ColorSource.Distribution.motion, "wind"),
                    ("By position", .spatial, "point.3.connected.trianglepath.dotted"),
                    ("Same everywhere", .uniform, "circle.fill"),
                    ("Random pick", .randomPick, "dice"),
                    ("Follows brightness", .brightness, "sun.max.fill")
                ], selection: document.layerBinding(\.color.distribution))
                StageToggleRow(title: "Loop back to the first colour", isOn: document.layerBinding(\.color.cycle))
            }
            Composer2EditorSection(title: "Character") {
                Composer2SliderRow(title: "Saturation", value: document.layerBinding(\.color.saturation), range: 0...2,
                                   format: { "\(Int(($0 * 100).rounded()))%" })
                Composer2SliderRow(title: "Warmth", value: document.layerBinding(\.color.warmth), range: -1...1,
                                   format: { $0 < -0.05 ? "cooler" : ($0 > 0.05 ? "warmer" : "neutral") })
                Composer2SliderRow(title: "Drift", value: document.layerBinding(\.color.drift), range: 0...1)
            }
        }
        .onChange(of: stops.count) { _, count in selectedStop = min(selectedStop, max(0, count - 1)) }
    }

    // MARK: Stops

    private var stopRow: some View {
        HStack(spacing: 8) {
            ForEach(Array(stops.enumerated()), id: \.offset) { index, stop in
                let selected = index == selectedStop
                Button {
                    HapticManager.shared.selection()
                    withAnimation(reduceMotion ? nil : HueAnimation.fast) { selectedStop = index }
                } label: {
                    Circle()
                        .fill(Composer2Theme.solidColor(x: stop.x, y: stop.y))
                        .frame(width: 34, height: 34)
                        .overlay(Circle().strokeBorder(selected ? Color.white : Color.white.opacity(0.25), lineWidth: selected ? 2 : 1))
                        .shadow(color: selected ? Composer2Theme.cyan.opacity(0.6) : .clear, radius: 8)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Colour \(index + 1) of \(stops.count)")
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
            if stops.count < Composer2ColorSource.maxStops {
                Button {
                    HapticManager.shared.medium()
                    let base = stops[min(selectedStop, stops.count - 1)]
                    document.editSelectedLayer { $0.color.stops = stops + [Composer2PaletteStop(x: base.x, y: base.y)] }
                    selectedStop = stops.count
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Composer2Theme.ink)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Composer2Theme.glassRaised))
                        .overlay(Circle().strokeBorder(Composer2Theme.line, lineWidth: 1))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add colour")
            }
            Spacer(minLength: 0)
            reorderButtons
        }
    }

    private var reorderButtons: some View {
        HStack(spacing: 4) {
            Button {
                move(by: -1)
            } label: {
                Image(systemName: "chevron.left").frame(width: 36, height: 36)
            }
            .disabled(selectedStop == 0)
            .accessibilityLabel("Move colour left")
            Button {
                move(by: 1)
            } label: {
                Image(systemName: "chevron.right").frame(width: 36, height: 36)
            }
            .disabled(selectedStop >= stops.count - 1)
            .accessibilityLabel("Move colour right")
            Button {
                remove()
            } label: {
                Image(systemName: "trash").frame(width: 36, height: 36)
            }
            .disabled(stops.count <= 1)
            .accessibilityLabel("Remove colour")
        }
        .font(.system(size: 13, weight: .bold))
        .foregroundStyle(Composer2Theme.ink)
        .buttonStyle(.plain)
    }

    private func move(by delta: Int) {
        let target = selectedStop + delta
        guard target >= 0, target < stops.count else { return }
        HapticManager.shared.soft()
        var next = stops
        next.swapAt(selectedStop, target)
        document.editSelectedLayer { $0.color.stops = next }
        selectedStop = target
    }

    private func remove() {
        guard stops.count > 1 else { return }
        HapticManager.shared.medium()
        var next = stops
        next.remove(at: selectedStop)
        document.editSelectedLayer { $0.color.stops = next }
        selectedStop = max(0, min(selectedStop, next.count - 1))
    }

    // MARK: Harmony

    static func harmonyName(_ rule: HarmonyRule) -> String {
        switch rule {
        case .none: return "Single"
        case .complementary: return "Complementary"
        case .triadic: return "Triad"
        case .analogous: return "Analogous"
        case .splitComplementary: return "Split"
        case .tetradic: return "Square"
        case .monochromatic: return "Mono"
        case .doubleComp: return "Double"
        }
    }

    /// Pure: the stops a harmony rule produces around a root colour.
    static func harmonyStops(rule: HarmonyRule, rootX: Double, rootY: Double) -> [Composer2PaletteStop] {
        let root = HueColorUtils.hsb(fromX: rootX, y: rootY, brightness: 100)
        let count = rule == .monochromatic ? 4 : max(2, rule.anchorCount)
        let colours = HarmonyEngine.palette(rule: rule, rootHue: root.h, saturation: max(0.55, root.s),
                                            brightness: 1, count: count)
        return colours.map { colour in
            let xy = HueColorUtils.xyFrom(hue: colour.hue, saturation: colour.saturation, brightness: 1)
            let clamped = HueColorUtils.clampXYToGamut(x: xy.x, y: xy.y, gamut: .c)
            return Composer2PaletteStop(x: clamped.x, y: clamped.y, position: nil)
        }
    }

    private func applyHarmony(_ rule: HarmonyRule) {
        guard selectedStop < stops.count else { return }
        HapticManager.shared.selection()
        let root = stops[selectedStop]
        let next = Self.harmonyStops(rule: rule, rootX: root.x, rootY: root.y)
        guard !next.isEmpty else { return }
        document.editSelectedLayer { $0.color.stops = next }
        selectedStop = 0
    }

    // MARK: Pad

    private func pad(for index: Int) -> some View {
        let stop = stops[index]
        let hsb = HueColorUtils.hsb(fromX: stop.x, y: stop.y, brightness: 100)
        return HueSaturationPad(
            title: "Colour \(index + 1)",
            hue: hsb.h,
            saturation: hsb.s,
            gamut: .c,
            height: 140,
            onChanged: { _, _, xy in
                let clamped = HueColorUtils.clampXYToGamut(x: xy.x, y: xy.y, gamut: .c)
                var next = stops
                guard index < next.count else { return }
                next[index] = Composer2PaletteStop(x: clamped.x, y: clamped.y, position: next[index].position)
                document.editSelectedLayer { $0.color.stops = next }
            },
            onDragStateChanged: { dragging in
                if !dragging { Composer2PlaybackCenter.shared.noteEditBurst() }
            }
        )
    }

    private var presets: some View {
        StageColorSwatchRow(
            title: "Quick picks",
            swatches: StudioViewModel.presetColors,
            selected: nil,
            onSelect: { swatch in
                let xy = CodableColor.from(color: swatch)
                let clamped = HueColorUtils.clampXYToGamut(x: xy.x, y: xy.y, gamut: .c)
                var next = stops
                guard selectedStop < next.count else { return }
                next[selectedStop] = Composer2PaletteStop(x: clamped.x, y: clamped.y, position: next[selectedStop].position)
                HapticManager.shared.selection()
                document.editSelectedLayer { $0.color.stops = next }
                Composer2PlaybackCenter.shared.noteEditBurst()
            }
        )
    }
}
