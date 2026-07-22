// MusicSourceContractTests.swift
// HueHome Pro — Unit Tests
//
// MusicSessionCoordinator (music integration R1): the session state
// machine (activate/track change/pause/deactivate), the BeatClock service
// drive it performs, stale-async-completion dropping (generation counter),
// artwork palette extraction, and the observation contract — a position
// tick must NOT invalidate observers; a track change must.

import XCTest
@testable import HueHome

// MARK: - Test doubles

@MainActor
private final class ScriptedMusicSource: MusicSource {
    let service: MusicService = .demo
    let capabilities: SourceCapabilities = [.transport, .position]
    var onUpdate: ((NowPlayingTrack?, PlaybackPosition?) -> Void)?
    private(set) var started = false
    private(set) var stopped = false
    private(set) var transportActions: [TransportAction] = []

    func start() async throws { started = true }
    func stop() { stopped = true }
    func transport(_ action: TransportAction) async { transportActions.append(action) }

    func emit(_ track: NowPlayingTrack?, _ position: PlaybackPosition?) {
        onUpdate?(track, position)
    }
}

/// start() suspends until released — models the auth-prompt / login-sheet
/// window where a second activation can interleave (audit R9, F4).
@MainActor
private final class GatedStartMusicSource: MusicSource {
    let service: MusicService = .demo
    let capabilities: SourceCapabilities = []
    var onUpdate: ((NowPlayingTrack?, PlaybackPosition?) -> Void)?
    private(set) var stopped = false
    var startError: MusicSourceError?
    private var gate: CheckedContinuation<Void, Never>?

    func start() async throws {
        await withCheckedContinuation { self.gate = $0 }
        if let startError { throw startError }
    }

    func releaseStart() {
        gate?.resume()
        gate = nil
    }

    func stop() { stopped = true }
    func transport(_ action: TransportAction) async {}
}

private final class SlowTempoProvider: TempoProvider, @unchecked Sendable {
    let id = "slow"
    let bpm: Double
    let delayNs: UInt64
    init(bpm: Double, delayNs: UInt64 = 50_000_000) {
        self.bpm = bpm
        self.delayNs = delayNs
    }
    func tempo(for query: TempoQuery) async throws -> Double? {
        try? await Task.sleep(nanoseconds: delayNs)
        return bpm
    }
}

// MARK: - Tests

@MainActor
final class MusicSourceContractTests: XCTestCase {

    private var clock: BeatClock!
    private var tempURL: URL!
    private var defaults: UserDefaults!
    private let suiteName = "MusicSourceContractTests"

    override func setUp() {
        super.setUp()
        clock = BeatClock()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("music-contract-\(UUID().uuidString).json")
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        defaults.removePersistentDomain(forName: suiteName)
        BeatClock().clear()
        super.tearDown()
    }

