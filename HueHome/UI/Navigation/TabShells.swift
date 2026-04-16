// TabShells.swift
// HueHome Pro — Stage 1
// Placeholder NavigationStack shells for tabs 2–5.
// Each will be filled out in their respective stages.

import SwiftUI

// MARK: - Scenes Tab

struct ScenesTabView: View {
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        ZStack {
            (colorScheme == .dark ? HuePalette.Noir.background : HuePalette.Estate.background)
                .ignoresSafeArea()

            VStack(spacing: HueSpacing.xxl) {
                Image(systemName: "sparkles")
                    .font(.system(size: 48))
                    .foregroundStyle(HuePalette.amber.opacity(0.6))

                Text("Scenes")
                    .font(HueFont.displayMedium)
                    .foregroundStyle(
                        colorScheme == .dark
                            ? HuePalette.Noir.textPrimary
                            : HuePalette.Estate.textPrimary
                    )

                Text("Full scene manager coming in Stage 2")
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
        .navigationTitle("Scenes")
        .navigationBarTitleDisplayMode(.large)
    }
}

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
