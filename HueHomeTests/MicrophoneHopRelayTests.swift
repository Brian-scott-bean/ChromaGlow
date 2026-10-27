// MicrophoneHopRelayTests.swift
// Chunk 2, low-latency capture: the relay between the real-time I/O thread
// and analysis. Whatever size the I/O cycle has, analysis gets contiguous
// fixed hops stamped with when their first sample was captured.

import AVFoundation
import XCTest
@testable import HueHome

final class MicrophoneHopRelayTests: XCTestCase {

    private struct Hop {
        var samples: [Float]
        var captureStart: Double
        var arrival: Double
        var bufferFrames: Int
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var hops: [Hop] = []
        func add(_ hop: Hop) { lock.lock(); hops.append(hop); lock.unlock() }
        var all: [Hop] { lock.lock(); defer { lock.unlock() }; return hops }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Double = 0
        var now: Double {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }

    private let fs = 48_000.0

    private func makeRelay(hopFrames: Int = 1024, capacity: Int = MicrophoneHopRelay.defaultCapacity,
                           clock: Clock = Clock(), into collector: Collector) -> MicrophoneHopRelay {
        MicrophoneHopRelay(sampleRate: fs, hopFrames: hopFrames, capacity: capacity,
                           now: { clock.now }) { data, count, start, arrival, buffer in
            collector.add(Hop(samples: Array(UnsafeBufferPointer(start: data, count: count)),
                              captureStart: start, arrival: arrival,
                              bufferFrames: Int(buffer?.frameLength ?? 0)))
        }
    }

    /// Writes `count` frames of a ramp (sample value = its frame index)
    /// captured at `t0 + index / fs`.
    private func writeRamp(_ relay: MicrophoneHopRelay, from start: Int, count: Int, t0: Double,
                           stride: Int = 1, otherChannel: Float = -1) {
        var samples = [Float](repeating: otherChannel, count: count * stride)
        for i in 0..<count { samples[i * stride] = Float(start + i) }
        samples.withUnsafeBufferPointer {
            relay.write($0.baseAddress!, count: count, stride: stride, hostTime: t0 + Double(start) / fs)
        }
    }

    func testAnyIOCycleSizeBecomesContiguousHopsStampedAtCapture() {
        let collector = Collector()
        let relay = makeRelay(into: collector)
        let t0 = 500.0
        var written = 0
        // ~5 ms cycles, the old ~100 ms buffers, and odd sizes, mixed.
        for size in [256, 256, 4800, 1000, 37, 512, 3, 2048, 999] {
            writeRamp(relay, from: written, count: size, t0: t0)
            written += size
            relay.drain()
        }
        let hops = collector.all
        XCTAssertEqual(hops.count, written / 1024)
        for (k, hop) in hops.enumerated() {
            XCTAssertEqual(hop.samples.count, 1024)
            XCTAssertEqual(hop.samples.first, Float(k * 1024), "hop \(k) starts where the last one ended")
            XCTAssertEqual(hop.samples.last, Float(k * 1024 + 1023), "and has no gap inside it")
            XCTAssertEqual(hop.captureStart, t0 + Double(k * 1024) / fs, accuracy: 1e-9,
                           "stamped with when its first sample was captured")
            XCTAssertEqual(hop.bufferFrames, 1024, "raw-buffer taps get the same hop")
        }
    }

    func testABurstKeepsItsSpacingAndItsNewestHopArrivesNow() throws {
        let collector = Collector()
        let clock = Clock()
        let relay = makeRelay(clock: clock, into: collector)
        let t0 = 10.0
        writeRamp(relay, from: 0, count: 3 * 1024, t0: t0)
        let captureEnd = t0 + Double(3 * 1024) / fs
        clock.now = captureEnd + 0.004
        relay.drain()

        let hops = collector.all
        XCTAssertEqual(hops.count, 3)
        let hopSeconds = 1024 / fs
        XCTAssertEqual(try XCTUnwrap(hops.last).arrival, clock.now, accuracy: 1e-9)
        for k in 1..<hops.count {
            XCTAssertEqual(hops[k].arrival - hops[k - 1].arrival, hopSeconds, accuracy: 1e-9,
                           "hops that arrive together keep the spacing they were captured with")
        }
    }

    func testAnInterleavedBufferIsReadOnChannelZero() {
        let collector = Collector()
        let relay = makeRelay(into: collector)
        writeRamp(relay, from: 0, count: 1024, t0: 0, stride: 2, otherChannel: -7)
        relay.drain()
        XCTAssertEqual(collector.all.first?.samples, (0..<1024).map(Float.init))
    }

    func testFallingBehindLosesTheOldestAudioNotTheNewest() {
        let collector = Collector()
        let relay = makeRelay(capacity: 4096, into: collector)
        let t0 = 3.0
        writeRamp(relay, from: 0, count: 3000, t0: t0)
        writeRamp(relay, from: 3000, count: 3000, t0: t0)   // no drain: 6000 > 4096
        relay.drain()

        XCTAssertEqual(relay.overflowCount, 1)
        let hops = collector.all
        XCTAssertEqual(hops.count, 4, "the newest 4096 frames survive")
        let firstKept = 6000 - 4096
        XCTAssertEqual(hops.first?.samples.first, Float(firstKept))
        XCTAssertEqual(hops.first?.captureStart ?? 0, t0 + Double(firstKept) / fs, accuracy: 1e-9,
                       "a hop after a gap is still stamped by its own frames")
        XCTAssertEqual(hops.last?.samples.last, 5999)
    }

    func testAnOversizedWriteKeepsItsNewestFrames() {
        let collector = Collector()
        let relay = makeRelay(capacity: 2048, into: collector)
        writeRamp(relay, from: 0, count: 5000, t0: 1)
        relay.drain()
        let hops = collector.all
        XCTAssertEqual(hops.count, 2)
        XCTAssertEqual(hops.first?.samples.first, 5000 - 2048)
        XCTAssertEqual(hops.first?.captureStart ?? 0, 1 + Double(5000 - 2048) / fs, accuracy: 1e-9)
    }

    func testTheThreadDeliversUntilStopped() async throws {
        let collector = Collector()
        let relay = makeRelay(into: collector)
        relay.start()
        writeRamp(relay, from: 0, count: 2048, t0: 0)
        let deadline = Date().addingTimeInterval(2)
        while collector.all.count < 2, Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(collector.all.count, 2, "the relay's own thread delivered both hops")

        relay.stop()
        try await Task.sleep(for: .milliseconds(50))
        writeRamp(relay, from: 2048, count: 2048, t0: 0)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(collector.all.count, 2, "nothing is delivered after stop")
    }
}
