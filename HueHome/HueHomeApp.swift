// HueHomeApp.swift
// HueHome Pro — Stage 1 + Stage 2A Foundation
// Entry point: SwiftData container, UnifiedOrchestrator environment injection, auth gate.

import SwiftUI
import SwiftData
import WatchConnectivity

@main
struct HueHomeApp: App {

    // Register AppDelegate so UNUserNotificationCenterDelegate is set at launch.
    // Required for automation notifications to actually execute light changes.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

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
                            orchestrator.enterDemoMode()
                        } else {
                            orchestrator.configure(bridges: bridges, modelContext: modelContext)
                            let cachedRooms = (try? modelContext.fetch(FetchDescriptor<HueLocalRoom>())) ?? []
                            orchestrator.preloadCached(from: cachedRooms)
                            await orchestrator.loadAll(cacheContext: modelContext)
                            orchestrator.startSSE()

                            // ── Pending automation (cold-start: user tapped notification) ──
                            if let presetID = UserDefaults.standard.string(forKey: "pendingAutomationPresetID") {
                                UserDefaults.standard.removeObject(forKey: "pendingAutomationPresetID")
                                await orchestrator.applyAutomationPreset(id: presetID)
                            }
                        }
                    }
                    // ── Foreground automation (notification arrived while app was open) ──
                    .onReceive(NotificationCenter.default.publisher(for: .automationShouldExecute)) { note in
                        guard let presetID = note.userInfo?["presetID"] as? String else { return }
                        Task { await orchestrator.applyAutomationPreset(id: presetID) }
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

// MARK: - WatchSessionManager
// Inlined here so it compiles as part of the HueHome target without requiring
// a manual Xcode "Add Files" step.

import WatchConnectivity

final class WatchSessionManager: NSObject, WCSessionDelegate, @unchecked Sendable {

    static let shared = WatchSessionManager()

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    // MARK: - Push to Watch

    func push(rooms: [WidgetRoomSnapshot], zones: [WidgetRoomSnapshot], ip: String, token: String) {
        guard WCSession.default.activationState == .activated,
              WCSession.default.isPaired,
              WCSession.default.isWatchAppInstalled else { return }
        guard let roomsData = try? JSONEncoder().encode(rooms),
              let zonesData = try? JSONEncoder().encode(zones) else { return }
        let context: [String: Any] = [
            "wc_rooms_v1" : roomsData,
            "wc_zones_v1" : zonesData,
            "wc_bridge_ip": ip,
            "wc_token"    : token
        ]
        try? WCSession.default.updateApplicationContext(context)
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {}

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }
}
