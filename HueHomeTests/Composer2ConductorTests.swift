// Composer2ConductorTests.swift
// HueHome Pro — Unit Tests ("it knows what's coming", step 3: the Conductor, build 922)
//
// Play Along → Follow the song: punches tighten every 4 → 2 → 1 beats onto a
// staged drop (one lands ON it), the room dims half a beat before it only
// at ≥ 0.9 confidence (a fall, never a flash), the drop's bar punches every
// beat — and every built-in look stays inside the flash gate.

import XCTest
@testable import HueHome

final class Composer2ConductorTests: XCTestCase {

    private let grid = BeatSnapshot(bpm: 120, beatEpoch: 0, beatsPerBar: 4, phaseConfidence: 1, barConfidence: 1)

    /// A song building from 100 s toward a drop staged at 116 s (8 bars at 120 BPM).
    private func building(confidence: Double, dropAt: Double = 116) -> SongStructure {
        var s = SongStructure(songStart: 1, barsCompleted: 49, currentBarStart: 98, barSeconds: 2,
                              beatsCompleted: 196, currentBeatStart: 98, beatSeconds: 0.5,
                              phraseBeats: 32, phraseOffset: 0, phraseConfidence: 0.8)
        s.energy = SongEnergy(state: .build, level: 0.8, buildScore: 0.8, buildStart: 100, dropAt: dropAt,
                              dropConfidence: confidence, lastDropAt: 0)
        return s
    }

    private func dropped(at t: Double) -> SongStructure {
        var s = building(confidence: 0)
        s.energy = SongEnergy(state: .peak, level: 1, buildScore: 0, buildStart: 0, dropAt: 0, dropConfidence: 0, lastDropAt: t)
        return s
    }

    // MARK: - The cue

    func testNothingWithoutASureStagedDrop() {
        XCTAssertEqual(Composer2Conductor.cue(.none, beat: grid, at: 101), .off)
        XCTAssertEqual(Composer2Conductor.cue(building(confidence: 0.4), beat: grid, at: 101), .off, "below 0.5")
        var groove = building(confidence: 0.9)
        groove.energy.state = .groove
        XCTAssertEqual(Composer2Conductor.cue(groove, beat: grid, at: 101), .off)
        XCTAssertEqual(Composer2Conductor.cue(building(confidence: 0.9), beat: .none, at: 101), .off, "no clock")
    }

    func testTheBuildTightensOntoTheDrop() {
        let song = building(confidence: 0.7)
        let early = Composer2Conductor.cue(song, beat: grid, at: 101)
        let middle = Composer2Conductor.cue(song, beat: grid, at: 108)
        let late = Composer2Conductor.cue(song, beat: grid, at: 114)
        XCTAssertEqual(early.phase, .early); XCTAssertEqual(early.beatEvery, 4)
        XCTAssertEqual(middle.phase, .middle); XCTAssertEqual(middle.beatEvery, 2)
        XCTAssertEqual(late.phase, .late); XCTAssertEqual(late.beatEvery, 1)
        XCTAssertLessThan(early.punchScale, middle.punchScale)
        XCTAssertLessThan(middle.punchScale, late.punchScale)
        XCTAssertEqual(early.beatAnchor, 232, "the drop's beat on the grid (116 s / 0.5 s)")
        XCTAssertEqual(late.dim, 1, "0.7 is not sure enough to dim")

        // Every 4 beats counted from the drop: one punch lands ON it.
        var m = Composer2PlayAlong.punch(feel: .hit, base: true, layer: Composer2Layer(name: "x"), beat: 0.5)
        m.beatEvery = 4
        m.beatAnchor = early.beatAnchor
        XCTAssertEqual(m.rawDrive(features: .silent, beat: grid, hostNow: 116.001), 1, accuracy: 0.02, "on the drop")
        XCTAssertEqual(m.rawDrive(features: .silent, beat: grid, hostNow: 114.001), 1, accuracy: 0.02, "4 beats before")
        XCTAssertLessThan(m.rawDrive(features: .silent, beat: grid, hostNow: 115.001), 0.1, "not 2 beats before")
        XCTAssertLessThan(m.rawDrive(features: .silent, beat: grid, hostNow: 115.501), 0.1, "nor 1")
    }

    func testTheDimNeedsCertaintyAndOnlyFalls() {
        let sure = building(confidence: 0.95)
        XCTAssertEqual(Composer2Conductor.cue(sure, beat: grid, at: 115.7).dim, 1, "not before the last half beat")
        var previous = 1.0
        for t in stride(from: 115.75, to: 116, by: 0.02) {
            let c = Composer2Conductor.cue(sure, beat: grid, at: t)
            XCTAssertEqual(c.phase, .preDrop)
            XCTAssertLessThanOrEqual(c.dim, previous + 1e-12, "a fall, never a rise")
            XCTAssertGreaterThanOrEqual(c.dim, Composer2Conductor.dimFloor - 1e-9)
            previous = c.dim
        }
        XCTAssertLessThan(previous, 0.45)
        let atDrop = Composer2Conductor.cue(sure, beat: grid, at: 116.01)
        XCTAssertEqual(atDrop.phase, .drop); XCTAssertEqual(atDrop.dim, 1); XCTAssertEqual(atDrop.beatEvery, 1)
        // 0.85: the build is shaped, but never a blackout.
        for t in stride(from: 115.75, to: 116, by: 0.02) {
            XCTAssertEqual(Composer2Conductor.cue(building(confidence: 0.85), beat: grid, at: t).dim, 1)
        }
    }

