// PhysicalControlsView.swift
// ChromaGlow — Round 3 Phase G (Tap Dial as DJ controller)
//
// One-tap "DJ Mode" template: the Hue Tap Dial becomes a physical
// performance controller. Events arrive over the SSE stream the app
// already holds open — no pairing, no extra connection.

import SwiftUI

struct PhysicalControlsView: View {

    @Environment(UnifiedOrchestrator.self) private var orchestrator

    var body: some View {
        ZStack {
            Color(red: 0.055, green: 0.055, blue: 0.08).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header

                    djModeCard

                    if orchestrator.djModeEnabled {
                        mappingCard
                    }

                    Text("Works with any Hue Tap Dial paired to your bridge. Rotations and presses arrive over the bridge's live event stream — nothing extra to set up.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.horizontal, 4)
                }
                .padding(20)
            }
        }
        .navigationTitle("Physical Controls")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(HuePalette.amber.opacity(0.18)).frame(width: 44, height: 44)
                Image(systemName: "dial.medium.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(HuePalette.amber)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Tap Dial · DJ Mode")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                Text("Hands-free tempo and punches while you perform")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private var djModeCard: some View {
        @Bindable var orchestrator = orchestrator
        return Toggle(isOn: $orchestrator.djModeEnabled) {
            VStack(alignment: .leading, spacing: 2) {
                Text("DJ Mode")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Text(orchestrator.djModeEnabled ? "Listening for dial events" : "Off")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .tint(HuePalette.amber)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.06)))
    }

    private var mappingCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            mappingRow(icon: "dial.medium", control: "Rotate the dial",
                       action: "Nudge BPM up / down (pins the clock)")
            divider
            mappingRow(icon: "1.circle.fill", control: "Button 1 · press",
                       action: "Tap tempo — press on the beat")
            divider
            mappingRow(icon: "1.circle", control: "Button 1 · hold",
                       action: "Resync the downbeat to now")
            divider
            mappingRow(icon: "2.circle.fill", control: "Buttons 2 – 4",
                       action: "Punch flashes on the playing room")
        }
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.06)))
    }

    private func mappingRow(icon: String, control: String, action: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(HuePalette.amber)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(control)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(action)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5)
            .padding(.leading, 54)
    }
}
