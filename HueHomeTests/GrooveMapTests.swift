// GrooveMapTests.swift
// HueHome Pro — Unit Tests ("the room is the band", step 2: the groove map)
//
// The groove map learns where kick, snare and hi-hat fall in the bar from the
// drum lanes and fires them PREDICTED on the beat grid, so a drum look lights
// on the drum instead of the render lead after it. The synthetic song: kicks
// on 1 and 3, snares on 2 and 4, hats on every eighth (PlayAlongTestSynth).
// Real-song numbers: docs/ios/play-along/beatlab, `run.sh -groove`.

import XCTest
@testable import HueHome

final class GrooveMapTests: XCTestCase {

    private typealias Synth = PlayAlongTestSynth

    private func grid(_ r: Synth.Rendered, bpm: Double, confidence: Double = 0.9) -> BeatSnapshot {
        BeatSnapshot(bpm: bpm, beatEpoch: r.beats[0].time, beatsPerBar: 4, phaseConfidence: confidence, barConfidence: 0.8)
    }

    /// Feed `r` as the microphone delivers it (1024-frame hops), a groove pass
    /// every 0.5 s like the tracker pass, and collect the predicted hits the
    /// lights would show (frames rendered every hop for 0.1 s ahead).
    private func play(_ r: Synth.Rendered, beat: BeatSnapshot, until end: Double = .infinity)
        -> (map: GrooveMap, predicted: [DrumLanes.Kind: [Double]]) {
        let analyzer = OnsetFrameAnalyzer()
        let map = GrooveMap()
        var pattern = GroovePattern.none
        var predicted: [DrumLanes.Kind: [Double]] = [.kick: [], .snare: [], .hat: []]
        var nextPass = 0.5
        let hop = 1024
        r.samples.withUnsafeBufferPointer { p in
            var k = 0
            while (k + 1) * hop <= r.samples.count {
                let start = Double(k * hop) / r.fs
                let now = start + Double(hop) / r.fs
                guard now < end else { break }
                analyzer.process(p.baseAddress! + k * hop, frameCount: hop, sampleRate: r.fs, bufferStart: start)
                if now >= nextPass {
                    nextPass += 0.5
                    pattern = map.update(analyzer.snapshot(seconds: 10), beat: beat)
                }
                for kind in DrumLanes.Kind.allCases {
                    if let hit = pattern.lastPredicted(kind, at: now + 0.1, beat: beat),
                       hit.time > (predicted[kind]!.last ?? -1) {
                        predicted[kind]!.append(hit.time)
                    }
                }
                k += 1
            }
        }
        return (map, predicted)
    }

    private func kicks(_ r: Synth.Rendered) -> [Double] {
        r.beats.enumerated().filter { $0.offset % 4 == 0 || $0.offset % 4 == 2 }.map(\.element.time)
    }

    func testItLearnsWhereEachDrumFallsInTheBar() {
        for bpm in [96.0, 120, 140] {
            let r = Synth.render(Synth.Song(bpm: bpm, bars: 16))
            // Stop a bar before the end so the song's tail doesn't fade it.
            let (map, _) = play(r, beat: grid(r, bpm: bpm), until: r.beats[r.beats.count - 4].time)
            let p = map.pattern
            XCTAssertEqual(p.slots, 16)
            let expected: [DrumLanes.Kind: Set<Int>] = [.kick: [0, 8], .snare: [4, 12], .hat: [0, 2, 4, 6, 8, 10, 12, 14]]
            for kind in DrumLanes.Kind.allCases {
                for slot in 0..<16 {
                    if expected[kind]!.contains(slot) {
                        XCTAssertGreaterThanOrEqual(p.weight(kind, slot), 0.8, "\(bpm) BPM \(kind) slot \(slot) is played")
                    } else {
                        XCTAssertLessThanOrEqual(p.weight(kind, slot), 0.3, "\(bpm) BPM \(kind) slot \(slot) is not")
                    }
                }
            }
            XCTAssertTrue(p.live[DrumLanes.Kind.kick.rawValue], "\(bpm) BPM: kicks are predicted")
            XCTAssertTrue(p.live[DrumLanes.Kind.snare.rawValue], "\(bpm) BPM: snares are predicted")
        }
    }

    func testPredictedKicksLandOnTheKicks() {
        for bpm in [96.0, 120, 140] {
            let r = Synth.render(Synth.Song(bpm: bpm, bars: 16))
            let truth = kicks(r)
            let (_, predicted) = play(r, beat: grid(r, bpm: bpm), until: truth.last! + 0.3)
            let fired = predicted[.kick]!
            let after = truth.filter { $0 > 9 }
            let onTime = after.filter { k in fired.contains { abs($0 - k) <= 0.015 } }.count
            let stray = fired.filter { p in !truth.contains { abs($0 - p) <= 0.05 } }.count
            print(String(format: "GrooveMapTests %.0f BPM: %d predicted kicks, %d of %d after 9 s within 15 ms, %d stray",
                         bpm, fired.count, onTime, after.count, stray))
            XCTAssertGreaterThanOrEqual(Double(onTime), Double(after.count) * 0.9, "\(bpm) BPM: on the kick")
            XCTAssertLessThanOrEqual(Double(stray), Double(max(1, fired.count)) * 0.1, "\(bpm) BPM: nothing between kicks")
        }
    }

