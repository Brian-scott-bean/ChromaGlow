// StudioScrollStabilityTests.swift
// HueHome Pro — Unit Tests
//
// Pins the R8b "picker findability" contract: the REAL StudioView
// (demo-mode orchestrator, fully populated deck) hosted at iPhone-17-Pro
// size must render the idle Now Playing bar in its floating position above
// the HueTabBar clearance band. The render attaches to the xcresult
// (.keepAlways) for human review.

import XCTest
import SwiftUI
@testable import HueHome

@MainActor
final class StudioScrollStabilityTests: XCTestCase {

    private var tempURL: URL!
    private var defaults: UserDefaults!
    private let suiteName = "StudioScrollStabilityTests"

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("scroll-stab-\(UUID().uuidString).json")
            defaults = UserDefaults(suiteName: suiteName)
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            BeatClock.shared.clear()
            try? FileManager.default.removeItem(at: tempURL)
            defaults.removePersistentDomain(forName: suiteName)
        }
        super.tearDown()
    }

    // MARK: Hosting

    private func makeMusic() -> MusicSessionCoordinator {
        MusicSessionCoordinator(
            clock: BeatClock.shared,
            resolver: TrackTempoResolver(providers: [], fileURL: tempURL,
                                         defaults: defaults, liveEstimate: { (0, 0) })
        )
    }

    /// Demo-mode orchestrator: the deck composes exactly as on the "Explore
    /// Demo" path — rooms, cards, previews — with zero network.
    private func makeDemoOrchestrator() async -> UnifiedOrchestrator {
        let orchestrator = UnifiedOrchestrator()
        orchestrator.enterDemoMode()
        await orchestrator.loadAll()
        XCTAssertFalse(orchestrator.allRooms.isEmpty, "demo seed produced no rooms")
        return orchestrator
    }

    private func hostStudio(orchestrator: UnifiedOrchestrator,
                            music: MusicSessionCoordinator) -> UIHostingController<AnyView> {
        let root = AnyView(
            StudioView()
                .environment(orchestrator)
                .environment(DeepLinkCoordinator())
                .environment(music)
        )
        let host = UIHostingController(rootView: root)
        host.view.bounds = CGRect(x: 0, y: 0, width: 402, height: 874)
        host.overrideUserInterfaceStyle = .dark
        host.view.backgroundColor = UIColor(StagePalette.stage)
        host.view.layoutIfNeeded()
        return host
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func attachRender(of host: UIHostingController<AnyView>, named name: String) -> UIImage {
        let size = host.view.bounds.size
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return image
    }

    /// Distinct colors across a horizontal strip of the image (device points).
    private func distinctColors(in image: UIImage, stripY: ClosedRange<CGFloat>, of height: CGFloat) -> Int {
        guard let cg = image.cgImage else { return 0 }
        let scale = CGFloat(cg.height) / height
        let y0 = Int(stripY.lowerBound * scale), y1 = min(cg.height - 1, Int(stripY.upperBound * scale))
        guard y1 > y0, let cropped = cg.cropping(to: CGRect(x: 0, y: y0, width: cg.width, height: y1 - y0)) else { return 0 }
        let w = 32, h = 12
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: srgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return 0 }
        ctx.interpolationQuality = .none
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return 0 }
        let buf = data.bindMemory(to: UInt32.self, capacity: w * h)
        var seen = Set<UInt32>()
        for i in 0..<(w * h) { seen.insert(buf[i]) }
        return seen.count
    }

    /// Fraction of a strip painted in the amber a StageKit slider fills its track
    /// with. Unlike `distinctColors`, this cannot be satisfied by the card's own
    /// gradient — an empty stretch of the host surface scores zero, a rendered
    /// control row does not. That distinction is the whole point of the row-36
    /// probes: a band that merely "has colors in it" proves nothing.
    private func amberFraction(in image: UIImage, stripY: ClosedRange<CGFloat>, of height: CGFloat) -> Double {
        guard let cg = image.cgImage else { return 0 }
        let scale = CGFloat(cg.height) / height
        let y0 = Int(stripY.lowerBound * scale), y1 = min(cg.height - 1, Int(stripY.upperBound * scale))
        guard y1 > y0, let cropped = cg.cropping(to: CGRect(x: 0, y: y0, width: cg.width, height: y1 - y0)) else { return 0 }
        let w = 96, h = 48
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: srgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return 0 }
        ctx.interpolationQuality = .none
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return 0 }
        let buf = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var amber = 0
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            let r = Int(buf[i]), g = Int(buf[i + 1]), b = Int(buf[i + 2])
            if r > 150, g > 90, b < 90, r > b + 80 { amber += 1 }
        }
        return Double(amber) / Double(w * h)
    }

    // MARK: Tests
    //
    // NOTE: offset-stability tests were removed — on iOS 26 SwiftUI's
    // ScrollView is not UIKit-backed, so there is no UIScrollView to pin and
    // measure in-process. Scroll behavior is covered by the on-device gate;
    // the simulator input-injection rig (DEVLOG R8b) is the reproduction
    // tool of record.

    /// R8 contract: with NO session, the idle Now Playing bar renders at the
    /// bottom of Studio (the picker entry point is visible on screen). Pixel
    /// probe: the bar strip must not be flat background.
    func testIdleNowPlayingBarRendersAtStudioBottom() async {
        let orchestrator = await makeDemoOrchestrator()
        let host = hostStudio(orchestrator: orchestrator, music: makeMusic())
        pump(0.5)

        let image = attachRender(of: host, named: "studio-idle-bar")
        // The hosted view has no tab bar; the bar floats 70pt above the
        // bottom edge (the HueTabBar clearance). A missing bar leaves this
        // strip flat background.
        let colors = distinctColors(in: image, stripY: 724...798, of: 874)
        XCTAssertGreaterThan(colors, 4,
                             "bottom strip is flat — idle Now Playing bar did not render")
    }

    // ──────────────────────────────────────────────────────────────
    // MARK: - Track A / C5 — inline customization host
    //
    // The overlay era's defect was spatial: a bottom-anchored tray up to 92% of
    // the screen tall, plus a full-screen invisible scrim, sat OVER the room
    // wheel. These probe the replacement — an inline region below a permanently
    // mounted wheel — by rendering the real views and reading pixels/geometry.
    // ──────────────────────────────────────────────────────────────

    /// The wheel band, in points, inside the harness below.
    private var wheelBand: ClosedRange<CGFloat> { 0...140 }

    private func stagedEntertainmentEffect() -> (StudioViewModel, RoomDisplayItem) {
        let vm = StudioViewModel()
        let room = RoomDisplayItem(
            id: "room-live", name: "Living Room", archetype: "living_room",
            isOn: true, brightness: 80, groupedLightID: "gl-1", lightCount: 4,
            bridgeID: "bridge-a", childResourceRefs: [])
        let card = StudioCard(
            id: "candle-card", name: "Candle", tagline: "Soft flicker", icon: "flame",
            accentColor: .orange, requiresForeground: false,
            params: [
                StudioParam(id: "speed", label: "Speed",
                            kind: .slider(min: 0, max: 100), defaultValue: 50, tier: .essential),
                StudioParam(id: "intensity", label: "Intensity",
                            kind: .slider(min: 0, max: 100), defaultValue: 70, tier: .essential),
                // TWO advanced params, deliberately. The row-36 probes assert that
                // advanced controls RENDER inline, and a single param could be
                // satisfied by a caption over near-empty space — the fixture has to
                // make a block tall enough to be unambiguous.
                StudioParam(id: "warmth", label: "Warmth",
                            kind: .slider(min: 0, max: 100), defaultValue: 30, tier: .advanced),
                StudioParam(id: "transition", label: "Transition",
                            kind: .slider(min: 0, max: 100), defaultValue: 40, tier: .advanced),
            ],
            strategy: .bridgeNative(effect: "candle"),
            compositionLayerActivity: nil)
        vm.selectedRoom = room
        vm.runningEffects[StudioSelectionKey(room: room)] = RunningEffect(
            cardID: card.id, card: card, room: room, lightIDs: ["L1"],
            isEntertainment: true, requestedTransport: nil, transportFallback: false,
            identity: RunningLookIdentity(
                bridgeID: room.bridgeID, groupID: room.id, kind: room.kind,
                cardID: card.id, execution: .bridgeNative(effect: "candle"),
                generation: vm.generationCounter.bump(.cardReplaced)))
        XCTAssertNotNil(vm.currentRoomEffect, "fixture: an effect must be running")
        return (vm, room)
    }

    /// The real composition order from `StudioView.body`: the wheel pinned on
    /// top, the region below it. `StudioView`'s own view model is `@State
    /// private`, so a running effect cannot be injected into the whole screen —
    /// this harness mirrors the layout the body builds instead, which is what
    /// the spatial claims below are about.
    private func hostRolodexAboveCustomization(
        vm: StudioViewModel, room: RoomDisplayItem, orchestrator: UnifiedOrchestrator
    ) -> UIHostingController<AnyView> {
        let root = AnyView(
            VStack(spacing: 0) {
                RoomRolodexView(
                    rooms: [room], zones: [],
                    selectedRoom: room, runningEffects: vm.runningEffects,
                    onCommit: { _ in }, onActivate: { _ in }
                )
                .padding(.horizontal, HueSpacing.lg)
                .padding(.vertical, HueSpacing.xs)

                StudioCustomizationHost(
                    vm: vm,
                    performVM: .constant(nil),
                    activeCompositionTab: .constant(.palette),
                    activeHarmonyRule: .constant(HarmonyRule.none),
                    editingSwatch: .constant(nil),
                    onBackToDecks: {},
                    onSaveComposition: { _ in },
                    onTransportSwitch: { _, _ in }
                )
                .frame(maxHeight: .infinity)
            }
            .background(StagePalette.stage)
            .environment(orchestrator)
        )
        let host = UIHostingController(rootView: root)
        host.view.bounds = CGRect(x: 0, y: 0, width: 402, height: 874)
        host.overrideUserInterfaceStyle = .dark
        host.view.backgroundColor = UIColor(StagePalette.stage)
        host.view.layoutIfNeeded()
        return host
    }

    /// The wheel band must render even while a STREAMING look is running — the
    /// exact case the deleted `rolodexHidden` predicate used to unmount it in,
    /// destroying the gesture that was choosing the room.
    func testRolodexBandRendersWhileAnEntertainmentEffectRuns() async {
        let orchestrator = await makeDemoOrchestrator()
        let (vm, room) = stagedEntertainmentEffect()
        let host = hostRolodexAboveCustomization(vm: vm, room: room, orchestrator: orchestrator)
        pump(0.4)

        let image = attachRender(of: host, named: "c5-wheel-with-entertainment-running")
        let colors = distinctColors(in: image, stripY: wheelBand, of: 874)
        XCTAssertGreaterThan(colors, 4,
            "the wheel band is flat while a streaming look runs — the rolodex was "
            + "unmounted or covered, which is the mid-gesture-unmount defect")
    }

    /// …and the customization host must not reach up into that band.
    func testCustomizationHostDoesNotCoverTheWheelBand() async {
        let orchestrator = await makeDemoOrchestrator()
        let (vm, room) = stagedEntertainmentEffect()
        let host = hostRolodexAboveCustomization(vm: vm, room: room, orchestrator: orchestrator)
        pump(0.4)

        _ = attachRender(of: host, named: "c5-host-below-wheel")

        // Geometry, not pixels: find the host's own backing view and assert its
        // top edge is below the wheel band. An overlay tray would have started
        // at the bottom and grown UP through it.
        let hostTop = deepestSubviewTop(in: host.view, minHeight: 200)
        XCTAssertGreaterThan(hostTop, wheelBand.upperBound - 1,
            "the customization region starts at y=\(hostTop), inside the wheel band "
            + "(0...\(wheelBand.upperBound)) — it is covering the selector")

        // …and it is INLINE, not bottom-anchored. The overlay tray grew upward
        // from the bottom edge to as much as 92% of the screen; an inline
        // region begins just under the wheel and runs down from there.
        XCTAssertLessThan(hostTop, 400,
            "the region starts at y=\(hostTop) — that is a bottom-anchored overlay, "
            + "not an inline region below the wheel")
    }

    /// The host renders its pinned header (identity + actions) and its content.
    func testCustomizationHostRendersHeaderAndParams() async {
        let orchestrator = await makeDemoOrchestrator()
        let (vm, room) = stagedEntertainmentEffect()
        let host = hostRolodexAboveCustomization(vm: vm, room: room, orchestrator: orchestrator)
        pump(0.4)

        let image = attachRender(of: host, named: "c5-host-header-and-content")

        // Header band, just below the wheel: the "Back to decks" row, the card
        // name, the room name and the action circles all live here.
        let header = distinctColors(in: image, stripY: 130...260, of: 874)
        XCTAssertGreaterThan(header, 4,
            "the pinned header band is flat — Stop / Perform / Save / Revert and "
            + "'Back to decks' would be unreachable")

        // The "Back to decks" row specifically — the grab bar's replacement.
        // Probed by pixels, not by walking for a UILabel: SwiftUI on iOS 26
        // renders text through display lists and vends no UIKit label to find.
        let backRow = distinctColors(in: image, stripY: 155...175, of: 874)
        XCTAssertGreaterThan(backRow, 2,
            "the 'Back to decks' row is flat — with the grab bar gone there would "
            + "be no way back to the decks")

        // Content below the separator belongs to the host, not to a deck pager
        // showing through: the region is a MODE SWITCH, so the decks are
        // unmounted here and their preview clocks are stopped.
        XCTAssertGreaterThan(distinctColors(in: image, stripY: 190...245, of: 874), 3,
            "the identity + actions row did not render")

        // The PARAMS half of this test's name: the two essential slider rows
        // render below the separator, inside the host's single scroll surface.
        XCTAssertGreaterThan(distinctColors(in: image, stripY: 265...400, of: 874), 3,
            "the content band below the header is flat — the inline param rows "
            + "did not render into the host's scroll surface")
    }

    // ── Build-47 device finding 3 (row 36) — one continuous surface ───
    //
    // The host scrolled continuously, but the advanced disclosure and "+N MORE"
    // presented a detached card/sheet. Worse, `showAdvanced` was never written
    // `true` anywhere in the repo, so the inline branch was unreachable and
    // "+N MORE" could ONLY open `StudioParamSheet`. Advanced controls now render
    // in the same column as the essentials, with no affordance to tap at all.

    /// The claim in one line: advanced controls are on the page already.
    func testAdvancedControlsRenderInlineInTheHostWithoutATap() async {
        let orchestrator = await makeDemoOrchestrator()
        let (vm, room) = stagedEntertainmentEffect()
        let host = hostRolodexAboveCustomization(vm: vm, room: room, orchestrator: orchestrator)
        pump(0.4)

        // Not one tap, not one state write — just render and look.
        let image = attachRender(of: host, named: "row36-advanced-inline-no-tap")

        // The fixture's card is essentials (speed ~y=371, intensity ~y=434) then
        // ADVANCED (warmth ~y=526, transition ~y=589). This band is the advanced
        // block alone, and it is measured by SLIDER FILL rather than colour
        // variety: the card's own gradient satisfies "has colours in it" whether
        // or not anything rendered, so a distinctColors probe here passes
        // vacuously. Amber track fill appears only if those two rows actually drew.
        XCTAssertGreaterThan(amberFraction(in: image, stripY: 500...620, of: 874), 0.005,
            "no slider fill in the advanced band — the advanced controls did not "
            + "render inline, which is the row-36 defect")

        // The detector's own control: bare host surface below the last row must
        // score zero, or the assertion above would mean nothing.
        XCTAssertEqual(amberFraction(in: image, stripY: 650...800, of: 874), 0, accuracy: 0.001,
            "empty host surface is scoring as control fill — the probe cannot "
            + "distinguish rendered controls from background")
    }

    /// Nothing in this host may present a detached surface. `StudioParamSheet`
    /// and `ComposerLayerSheet` are no longer presented from the Studio path.
    func testNoSheetIsPresentedFromTheStudioHost() async {
        let orchestrator = await makeDemoOrchestrator()
        let (vm, room) = stagedEntertainmentEffect()
        let host = hostRolodexAboveCustomization(vm: vm, room: room, orchestrator: orchestrator)
        pump(0.4)

        XCTAssertNil(host.presentedViewController,
            "the Studio host presented a sheet — advanced controls must expand in place")

        // …and it stays nil once everything has settled: a `.sheet` bound to a
        // state that flips during layout would land on a later runloop turn.
        pump(0.5)
        XCTAssertNil(host.presentedViewController,
            "a sheet appeared after the host settled")
    }

    /// The advanced rows CONTINUE the essentials' column rather than living on a
    /// surface of their own.
    ///
    /// Probed by pixels, for the same reason the header test is: on iOS 26 SwiftUI
    /// renders through display lists and vends no per-row UIView to walk. The
    /// structural half of this claim — exactly one vertical ScrollView, and no
    /// sheet modifier in the host at all — is enforced by hardening_guards
    /// Guard 13, which is where a source-level claim belongs.
    func testAdvancedControlsShareTheHostsSingleScrollSurface() async {
        let orchestrator = await makeDemoOrchestrator()
        let (vm, room) = stagedEntertainmentEffect()
        let host = hostRolodexAboveCustomization(vm: vm, room: room, orchestrator: orchestrator)
        pump(0.4)

        let image = attachRender(of: host, named: "row36-single-surface")

        // Controls run UNBROKEN from the essentials into the advanced rows: both
        // halves carry slider fill, in the same column, with no surface boundary
        // between them. If the advanced controls lived on a sheet, the lower band
        // would be bare host surface — which is what the empty band below proves
        // this probe can actually detect.
        let essentials = amberFraction(in: image, stripY: 350...450, of: 874)
        let advanced = amberFraction(in: image, stripY: 500...620, of: 874)
        let belowEverything = amberFraction(in: image, stripY: 650...800, of: 874)

        XCTAssertGreaterThan(essentials, 0.005, "the essential rows did not render")
        XCTAssertGreaterThan(advanced, 0.005,
            "the advanced rows are not in the same column as the essentials")
        XCTAssertEqual(belowEverything, 0, accuracy: 0.001,
            "the probe scores bare surface as content — the two assertions above "
            + "would then hold no matter what rendered")

        // The host still owns one tall region below the wheel, not two stacked ones.
        let hostTop = deepestSubviewTop(in: host.view, minHeight: 200)
        XCTAssertGreaterThan(hostTop, wheelBand.upperBound - 1,
            "the host region starts at y=\(hostTop), inside the wheel band")
    }

    /// The wheel stays visible and unobstructed with the taller content.
    func testRolodexBandStaysVisibleWithAdvancedControlsRendered() async {
        let orchestrator = await makeDemoOrchestrator()
        let (vm, room) = stagedEntertainmentEffect()
        let host = hostRolodexAboveCustomization(vm: vm, room: room, orchestrator: orchestrator)
        pump(0.4)

        let image = attachRender(of: host, named: "row36-wheel-with-advanced-inline")
        XCTAssertGreaterThan(distinctColors(in: image, stripY: wheelBand, of: 874), 4,
            "the wheel band went flat once the advanced controls were rendered — "
            + "the taller host is covering the selector")
    }

    // ── Probing helpers ───────────────────────────────────────────



    /// Top edge (in the root's coordinate space) of the tallest subview that is
    /// not the root itself — the customization region in this harness.
    private func deepestSubviewTop(in root: UIView, minHeight: CGFloat) -> CGFloat {
        var best: CGFloat = .greatestFiniteMagnitude
        func walk(_ v: UIView) {
            for sub in v.subviews {
                let frame = sub.convert(sub.bounds, to: root)
                if frame.height >= minHeight, frame.minY > 1 {
                    best = min(best, frame.minY)
                }
                walk(sub)
            }
        }
        walk(root)
        return best == .greatestFiniteMagnitude ? 0 : best
    }

}

