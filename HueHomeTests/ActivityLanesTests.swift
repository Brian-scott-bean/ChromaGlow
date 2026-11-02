// ActivityLanesTests.swift
// HueHome Pro — Unit Tests ("the room is the band", step 5: the slow lanes, build 919)
//
// Is a bass line playing, are drums playing — decided over about a second
// from the analyzer's own frames. Synthetic signals here; the real-music
// numbers (BabySlakh stems, rooms) are the beat lab's `run.sh -activity`.

import XCTest
@testable import HueHome

final class ActivityLanesTests: XCTestCase {

    private let fs = 48_000.0

    // MARK: - Synthetic music (deterministic)

    private struct Noise {
        var s: UInt64
        mutating func next() -> Float {
            s &+= 0x9E37_79B9_7F4A_7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Float(Double(z >> 11) / Double(1 << 53)) * 2 - 1
        }
    }

    private struct Parts: OptionSet {
        let rawValue: Int
        static let bass = Parts(rawValue: 1)
        static let kick = Parts(rawValue: 2)
        static let snare = Parts(rawValue: 4)
        static let hats = Parts(rawValue: 8)
        static let pad = Parts(rawValue: 16)
        static let drums: Parts = [.kick, .snare, .hats]
    }

    /// `seconds` of 120 BPM music with the chosen parts: a bass line (a note
    /// per beat, held), kick on 1 and 3, snare on 2 and 4, hats on eighths, a
    /// held chord in the mids.
    private func music(_ parts: Parts, seconds: Double, seed: UInt64 = 1) -> [Float] {
        let n = Int(seconds * fs)
        var x = [Float](repeating: 0, count: n)
        var rng = Noise(s: seed)
        let beat = 0.5
        let bassNotes: [Double] = [110, 147, 165, 98]
        var phase = 0.0
        var hp: Float = 0, lastNoise: Float = 0
        for i in 0..<n {
            let t = Double(i) / fs
            let k = Int(t / beat)
            let inBeat = t - Double(k) * beat
            var v: Float = 0
            if parts.contains(.bass) {
                let f = bassNotes[k % bassNotes.count]
                phase += 2 * .pi * f / fs
                // A held note with a few harmonics: plucked in 8 ms, released
                // over 15 ms, a 20 ms gap before the next.
                let env = Float(min(1, inBeat / 0.008, max(0, (beat - 0.02 - inBeat) / 0.015)))
                v += 0.12 * env * Float(sin(phase) + 0.5 * sin(2 * phase) + 0.3 * sin(3 * phase))
            }
            if parts.contains(.kick), k % 2 == 0, inBeat < 0.25 {
                let f = 50 + 90 * exp(-inBeat * 30)
                v += 0.5 * Float(exp(-inBeat * 18) * sin(2 * .pi * f * inBeat))
            }
            let noise = rng.next()
            hp = noise - lastNoise; lastNoise = noise          // the top end of the noise
            if parts.contains(.snare), k % 2 == 1, inBeat < 0.18 {
                let env = Float(exp(-inBeat * 22))
                v += 0.3 * env * noise + 0.2 * env * Float(sin(2 * .pi * 200 * inBeat))
            }
            if parts.contains(.hats) {
                let e = (t / (beat / 2)).truncatingRemainder(dividingBy: 1) * beat / 2
                if e < 0.04 { v += 0.12 * Float(exp(-e * 90)) * hp }
            }
            if parts.contains(.pad) {
                v += 0.05 * Float(sin(2 * .pi * 440 * t) + sin(2 * .pi * 554 * t) + sin(2 * .pi * 659 * t))
            }
            x[i] = v
        }
        return x
    }

    private func quietRoom(seconds: Double, dbfs: Double) -> [Float] {
        var rng = Noise(s: 7)
        let g = Float(pow(10, dbfs / 20) * 3.0.squareRoot())   // uniform noise: rms = 1/√3
        return (0..<Int(seconds * fs)).map { _ in rng.next() * g }
    }

    /// Feeds `x` in 1024-frame hops (as the microphone delivers), starting at `start` s.
    private func feed(_ a: OnsetFrameAnalyzer, _ x: [Float], start: Double = 0) {
        x.withUnsafeBufferPointer { p in
            var k = 0
            while (k + 1) * 1024 <= x.count {
                a.process(p.baseAddress! + k * 1024, frameCount: 1024, sampleRate: fs,
                          bufferStart: start + Double(k * 1024) / fs)
                k += 1
            }
        }
    }

    // MARK: - The lanes

    func testABassLineReadsAsPlaying() {
        let a = OnsetFrameAnalyzer()
        feed(a, music([.bass], seconds: 8))
        let act = a.musicActivity()
        XCTAssertGreaterThan(act.bass, 0.6, "a held bass line")
        XCTAssertLessThan(act.drums, 0.5, "bass notes are not drums")
    }

