// StudioParamControls.swift
// CastChroma — Studio engine-card parameter controls.
//
// Pure move out of StudioView.swift (adjustment-settings revamp): the
// per-param row renderer and the Essential/Color/Advanced half-sheet used
// by the mixer tray for bridge-native and app-driven cards.

import SwiftUI

// MARK: - StudioParamRow
//
// Performance note: slider still uses @Bindable vm for now.
// Phase 1 priority is layout. Phase 3 will convert to local @State + onCommit.

struct StudioParamRow: View {

    let param: StudioParam
    let cardID: String
    @Bindable var vm: StudioViewModel

    var body: some View {
        switch param.kind {
        case .slider(let min, let max):
            sliderRow(param: param, min: min, max: max)
        case .colorPicker:
            colorPickerRow(param: param)
        case .toggle:
            toggleRow(param: param)
        }
    }

    private func sliderRow(param: StudioParam, min: Double, max: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(param.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.60))
                Spacer()
                Text("\(Int(vm.paramValue(for: cardID, paramID: param.id, default: param.defaultValue)))")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.40))
            }
            Slider(
                value: Binding(
                    get: { vm.paramValue(for: cardID, paramID: param.id, default: param.defaultValue) },
                    set: { vm.setParamValue(for: cardID, paramID: param.id, value: $0) }
                ),
                in: min...max
            )
            .tint(HuePalette.amber)
            .onChange(of: vm.paramValues[cardID]?[param.id]) { _, newValue in
                guard let value = newValue else { return }
                // Send live updates for bridge-controllable params
                vm.sendParam(cardID: cardID, paramID: param.id, value: value)
            }
        }
    }

    private func colorPickerRow(param: StudioParam) -> some View {
        HStack {
            Text(param.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.60))
            Spacer()
            HStack(spacing: 8) {
                ForEach(StudioViewModel.presetColors, id: \.self) { color in
                    let isActive = vm.paramColor(for: cardID, paramID: param.id) == color
                    Circle()
                        .fill(color)
                        .frame(width: 26, height: 26)
                        .overlay(Circle().strokeBorder(.white, lineWidth: isActive ? 2 : 0))
                        .onTapGesture {
                            withAnimation(HueAnimation.fast) {
                                vm.setParamColor(for: cardID, paramID: param.id, color: color)
                            }
                        }
                }
            }
        }
    }

    private func toggleRow(param: StudioParam) -> some View {
        HStack {
            Text(param.label)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.white)
            Spacer()
            Toggle("", isOn: Binding(
                get: { vm.paramValue(for: cardID, paramID: param.id, default: 0) > 0.5 },
                set: { vm.setParamValue(for: cardID, paramID: param.id, value: $0 ? 1 : 0) }
            ))
            .tint(HuePalette.amber)
            .labelsHidden()
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
        NavigationStack {
            ScrollView {
                VStack(spacing: HueSpacing.lg) {
                    // ── Essential ─────────────────────────────
                    if !essentialParams.isEmpty {
                        paramSection(title: "ESSENTIAL", params: essentialParams)
                    }

                    // ── Color ────────────────────────────────
                    if !colorParams.isEmpty {
                        paramSection(title: "COLOR", params: colorParams)
                    }

                    // ── Advanced ─────────────────────────────
                    if !advancedParams.isEmpty {
                        paramSection(title: "ADVANCED", params: advancedParams)
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
                .padding(HueSpacing.screenH)
            }
            .navigationTitle(card.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }

    private func paramSection(title: String, params: [StudioParam]) -> some View {
        VStack(alignment: .leading, spacing: HueSpacing.md) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
                .tracking(0.8)

            ForEach(params) { param in
                StudioParamRow(param: param, cardID: card.id, vm: vm)
            }
        }
    }
}
