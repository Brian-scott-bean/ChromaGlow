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
    /// The "Back to decks" row that replaced the grab bar. The capsule's only
    /// job was "drag or tap to dismiss"; dismissal is a named destination now,
    /// so the gesture that competed with every child control is gone.
    static let backToDecksRowHeight: CGFloat = 36
    /// The badge lane inside the operational panel (LIVE, coverage,
    /// transport, room count). Fixed so the panel never resizes with badge
    /// count. (Slice 2 moved the lane from the pinned header into the panel
    /// that expands from the identity.)
    static let badgeLaneHeight: CGFloat = 28
    static let sliderRowHeight: CGFloat = 56
    static let verticalPadding: CGFloat = 16
    /// Floating tab bar + home indicator — the clearance a bottom-anchored
    /// Studio surface owes when nothing else is clearing the bar for it.
    static func tabBarClearance(bottomInset: CGFloat) -> CGFloat {
        max(72, 56 + bottomInset)
    }

    /// Clearance below the mixer tray. When the music bar is mounted it rides
    /// its own bottom safeAreaInset, which ALREADY floors Studio's content at
    /// the bar's top edge and ALREADY clears the floating HueTabBar (the bar's
    /// own `.padding(.bottom, 70)`) — so the tray owes only a card-to-card gap.
    /// Re-adding `tabBarClearance` on top of that padded the tray off a floor
    /// it was already sitting on: ~200pt of dead band, since `bottomInset` here
    /// is the whole music-bar band plus the home indicator. Same double-count
    /// DEVLOG R8c (2026-07-21) fixed for the deck spacer and missed on the
    /// tray. With the bar suppressed nothing else clears the tab bar and the
    /// full figure is owed.
    static func bottomClearance(bottomInset: CGFloat, barMounted: Bool) -> CGFloat {
        barMounted ? HueSpacing.sm : tabBarClearance(bottomInset: bottomInset)
    }

    // DELETED in Track A C5: `engineHeight`, `compositionHeight` and
    // `compactHeightCap` — they sized a fixed-height bottom-anchored box.
    //
    // DELETED in Slice 2: `headerHeight`, `statusLineHeight`,
    // `headerBlockHeight`, `moreRowHeight`, and the `inlineParams` /
    // `overflowParams` tier partition. The three-row pinned header became
    // the one-line identity (`StudioIdentityHeader`) with its status inside
    // the scrolling operational panel — nothing to reserve — and the board
    // layout comes from `StudioBoardCatalog.descriptor(for:)`, which places
    // EVERY declared param on the one board (hero / primary / supporting),
    // with no Advanced bucket to partition into. `bottomClearance` is NOT
    // dead and stays — it is the build-46 double-count fix.
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
                // "REST" is a developer word the transport vocabulary bans;
                // this string sat outside both guards and said it anyway.
                Text("STREAMING ONLY — INACTIVE IN ROOM MODE")
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
        // commitColorParam persists as the next-start default AND live-tints running
        // bridge-native effects per-light — the old row only persisted,
        // leaving base_color dead while an effect ran.
        VStack(alignment: .leading, spacing: 10) {
            StageColorSwatchRow(
                title: param.label,
                swatches: StudioViewModel.presetColors,
                selected: vm.paramColor(for: cardID, paramID: param.id),
                onSelect: { color in
                    withAnimation(HueAnimation.fast) {
                        vm.commitColorParam(cardID: cardID, paramID: param.id, color: color)
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
                        vm.commitColorParam(
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
                            vm.commitColorParam(
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
                set: { vm.commitParam(cardID: cardID, paramID: param.id, value: $0 ? 1 : 0) }
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
                        // commitParam captures the exact running identity at
                        // call time, commits through the fence, pushes the
                        // engine box, and schedules the debounced bridge send.
                        vm.commitParam(cardID: cardID, paramID: param.id, value: newValue)
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
    /// The exact identity + routing facts captured when THIS gesture began.
    /// Every tick commits against it — a selection change, stop, reset, or
    /// card replacement mid-drag makes the remaining ticks drop instead of
    /// landing on whatever is selected now.
    @State private var editSession: StudioParamSession?

    var body: some View {
        StageSlider(
            title: param.label,
            value: Binding(
                get: { localValue },
                set: { newValue in
                    localValue = newValue
                    if let session = editSession {
                        vm.updateParamEdit(session, value: newValue)
                    } else {
                        // No captured session (gesture began with the card not
                        // running here, or a tick arrived before the editing
                        // bracket) — one-shot capture-at-call is still exact.
                        vm.commitParam(cardID: cardID, paramID: param.id, value: newValue)
                    }
                }
            ),
            range: min...max,
            format: param.format ?? { "\(Int($0.rounded()))" },
            onEditingChanged: { editing in
                isDragging = editing
                if editing {
                    editSession = vm.beginParamEdit(cardID: cardID, paramID: param.id)
                } else {
                    if let session = editSession { vm.endParamEdit(session) }
                    editSession = nil
                }
            }
        )
        .onAppear {
            guard !seeded else { return }
            localValue = vm.paramValue(for: cardID, paramID: param.id, default: param.defaultValue)
            seeded = true
        }
        .onChange(of: vm.paramValue(for: cardID, paramID: param.id, default: param.defaultValue)) { _, newValue in
            guard !isDragging else { return }
            // Reset / target switch / external write — snap to the resolved value.
            if newValue != localValue { localValue = newValue }
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
    private var advancedParams: [StudioParam]   { card.params.filter { $0.tier == .support } }

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
