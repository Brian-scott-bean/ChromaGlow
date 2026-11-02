// Composer2BandTests.swift
// HueHome Pro — Unit Tests ("the room is the band", step 4: the band transform)
//
// Play Along → The room is the band: the base layer split across the room's
// heights — kick low, the look's wash in the middle, snare (and a hi-hat
// shimmer under the flash size) high — with every band drum flash sharing
// one room-wide budget (never two within the gate's 0.34 s).

import XCTest
@testable import HueHome

final class Composer2BandTests: XCTestCase {

    private let epoch = 1000.0

    private func beat(_ bpm: Double) -> BeatSnapshot {
        BeatSnapshot(bpm: bpm, beatEpoch: epoch, beatsPerBar: 4, phaseConfidence: 1, barConfidence: 1)
    }

    private func steadyLook(_ brightness: Double = 0.4) -> Composer2Composition {
        let layer = Composer2Layer(name: "Wash", color: .solid(Composer2XY(x: 0.3127, y: 0.329)),
                                   motion: Composer2Motion(kind: .static),
                                   rhythm: Composer2Rhythm(shape: .steady, maxBrightness: brightness))
        return Composer2Composition(name: "Wash", createdAt: Date(timeIntervalSince1970: 0), layers: [layer])
    }

    /// Six lights in a ring: two low, two middle, two high.
    private func room() -> Composer2SlotGeometry {
        var points: [(x: Double, z: Double)] = []
        for i in 0..<6 {
            let angle = Double(i) / 6 * 2 * .pi
            points.append((x: 0.5 + 0.45 * cos(angle), z: 0.5 + 0.3 * sin(angle)))
        }
        return Composer2SlotGeometry(points: points).withRoles([.low, .middle, .high, .low, .middle, .high])
    }

    // MARK: - The transform

    func testTheBandSplitsTheBaseLayerByHeight() throws {
        let look = steadyLook()
        let band = Composer2PlayAlong.apply(look, feel: .groove, bpm: 120, band: true)
        XCTAssertEqual(band.layers.count, 4)
        guard band.layers.count == 4 else { return }
        let middle = band.layers[0], low = band.layers[1], high = band.layers[2], hats = band.layers[3]
        XCTAssertEqual(middle.id, look.layers[0].id, "the wash keeps the base layer's identity")
        XCTAssertEqual(middle.mask.roles, [.middle])
        XCTAssertEqual(middle.audio.source, .amplitude, "a held wash that swells")
        XCTAssertEqual(low.mask.roles, [.low]); XCTAssertEqual(low.audio.source, .kick)
        XCTAssertEqual(high.mask.roles, [.high]); XCTAssertEqual(high.audio.source, .snare)
        XCTAssertTrue(low.audio.sharesFlashBudget && high.audio.sharesFlashBudget)
        XCTAssertEqual(hats.audio.source, .hat)
        XCTAssertFalse(hats.audio.sharesFlashBudget, "the shimmer is never a flash")
        XCTAssertLessThanOrEqual(hats.audio.intensity, 0.08)
        XCTAssertEqual(hats.blend, .addLighten)
        XCTAssertEqual(Set(band.layers.map(\.id)).count, 4, "every copy its own id")
        XCTAssertEqual(Composer2PlayAlong.apply(look, feel: .groove, bpm: 120, band: true), band, "deterministic")
        XCTAssertEqual(try JSONDecoder().decode(Composer2Composition.self, from: JSONEncoder().encode(band)), band)
    }

    func testLooksTheBandCantSplitPlayAsTheFeelMadeThem() {
        var masked = steadyLook()
        masked.layers[0].mask = .slots([0, 1])
        var listening = steadyLook()
        listening.layers[0].audio = Composer2AudioModulation(source: .bass, intensity: 0.5)
        for look in [masked, listening] {
            XCTAssertEqual(Composer2PlayAlong.apply(look, feel: .hit, bpm: 120, band: true),
                           Composer2PlayAlong.apply(look, feel: .hit, bpm: 120, band: false))
        }
        let look = steadyLook()
        XCTAssertEqual(Composer2PlayAlong.apply(look, feel: .glide, bpm: 120, band: true),
                       Composer2PlayAlong.apply(look, feel: .glide, bpm: 120), "Glide adds no punches")
        XCTAssertEqual(Composer2PlayAlong.apply(look, feel: .hit, bpm: 120, category: .calm, band: true),
                       Composer2PlayAlong.apply(look, feel: .hit, bpm: 120, category: .calm), "Calm stays calm")
    }

