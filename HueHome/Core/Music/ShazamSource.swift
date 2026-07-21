// ShazamSource.swift
// ChromaGlow — Core/Music (music integration R4)
//
// Auto-detect: continuous ShazamKit identification of whatever is audible
// in the room — the universal source, and the honest Pandora answer. Feeds
// SHSession from AudioAnalysisEngine's buffer tap so the engine stays the
// single AVAudioSession owner (its header contract), holding the
// `.shazamID` demand like Perform holds `.performance`.
//
// The killer datum is `predictedCurrentMatchOffset`: the predicted current
// position INSIDE the identified track — position + a sidecar BPM gives a
// beat-locked grid for any audible source. Privacy note: ShazamKit builds
// an on-device audio signature and matches it against the Shazam catalog;
// raw audio still never leaves the process.
//
// Device-only in practice: the Simulator has no ShazamKit inference (same
// class as the VisionKit/CIDetector rule in AGENTS.md).

import Foundation
import ShazamKit
import QuartzCore

// MARK: - Pure seams (testable without ShazamKit values)

struct ShazamMatchSnapshot: Equatable {
    var title: String
    var artist: String
    var isrc: String?
    var appleMusicID: String?
    var artworkURL: URL?
    var predictedOffsetSeconds: TimeInterval

    func track() -> NowPlayingTrack {
        NowPlayingTrack(
            service: .shazamDetected,
            title: title,
            artist: artist,
            isrc: isrc,
            appleMusicID: appleMusicID,
            artworkURL: artworkURL
        )
    }

    func position(capturedAt: Double) -> PlaybackPosition {
        PlaybackPosition(
            positionMs: max(0, Int((predictedOffsetSeconds * 1000).rounded())),
            capturedAt: capturedAt,
            isPlaying: true   // Shazam only ever matches audio that is playing
        )
    }
}

/// When to admit the song is gone: ShazamKit reports a no-match every few
/// seconds of unrecognized audio; a few in a row while a track is showing
/// means it ended (or the room went quiet).
struct ShazamMissPolicy: Equatable {
    var missesToClear = 6
    private(set) var consecutiveMisses = 0

    mutating func recordMatch() {
        consecutiveMisses = 0
    }

    /// Returns true when the current track should be cleared.
    mutating func recordMiss() -> Bool {
        consecutiveMisses += 1
        if consecutiveMisses >= missesToClear {
            consecutiveMisses = 0
            return true
        }
        return false
    }
}

// MARK: - ShazamSource

@MainActor
final class ShazamSource: NSObject, MusicSource {

    let service: MusicService = .shazamDetected
    let capabilities: SourceCapabilities = [.artwork, .position]
    var onUpdate: ((NowPlayingTrack?, PlaybackPosition?) -> Void)?

    private static let tapID = "shazam-id"

    /// SHSession isn't Sendable; the audio-thread tap only calls the
    /// documented-thread-safe matchStreamingBuffer.
    private final class SessionBox: @unchecked Sendable {
        let session: SHSession
        init(_ session: SHSession) { self.session = session }
    }

    private var sessionBox: SessionBox?
    private var missPolicy = ShazamMissPolicy()
    private var currentTrack: NowPlayingTrack?

    func start() async throws {
        guard await AudioAnalysisEngine.shared.setDemand(.shazamID, active: true) else {
            throw MusicSourceError.unavailable("microphone")
        }
        let session = SHSession()
        session.delegate = self
        let box = SessionBox(session)
        sessionBox = box
        AudioAnalysisEngine.addBufferTap(id: Self.tapID) { buffer, _ in
            // Audio thread: matchStreamingBuffer is documented safe here and
            // cheap (signature accumulation; matching happens elsewhere).
            box.session.matchStreamingBuffer(buffer, at: nil)
        }
    }

    func stop() {
        AudioAnalysisEngine.removeBufferTap(id: Self.tapID)
        sessionBox?.session.delegate = nil
        sessionBox = nil
        currentTrack = nil
        Task { await AudioAnalysisEngine.shared.setDemand(.shazamID, active: false) }
    }

    func transport(_ action: TransportAction) async {
        // Listening along — nothing to control.
    }

    // MARK: - Match handling (hopped to MainActor from the delegate)

    fileprivate func handle(snapshot: ShazamMatchSnapshot) {
        missPolicy.recordMatch()
        let track = snapshot.track()
        currentTrack = track
        onUpdate?(track, snapshot.position(capturedAt: CACurrentMediaTime()))
    }

    fileprivate func handleMiss() {
        guard currentTrack != nil else { return }
        if missPolicy.recordMiss() {
            currentTrack = nil
            onUpdate?(nil, nil)
        }
    }
}

// MARK: - SHSessionDelegate

extension ShazamSource: SHSessionDelegate {

    nonisolated func session(_ session: SHSession, didFind match: SHMatch) {
        guard let item = match.mediaItems.first else { return }
        let snapshot = ShazamMatchSnapshot(
            title: item.title ?? "Unknown Song",
            artist: item.artist ?? "",
            isrc: item.isrc,
            appleMusicID: item.appleMusicID,
            artworkURL: item.artworkURL,
            predictedOffsetSeconds: item.predictedCurrentMatchOffset
        )
        Task { @MainActor in self.handle(snapshot: snapshot) }
    }

    nonisolated func session(
        _ session: SHSession,
        didNotFindMatchFor signature: SHSignature,
        error: Error?
    ) {
        Task { @MainActor in self.handleMiss() }
    }
}