// ──────────────────────────────────────────────────────────────────────────
// MARK: - Track A / C3 — Rolodex behaviour correction
//
// The rule under test: PREVIEW DURING MOVEMENT, COMMIT AFTER THE WHEEL LOCKS.
//
// C2 extracted today's behaviour verbatim, including the per-detent commit that
// IS the defect. C3 corrects it in one atomic commit, because the settling
// phase, the generation token, the watchdog, the Reduce Motion path, the
// delayed commit and deliberate activation are a single correctness boundary.
// ──────────────────────────────────────────────────────────────────────────

@MainActor
final class RolodexSelectionMachineTests: XCTestCase {

    private let rowHeight: CGFloat = 32
    private let colWidth: CGFloat = 150

    // ── Fixtures ──────────────────────────────────────────────────────

    private func item(
        _ id: String, bridge: String? = "bridge-a", kind: RoomDisplayItem.Kind = .room
    ) -> RoomDisplayItem {
        RoomDisplayItem(
            kind: kind, id: id, name: id, archetype: nil,
            isOn: true, brightness: 50, groupedLightID: nil, lightCount: 1,
            bridgeID: bridge, childResourceRefs: [])
    }

    private func roomTokens(_ ids: [String], bridge: String? = "bridge-a") -> [RolodexItemToken] {
        ids.map { RolodexItemToken(item: item($0, bridge: bridge, kind: .room)) }
    }

