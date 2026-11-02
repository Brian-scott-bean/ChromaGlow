// SongEnergyTests.swift
// HueHome Pro — Unit Tests ("it knows what's coming", step 2: energy states, build and drop, build 921)
//
// The energy state machine on synthetic bar histories: a build staged onto
// the phrase line and confirmed when the bass and kick come back, a build
// that leads nowhere easing back, a steady groove never building, a
// breakdown, and the one-beat gap. Real-music numbers are the beat lab's
// `run.sh -drop`.

import XCTest
@testable import HueHome

final class SongEnergyTests: XCTestCase {

    private let barSeconds = 2.0        // 120 BPM
    private let beatSeconds = 0.5

    /// A phrase grid starting on bar 0 (beats ≡ 0 mod 32), sure of itself.
    private func structure(now: Double, confidence: Double = 0.9) -> SongStructure {
        let beats = Int(floor(now / beatSeconds))
        return SongStructure(songStart: 0.001, barsCompleted: Int(floor(now / barSeconds)),
                             currentBarStart: floor(now / barSeconds) * barSeconds, barSeconds: barSeconds,
                             beatsCompleted: beats, currentBeatStart: Double(beats) * beatSeconds,
                             beatSeconds: beatSeconds, phraseBeats: 32, phraseOffset: 0, phraseConfidence: confidence)
    }

    private enum Kind { case groove, build, drop, breakdown, quiet }

    /// One bar of each kind (`j` = bar within its section, of `n`).
    private func bar(_ kind: Kind, index: Int, j: Int = 0, n: Int = 8) -> SongBar {
        let start = Double(index) * barSeconds
        var b = SongBar(start: start, end: start + barSeconds)
        let progress = Float(j) / Float(max(1, n))
        switch kind {
        case .groove:
            b.energy = 3; b.loudness = 3; b.sub = 3; b.bass = 0.9; b.drums = 0.9; b.density = 1
            b.flatness = 0.2; b.high = 0.3
        case .build:
            // Climbing, the low end gone, the snare roll doubling, a riser.
            b.energy = 2.6 + 0.5 * progress; b.loudness = 2.8 + 0.4 * progress; b.sub = 1.5
            b.bass = 0.05; b.drums = 0.7
            b.density = progress < 0.5 ? 1 : progress < 0.75 ? 2 : 4
            b.flatness = 0.2 + 0.3 * progress; b.high = 0.3 + 0.6 * progress
        case .drop:
            b.energy = 3.6; b.loudness = 3.6; b.sub = 3.2; b.bass = 1; b.drums = 1; b.density = 1.5
            b.flatness = 0.2; b.high = 0.4
        case .breakdown:
            b.energy = 2.2; b.loudness = 2; b.sub = 1; b.bass = 0.1; b.drums = 0.05; b.density = 0
            b.flatness = 0.15; b.high = 0.1
        case .quiet:
            b.energy = 1.5; b.loudness = 1.5; b.sub = 0.5; b.bass = 0; b.drums = 0; b.density = 0
            b.flatness = 0.1; b.high = 0.05
        }
        return b
    }

    /// Feeds sections bar by bar; returns the energy after each bar.
    @discardableResult
    private func play(_ tracker: SongEnergyTracker, _ sections: [(Kind, Int)], from first: Int = 0,
                      history: inout [SongBar], confidence: Double = 0.9) -> [SongEnergy] {
        var out: [SongEnergy] = []
        var index = first
        for (kind, n) in sections {
            for j in 0..<n {
                history.append(bar(kind, index: index, j: j, n: n))
                tracker.barFinished(history, structure: structure(now: history.last!.end, confidence: confidence))
                out.append(tracker.energy)
                index += 1
            }
        }
        return out
    }

    // MARK: -

