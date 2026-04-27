// EffectControlsView.swift
// HueHome Pro — Effects Tab
//
// Dynamically renders controls (sliders, colour pickers, toggles, segmented,
// duration pickers, colour palettes) from an effect's param schema.
// Also owns the Activate button.

import SwiftUI

// MARK: - EffectControlsView

struct EffectControlsView: View {

    let effect: HueEffect
    @Bindable var vm: EffectsViewModel     // must be @Observable
    let lights: [LightDisplayItem]

    @State private var showColorPicker: String? = nil   // key of open color picker
    @State private var isActivating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Section header ──────────────────────────────
            sectionHeader

            // ── Strategy badge ──────────────────────────────
            strategyBadge
                .padding(.bottom, 14)

            // ── Controls ────────────────────────────────────
            GlassmorphicCard(isActive: true, glowColor: effect.accentColor) {
                VStack(spacing: 0) {
                    ForEach(Array(effect.params.enumerated()), id: \.element.id) { idx, param in
                        paramControl(param)
                        if idx < effect.params.count - 1 {
                            Divider().background(Color.white.opacity(0.07)).padding(.vertical, 2)
                        }
                    }
                }
            }

            // ── Activate button ─────────────────────────────
            activateButton
                .padding(.top, 16)

            // ── Status message ──────────────────────────────
            if let msg = vm.statusMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.50))
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: vm.statusMessage)
    }

    // MARK: - Header

    private var sectionHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: effect.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(effect.accentColor)
            Text(effect.name.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
            Spacer()
            Text("Controls")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.25))
        }
        .padding(.bottom, 10)
    }

    // MARK: - Strategy Badge

    private var strategyBadge: some View {
        let (icon, label, color): (String, String, Color) = {
            switch effect.strategy {
            case .oneShot:         return ("checkmark.seal.fill",   "Set & Forget — persists on bridge",              .green)
            case .bridgeNative:    return ("checkmark.seal.fill",   "Bridge Native — persists after app closes",      .green)
            case .gradual:         return ("clock.fill",            "Gradual ramp — persists on bridge",              .teal)
            case .appDriven:       return ("iphone.badge.play",     "Live Effect — app must remain open",             .orange)
            }
        }()
        let teal = Color(red: 0.25, green: 0.85, blue: 0.75)
        _ = teal
        return HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10))
            Text(label).font(.system(size: 11))
        }
        .foregroundStyle(color.opacity(0.85))
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.12)))
    }

    // MARK: - Param Controls (dynamic dispatch)

    @ViewBuilder
    private func paramControl(_ param: EffectParam) -> some View {
        switch param {
        case .slider(let key, let label, _, let range, let step, let unit):
            SliderRow(
                label: label, unit: unit,
                value: Binding(
                    get: { vm.paramState.sliders[key] ?? ((range.lowerBound + range.upperBound) / 2) },
                    set: { vm.paramState.sliders[key] = $0 }
                ),
                range: range, step: step,
                accentColor: effect.accentColor
            )
            .padding(.vertical, 10)

        case .colorSwatch(let key, let label, _):
            ColorSwatchRow(
                label: label,
                color: Binding(
                    get: { vm.paramState.colors[key] ?? .white },
                    set: { vm.paramState.colors[key] = $0 }
                ),
                isExpanded: Binding(
                    get: { showColorPicker == key },
                    set: { showColorPicker = $0 ? key : nil }
                ),
                accentColor: effect.accentColor
            )
            .padding(.vertical, 10)

        case .colorPalette(let key, let label, _, let maxCount):
            ColorPaletteRow(
                label: label,
                colors: Binding(
                    get: { vm.paramState.palettes[key] ?? [] },
                    set: { vm.paramState.palettes[key] = $0 }
                ),
                maxCount: maxCount,
                accentColor: effect.accentColor
            )
            .padding(.vertical, 10)

        case .toggle(let key, let label, _):
            ToggleRow(
                label: label,
                value: Binding(
                    get: { vm.paramState.toggles[key] ?? false },
                    set: { vm.paramState.toggles[key] = $0 }
                ),
                accentColor: effect.accentColor
            )
            .padding(.vertical, 10)

        case .segmented(let key, let label, let options, _):
            SegmentedRow(
                label: label,
                options: options,
                selectedIndex: Binding(
                    get: { vm.paramState.segmented[key] ?? 0 },
                    set: { vm.paramState.segmented[key] = $0 }
                ),
                accentColor: effect.accentColor
            )
            .padding(.vertical, 10)

        case .durationPicker(let key, let label, _, let opts, let fmt):
            DurationPickerRow(
                label: label,
                options: opts,
                formatter: fmt,
                selectedSeconds: Binding(
                    get: { vm.paramState.durations[key] ?? opts.first ?? 900 },
                    set: { vm.paramState.durations[key] = $0 }
                ),
                accentColor: effect.accentColor
            )
            .padding(.vertical, 10)
        }
    }

    // MARK: - Activate Button

    private var activateButton: some View {
        let roomLabel = vm.selectedRoomID == nil
            ? "All Rooms (\(lights.count) lights)"
            : "Selected Room (\(lights.count) lights)"

        return Button {
            isActivating = true
            HapticManager.shared.heavy()
            Task {
                await vm.activate(lights: lights)
                withAnimation { isActivating = false }
            }
        } label: {
            HStack(spacing: 10) {
                if isActivating {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.black)
                        .scaleEffect(0.75)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 14, weight: .bold))
                }
                Text(isActivating ? "Applying…" : "Activate — \(roomLabel)")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 17)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isActivating
                          ? effect.accentColor.opacity(0.6)
                          : effect.accentColor)
                    .shadow(color: effect.accentColor.opacity(0.45), radius: 16, x: 0, y: 6)
            )
        }
        .buttonStyle(.plain)
        .disabled(isActivating || lights.isEmpty)
    }
}