    private func zoneTokens(_ ids: [String], bridge: String? = "bridge-a") -> [RolodexItemToken] {
        ids.map { RolodexItemToken(item: item($0, bridge: bridge, kind: .zone)) }
    }

    private func machine(
        activeAxis: Axis = .vertical,
        room: Int = 0,
        zone: Int = 0,
        rooms: [String] = ["r0", "r1", "r2", "r3", "r4", "r5", "r6", "r7", "r8"],
        zones: [String] = ["z0", "z1", "z2", "z3"]
    ) -> RolodexSelectionMachine {
        RolodexSelectionMachine(
            rowHeight: rowHeight, colWidth: colWidth,
            activeAxis: activeAxis, committedRoom: room, committedZone: zone,
            roomTokens: roomTokens(rooms), zoneTokens: zoneTokens(zones))
    }

    /// Effects that leave the view. `.preview` and `.haptic` are wheel-local —
    /// if either ever appears here, preview has crossed the boundary.
    private func parentFacing(
        _ effects: [RolodexSelectionMachine.Effect]
    ) -> [RolodexSelectionMachine.Effect] {
        effects.filter {
            switch $0 {
            case .haptic, .preview: return false
            case .commit, .reconcileSelection, .applyExternalSelection, .activate: return true
            }
        }
    }

    /// Every effect that writes `vm.selectedRoom`, regardless of intent.
    private func selectionWrites(
        _ effects: [RolodexSelectionMachine.Effect]
    ) -> [RolodexSelectionMachine.Effect] {
        effects.filter {
            switch $0 {
            case .commit, .reconcileSelection, .applyExternalSelection: return true
            default: return false
            }
        }
    }

    private func commits(
        _ effects: [RolodexSelectionMachine.Effect]
    ) -> [RolodexSelectionMachine.Effect] {
        effects.filter { if case .commit = $0 { return true }; return false }
    }

    private func previews(
        _ effects: [RolodexSelectionMachine.Effect]
    ) -> [RolodexSelectionMachine.Effect] {
        effects.filter { if case .preview = $0 { return true }; return false }
    }

    private func haptics(
        _ effects: [RolodexSelectionMachine.Effect]
    ) -> [RolodexSelectionMachine.Effect] {
        effects.filter { if case .haptic = $0 { return true }; return false }
    }

    /// Drag down across `detents` detents, one detent per sample.
    @discardableResult
    private func dragDown(
        _ m: inout RolodexSelectionMachine, detents: Int
    ) -> [RolodexSelectionMachine.Effect] {
        var all: [RolodexSelectionMachine.Effect] = []
        for i in 1...detents {
            all += m.apply(.dragChanged(dx: 0, dy: -rowHeight * CGFloat(i)))
        }
        return all
    }

    // ── Preserved kinematics (C2, unchanged by C3) ────────────────────

    func testDetentMathMatchesLegacyRounding() {
        let count = 7
        for base in 0..<count {
            for tenths in -400...400 {
                let translation = CGFloat(tenths) / 2
                let legacy = min(
                    max(Int((CGFloat(base) - translation / rowHeight).rounded()), 0), count - 1)
                XCTAssertEqual(
                    RolodexKinematics.liveIndex(
                        base: base, translation: translation, step: rowHeight, count: count),
                    legacy,
                    "detent math diverged at base=\(base) translation=\(translation)")
            }
        }
        XCTAssertEqual(RolodexKinematics.clamp(-5, count: 4), 0)
        XCTAssertEqual(RolodexKinematics.clamp(99, count: 4), 3)
        XCTAssertEqual(RolodexKinematics.clamp(2, count: 0), -1)
    }

    func testSettleTargetUsesPredictedTranslation() {
        let live = RolodexKinematics.liveIndex(
            base: 5, translation: 32, step: rowHeight, count: 9)
        let settle = RolodexKinematics.settleTarget(
            base: 5, predicted: 128, step: rowHeight, count: 9)
        XCTAssertEqual(live, 4)
        XCTAssertEqual(settle, 1, "the settle must follow the prediction, not the live translation")
        XCTAssertEqual(
            RolodexKinematics.settleTarget(base: 0, predicted: 9_999, step: colWidth, count: 4), 0)
        XCTAssertEqual(
            RolodexKinematics.settleTarget(base: 3, predicted: -9_999, step: colWidth, count: 4), 3)
    }

    func testAxisLockRequiresSixPointsAndNeverFlips() {
        var m = machine()
        XCTAssertTrue(m.apply(.dragChanged(dx: 6, dy: 6)).isEmpty,
            "exactly 6pt is not more than 6pt — no lock")
        XCTAssertNil(m.lockAxis)

        m.apply(.dragChanged(dx: 7, dy: 0))
        XCTAssertEqual(m.lockAxis, .horizontal)
        XCTAssertEqual(m.activeAxis, .horizontal)

        m.apply(.dragChanged(dx: 7, dy: 400))
        XCTAssertEqual(m.lockAxis, .horizontal, "the axis re-locked mid-gesture")
        XCTAssertEqual(m.liveRoom, 0, "the vertical wheel must not have moved")
    }

    func testZeroCountAxisIsInert() {
        var m = machine(rooms: [], zones: [])
        XCTAssertTrue(m.apply(.dragChanged(dx: 0, dy: 200)).isEmpty)
        XCTAssertTrue(
            m.apply(.dragEnded(predictedDX: 0, predictedDY: 400, reduceMotion: false)).isEmpty)
        XCTAssertEqual(m.phase, .idle, "a zero-count axis must not enter settling")
        XCTAssertEqual(m.translation, 0)
        XCTAssertNil(m.lockAxis)
        XCTAssertTrue(m.apply(.tapCenter).isEmpty, "nothing to activate")
    }

    func testTokenMintingIsStableAndBridgeQualified() {
        let onA = item("room-1", bridge: "bridge-a")
        var renamed = onA
        renamed.name = "Renamed"
        renamed.brightness = 99
        XCTAssertEqual(RolodexItemToken(item: onA), RolodexItemToken(item: onA))
        XCTAssertEqual(RolodexItemToken(item: onA), RolodexItemToken(item: renamed),
            "a rename must not change identity — rebasing depends on it")
    }

    // ── The correction ────────────────────────────────────────────────

    /// THE defect, gone. Seven detent crossings produce seven previews and
    /// seven haptics and ZERO commits — so zero `selectedRoom` writes and zero
    /// capability/entertainment refreshes while the finger is down.
    func testDraggingAcrossSevenDetentsCommitsZeroTimes() {
        var m = machine(room: 0)
        let effects = dragDown(&m, detents: 7)

        XCTAssertEqual(previews(effects).count, 7, "expected one preview per detent crossing")
        XCTAssertEqual(haptics(effects).count, 7, "the detent tick must still be felt")
        XCTAssertEqual(commits(effects).count, 0, "a drag committed — this is the whole defect")
        XCTAssertTrue(parentFacing(effects).isEmpty,
            "nothing at all may reach the parent during a drag")
        XCTAssertEqual(m.liveRoom, 7, "the wheel still previews the seventh detent")
        XCTAssertEqual(m.committedRoom, 0, "…while the committed selection has not moved")
    }

    /// Lifting the finger is not choosing. It enters `.settling` and emits a
    /// preview of the target — never a commit.
    func testReleaseEntersSettlingWithoutCommitting() {
        var m = machine(room: 0)
        dragDown(&m, detents: 3)

        let effects = m.apply(
            .dragEnded(predictedDX: 0, predictedDY: -rowHeight * 5, reduceMotion: false))

        XCTAssertEqual(previews(effects).count, 1)
        XCTAssertTrue(commits(effects).isEmpty, "the finger lifting must not commit")
        XCTAssertTrue(parentFacing(effects).isEmpty)
        guard case let .settling(_, axis, target) = m.phase else {
            return XCTFail("release did not enter .settling — phase is \(m.phase)")
        }
        XCTAssertEqual(axis, .vertical)
        XCTAssertEqual(target, 5)
        XCTAssertEqual(m.liveRoom, 5, "the wheel previews the target")
        XCTAssertEqual(m.committedRoom, 0, "…and still has not committed")
        XCTAssertTrue(m.isPreviewing)
    }

    /// The settle completion is the commit, and it happens exactly once.
    func testSettleFinishedCommitsExactlyOnce() {
        var m = machine(room: 0)
        dragDown(&m, detents: 3)
        m.apply(.dragEnded(predictedDX: 0, predictedDY: -rowHeight * 5, reduceMotion: false))
        guard let token = m.activeSettleToken else { return XCTFail("no settle token") }

        let first = m.apply(.settleFinished(token))
        XCTAssertEqual(commits(first), [.commit(axis: .vertical, index: 5)])
        XCTAssertEqual(m.committedRoom, 5)
        XCTAssertEqual(m.phase, .idle)
        XCTAssertFalse(m.isPreviewing)

        // The same completion delivered twice must not commit twice.
        XCTAssertTrue(m.apply(.settleFinished(token)).isEmpty,
            "a repeated completion committed a second time")
    }

    /// A tap opens customization. It is NOT a selection write.
    func testTapOnSettledItemActivatesWithoutCommitting() {
        var m = machine(room: 2)
        let effects = m.apply(.tapCenter)
        XCTAssertEqual(effects, [.activate(axis: .vertical, index: 2)])
        XCTAssertTrue(selectionWrites(effects).isEmpty, "activation must not write the selection")
        XCTAssertEqual(m.committedRoom, 2, "…and must not move the selection either")
    }

    /// The case a commit-only design silently no-ops: the centred item is
    /// ALREADY the selection, so assigning it would change nothing and the
    /// surface would never open.
    func testTapOnAlreadySelectedRoomStillActivates() {
        var m = machine(room: 4)
        XCTAssertEqual(m.committedIndex, m.activeIndex, "fixture: already selected")

        let effects = m.apply(.tapCenter)
        XCTAssertEqual(effects, [.activate(axis: .vertical, index: 4)],
            "tapping the already-selected room must still open customization")
    }

