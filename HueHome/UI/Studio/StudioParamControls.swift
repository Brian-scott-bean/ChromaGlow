// StudioParamControls.swift
// CastChroma — Studio engine-card parameter controls.
//
// The per-param row renderer and the Essential/Color/Advanced half-sheet
// used by the mixer tray for bridge-native and app-driven cards. Rebuilt on
// StageKit (adjustment-settings revamp): rows are the shared stage
// components, the slider holds row-local state so drags don't round-trip
// through the ViewModel per tick, and the sheet uses the unified scaffold.

import SwiftUI

// MARK: - MixerTrayMetrics

/// Pure layout math for the mixer tray: which params render inline in the
/// compact tray, which overflow to the "+N more" reveal, and the
/// content-derived tray height (replaces the old hardcoded 390/420).
enum MixerTrayMetrics {
    static let grabBarHeight: CGFloat = 36
    /// Row 1 of the tray header: 40pt icon/action circles plus padding.
    static let headerHeight: CGFloat = 66
    /// Row 2: the horizontally scrolling badge lane (LIVE, coverage, beat,
    /// transport, room count). Fixed so the tray height never depends on how
    /// many badges happen to be showing.
    static let badgeLaneHeight: CGFloat = 28
    /// Row 3: the transport status sentence. Reserved for composition cards
    /// so the tray does not resize when the sentence appears or clears.
    static let statusLineHeight: CGFloat = 26
    static let sliderRowHeight: CGFloat = 56
    static let moreRowHeight: CGFloat = 44
    static let verticalPadding: CGFloat = 16
    /// Raised with the three-row header (and again for the 44pt-hit-target
    /// pass: +8 grab, +6 header, +4 badge lane) so compact devices keep the
    /// inline slider count they had before. MixerTrayMetricsTests pins this.
    static let compactHeightCap: CGFloat = 406

    /// Total height of the three-row tray header: identity+actions, badge
    /// lane, and — for composition cards — the transport status sentence.
    /// The status line is *reserved* rather than measured so the tray does not
    /// resize when a transport switch makes the sentence appear or clear.
    static func headerBlockHeight(hasStatusLine: Bool) -> CGFloat {
        var height = headerHeight + HueSpacing.xs + badgeLaneHeight
        if hasStatusLine { height += HueSpacing.xs + statusLineHeight }
        return height
    }

    /// Compact-tray params: essentials plus every color picker — color is
    /// the most-hunted adjustment, worth one always-visible row.
    static func inlineParams(for card: StudioCard) -> [StudioParam] {
        let essentials = card.params.filter { $0.tier == .essential }
        let colors = card.params.filter {
            if case .colorPicker = $0.kind { return $0.tier != .essential }
            return false
        }
        return essentials + colors
    }

    /// Everything else, revealed by "+N more" (sheet) or inline when the
    /// tray is dragged up.
    static func overflowParams(for card: StudioCard) -> [StudioParam] {
        let inlineIDs = Set(inlineParams(for: card).map(\.id))
        return card.params.filter { !inlineIDs.contains($0.id) }
    }

    /// Content-derived compact height for engine cards. Engine cards say their
    /// scope in a badge, so they get no status line.
    static func engineHeight(for card: StudioCard, isCompact: Bool) -> CGFloat {
        let rows = inlineParams(for: card).count
        let hasMore = !overflowParams(for: card).isEmpty
        var height = grabBarHeight + headerBlockHeight(hasStatusLine: false)
            + CGFloat(rows) * sliderRowHeight
            + verticalPadding
        if hasMore { height += moreRowHeight }
        return isCompact ? min(height, compactHeightCap) : height
    }

    /// Composition tray height (header + layer tabs + active-tab essentials;
    /// the inner ScrollView absorbs overflow). The 390/430 body figures are
    /// unchanged — only the taller three-row header is added on top.
    static func compositionHeight(isCompact: Bool) -> CGFloat {
        let body: CGFloat = isCompact ? 390 : 430
        return body - headerHeight + headerBlockHeight(hasStatusLine: true)
    }
}

// MARK: - StudioParamRow

struct StudioParamRow: View {

