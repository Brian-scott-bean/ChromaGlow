// MockMusicSource.swift
// ChromaGlow — Core/Music (music integration R1)
//
// The demo/Simulator music source: a scripted three-track playlist with
// known tempos and generated artwork, so the whole Now Playing → tempo →
// palette → BeatClock pipeline runs with no accounts, no network, and no
// physical device. Also the fixture for MusicSourceContractTests.

import Foundation
import CoreGraphics
import QuartzCore

@MainActor
final class MockMusicSource: MusicSource {

    struct DemoTrack {
        var title: String
        var artist: String
        var durationMs: Int
        var bpm: Double
        /// Two artwork gradient stops (linear sRGB 0–1).
        var art: (top: (r: Double, g: Double, b: Double),
                  bottom: (r: Double, g: Double, b: Double))
    }

    static let playlist: [DemoTrack] = [
        DemoTrack(title: "Golden Hour", artist: "Ava Lane", durationMs: 30_000, bpm: 96,
                  art: (top: (0.98, 0.62, 0.20), bottom: (0.85, 0.25, 0.45))),
        DemoTrack(title: "Neon Skyline", artist: "Midnight Drive", durationMs: 30_000, bpm: 120,
                  art: (top: (0.15, 0.85, 0.90), bottom: (0.75, 0.20, 0.90))),
        DemoTrack(title: "Tidal Bloom", artist: "Coral Fields", durationMs: 30_000, bpm: 128,
                  art: (top: (0.20, 0.80, 0.65), bottom: (0.08, 0.25, 0.60))),
    ]

    let service: MusicService = .demo
    let capabilities: SourceCapabilities = [.transport, .position, .artwork]
    var onUpdate: ((NowPlayingTrack?, PlaybackPosition?) -> Void)?

    private(set) var trackIndex = 0
    private var accumulatedMs = 0
    private var playingSince: Double?
    private var tickTask: Task<Void, Never>?
    /// Injectable clock for deterministic tests.
    private let hostNow: () -> Double

    init(hostNow: @escaping () -> Double = { CACurrentMediaTime() }) {
        self.hostNow = hostNow
    }

    var currentTrack: DemoTrack { Self.playlist[trackIndex] }

    func start() async throws {
        playingSince = hostNow()
        emit()
        startTicking()
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
        playingSince = nil
        accumulatedMs = 0
        onUpdate?(nil, nil)
    }

    func transport(_ action: TransportAction) async {
        switch action {
        case .play:
            guard playingSince == nil else { break }
            playingSince = hostNow()
            startTicking()
        case .pause:
            pauseInternal()
        case .togglePlayPause:
            if playingSince == nil { await transport(.play) } else { pauseInternal() }
        case .nextTrack:
            advance(by: 1)
        case .previousTrack:
            advance(by: Self.playlist.count - 1)
        }
        emit()
    }

    func artworkImage() async -> CGImage? {
        Self.generatedArtwork(for: currentTrack)
    }

    // MARK: - Internals

    private func pauseInternal() {
        if let since = playingSince {
            accumulatedMs += Int((hostNow() - since) * 1000)
            playingSince = nil
        }
        tickTask?.cancel()
        tickTask = nil
    }

    private func advance(by steps: Int) {
        trackIndex = (trackIndex + steps) % Self.playlist.count
        accumulatedMs = 0
        if playingSince != nil { playingSince = hostNow() }
    }

    private var positionMs: Int {
        var ms = accumulatedMs
        if let since = playingSince { ms += Int((hostNow() - since) * 1000) }
        return ms
    }

    /// Advance to the next track when the current one ends, then report.
    private func emit() {
        if positionMs >= currentTrack.durationMs { advance(by: 1) }
        let track = currentTrack
        onUpdate?(
            NowPlayingTrack(service: .demo, title: track.title, artist: track.artist,
                            durationMs: track.durationMs, tempoHint: track.bpm),
            PlaybackPosition(positionMs: positionMs, capturedAt: hostNow(),
                             isPlaying: playingSince != nil)
        )
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.emit()
            }
        }
    }

    // MARK: - Generated artwork

    /// Deterministic vertical two-stop gradient, 64×64 RGBA8.
    static func generatedArtwork(for track: DemoTrack) -> CGImage? {
        let size = 64
        guard let ctx = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let colors = [
            CGColor(red: track.art.top.r, green: track.art.top.g, blue: track.art.top.b, alpha: 1),
            CGColor(red: track.art.bottom.r, green: track.art.bottom.g, blue: track.art.bottom.b, alpha: 1),
        ] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: colors, locations: [0, 1]) else { return nil }
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: 0),
                               end: CGPoint(x: 0, y: size),
                               options: [])
        return ctx.makeImage()
    }
}