    func testAccentLayersStopPunchingOnTheBeat() {
        var look = steadyLook()
        var accent = look.layers[0]
        accent.id = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
        accent.blend = .addLighten
        accent.rhythm = Composer2Rhythm(shape: .breathe, periodSeconds: 4, maxBrightness: 0.3)
        look.layers.append(accent)
        let plain = Composer2PlayAlong.apply(look, feel: .groove, bpm: 120)
        XCTAssertEqual(plain.layers[1].audio.source, .beat, "(Groove punches it)")
        let band = Composer2PlayAlong.apply(look, feel: .groove, bpm: 120, band: true)
        let kept = band.layers.first { $0.id == accent.id }
        XCTAssertEqual(kept?.audio.isActive, false, "the drums are the band's punches now")
        XCTAssertGreaterThan(kept?.rhythm.quantizeBeats ?? 0, 0, "its cycle still locks to the bars")
    }

    // MARK: - The shared budget

    func testTheBudgetKeepsBandFlashesApart() {
        var ledger: [Double] = []
        XCTAssertTrue(Composer2Band.admit(10, ledger: &ledger))
        XCTAssertFalse(Composer2Band.admit(10.2, ledger: &ledger), "within 0.34 s")
        XCTAssertTrue(Composer2Band.admit(10.34, ledger: &ledger))
        XCTAssertFalse(Composer2Band.admit(10.1, ledger: &ledger), "out of order")
        var n = 0
        var l: [Double] = []
        for k in 0..<100 where Composer2Band.admit(Double(k) * 0.05, ledger: &l) { n += 1 }
        XCTAssertLessThanOrEqual(n, 15, "5 s of hits every 50 ms: at most one per 0.34 s")
        XCTAssertLessThanOrEqual(l.count, 7, "the ledger keeps two seconds")
    }

    /// Kick on 1 and 3, snare on 2 and 4, hats on every eighth, as heard.
    private func drums(_ bpm: Double, at t: Double, kickEveryEighth: Bool = false) -> AudioFeatures {
        var f = AudioFeatures()
        let b = 60 / bpm
        let eighths = floor((t - epoch) / (b / 2))
        let lastEighth = epoch + eighths * b / 2
        let beats = floor((t - epoch) / b)
        f.lastHatAt = lastEighth; f.hatStrength = 0.6
        // The latest kick and snare at or before t.
        var k = beats, s = beats
        while ((Int(k) % 4) + 4) % 4 % 2 != 0 { k -= 1 }
        while ((Int(s) % 4) + 4) % 4 % 2 != 1 { s -= 1 }
        f.lastKickAt = kickEveryEighth ? lastEighth : epoch + k * b; f.kickStrength = 1
        f.lastSnareAt = epoch + s * b; f.snareStrength = 0.9
        return f
    }

    func testKickLightsTheLowLightsAndSnareTheHighOnes() {
        let output = Composer2LiveOutput(composition: steadyLook(0.3))
        output.setPreviewGeometry(room())
        output.playAlongRequested = true
        output.playAlongFeel = .groove
        output.playAlongBand = true
        let b = beat(120)
        var atKick: [Double] = [], atSnare: [Double] = []
        for step in 0..<Int(8 * 50) {
            let t = epoch + Double(step) * 0.02
            let frames = output.evaluate(time: t - epoch, features: drums(120, at: t), beat: b, hostNow: t)
            let phase = (t - epoch).truncatingRemainder(dividingBy: 2)
            if step > 200, abs(phase - 0.02) < 0.005 { atKick = frames.map(\.brightness) }   // just after beat 1
            if step > 200, abs(phase - 0.52) < 0.005 { atSnare = frames.map(\.brightness) }  // just after beat 2
        }
        XCTAssertTrue(output.bandIsPlaying)
        XCTAssertEqual(output.playAlongWeight, 1)
        XCTAssertEqual(atKick.count, 6)
        XCTAssertGreaterThan(atKick[0], atKick[2] + 0.2, "a kick: low over high")
        XCTAssertGreaterThan(atSnare[2], atSnare[0] + 0.2, "a snare: high over low")
    }

    func testWithoutALowAndAHighLightTheBandWaits() {
        let output = Composer2LiveOutput(composition: steadyLook())
        output.setPreviewGeometry(room().withRoles(Array(repeating: .middle, count: 6)))
        output.playAlongRequested = true
        output.playAlongBand = true
        let b = beat(120)
        for step in 0..<200 {
            let t = epoch + Double(step) * 0.02
            _ = output.evaluate(time: t - epoch, features: drums(120, at: t), beat: b, hostNow: t)
        }
        XCTAssertFalse(output.bandIsPlaying)
        XCTAssertEqual(output.derived?.layers.count, 1, "the feel's look, not split")
    }