    /// A tap that lands mid-gesture is a stray touch, not an intent.
    func testTapDuringDragOrSettlingIsIgnored() {
        var dragging = machine(room: 0)
        dragDown(&dragging, detents: 2)
        XCTAssertEqual(dragging.phase, .dragging)
        XCTAssertTrue(dragging.apply(.tapCenter).isEmpty, "a tap mid-drag must be ignored")

        var settling = machine(room: 0)
        dragDown(&settling, detents: 2)
        settling.apply(.dragEnded(predictedDX: 0, predictedDY: -64, reduceMotion: false))
        XCTAssertTrue(settling.apply(.tapCenter).isEmpty, "a tap mid-settle must be ignored")
    }

    /// Never yank the wheel out from under a finger or mid-spring.
    func testExternalSelectDuringDragOrSettlingIsDeferredNotApplied() {
        var dragging = machine(room: 0)
        dragDown(&dragging, detents: 2)
        XCTAssertTrue(dragging.apply(.externalSelect(axis: .vertical, index: 6)).isEmpty)
        XCTAssertNotNil(dragging.deferredExternal)
        XCTAssertEqual(dragging.committedRoom, 0, "the external selection was applied mid-drag")

        var settling = machine(room: 0)
        dragDown(&settling, detents: 2)
        settling.apply(.dragEnded(predictedDX: 0, predictedDY: -64, reduceMotion: false))
        XCTAssertTrue(settling.apply(.externalSelect(axis: .vertical, index: 6)).isEmpty)
        XCTAssertNotNil(settling.deferredExternal)
    }

    /// Idle external selection snaps the wheels and emits nothing: the parent
    /// already holds this selection, so writing it back would be circular.
    func testExternalSelectWhileIdleSnapsWithoutEmittingCommit() {
        var m = machine(room: 0)
        let effects = m.apply(.externalSelect(axis: .vertical, index: 6))

        XCTAssertTrue(effects.isEmpty, "an idle external selection must emit nothing")
        XCTAssertEqual(m.committedRoom, 6, "…but the wheel must snap to it")
        XCTAssertEqual(m.liveRoom, 6)
        XCTAssertEqual(m.phase, .idle)
    }

    /// The sheet is deliberate in both senses — the opposite direction from a
    /// centre tap, so the two can never be silently swapped.
    func testPickerSheetSelectionCommitsAndActivates() {
        var m = machine(room: 0)
        let effects = m.apply(.pickerSelect(axis: .horizontal, index: 2))

        XCTAssertEqual(commits(effects), [.commit(axis: .horizontal, index: 2)])
        XCTAssertTrue(effects.contains(.activate(axis: .horizontal, index: 2)),
            "the picker must also open customization")
        XCTAssertEqual(m.committedZone, 2)
        XCTAssertEqual(m.activeAxis, .horizontal)
    }

    /// A vanished room is a repair, never a choice.
    func testRosterShrinkMidDragEmitsReconcileNotCommit() {
        var m = machine(room: 5)
        dragDown(&m, detents: 1)

        let effects = m.apply(.rosterChanged(
            rooms: roomTokens(["r0", "r1", "r2"]), zones: zoneTokens(["z0", "z1", "z2", "z3"])))

        XCTAssertTrue(commits(effects).isEmpty,
            "a roster shrink must never be counted as the user choosing")
        XCTAssertEqual(effects.filter {
            if case .reconcileSelection = $0 { return true }; return false
        }.count, 1, "the vanished selection must be repaired exactly once")
        XCTAssertLessThan(m.committedRoom, 3, "must land on a surviving room")
    }

    /// Identity survives a reorder: index 3 → 8, same token, no effect at all.
    func testRosterReorderMidDragRebasesOnTokenNotIndex() {
        let original = ["r0", "r1", "r2", "r3", "r4", "r5", "r6", "r7", "r8"]
        var m = machine(room: 3, rooms: original)
        dragDown(&m, detents: 1)

        // r3 moves to index 8; every id survives.
        let reordered = ["r0", "r1", "r2", "r4", "r5", "r6", "r7", "r8", "r3"]
        let effects = m.apply(.rosterChanged(
            rooms: roomTokens(reordered), zones: zoneTokens(["z0", "z1", "z2", "z3"])))

        XCTAssertTrue(effects.isEmpty,
            "a pure reorder must produce no effect at all — identity was preserved")
        XCTAssertEqual(m.committedRoom, 8, "the selection followed its token, not its index")
    }

    func testDuplicateRoomIDAcrossBridgesAreDistinctTokens() {
        let onA = RolodexItemToken(item: item("room-1", bridge: "bridge-a"))
        let onB = RolodexItemToken(item: item("room-1", bridge: "bridge-b"))
        XCTAssertNotEqual(onA, onB,
            "two bridges' same-id rooms must not rebase onto each other")

        // And the machine must not confuse them when rebasing.
        var m = machine(room: 0, rooms: ["room-1"])
        let bridgeBRoster = [RolodexItemToken(item: item("room-1", bridge: "bridge-b"))]
        let effects = m.apply(.rosterChanged(rooms: bridgeBRoster, zones: []))
        XCTAssertEqual(effects.filter {
            if case .reconcileSelection = $0 { return true }; return false
        }.count, 1, "bridge A's room vanishing must repair, not silently adopt bridge B's")
    }

    func testRoomAndZoneSharingAnIDAreDistinctTokens() {
        let asRoom = RolodexItemToken(item: item("group-7", kind: .room))
        let asZone = RolodexItemToken(item: item("group-7", kind: .zone))
        XCTAssertNotEqual(asRoom, asZone,
            "the two axes address different collections; kind is load-bearing")
    }

    /// Siri fires while the wheel is settling on someone else. Committing the
    /// stale target and THEN applying Siri's would switch the content twice.
    func testDeferredExternalAppliesSelectionWithoutCommitting() {
        var m = machine(room: 0)
        dragDown(&m, detents: 2)
        m.apply(.dragEnded(predictedDX: 0, predictedDY: -rowHeight * 3, reduceMotion: false))
        guard let token = m.activeSettleToken else { return XCTFail("no settle token") }

        m.apply(.externalSelect(axis: .vertical, index: 6))   // deferred
        let effects = m.apply(.settleFinished(token))

        XCTAssertEqual(effects, [.applyExternalSelection(axis: .vertical, index: 6)],
            "the deferred external must supersede the stale settle target")
        XCTAssertTrue(commits(effects).isEmpty,
            "the user did not choose room 6 by dragging — this is not a commit")
        XCTAssertEqual(m.committedRoom, 6, "…but it IS the selection now")
        XCTAssertEqual(m.phase, .idle)
        XCTAssertNil(m.deferredExternal)
    }

    /// One write means one refresh cycle. Two would mean two.
    func testDeferredExternalCausesExactlyOneSelectionKeyChange() {
        var m = machine(room: 0)
        var all: [RolodexSelectionMachine.Effect] = []
        all += dragDown(&m, detents: 2)
        all += m.apply(
            .dragEnded(predictedDX: 0, predictedDY: -rowHeight * 3, reduceMotion: false))
        guard let token = m.activeSettleToken else { return XCTFail("no settle token") }
        all += m.apply(.externalSelect(axis: .vertical, index: 6))
        all += m.apply(.settleFinished(token))

        XCTAssertEqual(selectionWrites(all).count, 1,
            "the whole interaction must produce exactly ONE selectedRoom write")
        XCTAssertEqual(commits(all).count, 0, "…and zero user commits")
    }

    /// Settle A completes after drag B began — the classic wrong-commit.
    ///
    /// Two distinct drops are covered, and they are NOT the same mechanism:
    /// the first is caught by the phase no longer being `.settling`, the second
    /// only by the token. A guard that checked the phase alone would pass the
    /// first and commit the wrong room on the second.
    func testStaleSettleCallbackIsDroppedByToken() {
        // (a) Superseded by a new drag — phase is `.dragging`.
        var m = machine(room: 0)
        dragDown(&m, detents: 2)
        m.apply(.dragEnded(predictedDX: 0, predictedDY: -rowHeight * 3, reduceMotion: false))
        guard let staleToken = m.activeSettleToken else { return XCTFail("no settle token") }

        m.apply(.dragChanged(dx: 0, dy: -rowHeight))
        XCTAssertEqual(m.phase, .dragging)
        XCTAssertTrue(m.apply(.settleFinished(staleToken)).isEmpty,
            "a settle superseded by a new drag committed anyway")
        XCTAssertEqual(m.committedRoom, 0)

        // (b) The token doing the work ALONE: a SECOND settle is active, so the
        // phase check passes and only the generation can tell them apart.
        m.apply(.dragEnded(predictedDX: 0, predictedDY: -rowHeight * 8, reduceMotion: false))
        guard let liveToken = m.activeSettleToken else { return XCTFail("no second settle") }
        XCTAssertNotEqual(staleToken, liveToken, "fixture: generations must differ")
        guard case .settling = m.phase else { return XCTFail("expected .settling") }

        XCTAssertTrue(m.apply(.settleFinished(staleToken)).isEmpty,
            "settle A's completion committed against settle B — the token was not consulted")
        XCTAssertEqual(m.committedRoom, 0, "…and it moved the committed selection")
        guard case .settling = m.phase else {
            return XCTFail("a stale completion resolved the LIVE settle")
        }

        // The live one still resolves correctly afterwards.
        XCTAssertEqual(commits(m.apply(.settleFinished(liveToken))).count, 1)
        XCTAssertEqual(m.committedRoom, 8)
    }

    /// A wheel stranded in `.settling` would never commit again.
    func testSettleWatchdogCommitsIfCompletionNeverFires() {
        var m = machine(room: 0)
        dragDown(&m, detents: 2)
        m.apply(.dragEnded(predictedDX: 0, predictedDY: -rowHeight * 4, reduceMotion: false))
        guard let token = m.activeSettleToken else { return XCTFail("no settle token") }

        // The spring's completion never arrives; only the watchdog does.
        let effects = m.apply(.settleWatchdogFired(token))
        XCTAssertEqual(commits(effects), [.commit(axis: .vertical, index: 4)],
            "the watchdog must commit exactly what the settle targeted")
        XCTAssertEqual(m.phase, .idle)
    }

