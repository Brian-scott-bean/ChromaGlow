// AudioFeatureCoreTests.swift
// HueHome Pro — Unit Tests
//
// Phase-2 DJ audio core: AudioFeatureExtractor (bands/AGC/onset),
// TempoEstimator (BPM on synthetic click tracks), and BeatClock
// (tap tempo, pinning, gentle audio phase correction).
//
// All signals are synthetic and deterministic (LCG noise, fixed seeds) —
// no audio hardware, no flakiness.

import XCTest
@testable import HueHome

// MARK: - Deterministic noise

private struct LCG {
    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 33) / Double(UInt32.max)   // 0..1
    }
}

// MARK: - TempoEstimator

final class TempoEstimatorTests: XCTestCase {

    /// Build an onset envelope with impulses on each beat.
    private func clickEnvelope(
        bpm: Double, hopRate: Double, seconds: Double,
        jitterMs: Double = 0, noiseFloor: Float = 0, seed: UInt64 = 42
    ) -> [Float] {
        let hops = Int(seconds * hopRate)
        var env = [Float](repeating: 0, count: hops)
        var rng = LCG(state: seed)
        if noiseFloor > 0 {
            for i in 0..<hops { env[i] = Float(rng.next()) * noiseFloor }
        }
        let beatInterval = 60.0 / bpm
        var t = 0.0
        while t < seconds {
            let jitter = jitterMs > 0 ? (rng.next() * 2 - 1) * jitterMs / 1000.0 : 0
            let idx = Int(((t + jitter) * hopRate).rounded())
            if idx >= 0 && idx < hops { env[idx] = 1.0 }
            t += beatInterval
        }
        return env
    }

    private func estimate(bpm: Double, jitterMs: Double = 0, noiseFloor: Float = 0) -> TempoEstimate? {
        let hopRate = 44100.0 / 1024.0
        let env = clickEnvelope(bpm: bpm, hopRate: hopRate, seconds: 6.0,
                                jitterMs: jitterMs, noiseFloor: noiseFloor)
        return TempoEstimator().update(onsetEnvelope: env, hopRate: hopRate)
    }

    func testCleanClickTracksAcrossTheRange() throws {
        for bpm in [60.0, 90.0, 120.0, 128.0, 174.0] {
            let e = try XCTUnwrap(estimate(bpm: bpm), "estimate expected for \(bpm) BPM")
            XCTAssertEqual(e.bpm, bpm, accuracy: 2.0, "clean \(bpm) BPM click must read within ±2")
        }
    }

    func testNoisyJitteredClickTrack() throws {
        let e = try XCTUnwrap(estimate(bpm: 120, jitterMs: 20, noiseFloor: 0.15))
        XCTAssertEqual(e.bpm, 120, accuracy: 3.0, "±20 ms jitter + noise floor must still read ~120")
    }

    func testPureSlowClickIsNotOctaveFolded() throws {
        // A true 60 BPM click has ~zero autocorrelation at the 120 BPM lag —
        // the 84–168 preference must NOT fold it up.
        let e = try XCTUnwrap(estimate(bpm: 60))
        XCTAssertEqual(e.bpm, 60, accuracy: 2.0, "true 60 BPM must stay 60, not fold to 120")
    }

    func testEighthNotePatternPrefersTheBeatRate() throws {
        // Strong beats at 120 BPM with weaker eighth-note energy between:
        // must report ~120, not the eighth-note rate.
        let hopRate = 44100.0 / 1024.0
        var env = clickEnvelope(bpm: 120, hopRate: hopRate, seconds: 6.0)
        let eighth = clickEnvelope(bpm: 240, hopRate: hopRate, seconds: 6.0)
        for i in 0..<env.count where eighth[i] > 0 && env[i] == 0 { env[i] = 0.4 }
        let e = try XCTUnwrap(TempoEstimator().update(onsetEnvelope: env, hopRate: hopRate))
        XCTAssertEqual(e.bpm, 120, accuracy: 3.0)
    }

    func testBeatPhaseOffsetPointsAtTheLastClick() throws {
        let hopRate = 44100.0 / 1024.0
        // Beats every 0.5 s; craft the envelope so a beat lands exactly
        // 10 hops before the end.
        let hops = Int(6.0 * hopRate)
        var env = [Float](repeating: 0, count: hops)
        let periodHops = Int(0.5 * hopRate + 0.5)   // ~21.5 → 22
        var idx = hops - 1 - 10
        while idx >= 0 { env[idx] = 1.0; idx -= periodHops }
        let e = try XCTUnwrap(TempoEstimator().update(onsetEnvelope: env, hopRate: hopRate))
        XCTAssertEqual(e.lastBeatOffset, 10.0 / hopRate, accuracy: 1.5 / hopRate,
                       "phase must locate the final click within ~1 hop")
    }

