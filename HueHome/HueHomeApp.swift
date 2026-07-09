// HueHomeApp.swift
// CastChroma — Stage 1 + Stage 2A Foundation
// Entry point: SwiftData container, UnifiedOrchestrator environment injection, auth gate.

import SwiftUI
import SwiftData
import WatchConnectivity

@main
struct HueHomeApp: App {

    // Register AppDelegate so UNUserNotificationCenterDelegate is set at launch.
    // Required for automation notifications to actually execute light changes.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // NOTE: WCSession activation moved to AppRootView's .task (post-first-frame).
    // It used to run here in init(), stacking an XPC handshake onto the same
    // pre-frame window as the ModelContainer creation. push() guards on
    // activationState == .activated, and the first widget/watch push happens
    // ≥500ms after the first loadAll — far after the .task activates the session.

    // MARK: SwiftData Container (includes BridgeRecord from Stage 2A)
    let modelContainer: ModelContainer = {
        StartupTimeline.mark("app-init.begin")
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

        // SwiftData's store already lives in the App Group container: Core
        // Data's defaultDirectoryURL() resolves there whenever an application-
        // group entitlement is present (HueHome.entitlements declares
        // group.com.huehome.pro). On a fresh container the
        // "Library/Application Support" subfolder doesn't exist yet, so the
        // first launch logs a wall of "Failed to create file / NSCocoaError
        // 512 / errno 2" before Core Data self-recovers. Pre-create that
        // directory and pin the store to its EXACT existing path
        // (default.store) — the noise is gone and no data moves.
        let appGroupID = "group.com.huehome.pro"
        let fm = FileManager.default
        let storeURL: URL = {
            if let container = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
                let dir = container.appendingPathComponent("Library/Application Support", isDirectory: true)
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                return dir.appendingPathComponent("default.store")
            }
            // Fallback: mirror Core Data's own default location if the App
            // Group container is somehow unavailable at launch.
            return URL.applicationSupportDirectory.appendingPathComponent("default.store")
        }()

        let config = ModelConfiguration(schema: schema, url: storeURL)
        do {
            let container = try ModelContainer(for: schema, configurations: [config])
            StartupTimeline.mark("modelcontainer.done")
            return container
        } catch {
            fatalError("HueHome: SwiftData container failed to initialize: \(error)")
        }
    }()

    // MARK: Stage 2A — UnifiedOrchestrator (shared across entire app)
    @State private var orchestrator = UnifiedOrchestrator()
    @State private var deepLink = DeepLinkCoordinator()

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environment(orchestrator)
                .environment(deepLink)
                .onOpenURL { url in deepLink.handle(url) }
        }
        .modelContainer(modelContainer)
    }
}

// MARK: - Deep Link Coordinator
//
// Widgets / Lock-Screen taps open `lightshade://room/{id}`, `lightshade://zone/{id}`,
// or `lightshade://dashboard`. The tab shell (MainTabView) observes `openToken`,
// switches to Home, and pushes `pendingGroupID`'s room detail — clearing the id once
// consumed. On a cold launch the id outlives the first frame: no group resolves until
// `loadAll` returns, so MainTabView retries when the rooms/zones arrive.

@Observable
final class DeepLinkCoordinator {
    /// The room/zone id from the tapped widget (nil for a plain dashboard open).
    var pendingGroupID: String?
    /// Bumped on every deep link so observers can react even to a repeated target.
    var openToken: Int = 0