    /// …but it must not commit somebody else's settle.
    func testWatchdogForAnOldSettleIsIgnored() {
        var m = machine(room: 0)
        dragDown(&m, detents: 2)
        m.apply(.dragEnded(predictedDX: 0, predictedDY: -rowHeight * 3, reduceMotion: false))
        guard let oldToken = m.activeSettleToken else { return XCTFail("no settle token") }
        m.apply(.settleFinished(oldToken))          // settle A resolves normally

        // A second gesture starts and settles.
        m.apply(.dragChanged(dx: 0, dy: -rowHeight))
        m.apply(.dragEnded(predictedDX: 0, predictedDY: -rowHeight, reduceMotion: false))
        let committedBefore = m.committedRoom

        let effects = m.apply(.settleWatchdogFired(oldToken))
        XCTAssertTrue(effects.isEmpty, "the FIRST settle's watchdog fired against the second")
        XCTAssertEqual(m.committedRoom, committedBefore)
    }

    /// Reduce Motion has no spring to wait on, so the SAME settle rule runs
    /// immediately — one code path, not a parallel reduced branch that drifts.
    func testReduceMotionCommitsImmediatelyWithoutASpring() {
        var m = machine(room: 0)
        dragDown(&m, detents: 2)

        let effects = m.apply(
            .dragEnded(predictedDX: 0, predictedDY: -rowHeight * 4, reduceMotion: true))

        XCTAssertEqual(commits(effects), [.commit(axis: .vertical, index: 4)],
            "Reduce Motion must commit on release, with no completion callback")
        XCTAssertEqual(m.phase, .idle, "…and must not be left waiting in .settling")
        XCTAssertNil(m.activeSettleToken)
        XCTAssertEqual(m.committedRoom, 4)

        // The animated path, by contrast, is still waiting.
        var animated = machine(room: 0)
        dragDown(&animated, detents: 2)
        animated.apply(
            .dragEnded(predictedDX: 0, predictedDY: -rowHeight * 4, reduceMotion: false))
        XCTAssertNotNil(animated.activeSettleToken)
        XCTAssertEqual(animated.committedRoom, 0)
    }

    /// The structural guarantee: no preview can reach the parent, because the
    /// only parent-facing effects are commit / reconcile / applyExternal /
    /// activate. There is no `onPreview` for a future edit to attach to.
    func testMachineExposesNoPreviewEffectToTheParent() {
        var m = machine(room: 0)
        var all: [RolodexSelectionMachine.Effect] = []
        all += dragDown(&m, detents: 5)
        all += m.apply(
            .dragEnded(predictedDX: 0, predictedDY: -rowHeight * 5, reduceMotion: false))

        XCTAssertFalse(previews(all).isEmpty, "fixture: previews were produced")
        XCTAssertTrue(parentFacing(all).isEmpty,
            "a preview escaped to the parent before the wheel settled")

        // And once settled, the ONLY parent-facing effect is the single commit.
        guard let token = m.activeSettleToken else { return XCTFail("no settle token") }
        let settled = m.apply(.settleFinished(token))
        XCTAssertEqual(parentFacing(settled), [.commit(axis: .vertical, index: 5)])
    }

    /// A flick past the end clamps to the last detent and produces ONE settle,
    /// not a second animation chasing an out-of-range target.
    func testFlickPastEndDoesNotDoubleAnimate() {
        var m = machine(room: 8, rooms: ["r0", "r1", "r2", "r3", "r4", "r5", "r6", "r7", "r8"])
        m.apply(.dragChanged(dx: 0, dy: -200))

        let effects = m.apply(
            .dragEnded(predictedDX: 0, predictedDY: -10_000, reduceMotion: false))

        guard case let .settling(token, _, target) = m.phase else {
            return XCTFail("expected exactly one settle, phase is \(m.phase)")
        }
        XCTAssertEqual(target, 8, "the flick must clamp to the last detent")
        XCTAssertEqual(previews(effects).count, 1, "one settle, one preview — not two")

        // Resolving it commits once and leaves nothing pending.
        let done = m.apply(.settleFinished(token))
        XCTAssertEqual(commits(done).count, 1)
        XCTAssertEqual(m.phase, .idle)
        XCTAssertNil(m.activeSettleToken)
    }

    // ── Build-47 device finding 1: the settle must not snap back ──────
    //
    // The wheel's rendered geometry is `(idx - renderBase)*step + translation`.
    // `applyDragEnded` zeroes `translation` INSIDE the spring transaction while the
    // commit is deliberately deferred to the spring's completion — so if the base is
    // still the previously committed row, the spring carries the wheel BACK there and
    // the commit then jumps it forward. Bathroom → Laundry rendered as
    // Bathroom → (back toward Bathroom) → Laundry.

    /// The base under a settle is the TARGET, not the row we are leaving.
    func testSettlingRendersFromTheSettleTargetNotThePreviousCommit() {
        var m = machine(room: 0)
        dragDown(&m, detents: 2)
        m.apply(.dragEnded(predictedDX: 0, predictedDY: -rowHeight * 5, reduceMotion: false))

        guard case let .settling(_, _, target) = m.phase else {
            return XCTFail("expected a settle, phase is \(m.phase)")
        }
        XCTAssertEqual(target, 5)
        XCTAssertEqual(m.committedRoom, 0, "the commit is still deferred — that is C3's rule")
        XCTAssertEqual(m.renderBase(for: .vertical), target,
            "the wheel must be DRAWN from the settle target while the spring runs")

        // The target cell's rendered offset must already be the centre, because
        // `translation` is zero and the base is the target.
        let pos = CGFloat(target - m.renderBase(for: .vertical)) * rowHeight + m.translation
        XCTAssertEqual(pos, 0, accuracy: 0.0001,
            "the settle target must land on the lens, not one wheel-length away")
    }

    /// The device finding itself: releasing on B must never render a frame whose
    /// destination is A. Walks every state the view can draw between release and
    /// commit and asserts the base is never the row the drag started from.
    func testReleasingOnTargetNeverRendersAnIntermediateTargetOfThePreviousItem() {
        var m = machine(room: 2)
        let previouslyCommitted = m.committedRoom

        dragDown(&m, detents: 3)
        XCTAssertEqual(m.renderBase(for: .vertical), previouslyCommitted,
            "while a finger is down the base IS the committed row — translation carries the wheel")

        m.apply(.dragEnded(predictedDX: 0, predictedDY: -rowHeight * 4, reduceMotion: false))
        guard case let .settling(token, _, target) = m.phase else {
            return XCTFail("expected a settle, phase is \(m.phase)")
        }
        XCTAssertNotEqual(target, previouslyCommitted)
        XCTAssertNotEqual(m.renderBase(for: .vertical), previouslyCommitted,
            "SNAP-BACK: the spring would carry the wheel back to the room we left")
        XCTAssertEqual(m.translation, 0, "…and it does so because translation is zeroed here")

        m.apply(.settleFinished(token))
        XCTAssertEqual(m.renderBase(for: .vertical), target,
            "the commit must not move the base — the wheel is already there")
        XCTAssertEqual(m.committedRoom, target)
    }

    /// The old committed marker answers "where does releasing unchanged return you".
    /// That question is live under a finger and answered once the wheel is settling —
    /// keeping the marker on the old row advertises a destination we are leaving.
    func testSettlingSuppressesTheOldCommittedMarker() {
        var m = machine(room: 1)
        XCTAssertEqual(m.committedMarker(for: .vertical), 1, "at rest the marker is the selection")

        dragDown(&m, detents: 3)
        XCTAssertEqual(m.committedMarker(for: .vertical), 1,
            "PRESERVED while dragging — this is the user's way back")

        m.apply(.dragEnded(predictedDX: 0, predictedDY: -rowHeight * 3, reduceMotion: false))
        guard case let .settling(token, _, target) = m.phase else {
            return XCTFail("expected a settle, phase is \(m.phase)")
        }
        XCTAssertNil(m.committedMarker(for: .vertical),
            "SUPPRESSED while settling — the choice is made")

        m.apply(.settleFinished(token))
        XCTAssertEqual(m.committedMarker(for: .vertical), target,
            "and it returns on the row we actually landed on")
    }

    /// One settle, one write. The snap-back fix must not add a second.
    func testOneSettleProducesExactlyOneParentSelectionWrite() {
        var m = machine(room: 0)
        var all: [RolodexSelectionMachine.Effect] = []
        all += dragDown(&m, detents: 4)
        all += m.apply(.dragEnded(predictedDX: 0, predictedDY: -rowHeight * 6, reduceMotion: false))
        guard let token = m.activeSettleToken else { return XCTFail("no settle token") }
        all += m.apply(.settleFinished(token))

        XCTAssertEqual(selectionWrites(all).count, 1, "exactly ONE selectedRoom write")
        XCTAssertEqual(commits(all).count, 1, "…and it is the user's commit")
        XCTAssertEqual(m.committedRoom, 6)
    }

    /// Reduce Motion has no spring to roll back through, and must not grow one.
    func testReduceMotionAppliesTheFinalTargetWithoutAVisualRollback() {
        var m = machine(room: 0)
        dragDown(&m, detents: 2)
        let effects = m.apply(
            .dragEnded(predictedDX: 0, predictedDY: -rowHeight * 5, reduceMotion: true))

        XCTAssertEqual(m.phase, .idle, "Reduce Motion never enters a settling window")
        XCTAssertNil(m.activeSettleToken)
        XCTAssertEqual(m.committedRoom, 5)
        XCTAssertEqual(m.renderBase(for: .vertical), 5,
            "the base goes straight to the target — there is no intermediate frame")
        XCTAssertEqual(m.committedMarker(for: .vertical), 5)
        XCTAssertEqual(selectionWrites(effects).count, 1, "one write, exactly as the spring path")
    }

    /// A settle on one axis must not disturb how the other wheel is drawn.
    func testInactiveAxisRenderBaseAndMarkerAreUnaffectedByASettleOnTheOtherAxis() {
        var m = machine(room: 0, zone: 2)
        dragDown(&m, detents: 3)
        m.apply(.dragEnded(predictedDX: 0, predictedDY: -rowHeight * 3, reduceMotion: false))

        XCTAssertEqual(m.renderBase(for: .horizontal), 2, "the zone wheel has no settle in flight")
        XCTAssertEqual(m.committedMarker(for: .horizontal), 2, "…so its marker stays put")
    }

