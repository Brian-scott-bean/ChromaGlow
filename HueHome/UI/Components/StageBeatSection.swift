// StageBeatSection.swift
// CastChroma — Slice 2 inline Beat instrument for the Studio board (spec §21).
//
// One shared Beat implementation remains app-wide: this is a thin
// progressive-reveal wrapper around the existing `BeatPanelView`, not a fork.
// Off → a single quiet activation row. On → the full shared Beat instrument
// (transport with Tap/Auto/Resync, bar meter, manual BPM, division chips,
// phase offset) reveals inline in the host's one scroll — natural reflow, no
// popover, no sheet.
//
// Only engines with PROVEN material BeatBinding consumption render this
// (audit §2C table: all four current Live engines qualify). The board
// descriptor decides; this view never guesses.
//
// Safety: the division the user picks is still walked through
// `wcagSafeBeatsPerCycle` inside every engine loop — nothing here can raise
// a flash rate past the ≤3 Hz ceiling.

import SwiftUI

struct StageBeatSection: View {
    @Binding var binding: BeatBinding

    private var isOn: Bool { binding.isActive }

    var body: some View {
        VStack(alignment: .leading, spacing: HueSpacing.sm) {
            activationRow
            if isOn {
                // The full shared instrument, inline. `.global` = transport
                // (Tap/Auto/Resync) + manual BPM + bar meter; `.binding`
                // adds the division chips and phase offset.
                BeatPanelView(capabilities: [.transport, .manualBPM, .barMeter, .binding],
                              binding: $binding)
                    .padding(.horizontal, -HueSpacing.md)  // panel carries its own padding
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var activationRow: some View {
        Button {
            withAnimation(HueAnimation.fast) {
                if isOn {
                    binding.mode = .off
                } else {
                    binding.mode = .beatLocked
                    if binding.beatsPerCycle <= 0 { binding.beatsPerCycle = 1 }
                }
            }
            HapticManager.shared.selection()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isOn ? "circle.fill" : "circle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isOn ? HuePalette.amber : .white.opacity(0.35))
                Text("BEAT SYNC")
                    .font(HueFont.stageTag)
                    .tracking(1.2)
                    .foregroundStyle(isOn ? StagePalette.ink : .white.opacity(0.55))
                if isOn {
                    BeatStatusChip()
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .frame(minHeight: HueHit.min)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Beat sync")
        .accessibilityValue(isOn ? "on" : "off")
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityHint(isOn ? "Turns beat sync off" : "Turns beat sync on and reveals its controls")
    }
}
