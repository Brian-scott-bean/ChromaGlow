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

    /// The tempo ring anchors BeatClock's grid, which is extrapolated into the
    /// future — so it must carry when the audio was CAPTURED (the buffer's
    /// midpoint), not when the tap callback ran a whole buffer later. The
    /// published features keep the arrival time the onset punch decays from.
    func testTheTempoRingIsStampedWithCaptureTimeAndFeaturesWithArrival() throws {
        let mid = try XCTUnwrap(AudioFeatureExtractor.captureMidpoint(
            bufferStart: 100, frameCount: 4800, sampleRate: 48_000))
        XCTAssertEqual(mid, 100.05, accuracy: 1e-12, "start + half of a 100 ms buffer")
        XCTAssertNil(AudioFeatureExtractor.captureMidpoint(bufferStart: nil, frameCount: 4800,
                                                           sampleRate: 48_000),
                     "no valid AVAudioTime → no capture time (callers fall back)")
        XCTAssertNil(AudioFeatureExtractor.captureMidpoint(bufferStart: .nan, frameCount: 4800,
                                                           sampleRate: 48_000))
        XCTAssertNil(AudioFeatureExtractor.captureMidpoint(bufferStart: 100, frameCount: 4800,
                                                           sampleRate: 0))

        let ex = AudioFeatureExtractor()
        var phase: Float = 0
        let buffer = sineBuffer(hz: 300, amplitude: 0.1, phase: &phase)
        let features = try XCTUnwrap(buffer.withUnsafeBufferPointer { buf in
            ex.process(data: buf.baseAddress!, frameCount: frames, sampleRate: sampleRate,
                       hostTime: 200.12, captureTime: 200.0116)
        })
        XCTAssertEqual(features.timestamp, 200.12, "features carry the arrival time")
        XCTAssertEqual(ex.onsetEnvelopeSnapshot().endTime, 200.0116, accuracy: 1e-12,
                       "the tempo ring carries the capture time")

        // Without a capture time the ring falls back to the arrival time.
        let fallback = AudioFeatureExtractor()
        buffer.withUnsafeBufferPointer { buf in
            _ = fallback.process(data: buf.baseAddress!, frameCount: frames,
                                 sampleRate: sampleRate, hostTime: 300.5)
        }
        XCTAssertEqual(fallback.onsetEnvelopeSnapshot().endTime, 300.5, accuracy: 1e-12)
    }

    /// The buffer a DEVICE delivers, not the 1024 frames `installTap` asks for:
    /// iOS hands the tap ~100 ms (4800 frames at 48 kHz), which `analyze()`
    /// reduces to a 4096-point FFT. The ring holds one entry per BUFFER, so its
    /// rate is 10 Hz. Stating the FFT's rate (48000 / 4096 = 11.72 Hz) read a
    /// 120 BPM click track as ~141 BPM and put the last beat ~15 % too close to
    /// the envelope's end.
    func testDeviceSizedBuffersStateTheBufferRateAndReadTheRealTempo() throws {
        let rate: Float = 48_000
        let bufferFrames = 4800
        let ex = AudioFeatureExtractor()
        var rng = LCG(state: 7)
        // A click every 5 buffers = every 0.5 s = 120 BPM. Each click is a
        // ~20 ms noise burst early in its buffer, inside the 4096-point window;
        // the buffers between are silent, so the envelope is a clean spike train.
        for hop in 0..<80 {
            var buffer = [Float](repeating: 0, count: bufferFrames)
            if hop % 5 == 0 {
                for i in 800..<1760 { buffer[i] = Float(rng.next() * 2 - 1) * 0.5 }
            }
            let hostTime = Double(hop) * Double(bufferFrames) / Double(rate)
            buffer.withUnsafeBufferPointer { buf in
                _ = ex.process(data: buf.baseAddress!, frameCount: bufferFrames,
                               sampleRate: rate, hostTime: hostTime)
            }
        }
        let snap = ex.onsetEnvelopeSnapshot()
        XCTAssertEqual(snap.envelope.count, 80)
        XCTAssertEqual(snap.hopRate, 10.0, accuracy: 1e-9,
                       "one ring entry per 4800-frame buffer at 48 kHz is 10 entries per second")

        let estimate = try XCTUnwrap(TempoEstimator().update(onsetEnvelope: snap.envelope,
                                                             hopRate: snap.hopRate))
        XCTAssertEqual(estimate.bpm, 120, accuracy: 3.0,
                       "a 120 BPM click in device-sized buffers must read ~120, not ~141")
        // The last click is buffer 75 of 0…79: four buffers before the end.
        XCTAssertEqual(estimate.lastBeatOffset, 0.4, accuracy: 0.1 + 1e-9,
                       "the beat offset is stated in seconds at the buffer rate")
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

    /// One stray Tap used to pin the clock at whatever it had — 0 BPM on a
    /// fresh clock — and a pinned clock ignores the mic until "Auto".
    func testASingleStrayTapDoesNotPinTheClock() {
        let clock = BeatClock()
        clock.tap(now: 10)
        XCTAssertFalse(clock.isPinned, "one tap measures no tempo")
        XCTAssertEqual(clock.bpm, 0)
        XCTAssertEqual(clock.source, .none)
        clock.ingest(estimate: TempoEstimate(bpm: 100, confidence: 0.9, lastBeatOffset: 0), endTime: 20)
        XCTAssertEqual(clock.bpm, 100, accuracy: 0.01, "the mic can still lock after a stray tap")
        XCTAssertEqual(clock.source, .audio)
    }

    func testASingleTapLeavesAnAudioDrivenClockAlone() {
        let clock = BeatClock()
        clock.ingest(estimate: TempoEstimate(bpm: 120, confidence: 0.9, lastBeatOffset: 0), endTime: 50)
        let before = BeatClock.snapshot()
        clock.tap(now: 51.13)
        XCTAssertFalse(clock.isPinned)
        XCTAssertEqual(clock.source, .audio)
        XCTAssertEqual(BeatClock.snapshot(), before, "neither tempo nor phase moves on one tap")
        // The second tap measures a tempo and pins.
        clock.tap(now: 51.73)
        XCTAssertTrue(clock.isPinned)
        XCTAssertEqual(clock.source, .tap)
        XCTAssertEqual(clock.bpm, 100, accuracy: 0.01)
        XCTAssertEqual(BeatClock.snapshot().beatPhase(at: 51.73), 0, accuracy: 1e-9)
    }

    func testASingleTapReAnchorsAClockTheUserAlreadyOwns() {
        let clock = BeatClock()
        clock.setBPM(100, now: 10)
        clock.tap(now: 50.37)
        XCTAssertTrue(clock.isPinned)
        XCTAssertEqual(clock.bpm, 100, accuracy: 1e-9)
        XCTAssertEqual(BeatClock.snapshot().beatPhase(at: 50.37), 0, accuracy: 1e-9,
                       "a tap on a pinned clock is still a beat")
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

    /// The ±1 BPM buttons (and a Tap Dial twist) call `setBPM` on a running
    /// clock. Phase is `(t − epoch) / interval`, so changing the interval
    /// under the old epoch rescaled every beat since it: 100 s into a 120 BPM
    /// clock, +1 BPM moved the phase at "now" from 0.30 to 0.97 of a beat and
    /// jumped the bar. The beat position at the moment of the change must hold.
    func testSetBPMKeepsBeatAndBarPositionContinuous() {
        let clock = BeatClock()
        clock.setBPM(120, now: 10)
        let t = 110.15                                   // 200.3 beats in
        let before = BeatClock.snapshot()
        clock.setBPM(121, now: t)
        let after = BeatClock.snapshot()
        XCTAssertEqual(after.bpm, 121)
        XCTAssertEqual(after.beatPhase(at: t), before.beatPhase(at: t), accuracy: 1e-9,
                       "a tempo change must not jump the beat phase")
        XCTAssertEqual(after.beatIndex(at: t), before.beatIndex(at: t),
                       "…or skip beats")
        XCTAssertEqual(after.barPhase(at: t), before.barPhase(at: t), accuracy: 1e-9,
                       "…or move the bar")
        // From the pivot on, the grid advances at the NEW interval.
        let nextBeat = t + (1 - after.beatPhase(at: t)) * (60.0 / 121.0)
        XCTAssertEqual(after.beatPhase(at: nextBeat + 1e-6), 0, accuracy: 1e-4)
    }

    /// The audio path drifts the tempo a fraction of a BPM at a time — and
    /// five minutes into a set a 0.3 BPM drift under the old epoch was a
    /// ~half-beat jump that the ≤30 ms correction then crept after for
    /// seconds. With the grid held at the analysis end time, an estimate that
    /// agrees with the grid about where the beat fell needs no correction.
    func testAudioTempoDriftKeepsTheGridWhereTheBeatIs() {
        let clock = BeatClock()
        clock.ingest(estimate: TempoEstimate(bpm: 120, confidence: 0.9, lastBeatOffset: 0),
                     endTime: 50)                        // epoch 50
        let end = 350.1                                  // 600.2 beats in; last beat at 350.0
        let phaseBefore = BeatClock.snapshot().beatPhase(at: end)
        clock.ingest(estimate: TempoEstimate(bpm: 120.3, confidence: 0.9, lastBeatOffset: 0.1),
                     endTime: end)
        let after = BeatClock.snapshot()
        XCTAssertEqual(after.bpm, 120.3, accuracy: 1e-9)
        XCTAssertEqual(after.beatPhase(at: end), phaseBefore, accuracy: 0.001,
                       "the drift must not move the beat position at the analysis end")
        let phaseAtBeat = after.beatPhase(at: 350.0)
        XCTAssertLessThan(min(phaseAtBeat, 1 - phaseAtBeat), 0.001,
                          "the observed beat still lands on the grid")
    }

    func testSnapshotMathWithNoClockIsInert() {
        let snap = BeatSnapshot.none
        XCTAssertEqual(snap.beatPhase(at: 123), 0)
        XCTAssertEqual(snap.beatIndex(at: 123), 0)
        XCTAssertEqual(snap.barPhase(at: 123), 0)
        XCTAssertEqual(snap.beatInterval, 0)
    }
}