    /// The counterpart guarantee, pinned deliberately: this fix does NOT suppress
    /// external selections. Siri, a deep link or a parent write naming the room we
    /// just left is a real reselection, not an echo — the event carries no origin, so
    /// a token-equality guess would silently swallow legitimate selections.
    func testExternalSelectionOfThePreviousRoomStillSupersedesAnActiveSettle() {
        var m = machine(room: 3)
        var all: [RolodexSelectionMachine.Effect] = []
        all += dragDown(&m, detents: 2)
        all += m.apply(.dragEnded(predictedDX: 0, predictedDY: -rowHeight * 4, reduceMotion: false))
        guard let token = m.activeSettleToken else { return XCTFail("no settle token") }

        // Index 3 is the room the drag STARTED from.
        all += m.apply(.externalSelect(axis: .vertical, index: 3))
        XCTAssertNotNil(m.deferredExternal, "a genuine external selection must still be held")

        all += m.apply(.settleFinished(token))
        XCTAssertEqual(m.committedRoom, 3, "…and must still supersede the settle target")
        XCTAssertEqual(selectionWrites(all).count, 1, "one write")
        XCTAssertTrue(commits(all).isEmpty, "…and it is not a user commit")
    }

    /// C2's extraction proof, re-pointed at C3. The detent ARITHMETIC is
    /// untouched — same indices, same settle target — and the ONLY divergence
    /// from the pre-extraction behaviour is that the mid-drag commits became
    /// previews and the commit moved behind the settle. If anything else about
    /// the wheel changed, this fails.
    func testC3DivergesFromLegacyOnlyByDeferringTheCommit() {
        // The pre-C2 algorithm, transcribed verbatim.
        struct Legacy {
            let rowHeight: CGFloat = 32
            var selRoom = 0, liveRoom = 0
            var lockAxis: Axis?
            var drag: CGFloat = 0
            let roomCount: Int
            var commits: [Int] = []

            mutating func onChanged(dy: CGFloat) {
                if lockAxis == nil {
                    guard abs(dy) > 6 else { return }
                    lockAxis = .vertical
                }
                drag = dy
                let newRoom = min(
                    max(Int((CGFloat(selRoom) - drag / rowHeight).rounded()), 0), roomCount - 1)
                guard newRoom != liveRoom else { return }
                liveRoom = newRoom
                commits.append(newRoom)          // onSelect fired HERE, mid-drag
            }

            mutating func onEnded(pdy: CGFloat) {
                let target = min(
                    max(Int((CGFloat(selRoom) - pdy / rowHeight).rounded()), 0), roomCount - 1)
                selRoom = target; liveRoom = target
                commits.append(target)
            }
        }

        var legacy = Legacy(roomCount: 9)
        var m = machine(room: 0)
        var effects: [RolodexSelectionMachine.Effect] = []

        for i in 1...7 {
            let dy = -rowHeight * CGFloat(i)
            legacy.onChanged(dy: dy)
            effects += m.apply(.dragChanged(dx: 0, dy: dy))
        }
        let predicted = -rowHeight * CGFloat(7)
        legacy.onEnded(pdy: predicted)
        effects += m.apply(
            .dragEnded(predictedDX: 0, predictedDY: predicted, reduceMotion: false))
        guard let token = m.activeSettleToken else { return XCTFail("no settle token") }
        effects += m.apply(.settleFinished(token))

        // Same arithmetic: the detents crossed and the final selection agree.
        let previewIndices = previews(effects).compactMap {
            if case let .preview(_, index) = $0 { return index }; return Int?.none
        }
        XCTAssertEqual(Array(previewIndices.prefix(7)), Array(legacy.commits.prefix(7)),
            "C3 must preview exactly the detents the legacy code committed")
        XCTAssertEqual(m.committedRoom, legacy.selRoom,
            "the settled selection must match the legacy result exactly")

        // The one intended divergence.
        XCTAssertEqual(legacy.commits.count, 8,
            "fixture: the legacy code committed 7 times mid-drag plus once on release")
        XCTAssertEqual(commits(effects).count, 1,
            "C3 must commit exactly once, after the wheel stops")
    }
}

// ─────────────────────────────────────────────────────────────────────────
// N1b — AI presentation stabilization.
//
// THE DEVICE DEFECT (build 49, Brian): tapping the wand on the Composer deck
// sent the app straight back to the Effects deck. His own observation named
// the mechanism — "as the keyboard comes up we are then directed to effects
// page. maybe it pushes us there because there isn't enough room?" The AI
// prompt's keyboard shrank the bottom safe area, Studio's root GeometryReader
// handed the entire collapse to the deck region (every sibling holds an
// intrinsic height), and the crushed page-style TabView — a
// UIPageViewController underneath — recovered by writing its FIRST page back
// through the selection binding. Deck 0 is Effects.
//
// The proof that this could only be the pager: nothing in ChromaGlow ever
// assigns deck 0. So the fix REFUSES the write rather than repairing it after.
//
// These tests drive `StudioAIPresentation` — the same value the wand button,
// the Cancel action, the pager's selection binding, the overlay's visibility
// and the delayed focus callback all go through. There is no parallel model
// here: `open()`, `propose(_:)`, `beginDismissal()`, `finishDismissal(token:)`
// and `focusIsCurrent(_:)` are literally the methods StudioView calls.
//
// N1's `StudioAIGeneration` rules (commit 906525d) are untouched and still
// required — they protect the APPLICATION phase, a second and a half later.
// ─────────────────────────────────────────────────────────────────────────
@MainActor
final class StudioAIPresentationTests: XCTestCase {

    private let composerDeck = 2
    private let effectsDeck = 0

    /// A presentation sitting on the Composer deck, exactly where Brian is.
    private func onComposerDeck() -> StudioAIPresentation {
        var p = StudioAIPresentation(deck: 0)
        p.propose(composerDeck)
        XCTAssertEqual(p.deck, composerDeck, "fixture: an unfenced proposal must land")
        return p
    }

    // ── 1. Opening captures and holds the originating deck ──────────

    func testOpeningAIComposerFromComposerDeckCapturesAndHoldsIt() {
        var p = onComposerDeck()
        p.open()

        XCTAssertEqual(p.deck, composerDeck, "opening the composer may not move the user")
        XCTAssertTrue(p.isFenced, "the originating deck must be captured on open")
        XCTAssertTrue(p.isOverlayVisible, "the overlay is what the user tapped for")
    }

    // ── 2. The pager's deck-0 write-back, while the overlay is open ──

    func testDeckZeroProposedWhileOverlayIsOpenIsRejected() {
        var p = onComposerDeck()
        p.open()

        // This is the exact event the keyboard's relayout produces.
        p.propose(effectsDeck)

        XCTAssertEqual(p.deck, composerDeck,
            "the pager wrote Effects through the selection binding and it was accepted — "
            + "this is the build-49 defect")
    }

    /// NC-1 — the fence is load-bearing. Without it the SAME call reaches
    /// Effects, which is precisely what build 49 does.
    func testWithoutTheFenceTheSameProposalReachesEffects() {
        var p = onComposerDeck()
        // No open() — no fence.
        p.propose(effectsDeck)

        XCTAssertEqual(p.deck, effectsDeck,
            "negative control: an unfenced presentation MUST accept deck 0, otherwise "
            + "the fenced tests above would pass for the wrong reason")
    }

    // ── 3. The dismissal window ─────────────────────────────────────

    func testDeckZeroProposedDuringOverlayAndKeyboardDismissalIsRejected() {
        var p = onComposerDeck()
        p.open()
        let settle = p.beginDismissal()

        // The overlay is gone but the keyboard is still animating away, and its
        // dismissal relayout proposes deck 0 exactly as its appearance did.
        XCTAssertFalse(p.isOverlayVisible, "the overlay closes at beginDismissal")
        XCTAssertTrue(p.isFenced,
            "NC-2: releasing the fence when the overlay closes reopens the defect — "
            + "the keyboard has not finished leaving yet")

        p.propose(effectsDeck)
        XCTAssertEqual(p.deck, composerDeck, "a dismissal-time deck-0 write must be refused")

        p.finishDismissal(token: settle)
        XCTAssertEqual(p.deck, composerDeck,
            "Cancel must leave the user on the deck they opened AI from")
        XCTAssertFalse(p.isFenced, "the fence releases only after the keyboard is gone")
    }

    // ── 4. Cancel before the delayed focus callback fires ───────────

    func testImmediateCancelBeforeDelayedFocusCallbackRejectsIt() {
        var p = onComposerDeck()
        let focus = p.open()
        XCTAssertTrue(p.focusIsCurrent(focus), "fixture: the callback is valid while presenting")

        p.beginDismissal()   // the user cancelled inside the 0.1s window

        XCTAssertFalse(p.focusIsCurrent(focus),
            "a focus callback belonging to a cancelled presentation must raise nothing")
    }

    // ── 5. A stale callback from an older presentation ──────────────

    func testStaleFocusCallbackFromAnOlderPresentationIsRejected() {
        var p = onComposerDeck()
        let older = p.open()
        let settle = p.beginDismissal()
        p.finishDismissal(token: settle)

        let newer = p.open()

        XCTAssertFalse(p.focusIsCurrent(older),
            "the older presentation's callback must not raise the keyboard for the newer one")
        XCTAssertTrue(p.focusIsCurrent(newer), "the current presentation's callback is valid")
        XCTAssertNotEqual(older, newer, "tokens must be monotonic, not reused")

        // And a settle callback from the superseded presentation cannot release
        // the newer presentation's fence.
        p.finishDismissal(token: settle)
        XCTAssertTrue(p.isFenced, "a stale settle callback must not lower a newer fence")
    }

    // ── 6. Normal selection resumes after full release ──────────────

    func testNormalDeckChangesResumeAfterTheFenceIsFullyReleased() {
        var p = onComposerDeck()
        p.open()
        let settle = p.beginDismissal()
        p.finishDismissal(token: settle)

        p.propose(effectsDeck)
        XCTAssertEqual(p.deck, effectsDeck, "an explicit deck change must work again after Cancel")
        p.propose(1)
        XCTAssertEqual(p.deck, 1, "and keep working")
    }

    // ── 7. The full device sequence, asserted at EVERY step ─────────