    func testTheDropsBarPunchesEveryBeat() {
        let c = Composer2Conductor.cue(dropped(at: 116), beat: grid, at: 116.5)
        XCTAssertEqual(c.phase, .drop)
        XCTAssertEqual(c.beatEvery, 1)
        XCTAssertGreaterThan(c.punchScale, 1)
        XCTAssertEqual(Composer2Conductor.cue(dropped(at: 116), beat: grid, at: 118.1), .off, "a bar later")
    }

    func testLandAtTimeT() {
        XCTAssertEqual(Composer2Quantizer.landing(at: 116.03, beat: grid) ?? 0, 116, accuracy: 1e-9)
        XCTAssertEqual(Composer2Quantizer.landing(at: 115.9, beat: grid) ?? 0, 116, accuracy: 1e-9)
        XCTAssertNil(Composer2Quantizer.landing(at: 116, beat: .none))
    }

    // MARK: - The look

    func testOnlyBeatPunchesAreShaped() throws {
        // A built-in look that Hit gives beat punches (a still, steady look
        // plays as Glide: nothing to reshape).
        guard let look = Composer2PresetLibrary.all.first(where: { look in
            Composer2PlayAlong.apply(look, feel: .hit, bpm: 120).layers.contains { $0.audio.source == .beat }
        }) else { return XCTFail("no built-in look punches on the beat") }
        let played = Composer2PlayAlong.apply(look, feel: .hit, bpm: 120)
        let cue = Composer2Conductor.cue(building(confidence: 0.7), beat: grid, at: 101)
        let shaped = Composer2Conductor.apply(cue, to: played)
        XCTAssertEqual(shaped.layers.count, played.layers.count)
        var changed = 0
        for (a, b) in zip(played.layers, shaped.layers) {
            if a.audio.source == .beat && a.audio.isActive {
                changed += 1
                XCTAssertEqual(b.audio.beatEvery, 4)
                XCTAssertEqual(b.audio.beatAnchor, 232)
                XCTAssertEqual(b.audio.travel, .together)
                XCTAssertEqual(b.audio.intensity, min(1, a.audio.intensity * cue.punchScale), accuracy: 1e-9)
            } else {
                XCTAssertEqual(a, b, "authored sound is left alone")
            }
        }
        XCTAssertGreaterThan(changed, 0)
        XCTAssertEqual(Composer2Conductor.apply(.off, to: played), played)
        // The band's punches are its drums (kick, snare): left alone.
        let band = Composer2PlayAlong.apply(look, feel: .hit, bpm: 120, band: true)
        XCTAssertEqual(Composer2Conductor.apply(cue, to: band), band)
        // Encoded only when set; round trip.
        let plain = try JSONEncoder().encode(Composer2AudioModulation(source: .beat))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("beatEvery"))
        if let m = shaped.layers.first(where: { $0.audio.beatEvery == 4 })?.audio {
            XCTAssertEqual(try JSONDecoder().decode(Composer2AudioModulation.self, from: JSONEncoder().encode(m)), m)
        }
    }

    // MARK: - Every built-in look through a conducted build and drop

    func testConductedDropsStayInsideTheFlashGate() {
        var report: [String] = []
        var totalHolds = 0
        for look in Composer2PresetLibrary.all {
            let r = play(look)
            totalHolds += r.holds
            report.append(String(format: "%@ shaped=%.3f holds=%d dimmed=%@", look.name, r.shaped, r.holds, r.dimmed ? "yes" : "no"))
            XCTAssertLessThanOrEqual(r.holds, 3, "\(look.name): the wire gate held \(r.holds) frames")
        }
        report.append("TOTAL holds \(totalHolds) over \(Composer2PresetLibrary.all.count) looks")
        print("Composer2ConductorTests gate report:\n" + report.joined(separator: "\n"))
    }

    /// Hit feel, Follow the song on, a sure drop staged at 116 s: 8 s of the
    /// build (with the dim), the drop, and a bar after it, through the live
    /// output on the 20 ms grid and an independent copy of the wire gate.
    private func play(_ look: Composer2Composition) -> (shaped: Double, holds: Int, dimmed: Bool) {
        let output = Composer2LiveOutput(composition: look)
        output.eventCap = 1
        var points: [(x: Double, z: Double)] = []
        for i in 0..<6 { let a = Double(i) / 6 * 2 * .pi; points.append((x: 0.5 + 0.45 * cos(a), z: 0.5 + 0.3 * sin(a))) }
        output.setPreviewGeometry(Composer2SlotGeometry(points: points))
        output.playAlongRequested = true
        output.playAlongFeel = .hit
        output.playAlongConductor = true
        var gate = BeatMath.FlashSafety.OnsetGate()
        var holds = 0, dimmed = false
        let start = 104.0, end = 118.0
        var shapedBefore = 0, totalBefore = 0
        var step = 0
        while true {
            let t = start + Double(step) * 0.02
            if t > end { break }
            if step == 50 { shapedBefore = output.shaper.shapedFrames; totalBefore = output.shaper.totalFrames }
            var f = AudioFeatures()
            f.structure = t < 116 ? building(confidence: 0.95) : dropped(at: 116)
            let frames = output.evaluate(time: t - 100, features: f, beat: grid, hostNow: t)
            if output.conductorCue.phase == .preDrop { dimmed = true }
            let field = BeatMath.FlashSafety.fieldFrame(channels: frames.map { (x: $0.x, y: $0.y, brightness: $0.brightness) })
            let reservation = gate.admit(frame: field, source: "wire", at: t, minPeriod: BeatMath.FlashSafety.minOnsetLedgerPeriod)
            if !reservation.wasAdmitted, step >= 50 { holds += 1 }
            gate.commit(reservation, delivered: true, at: t)
            step += 1
        }
        let shaped = output.shaper.shapedFrames - shapedBefore
        return (Double(shaped) / Double(max(1, output.shaper.totalFrames - totalBefore)), holds, dimmed)
    }
}
