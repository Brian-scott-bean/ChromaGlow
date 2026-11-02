// Composer2LabSoundTests.swift
// HueHome Pro — Unit Tests (Tune's Sound dial)
//
// One saved amount per look scales how much every layer reacts to sound:
// its own reaction (Beat Drop, Club Pulse) and the one Play Along adds,
// alike. Still turns the reaction off and lets go of the microphone;
// Lightly halves it; Dances pushes it further. These tests check the model
// stays byte-identical for looks that never touch it, that the dial scales
// a punch and the moving-hits dip, that Play Along still knows which layers
// listen, and that Dim Flashing Lights and the flash gate still bound a look
// turned all the way up.

import XCTest
@testable import HueHome

final class Composer2LabSoundTests: XCTestCase {

    private let epoch = 1000.0
    private let step = 0.002

    private func beat(_ bpm: Double, knowsTheOne: Bool = true) -> BeatSnapshot {
        BeatSnapshot(bpm: bpm, beatEpoch: epoch, beatsPerBar: 4, phaseConfidence: 1,
                     barConfidence: knowsTheOne ? 1 : 0)
    }

    private func ring(_ n: Int) -> Composer2SlotGeometry {
        guard n > 1 else { return .linear(count: n) }
        var points: [(x: Double, z: Double)] = []
        for i in 0..<n {
            let angle = Double(i) / Double(n) * 2 * .pi
            points.append((x: 0.5 + 0.45 * cos(angle), z: 0.5 + 0.3 * sin(angle)))
        }
        return Composer2SlotGeometry(points: points)
    }

    /// One steady white layer at 40 % that punches on the beat.
    private func punchLook(sound: Double = 1, travel: Composer2AudioModulation.Travel? = nil,
                           source: Composer2AudioModulation.Source = .beat) -> Composer2Composition {
        var layer = Composer2Layer(name: "Hits", color: .solid(Composer2XY(x: 0.3127, y: 0.329)),
                                   motion: Composer2Motion(kind: .static),
                                   rhythm: Composer2Rhythm(shape: .steady, maxBrightness: 0.4))
        layer.audio = Composer2AudioModulation(source: source, smoothing: 0, intensity: 0.8,
                                               punchDecay: (0.15 - 0.08) / 0.52, travel: travel)
        var look = Composer2Composition(name: "Hits", createdAt: Date(timeIntervalSince1970: 0), layers: [layer])
        look.master.soundAmount = sound
        return look
    }

    private func silenced(_ look: Composer2Composition) -> Composer2Composition {
        var out = look
        for i in out.layers.indices { out.layers[i].audio = Composer2AudioModulation() }
        out.master.soundAmount = 1
        return out
    }

    /// Brightness per light every `step` seconds over [from, to).
    private func render(_ look: Composer2Composition, geometry: Composer2SlotGeometry, beat: BeatSnapshot,
                        from: Double, to: Double, eventCap: Double = 1,
                        heard: (Double) -> AudioFeatures = { _ in .silent }) -> [[Double]] {
        var state = Composer2EngineState()
        var plans = Composer2Engine.plans(for: look, geometry: geometry)
        var frames: [Composer2Frame] = []
        var out: [[Double]] = []
        let count = Int(((to - from) / step).rounded())
        for k in 0..<count {
            let t = from + Double(k) * step
            Composer2Engine.evaluate(look, time: t - epoch, geometry: geometry, plans: &plans, state: &state,
                                     audio: heard(t), beat: beat, hostNow: t, eventCap: eventCap, into: &frames)
            out.append(frames.map(\.brightness))
        }
        return out
    }

    private func rise(_ samples: [[Double]], light: Int = 0) -> Double {
        let b = samples.map { $0[light] }
        return b.max()! - b.min()!
    }

    // MARK: - The model

    func testSoundIsOptionalAndLooksSavedBeforeItEncodeAsBefore() throws {
        let master = Composer2MasterControls(seed: 42)
        XCTAssertEqual(master.soundAmount, 1)
        let data = try JSONEncoder().encode(master)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["soundAmount"], "a look that never touched Sound encodes exactly as before")
        XCTAssertEqual(try JSONDecoder().decode(Composer2MasterControls.self, from: data).soundAmount, 1)

