// AppGallerySnapshotTests.swift
// ChromaGlow — v2.2 redesign. Renders every main surface of the real app in
// Demo Mode (rooms, scenes, Studio, More, Composer) into the result bundle,
// so each visual change can be reviewed as an image. Each render must also
// produce a non-blank picture. Export with
// `xcrun xcresulttool export attachments --path <bundle> --output-path <dir>`.

import XCTest
import SwiftUI
import SwiftData
@testable import HueHome

@MainActor
final class AppGallerySnapshotTests: XCTestCase {

    private let size = CGSize(width: 402, height: 874)

    private func demoOrchestrator() async -> UnifiedOrchestrator {
        let orchestrator = UnifiedOrchestrator()
        orchestrator.enterDemoMode()
        await orchestrator.loadAll()
        XCTAssertFalse(orchestrator.allRooms.isEmpty, "demo seed produced no rooms")
        return orchestrator
    }

    /// ONE in-memory container for every gallery screen, alive for the whole
    /// test process. SwiftUI's `@Query` leaves a SwiftData observer behind
    /// that outlives its view; when each render had its own container, that
    /// observer pointed at a freed container and the NEXT test's SwiftData
    /// save (any test, any class) trapped inside it.
    private static let sharedContainer: ModelContainer = {
        let schema = Schema([BridgeRecord.self, HueLocalRoom.self, HueLocalScene.self, EffectPreset.self,
                             FavouriteColor.self, ActivityEvent.self, EnergySnapshot.self, AppSettings.self,
                             AppAutomation.self, GuestProfile.self, GuestAccessGrant.self])
        do {
            return try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        } catch {
            fatalError("gallery container: \(error)")
        }
    }()

    private func container() throws -> ModelContainer { Self.sharedContainer }

    private func host<V: View>(_ view: V, orchestrator: UnifiedOrchestrator) throws -> (UIWindow, UIHostingController<AnyView>) {
        let root = AnyView(
            view
                .environment(orchestrator)
                .environment(DeepLinkCoordinator())
                .environment(MusicSessionCoordinator.shared)
                .modelContainer(try container())
                .preferredColorScheme(.dark)
        )
        let controller = UIHostingController(rootView: root)
        controller.overrideUserInterfaceStyle = .dark
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = controller
        window.isHidden = false
        controller.view.layoutIfNeeded()
        return (window, controller)
    }

    /// Take a hosted screen fully down before the test ends. A hidden window
    /// that keeps its root alive leaves SwiftUI `@Query` observers running in
    /// this test process; a later test's SwiftData save then reached them and
    /// trapped (seen once in a full-suite run).
    private func dismantle(_ window: UIWindow) {
        window.rootViewController = nil
        window.isHidden = true
        pump(0.2)
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func capture(_ controller: UIHostingController<AnyView>, named name: String) {
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            controller.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertNotNil(image.cgImage, name)
    }

    private func render<V: View>(_ view: V, named name: String, settle: TimeInterval = 1.2) async throws {
        let orchestrator = await demoOrchestrator()
        let (window, controller) = try host(view, orchestrator: orchestrator)
        pump(settle)
        capture(controller, named: name)
        dismantle(window)
        orchestrator.exitDemoMode()
    }

    func testHome() async throws {
        try await render(MainTabView(), named: "gallery-home")
    }

    func testScenes() async throws {
        try await render(NavigationStack { ScenesTabView() }, named: "gallery-scenes")
    }

    func testStudio() async throws {
        try await render(StudioView(), named: "gallery-studio", settle: 2)
    }

    func testMore() async throws {
        try await render(NavigationStack { MoreView() }, named: "gallery-more")
    }

    /// The Composer tab's front page: the live library.
    func testComposerLibrary() async throws {
        try await render(NavigationStack { ComposerLibraryHome(onOpenStudioClassic: {}) },
                         named: "gallery-composer-library", settle: 1.5)
    }

    func testRoomDetail() async throws {
        let orchestrator = await demoOrchestrator()
        let room = try XCTUnwrap(orchestrator.allRooms.first)
        let (window, controller) = try host(NavigationStack { RoomDetailView(room: room) }, orchestrator: orchestrator)
        pump(3)
        capture(controller, named: "gallery-room-detail")
        dismantle(window)
        orchestrator.exitDemoMode()
    }

    func testComposer() async throws {
        let orchestrator = await demoOrchestrator()
        let room = orchestrator.allRooms.first
        for (mode, look) in [(Composer2Mode.looks, Composer2PresetLibrary.thunderstorm),
                             (.tune, Composer2PresetLibrary.passingStorm),
                             (.layers, Composer2PresetLibrary.jackOLantern)] {
            let (window, controller) = try host(Composer2View(room: room, composition: look, mode: mode),
                                                orchestrator: orchestrator)
            pump(1.5)
            capture(controller, named: "gallery-composer-\(mode.rawValue)")
            dismantle(window)
        }
        orchestrator.exitDemoMode()
    }

    // MARK: - Lead: onboarding & tour

    func testSplash() async throws {
        try await render(SplashView(), named: "gallery-splash", settle: 0.4)
    }

    func testBridgeSetup() async throws {
        try await render(BridgeSetupView(onPaired: {}, onDemo: {}), named: "gallery-bridge-setup", settle: 1.0)
    }

    func testWelcomeTour() async throws {
        try await render(WelcomeTourView(pages: TutorialCatalog.pages) {}, named: "gallery-welcome-tour", settle: 0.8)
    }

    func testTourComposerArt() async throws {
        let art = TutorialIllustrationView(kind: .studio, accent: Color(hex: "#668AFF"), isActive: false)
            .frame(height: 250)
            .luminousStageFrame()
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LuminousPalette.void)
        try await render(art, named: "gallery-tour-composer-art", settle: 0.4)
    }
}
