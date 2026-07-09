// StudioParamControls.swift
// CastChroma — Studio engine-card parameter controls.
//
// The per-param row renderer and the Essential/Color/Advanced half-sheet
// used by the mixer tray for bridge-native and app-driven cards. Rebuilt on
// StageKit (adjustment-settings revamp): rows are the shared stage
// components, the slider holds row-local state so drags don't round-trip
// through the ViewModel per tick, and the sheet uses the unified scaffold.

import SwiftUI

// MARK: - StudioParamRow

struct StudioParamRow: View {

    let param: StudioParam
    let cardID: String
    @Bindable var vm: StudioViewModel

    var body: some View {
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

    private func colorPickerRow(param: StudioParam) -> some View {
        // sendColorParam persists via setParamColor AND live-tints running
        // bridge-native effects per-light — the old row only persisted,
        // leaving base_color dead while an effect ran.
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
                .font(.system(size: 12, weight: .medium))
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
            guard !isDragging, let value = newValue, value != localValue else { return }
            localValue = value
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

            // ── Stop button ──────────────────────────
            Button {
                Task { await vm.explicitStop(card) }
                HapticManager.shared.medium()
            } label: {
                HStack {
                    Image(systemName: "stop.fill")
                    Text("Stop \(card.name)")
                        .fontWeight(.semibold)
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
                    StudioParamRow(param: param, cardID: card.id, vm: vm)
                }
            }
        }
    }
}