    /// Composer deck → AI tapped → overlay opens → keyboard rises (the pager
    /// proposes 0, repeatedly, as SwiftUI re-lays out) → Cancel → keyboard
    /// leaves (more proposals) → settled. A final-state-only assertion would
    /// miss an intermediate Effects flash, so every step is checked.
    func testKeyboardRelayoutTraceNeverLeavesTheComposerDeck() {
        var p = onComposerDeck()
        var trace: [Int] = []

        p.open();                       trace.append(p.deck)
        p.propose(effectsDeck);         trace.append(p.deck)   // keyboardWillShow relayout
        p.propose(effectsDeck);         trace.append(p.deck)   // and again on the next pass
        p.propose(1);                   trace.append(p.deck)   // a mid-animation intermediate
        let settle = p.beginDismissal();trace.append(p.deck)   // Cancel
        p.propose(effectsDeck);         trace.append(p.deck)   // keyboardWillHide relayout
        p.finishDismissal(token: settle);trace.append(p.deck)

        XCTAssertEqual(trace, Array(repeating: composerDeck, count: 7),
            "the user must stay on the Composer deck at every step: \(trace)")
        XCTAssertFalse(p.isFenced, "and end with ordinary selection restored")
    }

    // ── 8. Opening mutates nothing else ─────────────────────────────

    /// `StudioAIPresentation` holds no reference to `StudioViewModel`, the
    /// orchestrator, or any transport API, so "opening the AI composer performs
    /// zero playback mutations" is true BY CONSTRUCTION — there is nothing
    /// reachable from `open()` that could start, stop or retarget anything.
    /// (No claim is made here about reading a mounted `StudioView`'s private
    /// view model; that is not possible and is not attempted.) What this pins
    /// is the rest of the mutation surface.
    func testOpeningTouchesOnlyPresentationStateAndPreservesTheDraft() {
        var p = onComposerDeck()
        p.promptText = "ocean calm with soft pulse"
        let before = p

        p.open()

        XCTAssertEqual(p.deck, before.deck, "open() must not move the deck")
        XCTAssertEqual(p.promptText, before.promptText, "open() must not touch the draft")
        XCTAssertNotEqual(p, before, "…but it IS a state change: phase, origin and token")

        let settle = p.beginDismissal()
        p.finishDismissal(token: settle)
        XCTAssertEqual(p.promptText, "ocean calm with soft pulse",
            "a draft the caller did not clear must survive the whole presentation")
        XCTAssertEqual(p.deck, composerDeck)
    }

    // ── 9. A teardown forced by the region taking over ──────────────

    /// The customization region unmounts the deck ZStack — pager AND overlay —
    /// and it can do so while the composer is open (the rolodex and the "Live
    /// Controls" pill both sit outside the overlay and both call
    /// `expandMixer()`). Only `finishDismissal` lowers the fence, so a takeover
    /// that skipped the teardown would leave the pager fenced forever: every
    /// deck pill and every swipe refused until a relaunch. The takeover
    /// therefore runs the SAME ordered teardown, keeping the draft — the user
    /// never cancelled.
    func testRegionTakeoverTeardownReleasesTheFenceAndKeepsTheDraft() {
        var p = onComposerDeck()
        p.promptText = "sunset over the water"
        p.open()

        // `dismissAIComposer(clearingDraft: false)` in production is exactly
        // this pair, and nothing here clears the draft.
        let settle = p.beginDismissal()
        p.finishDismissal(token: settle)

        XCTAssertFalse(p.isFenced,
            "a takeover that leaves the fence up locks deck navigation permanently")
        XCTAssertEqual(p.phase, .idle)
        XCTAssertEqual(p.promptText, "sunset over the water",
            "a takeover is not a cancel — the draft survives")

        p.propose(effectsDeck)
        XCTAssertEqual(p.deck, effectsDeck, "and ordinary deck selection works again")
    }

    // ── 10. Guards on the reducer's own edges ───────────────────────

    func testOutOfOrderTransitionsAreInert() {
        var p = onComposerDeck()

        // finishDismissal without a dismissal in flight.
        p.finishDismissal(token: 99)
        XCTAssertEqual(p.phase, .idle)
        XCTAssertFalse(p.isFenced)

        // beginDismissal without a presentation.
        let token = p.beginDismissal()
        XCTAssertEqual(p.phase, .idle, "there was nothing to dismiss")
        XCTAssertFalse(p.focusIsCurrent(token), "and nothing to focus")
    }
}

// ─────────────────────────────────────────────────────────────────────────
// N1c — AI composer keyboard-layout stabilization.
//
// THE DEVICE DEFECT (build 50, Brian): N1b held the deck — Composer stayed
// selected as the keyboard rose — but the expanded panel collapsed. Header,
// prompt field, suggestion chips, Cancel and Generate shared the same
// vertical space, deck content showed through, and tap targets were
// ambiguous. The keyboard was BELOW the panel, so this was never the keyboard
// covering the buttons.
//
// The mechanism is arithmetic. The panel is a child of Zone B, which is
// `.frame(maxHeight: .infinity)` among VStack siblings that all hold
// intrinsic heights, inside a root GeometryReader that honestly shrinks with
// the keyboard. With the keyboard up the region offers roughly 150pt; the
// rows need roughly 220pt; and a VStack handed less than its ideal compresses
// rows that — being fixed-padding capsules and a `reservesSpace` field —
// cannot compress, so they overlap. The old `.frame(minHeight: 146)` was a
// MINIMUM below what the region was already offering: it never bound, and
// changing that number alone would have fixed nothing.
//
// These tests drive `StudioAIComposerLayout` — the same metrics and the same
// `fit(availableHeight:)` the production panel consumes. They prove the
// POLICY, not the pixels: no unit test here claims anything about exact
// physical rendering, which only Brian's device pass can show.
// ─────────────────────────────────────────────────────────────────────────
@MainActor
final class StudioAIComposerLayoutTests: XCTestCase {

    private typealias L = StudioAIComposerLayout

    // ── 1. A roomy region seats everything, nothing scrolls ─────────

    func testNormalAvailableHeightSelectsTheCompleteNonScrollingLayout() {
        XCTAssertEqual(L.fit(availableHeight: L.idealHeight), .full)
        XCTAssertEqual(L.fit(availableHeight: L.idealHeight + 200), .full)
    }

    // ── 2. A keyboard-constrained region falls back, never compresses ─

    func testKeyboardConstrainedHeightSelectsTheScrollFallback() {
        // Zone B with the keyboard up, measured in the shape the device hit.
        let constrained = L.idealHeight - 60
        guard case let .scrolling(contentHeight) = L.fit(availableHeight: constrained) else {
            return XCTFail("a region below ideal must scroll, not compress into overlap")
        }
        XCTAssertLessThan(contentHeight, L.idealHeight - L.fixedChromeHeight,
            "the fallback must actually give up middle height")
        XCTAssertGreaterThanOrEqual(contentHeight, L.minimumContentHeight)
    }

    // ── 3. The fallback keeps dedicated space for all three regions ──

    func testFallbackPreservesDedicatedSpaceForHeaderContentAndActionRow() {
        for available in stride(from: CGFloat(80), through: L.idealHeight, by: 17) {
            let content: CGFloat
            switch L.fit(availableHeight: available) {
            case .full:                       content = L.idealHeight - L.fixedChromeHeight
            case .scrolling(let c):           content = c
            }
            XCTAssertGreaterThanOrEqual(content, L.minimumContentHeight,
                "at \(available)pt the prompt field lost its own space")
            XCTAssertGreaterThan(L.headerHeight, 0, "the header is never zero-height")
            XCTAssertGreaterThan(L.actionRowHeight, 0, "the action row is never zero-height")
            // The three regions are additive, never overlapping allocations.
            XCTAssertGreaterThanOrEqual(
                L.headerHeight + content + L.actionRowHeight,
                L.headerHeight + L.minimumContentHeight + L.actionRowHeight)
        }
    }

    // ── 4. The legacy compact allocation is rejected ─────────────────

    /// ~146pt was the expanded branch's old `minHeight`, carried over from the
    /// compact hero era. It is not enough for the expanded panel, and the
    /// policy must say so rather than seat everything and overlap.
    func testLegacyCompactAllocationIsRejectedAsInsufficient() {
        XCTAssertNotEqual(L.fit(availableHeight: 146), .full,
            "146pt must never select the complete non-scrolling layout")
        XCTAssertGreaterThan(L.idealHeight, 146,
            "the expanded panel's ideal height must exceed the legacy compact number")
        XCTAssertGreaterThan(L.minimumHeight, L.fixedChromeHeight,
            "the floor must reserve middle space, not just chrome")
    }

    // ── 5. The action row is outside the scrolling region ────────────

    /// Structural guard, supplementing (not replacing) the policy tests: the
    /// production panel's Cancel/Generate row must be a sibling of the
    /// ScrollView, never inside it.
    func testActionRowIsNotInsideTheScrollableMiddle() throws {
        let source = try Self.studioViewSource()
        // Bound the window on the REAL property boundaries, so the guard cannot
        // pass vacuously by stopping short of the row it is checking.
        let open = try XCTUnwrap(source.range(of: "private var aiComposerPanel"))
        let close = try XCTUnwrap(
            source.range(of: "private var aiComposerContent", range: open.upperBound..<source.endIndex))
        let body = String(source[open.upperBound..<close.lowerBound])

        XCTAssertTrue(body.contains("ScrollView(showsIndicators: false) { aiComposerContent }"),
            "the scroll fallback must wrap ONLY the extracted middle")
        XCTAssertTrue(body.contains("StudioAIComposerLayout.actionRowHeight"),
            "the action row must claim its own fixed height outside the scroll")
        XCTAssertTrue(body.contains("StudioAIComposerLayout.headerHeight"),
            "the header must claim its own fixed height outside the scroll")
        // Exactly one ScrollView in the panel, and it is the single-line form
        // wrapping the extracted middle — nothing else can drift inside it.
        XCTAssertEqual(body.components(separatedBy: "ScrollView").count - 1, 1,
            "the panel must contain exactly one ScrollView, around the middle only")
    }

    // ── 6. Presentation does not move the deck ──────────────────────

    func testOverlayPresentationDoesNotChangeTheAcceptedDeck() {
        var p = StudioAIPresentation(deck: 0)
        p.propose(2)
        p.open()
        XCTAssertEqual(p.deck, 2, "opening the layout-corrected overlay must not move the deck")
        XCTAssertTrue(p.isOverlayVisible)
    }

    // ── 7 & 8. Covered content is inert, and recovers on dismissal ───

