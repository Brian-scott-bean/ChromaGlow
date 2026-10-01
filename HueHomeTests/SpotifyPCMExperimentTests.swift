// SpotifyPCMExperimentTests.swift
// LOCAL-ONLY Spotify Connect PCM experiment. Compiles (and runs) only in the
// Debug-SpotifyExperimental configuration:
//   xcodebuild test -scheme "HueHome Spotify Experimental" …
// Covers source switching, the receiver→analysis router gates, playout delay,
// stall silence, no-persistence, the C ABI layout, real start/stop cycles of
// the Rust receiver (it advertises "… (test)" on the LAN for ~a second), and
// Phase 2 playback: the output's lifecycle, the renderer feeder (pull policy,
// stall / pause / stop, sample buffers), the timeline clock, light offset.

#if CHROMAGLOW_EXPERIMENTAL_SPOTIFY

import AVFoundation
import ChromaGlowSpotifyFFI
import CoreMedia
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

    /// Build 903 crash: Auto Detect's ShazamKit tap received Spotify hops on
    /// librespot's player thread and threw an Objective-C exception there.
    func testSpotifyHopsNeverReachRawBufferTaps() async {
        let engine = await spotifyEngine()
        SpotifyPCMRouter.shared.setReceiverGeneration(4)
        let calls = TapCounter()
        AudioAnalysisEngine.addBufferTap(id: "spotify-test-tap") { _, _ in calls.hit() }
        defer { AudioAnalysisEngine.removeBufferTap(id: "spotify-test-tap") }
        for _ in 0..<4 { route(4) }
        XCTAssertGreaterThan(AudioAnalysisEngine.latestFeatures().rawOverall, 0.05, "analysis still runs")
        XCTAssertEqual(calls.count, 0)
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
        // src/state.rs `status_layout_is_pinned` asserts the same 992 bytes.
        XCTAssertEqual(MemoryLayout<CGSpotifyStatus>.size, 992)
        XCTAssertEqual(MemoryLayout<CGSpotifyStatus>.alignment, 8)
    }

    // MARK: - Transport / lock screen

    func testCommandsWithoutAConnectSessionAreRefused() {
        XCTAssertFalse(cg_spotify_command(UInt32(CGSpotifyCommandPlay)))
        XCTAssertFalse(cg_spotify_command(UInt32(CGSpotifyCommandBringHere)))
        XCTAssertFalse(SpotifyConnectReceiver.shared.send(.next), "receiver not started")
    }

    func testSpeakerAutoResumesOnlyWhenSpotifyPlaysHereAndNothingElseDoes() {
        func check(interrupted: Bool = true, phone: Bool = true, playback: SpotifyConnectReceiver.Playback = .playing,
                   handoff: SpotifyConnectReceiver.Handoff = .active, other: Bool = false, since: Double = 5) -> Bool {
            SpotifyConnectReceiver.shouldAutoResume(outputInterrupted: interrupted, playsOnPhone: phone, playback: playback,
                                                    handoff: handoff, otherAudioPlaying: other, sinceLastAttempt: since)
        }
        XCTAssertTrue(check())
        XCTAssertFalse(check(other: true), "a call or another app is playing")
        XCTAssertFalse(check(playback: .paused))
        XCTAssertFalse(check(handoff: .movedAway))
        XCTAssertFalse(check(phone: false))
        XCTAssertFalse(check(interrupted: false))
        XCTAssertFalse(check(since: 1), "throttled")
    }

    func testTrackPositionAdvancesOnlyWhilePlaying() {
        XCTAssertEqual(SpotifyConnectReceiver.position(reportedMs: 78_000, ageMs: 2_500, durationMs: 220_000, playing: true), 80.5)
        XCTAssertEqual(SpotifyConnectReceiver.position(reportedMs: 78_000, ageMs: 2_500, durationMs: 220_000, playing: false), 78)
        XCTAssertEqual(SpotifyConnectReceiver.position(reportedMs: 219_000, ageMs: 9_000, durationMs: 220_000, playing: true), 220,
                       "clamped to the track")
    }

    func testLockScreenRepublishesOnlyOnVisibleChanges() {
        typealias S = SpotifyNowPlaying.Sample
        let base = S(title: "A", artist: "B", duration: 200, playing: true, position: 10, publishedAt: 100)
        var later = base
        later.publishedAt = 104
        later.position = 14.2
        XCTAssertFalse(SpotifyNowPlaying.needsPublish(last: base, next: later), "progress the lock screen extrapolates")
        later.position = 40
        XCTAssertTrue(SpotifyNowPlaying.needsPublish(last: base, next: later), "a seek")
        var paused = base
        paused.playing = false
        XCTAssertTrue(SpotifyNowPlaying.needsPublish(last: base, next: paused))
        var track = base
        track.title = "C"
        XCTAssertTrue(SpotifyNowPlaying.needsPublish(last: base, next: track))
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

    /// The output comes up BEFORE the receiver; starting the receiver must
    /// leave the speaker pulling (build 902 on device: the receiver's start
    /// switched playback off, so the music was decoded but never heard).
    func testSpeakerKeepsPullingAfterTheReceiverStarts() async throws {
        let receiver = SpotifyConnectReceiver.shared
        receiver.setPlaysOnPhone(true)
        receiver.start()
        await receiver.settle()
        let deadline = Date().addingTimeInterval(2)
        while !cg_spotify_playback_live(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(cg_spotify_playback_live(), "the render thread pulls the receiver's ring")
        receiver.stop()
        await receiver.settle()
        XCTAssertFalse(cg_spotify_playback_live(), "and stops with it")
    }

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

    // MARK: - Phase 2: renderer feeder (AVSampleBufferAudioRenderer)

    func testFeedPolicyPrefersWholeChunks() {
        let chunk = SpotifyFeedPolicy.chunkFrames
        func pull(_ available: Int, room: Int = 1_000_000, low: Bool = false, keepAlive: Bool = false) -> Int {
            SpotifyFeedPolicy.framesToPull(available: available, roomFrames: room, lowWater: low, keepAliveDue: keepAlive)
        }
        XCTAssertEqual(pull(10_000), chunk, "a whole chunk when the ring has one")
        XCTAssertEqual(pull(1_000), 0, "wait for a whole chunk while the renderer is well fed")
        XCTAssertEqual(pull(1_000, low: true), 1_000, "take what there is when it runs low")
        XCTAssertEqual(pull(10_000, room: 100), 0, "never past the lookahead…")
        XCTAssertEqual(pull(10_000, room: 100, keepAlive: true), 100, "…except to keep the receiver's consumer alive")
        XCTAssertEqual(pull(500, room: 0, keepAlive: true), 500)
        XCTAssertEqual(pull(0, low: true, keepAlive: true), 0, "no silence is ever made up")
    }

    func testTimelineParksOnlyWhenRunningDry() {
        XCTAssertTrue(SpotifyFeedPolicy.shouldStall(running: true, bufferedSeconds: 0.01, available: 0))
        XCTAssertFalse(SpotifyFeedPolicy.shouldStall(running: true, bufferedSeconds: 0.01, available: 64))
        XCTAssertFalse(SpotifyFeedPolicy.shouldStall(running: true, bufferedSeconds: 0.5, available: 0))
        XCTAssertFalse(SpotifyFeedPolicy.shouldStall(running: false, bufferedSeconds: 0, available: 0))
    }

    func testClockHostTimeMath() {
        // Running: heard when the timeline reaches the frame.
        XCTAssertEqual(SpotifyPlaybackClock.hostTime(
            framePTS: 12, timelineNow: 10.5, timelineRate: 1, hostNow: 100,
            scheduledStart: nil, pendingStartDelay: 0.2), 101.5, accuracy: 1e-9)
        // Parked with a scheduled start: anchored to that start.
        XCTAssertEqual(SpotifyPlaybackClock.hostTime(
            framePTS: 5.5, timelineNow: 5, timelineRate: 0, hostNow: 100,
            scheduledStart: (pts: 5, host: 100.8), pendingStartDelay: 0.2), 101.3, accuracy: 1e-9)
        // Parked, nothing scheduled: starts pendingStartDelay after arrival.
        XCTAssertEqual(SpotifyPlaybackClock.hostTime(
            framePTS: 5.25, timelineNow: 5, timelineRate: 0, hostNow: 100,
            scheduledStart: nil, pendingStartDelay: 1), 101.25, accuracy: 1e-9)
    }

    /// The router's clock converts through a real CMTimebase on the host
    /// clock — the same clock CACurrentMediaTime reads.
    func testClockFollowsARealTimebase() throws {
        XCTAssertEqual(CMClockGetTime(CMClockGetHostTimeClock()).seconds, CACurrentMediaTime(), accuracy: 0.002)
        let clock = try runningClock(at: 10)
        clock.setNextFrame(Int64(10.5 * 44_100))
        let now = CACurrentMediaTime()
        let heard = try XCTUnwrap(clock.presentationHostTime(queuedFrames: 44_100, now: now))
        XCTAssertEqual(heard - now, 1.5, accuracy: 0.005, "0.5 s ahead in the renderer + 1 s in the ring")
        clock.deactivate()
        XCTAssertNil(clock.presentationHostTime(queuedFrames: 0, now: now))
    }

    func testRouterSchedulesLightsFromThePlaybackClock() async throws {
        let engine = await spotifyEngine()
        defer { SpotifyPCMRouter.shared.setPlaybackClock(nil) }
        SpotifyPCMRouter.shared.setReceiverGeneration(15)
        SpotifyPCMRouter.shared.setOutputLatency(2)   // reported route latency: ignored
        let clock = try runningClock(at: 0)
        SpotifyPCMRouter.shared.setPlaybackClock(clock)
        route(15, queued: 22_050)
        XCTAssertEqual(SpotifyPCMRouter.shared.snapshot().presentationDelay, 0.5, accuracy: 0.01)
        SpotifyPCMRouter.shared.setUserOffset(0.1)
        route(15, queued: 22_050)
        XCTAssertEqual(SpotifyPCMRouter.shared.snapshot().presentationDelay, 0.6, accuracy: 0.01)
        SpotifyPCMRouter.shared.setPlaybackClock(nil)
        route(15, queued: 0)
        XCTAssertEqual(SpotifyPCMRouter.shared.snapshot().presentationDelay, 2.1, accuracy: 0.001,
                       "without the clock: the analysis-only formula")
        await engine.setDemand(.composerReaction, active: false)
    }

    /// Spotify paused → the output flushes its audio; lights already
    /// scheduled for that audio must not flash on afterwards.
    func testPauseFlushDropsScheduledLights() async throws {
        let engine = await spotifyEngine()
        SpotifyPCMRouter.shared.setReceiverGeneration(16)
        SpotifyPCMRouter.shared.setUserOffset(0.2)
        route(16)
        SpotifyPCMRouter.shared.dropScheduledLights()
        try await Task.sleep(for: .milliseconds(260))
        XCTAssertEqual(AudioAnalysisEngine.latestFeatures().rawOverall, 0)
        await engine.setDemand(.composerReaction, active: false)
    }

    func testHistoryWrapsAndReadsBack() {
        var history = SpotifyPCMHistory(capacityFrames: 8)
        let a: [Float] = (0..<12).map(Float.init)          // 6 frames
        let b: [Float] = (12..<24).map(Float.init)         // 6 more
        a.withUnsafeBufferPointer { history.append($0.baseAddress!, count: 6, at: 0) }
        b.withUnsafeBufferPointer { history.append($0.baseAddress!, count: 6, at: 6) }
        XCTAssertEqual(history.start, 4, "bounded: the oldest frames fall out")
        XCTAssertEqual(history.end, 12)
        var out = [Float](repeating: -1, count: 8)
        XCTAssertEqual(out.withUnsafeMutableBufferPointer { history.read(from: 2, count: 4, into: $0.baseAddress!) }, 0)
        XCTAssertEqual(out.withUnsafeMutableBufferPointer { history.read(from: 5, count: 4, into: $0.baseAddress!) }, 4)
        XCTAssertEqual(out, [10, 11, 12, 13, 14, 15, 16, 17])
        a.withUnsafeBufferPointer { history.append($0.baseAddress!, count: 2, at: 100) }
        XCTAssertEqual(history.start, 100, "a gap starts over")
        XCTAssertEqual(history.end, 102)
    }

    func testSampleBufferCarriesFramesAndTimestamp() throws {
        let feeder = try SpotifyPlaybackFeeder(sampleRate: 44_100, source: FakeRing().source)
        let pcm = [Float](repeating: 0.25, count: 2_000)
        let buffer = try XCTUnwrap(pcm.withUnsafeBufferPointer {
            feeder.makeSampleBuffer($0.baseAddress!, frames: 1_000, at: 44_100)
        })
        XCTAssertEqual(CMSampleBufferGetNumSamples(buffer), 1_000)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(buffer).seconds, 1, accuracy: 1e-9)
        let asbd = try XCTUnwrap(CMSampleBufferGetFormatDescription(buffer)
            .flatMap(CMAudioFormatDescriptionGetStreamBasicDescription)?.pointee)
        XCTAssertEqual(asbd.mChannelsPerFrame, 2)
        XCTAssertEqual(asbd.mSampleRate, 44_100)
        XCTAssertEqual(CMBlockBufferGetDataLength(try XCTUnwrap(CMSampleBufferGetDataBuffer(buffer))), 8_000)
    }

    /// Real renderer + synchronizer on a fake ring: audio is enqueued, the
    /// timeline starts on schedule and stays within the lookahead; a Spotify
    /// pause flushes and parks it; stop leaves nothing running.
    func testFeederPlaysPausesAndStops() async throws {
        let ring = FakeRing()
        ring.add(frames: 88_200)   // 2 s
        let feeder = try SpotifyPlaybackFeeder(sampleRate: 44_100, source: ring.source)
        feeder.start(airPlay: false)
        try await Task.sleep(for: .milliseconds(700))
        var s = feeder.snapshot()
        XCTAssertTrue(s.feeding)
        XCTAssertTrue(s.running)
        XCTAssertEqual(s.timelineRate, 1)
        XCTAssertGreaterThan(s.framesEnqueued, 0)
        XCTAssertGreaterThan(s.timelineSeconds, 0.1, "started ~0.2 s after the first audio")
        XCTAssertLessThanOrEqual(s.bufferedSeconds, SpotifyFeedPolicy.Tuning.local.lookahead + 0.1,
                                 "bounded lookahead: the decoder isn't run arbitrarily far ahead")
        XCTAssertEqual(s.nextFrame, s.framesEnqueued, "contiguous timeline, nothing made up")

        ring.setPaused(true)
        try await Task.sleep(for: .milliseconds(80))
        s = feeder.snapshot()
        XCTAssertEqual(s.pauseFlushes, 1)
        XCTAssertFalse(s.running)
        XCTAssertEqual(s.timelineRate, 0, "pause stops the timeline")
        let parked = s.timelineSeconds
        XCTAssertEqual(Double(s.nextFrame) / 44_100, parked, accuracy: 0.001, "resumes where it was heard")

        ring.setPaused(false)
        try await Task.sleep(for: .milliseconds(500))
        s = feeder.snapshot()
        XCTAssertTrue(s.running, "play resumes the same timeline")
        XCTAssertGreaterThan(s.timelineSeconds, parked)

        feeder.stop()
        s = feeder.snapshot()
        XCTAssertFalse(s.feeding)
        XCTAssertEqual(s.timelineRate, 0)
        let reads = ring.reads
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(ring.reads, reads, "no timer left pulling")
    }

    func testFeederParksTheTimelineOnAnUnderrunAndKeepsPulling() async throws {
        let ring = FakeRing()
        ring.add(frames: 8_820)    // 0.2 s, then the stream stalls
        let feeder = try SpotifyPlaybackFeeder(sampleRate: 44_100, source: ring.source)
        feeder.start(airPlay: false)
        defer { feeder.stop() }
        try await Task.sleep(for: .milliseconds(900))
        var s = feeder.snapshot()
        XCTAssertGreaterThanOrEqual(s.stalls, 1)
        XCTAssertFalse(s.running)
        XCTAssertEqual(s.timelineRate, 0, "parked, not running ahead on silence")
        XCTAssertEqual(s.framesEnqueued, 8_820)
        XCTAssertGreaterThanOrEqual(ring.reads, 5, "an empty ring is still pulled (receiver consumer liveness)")

        ring.add(frames: 44_100)
        try await Task.sleep(for: .milliseconds(400))
        s = feeder.snapshot()
        XCTAssertTrue(s.running)
        XCTAssertEqual(s.timelineRate, 1)
    }

    func testPlaybackOutputUsesLongFormRouting() {
        let output = SpotifyPlaybackOutput()
        output.start()
        defer { output.stop() }
        XCTAssertEqual(output.state, .playing)
        let session = AVAudioSession.sharedInstance()
        XCTAssertEqual(session.category, .playback)
        XCTAssertEqual(session.routeSharingPolicy, .longFormAudio, "AirPlay 2 multi-room needs long-form")
        XCTAssertEqual(output.feedSnapshot()?.feeding, true)
        output.stop()
        XCTAssertNil(output.feedSnapshot(), "stop leaves no feeder behind")
        XCTAssertFalse(cg_spotify_playback_live())
    }

    private func runningClock(at seconds: Double) throws -> SpotifyPlaybackClock {
        var timebase: CMTimebase?
        XCTAssertEqual(CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
                                                       sourceClock: CMClockGetHostTimeClock(),
                                                       timebaseOut: &timebase), noErr)
        let tb = try XCTUnwrap(timebase)
        CMTimebaseSetTime(tb, time: CMTime(seconds: seconds, preferredTimescale: 44_100))
        CMTimebaseSetRate(tb, rate: 1)
        return SpotifyPlaybackClock(sampleRate: 44_100, timebase: tb, pendingStartDelay: 0)
    }
}

/// A stand-in for the Rust ring: silent frames on demand.
final class FakeRing: @unchecked Sendable {
    private let lock = NSLock()
    private var queued = 0
    private var paused = false
    private var readCount = 0

    var reads: Int { lock.lock(); defer { lock.unlock() }; return readCount }

    func add(frames: Int) { lock.lock(); queued += frames; lock.unlock() }
    func setPaused(_ on: Bool) { lock.lock(); paused = on; lock.unlock() }

    var source: SpotifyPlaybackFeeder.Source {
        SpotifyPlaybackFeeder.Source(
            status: { [self] in
                lock.lock(); defer { lock.unlock() }
                return (queued, paused)
            },
            read: { [self] out, frames in
                lock.lock(); defer { lock.unlock() }
                readCount += 1
                let got = paused ? 0 : min(frames, queued)
                queued -= got
                out.update(repeating: 0, count: frames * 2)
                return got
            }
        )
    }
}

/// Counts raw-buffer tap calls from any thread.
private final class TapCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func hit() { lock.lock(); calls += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
}

#endif
