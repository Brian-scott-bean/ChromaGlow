// PhysicalControlsView.swift
// ChromaGlow — Physical Controls (Luminous).
//
// One-tap "DJ Mode" template: the Hue Tap Dial becomes a physical
// performance controller. Events arrive over the SSE stream the app
// already holds open — no pairing, no extra connection. "Hue Tap Dial" is
// the only trademark form used on this screen.

import SwiftUI

struct PhysicalControlsView: View {

    @Environment(UnifiedOrchestrator.self) private var orchestrator

    private let blue = Color(hex: "#668AFF")

    var body: some View {
        LuminousPage(title: "Physical Controls",
                     eyebrow: "Tap Dial · DJ Mode",
                     eyebrowSymbol: "dial.medium.fill",
                     tint: blue,
                     subtitle: "Hands-free tempo and punches while you perform",
                     ambience: [blue, LuminousPalette.violet]) {
            djModeCard

            if orchestrator.djModeEnabled {
                mappingCard
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Text("Works with any Hue Tap Dial paired to your bridge. Rotations and presses arrive over the bridge's live event stream — nothing extra to set up.")
                .font(.footnote)
                .foregroundStyle(LuminousPalette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: orchestrator.djModeEnabled)
    }

    private var djModeCard: some View {
        @Bindable var orchestrator = orchestrator
        return LuminousGroup {
            LuminousToggleRow(symbol: "dial.medium.fill", tint: blue, title: "DJ Mode",
                              subtitle: orchestrator.djModeEnabled ? "Listening for dial events" : "Off",
                              isOn: $orchestrator.djModeEnabled)
        }
    }

    private var mappingCard: some View {
        LuminousGroup(title: "What the dial does") {
            mappingRow(icon: "dial.medium", control: "Rotate the dial",
                       action: "Nudge BPM up / down (pins the clock)")
            LuminousRowDivider()
            mappingRow(icon: "1.circle.fill", control: "Button 1 · press",
                       action: "Tap tempo — press on the beat")
            LuminousRowDivider()
            mappingRow(icon: "1.circle", control: "Button 1 · hold",
                       action: "Resync the downbeat to now")
            LuminousRowDivider()
            mappingRow(icon: "2.circle.fill", control: "Buttons 2 – 4",
                       action: "Punch flashes on the playing room")
        }
    }

    private func mappingRow(icon: String, control: String, action: String) -> some View {
        LuminousRow(symbol: icon, tint: blue, title: control, subtitle: action) { EmptyView() }
            .accessibilityElement(children: .combine)
    }
}