    func testDrumsWithoutABassLineAreNotABassLine() {
        // The kick lives in the low end too; its low end is gone within 0.3 s.
        let a = OnsetFrameAnalyzer()
        feed(a, music(.drums, seconds: 8))
        let act = a.musicActivity()
        XCTAssertLessThan(act.bass, 0.3, "kicks alone are not a bass line")
        XCTAssertGreaterThan(act.drums, 0.6, "a kit playing")
    }

    func testAChordInTheMidsIsNeither() {
        let a = OnsetFrameAnalyzer()
        feed(a, music([.pad], seconds: 8))
        let act = a.musicActivity()
        XCTAssertLessThan(act.bass, 0.3)
        XCTAssertLessThan(act.drums, 0.3)
    }

    func testAQuietRoomIsNothing() {
        let a = OnsetFrameAnalyzer()
        feed(a, quietRoom(seconds: 8, dbfs: -60))
        let act = a.musicActivity()
        XCTAssertLessThan(act.bass, 0.15, "a quiet room's hiss is not a bass line")
        XCTAssertLessThan(act.drums, 0.15)
    }

    func testTheBassDropsOutAndComesBack() {
        // Full band 8 s → drums only 6 s (a breakdown) → full band 6 s.
        let a = OnsetFrameAnalyzer()
        let full = music([.bass, .kick, .snare, .hats, .pad], seconds: 8)
        let breakdown = music([.kick, .snare, .hats, .pad], seconds: 6, seed: 2)
        let back = music([.bass, .kick, .snare, .hats, .pad], seconds: 6, seed: 3)
        feed(a, full + breakdown + back)
        let f = a.snapshot()
        func bass(at t: Double) -> Float {
            let i = f.times.lastIndex { $0 <= t } ?? 0
            return f.bassActivity[i]
        }
        XCTAssertEqual(f.bassActivity.count, f.times.count)
        XCTAssertGreaterThan(bass(at: 7.9), 0.5, "the full band")
        XCTAssertLessThan(bass(at: 11), 0.5, "within 3 s of the bass stopping")
        XCTAssertLessThan(bass(at: 13.9), 0.3)
        XCTAssertGreaterThan(bass(at: 17.5), 0.5, "within 3.5 s of the bass coming back")
        XCTAssertTrue(f.bassActivity.allSatisfy { (0...1).contains($0) })
        XCTAssertTrue(f.drumActivity.allSatisfy { (0...1).contains($0) })
        // The drums never stopped.
        let drumsDuringBreakdown = f.times.indices.filter { f.times[$0] > 9 && f.times[$0] < 13.9 }.map { f.drumActivity[$0] }
        XCTAssertGreaterThan(drumsDuringBreakdown.min() ?? 0, 0.5)
    }

    func testTheLanesNeverRiseFasterThanAWash() {
        // From silence straight into the full band: about a second to rise.
        let a = OnsetFrameAnalyzer()
        feed(a, [Float](repeating: 0, count: Int(2 * fs)) + music([.bass, .kick, .snare, .hats], seconds: 4))
        let f = a.snapshot()
        var maxStep: Float = 0
        for i in 1..<f.count {
            maxStep = max(maxStep, f.bassActivity[i] - f.bassActivity[i - 1], f.drumActivity[i] - f.drumActivity[i - 1])
        }
        XCTAssertLessThan(maxStep, 0.05, "per 10 ms frame")
    }

    // MARK: - Where they reach the looks

    func testFeaturesAdoptTheActivity() {
        var f = AudioFeatures()
        f.adopt(MusicActivity(bass: 0.7, drums: 0.4))
        XCTAssertEqual(f.bassActivity, 0.7)
        XCTAssertEqual(f.drumActivity, 0.4)
    }

    func testTheSlowSourcesFollowTheLanes() throws {
        var f = AudioFeatures()
        f.bassActivity = 0.8
        f.drumActivity = 0.1
        let bass = Composer2AudioModulation(source: .bassLine, sensitivity: 0.7, threshold: 0.1, smoothing: 0.5,
                                            targets: [.brightness, .palettePosition])
        let drums = Composer2AudioModulation(source: .drumsPlaying, sensitivity: 0.7, threshold: 0.1, smoothing: 0.5)
        XCTAssertGreaterThan(bass.rawDrive(features: f, beat: .none, hostNow: 1), 0.9)
        XCTAssertEqual(drums.rawDrive(features: f, beat: .none, hostNow: 1), 0, accuracy: 1e-6, "under the gate")
        XCTAssertFalse(bass.isHit, "a wash, never a punch")
        XCTAssertTrue(bass.usesMicrophoneBands && drums.usesMicrophoneBands)
        XCTAssertGreaterThan(bass.paletteOffset(drive: 1), 0, "can move the colour slowly")
        // Saved and read back; a phone without these sources reads "off" (DrumLanesTests).
        let data = try JSONEncoder().encode(bass)
        XCTAssertEqual(try JSONDecoder().decode(Composer2AudioModulation.self, from: data), bass)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"bassLine\""))
    }
}
