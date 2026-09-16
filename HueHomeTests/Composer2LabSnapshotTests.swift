// Composer2LabSnapshotTests.swift
// ChromaGlow — Composer 2 lab. Review renders of every major state, attached
// to the result bundle (export with `xcresulttool export attachments`).
// Same pattern as MusicUISnapshotTests: a UIHostingController at phone
// widths that must produce non-blank pixels.

import XCTest
import SwiftUI
@testable import HueHome

@MainActor
final class Composer2LabSnapshotTests: XCTestCase {

    private let widths: [CGFloat] = [393, 375]

    // MARK: Fixtures

    private func demoDocument(_ composition: Composer2Composition, mode: Composer2Mode = .customize) -> Composer2Document {
        let room = DemoDataProvider.rooms[0]
        let lights = DemoDataProvider.lights(for: room.id)
        var context = Composer2RoomContext(room: room)
        context.lights = lights
        context.layout = Composer2SlotLayout.estimated(lights: lights)
        context.isDemo = true
        context.connectionText = Composer2Copy.demoHome
        let doc = Composer2Document(composition: composition, roomContext: context)
        doc.mode = mode
        return doc
    }

    private func feed(for doc: Composer2Document) -> Composer2PreviewFeed {
        let output = Composer2LiveOutput(composition: doc.composition)
        output.setPreviewGeometry(doc.roomContext.layout.geometry)
        return Composer2PreviewFeed(output: output)
    }

    private func screen<Content: View>(_ doc: Composer2Document, center: Composer2PlaybackCenter,
                                       previewOn: Bool = true, @ViewBuilder mode: () -> Content) -> some View {
        let f = feed(for: doc)
        return ZStack {
            Composer2Theme.backgroundGradient.ignoresSafeArea()
            VStack(spacing: HueSpacing.lg) {
                Composer2Header(document: doc, center: center, rooms: DemoDataProvider.rooms,
                                onSelectRoom: { _ in }, onClose: {})
                Composer2HeroCard(document: doc, center: center, feed: f, previewOn: previewOn, onTapLights: {})
                Composer2TitleBlock(document: doc)
                Composer2ModeSelector(selection: .constant(doc.mode))
                mode()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, HueSpacing.screenH)
            .padding(.top, HueSpacing.md)
            .frame(maxHeight: .infinity, alignment: .top)
            .safeAreaInset(edge: .bottom) {
                Composer2PerformanceBar(document: doc, center: center, previewOn: .constant(previewOn),
                                        onLive: {}, onSave: {}, onApply: {}, onDismissNotice: {})
            }
        }
        .environment(UnifiedOrchestrator())
        .preferredColorScheme(.dark)
    }

    // MARK: Render helper

