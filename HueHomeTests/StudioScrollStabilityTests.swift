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
// MARK: - Track A / C2 — RolodexSelectionMachine extraction
//
// C2 is a MECHANICAL extraction: same arithmetic, same event stream, same
// haptics. These tests cover only the preserved mechanics. Nothing here may
// assert a settling phase, a deliberate activation, a delayed commit, a settle
// token, a watchdog or token-based rebasing — those arrive in C3, and asserting
// them now would make this commit a bad bisect anchor.
// ──────────────────────────────────────────────────────────────────────────

@MainActor
final class RolodexSelectionMachineTests: XCTestCase {

    private let rowHeight: CGFloat = 32
    private let colWidth: CGFloat = 150

    private func machine(
        activeAxis: Axis = .vertical, room: Int = 0, zone: Int = 0
    ) -> RolodexSelectionMachine {
        RolodexSelectionMachine(
            rowHeight: rowHeight, colWidth: colWidth,
            activeAxis: activeAxis, committedRoom: room, committedZone: zone)
    }

    // ── The pre-extraction algorithm, transcribed verbatim ────────────
    //
    // This is `RoomRolodexView`'s gesture code AS IT WAS before C2, kept here
    // as the reference the extraction is measured against. It must not be
    // "cleaned up" — its value is that it is a literal copy.

    private enum LegacyEvent: Equatable {
        case haptic
        case commit(axis: Axis, index: Int)
    }

    private struct LegacyRolodex {
        let rowHeight: CGFloat = 32
        let colWidth: CGFloat = 150
        var selRoom = 0, selZone = 0, liveRoom = 0, liveZone = 0
        var lockAxis: Axis?
        var activeAxis: Axis = .vertical
        var drag: CGFloat = 0
        var roomCount: Int, zoneCount: Int

        private func clampIndex(_ v: CGFloat, _ count: Int) -> Int {
            min(max(Int(v.rounded()), 0), count - 1)
        }

        private var activeIndex: Int { activeAxis == .vertical ? liveRoom : liveZone }

        mutating func onChanged(dx: CGFloat, dy: CGFloat) -> [LegacyEvent] {
            if lockAxis == nil {
                guard abs(dx) > 6 || abs(dy) > 6 else { return [] }
                lockAxis = abs(dx) > abs(dy) ? .horizontal : .vertical
                activeAxis = lockAxis!
            }
            drag = lockAxis == .horizontal ? dx : dy
            // updateLive()
            var newRoom = liveRoom, newZone = liveZone
            if lockAxis == .vertical, roomCount > 0 {
                newRoom = clampIndex(CGFloat(selRoom) - drag / rowHeight, roomCount)
            } else if lockAxis == .horizontal, zoneCount > 0 {
                newZone = clampIndex(CGFloat(selZone) - drag / colWidth, zoneCount)
            }
            guard newRoom != liveRoom || newZone != liveZone else { return [] }
            liveRoom = newRoom; liveZone = newZone
            // HapticManager.selection(), then onSelect(activeItem)
            return [.haptic, .commit(axis: activeAxis, index: activeIndex)]
        }

        mutating func onEnded(pdx: CGFloat, pdy: CGFloat) -> [LegacyEvent] {
            let axis = lockAxis ?? activeAxis
            let step = axis == .horizontal ? colWidth : rowHeight
            let predicted = axis == .horizontal ? pdx : pdy
            let base = axis == .horizontal ? selZone : selRoom
            let count = axis == .horizontal ? zoneCount : roomCount
            guard count > 0 else { lockAxis = nil; drag = 0; return [] }

            let target = min(max(Int((CGFloat(base) - predicted / step).rounded()), 0), count - 1)
            if axis == .horizontal { selZone = target; liveZone = target }
            else { selRoom = target; liveRoom = target }
            drag = 0
            // select(item): the item is on `axis`, so the lookup lands on the
            // same axis and re-writes the same indices — then onSelect, haptic.
            activeAxis = axis
            lockAxis = nil
            return [.commit(axis: axis, index: target), .haptic]
        }
    }