    func testCoveredLowerContentIsNoninteractiveWhileTheOverlayIsVisible() {
        XCTAssertFalse(L.lowerContentIsInteractive(overlayVisible: true),
            "a tap aimed at Cancel must not reach a deck card behind it")
        XCTAssertTrue(L.lowerContentIsInteractive(overlayVisible: false))
    }

    func testDismissalRestoresOrdinaryLowerContentInteraction() {
        var p = StudioAIPresentation(deck: 0)
        p.propose(2)
        p.open()
        XCTAssertFalse(L.lowerContentIsInteractive(overlayVisible: p.isOverlayVisible))

        let settle = p.beginDismissal()
        XCTAssertTrue(L.lowerContentIsInteractive(overlayVisible: p.isOverlayVisible),
            "the pager takes touches again as soon as the overlay leaves")
        p.finishDismissal(token: settle)
        XCTAssertEqual(p.deck, 2, "and the user is still on the Composer deck")
    }

    // ── source access for the structural guard ──────────────────────

    private static func studioViewSource() throws -> String {
        // HueHomeTests runs from the repo's build products; walk up to the
        // checkout the same way the guards script does.
        var dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // HueHomeTests
            .deletingLastPathComponent()   // repo root
        let path = dir.appendingPathComponent("HueHome/UI/Studio/StudioView.swift")
        dir = path
        return try String(contentsOf: path, encoding: .utf8)
    }
}

// ─────────────────────────────────────────────────────────────────────────
// N1d — AI focus retention and content-sized card.
//
// DEVICE EVIDENCE (build 51, Brian). N1b and N1c held: no Effects redirect,
// Composer stays selected. Two failures remained.
//
// FAIL 1, focus: tapping the prompt began to raise the keyboard and it
// immediately fell back down, so nothing could be typed. The evidence
// suggests that the keyboard-driven layout-mode transition replaced or
// remounted the focused TextField, causing focus loss; the exact
// focus-clearing event was not directly observed. What IS directly visible in
// the build-51 source is the shape that would cause it: the panel's middle
// was a `switch fit { case .full: … case .scrolling: … }` — a
// `_ConditionalContent` whose two branches each carried their OWN TextField.
// The keyboard's rise shrinks the region, `fit` flips, and SwiftUI tears down
// the branch holding the first responder and inserts a different one.
//
// FAIL 2, card size: the card filled the whole Studio region with a large
// empty middle. Its root was a `GeometryReader`, which always accepts every
// point its parent proposes, and the middle carried
// `.frame(maxHeight: .infinity)`. Height was taken because it was available,
// not because anything needed it.
//
// These tests drive `StudioAIComposerLayout.card(…)` — the production sizing
// policy the panel consumes — plus a structural guard over the real source.
// They prove POLICY and STRUCTURE. No test here claims anything about
// physical keyboard rendering; only Brian's device pass can show that.
// ─────────────────────────────────────────────────────────────────────────
@MainActor
final class StudioAIComposerCardTests: XCTestCase {

    private typealias L = StudioAIComposerLayout

    private func metrics(
        available: CGFloat, suggestions: Bool = true, status: Bool = false
    ) -> L.CardMetrics {
        L.card(availableHeight: available, hasSuggestions: suggestions, hasStatusContent: status)
    }

    // ── 1. Content-sized, not parent-sized ──────────────────────────

    func testNormalAvailableHeightRendersTheIdealContentHeightNotTheFullRegion() {
        let m = metrics(available: 500)
        XCTAssertEqual(m.renderedHeight, m.idealHeight,
            "a roomy region must render the card at its CONTENT height")
        XCTAssertLessThan(m.renderedHeight, 500,
            "the card must not take 500pt merely because 500pt was offered")
        XCTAssertFalse(m.scrolls, "nothing needs to scroll when everything fits")
    }

    /// The policy must be flat in available height once the ideal fits — the
    /// exact "no empty-fill" invariant.
    func testMoreParentHeightNeverGrowsTheCard() {
        let base = metrics(available: 400).renderedHeight
        for available in [CGFloat(500), 700, 1200, 4000] {
            XCTAssertEqual(metrics(available: available).renderedHeight, base,
                "the card grew to \(available)pt of offered height")
        }
    }

    // ── 2. Constrained: cap to the safe height and scroll the middle ─

    func testConstrainedHeightCapsTheCardAndScrollsTheMiddle() {
        let ideal = metrics(available: 1000).idealHeight
        let squeezed = ideal - 70
        let m = metrics(available: squeezed)

        XCTAssertEqual(m.renderedHeight, squeezed,
            "below ideal the card must cap to the keyboard-safe height")
        XCTAssertTrue(m.scrolls, "and the middle must scroll rather than compress")
        XCTAssertGreaterThanOrEqual(m.contentHeight, L.minimumContentHeight,
            "the prompt field keeps its own space at every height")
    }

    // ── 3. Optional content changes the ideal height ─────────────────

    func testRemovingOptionalContentShrinksTheIdealCard() {
        let full = metrics(available: 1000, suggestions: true, status: true).idealHeight
        let noStatus = metrics(available: 1000, suggestions: true, status: false).idealHeight
        let bare = metrics(available: 1000, suggestions: false, status: false).idealHeight

        XCTAssertLessThan(noStatus, full, "dropping the status row must shrink the card")
        XCTAssertLessThan(bare, noStatus, "dropping the suggestion strip must shrink it again")
        XCTAssertEqual(full - noStatus, L.rowSpacing + L.statusRowHeight,
            "the status row costs exactly its own height plus one gap")
        XCTAssertEqual(noStatus - bare, L.rowSpacing + L.suggestionRowHeight)
    }

    /// The worked example from the packet.
    func testWorkedExample() {
        let m = metrics(available: 500)
        XCTAssertEqual(m.renderedHeight, m.idealHeight)
        XCTAssertEqual(m.contentHeight, m.idealHeight - L.fixedChromeHeight)
        XCTAssertNotEqual(m.renderedHeight, 500)
    }

    // ── 4. A degenerate first layout pass never yields a zero card ────

    func testZeroAvailableHeightFallsBackToTheIdealRatherThanCollapsing() {
        let m = metrics(available: 0)
        XCTAssertEqual(m.renderedHeight, m.idealHeight,
            "a GeometryReader's first pass reports 0; the card must not vanish")
        XCTAssertFalse(m.scrolls)
    }

    // ── 5 & 7. ONE prompt hierarchy, in the real production source ────

    /// The build-51 defect shape, guarded structurally: the prompt subtree
    /// must not be duplicated across mutually exclusive layout branches, and
    /// scrolling must be a CONFIGURATION rather than a branch replacement.
    func testPromptHierarchyIsNotDuplicatedAcrossLayoutBranches() throws {
        let source = try Self.studioViewSource()
        let open = try XCTUnwrap(source.range(of: "private var aiComposerPanel"))
        let close = try XCTUnwrap(
            source.range(of: "private func composerGrid", range: open.upperBound..<source.endIndex))
        let region = String(source[open.upperBound..<close.lowerBound])

        XCTAssertEqual(region.components(separatedBy: "TextField(").count - 1, 1,
            "exactly ONE TextField may exist in the composer panel + card + content")
        XCTAssertEqual(region.components(separatedBy: ".focused($aiPromptFocused)").count - 1, 1,
            "exactly ONE view may bind the AI focus state")
        XCTAssertEqual(region.components(separatedBy: "aiComposerContent").count - 1, 2,
            "the middle is referenced once and declared once — never branched")
        XCTAssertTrue(region.contains(".scrollDisabled("),
            "scrolling must be configured on one container, not switched between two")
        XCTAssertFalse(region.contains("case .full:"),
            "the mutually exclusive full/scrolling content branches must stay gone")
    }

    /// The card must not claim height merely because a parent offers it.
    func testVisibleCardDoesNotUseUnrestrictedVerticalExpansion() throws {
        let source = try Self.studioViewSource()
        let open = try XCTUnwrap(source.range(of: "private func aiComposerCard"))
        let close = try XCTUnwrap(
            source.range(of: "private var aiComposerContent", range: open.upperBound..<source.endIndex))
        let card = String(source[open.upperBound..<close.lowerBound])

        XCTAssertFalse(card.contains("maxHeight: .infinity"),
            "the visible card must be content-sized; only the shield may fill the region")
        XCTAssertTrue(card.contains("metrics.contentHeight"),
            "the middle must take its height from the sizing policy")
    }

    // ── 6. A layout transition disturbs no presentation state ────────

    func testLayoutTransitionDoesNotDisturbThePresentation() {
        var p = StudioAIPresentation(deck: 0)
        p.propose(2)
        let focus = p.open()
        let before = p

        // The keyboard rises: available height collapses and the sizing policy
        // moves from fitting to constrained. Nothing about the presentation may
        // change — this is a pure layout recomputation.
        let roomy = metrics(available: 500)
        let squeezed = metrics(available: 120)
        XCTAssertNotEqual(roomy, squeezed, "fixture: the modes really do differ")

        XCTAssertEqual(p, before, "a layout transition must not mutate presentation state")
        XCTAssertTrue(p.isOverlayVisible, "it must not close the composer")
        XCTAssertEqual(p.deck, 2, "it must not alter the accepted deck")
        XCTAssertTrue(p.focusIsCurrent(focus),
            "it must not invalidate the token, i.e. must not request focus dismissal")
    }

    // ── 8. Focus lifecycle is unchanged by the sizing work ───────────

    func testOpeningRequestsFocusOnceAndCancelStillClearsIt() {
        var p = StudioAIPresentation(deck: 0)
        p.propose(2)
        let first = p.open()
        XCTAssertTrue(p.focusIsCurrent(first), "opening requests focus exactly once…")

        // No layout event mints a second request.
        _ = metrics(available: 120)
        XCTAssertTrue(p.focusIsCurrent(first), "…and no relayout re-requests it")

        let settle = p.beginDismissal()          // Cancel clears focus first
        XCTAssertFalse(p.focusIsCurrent(first), "Cancel must invalidate the pending request")
        p.finishDismissal(token: settle)

        let second = p.open()
        XCTAssertFalse(p.focusIsCurrent(first), "a stale callback stays rejected")
        XCTAssertTrue(p.focusIsCurrent(second))
    }

    private static func studioViewSource() throws -> String {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("HueHome/UI/Studio/StudioView.swift")
        return try String(contentsOf: path, encoding: .utf8)
    }
}
