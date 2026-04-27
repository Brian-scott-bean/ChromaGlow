// TabShells.swift
// HueHome Pro — Stage 1
// Placeholder shells for tabs 3–5 (Automations, Devices, Settings).
// Scenes tab moved to UI/Scenes/ScenesTabView.swift (Stage 2B).

import SwiftUI

// MARK: - Automations Tab

struct AutomationsTabView: View {
    var body: some View {
        // AutomationsView reads @Environment(UnifiedOrchestrator.self) itself —
        // same pattern as ScenesTabView. No wrapper needed.
        AutomationsView()
    }
}

// MARK: - Devices Tab

struct DevicesTabView: View {
    var body: some View {
        DevicesView()
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
