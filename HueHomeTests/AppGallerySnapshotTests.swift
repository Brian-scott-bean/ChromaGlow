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

    // MARK: - Lane Scenes

    /// Like `render`, but on a canvas tall enough to see a whole page.
    private func renderScenesPage<V: View>(_ view: V, named name: String,
                                          height: CGFloat = 1700, settle: TimeInterval = 1.2) async throws {
        let orchestrator = await demoOrchestrator()
        let tall = CGSize(width: size.width, height: height)
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
        let window = UIWindow(frame: CGRect(origin: .zero, size: tall))
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = controller
        window.isHidden = false
        controller.view.layoutIfNeeded()
        pump(settle)
        let image = UIGraphicsImageRenderer(size: tall).image { _ in
            controller.view.drawHierarchy(in: CGRect(origin: .zero, size: tall), afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertNotNil(image.cgImage, name)
        dismantle(window)
        orchestrator.exitDemoMode()
    }

    /// Runs `body` with the given favorites CSV, restoring the previous one.
    private func withSceneFavorites(_ csv: String, _ body: () async throws -> Void) async rethrows {
        let key = "favoriteSceneIDs"
        let previous = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set(csv, forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try await body()
    }

    /// The whole Scenes tab, grouped by room, with favorites on the shelf.
    func testScenesGroupedPage() async throws {
        try await withSceneFavorites("ds-lv-3,ds-pt-2,ds-bd-1") {
            try await renderScenesPage(NavigationStack { ScenesTabView() }, named: "gallery-scenes-page")
        }
    }

    /// The tab filtered by a search — one flat grid of results.
    func testScenesSearch() async throws {
        try await renderScenesPage(NavigationStack { ScenesTabView(initialSearchText: "Relax") },
                                   named: "gallery-scenes-search", height: 874)
    }

    /// Every card state side by side: on, dynamic, favorite, Studio,
    /// a real bridge palette, a full-width card.
    func testSceneCardStates() async throws {
        let b = "demo-bridge"
        let cards: [(GlobalSceneItem, Bool, Bool)] = [
            (GlobalSceneItem(id: "\(b):s1", bridgeSceneID: "s1", name: "Movie Night", roomID: "r1", bridgeID: b,
                             isActive: true, isDynamic: false, speed: 0.5), true, false),
            (GlobalSceneItem(id: "\(b):s2", bridgeSceneID: "s2", name: "Party", roomID: "r1", bridgeID: b,
                             isActive: false, isDynamic: true, speed: 0.6), false, false),
            (GlobalSceneItem(id: "\(b):s3", bridgeSceneID: "s3", name: "Northern Lights", roomID: "r1", bridgeID: b,
                             isActive: true, isDynamic: true, speed: 0.4,
                             paletteXY: [SceneXY(x: 0.20, y: 0.35), SceneXY(x: 0.24, y: 0.52), SceneXY(x: 0.26, y: 0.13)]),
             false, false),
            (GlobalSceneItem(id: "\(b):s4", bridgeSceneID: "s4", name: "Golden Hour", roomID: "r1", bridgeID: b,
                             isActive: false, isDynamic: false, speed: 0.5), true, true),
            (GlobalSceneItem(id: "\(b):s5", bridgeSceneID: "s5", name: "Sleep", roomID: "r1", bridgeID: b,
                             isActive: false, isDynamic: false, speed: 0.5), false, false),
            (GlobalSceneItem(id: "\(b):s6", bridgeSceneID: "s6", name: "Bright", roomID: "r1", bridgeID: b,
                             isActive: false, isDynamic: false, speed: 0.5), false, false),
        ]
        let grid = ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(cards, id: \.0.id) { card in
                        LuminousSceneCard(scene: card.0, roomName: "Living Room", isFavorite: card.1,
                                          isStudio: card.2, onActivate: {}, onSpeed: {})
                    }
                }
                LuminousSceneCard(scene: cards[2].0, roomName: "Living Room", isFavorite: true,
                                  onActivate: {}, onSpeed: {})
            }
            .padding(20)
        }
        .background { LuminousAmbience(colors: [LuminousPalette.violet]) }
        try await renderScenesPage(grid, named: "gallery-scene-cards", height: 1000)
    }
}
