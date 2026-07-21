// MusicUISnapshotTests.swift
// HueHome Pro — Unit Tests
//
// Render-crash smoke for the R2 music surfaces: each renders into a real
// UIHostingController at phone width and must produce non-blank pixels.
// The renders attach to the xcresult (.keepAlways) so a human can review
// look/placement without booting the app — the Gate-A review artifact.

import XCTest
import SwiftUI
@testable import HueHome

@MainActor
final class MusicUISnapshotTests: XCTestCase {

    private var tempURL: URL!
    private var defaults: UserDefaults!
    private let suiteName = "MusicUISnapshotTests"

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("music-snap-\(UUID().uuidString).json")
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        // Renders drive the SHARED clock (BeatStatusChip reads it) — reset it.
        BeatClock.shared.clear()
        try? FileManager.default.removeItem(at: tempURL)
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// A coordinator mid-session on the demo playlist (track, tempo, palette).
    /// Uses the SHARED BeatClock so the bar's BeatStatusChip (which reads
    /// BeatClock.shared, as in production) renders the real BPM.
    private func seededSession() async throws -> MusicSessionCoordinator {
        let music = MusicSessionCoordinator(
            clock: BeatClock.shared,
            resolver: TrackTempoResolver(providers: [], fileURL: tempURL,
                                         defaults: defaults, liveEstimate: { (0, 0) })
        )
        try await music.activate(MockMusicSource(hostNow: { 100 }))
        let deadline = Date().addingTimeInterval(2)
        while (music.tempo == nil || music.artworkPalette == nil) && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(music.tempo)
        XCTAssertNotNil(music.artworkPalette)
        return music
    }

    private func render<V: View>(_ view: V, size: CGSize, named name: String) {
        let host = UIHostingController(rootView: view)
        host.view.bounds = CGRect(origin: .zero, size: size)
        host.overrideUserInterfaceStyle = .dark
        host.view.backgroundColor = UIColor(StagePalette.stage)
        host.view.layoutIfNeeded()

        let image = UIGraphicsImageRenderer(size: size).image { _ in
            host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }

        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        // Non-blank check: a broken render comes out one flat color.
        let colors = distinctSampleColors(of: image)
        XCTAssertGreaterThan(colors, 3, "\(name) rendered blank")
    }

    private func distinctSampleColors(of image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 0 }
        let w = 24, h = 24
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: srgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return 0 }
        ctx.interpolationQuality = .none
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return 0 }
        let buf = data.bindMemory(to: UInt32.self, capacity: w * h)
        var seen = Set<UInt32>()
        for i in 0..<(w * h) { seen.insert(buf[i]) }
        return seen.count
    }

    // MARK: - Surfaces

    func testFullBarRenders() async throws {
        let music = try await seededSession()
        render(
            MusicNowPlayingBar(style: .full, onUseAlbumColors: {}, onOpenPicker: {})
                .environment(music)
                .padding(16)
                .background(StagePalette.stage),
            size: CGSize(width: 393, height: 100),
            named: "music-bar-full"
        )
        music.deactivate()
    }

    func testCompactBarRenders() async throws {
        let music = try await seededSession()
        render(
            MusicNowPlayingBar(style: .compact)
                .environment(music)
                .padding(16)
                .background(StagePalette.stage),
            size: CGSize(width: 393, height: 90),
            named: "music-bar-compact"
        )
        music.deactivate()
    }

    func testSourcePickerRenders() async throws {
        let music = try await seededSession()
        let orchestrator = UnifiedOrchestrator()
        render(
            MusicSourcePicker()
                .environment(music)
                .environment(orchestrator),
            size: CGSize(width: 393, height: 640),
            named: "music-source-picker"
        )
        music.deactivate()
    }
}