        for amount in [0, 0.5, 1.5, 2.0] {
            var tuned = master
            tuned.soundAmount = amount
            let round = try JSONDecoder().decode(Composer2MasterControls.self, from: JSONEncoder().encode(tuned))
            XCTAssertEqual(round, tuned, "\(amount) is saved with the look")
        }

        // Every built-in look is untouched by the new key.
        for look in Composer2PresetLibrary.all {
            let encoded = try JSONEncoder().encode(look)
            XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("soundAmount"), look.name)
        }
    }

    func testSoundAmountIsSanitized() throws {
        var m = Composer2MasterControls(seed: 1)
        m.soundAmount = -1
        XCTAssertEqual(m.sanitizedSoundAmount, 0)
        m.soundAmount = 9
        XCTAssertEqual(m.sanitizedSoundAmount, Composer2MasterControls.maxSoundAmount)
        m.soundAmount = .nan
        XCTAssertEqual(m.sanitizedSoundAmount, 1)
        let junk = Data(#"{"seed":"7","soundAmount":"loud"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(Composer2MasterControls.self, from: junk).soundAmount, 1,
                       "an unreadable amount reads as as authored")
    }

    func testTheDialScalesTheReactionAndStillTurnsItOff() {
        let mod = Composer2AudioModulation(source: .onset, intensity: 0.8, targets: [.brightness, .palettePosition],
                                           triggerEventsOnOnset: true, travel: .roll)
        XCTAssertEqual(mod.scaled(by: 1), mod, "as authored")
        XCTAssertEqual(mod.scaled(by: 0.5).intensity, 0.4, accuracy: 1e-12)
        XCTAssertEqual(mod.scaled(by: 1.5).intensity, 1.2, accuracy: 1e-12)
        var expected = mod
        expected.intensity = 0.4
        XCTAssertEqual(mod.scaled(by: 0.5), expected, "only the strength changes")
        let still = mod.scaled(by: 0)
        XCTAssertFalse(still.isActive, "Still: no punches, palette steps or events forced on hits")
        XCTAssertFalse(still.travels)
        XCTAssertEqual(Composer2AudioModulation().scaled(by: 2), Composer2AudioModulation(), "nothing to scale")
        XCTAssertEqual(mod.punch(drive: 1), 0.8, accuracy: 1e-12)
        XCTAssertEqual(mod.scaled(by: 2).punch(drive: 1), 1, accuracy: 1e-12, "a punch never exceeds full")
    }

    // MARK: - The engine

    func testThePunchFollowsTheDial() {
        let g = Composer2SlotGeometry.linear(count: 3)
        let b = beat(120)
        func punchRise(_ sound: Double) -> Double {
            rise(render(punchLook(sound: sound), geometry: g, beat: b, from: epoch + 1, to: epoch + 3))
        }
        let authored = punchRise(1)
        XCTAssertGreaterThan(authored, 0.3)
        XCTAssertEqual(punchRise(0.5), authored * 0.5, accuracy: 0.005, "Lightly: half the punch")
        XCTAssertEqual(punchRise(0), 0, accuracy: 1e-12, "Still: no punch")
        XCTAssertGreaterThan(punchRise(1.5), authored + 0.05, "Dances: more than as authored")
        // At 1.25 the punch already reaches full (0.8 × 1.25), so 2 adds nothing more.
        XCTAssertEqual(punchRise(2), punchRise(1.25), accuracy: 1e-9)

        // Still plays exactly what the look plays with no sound at all.
        let still = render(punchLook(sound: 0), geometry: g, beat: b, from: epoch + 1, to: epoch + 2)
        let none = render(silenced(punchLook()), geometry: g, beat: b, from: epoch + 1, to: epoch + 2)
        XCTAssertEqual(still, none)
    }

    func testStillLeavesNoMovingHitsAndNoDip() {
        let g = ring(5)
        let b = beat(120)
        let still = render(punchLook(sound: 0, travel: .roll), geometry: g, beat: b, from: epoch + 1, to: epoch + 3)
        let none = render(silenced(punchLook(travel: .roll)), geometry: g, beat: b, from: epoch + 1, to: epoch + 3)
        XCTAssertEqual(still, none, "lights don't sit lower waiting for hits that never come")

        let lightly = render(punchLook(sound: 0.5, travel: .roll), geometry: g, beat: b, from: epoch + 1, to: epoch + 3)
        let authored = render(punchLook(travel: .roll), geometry: g, beat: b, from: epoch + 1, to: epoch + 3)
        let base = none[0][0]
        let dipLightly = base - lightly.flatMap { $0 }.min()!
        let dipAuthored = base - authored.flatMap { $0 }.min()!
        XCTAssertEqual(dipAuthored, base * Composer2Hits.duckShare * 0.8, accuracy: 0.01)
        XCTAssertEqual(dipLightly, dipAuthored * 0.5, accuracy: 0.01, "the dip follows the dial")
    }

    func testHeardHitsAndSwellsFollowTheDial() {
        let g = Composer2SlotGeometry.linear(count: 2)
        // A hit every half second.
        let e = epoch
        let hits: (Double) -> AudioFeatures = { t in
            var f = AudioFeatures()
            f.lastOnsetAt = e + 1 + floor((t - e - 1) / 0.5) * 0.5
            f.level = 0.8
            return f
        }
        let onset = rise(render(punchLook(source: .onset), geometry: g, beat: .none, from: epoch + 1, to: epoch + 3,
                                heard: hits))
        let onsetLightly = rise(render(punchLook(sound: 0.5, source: .onset), geometry: g, beat: .none,
                                       from: epoch + 1, to: epoch + 3, heard: hits))
        XCTAssertGreaterThan(onset, 0.3)
        XCTAssertEqual(onsetLightly, onset * 0.5, accuracy: 0.005)

        // A loudness swell: brightness above the quiet look, scaled.
        let loud: (Double) -> AudioFeatures = { _ in var f = AudioFeatures(); f.level = 0.9; return f }
        func lift(_ sound: Double) -> Double {
            let s = render(punchLook(sound: sound, source: .amplitude), geometry: g, beat: .none,
                           from: epoch + 1, to: epoch + 2, heard: loud)
            return s.last![0] - render(silenced(punchLook()), geometry: g, beat: .none,
                                       from: epoch + 1, to: epoch + 1.01)[0][0]
        }
        XCTAssertGreaterThan(lift(1), 0.1)
        XCTAssertEqual(lift(0.5), lift(1) * 0.5, accuracy: 0.005)
        XCTAssertEqual(lift(0), 0, accuracy: 1e-12)
    }

    // MARK: - The microphone

    func testStillLetsGoOfTheMicrophoneButKeepsTime() {
        var drop = Composer2PresetLibrary.beatDrop
        XCTAssertTrue(drop.usesAudio)
        drop.master.soundAmount = 0
        XCTAssertTrue(drop.hasSound, "the look still has its own sound settings")
        XCTAssertFalse(drop.usesAudio)
        XCTAssertFalse(drop.usesMicrophoneBands)
        XCTAssertEqual(Composer2LiveOutput(composition: drop).mirroredReactionSource(), .none,
                       "Still stops holding the microphone")
        drop.master.soundAmount = 0.3
        XCTAssertEqual(Composer2LiveOutput(composition: drop).mirroredReactionSource(), .micAmplitude)

        var pulse = Composer2PresetLibrary.clubPulse
        pulse.master.soundAmount = 0
        XCTAssertFalse(pulse.usesBeatClock)
        XCTAssertEqual(Composer2LiveOutput(composition: pulse).mirroredReactionSource(), .none)
        pulse.layers[0].rhythm.quantizeBeats = 4
        XCTAssertTrue(pulse.usesBeatClock, "a beat-locked rhythm keeps time at Still")

        // Play Along still listens: the beat is what keeps the look in time.
        let output = Composer2LiveOutput(composition: drop)
        drop.master.soundAmount = 0
        output.composition = drop
        output.playAlongRequested = true
        XCTAssertEqual(output.mirroredReactionSource(), .micAmplitude)
    }

    // MARK: - Play Along

    func testPlayAlongStillKnowsWhichLayersListen() {
        for (look, category) in [(Composer2PresetLibrary.neonNights, Composer2LookCategory.party),
                                 (Composer2PresetLibrary.beatDrop, .party),
                                 (Composer2PresetLibrary.clubPulse, .party)] {
            for feel in Composer2PlayAlong.Feel.allCases {
                let authored = Composer2PlayAlong.apply(look, feel: feel, bpm: 124, category: category, hits: .roll)
                for amount in [0, 0.5, 2.0] {
                    var tuned = look
                    tuned.master.soundAmount = amount
                    let out = Composer2PlayAlong.apply(tuned, feel: feel, bpm: 124, category: category, hits: .roll)
                    XCTAssertEqual(out.layers, authored.layers, "\(look.name) \(feel.title) at \(amount)")
                    XCTAssertEqual(out.master.soundAmount, amount, "the dial rides along")
                }
            }
        }
    }

    func testPlayAlongPunchesFollowTheDial() {
        let g = ring(4)
        let b = beat(120)
        let derived = Composer2PlayAlong.apply(Composer2PresetLibrary.neonNights, feel: .hit, bpm: 120,
                                               category: .party, hits: .roll)
        XCTAssertTrue(derived.usesAudio)
        var still = derived
        still.master.soundAmount = 0
        XCTAssertEqual(render(still, geometry: g, beat: b, from: epoch + 1, to: epoch + 3),
                       render(silenced(derived), geometry: g, beat: b, from: epoch + 1, to: epoch + 3),
                       "Still: the look moves in time, with no punches")

        func swing(_ amount: Double) -> Double {
            var look = derived
            look.master.soundAmount = amount
            let s = render(look, geometry: g, beat: b, from: epoch + 1, to: epoch + 3)
            let quiet = render(silenced(derived), geometry: g, beat: b, from: epoch + 1, to: epoch + 3)
            return zip(s, quiet).map { zip($0, $1).map { abs($0 - $1) }.max()! }.max()!
        }
        XCTAssertLessThan(swing(0.5), swing(1))
        XCTAssertLessThan(swing(1), swing(1.5))
    }

    func testTheLiveLookFollowsTheDialOnTheNextFrame() {
        var look = Composer2PresetLibrary.clubPulse
        let output = Composer2LiveOutput(composition: look)
        output.setPreviewGeometry(ring(4))
        output.playAlongRequested = true
        let b = beat(128)
        var t = epoch
        while t < epoch + 3 {
            output.evaluate(time: t - epoch, beat: b, hostNow: t)
            t += 0.02
        }
        XCTAssertEqual(output.derived?.master.soundAmount, 1)
        look.master.soundAmount = 0.5
        output.composition = look
        output.evaluate(time: t - epoch, beat: b, hostNow: t)
        XCTAssertEqual(output.derived?.master.soundAmount, 0.5)
    }

    // MARK: - Safety

    func testDimFlashingLightsStillCapsDances() {
        let g = Composer2SlotGeometry.linear(count: 3)
        let b = beat(120)
        let base = render(silenced(punchLook()), geometry: g, beat: b, from: epoch + 1, to: epoch + 1.01)[0][0]
        for travel in [nil, Composer2AudioModulation.Travel.roll] {
            let dances = render(punchLook(sound: Composer2MasterControls.maxSoundAmount, travel: travel),
                                geometry: g, beat: b, from: epoch + 1, to: epoch + 3, eventCap: 0.3)
            let top = dances.flatMap { $0 }.max()!
            XCTAssertLessThanOrEqual(top - base, 0.3 * (1 - base) + 1e-9,
                                     "\(String(describing: travel)): a hit adds at most 30 % of the headroom")
        }
    }

    /// Every built-in look, with Play Along engaged, at as authored and at
    /// the top of the dial, through the real output path (engine + flash
    /// shaper) on the 20 ms grid and then an independent copy of the wire's
    /// gate. The wire must never stutter more at Dances; how much more the
    /// shaper softens a look turned all the way up is printed for every case.
    func testDancesNeverMakesTheWireStutter() {
        var report: [String] = []
        let cases: [(feel: Composer2PlayAlong.Feel, bpm: Double, n: Int, travel: Composer2AudioModulation.Travel)] = [
            (.hit, 128, 6, .roll), (.hit, 96, 3, .together), (.groove, 120, 4, .roll),
        ]
        for c in cases {
            var sums: [Double: Double] = [:]
            for look in Composer2PresetLibrary.all {
                var measured: [Double: (shaped: Double, holds: Int)] = [:]
                for amount in [1, Composer2MasterControls.maxSoundAmount] {
                    var tuned = look
                    tuned.master.soundAmount = amount
                    measured[amount] = play(tuned, feel: c.feel, travel: c.travel, bpm: c.bpm, n: c.n, seconds: 8)
                    sums[amount, default: 0] += measured[amount]!.shaped
                }
                let authored = measured[1]!, dances = measured[Composer2MasterControls.maxSoundAmount]!
                let label = "\(look.name) \(c.feel.title) \(Int(c.bpm)) BPM n=\(c.n) \(c.travel.rawValue)"
                report.append(String(format: "%@ shaped=%.3f (as authored %.3f) holds=%d (as authored %d)",
                                     label, dances.shaped, authored.shaped, dances.holds, authored.holds))
                XCTAssertLessThanOrEqual(dances.holds, max(3, authored.holds), "\(label): the wire gate held \(dances.holds)")
            }
            let looks = Double(Composer2PresetLibrary.all.count)
            report.append(String(format: "MEAN %@ %.0f BPM n=%d %@ shaped=%.4f (as authored %.4f)",
                                 c.feel.title, c.bpm, c.n, c.travel.rawValue,
                                 sums[Composer2MasterControls.maxSoundAmount]! / looks, sums[1]! / looks))
        }
        print("Composer2LabSoundTests gate report:\n" + report.joined(separator: "\n"))
    }

    private func play(_ look: Composer2Composition, feel: Composer2PlayAlong.Feel,
                      travel: Composer2AudioModulation.Travel, bpm: Double, n: Int,
                      seconds: Double) -> (shaped: Double, holds: Int) {
        let output = Composer2LiveOutput(composition: look)
        output.eventCap = 1
        output.setPreviewGeometry(ring(n))
        output.playAlongRequested = true
        output.playAlongFeel = feel
        output.playAlongHits = travel
        let b = beat(bpm)
        var gate = BeatMath.FlashSafety.OnsetGate()
        var holds = 0
        let fps = 50.0
        let start = epoch + 4
        var shapedBefore = 0, totalBefore = 0
        for step in 0..<Int((4 + seconds) * fps) {
            let t = epoch + Double(step) / fps
            if step == Int(4 * fps) {
                shapedBefore = output.shaper.shapedFrames
                totalBefore = output.shaper.totalFrames
            }
            let frames = output.evaluate(time: t - epoch, features: .silent, beat: b, hostNow: t)
            let field = BeatMath.FlashSafety.fieldFrame(channels: frames.map { (x: $0.x, y: $0.y, brightness: $0.brightness) })
            let reservation = gate.admit(frame: field, source: "wire", at: t,
                                         minPeriod: BeatMath.FlashSafety.minOnsetLedgerPeriod)
            if !reservation.wasAdmitted, t >= start { holds += 1 }
            gate.commit(reservation, delivered: true, at: t)
        }
        XCTAssertEqual(output.playAlongWeight, 1, "\(look.name): Play Along engaged")
        let shaped = output.shaper.shapedFrames - shapedBefore
        return (Double(shaped) / Double(max(1, output.shaper.totalFrames - totalBefore)), holds)
    }
}