    private func coordinator(providers: [TempoProvider] = []) -> MusicSessionCoordinator {
        MusicSessionCoordinator(
            clock: clock,
            resolver: TrackTempoResolver(providers: providers, fileURL: tempURL,
                                         defaults: defaults, liveEstimate: { (0, 0) })
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2, _ message: String = "condition not met",
        _ cond: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(cond(), message)
    }

    // MARK: - Demo end-to-end

    func testActivateDemoSourceDrivesClockFromHint() async throws {
        let mus = coordinator()
        let mock = MockMusicSource(hostNow: { 100.0 })
        try await mus.activate(mock)

        XCTAssertTrue(mus.hasSession)
        XCTAssertEqual(mus.activeService, .demo)
        XCTAssertEqual(mus.nowPlaying?.title, "Golden Hour")
        XCTAssertTrue(mus.isPlaying)

        await waitUntil("tempo hint must resolve") { mus.tempo != nil }
        XCTAssertEqual(mus.tempo, ResolvedTempo(bpm: 96, confidence: 1.0, origin: .hint))
        XCTAssertEqual(clock.source, .service)
        XCTAssertEqual(clock.bpm, 96)
        // Track t=0 at host 100 → phase 0 there.
        XCTAssertEqual(BeatClock.snapshot().beatPhase(at: 100), 0, accuracy: 1e-6)

        await waitUntil("demo artwork must yield a palette") { mus.artworkPalette != nil }
    }

    func testPauseEndsServiceDriveAndKeepsTempo() async throws {
        let mus = coordinator()
        let mock = MockMusicSource(hostNow: { 100 })
        try await mus.activate(mock)
        await waitUntil { self.clock.source == .service }

        await mus.transport(.pause)
        XCTAssertFalse(mus.isPlaying)
        XCTAssertEqual(clock.source, .audio, "pause hands the clock back to audio-follow")
        XCTAssertEqual(clock.bpm, 96, "the look keeps running at the last tempo")
    }

    func testTrackChangeResetsTempoAndRedrives() async throws {
        let mus = coordinator()
        let mock = MockMusicSource(hostNow: { 100 })
        try await mus.activate(mock)
        await waitUntil { self.clock.bpm == 96 }

        await mus.transport(.nextTrack)
        XCTAssertEqual(mus.nowPlaying?.title, "Neon Skyline")
        await waitUntil("new track's hint must drive the clock") { self.clock.bpm == 120 }
        XCTAssertEqual(mus.tempo?.origin, .hint)
    }

    func testDeactivateClearsEverything() async throws {
        let mus = coordinator()
        let scripted = ScriptedMusicSource()
        try await mus.activate(scripted)
        scripted.emit(
            NowPlayingTrack(service: .demo, title: "T", artist: "A", tempoHint: 96),
            PlaybackPosition(positionMs: 0, capturedAt: 100, isPlaying: true)
        )
        await waitUntil { self.clock.source == .service }

        mus.deactivate()
        XCTAssertFalse(mus.hasSession)
        XCTAssertNil(mus.nowPlaying)
        XCTAssertNil(mus.tempo)
        XCTAssertNil(mus.artworkPalette)
        XCTAssertNil(mus.lastPosition)
        XCTAssertFalse(mus.isPlaying)
        XCTAssertTrue(scripted.stopped)
        XCTAssertEqual(clock.source, .audio, "session end releases the clock")
    }

    // MARK: - Track change releases the clock (audit R9, F1)

    func testTrackChangeEndsServiceDriveWhileTempoUnresolved() async throws {
        // No providers, silent live estimate: the second track's tempo can
        // NEVER resolve. The old track's grid must not keep driving —
        // before the fix it held serviceHold forever, suppressing the mic
        // demand that ingest's self-heal needed.
        let mus = coordinator()
        let scripted = ScriptedMusicSource()
        try await mus.activate(scripted)
        scripted.emit(
            NowPlayingTrack(service: .demo, title: "A", artist: "X", tempoHint: 120),
            PlaybackPosition(positionMs: 0, capturedAt: 100, isPlaying: true)
        )
        await waitUntil { self.clock.source == .service }

        scripted.emit(
            NowPlayingTrack(service: .demo, title: "B", artist: "X"),   // no hint
            PlaybackPosition(positionMs: 0, capturedAt: 200, isPlaying: true)
        )
        XCTAssertEqual(clock.source, .audio,
                       "an unresolved next track hands the clock to audio-follow, like a pause")
        XCTAssertEqual(clock.bpm, 120, "the look keeps running at the last tempo")
        XCTAssertFalse(clock.isServiceDriven(now: 201),
                       "mic demand for .beat looks must be able to return immediately")
    }

    // MARK: - Activation liveness (audit R9, F4)

    func testFailedStartDoesNotKillNewerSession() async throws {
        let mus = coordinator()
        let slow = GatedStartMusicSource()
        slow.startError = .authorizationDenied

        let firstActivation = Task { try await mus.activate(slow) }
        await waitUntil { mus.activeService != nil }   // slow is provisionally active

        // The user changes their mind mid-auth-prompt and picks another source.
        let fast = ScriptedMusicSource()
        try await mus.activate(fast)
        fast.emit(
            NowPlayingTrack(service: .demo, title: "T", artist: "A", tempoHint: 96),
            PlaybackPosition(positionMs: 0, capturedAt: 100, isPlaying: true)
        )
        await waitUntil { mus.tempo != nil }

        // Now the abandoned auth prompt resolves to a denial.
        slow.releaseStart()
        _ = await firstActivation.result

        XCTAssertTrue(mus.hasSession, "the failed OLD activation must not tear down the NEW session")
        XCTAssertEqual(mus.nowPlaying?.title, "T")
        XCTAssertFalse(fast.stopped)
        XCTAssertTrue(slow.stopped)
    }

    func testSupersededStartUnwindsQuietly() async throws {
        let mus = coordinator()
        let slow = GatedStartMusicSource()   // will SUCCEED, but too late

        let firstActivation = Task { try await mus.activate(slow) }
        await waitUntil { mus.activeService != nil }

        let fast = ScriptedMusicSource()
        try await mus.activate(fast)

        slow.releaseStart()
        _ = await firstActivation.result

        XCTAssertTrue(slow.stopped, "a superseded start must unwind, not run as a zombie")
        XCTAssertNil(slow.onUpdate, "a superseded source must not keep a coordinator callback")
        XCTAssertFalse(fast.stopped)
    }

    // MARK: - Generation counter

    func testStaleTempoResolutionIsDropped() async throws {
        // Track A resolves via a slow provider; track B lands first via hint.
        // A's late completion must be dropped, never overwriting B's grid.
        let mus = coordinator(providers: [SlowTempoProvider(bpm: 124)])
        let scripted = ScriptedMusicSource()
        try await mus.activate(scripted)

        let trackA = NowPlayingTrack(service: .demo, title: "Slow A", artist: "X")
        scripted.emit(trackA, PlaybackPosition(positionMs: 0, capturedAt: 100, isPlaying: true))
        let trackB = NowPlayingTrack(service: .demo, title: "Fast B", artist: "X", tempoHint: 130)
        scripted.emit(trackB, PlaybackPosition(positionMs: 0, capturedAt: 100, isPlaying: true))

        await waitUntil { mus.tempo?.bpm == 130 }
        // Give A's slow provider time to complete — its result must vanish.
        try? await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(mus.tempo?.bpm, 130, "a stale resolution must never clobber the current track")
        XCTAssertEqual(clock.bpm, 130)
    }

    // MARK: - Position estimate

    func testCurrentPositionEstimateExtrapolatesAndCaps() async throws {
        let mus = coordinator()
        let scripted = ScriptedMusicSource()
        try await mus.activate(scripted)
        let track = NowPlayingTrack(service: .demo, title: "T", artist: "A",
                                    durationMs: 10_000, tempoHint: 120)
        scripted.emit(track, PlaybackPosition(positionMs: 4_000, capturedAt: 100, isPlaying: true))

        let est = mus.currentPositionEstimate(now: 103)
        XCTAssertEqual(est?.positionMs, 7_000, "4 s + 3 s elapsed")
        let capped = mus.currentPositionEstimate(now: 120)
        XCTAssertEqual(capped?.positionMs, 10_000, "estimate never runs past the track")
    }

    // MARK: - Observation contract

    func testPositionTickDoesNotInvalidateObservers() async throws {
        let mus = coordinator()
        let scripted = ScriptedMusicSource()
        try await mus.activate(scripted)
        let track = NowPlayingTrack(service: .demo, title: "T", artist: "A", tempoHint: 120)
        scripted.emit(track, PlaybackPosition(positionMs: 0, capturedAt: 100, isPlaying: true))
        await waitUntil { mus.tempo != nil }

        let fired = expectation(description: "observation fired")
        fired.isInverted = true
        withObservationTracking {
            _ = mus.nowPlaying
            _ = mus.isPlaying
            _ = mus.tempo
            _ = mus.artworkPalette
        } onChange: { fired.fulfill() }

        // Same track, new position: only the unobserved lastPosition moves.
        scripted.emit(track, PlaybackPosition(positionMs: 1_000, capturedAt: 101, isPlaying: true))
        XCTAssertEqual(mus.lastPosition?.positionMs, 1_000)
        await fulfillment(of: [fired], timeout: 0.3)
    }

    func testTrackChangeDoesInvalidateObservers() async throws {
        let mus = coordinator()
        let scripted = ScriptedMusicSource()
        try await mus.activate(scripted)
        let track = NowPlayingTrack(service: .demo, title: "T", artist: "A", tempoHint: 120)
        scripted.emit(track, PlaybackPosition(positionMs: 0, capturedAt: 100, isPlaying: true))

        let fired = expectation(description: "observation fired")
        withObservationTracking {
            _ = mus.nowPlaying
        } onChange: { fired.fulfill() }

        scripted.emit(
            NowPlayingTrack(service: .demo, title: "T2", artist: "A", tempoHint: 96),
            PlaybackPosition(positionMs: 0, capturedAt: 200, isPlaying: true)
        )
        await fulfillment(of: [fired], timeout: 1.0)
    }
}
