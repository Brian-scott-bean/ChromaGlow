// SpotifyPCMExperimentTests.swift
// LOCAL-ONLY Spotify Connect PCM experiment. Compiles (and runs) only in the
// Debug-SpotifyExperimental configuration:
//   xcodebuild test -scheme "HueHome Spotify Experimental" …
// Covers source switching, the receiver→analysis router gates, playout delay,
// stall silence, no-persistence, the C ABI layout, real start/stop cycles of
// the Rust receiver (it advertises "… (test)" on the LAN for ~a second), and
// Phase 2 playback: the output's lifecycle, the render pull, light offset.

#if CHROMAGLOW_EXPERIMENTAL_SPOTIFY

import AVFoundation
import ChromaGlowSpotifyFFI
import QuartzCore
import XCTest
@testable import HueHome

@MainActor
final class SpotifyPCMExperimentTests: XCTestCase {

    private var events: [String] = []
    private var sources: [RecordingAudioSource] = []
    private let center = NotificationCenter()

    override func setUp() async throws {
        events = []
        sources = []
        SpotifyPCMRouter.shared.setReceiverGeneration(0)
        SpotifyPCMRouter.shared.closeGate()
        SpotifyPCMRouter.shared.setUserOffset(0)
        SpotifyPCMRouter.shared.setOutputLatency(0)
    }

    override func tearDown() async throws {
        SpotifyPCMRouter.shared.setReceiverGeneration(0)
        SpotifyPCMRouter.shared.closeGate()
    }

    private func recordingEngine() -> AudioAnalysisEngine {
        AudioAnalysisEngine(makeSource: { [unowned self] kind in
            let s = RecordingAudioSource(kind: kind, id: self.sources.count) { [unowned self] in
                self.events.append($0)
            }
            self.sources.append(s)
            return s
        }, notificationCenter: center)
    }

    /// An engine wired to the REAL SpotifyPCMSource (the router singleton) and
    /// a recording stand-in for the microphone (no permission prompt in tests).
    private func spotifyEngine() async -> AudioAnalysisEngine {
        let engine = AudioAnalysisEngine(makeSource: { [unowned self] kind in
            guard kind == .microphone else { return AudioAnalysisEngine.defaultSource(kind) }
            let s = RecordingAudioSource(kind: kind, id: self.sources.count) { [unowned self] in
                self.events.append($0)
            }
            self.sources.append(s)
            return s
        }, notificationCenter: center)
        await engine.selectSource(.spotifyConnect)
        let started = await engine.setDemand(.composerReaction, active: true)
        XCTAssertTrue(started)
        return engine
    }

    /// Interleaved stereo chunk of the synthetic tone (same in both channels).
    private func stereoChunk(frames: Int = 1024) -> [Float] {
        syntheticMono(frames: frames).flatMap { [$0, $0] }
    }

    private func route(_ generation: UInt64, queued: UInt32 = 0, frames: Int = 1024) {
        let chunk = stereoChunk(frames: frames)
        chunk.withUnsafeBufferPointer { buf in
            SpotifyPCMRouter.shared.route(generation: generation, samples: buf.baseAddress!,
                                          frames: UInt32(frames), channels: 2,
                                          sampleRate: 44_100, queuedFrames: queued)
        }
    }

    // MARK: - Source switching

    func testDefaultFactoryBuildsTheSpotifySource() {
        XCTAssertTrue(AudioAnalysisEngine.defaultSource(.spotifyConnect) is SpotifyPCMSource)
    }

    func testSwitchingStopsThePreviousSourceBeforeStartingTheNext() async throws {
        let engine = recordingEngine()
        await engine.setDemand(.composerReaction, active: true)
        let micSink = try XCTUnwrap(sources.last?.sink)

        let onSpotify = await engine.selectSource(.spotifyConnect)
        XCTAssertTrue(onSpotify)
        XCTAssertFalse(micSink.isCurrent, "the outgoing source's sink is dead")
        XCTAssertEqual(events, [
            "prepare:microphone#0", "start:microphone#0",
            "stop:microphone#0", "prepare:spotifyConnect#1", "start:spotifyConnect#1",
        ])

        events = []
        let spotifySink = try XCTUnwrap(sources.last?.sink)
        await engine.selectSource(.microphone)
        XCTAssertFalse(spotifySink.isCurrent)
        XCTAssertEqual(events, ["stop:spotifyConnect#1", "prepare:microphone#2", "start:microphone#2"])
        await engine.setDemand(.composerReaction, active: false)
    }