    func testSilenceReturnsNil() {
        let hopRate = 44100.0 / 1024.0
        let env = [Float](repeating: 0, count: Int(6.0 * hopRate))
        XCTAssertNil(TempoEstimator().update(onsetEnvelope: env, hopRate: hopRate))
    }

    func testHysteresisResistsOneOffTempoFlips() throws {
        let hopRate = 44100.0 / 1024.0
        let est = TempoEstimator()
        let at120 = clickEnvelope(bpm: 120, hopRate: hopRate, seconds: 6.0)
        let at90  = clickEnvelope(bpm: 90,  hopRate: hopRate, seconds: 6.0)
        _ = est.update(onsetEnvelope: at120, hopRate: hopRate)
        // One deviating pass must not switch the reported tempo…
        let flip1 = try XCTUnwrap(est.update(onsetEnvelope: at90, hopRate: hopRate))
        XCTAssertEqual(flip1.bpm, 120, accuracy: 3.0, "a single 90 BPM pass must not flip the clock")
        // …but three consecutive passes must.
        _ = est.update(onsetEnvelope: at90, hopRate: hopRate)
        let flip3 = try XCTUnwrap(est.update(onsetEnvelope: at90, hopRate: hopRate))
        XCTAssertEqual(flip3.bpm, 90, accuracy: 3.0, "three consistent passes must switch the clock")
    }
}

// MARK: - AudioFeatureExtractor

final class AudioFeatureExtractorTests: XCTestCase {

    private let sampleRate: Float = 44100
    private let frames = 1024

    private func sineBuffer(hz: Float, amplitude: Float, phase: inout Float) -> [Float] {
        var out = [Float](repeating: 0, count: frames)
        let step = 2 * Float.pi * hz / sampleRate
        for i in 0..<frames {
            out[i] = sin(phase) * amplitude
            phase += step
        }
        return out
    }

    @discardableResult
    private func feed(_ extractor: AudioFeatureExtractor, buffer: [Float], hop: Int) -> AudioFeatures? {
        let hostTime = Double(hop) * Double(frames) / Double(sampleRate)
        return buffer.withUnsafeBufferPointer { buf in
            extractor.process(data: buf.baseAddress!, frameCount: frames,
                              sampleRate: sampleRate, hostTime: hostTime)
        }
    }

    func testBassSineDominatesBassBand() throws {
        let ex = AudioFeatureExtractor()
        var phase: Float = 0
        var last: AudioFeatures?
        for hop in 0..<10 {
            last = feed(ex, buffer: sineBuffer(hz: 100, amplitude: 0.3, phase: &phase), hop: hop)
        }
        let f = try XCTUnwrap(last)
        XCTAssertGreaterThan(f.rawBass, f.rawTreble, "a 100 Hz tone must read as bass, not treble")
        XCTAssertGreaterThan(f.level, 0, "audible signal must produce a normalized level")
    }

    func testSilenceGatesToZero() throws {
        let ex = AudioFeatureExtractor()
        let silent = [Float](repeating: 0, count: frames)
        var last: AudioFeatures?
        for hop in 0..<5 { last = feed(ex, buffer: silent, hop: hop) }
        let f = try XCTUnwrap(last)
        XCTAssertEqual(f.level, 0, "silence must gate the normalized level to 0")
        XCTAssertEqual(f.rawOverall, 0, accuracy: 0.001)
        XCTAssertFalse(f.isOnset)
    }

    func testSuddenLoudBufferFiresOnset() throws {
        let ex = AudioFeatureExtractor()
        var phase: Float = 0
        // ~0.7 s of quiet signal to build flux history…
        for hop in 0..<30 {
            _ = feed(ex, buffer: sineBuffer(hz: 200, amplitude: 0.01, phase: &phase), hop: hop)
        }
        // …then a sudden loud hit.
        let f = try XCTUnwrap(feed(ex, buffer: sineBuffer(hz: 200, amplitude: 0.5, phase: &phase), hop: 30))
        XCTAssertTrue(f.isOnset, "a quiet→loud jump must register as an onset")
        XCTAssertGreaterThan(f.onsetStrength, 0.5)
    }

    func testAGCConvergesQuietSignalTowardTarget() throws {
        let ex = AudioFeatureExtractor()
        var phase: Float = 0
        var last: AudioFeatures?
        // A steady, fairly quiet signal: AGC should pull the normalized
        // level up toward ~0.8 within a few seconds.
        for hop in 0..<200 {
            last = feed(ex, buffer: sineBuffer(hz: 440, amplitude: 0.05, phase: &phase), hop: hop)
        }
        let f = try XCTUnwrap(last)
        XCTAssertEqual(f.level, 0.8, accuracy: 0.15,
                       "AGC must normalize a steady signal to ~0.8 regardless of its absolute loudness")
    }

