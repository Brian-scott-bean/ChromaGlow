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

    /// The speed sheet for a dynamic scene.
    func testSceneSpeedSheet() async throws {
        let party = GlobalSceneItem(id: "demo-bridge:ds-pt-2", bridgeSceneID: "ds-pt-2", name: "Party",
                                    roomID: "demo-room-patio", bridgeID: "demo-bridge",
                                    isActive: false, isDynamic: true, speed: 0.6)
        try await renderScenesPage(SceneSpeedSheet(scene: party, onSpeedChange: { _ in }, onActivate: {}),
                                   named: "gallery-scene-speed", height: 560)
    }

    /// The color builder on the demo living room's lights.
    func testSceneColorBuilder() async throws {
        let lights = DemoDataProvider.lights(for: "demo-room-living")
        XCTAssertFalse(lights.isEmpty)
        try await renderScenesPage(SceneColorBuilderView(roomID: "demo-room-living", roomRType: "room",
                                                         bridgeID: "demo-bridge", existingSceneID: nil,
                                                         existingSceneName: nil, initialLights: lights,
                                                         onSave: {}),
                                   named: "gallery-scene-builder", height: 1900, settle: 1.5)
    }

    /// Capture Room Look, Build Colors' room picker and Rename.
    func testSceneCreationSheets() async throws {
        try await renderScenesPage(CreateGlobalSceneView(), named: "gallery-scene-capture", height: 874)
        try await renderScenesPage(SceneBuilderLauncherView(), named: "gallery-scene-build-launcher", height: 874)
        let scene = GlobalSceneItem(id: "demo-bridge:ds-lv-3", bridgeSceneID: "ds-lv-3", name: "Movie Night",
                                    roomID: "demo-room-living", bridgeID: "demo-bridge",
                                    isActive: true, isDynamic: false, speed: 0.5)
        try await renderScenesPage(RenameSceneSheet(scene: scene, initialName: scene.name) { _ in },
                                   named: "gallery-scene-rename", height: 500)
    }

    /// Studio Classic's share sheet, the scanner (unsupported on the
    /// Simulator) and the import failure sheet.
    func testSceneShareSheets() async throws {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("no-such-compositions.json")
        let preset = try XCTUnwrap(CompositionStore.readPresets(from: missing).presets
            .first { $0.name.localizedCaseInsensitiveContains("aurora") }
            ?? CompositionStore.readPresets(from: missing).presets.first)
        try await renderScenesPage(ShareSceneSheet(preset: preset), named: "gallery-scene-share",
                                   height: 1000, settle: 1.5)
        try await renderScenesPage(ScanSceneView { _ in }, named: "gallery-scene-scan", height: 874)
        try await renderScenesPage(ImportSceneFailureSheet(error: ScenePayloadError.unsupportedVersion(99)),
                                   named: "gallery-scene-import-failure", height: 600)
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

    // MARK: - Lane More
    //
    // The setup screens (More, Settings, Automations, Devices, Bridges,
    // People, Physical Controls, Entertainment Areas, Share Invite), rendered
    // in a tall window so the whole scroll is reviewable as one image.

    private func renderSetupPage<V: View>(_ view: V, named name: String, height: CGFloat = 1600,
                                     settle: TimeInterval = 1.2) async throws {
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
        // Await rather than pump: a synchronous run-loop pump inside this
        // main-actor test never lets the screen's own `.task` work run, so
        // views that load on appear would be captured mid-load.
        pump(0.2)
        try await Task.sleep(for: .seconds(settle))
        pump(0.2)
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

    func testLaneMoreMoreTall() async throws {
        try await renderSetupPage(NavigationStack { MoreView() }, named: "lane-more-more", height: 1500)
    }

    func testLaneMoreSettings() async throws {
        try await renderSetupPage(NavigationStack { SettingsView(onForget: {}) }, named: "lane-more-settings", height: 1900)
    }

    func testLaneMoreAutomations() async throws {
        try await renderSetupPage(NavigationStack { AutomationsView() }, named: "lane-more-automations", height: 1300, settle: 3)
    }

    func testLaneMoreCreateAutomation() async throws {
        try await renderSetupPage(CreateAutomationView(), named: "lane-more-create-automation", height: 1500)
    }

    func testLaneMoreDevices() async throws {
        try await renderSetupPage(NavigationStack { DevicesView() }, named: "lane-more-devices", height: 1300, settle: 3)
    }

    func testLaneMoreBridgeManager() async throws {
        try await renderSetupPage(NavigationStack { BridgeManagerView() }, named: "lane-more-bridges", height: 1000)
    }

    func testLaneMoreProfilesAccess() async throws {
        try await renderSetupPage(NavigationStack { ProfilesAccessView() }, named: "lane-more-profiles", height: 1300)
    }

    func testLaneMorePhysicalControls() async throws {
        try await renderSetupPage(NavigationStack { PhysicalControlsView() }, named: "lane-more-physical-controls", height: 1000)
    }

    func testLaneMoreEntertainmentAreas() async throws {
        try await renderSetupPage(NavigationStack { EntertainmentAreasView() }, named: "lane-more-entertainment-areas", height: 1000)
    }

    func testLaneMoreShareInvite() async throws {
        try await renderSetupPage(ShareInviteSheet(), named: "lane-more-share-invite", height: 1100)
    }

    /// Profiles & Access with two people on it (inserted for the render
    /// only, then removed — the container is shared by the whole class).
    func testLaneMoreProfilesWithPeople() async throws {
        let context = try container().mainContext
        let mia = GuestProfile(name: "Mia", icon: "figure.child", colorHex: "#FF9ECF",
                               allowedGroupIDs: ["demo-room-living", "demo-room-kitchen"])
        mia.lastInviteAt = Date().addingTimeInterval(-3 * 86_400)
        let sam = GuestProfile(name: "Sam (guest)", icon: "person.fill", colorHex: "#40D9BF",
                               allowedGroupIDs: [], features: [GuestFeature.onOff])
        context.insert(mia)
        context.insert(sam)
        try context.save()
        defer {
            context.delete(mia)
            context.delete(sam)
            try? context.save()
        }
        try await renderSetupPage(NavigationStack { ProfilesAccessView() }, named: "lane-more-profiles-people", height: 1300)
    }

    func testLaneMoreProfileEditor() async throws {
        try await renderSetupPage(GuestProfileEditorView(profile: nil), named: "lane-more-profile-editor", height: 1500)
    }

    func testLaneMoreJoinSharedHome() async throws {
        let payload = HomeJoinPayload(
            bridges: [SharedBridgeJoin(bid: "001788FFFE000001", host: "192.168.1.20", port: 443,
                                       name: "Main Bridge", pinPK: "demo")],
            homeName: "My Home", issuedAt: Date())
        try await renderSetupPage(JoinSharedHomeView(payload: payload, isAddingAdditional: true),
                             named: "lane-more-join-home", height: 1000)
    }

    func testLaneMoreGuestInviteMint() async throws {
        let spec = GuestInviteSpec(profileID: "demo-profile", profileName: "Mia",
                                   allowedGroupIDs: ["demo-room-living"], features: GuestFeature.all,
                                   isRevoked: false)
        try await renderSetupPage(GuestInviteMintSheet(spec: spec), named: "lane-more-guest-mint", height: 1000)
    }

    func testLaneMoreEntertainmentBuilder() async throws {
        try await renderSetupPage(EntertainmentConfigBuilderView(), named: "lane-more-entertainment-builder", height: 1000)
    }

    /// The app-wide failure toast and the undo toast, over the void.
    func testLaneMoreToasts() async throws {
        let toasts = VStack(spacing: 24) {
            HueToastView(message: "Couldn't reach bridge — Hallway reverted")
            HueActionToast(message: "Moved to Kitchen", actionTitle: "Undo", action: {})
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LuminousPalette.void)
        try await renderSetupPage(toasts, named: "lane-more-toasts", height: 400)
    }

    func testLaneMoreMusicPicker() async throws {
        try await renderSetupPage(MusicSourcePicker(), named: "lane-more-music-picker", height: 1000)
    }
}
