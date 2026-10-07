// SongMemoryTests.swift
// HueHome Pro — Unit Tests (Play Along P5)
//
// The song memory: a song learned on these speakers locks at once next
// time (beat AND the one); other speakers relearn instead of reusing; a
// scattered or unsure grid is not stored as sure; a damaged file costs only
// the damaged song; the file holds no readable listening history; and the
// whole loop — mic confirms, coordinator remembers, the next play drives
// the clock straight onto the beat.

import XCTest
@testable import HueHome

@MainActor
private final class ScriptedSource: MusicSource {
    let service: MusicService = .appleMusic
    let capabilities: SourceCapabilities = [.position]
    var onUpdate: ((NowPlayingTrack?, PlaybackPosition?) -> Void)?
    func start() async throws {}
    func stop() {}
    func transport(_ action: TransportAction) async {}
    func emit(_ track: NowPlayingTrack?, _ position: PlaybackPosition?) { onUpdate?(track, position) }
}

@MainActor
final class SongMemoryTests: XCTestCase {

    private var fileURL: URL!
    private var tempoURL: URL!
    private var defaults: UserDefaults!
    private let suiteName = "SongMemoryTests"

    private let track = NowPlayingTrack(service: .appleMusic, title: "Golden Hour", artist: "JVKE",
                                        isrc: "USA2P2230223", tempoHint: 120)

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("song-memory-\(UUID().uuidString).json")
        tempoURL = FileManager.default.temporaryDirectory.appendingPathComponent("song-tempo-\(UUID().uuidString).json")
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: tempoURL)
        defaults.removePersistentDomain(forName: suiteName)
        BeatClock().clear()
        super.tearDown()
    }

    private func key(route: String = "builtIn") -> String {
        SongMemory.key(for: TempoQuery(track: track), route: route)
    }

    /// 120 BPM, one confirmed observation a second (the coordinator's drive
    /// cadence). Default: the first beat 0.37 s in, bars starting one beat
    /// later (0.87 s) — the one is the second beat.
    private func learn(_ memory: SongMemory, key: String, seconds: Int = 20, barOffset: Double = 0.87,
                       barConfidence: Double = 0.8) {
        for i in 0..<seconds {
            let wobble = (i % 2 == 0 ? 1.0 : -1.0) * 0.004
            memory.observe(key, bpm: 120, barOffset: barOffset + wobble, beatsPerBar: 4,
                           phaseConfidence: 0.8, barConfidence: barConfidence, at: 1000 + Double(i))
        }
    }

    // MARK: - Learn, persist, recall

    func testASongLearnedHereIsRecalledAfterARelaunch() throws {
        let memory = SongMemory(fileURL: fileURL)
        learn(memory, key: key(), seconds: 15)
        XCTAssertNil(memory.entry(key()), "under 8 bars: not yet")
        learn(memory, key: key())
        let entry = try XCTUnwrap(memory.entry(key()), "8 agreeing bars are stored")
        XCTAssertEqual(entry.beatOffset, 0.37, accuracy: 0.003)
        XCTAssertEqual(entry.downbeatSlot, 1)
        XCTAssertEqual(entry.bpm, 120)

        let relaunched = SongMemory(fileURL: fileURL)
        let recall = try XCTUnwrap(relaunched.recall(key(), bpm: 120))
        XCTAssertTrue(recall.barKnown)
        XCTAssertEqual(recall.offset, 0.87, accuracy: 0.003)
    }

    func testOtherSpeakersRelearnInsteadOfReusing() throws {
        let memory = SongMemory(fileURL: fileURL)
        learn(memory, key: key(route: "builtIn"))
        XCTAssertNil(memory.recall(key(route: "AirPlay#living-room"), bpm: 120), "another route has another delay")
        learn(memory, key: key(route: "AirPlay#living-room"), barOffset: 1.52)
        XCTAssertEqual(try XCTUnwrap(memory.recall(key(route: "AirPlay#living-room"), bpm: 120)).offset, 1.52,
                       accuracy: 0.003)
        XCTAssertEqual(try XCTUnwrap(memory.recall(key(route: "builtIn"), bpm: 120)).offset, 0.87, accuracy: 0.003,
                       "each route keeps its own")
    }

    func testAnotherTempoIsNotTheSameGrid() {
        let memory = SongMemory(fileURL: fileURL)
        learn(memory, key: key())
        XCTAssertNotNil(memory.recall(key(), bpm: 120))
        XCTAssertNil(memory.recall(key(), bpm: 121))
    }

    func testScatteredOffsetsAreNeverStored() {
        let memory = SongMemory(fileURL: fileURL)
        for i in 0..<40 {
            memory.observe(key(), bpm: 120, barOffset: Double((i * 7919) % 500) / 1000, beatsPerBar: 4,
                           phaseConfidence: 0.8, barConfidence: 0.8, at: 1000 + Double(i))
        }
        XCTAssertNil(memory.entry(key()))
    }

    func testAnUnsureBarStoresTheBeatButNotTheOne() throws {
        let memory = SongMemory(fileURL: fileURL)
        learn(memory, key: key(), barConfidence: 0.2)
        let recall = try XCTUnwrap(memory.recall(key(), bpm: 120))
        XCTAssertFalse(recall.barKnown)
        XCTAssertEqual(recall.offset, 0.37, accuracy: 0.003)
    }

    func testTappingTheOneRelabelsWhatIsStored() throws {
        let memory = SongMemory(fileURL: fileURL)
        learn(memory, key: key())
        // The user names another one: same beats, bars one beat later.
        for i in 20..<60 {
            memory.observe(key(), bpm: 120, barOffset: 1.37, beatsPerBar: 4, phaseConfidence: 0.9,
                           barConfidence: 1, at: 1000 + Double(i))
        }
        XCTAssertEqual(try XCTUnwrap(memory.entry(key())).downbeatSlot, 2)
    }

    // MARK: - The file

    func testTheFileHoldsNoReadableListeningHistory() throws {
        let memory = SongMemory(fileURL: fileURL)
        learn(memory, key: key())
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(text.contains("Golden"))
        XCTAssertFalse(text.contains("JVKE"))
        XCTAssertFalse(text.contains("USA2P2230223"))
        XCTAssertEqual(key().count, 64, "a SHA-256 digest")
        XCTAssertNotEqual(key(route: "builtIn"), key(route: "Headphones#1"))
    }

    func testADamagedFileCostsOnlyTheDamagedSong() throws {
        let json = """
        {"entries":{"aaa":{"bpm":120,"beatOffset":0.25,"downbeatSlot":2,"beatsPerBar":4,"phaseConfidence":0.8,\
        "barConfidence":0.7,"observations":20,"updatedAt":0},"bbb":{"bpm":"fast"},"ccc":{"bpm":96,"beatOffset":0.1}}}
        """
        try Data(json.utf8).write(to: fileURL)
        let memory = SongMemory(fileURL: fileURL)
        XCTAssertEqual(memory.count, 2)
        XCTAssertEqual(memory.recall("aaa", bpm: 120), SongMemory.Recall(offset: 1.25, barKnown: true))
        XCTAssertEqual(memory.recall("ccc", bpm: 96)?.barKnown, false)

        try Data("not json".utf8).write(to: fileURL)
        XCTAssertEqual(SongMemory(fileURL: fileURL).count, 0, "garbage starts clean, never throws")
    }

    func testTheMemoryIsBoundedOldestOut() {
        var stamp = Date(timeIntervalSince1970: 0)
        let memory = SongMemory(fileURL: fileURL, maxEntries: 3, now: { stamp })
        for n in 0..<4 {
            stamp = Date(timeIntervalSince1970: Double(n))
            learn(memory, key: "song-\(n)")
        }
        XCTAssertEqual(memory.count, 3)
        XCTAssertNil(memory.entry("song-0"), "oldest out")
        XCTAssertNotNil(memory.entry("song-3"))
    }

    // MARK: - The clock

    func testARememberedGridAnchorsTheClockExactly() {
        let clock = BeatClock()
        clock.driveFromTrack(bpm: 120, position: PlaybackPosition(positionMs: 30_000, capturedAt: 500, isPlaying: true),
                             beatOffset: 0.87, barKnown: true, now: 500)
        let snap = BeatClock.snapshot()
        XCTAssertGreaterThanOrEqual(snap.phaseConfidence, 0.5, "locked at once")
        XCTAssertGreaterThanOrEqual(snap.barConfidence, Composer2Quantizer.barConfidenceForBar, "and knows the one")
        let barStart = 470 + 0.87 + 40   // track t=0 at host 470; 20 bars in
        let phase = snap.barPhase(at: barStart)
        XCTAssertLessThan(min(phase, 1 - phase), 1e-9)
    }

    func testARememberedBeatWithoutTheOneLeavesTheBarUnsure() {
        let clock = BeatClock()
        clock.driveFromTrack(bpm: 120, position: PlaybackPosition(positionMs: 30_000, capturedAt: 500, isPlaying: true),
                             beatOffset: 0.37, barKnown: false, now: 500)
        let snap = BeatClock.snapshot()
        XCTAssertGreaterThanOrEqual(snap.phaseConfidence, 0.5)
        XCTAssertLessThan(snap.barConfidence, Composer2Quantizer.barConfidenceForHalfBar)
        let phase = snap.beatPhase(at: 470.37 + 13)
        XCTAssertLessThan(min(phase, 1 - phase), 1e-9)
    }

    func testTheMicKeepsItsBeatWhenAServiceTempoArrives() {
        let clock = BeatClock()
        // The mic locked first: beats at 0.2 + k/2.
        for k in 0..<6 {
            clock.ingest(observation: BeatObservation(bpm: 120, lastBeat: 100.2 + Double(k) * 0.5, tempoConfidence: 0.8,
                                                      phaseConfidence: 0.8, barSlot: nil, barConfidence: 0))
        }
        // Then the song's tempo resolves; the service's t=0 guess sits elsewhere.
        clock.driveFromTrack(bpm: 120, position: PlaybackPosition(positionMs: 40_000, capturedAt: 103, isPlaying: true),
                             now: 103)
        let phase = BeatClock.snapshot().beatPhase(at: 103.2)
        XCTAssertLessThan(min(phase, 1 - phase), 1e-6, "the lights stay on the beat the room is hearing")
        XCTAssertEqual(clock.source, .service)
        XCTAssertGreaterThanOrEqual(BeatClock.snapshot().phaseConfidence, 0.5)
    }

    func testOnlyAMicConfirmedOffsetIsOfferedToTheMemory() {
        let clock = BeatClock()
        clock.driveFromTrack(bpm: 120, position: PlaybackPosition(positionMs: 0, capturedAt: 100, isPlaying: true),
                             beatOffset: 0.87, barKnown: true, now: 100)
        XCTAssertNil(clock.confirmedServiceOffset(now: 100), "a handed-in offset is not evidence")
        clock.ingest(observation: BeatObservation(bpm: 120, lastBeat: 100.37, tempoConfidence: 0.8,
                                                  phaseConfidence: 0.8, barSlot: nil, barConfidence: 0))
        XCTAssertEqual(try XCTUnwrap(clock.confirmedServiceOffset(now: 100.5)), 0.87, accuracy: 1e-6)
        XCTAssertNil(clock.confirmedServiceOffset(now: 103), "the mic went quiet")
    }

    // MARK: - The whole loop

    func testTheMicTeachesTheMemoryAndTheNextPlayLocksAtOnce() async throws {
        let memory = SongMemory(fileURL: fileURL)
        let clock = BeatClock()
        var simNow = 1000.0
        let mus = MusicSessionCoordinator(
            clock: clock,
            resolver: TrackTempoResolver(providers: [], fileURL: tempoURL, defaults: defaults, liveEstimate: { (0, 0) }),
            fetchArtwork: { _ in nil },
            songMemory: memory, route: { "builtIn" }, hostNow: { simNow })
        let source = ScriptedSource()
        try await mus.activate(source)

        // First play: the song starts at host 1000; its first beat is 0.37 s
        // in and bars start one beat later.
        func position(_ t: Double) -> PlaybackPosition {
            PlaybackPosition(positionMs: Int(((t - 1000) * 1000).rounded()), capturedAt: t, isPlaying: true)
        }
        source.emit(track, position(simNow))
        await waitUntil("the hinted tempo resolves") { mus.tempo != nil }
        XCTAssertFalse(mus.beatRemembered)
        var beat = 0
        while simNow < 1045 {
            simNow += 0.5
            let lastBeat = 1000.37 + 0.5 * floor((simNow - 1000.37) / 0.5)
            beat = Int(((lastBeat - 1000.37) / 0.5).rounded())
            clock.ingest(observation: BeatObservation(bpm: 120, lastBeat: lastBeat, tempoConfidence: 0.8,
                                                      phaseConfidence: 0.8, barSlot: ((1 - beat) % 4 + 4) % 4,
                                                      barConfidence: 0.8))
            if simNow.truncatingRemainder(dividingBy: 1) == 0 { source.emit(track, position(simNow)) }
        }
        let learned = try XCTUnwrap(memory.entry(SongMemory.key(for: TempoQuery(track: track), route: "builtIn")),
                                    "the confirmed offset was remembered")
        XCTAssertEqual(learned.beatOffset, 0.37, accuracy: 0.01)
        XCTAssertEqual(learned.downbeatSlot, 1)

        // Next play, after a relaunch, no microphone yet: on the beat and on
        // the one from the first drive.
        mus.deactivate()
        clock.clear()
        let next = MusicSessionCoordinator(
            clock: clock,
            resolver: TrackTempoResolver(providers: [], fileURL: tempoURL, defaults: defaults, liveEstimate: { (0, 0) }),
            fetchArtwork: { _ in nil },
            songMemory: SongMemory(fileURL: fileURL), route: { "builtIn" }, hostNow: { simNow })
        let again = ScriptedSource()
        try await next.activate(again)
        simNow = 5000
        again.emit(track, PlaybackPosition(positionMs: 0, capturedAt: 5000, isPlaying: true))
        await waitUntil("the hinted tempo resolves") { next.tempo != nil }
        XCTAssertTrue(next.beatRemembered)
        let snap = BeatClock.snapshot()
        XCTAssertGreaterThanOrEqual(snap.phaseConfidence, 0.5)
        let phase = snap.barPhase(at: 5000.87 + 8)
        XCTAssertLessThan(min(phase, 1 - phase), 0.01, "bars land where they did last time")
        next.deactivate()
    }

    private func waitUntil(timeout: TimeInterval = 2, _ message: String = "condition not met",
                           _ cond: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(cond(), message)
    }
}