    func testBusyDrumsShareOneBudgetAcrossTheRoom() {
        // A kick on every eighth AND snares: far more than three a second.
        var state = Composer2EngineState()
        let look = Composer2PlayAlong.apply(steadyLook(0.2), feel: .hit, bpm: 150, band: true)
        let g = room()
        let b = beat(150)
        var rises: [Double] = []
        var previous: [Double] = []
        for step in 0..<Int(10 * 50) {
            let t = epoch + Double(step) * 0.02
            let frames = Composer2Engine.evaluate(look, time: t - epoch, geometry: g, state: &state,
                                                  audio: drums(150, at: t, kickEveryEighth: true), beat: b, hostNow: t)
            let bri = frames.map(\.brightness)
            if previous.count == bri.count {
                let lowOrHigh = [0, 2, 3, 5]
                if lowOrHigh.contains(where: { bri[$0] - previous[$0] >= 0.15 }) { rises.append(t) }
            }
            previous = bri
        }
        let gaps = zip(rises.dropFirst(), rises).map { $0 - $1 }
        XCTAssertGreaterThan(rises.count, 10, "the drums still play")
        XCTAssertGreaterThanOrEqual(gaps.min() ?? 1, 0.33, "no two band flashes within 0.34 s, kick or snare")
    }

    // MARK: - Every built-in look, through the real output and the wire gate

    func testBandLooksNeverMakeTheWireStutter() {
        var report: [String] = []
        for (bpm, eighthKicks) in [(120.0, false), (150.0, true)] {
            var shapedSum = 0.0, holdsSum = 0, split = 0
            for look in Composer2PresetLibrary.all {
                let r = play(look, bpm: bpm, eighthKicks: eighthKicks, seconds: 8)
                shapedSum += r.shaped
                holdsSum += r.holds
                if r.split { split += 1 }
                report.append(String(format: "%@ %.0f BPM%@ split=%@ shaped=%.3f holds=%d", look.name, bpm,
                                     eighthKicks ? " (eighth kicks)" : "", r.split ? "yes" : "no", r.shaped, r.holds))
                XCTAssertLessThanOrEqual(r.holds, 3, "\(look.name) \(bpm) BPM: the wire gate held \(r.holds) frames")
            }
            report.append(String(format: "MEAN %.0f BPM%@ split %d of %d looks, shaped=%.4f, holds total %d", bpm,
                                 eighthKicks ? " (eighth kicks)" : "", split, Composer2PresetLibrary.all.count,
                                 shapedSum / Double(Composer2PresetLibrary.all.count), holdsSum))
        }
        print("Composer2BandTests gate report:\n" + report.joined(separator: "\n"))
    }

    private func play(_ look: Composer2Composition, bpm: Double, eighthKicks: Bool,
                      seconds: Double) -> (shaped: Double, holds: Int, split: Bool) {
        let output = Composer2LiveOutput(composition: look)
        output.eventCap = 1
        output.setPreviewGeometry(room())
        output.playAlongRequested = true
        output.playAlongFeel = .hit
        output.playAlongBand = true
        let b = beat(bpm)
        var gate = BeatMath.FlashSafety.OnsetGate()
        var holds = 0
        let start = epoch + 4
        var shapedBefore = 0, totalBefore = 0
        for step in 0..<Int((4 + seconds) * 50) {
            let t = epoch + Double(step) / 50
            if step == 4 * 50 {
                shapedBefore = output.shaper.shapedFrames
                totalBefore = output.shaper.totalFrames
            }
            let frames = output.evaluate(time: t - epoch, features: drums(bpm, at: t, kickEveryEighth: eighthKicks),
                                         beat: b, hostNow: t)
            let field = BeatMath.FlashSafety.fieldFrame(channels: frames.map { (x: $0.x, y: $0.y, brightness: $0.brightness) })
            let reservation = gate.admit(frame: field, source: "wire", at: t, minPeriod: BeatMath.FlashSafety.minOnsetLedgerPeriod)
            if !reservation.wasAdmitted, t >= start { holds += 1 }
            gate.commit(reservation, delivered: true, at: t)
        }
        let split = (output.derived?.layers.count ?? 0) > look.layers.count
        let shaped = output.shaper.shapedFrames - shapedBefore
        return (Double(shaped) / Double(max(1, output.shaper.totalFrames - totalBefore)), holds, split)
    }
}