// MARK: - SliderRow

struct SliderRow: View {
    let label:       String
    let unit:        String
    @Binding var value: Double
    let range:       ClosedRange<Double>
    let step:        Double
    let accentColor: Color

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.80))
                Spacer()
                Text(formattedValue)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(accentColor)
                    .frame(minWidth: 50, alignment: .trailing)
            }
            HStack(spacing: 10) {
                Text(formatted(range.lowerBound))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.25))
                    .frame(width: 28, alignment: .leading)

                Slider(value: $value, in: range, step: step)
                    .tint(accentColor)

                Text(formatted(range.upperBound))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.25))
                    .frame(width: 34, alignment: .trailing)
            }
        }
    }

    private var formattedValue: String {
        if unit == "%" { return "\(Int(value))\(unit)" }
        if unit == "K" { return "\(Int(1_000_000 / value))K" }   // mirek → Kelvin display
        if unit == "ms" { return value >= 1000 ? String(format: "%.1fs", value / 1000) : "\(Int(value))ms" }
        if unit == "BPM" { return "\(Int(value)) BPM" }
        if unit == "" { return String(format: "%.1f", value) }
        return "\(Int(value)) \(unit)"
    }

    private func formatted(_ v: Double) -> String {
        v >= 1000 ? String(format: "%.0f", v) : String(format: v.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f" : "%.1f", v)
    }
}

// MARK: - ColorSwatchRow

struct ColorSwatchRow: View {
    let label:       String
    @Binding var color: Color
    @Binding var isExpanded: Bool
    let accentColor: Color

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.80))
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.3)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(color)
                            .frame(width: 32, height: 24)
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(.white.opacity(0.15), lineWidth: 1))
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
                .buttonStyle(.plain)
            }
            if isExpanded {
                ColorPicker("", selection: $color, supportsOpacity: false)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }
}

// MARK: - ToggleRow

struct ToggleRow: View {
    let label: String
    @Binding var value: Bool
    let accentColor: Color

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.80))
            Spacer()
            Toggle("", isOn: $value)
                .tint(accentColor)
                .labelsHidden()
        }
    }
}

// MARK: - SegmentedRow

struct SegmentedRow: View {
    let label:       String
    let options:     [String]
    @Binding var selectedIndex: Int
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.80))

            HStack(spacing: 6) {
                ForEach(Array(options.enumerated()), id: \.offset) { idx, opt in
                    Button {
                        withAnimation(.spring(response: 0.25)) { selectedIndex = idx }
                        HapticManager.shared.light()
                    } label: {
                        Text(opt)
                            .font(.system(size: 12, weight: selectedIndex == idx ? .semibold : .regular))
                            .foregroundStyle(selectedIndex == idx ? .black : .white.opacity(0.65))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Capsule().fill(
                                selectedIndex == idx ? accentColor : Color.white.opacity(0.10)
                            ))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - DurationPickerRow

struct DurationPickerRow: View {
    let label:    String
    let options:  [Int]
    let formatter: (Int) -> String
    @Binding var selectedSeconds: Int
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.80))
            HStack(spacing: 8) {
                ForEach(options, id: \.self) { secs in
                    Button {
                        withAnimation { selectedSeconds = secs }
                        HapticManager.shared.light()
                    } label: {
                        Text(formatter(secs))
                            .font(.system(size: 12, weight: selectedSeconds == secs ? .semibold : .regular))
                            .foregroundStyle(selectedSeconds == secs ? .black : .white.opacity(0.65))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Capsule().fill(
                                selectedSeconds == secs ? accentColor : Color.white.opacity(0.10)
                            ))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - ColorPaletteRow

struct ColorPaletteRow: View {
    let label:       String
    @Binding var colors: [Color]
    let maxCount:    Int
    let accentColor: Color

    @State private var editingIndex: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.80))
                Spacer()
                if colors.count < maxCount {
                    Button {
                        withAnimation { colors.append(.white) }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(accentColor)
                            .font(.system(size: 18))
                    }
                    .buttonStyle(.plain)
                }
            }

            // Swatches (drag-to-reorder omitted for now — use long-press delete)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(colors.enumerated()), id: \.offset) { idx, col in
                        ZStack(alignment: .topTrailing) {
                            Button {
                                editingIndex = editingIndex == idx ? nil : idx
                            } label: {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(col)
                                    .frame(width: 48, height: 48)
                                    .overlay(RoundedRectangle(cornerRadius: 10)
                                        .strokeBorder(editingIndex == idx ? .white : .white.opacity(0.15),
                                                      lineWidth: editingIndex == idx ? 2 : 1))
                                    .shadow(color: col.opacity(0.5), radius: 8, x: 0, y: 3)
                            }
                            .buttonStyle(.plain)

                            // Delete button
                            if colors.count > 1 {
                                Button {
                                    withAnimation { colors.remove(at: idx); editingIndex = nil }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 14))
                                        .foregroundStyle(.white)
                                        .background(Circle().fill(.black.opacity(0.5)).padding(2))
                                }
                                .buttonStyle(.plain)
                                .offset(x: 5, y: -5)
                            }
                        }
                    }
                }
                .padding(.horizontal, 2).padding(.vertical, 6)
            }

            // Inline color picker for selected swatch
            if let idx = editingIndex, idx < colors.count {
                ColorPicker("Edit color \(idx + 1)", selection: $colors[idx], supportsOpacity: false)
                    .labelsHidden()
                    .transition(.opacity)
            }
        }
    }
}