    func testSelectingWithoutDemandOnlyRecordsTheChoice() async {
        let engine = recordingEngine()
        let running = await engine.selectSource(.spotifyConnect)
        XCTAssertFalse(running)
        XCTAssertEqual(engine.sourceKind, .spotifyConnect)
        XCTAssertTrue(sources.isEmpty, "nothing starts until a Live look asks for audio")
    }

    // MARK: - Router gates

    func testRouterFeedsAnalysisOnlyForTheLiveReceiverGeneration() async {
        let engine = await spotifyEngine()
        SpotifyPCMRouter.shared.setReceiverGeneration(5)

        route(4)
        XCTAssertEqual(AudioAnalysisEngine.latestFeatures().rawOverall, 0, "stale receiver generation dropped")

        route(5)
        let live = AudioAnalysisEngine.latestFeatures()
        XCTAssertGreaterThan(live.rawOverall, 0.05)
        XCTAssertGreaterThan(live.rawBass, 0, "80 Hz tone lands in the bass band")

        SpotifyPCMRouter.shared.setReceiverGeneration(0)   // Stop pressed
        XCTAssertEqual(AudioAnalysisEngine.latestFeatures().rawOverall, 0, "stop publishes silence instantly")
        route(5)
        XCTAssertEqual(AudioAnalysisEngine.latestFeatures().rawOverall, 0, "late callbacks after stop are dropped")
        XCTAssertGreaterThanOrEqual(SpotifyPCMRouter.shared.snapshot().chunksDropped, 2)
        await engine.setDemand(.composerReaction, active: false)
    }

    func testClosedGateDropsPCMWhenAnalysisIsOnTheMicrophone() async {
        let engine = await spotifyEngine()
        SpotifyPCMRouter.shared.setReceiverGeneration(9)
        await engine.selectSource(.microphone)   // closes the Spotify gate
        route(9)
        XCTAssertFalse(SpotifyPCMRouter.shared.snapshot().gateOpen)
        XCTAssertEqual(AudioAnalysisEngine.latestFeatures().rawOverall, 0)
        await engine.setDemand(.composerReaction, active: false)
    }

    func testHopsAreAnalyzedPerThousandTwentyFourFrames() async {
        let engine = await spotifyEngine()
        SpotifyPCMRouter.shared.setReceiverGeneration(3)
        let before = SpotifyPCMRouter.shared.snapshot().hopsAnalyzed
        for _ in 0..<5 { route(3, frames: 700) }   // 3500 frames
        XCTAssertEqual(SpotifyPCMRouter.shared.snapshot().hopsAnalyzed - before, 3)
        await engine.setDemand(.composerReaction, active: false)
    }

    // MARK: - Delay / offset

    func testUserOffsetDelaysTheLights() async throws {
        let engine = await spotifyEngine()
        SpotifyPCMRouter.shared.setReceiverGeneration(11)
        SpotifyPCMRouter.shared.setUserOffset(0.2)
        route(11)
        XCTAssertEqual(SpotifyPCMRouter.shared.snapshot().presentationDelay, 0.2, accuracy: 0.001)
        XCTAssertEqual(AudioAnalysisEngine.latestFeatures().rawOverall, 0, "held for the offset")
        try await Task.sleep(for: .milliseconds(260))
        XCTAssertGreaterThan(AudioAnalysisEngine.latestFeatures().rawOverall, 0.05)
        await engine.setDemand(.composerReaction, active: false)
    }

    func testPlayoutQueueAndRouteLatencyAddUp() async {
        let engine = await spotifyEngine()
        SpotifyPCMRouter.shared.setReceiverGeneration(12)
        SpotifyPCMRouter.shared.setOutputLatency(0.1)
        route(12, queued: 22_050)   // half a second queued
        XCTAssertEqual(SpotifyPCMRouter.shared.snapshot().presentationDelay, 0.6, accuracy: 0.001)
        SpotifyPCMRouter.shared.setUserOffset(-5)
        route(12, queued: 22_050)
        XCTAssertEqual(SpotifyPCMRouter.shared.snapshot().presentationDelay, 0, accuracy: 0.001,
                       "lights can lead, but never before the audio exists")
        await engine.setDemand(.composerReaction, active: false)
    }

