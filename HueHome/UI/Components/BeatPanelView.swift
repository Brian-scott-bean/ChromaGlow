// BeatPanelView.swift
// ChromaGlow — UI/Components (Round 3: Universal Beat Panel)
//
// ONE beat panel for the whole app. Surfaces declare what they support via
// BeatPanelCapabilities; the panel renders only those sections. The live
// chip (BeatStatusChip) is the panel's door — it sits in the Dashboard
// Now-Playing bar, the Studio mixer header, and the Effects running banner,
// and opens the panel as a popover.
//
// The panel is UI only: it reads/writes BeatClock.shared and an optional
// BeatBinding. Loops consume the clock via BeatClock.snapshot() + BeatMath —
// never through this view.

import SwiftUI
import QuartzCore

// MARK: - BeatPanelCapabilities

/// What a hosting surface supports. Global effects get transport + sync;
/// Composer adds its deeper reaction controls (rendered by the editor).
struct BeatPanelCapabilities: OptionSet {
    let rawValue: Int

    static let transport  = BeatPanelCapabilities(rawValue: 1 << 0)  // Tap/Auto/Resync + live BPM
    static let manualBPM  = BeatPanelCapabilities(rawValue: 1 << 1)  // − BPM + stepper, nudge
    static let barMeter   = BeatPanelCapabilities(rawValue: 1 << 2)  // pulsing beat dots
    static let binding    = BeatPanelCapabilities(rawValue: 1 << 3)  // Off ¼ ½ 1 2 4 8 + phase
    static let colorStep  = BeatPanelCapabilities(rawValue: 1 << 4)  // Composer: quantized color
    static let motionLock = BeatPanelCapabilities(rawValue: 1 << 5)  // Composer: beats/cycle
    static let punchDecay = BeatPanelCapabilities(rawValue: 1 << 6)  // Composer: punch decay

    /// Effects tab / Studio cards / Dashboard popover.
    static let global: BeatPanelCapabilities = [.transport, .manualBPM, .barMeter, .binding]
    /// Composer editor (binding lives in ReactionConfig, not BeatBinding).
    static let composer: BeatPanelCapabilities = [.transport, .manualBPM, .barMeter,
                                                  .colorStep, .motionLock, .punchDecay]
}

// MARK: - BeatStatusChip

/// Compact live clock chip: pulsing dot + BPM. Tap target for the panel
/// popover — the host attaches the action/popover.
struct BeatStatusChip: View {
    var compact = false

    private var clock: BeatClock { BeatClock.shared }

    var body: some View {
        HStack(spacing: 6) {
            TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { _ in
                // context.date only triggers redraw; the clock runs on the
                // CACurrentMediaTime timebase.
                let snap = BeatClock.snapshot()
                let phase = snap.beatPhase(at: CACurrentMediaTime())
                Circle()
                    .fill(HuePalette.amber)
                    .frame(width: 7, height: 7)
                    .opacity(snap.bpm > 0 ? (1.0 - 0.65 * beatFlashDecay(phase)) : 0.35)
            }
            Text(clock.bpm > 0 ? "\(Int(clock.bpm.rounded()))" : "—")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(clock.bpm > 0 ? HuePalette.amber : .white.opacity(0.45))
            if !compact {
                Image(systemName: "metronome.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(.white.opacity(0.08)))
        .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
        .contentShape(Capsule())
        .accessibilityLabel(clock.bpm > 0
                            ? "Beat clock, \(Int(clock.bpm.rounded())) BPM"
                            : "Beat clock, no tempo")
    }

    /// 1 right on the beat → 0 by mid-beat (sharp attack, fast decay).
    private func beatFlashDecay(_ phase: Double) -> Double {
        min(1, phase * 3)
    }
}

// MARK: - ChipPickerRow

/// One-tap pill row that replaces two-tap `.menu` pickers. Every option is
/// visible (horizontally scrollable when tight); selection is a single tap.
struct ChipPickerRow<Value: Hashable>: View {
    struct Item {
        let value: Value
        let label: String
        var icon: String? = nil
    }

    let items: [Item]
    @Binding var selection: Value

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    let selected = item.value == selection
                    Button {
                        guard !selected else { return }
                        selection = item.value
                        HapticManager.shared.selection()
                    } label: {
                        HStack(spacing: 4) {
                            if let icon = item.icon {
                                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                            }
                            Text(item.label)
                                .font(.system(size: 12, weight: selected ? .bold : .medium,
                                              design: .monospaced))
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(selected ? HuePalette.amber : .white.opacity(0.08)))
                        .foregroundStyle(selected ? Color.black.opacity(0.85) : .white.opacity(0.65))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.vertical, 1)
        }
    }
}

// MARK: - BeatPanelView

/// The shared panel. `binding` is non-nil for surfaces that persist a
/// BeatBinding (Effects tab, Studio cards); Composer passes nil and renders
/// its ReactionConfig controls alongside via `capabilities`.
struct BeatPanelView: View {
    let capabilities: BeatPanelCapabilities
    var binding: Binding<BeatBinding>? = nil

