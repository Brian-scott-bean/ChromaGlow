// TabShells.swift
// HueHome Pro — Stage 1
// Placeholder shells for tabs 3–5 (Automations, Devices, Settings).
// Scenes tab moved to UI/Scenes/ScenesTabView.swift (Stage 2B).

import SwiftUI

// MARK: - Automations Tab

struct AutomationsTabView: View {
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        ZStack {
            (colorScheme == .dark ? HuePalette.Noir.background : HuePalette.Estate.background)
                .ignoresSafeArea()

            // Temporary — existing AutomationsView content will be moved here in Stage 4
            AutomationsView()
        }
        .navigationTitle("Automate")
        .navigationBarTitleDisplayMode(.large)
    }
}

// MARK: - Devices Tab

struct DevicesTabView: View {
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        ZStack {
            (colorScheme == .dark ? HuePalette.Noir.background : HuePalette.Estate.background)
                .ignoresSafeArea()

            VStack(spacing: HueSpacing.xxl) {
                Image(systemName: "sensor.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(HuePalette.amber.opacity(0.6))

                Text("Devices")
                    .font(HueFont.displayMedium)
                    .foregroundStyle(
                        colorScheme == .dark
                            ? HuePalette.Noir.textPrimary
                            : HuePalette.Estate.textPrimary
                    )

                Text("Sensors, buttons, and firmware viewer coming in Stage 3")
                    .font(HueFont.body)
                    .foregroundStyle(
                        colorScheme == .dark
                            ? HuePalette.Noir.textSecondary
                            : HuePalette.Estate.textSecondary
                    )
                    .multilineTextAlignment(.center)
            }
            .padding(HueSpacing.section)
        }
        .navigationTitle("Devices")
        .navigationBarTitleDisplayMode(.large)
    }
}

// MARK: - Settings Tab

struct SettingsTabView: View {
    var body: some View {
        // SettingsView owns its own background and nav modifiers.
        // MainTabView provides the surrounding NavigationStack
        // so BridgeManagerView NavigationLink pushes correctly.
        SettingsView(onForget: {
            NotificationCenter.default.post(name: .hueBridgeUnpaired, object: nil)
        })
    }
}
