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

    // MARK: - Lane Room

    /// Renders a screen taller than the phone, so a whole scrolling page can
    /// be reviewed in one image.
    /// Suspends (rather than pumping the run loop) so the screen's own
    /// main-actor `.task` work — a room loading its lights — actually runs.
    private func renderTall<V: View>(_ view: V, named name: String, height: CGFloat,
                                     orchestrator: UnifiedOrchestrator, settle: TimeInterval = 2) async throws {
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
        try await Task.sleep(for: .seconds(settle))
        pump(0.3)
        let image = UIGraphicsImageRenderer(size: tall).image { _ in
            controller.view.drawHierarchy(in: CGRect(origin: .zero, size: tall), afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertNotNil(image.cgImage, name)
        dismantle(window)
    }

    /// The Room page, each segment, on a lit room and on a dark one.
    func testRoomDetailSegments() async throws {
        let orchestrator = await demoOrchestrator()
        let living = try XCTUnwrap(orchestrator.allRooms.first { $0.id == "demo-room-living" })
        let bedroom = try XCTUnwrap(orchestrator.allRooms.first { $0.id == "demo-room-bedroom" })
        for segment in RoomDetailView.Segment.allCases {
            try await renderTall(NavigationStack { RoomDetailView(room: living, initialSegment: segment) },
                           named: "gallery-room-\(segment.rawValue)", height: 1500, orchestrator: orchestrator)
        }
        try await renderTall(NavigationStack { RoomDetailView(room: bedroom) },
                       named: "gallery-room-dark", height: 1200, orchestrator: orchestrator)
        orchestrator.exitDemoMode()
    }

    /// One light: a colour lamp and a white-only lamp.
    func testLightControl() async throws {
        let orchestrator = await demoOrchestrator()
        let colourLamp = try XCTUnwrap(DemoDataProvider.lights(for: "demo-room-living").first { $0.name == "TV Backlight" })
        let whiteLamp = try XCTUnwrap(DemoDataProvider.lights(for: "demo-room-kitchen").first { $0.name == "Counter Strip" })
        try await renderTall(LightControlHarness(light: colourLamp), named: "gallery-light-colour",
                       height: 1500, orchestrator: orchestrator)
        try await renderTall(LightControlHarness(light: whiteLamp), named: "gallery-light-white",
                       height: 1100, orchestrator: orchestrator)
        orchestrator.exitDemoMode()
    }

    /// The long-press colour wash sheet.
    func testRoomColorPopover() async throws {
        let orchestrator = await demoOrchestrator()
        let room = try XCTUnwrap(orchestrator.allRooms.first)
        try await renderTall(RoomColorPopover(room: room), named: "gallery-room-color-wash",
                       height: 1100, orchestrator: orchestrator, settle: 1)
        orchestrator.exitDemoMode()
    }

    /// The edit sheet and the two selection docks.
    func testRoomSheetsAndDocks() async throws {
        let orchestrator = await demoOrchestrator()
        let room = try XCTUnwrap(orchestrator.allRooms.first { $0.id == "demo-room-living" })
        try await renderTall(EditRoomSheet(room: room, isZone: false) { _, _ in },
                             named: "gallery-room-edit", height: 1100, orchestrator: orchestrator, settle: 1)
        let vm = RoomDetailViewModel(room: room, isDemoMode: true,
                                     initialLights: DemoDataProvider.lights(for: room.id))
        vm.scenes = DemoDataProvider.scenes(for: room.id)
        vm.enterSelectMode(preselecting: vm.lights.first?.id)
        vm.enterSceneSelectMode()
        if let first = vm.scenes.first { vm.toggleSceneSelection(id: first.id) }
        try await renderTall(VStack(spacing: 12) {
                                 Spacer()
                                 BulkActionBar(vm: vm) {}
                                 SceneEditBar(vm: vm) { _ in }
                             }
                             .padding(.bottom, 24)
                             .background { LuminousAmbience(colors: [LuminousPalette.amber]) },
                             named: "gallery-room-docks", height: 600, orchestrator: orchestrator, settle: 1)
        orchestrator.exitDemoMode()
    }

    /// Hosts LightControlView with a local binding (its host owns the writes).
    private struct LightControlHarness: View {
        @State var light: LightDisplayItem

        var body: some View {
            NavigationStack {
                LightControlView(light: $light,
                                 onToggle: { light.isOn = $0 },
                                 onBrightness: { light.brightness = $0 },
                                 onColor: { x, y in light.colorX = x; light.colorY = y; light.colorTempMirek = nil },
                                 onColorTemp: { light.colorTempMirek = $0 },
                                 onIdentify: {})
            }
        }
    }
}
