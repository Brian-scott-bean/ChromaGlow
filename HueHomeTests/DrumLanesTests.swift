// DrumLanesTests.swift
// HueHome Pro — Unit Tests ("the room is the band", step 1: drum lanes)
//
// Kick, snare and hi-hat, each heard on its own from the analyzer's 10 ms
// frames. The synthetic song has kicks on 1 and 3, snares on 2 and 4, hats on
// every eighth and a bass note on EVERY beat — so a kick lane that fires on
// bass notes fires on 2 and 4, and fails here. The real-song numbers are the
// beat lab's (docs/ios/play-along/beatlab, `run.sh -drums`, `-kickbass`).
// One known limit is recorded as an expected failure, not loosened:
// `testABassLineWithNoDrumsIsAKnownLimit`.

import XCTest
@testable import HueHome

final class DrumLanesTests: XCTestCase {

    private typealias Synth = PlayAlongTestSynth

    /// Firings of each lane, fed as the microphone delivers (1024-frame hops).
    private func lanes(_ r: Synth.Rendered) -> [String: [Double]] {
        let analyzer = OnsetFrameAnalyzer()
        let hop = 1024
        var out: [String: [Double]] = ["kick": [], "snare": [], "hat": []]
        var lastTime = -Double.infinity
        r.samples.withUnsafeBufferPointer { p in
            var k = 0
            while (k + 1) * hop <= r.samples.count {
                analyzer.process(p.baseAddress! + k * hop, frameCount: hop, sampleRate: r.fs,
                                 bufferStart: Double(k * hop) / r.fs)
                let end = (k + 2) * hop > r.samples.count
                if k % 8 == 7 || end {
                    // Held hits are marked back on their onset frame: read only
                    // settled frames (the end flushes the rest).
                    let f = analyzer.snapshot(seconds: 0.5)
                    let settled = end ? Double.infinity : (f.times.last ?? 0) - DrumLanes.settleSeconds
                    for i in 0..<f.count where f.times[i] > lastTime && f.times[i] <= settled {
                        if f.kick[i] > 0 { out["kick"]!.append(f.times[i]) }
                        if f.snare[i] > 0 { out["snare"]!.append(f.times[i]) }
                        if f.hat[i] > 0 { out["hat"]!.append(f.times[i]) }
                        lastTime = f.times[i]
                    }
                }
                k += 1
            }
        }
        return out
    }

    private func near(_ t: Double, _ list: [Double], _ w: Double = 0.05) -> Bool { list.contains { abs($0 - t) <= w } }

    private struct Truth { var kicks: [Double] = []; var snares: [Double] = []; var hats: [Double] = []; var beats: [Double] = [] }

    private func truth(_ r: Synth.Rendered, bpm: Double, from: Double) -> Truth {
        var t = Truth()
        let half = 60 / bpm / 2
        for (i, b) in r.beats.enumerated() where b.time >= from {
            t.beats.append(b.time)
            if i % 4 == 0 || i % 4 == 2 { t.kicks.append(b.time) } else { t.snares.append(b.time) }
            t.hats.append(b.time)
            t.hats.append(b.time + half)
        }
        return t
    }