    func testABreakStopsThePredictionsWithinABeatOrTwo() {
        // Eight bars of the full song, then only the chords (drums and bass stop).
        let bpm = 120.0
        let a = Synth.render(Synth.Song(bpm: bpm, bars: 16))
        let b = Synth.render(Synth.Song(bpm: bpm, bars: 16, drums: false, bass: false))
        let cut = a.beats[32].time
        var spliced = a
        let n = Int(cut * a.fs)
        spliced.samples = Array(a.samples[0..<n]) + Array(b.samples[n...])
        let (_, predicted) = play(spliced, beat: grid(spliced, bpm: bpm))
        let afterBreak = predicted[.kick]!.filter { $0 > cut - 0.05 }
        print("GrooveMapTests break: predicted kicks after it at", afterBreak.map { String(format: "%+.2f s", $0 - cut) })
        XCTAssertLessThanOrEqual(afterBreak.count, 2, "at most the two kicks it takes to notice")
        XCTAssertTrue(afterBreak.allSatisfy { $0 < cut + 1.6 }, "nothing predicted once the break is noticed")
        XCTAssertFalse(predicted[.kick]!.filter { $0 < cut }.isEmpty, "it was predicting before the break")
    }

    // MARK: - The pattern as the lights read it

    /// A 120 BPM pattern with kicks live on slots 0 and 8 (weights given).
    private func kickPattern(_ w0: Float = 1, _ w8: Float = 1) -> (GroovePattern, BeatSnapshot) {
        var p = GroovePattern.none
        p.bpm = 120; p.beatEpoch = 100; p.beatsPerBar = 4
        p.weights = [Float](repeating: 0, count: 48)
        p.offsets = [Float](repeating: 0, count: 48)
        p.strengths = [Float](repeating: 0, count: 48)
        p.weights[0] = w0; p.weights[8] = w8
        p.strengths[0] = 1; p.strengths[8] = 1
        p.live = [true, false, false]
        return (p, BeatSnapshot(bpm: 120, beatEpoch: 100, beatsPerBar: 4, phaseConfidence: 0.9, barConfidence: 0.8))
    }

    func testAHeardHitOnTheSlotIsThePredictedHit() {
        let (p, beat) = kickPattern()
        // Bar 3 starts at 106 s; slot 8 at 107 s.
        XCTAssertEqual(p.lastPredicted(.kick, at: 106.05, beat: beat)?.time ?? 0, 106, accuracy: 1e-9)
        XCTAssertEqual(p.lastPredicted(.kick, at: 106.99, beat: beat)?.time ?? 0, 106, accuracy: 1e-9)
        XCTAssertEqual(p.lastPredicted(.kick, at: 107.0, beat: beat)?.time ?? 0, 107, accuracy: 1e-9)
        // The lanes hear the 106 s kick 20 ms late: still the predicted hit.
        let same = p.latestHit(.kick, heardAt: 106.02, heardStrength: 0.7, beat: beat, at: 106.3)
        XCTAssertEqual(same.time, 106, accuracy: 1e-9, "one hit, not two")
        // A kick between the slots is one the pattern didn't predict.
        let extra = p.latestHit(.kick, heardAt: 106.5, heardStrength: 0.7, beat: beat, at: 106.7)
        XCTAssertEqual(extra.time, 106.5, accuracy: 1e-9)
        // With the drum's prediction off, a heard hit on a slot keeps the slot's
        // time — so a prediction switching off can't fire the same kick twice.
        var off = p
        off.live = [false, false, false]
        XCTAssertNil(off.lastPredicted(.kick, at: 106.3, beat: beat))
        XCTAssertEqual(off.latestHit(.kick, heardAt: 106.02, heardStrength: 0.7, beat: beat, at: 106.3).time, 106, accuracy: 1e-9)
        // Other drums aren't predicted at all.
        XCTAssertNil(p.lastPredicted(.snare, at: 106.3, beat: beat))
        XCTAssertEqual(p.latestHit(.snare, heardAt: 106.02, heardStrength: 0.5, beat: beat, at: 106.3).time, 106.02, accuracy: 1e-9)
    }

    func testNothingIsPredictedOnAnotherGrid() {
        let (p, beat) = kickPattern()
        var shaky = beat; shaky.phaseConfidence = 0.3
        XCTAssertNil(p.lastPredicted(.kick, at: 106.1, beat: shaky), "a grid Play Along doesn't trust")
        var faster = beat; faster.bpm = 126
        XCTAssertNil(p.lastPredicted(.kick, at: 106.1, beat: faster), "another tempo")
        var moved = beat; moved.beatEpoch = 100.5
        XCTAssertNil(p.lastPredicted(.kick, at: 106.1, beat: moved), "the one moved by a beat")
        var nudged = beat; nudged.beatEpoch = 100.02
        XCTAssertNotNil(p.lastPredicted(.kick, at: 106.1, beat: nudged), "a phase nudge is the same grid")
        var wholeBar = beat; wholeBar.beatEpoch = 102
        XCTAssertNotNil(p.lastPredicted(.kick, at: 106.1, beat: wholeBar), "an epoch a whole bar on is the same grid")
    }