    let param: StudioParam
    let cardID: String
    @Bindable var vm: StudioViewModel
    /// True in the param sheet: color params grow the full hue/sat pad and the
    /// saved-colors strip (composer grammar). The compact tray stays swatches-
    /// only so MixerTrayMetrics' derived height keeps holding.
    var expandedColor: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            control
            if showsEntOnlyHint {
                Text("STREAMING ONLY — INACTIVE OVER REST")
                    .font(HueFont.stageTag)
                    .tracking(0.8)
                    .foregroundStyle(HuePalette.amber.opacity(0.65))
            }
        }
    }

    /// ENT-only params are ignored by the REST fallback loop — surface that
    /// while the card is actually running over REST.
    private var showsEntOnlyHint: Bool {
        param.entOnly
            && vm.currentRoomEffect?.cardID == cardID
            && vm.currentRoomEffect?.isEntertainment == false
    }

    @ViewBuilder
    private var control: some View {
        switch param.kind {
        case .slider(let min, let max):
            StudioSliderRow(param: param, cardID: cardID, min: min, max: max, vm: vm)
        case .colorPicker:
            colorPickerRow(param: param)
        case .toggle:
            toggleRow(param: param)
        case .segmented(let options):
            segmentedRow(param: param, options: options)
        }
    }

    @ViewBuilder
    private func colorPickerRow(param: StudioParam) -> some View {
        // sendColorParam persists via setParamColor AND live-tints running
        // bridge-native effects per-light — the old row only persisted,
        // leaving base_color dead while an effect ran.
        VStack(alignment: .leading, spacing: 10) {
            StageColorSwatchRow(
                title: param.label,
                swatches: StudioViewModel.presetColors,
                selected: vm.paramColor(for: cardID, paramID: param.id),
                onSelect: { color in
                    withAnimation(HueAnimation.fast) {
                        vm.sendColorParam(cardID: cardID, paramID: param.id, color: color)
                    }
                }
            )

            // Composer-grammar upgrade (sheet only — the compact tray keeps the
            // seven-swatch strip so MixerTrayMetrics' derived height holds):
            // the full hue/sat pad, plus the user's saved "My Colors".
            if expandedColor {
                HueSaturationPad(
                    title: "Fine Tune",
                    hue: currentHueSat(for: param).hue,
                    saturation: currentHueSat(for: param).saturation,
                    gamut: .c,
                    height: 120,
                    onChanged: { hue, sat, _ in
                        vm.sendColorParam(
                            cardID: cardID, paramID: param.id,
                            color: Color(hue: hue, saturation: sat, brightness: 1.0)
                        )
                    }
                )

                if !SavedColorStore.shared.colors.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("MY COLORS")
                            .font(HueFont.stageTag)
                            .tracking(1.2)
                            .foregroundStyle(.white.opacity(0.45))
                        SavedColorStrip { saved in
                            // Mirek-only swatches carry no xy; skip rather than guess.
                            guard let x = saved.x, let y = saved.y else { return }
                            let hsb = HueColorUtils.hsb(fromX: x, y: y, brightness: 100)
                            vm.sendColorParam(
                                cardID: cardID, paramID: param.id,
                                color: Color(hue: hsb.h, saturation: hsb.s, brightness: 1.0)
                            )
                            HapticManager.shared.selection()
                        }
                        .padding(.horizontal, -16)   // strip has its own margins
                    }
                }
            }
        }
    }

    /// The pad's canonical position for a color param — where the stored color
    /// actually sits, so the thumb doesn't lie.
    private func currentHueSat(for param: StudioParam) -> (hue: Double, saturation: Double) {
        guard let color = vm.paramColor(for: cardID, paramID: param.id) else { return (0, 1) }
        let ui = UIColor(color)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
        ui.getHue(&h, saturation: &s, brightness: &b, alpha: nil)
        return (Double(h), Double(s))
    }

    private func toggleRow(param: StudioParam) -> some View {
        StageToggleRow(
            title: param.label,
            isOn: Binding(
                get: { vm.paramValue(for: cardID, paramID: param.id, default: param.defaultValue) > 0.5 },
                set: { vm.setParamValue(for: cardID, paramID: param.id, value: $0 ? 1 : 0) }
            )
        )
    }

    private func segmentedRow(param: StudioParam, options: [(label: String, value: Double)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(param.label)
                .font(HueFont.stageControl)
                .foregroundStyle(.white.opacity(0.60))
            ChipPickerRow(
                items: options.map { ChipPickerRow<Double>.Item(value: $0.value, label: $0.label) },
                selection: Binding(
                    get: {
                        // Snap the stored value to the nearest option so values
                        // persisted before a param became segmented still select a chip.
                        let current = vm.paramValue(for: cardID, paramID: param.id, default: param.defaultValue)
                        return options.min { abs($0.value - current) < abs($1.value - current) }?.value ?? param.defaultValue
                    },
                    set: { newValue in
                        vm.setParamValue(for: cardID, paramID: param.id, value: newValue)
                        vm.sendParam(cardID: cardID, paramID: param.id, value: newValue)
                    }
                )
            )
        }
    }
}

