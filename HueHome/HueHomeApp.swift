// HueHomeApp.swift
// HueHome Pro — Stage 1 + Stage 2A Foundation
// Entry point: SwiftData container, UnifiedOrchestrator environment injection, auth gate.

import SwiftUI
import SwiftData
import WatchConnectivity

@main
struct HueHomeApp: App {

    init() {
        // Activate WCSession early so the first room write can push to watch
        _ = WatchSessionManager.shared
    }

    // MARK: SwiftData Container (includes BridgeRecord from Stage 2A)
    let modelContainer: ModelContainer = {
        let schema = Schema([
            BridgeRecord.self,
            HueLocalRoom.self,
            HueLocalScene.self,
            EffectPreset.self,
            FavouriteColor.self,
            ActivityEvent.self,
            EnergySnapshot.self,
            AppSettings.self,
            AppAutomation.self,   // user-created scheduled automations
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

    @State private var isPaired:    Bool = false
    @State private var isDemoMode:  Bool = false

    var body: some View {
        Group {
            if isPaired || isDemoMode {
                MainTabView()
                    .task {
                        if isDemoMode {
                            // Demo: just load mock data, no real network
                            orchestrator.enterDemoMode()
                        } else {
                            orchestrator.configure(bridges: bridges, modelContext: modelContext)
                            // Show cached rooms instantly (including groupedLightID) so
                            // toggles work before the first network fetch completes.
                            let cachedRooms = (try? modelContext.fetch(FetchDescriptor<HueLocalRoom>())) ?? []
                            orchestrator.preloadCached(from: cachedRooms)
                            await orchestrator.loadAll(cacheContext: modelContext)
                            orchestrator.startSSE()
                        }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .hueBridgeUnpaired)) { _ in
                        orchestrator.stopSSE()
                        orchestrator.exitDemoMode()
                        isPaired   = false
                        isDemoMode = false
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .hueDemoExited)) { _ in
                        orchestrator.exitDemoMode()
                        isDemoMode = false
                    }
            } else {
                SplashView(
                    onPaired:  { isPaired   = true },
                    onDemo:    { isDemoMode = true }
                )
            }
        }
        .onAppear {
            let hasNewStyle = !bridges.isEmpty
            let hasLegacy   = (try? KeychainManager.shared.loadAPIToken()) != nil
            isPaired = hasNewStyle || hasLegacy
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let hueBridgeUnpaired = Notification.Name("hueBridgeUnpaired")
    static let hueDemoExited     = Notification.Name("hueDemoExited")
}