    private func asLegacy(_ effects: [RolodexSelectionMachine.Effect]) -> [LegacyEvent] {
        effects.map {
            switch $0 {
            case .haptic: return .haptic
            case let .commit(axis, index): return .commit(axis: axis, index: index)
            }
        }
    }

    // ── The tests ─────────────────────────────────────────────────────

    /// `liveIndex` must reproduce `clampIndex(CGFloat(base) - drag / step, count)`
    /// bit for bit, including `.rounded()`'s half-away-from-zero behaviour and
    /// the clamp at both ends.
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

        // The clamp's own edges, including the legacy zero-count result.
        XCTAssertEqual(RolodexKinematics.clamp(-5, count: 4), 0)
        XCTAssertEqual(RolodexKinematics.clamp(99, count: 4), 3)
        XCTAssertEqual(RolodexKinematics.clamp(2, count: 0), -1,
            "a zero-count axis still yields -1, exactly as clampIndex did — "
            + "callers guard on a non-empty axis before reaching it")
    }

    /// The settle uses the FLICK (predicted translation), not where the finger
    /// actually stopped. There is no momentum simulation and there never was.
    func testSettleTargetUsesPredictedTranslation() {
        // Finger stopped one detent up; the flick predicts four.
        let live = RolodexKinematics.liveIndex(
            base: 5, translation: 32, step: rowHeight, count: 9)
        let settle = RolodexKinematics.settleTarget(
            base: 5, predicted: 128, step: rowHeight, count: 9)
        XCTAssertEqual(live, 4)
        XCTAssertEqual(settle, 1, "the settle must follow the prediction, not the live translation")
        XCTAssertNotEqual(live, settle)

        // Same expression as the legacy `.onEnded` line, at the clamp edges.
        XCTAssertEqual(
            RolodexKinematics.settleTarget(base: 0, predicted: 9_999, step: colWidth, count: 4), 0)
        XCTAssertEqual(
            RolodexKinematics.settleTarget(base: 3, predicted: -9_999, step: colWidth, count: 4), 3)
    }

    /// Axis capture needs more than 6pt, and once captured it never flips for
    /// the life of the gesture — the guard that keeps a diagonal drag from
    /// jumping between the room and zone wheels mid-scrub.
    func testAxisLockRequiresSixPointsAndNeverFlips() {
        var m = machine()

        XCTAssertTrue(m.apply(.dragChanged(dx: 6, dy: 6), roomCount: 5, zoneCount: 5).isEmpty,
            "exactly 6pt is not more than 6pt — no lock, no effects")
        XCTAssertNil(m.lockAxis)

        XCTAssertTrue(m.apply(.dragChanged(dx: 7, dy: 0), roomCount: 5, zoneCount: 5).isEmpty,
            "locking horizontally does not by itself cross a detent")
        XCTAssertEqual(m.lockAxis, .horizontal)
        XCTAssertEqual(m.activeAxis, .horizontal)

        // A far larger vertical component afterwards must NOT re-lock.
        m.apply(.dragChanged(dx: 7, dy: 400), roomCount: 5, zoneCount: 5)
        XCTAssertEqual(m.lockAxis, .horizontal, "the axis re-locked mid-gesture")
        XCTAssertEqual(m.activeAxis, .horizontal)
        XCTAssertEqual(m.liveRoom, 0, "the vertical wheel must not have moved")
    }

    /// An axis with no items is inert: no detent tick, no settle, no commit —
    /// matching the legacy `!rooms.isEmpty` and `guard count > 0` guards.
    func testZeroCountAxisIsInert() {
        var m = machine()

        XCTAssertTrue(
            m.apply(.dragChanged(dx: 0, dy: 200), roomCount: 0, zoneCount: 0).isEmpty,
            "a zero-count axis emitted a detent tick")
        XCTAssertEqual(m.liveRoom, 0)

        XCTAssertTrue(
            m.apply(.dragEnded(predictedDX: 0, predictedDY: 400), roomCount: 0, zoneCount: 0)
                .isEmpty,
            "a zero-count axis emitted a settle")
        XCTAssertEqual(m.committedRoom, 0)
        XCTAssertEqual(m.translation, 0, "the drag translation still resets")
        XCTAssertNil(m.lockAxis)
    }

    /// THE extraction proof: driven through the same gesture, the machine and
    /// the transcribed pre-extraction algorithm produce an identical event
    /// stream — including the per-detent commit that C2 deliberately preserves.
    func testLegacyEventStreamMatchesPreExtractionBehaviour() {
        let roomCount = 9, zoneCount = 4

        // A drag down across seven detents, then a flick that overshoots.
        let samples: [(CGFloat, CGFloat)] = (0...14).map { (0, CGFloat($0) * -16) }
        let predicted: (CGFloat, CGFloat) = (0, -260)

        var m = machine(room: 7)
        var legacy = LegacyRolodex(roomCount: roomCount, zoneCount: zoneCount)
        legacy.selRoom = 7; legacy.liveRoom = 7

        var fromMachine: [LegacyEvent] = []
        var fromLegacy: [LegacyEvent] = []

        for (dx, dy) in samples {
            fromMachine += asLegacy(
                m.apply(.dragChanged(dx: dx, dy: dy),
                        roomCount: roomCount, zoneCount: zoneCount))
            fromLegacy += legacy.onChanged(dx: dx, dy: dy)
        }

        // The view composes the end of the gesture out of two applies, mirroring
        // the legacy spring-then-`select(_:)` shape.
        m.apply(.dragEnded(predictedDX: predicted.0, predictedDY: predicted.1),
                roomCount: roomCount, zoneCount: zoneCount)
        fromMachine += asLegacy(
            m.apply(.pickerSelect(axis: m.activeAxis, index: m.activeIndex),
                    roomCount: roomCount, zoneCount: zoneCount))
        fromLegacy += legacy.onEnded(pdx: predicted.0, pdy: predicted.1)

        XCTAssertEqual(fromMachine, fromLegacy,
            "the extraction changed the event stream — C2 must be behaviour-identical")
        XCTAssertEqual(m.committedRoom, legacy.selRoom, "committed index diverged")
        XCTAssertEqual(m.liveRoom, legacy.liveRoom, "live index diverged")
        XCTAssertEqual(m.activeAxis, legacy.activeAxis)

        // C2 still commits per detent crossing. That IS the defect, and pinning
        // it here is what makes C3's change visible in the diff rather than
        // smuggled in alongside an extraction.
        let commits = fromMachine.filter { if case .commit = $0 { return true }; return false }
        XCTAssertGreaterThan(commits.count, 1,
            "C2 must preserve per-detent commits — moving them behind settling is C3")
    }

    /// Tokens are minted from the full item identity and are bridge-qualified.
    /// C2 introduces them as DATA only — nothing consults them yet.
    func testTokenMintingIsStableAndBridgeQualified() {
        func item(_ id: String, bridge: String?, kind: RoomDisplayItem.Kind) -> RoomDisplayItem {
            RoomDisplayItem(
                kind: kind, id: id, name: "n", archetype: nil,
                isOn: true, brightness: 50, groupedLightID: nil, lightCount: 1,
                bridgeID: bridge, childResourceRefs: [])
        }

        let onA = item("room-1", bridge: "bridge-a", kind: .room)
        let onB = item("room-1", bridge: "bridge-b", kind: .room)
        let zoneA = item("room-1", bridge: "bridge-a", kind: .zone)

        XCTAssertEqual(RolodexItemToken(item: onA), RolodexItemToken(item: onA),
            "minting must be stable — a token is compared across roster rebuilds")
        XCTAssertNotEqual(RolodexItemToken(item: onA), RolodexItemToken(item: onB),
            "two bridges' same-id rooms must mint different tokens")
        XCTAssertNotEqual(RolodexItemToken(item: onA), RolodexItemToken(item: zoneA),
            "a room and a zone sharing an id must mint different tokens")

        // Mutable display state is not identity: the same resource with a
        // changed name or brightness must still mint the same token.
        var renamed = onA
        renamed.name = "Renamed"
        renamed.brightness = 99
        XCTAssertEqual(RolodexItemToken(item: onA), RolodexItemToken(item: renamed),
            "a rename must not change identity — C3 rebases on these")
    }
}