    /// Once music plays, the route's latency counts even while the ring is
    /// momentarily empty — the delay must not collapse to 0 on an underrun.
    func testRouteLatencyCountsWithAnEmptyQueue() async {
        let engine = await spotifyEngine()
        SpotifyPCMRouter.shared.setReceiverGeneration(14)
        SpotifyPCMRouter.shared.setOutputLatency(0.15)
        route(14, queued: 0)
        XCTAssertEqual(SpotifyPCMRouter.shared.snapshot().presentationDelay, 0.15, accuracy: 0.001)
        await engine.setDemand(.composerReaction, active: false)
    }

    func testStalledStreamSettlesToSilence() async {
        let engine = await spotifyEngine()
        SpotifyPCMRouter.shared.setReceiverGeneration(13)
        route(13)
        XCTAssertGreaterThan(AudioAnalysisEngine.latestFeatures().rawOverall, 0.05)
        SpotifyPCMRouter.shared.silenceIfStalled(now: CACurrentMediaTime() + 0.1)
        XCTAssertGreaterThan(AudioAnalysisEngine.latestFeatures().rawOverall, 0.05, "not stalled yet")
        SpotifyPCMRouter.shared.silenceIfStalled(now: CACurrentMediaTime() + 1)
        XCTAssertEqual(AudioAnalysisEngine.latestFeatures().rawOverall, 0, "pause → lights settle")
        await engine.setDemand(.composerReaction, active: false)
    }

    // MARK: - Storage

    func testStreamTempDirectoryIsPurged() throws {
        let dir = SpotifyConnectReceiver.resetStreamDirectory()
        XCTAssertTrue(dir.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        try Data([1, 2, 3]).write(to: dir.appendingPathComponent("stale-stream"))
        SpotifyConnectReceiver.purgeStreamDirectory()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    /// The Swift PCM path writes nothing to disk: snapshot every app container
    /// directory around a 10 s burst of synthetic PCM through the real router.
    func testNoAudioIsWrittenToStorage() async throws {
        let fm = FileManager.default
        let roots = [fm.urls(for: .documentDirectory, in: .userDomainMask)[0],
                     fm.urls(for: .libraryDirectory, in: .userDomainMask)[0],
                     fm.temporaryDirectory]
        func inventory() -> Set<String> {
            var paths = Set<String>()
            for root in roots {
                let e = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])
                while let url = e?.nextObject() as? URL { paths.insert(url.path) }
            }
            return paths
        }
        let before = inventory()
        let engine = await spotifyEngine()
        SpotifyPCMRouter.shared.setReceiverGeneration(21)
        for _ in 0..<430 { route(21) }   // ≈ 10 s of audio
        await engine.setDemand(.composerReaction, active: false)
        let added = inventory().subtracting(before).filter { path in
            // Unrelated system churn (caches, saved state) is not audio.
            !path.contains("/Caches/") && !path.contains("Saved Application State") && !path.contains("/Preferences/")
        }
        XCTAssertTrue(added.isEmpty, "unexpected new files: \(added.sorted())")
    }

    // MARK: - C ABI / real receiver

    func testStatusLayoutMatchesTheRustDefinition() {
        // src/state.rs `status_layout_is_pinned` asserts the same 976 bytes.
        XCTAssertEqual(MemoryLayout<CGSpotifyStatus>.size, 976)
        XCTAssertEqual(MemoryLayout<CGSpotifyStatus>.alignment, 8)
    }

    func testLinkedReceiverReportsThePinnedRevision() {
        let revision = String(cString: cg_spotify_librespot_revision())
        XCTAssertEqual(revision, "librespot dev@939dc5ee9d833e1980f9495241219d9d4868a061")
    }

    /// Real Rust receiver in the simulator: Bonjour advertisement comes up,
    /// stop tears it down, and repeated cycles leave no zombie generation.
    func testReceiverStartStopCyclesAreClean() async throws {
        let dir = SpotifyConnectReceiver.resetStreamDirectory()
        defer { SpotifyConnectReceiver.purgeStreamDirectory() }
        var generations: [UInt64] = []
        for _ in 0..<3 {
            let generation = await Task.detached {
                "ChromaGlow Sync (test)".withCString { name in
                    dir.path.withCString { tmp in cg_spotify_start(name, tmp, nil) }
                }
            }.value
            XCTAssertGreaterThan(generation, 0)
            generations.append(generation)

            var status = CGSpotifyStatus()
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                _ = cg_spotify_status(&status)
                if Int(status.state) == Int(CGSpotifyStateWaiting) || Int(status.state) == Int(CGSpotifyStateFailed) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(Int(status.state), Int(CGSpotifyStateWaiting),
                           "advertising failed: \(SpotifyConnectReceiver.string(status.message))")
            XCTAssertGreaterThan(status.zeroconf_port, 0)
            XCTAssertEqual(status.generation, generation)

            await Task.detached { cg_spotify_stop() }.value
            _ = cg_spotify_status(&status)
            XCTAssertEqual(Int(status.state), Int(CGSpotifyStateStopped))
            XCTAssertEqual(status.frames_delivered, 0)
        }
        XCTAssertEqual(generations, generations.sorted())
        XCTAssertEqual(Set(generations).count, 3)
    }

