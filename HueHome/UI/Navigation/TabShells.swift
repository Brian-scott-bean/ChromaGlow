// TabShells.swift
// CastChroma — Navigation shells for tab-routed views.

import SwiftUI

// MARK: - Effects Tab

struct EffectsTabView: View {
    var body: some View {
        EffectsView()
    }
}

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
