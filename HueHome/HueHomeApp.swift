// HueHomeApp.swift
// HueHome Pro — Stage 1 + Stage 2A Foundation
// Entry point: SwiftData container, UnifiedOrchestrator environment injection, auth gate.

import SwiftUI
import SwiftData

@main
struct HueHomeApp: App {

    // MARK: SwiftData Container (includes BridgeRecord from Stage 2A)
    let modelContainer: ModelContainer = {
        let schema = Schema([
            BridgeRecord.self,     // Stage 2A — multi-bridge registry
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

    // MARK: Stage 2A — UnifiedOrchestrator (shared across entire app)
    @State private var orchestrator = UnifiedOrchestrator()

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environment(orchestrator)
        }
        .modelContainer(modelContainer)
    }
}

// MARK: - App Root (auth gate)

/// Shows SplashView/BridgeSetup until credentials exist, then MainTabView.
/// On Stage 2A: first launch after update triggers legacy credential migration.
@MainActor
struct AppRootView: View {
    @Environment(\.modelContext)          private var modelContext
    @Environment(UnifiedOrchestrator.self) private var orchestrator
    @Query private var bridges: [BridgeRecord]

    @State private var isPaired: Bool = false

    var body: some View {
        Group {
            if isPaired {
                MainTabView()
                    .task {
                        // Configure orchestrator on every foreground entry
                        orchestrator.configure(bridges: bridges, modelContext: modelContext)
                        await orchestrator.loadAll()
                        orchestrator.startSSE()
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .hueBridgeUnpaired)) { _ in
                        orchestrator.stopSSE()
                        isPaired = false
                    }
            } else {
                SplashView(onPaired: { isPaired = true })
            }
        }
        .onAppear {
            // Determine if already paired:
            // 1. Have BridgeRecords with valid credentials, OR
            // 2. Have legacy single-bridge Keychain entry (will be migrated)
            let hasNewStyle = !bridges.isEmpty
            let hasLegacy   = (try? KeychainManager.shared.loadAPIToken()) != nil
            isPaired = hasNewStyle || hasLegacy
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let hueBridgeUnpaired = Notification.Name("hueBridgeUnpaired")
}
