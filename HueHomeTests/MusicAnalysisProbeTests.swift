// MusicAnalysisProbeTests.swift
// HueHome Pro — Unit Tests (Debug-only music analysis probe)
//
// The probe's test song must be exactly what its truth says — 72 bars at
// 128 BPM with seven sections — or the phone's numbers mean nothing. The
// scores must count the way the lab's do. And on an iOS 27 simulator the
// whole chain must run: the song into Apple's Music Understanding, beats out.

import XCTest
@testable import HueHome
#if canImport(MusicUnderstanding)
import MusicUnderstanding
#endif

final class MusicAnalysisProbeTests: XCTestCase {

    func testTheTestSongIsWhatItsTruthSays() {
        let song = MusicAnalysisProbe.makeTestSong(sampleRate: 22_050)
        let beat = 60 / 128.0
        XCTAssertEqual(song.beats.count, 72 * 4)
        XCTAssertEqual(song.beats.first ?? 0, 0.5, accuracy: 1e-9)
        for (a, b) in zip(song.beats, song.beats.dropFirst()) { XCTAssertEqual(b - a, beat, accuracy: 1e-9) }
        XCTAssertEqual(song.sectionNames, ["intro", "build", "drop", "breakdown", "build", "drop", "outro"])
        let bars = [8, 16, 32, 40, 48, 64].map { 0.5 + Double($0) * 4 * beat }
        XCTAssertEqual(song.sectionStarts.count, bars.count)
        for (a, b) in zip(song.sectionStarts, bars) { XCTAssertEqual(a, b, accuracy: 1e-9) }
        XCTAssertEqual(song.duration, 0.5 + 72 * 4 * beat + 1.5, accuracy: 0.01)
        XCTAssertTrue(song.samples.allSatisfy { $0.isFinite && abs($0) <= 0.9001 })
        XCTAssertEqual(song.samples.map { abs($0) }.max() ?? 0, 0.9, accuracy: 1e-4, "normalised")

        // The drops are louder than the breakdown, so structure has something to find.
        func rms(_ from: Double, _ to: Double) -> Float {
            let s = song.samples[Int(from * song.sampleRate)..<Int(to * song.sampleRate)]
            return (s.reduce(0) { $0 + $1 * $1 } / Float(s.count)).squareRoot()
        }
        let drop = rms(song.sectionStarts[1], song.sectionStarts[2])
        let breakdown = rms(song.sectionStarts[2], song.sectionStarts[3])
        XCTAssertGreaterThan(drop, breakdown * 1.5)
        XCTAssertEqual(MusicAnalysisProbe.makeTestSong(sampleRate: 22_050).samples, song.samples, "deterministic")
    }

    func testScoresCountLikeTheLab() {
        let truth = (0..<40).map { 5.0 + Double($0) * 0.5 }
        XCTAssertEqual(MusicAnalysisProbe.beatF(reference: truth, found: truth), 1)
        XCTAssertEqual(MusicAnalysisProbe.beatF(reference: truth, found: truth.map { $0 + 0.05 }), 1, "within ±70 ms")
        XCTAssertEqual(MusicAnalysisProbe.beatF(reference: truth, found: truth.map { $0 + 0.1 }), 0)
        let every2nd = stride(from: 0, to: truth.count, by: 2).map { truth[$0] }
        XCTAssertEqual(MusicAnalysisProbe.beatF(reference: truth, found: every2nd), 2.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(MusicAnalysisProbe.beatF(reference: truth, found: []), 0)
        XCTAssertEqual(MusicAnalysisProbe.boundaryHits(truth: [10, 20, 30], found: [11.5, 26, 30.2]), 2)
    }

    #if canImport(MusicUnderstanding)
    func testTheSongRunsThroughMusicUnderstanding() async throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("Music Understanding needs iOS 27") }
        let song = MusicAnalysisProbe.makeTestSong(sampleRate: 22_050)
        // The first drop and a little either side: 30 s.
        let start = song.sectionStarts[1] - 5
        let r = try await MusicAnalysisProbe.analyze(song, start: start, duration: 30, types: [.rhythm])
        XCTAssertGreaterThan(r.beats.count, 30, "beats found")
        let truth = song.beats.filter { $0 >= start + 5 && $0 < start + 25 }
        let found = r.beats.filter { $0 >= start + 5 && $0 < start + 25 }
        let f = MusicAnalysisProbe.beatF(reference: truth, found: found)
        print(String(format: "MusicAnalysisProbeTests: %d beats, F %.2f, BPM %@, %.2f s",
                     r.beats.count, f, r.bpm.map { String(format: "%.1f", $0) } ?? "—", r.seconds))
        XCTAssertGreaterThan(f, 0.8, "beats land where the song's beats are")
    }
    #endif
}