// MARK: - StudioSliderRow

/// Slider with row-local value state: drags write through to the ViewModel
/// (running app-driven engines read `paramValues` live) but the row renders
/// from its own @State, and external writes (beat panel, reset, restore)
/// re-sync only when the user isn't dragging.
private struct StudioSliderRow: View {
    let param: StudioParam
    let cardID: String
    let min: Double
    let max: Double
    @Bindable var vm: StudioViewModel

    @State private var localValue: Double = 0
    @State private var isDragging = false
    @State private var seeded = false

    var body: some View {
        StageSlider(
            title: param.label,
            value: Binding(
                get: { localValue },
                set: { newValue in
                    localValue = newValue
                    vm.setParamValue(for: cardID, paramID: param.id, value: newValue)
                    // Same debounce + latest-wins mailbox discipline as before —
                    // sendParam itself debounces 150 ms and enqueues.
                    vm.sendParam(cardID: cardID, paramID: param.id, value: newValue)
                }
            ),
            range: min...max,
            format: param.format ?? { "\(Int($0.rounded()))" },
            onEditingChanged: { isDragging = $0 }
        )
        .onAppear {
            guard !seeded else { return }
            localValue = vm.paramValue(for: cardID, paramID: param.id, default: param.defaultValue)
            seeded = true
        }
        .onChange(of: vm.paramValues[cardID]?[param.id]) { _, newValue in
            guard !isDragging else { return }
            // nil = the card was reset to defaults — snap back to the default.
            let resolved = newValue ?? param.defaultValue
            if resolved != localValue { localValue = resolved }
        }
    }
}

// MARK: - StudioParamSheet
//
// Full parameter sheet with sections: Essential, Color, Advanced.
// Presented as a half-sheet from the mixer tray chevron.

struct StudioParamSheet: View {

    let card: StudioCard
    @Bindable var vm: StudioViewModel

    private var essentialParams: [StudioParam] { card.params.filter { $0.tier == .essential } }
    private var colorParams: [StudioParam]     { card.params.filter { $0.tier == .color } }
    private var advancedParams: [StudioParam]   { card.params.filter { $0.tier == .advanced } }

    var body: some View {
        StageSheetScaffold(title: card.name) {
            if !essentialParams.isEmpty {
                paramSection(title: "Essential", params: essentialParams)
            }
            if !colorParams.isEmpty {
                paramSection(title: "Color", params: colorParams)
            }
            if !advancedParams.isEmpty {
                paramSection(title: "Advanced", params: advancedParams)
            }

            // ── Reset to defaults ────────────────────
            Button {
                Task { await vm.resetParams(for: card) }
                HapticManager.shared.light()
            } label: {
                HStack {
                    Image(systemName: "arrow.counterclockwise")
                    Text("Reset to Defaults")
                        .fontWeight(.semibold)
                }
                .foregroundStyle(.white.opacity(0.75))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: HueRadius.lg)
                        .fill(Color.white.opacity(0.07))
                )
            }
            .buttonStyle(.plain)
            .padding(.top, HueSpacing.sm)

            // ── Stop button ──────────────────────────
            Button {
                Task { await vm.explicitStop(card) }
                HapticManager.shared.medium()
            } label: {
                HStack {
                    Image(systemName: "stop.fill")
                    Text("Stop \(card.name)")
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .allowsTightening(true)
                }
                .foregroundStyle(HuePalette.Noir.destructive)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: HueRadius.lg)
                        .fill(HuePalette.Noir.destructive.opacity(0.12))
                )
            }
            .buttonStyle(.plain)
            .padding(.top, HueSpacing.sm)
        }
    }

    private func paramSection(title: String, params: [StudioParam]) -> some View {
        StageCard(title: title) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(params) { param in
                    StudioParamRow(param: param, cardID: card.id, vm: vm, expandedColor: true)
                }
            }
        }
    }
}