    func testABuildIsStagedOnThePhraseLineAndTheDropConfirmed() {
        // Groove for bars 0–15, a build 16–23, the drop on bar 24 (a phrase line: beat 96 ≡ 0 mod 32).
        let tracker = SongEnergyTracker()
        var history: [SongBar] = []
        let groove = play(tracker, [(.groove, 16)], history: &history)
        XCTAssertFalse(groove.contains { $0.state == .build }, "a steady groove never builds")
        let build = play(tracker, [(.build, 8)], from: 16, history: &history)
        XCTAssertTrue(build.suffix(4).allSatisfy { $0.state == .build }, "building by the build's fifth bar")
        let dropTime = 24 * barSeconds
        guard let staged = build.last else { return XCTFail() }
        XCTAssertEqual(staged.dropAt, dropTime, accuracy: 1e-6, "staged on the phrase line")
        XCTAssertGreaterThanOrEqual(staged.dropConfidence, 0.5)
        XCTAssertGreaterThan(staged.buildProgress(at: dropTime - 1), 0.8)
        let after = play(tracker, [(.drop, 2)], from: 24, history: &history)
        XCTAssertEqual(after.last?.state, .peak)
        XCTAssertEqual(after.last?.lastDropAt ?? 0, dropTime, accuracy: 1e-6, "the drop came")
        XCTAssertEqual(after.last?.dropAt, 0, "nothing staged any more")
    }

    func testABuildThatLeadsNowhereEasesBack() {
        let tracker = SongEnergyTracker()
        var history: [SongBar] = []
        play(tracker, [(.groove, 16), (.build, 8)], history: &history)
        XCTAssertEqual(tracker.energy.state, .build)
        // No drop on bar 24: a breakdown instead.
        let after = play(tracker, [(.breakdown, 3)], from: 24, history: &history)
        XCTAssertNotEqual(after.last?.state, .build, "eased back within a bar or two")
        XCTAssertNotEqual(after.last?.state, .peak)
        XCTAssertEqual(after.last?.dropAt, 0)
        XCTAssertEqual(after.last?.dropConfidence, 0)
        XCTAssertEqual(after.last?.lastDropAt, 0, "no drop recorded")
    }

    func testDrumsDroppingOutIsABreakdown() {
        let tracker = SongEnergyTracker()
        var history: [SongBar] = []
        let states = play(tracker, [(.groove, 12), (.breakdown, 6)], history: &history).map(\.state)
        XCTAssertTrue(states.suffix(4).allSatisfy { $0 == .breakdown })
        XCTAssertFalse(states.contains(.build))
    }

    func testAnUnsurePhraseGridStagesOnTheBuildsOwnBars() {
        // Phrase confidence 0: the drop goes on the 4-, 8- or 16-bar line from
        // the build's start, and the call is less sure.
        let tracker = SongEnergyTracker()
        var history: [SongBar] = []
        let sure = SongEnergyTracker()
        var sureHistory: [SongBar] = []
        play(tracker, [(.groove, 16), (.build, 7)], history: &history, confidence: 0)
        play(sure, [(.groove, 16), (.build, 7)], history: &sureHistory, confidence: 0.9)
        let e = tracker.energy
        XCTAssertEqual(e.state, .build)
        let fromStart = (e.dropAt - e.buildStart) / barSeconds
        XCTAssertTrue([4.0, 8, 16].contains { abs($0 - fromStart) < 1e-6 }, "\(fromStart) bars from the build's start")
        XCTAssertLessThan(e.dropConfidence, sure.energy.dropConfidence)
    }

    func testTheGapBeforeTheDropSaysNow() {
        // An unsure phrase grid (so the call isn't already certain).
        let tracker = SongEnergyTracker()
        var history: [SongBar] = []
        play(tracker, [(.groove, 16), (.build, 7)], history: &history, confidence: 0)
        let staged = tracker.energy
        XCTAssertEqual(staged.state, .build)
        // The build's last bar: three loud beats, then the sound falls away.
        let s = structure(now: 47, confidence: 0)
        for (k, level) in [Float(3.2), 3.3, 3.4, 3.5, 1.0].enumerated() {
            tracker.beatFinished(level: level, end: 45.5 + Double(k) * beatSeconds, structure: s)
        }
        XCTAssertGreaterThan(tracker.energy.dropConfidence, staged.dropConfidence, "the gap raises the call")
        XCTAssertEqual(tracker.energy.dropAt, 47.5, accuracy: 1e-6, "the drop is where the gap ends")
    }

    func testTheSnapshotCarriesTheEnergy() {
        XCTAssertEqual(SongStructure.none.energy, .none)
        XCTAssertEqual(SongEnergy.none.state, .unknown)
        XCTAssertEqual(SongEnergy.none.buildProgress(at: 10), 0)
        XCTAssertEqual(AudioFeatures().structure.energy.dropAt, 0)
    }
}