    func testReceiverControllerStartsAndStops() async throws {
        let receiver = SpotifyConnectReceiver.shared
        receiver.setPlaysOnPhone(true)
        receiver.start()
        XCTAssertEqual(receiver.output.state, .playing, "music output comes up with the receiver")
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playback)
        let deadline = Date().addingTimeInterval(4)
        while receiver.snapshot.phase != .waiting, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(receiver.snapshot.phase, .waiting)
        XCTAssertTrue(receiver.isEnabled)
        receiver.stop()
        await receiver.settle()
        XCTAssertFalse(receiver.isEnabled)
        XCTAssertEqual(receiver.snapshot.phase, .stopped)
        XCTAssertEqual(receiver.output.state, .off, "the music stops with the receiver")
        XCTAssertFalse(FileManager.default.fileExists(atPath: SpotifyConnectReceiver.streamDirectory.path))
    }

    // MARK: - Phase 2: playback

    func testTurningPlaybackOffFallsBackToListeningOnly() async throws {
        let receiver = SpotifyConnectReceiver.shared
        receiver.setPlaysOnPhone(true)
        receiver.start()
        defer { receiver.setPlaysOnPhone(true) }
        XCTAssertEqual(receiver.output.state, .playing)
        receiver.setPlaysOnPhone(false)
        XCTAssertEqual(receiver.output.state, .off, "off while the receiver keeps running")
        XCTAssertTrue(receiver.isEnabled)
        XCTAssertEqual(UserDefaults.standard.object(forKey: SpotifyConnectReceiver.playsOnPhoneKey) as? Bool, false)
        receiver.setPlaysOnPhone(true)
        XCTAssertEqual(receiver.output.state, .playing, "and back on live")
        receiver.stop()
        await receiver.settle()
        XCTAssertEqual(receiver.output.state, .off)
    }

    func testPlaybackOutputReportsItsRoute() {
        let output = SpotifyPlaybackOutput()
        output.start()
        defer { output.stop() }
        XCTAssertEqual(output.state, .playing)
        XCTAssertFalse(output.routeName.isEmpty)
        XCTAssertGreaterThanOrEqual(output.routeLatency, 0)
        XCTAssertLessThan(output.routeLatency, 5)
        output.stop()
        XCTAssertEqual(output.state, .off)
        XCTAssertEqual(output.routeLatency, 0, "no latency is charged to the lights when nothing plays")
    }

    func testLightOffsetIsClampedAndPersisted() {
        let receiver = SpotifyConnectReceiver.shared
        let original = receiver.lightOffsetMs
        defer { receiver.setLightOffset(milliseconds: original) }
        receiver.setLightOffset(milliseconds: 9_000)
        XCTAssertEqual(receiver.lightOffsetMs, SpotifyConnectReceiver.lightOffsetRange.upperBound)
        receiver.setLightOffset(milliseconds: -9_000)
        XCTAssertEqual(receiver.lightOffsetMs, SpotifyConnectReceiver.lightOffsetRange.lowerBound)
        receiver.setLightOffset(milliseconds: 120)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: SpotifyConnectReceiver.lightOffsetKey), 120)
    }

    /// The render pull deinterleaves what the ring has and zero-fills the
    /// rest — here the ring is empty, and the request is bigger than one C
    /// call's scratch, so the loop runs twice.
    func testRenderPullZeroFillsAnEmptyRing() throws {
        cg_spotify_set_playback(false, 0)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let frames = AVAudioFrameCount(PlaybackScratch.capacityFrames + 904)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<2 {
            buffer.floatChannelData![channel].update(repeating: 1, count: Int(frames))
        }
        PlaybackScratch().render(frameCount: Int(frames), into: buffer.mutableAudioBufferList)
        for channel in 0..<2 {
            let samples = UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: Int(frames))
            XCTAssertTrue(samples.allSatisfy { $0 == 0 }, "channel \(channel) not silent")
        }
    }
}

#endif