    func testAnUncertainSlotFlashesSofter() {
        let (p, beat) = kickPattern(1, 0.6)
        let sure = p.lastPredicted(.kick, at: 106.05, beat: beat)!.strength
        let unsure = p.lastPredicted(.kick, at: 107.05, beat: beat)!.strength
        XCTAssertEqual(sure, 1, accuracy: 1e-6)
        XCTAssertLessThan(unsure, 0.7, "a slot played in 60 % of bars")
        XCTAssertGreaterThan(unsure, 0.4)
    }

    func testANewTempoStartsOver() {
        let r = Synth.render(Synth.Song(bpm: 120, bars: 12))
        let (map, _) = play(r, beat: grid(r, bpm: 120), until: r.beats[40].time)
        XCTAssertGreaterThan(map.pattern.weight(.kick, 0), 0.8)
        let other = BeatSnapshot(bpm: 100, beatEpoch: 0.3, beatsPerBar: 4, phaseConfidence: 0.9, barConfidence: 0.8)
        let analyzer = OnsetFrameAnalyzer()
        r.samples.withUnsafeBufferPointer { p in
            for k in 0..<40 { analyzer.process(p.baseAddress! + k * 1024, frameCount: 1024, sampleRate: r.fs, bufferStart: Double(k * 1024) / r.fs) }
        }
        let fresh = map.update(analyzer.snapshot(seconds: 10), beat: other)
        XCTAssertEqual(fresh.weight(.kick, 0), 0, "learned on another grid: forgotten")
        XCTAssertFalse(fresh.live.contains(true))
    }

    // MARK: - In the engine

    private func kickLook() -> Composer2Composition {
        var layer = Composer2Layer(name: "Kick", color: .solid(Composer2XY(x: 0.3127, y: 0.329)),
                                   motion: Composer2Motion(kind: .static),
                                   rhythm: Composer2Rhythm(shape: .steady, maxBrightness: 0.4))
        layer.audio = Composer2AudioModulation(source: .kick, smoothing: 0, intensity: 0.8)
        layer.audio.targets = [.brightness, .palettePosition]
        layer.audio.paletteStep = 0.25
        return Composer2Composition(name: "Kick", createdAt: Date(timeIntervalSince1970: 0), layers: [layer])
    }

    func testAKickLookLightsOnThePredictedKick() {
        let (p, beat) = kickPattern()
        let look = kickLook()
        let g = Composer2SlotGeometry.linear(count: 2)
        var state = Composer2EngineState()
        var f = AudioFeatures()
        f.groove = p
        f.lastKickAt = 105.0; f.kickStrength = 1     // the last kick HEARD was a bar ago
        let before = Composer2Engine.evaluate(look, time: 1, geometry: g, state: &state, audio: f, beat: beat,
                                              hostNow: 105.97)[0].brightness
        let on = Composer2Engine.evaluate(look, time: 1.04, geometry: g, state: &state, audio: f, beat: beat,
                                          hostNow: 106.01)[0].brightness
        XCTAssertEqual(before, 0.4, accuracy: 0.05, "nothing before the kick")
        XCTAssertGreaterThan(on, 0.8, "the frame shown at the kick lights it, before the lanes have heard it")
        XCTAssertEqual(f.lastKickAt, 105.0, "(nothing heard yet)")
    }

    func testThePredictedKickAndItsHeardCopyStepThePaletteOnce() {
        let (p, beat) = kickPattern()
        let look = kickLook()
        let g = Composer2SlotGeometry.linear(count: 2)
        var state = Composer2EngineState()
        var f = AudioFeatures()
        f.groove = p
        _ = Composer2Engine.evaluate(look, time: 1, geometry: g, state: &state, audio: f, beat: beat, hostNow: 105.9)
        _ = Composer2Engine.evaluate(look, time: 1.2, geometry: g, state: &state, audio: f, beat: beat, hostNow: 106.1)
        let afterPredicted = state.layers.first?.paletteStepPhase ?? -1
        f.lastKickAt = 106.018; f.kickStrength = 0.9  // the lanes hear it
        _ = Composer2Engine.evaluate(look, time: 1.3, geometry: g, state: &state, audio: f, beat: beat, hostNow: 106.2)
        XCTAssertEqual(state.layers.first?.paletteStepPhase ?? -2, afterPredicted, accuracy: 1e-9, "the same kick")
        f.lastKickAt = 106.5  // a kick the pattern didn't predict
        _ = Composer2Engine.evaluate(look, time: 1.7, geometry: g, state: &state, audio: f, beat: beat, hostNow: 106.6)
        XCTAssertNotEqual(state.layers.first?.paletteStepPhase ?? -2, afterPredicted, "a new kick steps it")
    }
}
