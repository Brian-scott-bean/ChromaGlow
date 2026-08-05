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
