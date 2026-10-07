// OnsetFrameAnalyzerTests.swift
// HueHome Pro — Unit Tests (Play Along P1)
//
// The beat tracker's front end: 10 ms frames, each stamped with the moment
// its audio was captured — exact to the frame however the buffers arrive.
// The old extractor stamped one value per ~100 ms buffer.

import XCTest
@testable import HueHome

final class OnsetFrameAnalyzerTests: XCTestCase {

    /// Silence with one click at `clickTime`, fed in buffers of `buffer` samples.
    private func feedClick(at clickTime: Double, fs: Double = 48_000, seconds: Double = 2,
                           buffer: Int = 4800, start: Double = 100,
                           into analyzer: OnsetFrameAnalyzer) {
        var samples = [Float](repeating: 0, count: Int(seconds * fs))
        let at = Int(clickTime * fs)
        for i in 0..<240 where at + i < samples.count {
            samples[at + i] = Float(sin(Double(i) * 0.7) * exp(-Double(i) / 60))
        }
        samples.withUnsafeBufferPointer { p in
            var k = 0
            while (k + 1) * buffer <= samples.count {
                analyzer.process(p.baseAddress! + k * buffer, frameCount: buffer, sampleRate: fs,
                                 bufferStart: start + Double(k * buffer) / fs)
                k += 1
            }
        }
    }

    private func peakFluxTime(_ frames: OnsetFrames) -> Double {
        let i = frames.flux.indices.max { frames.flux[$0] < frames.flux[$1] }!
        return frames.times[i]
    }

    func testFramesRunAtOneHundredPerSecond() {
        let analyzer = OnsetFrameAnalyzer()
        feedClick(at: 1.0, into: analyzer)
        let frames = analyzer.snapshot()
        XCTAssertEqual(frames.frameRate, 100, accuracy: 0.01)
        XCTAssertGreaterThan(frames.count, 170, "2 s of audio is ~190 frames after the first window fills")
        for i in 1..<frames.count {
            XCTAssertEqual(frames.times[i] - frames.times[i - 1], 0.01, accuracy: 1e-9)
        }
    }

    /// A click in the MIDDLE of a 100 ms buffer is placed within one frame of
    /// where it was captured — the old pipeline could only say "somewhere in
    /// this buffer".
    func testAClickIsStampedWithinAFrameOfItsCapture() {
        for click in [0.73, 1.0, 1.257] {
            let analyzer = OnsetFrameAnalyzer()
            feedClick(at: click, into: analyzer)
            let peak = peakFluxTime(analyzer.snapshot())
            XCTAssertEqual(peak, 100 + click, accuracy: 0.015, "click at \(click) s")
        }
    }

    func testDeliveryCadenceDoesNotMoveTheStamps() {
        let small = OnsetFrameAnalyzer(), large = OnsetFrameAnalyzer()
        feedClick(at: 1.11, buffer: 1024, into: small)
        feedClick(at: 1.11, buffer: 9600, into: large)
        XCTAssertEqual(peakFluxTime(small.snapshot()), peakFluxTime(large.snapshot()), accuracy: 0.011)
    }

    func testInputLatencyIsSubtractedFromEveryStamp() {
        let plain = OnsetFrameAnalyzer(), corrected = OnsetFrameAnalyzer()
        corrected.setInputLatency(0.02)
        feedClick(at: 1.0, into: plain)
        feedClick(at: 1.0, into: corrected)
        XCTAssertEqual(peakFluxTime(plain.snapshot()) - peakFluxTime(corrected.snapshot()), 0.02, accuracy: 1e-6)
    }

    func testOtherSampleRatesKeepTenMillisecondFrames() {
        for fs in [44_100.0, 24_000.0, 16_000.0] {
            let analyzer = OnsetFrameAnalyzer()
            feedClick(at: 1.0, fs: fs, buffer: Int(fs / 10), into: analyzer)
            let frames = analyzer.snapshot()
            XCTAssertEqual(frames.frameRate, fs / Double(Int((fs * 0.01).rounded())), accuracy: 1e-9)
            XCTAssertEqual(peakFluxTime(frames), 101, accuracy: 0.02, "\(fs) Hz")
        }
    }

    func testTheRingKeepsTwelveSecondsOldestFirst() {
        let analyzer = OnsetFrameAnalyzer()
        feedClick(at: 1, seconds: 15, into: analyzer)
        let all = analyzer.snapshot(seconds: 60)
        XCTAssertLessThanOrEqual(Double(all.count), OnsetFrameAnalyzer.ringSeconds * 100 + 1)
        XCTAssertEqual(all.times.first!, all.times.last! - Double(all.count - 1) * 0.01, accuracy: 1e-6)
        let recent = analyzer.snapshot(seconds: 2)
        XCTAssertEqual(recent.count, 200)
        XCTAssertEqual(recent.times.last, all.times.last)
        XCTAssertEqual(recent.bands.count, recent.count * OnsetFrameAnalyzer.bandCount)
    }
}