    private func render<V: View>(_ view: V, size: CGSize, named name: String) {
        let host = UIHostingController(rootView: view)
        host.view.bounds = CGRect(origin: .zero, size: size)
        host.overrideUserInterfaceStyle = .dark
        host.view.backgroundColor = UIColor(Composer2Theme.background)
        host.view.layoutIfNeeded()

        let image = UIGraphicsImageRenderer(size: size).image { _ in
            host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertGreaterThan(distinctSampleColors(of: image), 3, "\(name) rendered blank")
    }

    private func distinctSampleColors(of image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 0 }
        let w = 24, h = 24
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: srgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.interpolationQuality = .none
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return 0 }
        let buf = data.bindMemory(to: UInt32.self, capacity: w * h)
        var seen = Set<UInt32>()
        for i in 0..<(w * h) { seen.insert(buf[i]) }
        return seen.count
    }

    private func editorFrame<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        ZStack {
            Composer2Theme.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: HueSpacing.md) {
                Text(title).font(HueFont.displaySmall).foregroundStyle(Composer2Theme.ink)
                content()
                Spacer(minLength: 0)
            }
            .padding(HueSpacing.screenH)
        }
        .environment(UnifiedOrchestrator())
        .preferredColorScheme(.dark)
    }

    // MARK: Screens

    func testCustomizeModeRendersAtBothWidths() {
        for width in widths {
            let doc = demoDocument(Composer2PresetLibrary.auroraDrift)
            render(screen(doc, center: Composer2PlaybackCenter()) { Composer2CustomizeGrid(document: doc) },
                   size: CGSize(width: width, height: 1500), named: "composer2-customize-aurora-\(Int(width))")
        }
    }

    func testQuickModeRenders() {
        let doc = demoDocument(Composer2PresetLibrary.lavaLamp, mode: .quick)
        render(screen(doc, center: Composer2PlaybackCenter()) { Composer2QuickPanel(document: doc) },
               size: CGSize(width: 393, height: 1300), named: "composer2-quick-lava")
    }

    func testAdvancedModeRendersThunderstormLightning() {
        let doc = demoDocument(Composer2PresetLibrary.thunderstorm, mode: .advanced)
        doc.select(layerID: Composer2PresetLibrary.thunderstorm.layers[1].id)
        render(screen(doc, center: Composer2PlaybackCenter()) { Composer2AdvancedPanel(document: doc) },
               size: CGSize(width: 393, height: 2200), named: "composer2-advanced-thunderstorm")
    }

    func testExpertModeRendersHauntedHouse() {
        let doc = demoDocument(Composer2PresetLibrary.hauntedHouse, mode: .expert)
        render(screen(doc, center: Composer2PlaybackCenter()) { Composer2ExpertStack(document: doc) },
               size: CGSize(width: 393, height: 2000), named: "composer2-expert-haunted")
    }

    func testChristmasChasePreviewRenders() {
        let doc = demoDocument(Composer2PresetLibrary.christmasChase)
        render(screen(doc, center: Composer2PlaybackCenter()) { Composer2CustomizeGrid(document: doc) },
               size: CGSize(width: 393, height: 1500), named: "composer2-customize-christmas")
    }

    func testLiveUnavailableInDemoRenders() async {
        let doc = demoDocument(Composer2PresetLibrary.thunderstorm)
        let center = Composer2PlaybackCenter()
        let gateway = Composer2FakeGateway()
        gateway.gateResult = .demo
        _ = await center.start(document: doc, output: Composer2LiveOutput(composition: doc.composition), gateway: gateway, audition: true)
        XCTAssertEqual(center.status, .failed(Composer2Copy.liveDemoUnavailable))
        render(screen(doc, center: center) { Composer2CustomizeGrid(document: doc) },
               size: CGSize(width: 393, height: 1500), named: "composer2-live-unavailable-demo")
    }

    func testPausedPreviewRenders() {
        let doc = demoDocument(Composer2PresetLibrary.auroraDrift)
        render(screen(doc, center: Composer2PlaybackCenter(), previewOn: false) { Composer2CustomizeGrid(document: doc) },
               size: CGSize(width: 393, height: 1500), named: "composer2-preview-paused")
    }

    // MARK: Editors

    func testEveryEditorRenders() {
        let doc = demoDocument(Composer2PresetLibrary.thunderstorm)
        doc.select(layerID: Composer2PresetLibrary.thunderstorm.layers[1].id)
        doc.selectedSlots = [1, 3]
        for editor in Composer2Editor.allCases {
            render(editorFrame(editor.title) { Composer2EditorContent(document: doc, editor: editor) },
                   size: CGSize(width: 393, height: 1400), named: "composer2-editor-\(editor.rawValue)")
        }
    }

    func testEntryCardRenders() {
        let card = ZStack {
            HuePalette.Noir.background.ignoresSafeArea()
            Composer2EntryCard(selectedRoom: DemoDataProvider.rooms[0])
                .padding(HueSpacing.screenH)
        }
        .environment(UnifiedOrchestrator())
        .preferredColorScheme(.dark)
        render(card, size: CGSize(width: 393, height: 220), named: "composer2-studio-entry-card")
    }

    // MARK: v2.1 states

    func testEntryCardRendersSavedLooksAndPlayingPill() async {
        let store = Composer2Store.shared
        let mine = store.save(Composer2PresetLibrary.lavaLamp.duplicated(name: "Snapshot Look", at: Date(timeIntervalSince1970: 1)))
        defer { store.delete(id: mine.id) }
        let center = Composer2PlaybackCenter.shared
        let gateway = Composer2FakeGateway()
        let doc = demoDocument(mine)
        _ = await center.start(document: doc, output: Composer2LiveOutput(composition: mine), gateway: gateway, audition: false)
        XCTAssertTrue(center.isLive)
        let card = ZStack {
            HuePalette.Noir.background.ignoresSafeArea()
            Composer2EntryCard(selectedRoom: DemoDataProvider.rooms[0])
                .padding(HueSpacing.screenH)
        }
        .environment(UnifiedOrchestrator())
        .preferredColorScheme(.dark)
        render(card, size: CGSize(width: 393, height: 300), named: "composer2-studio-entry-card-playing-saved-looks")
        await center.stop(gateway: gateway)
        XCTAssertFalse(center.isLive)
    }

    func testTakeoverWaitingStateRenders() async {
        let doc = demoDocument(Composer2PresetLibrary.auroraDrift)
        let center = Composer2PlaybackCenter(observeApplication: false)
        let gateway = Composer2FakeGateway()
        gateway.foreignControllerPresent = true
        let task = Task { await center.start(document: doc, output: Composer2LiveOutput(composition: doc.composition), gateway: gateway, audition: true) }
        var spins = 0
        while !center.takeoverPending && spins < 20_000 { await Task.yield(); spins += 1 }
        XCTAssertTrue(center.takeoverPending)
        XCTAssertEqual(center.statusText, Composer2Copy.takeoverWaiting)
        render(screen(doc, center: center) { Composer2CustomizeGrid(document: doc) },
               size: CGSize(width: 393, height: 1500), named: "composer2-takeover-waiting")
        center.answerTakeover(false)
        let declined = await task.value
        XCTAssertEqual(declined, .failed(Composer2Copy.takeoverDeclined))
    }

    func testAppliedAndDeclinedNoticesRender() {
        let notices = VStack(spacing: 12) {
            Composer2NoticeBanner(text: Composer2Copy.applied, onDismiss: {})
            Composer2NoticeBanner(text: Composer2Copy.takeoverDeclined, onDismiss: {})
            Composer2NoticeBanner(text: Composer2Copy.liveEndedElsewhere, onDismiss: {})
        }
        .padding(HueSpacing.screenH)
        .background(Composer2Theme.backgroundGradient)
        .preferredColorScheme(.dark)
        render(notices, size: CGSize(width: 393, height: 260), named: "composer2-notices")
    }

    func testImportSheetRenders() {
        let doc = demoDocument(Composer2PresetLibrary.auroraDrift)
        let sheet = Composer2ImportSheet(document: doc)
            .environment(UnifiedOrchestrator())
        render(sheet, size: CGSize(width: 393, height: 700), named: "composer2-import-legacy")
    }

    func testAccessibilitySizeLayoutsRender() {
        let doc = demoDocument(Composer2PresetLibrary.hauntedHouse)
        render(screen(doc, center: Composer2PlaybackCenter(observeApplication: false)) { Composer2CustomizeGrid(document: doc) }
                   .environment(\.dynamicTypeSize, .accessibility2),
               size: CGSize(width: 393, height: 2600), named: "composer2-customize-accessibility2")
        doc.mode = .quick
        render(screen(doc, center: Composer2PlaybackCenter(observeApplication: false)) { Composer2QuickPanel(document: doc) }
                   .environment(\.dynamicTypeSize, .accessibility2),
               size: CGSize(width: 393, height: 2600), named: "composer2-quick-accessibility2")
        doc.mode = .expert
        render(screen(doc, center: Composer2PlaybackCenter(observeApplication: false)) { Composer2ExpertStack(document: doc) }
                   .environment(\.dynamicTypeSize, .accessibility2),
               size: CGSize(width: 393, height: 2600), named: "composer2-expert-accessibility2")
    }

    func testHarmonyAndAudioEditorsRenderTheirNewRows() {
        let doc = demoDocument(Composer2PresetLibrary.christmasChase)
        doc.editSelectedLayer { $0.audio.source = .bass; $0.audio.targets = [.brightness] }
        render(editorFrame(Composer2Editor.palette.title) { Composer2EditorContent(document: doc, editor: .palette) },
               size: CGSize(width: 393, height: 1500), named: "composer2-editor-palette-harmony")
        render(editorFrame(Composer2Editor.audio.title) { Composer2EditorContent(document: doc, editor: .audio) },
               size: CGSize(width: 393, height: 1400), named: "composer2-editor-audio-punch")
    }
}