    func testEachDrumIsHeardOnItsOwn() {
        for bpm in [96.0, 120, 140] {
            let r = Synth.render(Synth.Song(bpm: bpm, bars: 16))
            let fired = lanes(r)
            let from = 3.0, to = r.beats.last!.time + 0.2
            let truth = truth(r, bpm: bpm, from: from)
            func inWindow(_ x: [Double]) -> [Double] { x.filter { $0 >= from - 0.05 && $0 <= to } }
            let kicks = inWindow(fired["kick"]!), snares = inWindow(fired["snare"]!), hats = inWindow(fired["hat"]!)

            let kickRecall = Double(truth.kicks.filter { near($0, kicks) }.count) / Double(truth.kicks.count)
            let kickOnBassOnly = truth.snares.filter { near($0, kicks) }.count
            let snareRecall = Double(truth.snares.filter { near($0, snares) }.count) / Double(truth.snares.count)
            let snareOnKick = truth.kicks.filter { near($0, snares) }.count
            let hatRecall = Double(truth.hats.filter { near($0, hats) }.count) / Double(truth.hats.count)
            print(String(format: "DrumLanesTests %.0f BPM: kick %.2f (on 2/4 with bass: %d of %d), snare %.2f (on 1/3: %d), hat %.2f",
                         bpm, kickRecall, kickOnBassOnly, truth.snares.count, snareRecall, snareOnKick, hatRecall))
            XCTAssertGreaterThanOrEqual(kickRecall, 0.9, "\(bpm) BPM: kicks heard")
            XCTAssertLessThanOrEqual(Double(kickOnBassOnly), Double(truth.snares.count) * 0.15,
                                     "\(bpm) BPM: a bass note under a snare is not a kick")
            XCTAssertGreaterThanOrEqual(snareRecall, 0.85, "\(bpm) BPM: snares heard")
            XCTAssertLessThanOrEqual(Double(snareOnKick), Double(truth.kicks.count) * 0.15, "\(bpm) BPM: a kick is not a snare")
            XCTAssertGreaterThanOrEqual(hatRecall, 0.6, "\(bpm) BPM: hats heard")
            // Every firing lands on something that was played.
            for (kind, list, played) in [("kick", kicks, truth.kicks), ("snare", snares, truth.snares), ("hat", hats, truth.hats)] {
                let stray = list.filter { !near($0, played) }.count
                XCTAssertLessThanOrEqual(Double(stray), Double(max(1, list.count)) * 0.15, "\(bpm) BPM: \(kind) fires on nothing")
            }
        }
    }

    func testChordsAloneFireNoDrums() {
        let quiet = Synth.render(Synth.Song(bpm: 120, bars: 8, drums: false, bass: false))
        let q = lanes(quiet)
        XCTAssertEqual(q["kick"]!.filter { $0 > 2 }.count + q["snare"]!.filter { $0 > 2 }.count, 0, "chords alone fire nothing")
    }

    /// KNOWN LIMIT (decided in build 915, README §21): a bass line with no
    /// drums at all fires the kick lane on its notes. Through the analyzer's
    /// 47 Hz bins a bass note that starts from silence rises like a kick; the
    /// lane tells them apart by loudness against the song's loudest low end
    /// (`kickLevelGate`), and with no kick in the song that loudest low end
    /// IS the bass. Waiting for the decay (a kick dies away, a bass note
    /// holds) separates them, but publishes kicks 80–120 ms late and on the
    /// lab's real mixes scored no better than the gate — so the lanes don't
    /// wait. If this ever passes, the expected failure below fails: remove it
    /// and tighten the test.
    func testABassLineWithNoDrumsIsAKnownLimit() {
        let r = Synth.render(Synth.Song(bpm: 120, bars: 12, drums: false))
        let fired = lanes(r)
        let notes = r.beats.filter { $0.time > 3 }.count
        let kicks = fired["kick"]!.filter { $0 > 3 }.count
        let snares = fired["snare"]!.filter { $0 > 3 }.count
        print("DrumLanesTests bass only: \(kicks) kicks, \(snares) snares for \(notes) bass notes")
        // What holds: never more than one kick per note, and no snares.
        XCTAssertLessThanOrEqual(kicks, notes, "one firing per bass note at most")
        XCTAssertLessThanOrEqual(Double(snares), Double(notes) * 0.1, "a bass line is not a snare")
        XCTExpectFailure("Known limit: a bass line with no drums reads as kicks (README §21)") {
            XCTAssertLessThanOrEqual(Double(kicks), Double(notes) * 0.15, "a bass line is not a kick drum")
        }
    }

    func testTheLatestHitsReachTheFeatures() {
        let r = Synth.render(Synth.Song(bpm: 120, bars: 6))
        let analyzer = OnsetFrameAnalyzer()
        r.samples.withUnsafeBufferPointer { p in
            var k = 0
            while (k + 1) * 1024 <= r.samples.count {
                analyzer.process(p.baseAddress! + k * 1024, frameCount: 1024, sampleRate: r.fs, bufferStart: Double(k * 1024) / r.fs)
                k += 1
            }
        }
        let hits = analyzer.drumHits()
        let end = Double(r.samples.count) / r.fs
        XCTAssertGreaterThan(hits.kickAt, end - 2.5)
        XCTAssertGreaterThan(hits.snareAt, end - 2.5)
        XCTAssertGreaterThan(hits.hatAt, end - 2.5)
        XCTAssertGreaterThan(hits.kickStrength, 0)
        XCTAssertLessThanOrEqual(hits.kickStrength, 1)

        var f = AudioFeatures()
        f.adopt(hits)
        XCTAssertEqual(f.lastKickAt, hits.kickAt)
        XCTAssertEqual(f.snareStrength, hits.snareStrength)
        XCTAssertEqual(f.lastHatAt, hits.hatAt)
    }

