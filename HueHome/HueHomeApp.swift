// HueHomeApp.swift
// HueHome Pro — Stage 1 Foundation
// Entry point with SwiftData container, @Observable env, and 5-tab navigation.

import SwiftUI
import SwiftData

@main
struct HueHomeApp: App {

    // MARK: SwiftData Container
    let modelContainer: ModelContainer = {
        let schema = Schema([
            HueLocalRoom.self,
            HueLocalScene.self,
            EffectPreset.self,
            FavouriteColor.self,
            ActivityEvent.self,
            EnergySnapshot.self,
            AppSettings.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("HueHome: SwiftData container failed to initialize: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            AppRootView()
        }
        .modelContainer(modelContainer)
    }
}

// MARK: - App Root (auth gate)

/// Shows SplashView/BridgeSetup until credentials exist, then MainTabView.
struct AppRootView: View {
    @State private var isPaired: Bool = (try? KeychainManager.shared.loadAPIToken()) != nil

    var body: some View {
        if isPaired {
            MainTabView()
                .onReceive(NotificationCenter.default.publisher(for: .hueBridgeUnpaired)) { _ in
                    isPaired = false
                }
        } else {
            SplashView(onPaired: { isPaired = true })
        }
    }
}

extension Notification.Name {
    static let hueBridgeUnpaired = Notification.Name("hueBridgeUnpaired")
}