    func handle(_ url: URL) {
        guard url.scheme == "lightshade" else { return }
        switch url.host {
        case "room", "zone":
            pendingGroupID = url.pathComponents.first(where: { $0 != "/" })
        default:
            pendingGroupID = nil
        }
        openToken &+= 1
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
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if isPaired || isDemoMode {
                MainTabView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .task {
                        if isDemoMode {
                            orchestrator.enterDemoMode()
                        } else {
                            StartupTimeline.mark("tabs.task.begin", "bridges=\(bridges.count)")
                            orchestrator.configure(bridges: bridges, modelContext: modelContext)
                            StartupTimeline.mark("configure.done")
                            let cachedRooms = (try? modelContext.fetch(FetchDescriptor<HueLocalRoom>())) ?? []
                            orchestrator.preloadCached(from: cachedRooms)
                            StartupTimeline.mark("preload.done", "cachedRooms=\(cachedRooms.count)")
                            await orchestrator.loadAll(cacheContext: modelContext)
                            StartupTimeline.mark("loadAll.returned")
                            orchestrator.startSSE()
                            orchestrator.startAllDayScenesIfNeeded()
                            StartupTimeline.mark("sse.start")

                            // ── Pending automation (cold-start: user tapped notification) ──
                            if let presetID = UserDefaults.standard.string(forKey: "pendingAutomationPresetID") {
                                UserDefaults.standard.removeObject(forKey: "pendingAutomationPresetID")
                                await orchestrator.applyAutomationPreset(id: presetID)
                            }
                            if let effectID = UserDefaults.standard.string(forKey: "pendingAutomationEffectID") {
                                UserDefaults.standard.removeObject(forKey: "pendingAutomationEffectID")
                                await orchestrator.applyAutomationEffect(id: effectID)
                            }
                        }
                    }
                    // ── Foreground automation (notification arrived while app was open) ──
                    .onReceive(NotificationCenter.default.publisher(for: .automationShouldExecute)) { note in
                        let actionType = note.userInfo?["actionType"] as? String ?? "preset"
                        if actionType == "effect",
                           let effectID = note.userInfo?["effectID"] as? String {
                            Task { await orchestrator.applyAutomationEffect(id: effectID) }
                        } else if let presetID = note.userInfo?["presetID"] as? String {
                            Task { await orchestrator.applyAutomationPreset(id: presetID) }
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
                    // ── Background automation drain ──────────────────────────────────
                    // willPresent only fires when app is foregrounded at trigger time.
                    // If the app was backgrounded, the notification fires silently.
                    // When the user opens the app again, scenePhase hits .active here
                    // and we drain whatever UserDefaults stored from didReceive.
                    .onChange(of: scenePhase) { _, newPhase in
                        guard newPhase == .active, isPaired, !isDemoMode else { return }
                        if let presetID = UserDefaults.standard.string(forKey: "pendingAutomationPresetID") {
                            UserDefaults.standard.removeObject(forKey: "pendingAutomationPresetID")
                            Task { await orchestrator.applyAutomationPreset(id: presetID) }
                        }
                        if let effectID = UserDefaults.standard.string(forKey: "pendingAutomationEffectID") {
                            UserDefaults.standard.removeObject(forKey: "pendingAutomationEffectID")
                            Task { await orchestrator.applyAutomationEffect(id: effectID) }
                        }
                    }
            } else {
                SplashView(
                    onPaired:  { isPaired   = true },
                    onDemo:    { isDemoMode = true }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            StartupTimeline.mark("first-frame")
            let hasNewStyle = !bridges.isEmpty
            let hasLegacy   = (try? KeychainManager.shared.loadAPIToken()) != nil
            isPaired = hasNewStyle || hasLegacy
            StartupTimeline.mark(
                "pairing-gate",
                isPaired ? "paired via \(hasNewStyle ? "bridge-records(\(bridges.count))" : "legacy-keychain")" : "unpaired"
            )
        }
        // Activate WCSession after the first frame (was in App.init, blocking launch).
        .task { _ = WatchSessionManager.shared }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let hueBridgeUnpaired  = Notification.Name("hueBridgeUnpaired")
    static let hueDemoExited      = Notification.Name("hueDemoExited")
    static let studioStopAll      = Notification.Name("studioStopAll")
    // NOTE (Phase 2): composerMicExclusiveBegan removed — capture is unified
    // in AudioAnalysisEngine, so there is no session handoff to coordinate.
    /// Mic capture unavailable (denied / hardware error) — posted by AudioAnalysisEngine.
    static let compositionMicPermissionDenied = Notification.Name("compositionMicPermissionDenied")
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

    func push(
        rooms: [WidgetRoomSnapshot],
        zones: [WidgetRoomSnapshot],
        scenes: [WidgetSceneSnapshot] = [],
        bridges: [String: WidgetBridgeCredentials],
        unpaired: Bool = false
    ) {
        guard WCSession.default.activationState == .activated,
              WCSession.default.isPaired,
              WCSession.default.isWatchAppInstalled else { return }
        guard let roomsData = try? JSONEncoder().encode(rooms),
              let zonesData = try? JSONEncoder().encode(zones),
              let scenesData = try? JSONEncoder().encode(scenes),
              let bridgesData = try? JSONEncoder().encode(bridges) else { return }
        let fallback = bridges.values.first
        // The token travels only inside wc_bridges_v1 (persisted to the watch
        // Keychain, D-018); the raw wc_token legacy key is gone so no watch
        // build can land it in UserDefaults again. Forget-all is signalled by
        // the EXPLICIT wc_unpaired flag — never inferred from an empty map,
        // which is indistinguishable from a transient Keychain read failure.
        var context: [String: Any] = [
            "wc_rooms_v1" : roomsData,
            "wc_zones_v1" : zonesData,
            "wc_scenes_v1": scenesData,
            "wc_bridges_v1": bridgesData,
            "wc_bridge_ip": fallback?.ip ?? "",
            "wc_unpaired" : unpaired
        ]
        // Bridge TLS pins ride along with credentials (D-016) so the watch's
        // pinned trust delegate can validate its direct bridge connections.
        if let pinsData = BridgePinStore.shared.encodedPins() {
            context[BridgePinStore.storageKey] = pinsData
        }
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