    // MARK: - The sources

    func testEachDrumSourcePunchesOnlyOnItsDrum() {
        var f = AudioFeatures()
        f.lastKickAt = 10; f.kickStrength = 0.8
        f.lastSnareAt = 9; f.snareStrength = 1
        f.lastOnsetAt = 10
        let kick = Composer2AudioModulation(source: .kick, punchDecay: 0.4)
        let snare = Composer2AudioModulation(source: .snare, punchDecay: 0.4)
        let hat = Composer2AudioModulation(source: .hat, punchDecay: 0.4)
        XCTAssertEqual(kick.rawDrive(features: f, beat: .none, hostNow: 10), 0.8, accuracy: 1e-6, "as hard as it was struck")
        XCTAssertLessThan(snare.rawDrive(features: f, beat: .none, hostNow: 10), 0.2, "the snare was a second ago")
        XCTAssertEqual(hat.rawDrive(features: f, beat: .none, hostNow: 10), 0, "no hat yet")
        XCTAssertEqual(kick.rawDrive(features: f, beat: .none, hostNow: 9.5), 0, "a frame shown before the hit")

        for m in [kick, snare, hat] {
            XCTAssertTrue(m.isHit)
            XCTAssertTrue(m.usesMicrophoneBands)
            var moving = m
            moving.travel = .roll
            XCTAssertTrue(moving.travels, "a drum's punches can move across the room")
            XCTAssertEqual(m.paletteOffset(drive: 1), 0, "a hit steps the palette instead")
        }
        XCTAssertEqual(kick.lastHitTime(f), 10)
        XCTAssertEqual(snare.lastHitTime(f), 9)
        XCTAssertEqual(Composer2AudioModulation(source: .amplitude).lastHitTime(f), 10, "others hear any hit, as before")
    }

    func testDrumSourcesSaveAndOlderLooksStillRead() throws {
        for source in [Composer2AudioModulation.Source.kick, .snare, .hat] {
            let m = Composer2AudioModulation(source: source, intensity: 0.6)
            XCTAssertEqual(try JSONDecoder().decode(Composer2AudioModulation.self, from: JSONEncoder().encode(m)), m)
        }
        let future = Data(#"{"source":"cowbell","intensity":0.5}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(Composer2AudioModulation.self, from: future).source, .off,
                       "a source this version doesn't know is silent, not an error")
    }

    func testAKickLookPunchesOnKicksInTheEngine() {
        var layer = Composer2Layer(name: "Kick", color: .solid(Composer2XY(x: 0.3127, y: 0.329)),
                                   motion: Composer2Motion(kind: .static),
                                   rhythm: Composer2Rhythm(shape: .steady, maxBrightness: 0.4))
        layer.audio = Composer2AudioModulation(source: .kick, smoothing: 0, intensity: 0.8)
        let look = Composer2Composition(name: "Kick", createdAt: Date(timeIntervalSince1970: 0), layers: [layer])
        let g = Composer2SlotGeometry.linear(count: 2)
        var state = Composer2EngineState()
        var f = AudioFeatures()
        f.lastSnareAt = 100; f.snareStrength = 1
        let before = Composer2Engine.evaluate(look, time: 1, geometry: g, state: &state, audio: f, hostNow: 100.01)[0].brightness
        f.lastKickAt = 100.02; f.kickStrength = 1
        let after = Composer2Engine.evaluate(look, time: 1.02, geometry: g, state: &state, audio: f, hostNow: 100.03)[0].brightness
        XCTAssertEqual(before, 0.4, accuracy: 0.01, "a snare doesn't move a kick look")
        XCTAssertGreaterThan(after, 0.8, "a kick does")
    }
}
