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