    func testOnsetEnvelopeSnapshotAccumulates() {
        let ex = AudioFeatureExtractor()
        var phase: Float = 0
        for hop in 0..<50 {
            _ = feed(ex, buffer: sineBuffer(hz: 300, amplitude: hop % 10 == 0 ? 0.5 : 0.02, phase: &phase), hop: hop)
        }
        let snap = ex.onsetEnvelopeSnapshot()
        XCTAssertEqual(snap.envelope.count, 50)
        XCTAssertEqual(snap.hopRate, Double(sampleRate) / Double(frames), accuracy: 0.01)
        XCTAssertGreaterThan(snap.envelope.max() ?? 0, 0, "flux spikes must land in the ring")
    }
}

// MARK: - BeatClock

@MainActor
final class BeatClockTests: XCTestCase {

    func testTapTempoSetsBPMAndPins() {
        let clock = BeatClock()
        for i in 0..<4 { clock.tap(now: 100.0 + Double(i) * 0.5) }
        XCTAssertEqual(clock.bpm, 120, accuracy: 0.5)
        XCTAssertTrue(clock.isPinned)
        XCTAssertEqual(clock.source, .tap)
        // The last tap re-anchors phase: snapshot phase at the tap instant is 0.
        let snap = BeatClock.snapshot()
        XCTAssertEqual(snap.bpm, 120, accuracy: 0.5)
        XCTAssertEqual(snap.beatPhase(at: 101.5), 0, accuracy: 0.001)
    }

    func testPinnedClockIgnoresAudio() {
        let clock = BeatClock()
        for i in 0..<4 { clock.tap(now: 100.0 + Double(i) * 0.5) }
        clock.ingest(estimate: TempoEstimate(bpm: 100, confidence: 0.9, lastBeatOffset: 0), endTime: 102)
        XCTAssertEqual(clock.bpm, 120, accuracy: 0.5, "audio must not override a pinned (tapped) clock")
    }

    func testUnpinnedClockFollowsConfidentAudio() {
        let clock = BeatClock()
        clock.ingest(estimate: TempoEstimate(bpm: 100, confidence: 0.9, lastBeatOffset: 0.1), endTime: 50)
        XCTAssertEqual(clock.bpm, 100, accuracy: 0.01)
        XCTAssertEqual(clock.source, .audio)
        // Low confidence never drives the clock.
        clock.ingest(estimate: TempoEstimate(bpm: 140, confidence: 0.2, lastBeatOffset: 0), endTime: 51)
        XCTAssertEqual(clock.bpm, 100, accuracy: 0.01)
    }

    func testAudioPhaseCorrectionIsGentle() {
        let clock = BeatClock()
        clock.ingest(estimate: TempoEstimate(bpm: 120, confidence: 0.9, lastBeatOffset: 0), endTime: 50)
        let before = BeatClock.snapshot().beatEpoch
        // Audio now claims the beat sits 200 ms off our grid — correction
        // must be clamped to ≤30 ms so lights never visibly jump.
        clock.ingest(estimate: TempoEstimate(bpm: 120, confidence: 0.9, lastBeatOffset: 0.2), endTime: 52)
        let after = BeatClock.snapshot().beatEpoch
        XCTAssertLessThanOrEqual(abs(after - before), 0.0301,
                                 "per-ingest phase correction must be ≤30 ms")
    }

    func testResyncDownbeatAnchorsBarStart() {
        let clock = BeatClock()
        clock.setBPM(120, now: 10)
        clock.resyncDownbeat(now: 42.37)
        let snap = BeatClock.snapshot()
        XCTAssertEqual(snap.beatPhase(at: 42.37), 0, accuracy: 0.0001)
        XCTAssertEqual(snap.barPhase(at: 42.37), 0, accuracy: 0.0001)
        XCTAssertEqual(snap.beatIndex(at: 42.37 + 0.6), 1, "0.6 s after the anchor at 120 BPM is beat 1")
    }

    func testSnapshotMathWithNoClockIsInert() {
        let snap = BeatSnapshot.none
        XCTAssertEqual(snap.beatPhase(at: 123), 0)
        XCTAssertEqual(snap.beatIndex(at: 123), 0)
        XCTAssertEqual(snap.barPhase(at: 123), 0)
        XCTAssertEqual(snap.beatInterval, 0)
    }
}