    private var clock: BeatClock { BeatClock.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: HueSpacing.md) {
            if capabilities.contains(.transport) { transportRow }
            if capabilities.contains(.barMeter) { barMeterRow }
            if capabilities.contains(.manualBPM) { manualRow }
            if capabilities.contains(.binding), let binding { bindingSection(binding) }
        }
        .padding(HueSpacing.md)
    }

    // ── Transport: live readout + Tap / Auto / Resync ──
    private var transportRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "metronome.fill")
                .font(.system(size: 12))
                .foregroundStyle(HuePalette.amber)
            Text(clock.bpm > 0
                 ? String(format: "%.1f BPM · %@", clock.bpm, clock.source.rawValue.capitalized)
                 : "Listening for a beat…")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
            Spacer(minLength: 4)
            Button("Tap") {
                clock.tap()
                HapticManager.shared.light()
            }
            .font(.system(size: 12, weight: .semibold))
            .buttonStyle(.bordered)
            .tint(HuePalette.amber)
            if clock.isPinned {
                Button("Auto") {
                    clock.unpin()
                    HapticManager.shared.selection()
                }
                .font(.system(size: 12, weight: .semibold))
                .buttonStyle(.bordered)
                .tint(.white.opacity(0.5))
            } else if clock.bpm > 0 {
                Button("Resync") {
                    clock.resyncDownbeat()
                    HapticManager.shared.selection()
                }
                .font(.system(size: 12, weight: .semibold))
                .buttonStyle(.bordered)
                .tint(.white.opacity(0.5))
            }
        }
    }

    // ── Bar meter: dots that fill as the bar advances ──
    private var barMeterRow: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { _ in
            let snap = BeatClock.snapshot()
            let beats = max(1, snap.beatsPerBar)
            let now = CACurrentMediaTime()
            let beatInBar = snap.bpm > 0
                ? Int(snap.barPhase(at: now) * Double(beats))
                : -1
            HStack(spacing: 5) {
                ForEach(0..<beats, id: \.self) { i in
                    Circle()
                        .fill(i <= beatInBar ? HuePalette.amber : .white.opacity(0.15))
                        .frame(width: 7, height: 7)
                }
                Spacer()
            }
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }

    // ── Manual BPM + phase nudge (headless in Phase 2 — now real UI) ──
    private var manualRow: some View {
        HStack(spacing: 8) {
            Button {
                clock.setBPM(max(20, clock.bpm.rounded() - 1))
                HapticManager.shared.selection()
            } label: { Image(systemName: "minus") }
            .buttonStyle(.bordered)
            .tint(.white.opacity(0.5))
            .disabled(clock.bpm <= 0)

            Text(clock.bpm > 0 ? "\(Int(clock.bpm.rounded()))" : "—")
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundStyle(HuePalette.amber)
                .frame(minWidth: 44)

            Button {
                clock.setBPM(min(300, clock.bpm > 0 ? clock.bpm.rounded() + 1 : 120))
                HapticManager.shared.selection()
            } label: { Image(systemName: "plus") }
            .buttonStyle(.bordered)
            .tint(.white.opacity(0.5))

            Spacer()

            Button("−10ms") {
                clock.nudgePhase(ms: -10)
                HapticManager.shared.selection()
            }
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .buttonStyle(.bordered)
            .tint(.white.opacity(0.5))
            .disabled(clock.bpm <= 0)
            Button("+10ms") {
                clock.nudgePhase(ms: 10)
                HapticManager.shared.selection()
            }
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .buttonStyle(.bordered)
            .tint(.white.opacity(0.5))
            .disabled(clock.bpm <= 0)
        }
    }

    // ── Binding: Off ¼ ½ 1 2 4 8 + phase offset ──
    @ViewBuilder
    private func bindingSection(_ binding: Binding<BeatBinding>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Beat sync")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
            ChipPickerRow(
                items: [ChipPickerRow<Double>.Item(value: 0, label: "Off")]
                    + BeatBinding.allowedSteps.map {
                        ChipPickerRow<Double>.Item(value: $0, label: Self.stepLabel($0))
                    },
                selection: Binding(
                    get: {
                        binding.wrappedValue.isActive ? binding.wrappedValue.beatsPerCycle : 0
                    },
                    set: { newValue in
                        if newValue <= 0 {
                            binding.wrappedValue.mode = .off
                        } else {
                            binding.wrappedValue.mode = .beatLocked
                            binding.wrappedValue.beatsPerCycle = newValue
                        }
                    }
                )
            )
            if binding.wrappedValue.isActive {
                HStack {
                    Text("Phase")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                    Slider(
                        value: Binding(
                            get: { binding.wrappedValue.phaseOffsetBeats },
                            set: { binding.wrappedValue.phaseOffsetBeats = ($0 * 4).rounded() / 4 }
                        ),
                        in: -2...2
                    )
                    .tint(HuePalette.amber)
                    Text(String(format: "%+.2f ♩", binding.wrappedValue.phaseOffsetBeats))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(width: 58, alignment: .trailing)
                }
            }
        }
    }

    static func stepLabel(_ step: Double) -> String {
        switch step {
        case 0.25: return "¼"
        case 0.5:  return "½"
        default:   return String(Int(step))
        }
    }
}
