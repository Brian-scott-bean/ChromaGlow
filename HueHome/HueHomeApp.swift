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
            GuestProfile.self,     // Family Sharing: owner-side profiles (additive)
            GuestAccessGrant.self, // Family Sharing: guest-side grants (additive)
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
    @State private var deepLink = DeepLinkCoordinator.shared
    @State private var music = MusicSessionCoordinator.shared

    init() {
        // Compositions saved/renamed/deleted → re-donate so Siri's
        // "Start <composition>" phrases track the library. Wired here (not
        // in CompositionStore) so unit tests with injected stores never
        // trigger system donation calls.
        //
        // Two donation funnels by design, NO extra rate limit: this one fires
        // only on explicit preset saves, and scheduleWidgetWrite's donation
        // already rides its 500ms debounce. A throttle here risks eating the
        // trailing donation after a rename — the exact freshness bug 282fbef
        // fixed.
        CompositionStore.onPersist = {
            HueAppShortcuts.updateAppShortcutParameters()
        }
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environment(orchestrator)
                .environment(deepLink)
                .environment(music)
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
//
// Shared scenes arrive as `lightshade://share?d=<blob>` (see ScenePayloadCodec).
// They are decoded here but never saved here — `pendingSharedScene` is a
// proposal that MainTabView shows the user, who accepts or declines. A link that
// cannot be decoded surfaces as `pendingShareError` rather than vanishing.

@Observable
@MainActor
final class DeepLinkCoordinator {
    /// One instance app-wide. Open-app Siri intents run in-process AFTER the
    /// app foregrounds, so they hand Studio their action through this shared
    /// coordinator rather than a URL round-trip. @MainActor: every consumer
    /// (onOpenURL, view bodies, and both Siri perform()s, which are already
    /// @MainActor) runs on the main actor — the annotation makes the shared
    /// mutable state provably single-threaded.
    static let shared = DeepLinkCoordinator()

    /// True while the Welcome Tour's fullScreenCover is on screen (mirrored
    /// by WelcomeTourWiring). A deep link arriving mid-tour dismisses the
    /// tour and MainTabView delays its routing one beat past the dismissal
    /// animation — presenting a sheet from a hierarchy whose cover is still
    /// animating away is the silently-dropped-presentation class.
    var tourSurfaceUp = false

    /// The room/zone id from the tapped widget (nil for a plain dashboard open).
    var pendingGroupID: String?
    /// A scene decoded from a share link, awaiting the user's confirmation.
    var pendingSharedScene: SharedScene?
    /// Why the last share link could not be opened. Shown, then cleared.
    var pendingShareError: ScenePayloadError?
    /// A decoded home-join invite awaiting its join flow (MainTabView when
    /// paired; BridgeSetup during onboarding). Decode-only, like scenes —
    /// the accept (pairing + registrar) lives in JoinSharedHomeView.
    var pendingInvite: HomeJoinPayload?
    /// A decoded token-bearing guest invite (kind "invite", Phase 2).
    /// Decode-only — the accept (identity gate + token probe + registrar +
    /// grant) lives in GuestInviteAcceptor/GuestInviteAcceptView.
    var pendingGuestInvite: GuestInvitePayload?
    /// Why the last invite link could not be opened. Shown, then cleared.
    /// Shared by both invite kinds.
    var pendingInviteError: InvitePayloadError?
    /// A Siri "start this in that room" awaiting Studio's drain.
    var pendingStudioAction: PendingStudioAction?
    /// Bumped on every deep link so observers can react even to a repeated target.
    var openToken: Int = 0

    /// True when a cold-start deep link is waiting for a route — the Welcome
    /// Tour must not present on top of a widget/Siri/invite launch.
    var hasPendingRoute: Bool {
        pendingGroupID != nil || pendingSharedScene != nil || pendingShareError != nil
            || pendingInvite != nil || pendingGuestInvite != nil
            || pendingInviteError != nil || pendingStudioAction != nil
    }

    /// Entry point for the open-app Siri intents (StartComposition/Effect).
    func requestStudioAction(_ action: PendingStudioAction) {
        pendingStudioAction = action
        openToken += 1
    }

    func handle(_ url: URL) {
        guard url.scheme == "lightshade" else { return }

        if ScenePayloadCodec.isShareLink(url) {
            // One URL host, many kinds (the envelope's design): probe the
            // kind so an invite never lands in Studio's scene-import flow.
            switch try? ScenePayloadCodec.probeKind(url).kind {
            case InvitePayloadCodec.homeJoinKind:
                acceptInviteLink(url)
            case InvitePayloadCodec.inviteKind:
                acceptGuestInviteLink(url)
            default:
                acceptShareLink(url)
            }
            openToken &+= 1
            return
        }

        switch url.host {
        case "room", "zone":
            pendingGroupID = url.pathComponents.first(where: { $0 != "/" })
        default:
            pendingGroupID = nil
        }
        openToken &+= 1
    }

    /// Also the entry point for a QR scanned in-app, which produces the same URL.
    ///
    /// LOAD-BEARING: this deliberately does NOT bump `openToken`. The in-app
    /// scanner calls it while its own sheet is still presented; if the token
    /// changed, StudioView's `.onChange(of: openToken)` would try to present
    /// the import sheet on top of the scanner and SwiftUI would drop it. The
    /// scanner drains via its `onDismiss` instead. External URLs get their
    /// token bump from `handle(_:)`, which wraps this.
    func acceptShareLink(_ url: URL) {
        pendingGroupID = nil
        do {
            pendingSharedScene = try ScenePayloadCodec.decode(url)
            pendingShareError = nil
        } catch let error as ScenePayloadError {
            pendingSharedScene = nil
            pendingShareError = error
        } catch {
            pendingSharedScene = nil
            pendingShareError = .malformedPayload
        }
    }

    func clearShare() {
        pendingSharedScene = nil
        pendingShareError = nil
    }

    /// Decode-only, mirroring acceptShareLink (and its token rule: the in-app
    /// scanner calls this while its sheet is presented, so no token bump here
    /// — external URLs get theirs from handle(_:)). The accept/save is the
    /// join flow's: pairing + BridgePairingRegistrar, never the coordinator.
    func acceptInviteLink(_ url: URL) {
        pendingGroupID = nil
        do {
            pendingInvite = try InvitePayloadCodec.decode(url)
            pendingInviteError = nil
        } catch let error as InvitePayloadError {
            pendingInvite = nil
            pendingInviteError = error
        } catch {
            pendingInvite = nil
            pendingInviteError = .malformedPayload
        }
    }

    /// Decode-only, same token rule as acceptInviteLink. The one secret-
    /// bearing payload kind: decoded into memory for the accept flow, never
    /// logged, never persisted here.
    func acceptGuestInviteLink(_ url: URL) {
        pendingGroupID = nil
        do {
            pendingGuestInvite = try InvitePayloadCodec.decodeInvite(url)
            pendingInviteError = nil
        } catch let error as InvitePayloadError {
            pendingGuestInvite = nil
            pendingInviteError = error
        } catch {
            pendingGuestInvite = nil
            pendingInviteError = .malformedPayload
        }
    }

    /// Scanner entry for BOTH invite kinds ("Join a Shared Home" accepts a
    /// home-join or a token invite; the scene scanner stays separate). A
    /// scene link scanned here surfaces the home-join decoder's honest
    /// refusal via pendingInviteError.
    func acceptEitherInviteLink(_ url: URL) {
        if (try? ScenePayloadCodec.probeKind(url).kind) == InvitePayloadCodec.inviteKind {
            acceptGuestInviteLink(url)
        } else {
            acceptInviteLink(url)
        }
    }

    func clearInvite() {
        pendingInvite = nil
        pendingGuestInvite = nil
        pendingInviteError = nil
    }
}

// MARK: - App Root (auth gate)

/// Shows SplashView/BridgeSetup until credentials exist, then MainTabView.
/// On Stage 2A: first launch after update triggers legacy credential migration.
@MainActor
struct AppRootView: View {
    @Environment(\.modelContext)          private var modelContext
    @Environment(UnifiedOrchestrator.self) private var orchestrator
    @Environment(MusicSessionCoordinator.self) private var music
    @Query private var bridges: [BridgeRecord]

    @State private var isPaired:    Bool = false
    @State private var isDemoMode:  Bool = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if isPaired || isDemoMode {
                MainTabView()
                    .modifier(WelcomeTourWiring())
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

                            // Re-register every enabled automation's local
                            // notifications: pending requests don't survive a
                            // restore/new-phone migration, and ones scheduled
                            // while permission was denied were silently dead
                            // even after the user granted it in Settings.
                            // Same-identifier adds replace — idempotent.
                            let appAutomations = (try? modelContext.fetch(
                                FetchDescriptor<AppAutomation>())) ?? []
                            AutomationScheduler.shared.scheduleAll(appAutomations)

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
                    // ── Siri "stop the lights" (app alive) ───────────────────────────
                    // Route through the shared registry so the owning engine
                    // loop tears down and Studio's mirror stays in sync — a
                    // bare stopStudioMode/stopCompositionMode here would leave
                    // loops running (the b20f0ef bug class).
                    .onReceive(NotificationCenter.default.publisher(for: .siriStopAllEffects)) { _ in
                        Task {
                            for entry in orchestrator.activeEffectEntries {
                                // turnOffLights: false — the Siri shortcut promises
                                // "lights stay on at their current state".
                                await orchestrator.requestNowPlayingStop(entry,
                                                                         turnOffLights: false)
                            }
                        }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .hueBridgeUnpaired)) { _ in
                        // Music has no other teardown hook here — without
                        // this, a Shazam session kept the mic hot on the
                        // pairing splash with no reachable UI to stop it.
                        music.deactivate()
                        orchestrator.stopSSE()
                        orchestrator.exitDemoMode()
                        isPaired   = false
                        isDemoMode = false
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .hueDemoExited)) { _ in
                        // Sample Track must not leak into real mode — a
                        // phantom 96–128 BPM playlist grid suppresses the
                        // mic for every .beat look on real lights.
                        if music.activeService == .demo { music.deactivate() }
                        orchestrator.exitDemoMode()
                        isDemoMode = false
                        // exitDemoMode wipes clients/rooms/SSE, and the
                        // MainTabView .task won't re-fire (view identity
                        // unchanged while isPaired stays true) — rebuild, or
                        // "Resume real bridge" hands back a dead app until
                        // relaunch.
                        if isPaired {
                            Task {
                                orchestrator.configure(bridges: bridges, modelContext: modelContext)
                                await orchestrator.loadAll(cacheContext: modelContext)
                                orchestrator.startSSE()
                                orchestrator.startAllDayScenesIfNeeded()
                            }
                        }
                    }
                    // ── Background automation drain ──────────────────────────────────
                    // willPresent only fires when app is foregrounded at trigger time.
                    // If the app was backgrounded, the notification fires silently.
                    // When the user opens the app again, scenePhase hits .active here
                    // and we drain whatever UserDefaults stored from didReceive.
                    .onChange(of: scenePhase) { _, newPhase in
                        guard newPhase == .active, isPaired, !isDemoMode else { return }
                        // Coming back to the app is the most likely moment for
                        // the entertainment inventory to have changed behind our
                        // back — the user was just in the Hue app creating or
                        // deleting an area. Nothing here ever re-asked, so the
                        // stale verdict outlived the change (packet 7 follow-up).
                        orchestrator.refreshEntertainmentAvailability(reason: .userInitiated)
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
