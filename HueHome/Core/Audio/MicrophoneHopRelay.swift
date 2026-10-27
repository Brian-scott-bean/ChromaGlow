// MicrophoneHopRelay.swift
// ChromaGlow — Core/Audio (chunk 2: low-latency capture)
//
// The microphone used to reach analysis through `installTap`, which iOS
// delivers in ~100 ms buffers whatever size is asked for: the published
// level and onset features changed about ten times a second, and an onset
// was stamped up to a whole buffer after the sound. Capture now runs on an
// AVAudioSinkNode at the session's small I/O buffer (~5 ms). That callback
// is on the real-time I/O thread, so it only copies samples in here; the
// relay's own thread cuts them into fixed hops — 1024 frames, ~21 ms at
// 48 kHz, the size the extractor and the Spotify hopper were built for —
// and delivers each one with the host time its first sample was captured.
//
// THREADING CONTRACT: one producer (the I/O thread) calls `write`; one
// consumer delivers — the relay's thread after `start()`, or a test calling
// `drain()` with no thread running. The producer never allocates, never
// calls into analysis, and holds the lock only for a copy. Raw audio lives
// here for at most `capacity` frames and is never stored beyond that.

import AVFoundation
import Foundation
import QuartzCore
import os

final class MicrophoneHopRelay: @unchecked Sendable {

    /// Frames per analysis hop.
    static let defaultHopFrames = 1024
    /// Ring size in frames: ~0.68 s at 48 kHz. A consumer that falls further
    /// behind than this loses the oldest audio, never the newest.
    static let defaultCapacity = 1 << 15

    /// One hop: its samples (valid only during the call), how many, the host
    /// time its first sample was captured, the host time it counts as having
    /// arrived, and a mono buffer of the same samples for raw-buffer taps.
    typealias Deliver = @Sendable (UnsafePointer<Float>, Int, _ captureStart: Double, _ arrival: Double,
                                   AVAudioPCMBuffer?) -> Void

    let sampleRate: Double
    let hopFrames: Int
    let capacity: Int
    private let deliver: Deliver
    private let now: @Sendable () -> Double

    // ── Shared (producer ⇄ consumer), under `lock` ──
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private let ring: UnsafeMutablePointer<Float>
    /// Total frames ever written / read; the ring index is `count % capacity`.
    private var written: UInt64 = 0
    private var read: UInt64 = 0
    /// The newest write's first frame and the host time it was captured.
    private var anchorFrame: UInt64 = 0
    private var anchorHost: Double = 0
    /// The producer overwrote frames the consumer had not read.
    private var overflowed = false
    private var stopped = false

    // ── Consumer only ──
    private let scratch: UnsafeMutablePointer<Float>
    private let hop: UnsafeMutablePointer<Float>
    private var filled = 0
    private var hopStartFrame: UInt64 = 0
    private let hopBuffer: AVAudioPCMBuffer?
    private let wake = DispatchSemaphore(value: 0)
    private var thread: Thread?

    /// Times the consumer fell more than `capacity` behind and the oldest
    /// audio was lost (diagnostics and tests). Consumer only.
    private(set) var overflowCount = 0

    init(sampleRate: Double,
         hopFrames: Int = MicrophoneHopRelay.defaultHopFrames,
         capacity: Int = MicrophoneHopRelay.defaultCapacity,
         now: @escaping @Sendable () -> Double = { CACurrentMediaTime() },
         deliver: @escaping Deliver) {
        let hopFrames = max(1, hopFrames)
        self.sampleRate = sampleRate
        self.hopFrames = hopFrames
        self.capacity = max(hopFrames, capacity)
        self.deliver = deliver
        self.now = now
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        ring = .allocate(capacity: self.capacity)
        ring.initialize(repeating: 0, count: self.capacity)
        scratch = .allocate(capacity: self.capacity)
        scratch.initialize(repeating: 0, count: self.capacity)
        hop = .allocate(capacity: hopFrames)
        hop.initialize(repeating: 0, count: hopFrames)
        hopBuffer = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
            .flatMap { AVAudioPCMBuffer(pcmFormat: $0, frameCapacity: AVAudioFrameCount(hopFrames)) }
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
        ring.deallocate()
        scratch.deallocate()
        hop.deallocate()
    }

    // MARK: - Producer (real-time I/O thread)

    /// Copy `count` frames whose first was captured at `hostTime`. `stride`
    /// steps over the other channels of an interleaved buffer (1 for the
    /// deinterleaved float format the input node normally delivers).
    func write(_ samples: UnsafePointer<Float>, count: Int, stride: Int = 1, hostTime: Double) {
        guard count > 0, stride > 0 else { return }
        // Only the newest `capacity` frames of an oversized write can be kept.
        let skip = max(0, count - capacity)
        let n = count - skip
        os_unfair_lock_lock(lock)
        let start = written
        var index = Int(start % UInt64(capacity))
        if stride == 1 {
            let first = min(n, capacity - index)
            (ring + index).update(from: samples + skip, count: first)
            if first < n { ring.update(from: samples + skip + first, count: n - first) }
        } else {
            for i in 0..<n {
                ring[index] = samples[(skip + i) * stride]
                index += 1
                if index == capacity { index = 0 }
            }
        }
        written = start + UInt64(n)
        anchorFrame = start
        anchorHost = hostTime + Double(skip) / sampleRate
        if written - read > UInt64(capacity) {
            read = written - UInt64(capacity)
            overflowed = true
        }
        os_unfair_lock_unlock(lock)
        wake.signal()
    }

    // MARK: - Consumer

    /// Deliver every complete hop written so far. Consumer thread only.
    func drain() {
        os_unfair_lock_lock(lock)
        let from = read
        let take = Int(written - read)
        let index = Int(from % UInt64(capacity))
        let first = min(take, capacity - index)
        scratch.update(from: ring + index, count: first)
        if first < take { (scratch + first).update(from: ring, count: take - first) }
        read = written
        let anchor = (frame: anchorFrame, host: anchorHost)
        let lost = overflowed
        overflowed = false
        os_unfair_lock_unlock(lock)
        guard take > 0 else { return }

        if lost {
            // A gap in the audio: the partial hop is not contiguous any more.
            overflowCount += 1
            filled = 0
        }
        // Everything drained counts as having arrived now; earlier hops in
        // the batch arrived as far before now as they were captured before
        // the newest frame, so a burst keeps its spacing.
        let drainedEnd = hostTime(ofFrame: from + UInt64(take), anchor: anchor)
        let arrivalOffset = max(0, now() - drainedEnd)

        var offset = 0
        while offset < take {
            if filled == 0 { hopStartFrame = from + UInt64(offset) }
            let chunk = min(hopFrames - filled, take - offset)
            (hop + filled).update(from: scratch + offset, count: chunk)
            filled += chunk
            offset += chunk
            if filled == hopFrames {
                filled = 0
                let start = hostTime(ofFrame: hopStartFrame, anchor: anchor)
                let end = start + Double(hopFrames) / sampleRate
                if let hopBuffer, let dst = hopBuffer.floatChannelData?[0] {
                    dst.update(from: hop, count: hopFrames)
                    hopBuffer.frameLength = AVAudioFrameCount(hopFrames)
                }
                deliver(UnsafePointer(hop), hopFrames, start, end + arrivalOffset, hopBuffer)
            }
        }
    }

    private func hostTime(ofFrame frame: UInt64, anchor: (frame: UInt64, host: Double)) -> Double {
        anchor.host + (Double(frame) - Double(anchor.frame)) / sampleRate
    }

    // MARK: - Thread

    /// Start the delivery thread. Idempotent. The thread keeps the relay
    /// alive until `stop()`, which every start must be paired with.
    func start() {
        os_unfair_lock_lock(lock)
        let alreadyRunning = thread != nil || stopped
        os_unfair_lock_unlock(lock)
        guard !alreadyRunning else { return }
        let t = Thread { [self] in
            while true {
                _ = wake.wait(timeout: .now() + .milliseconds(250))
                os_unfair_lock_lock(lock)
                let done = stopped
                os_unfair_lock_unlock(lock)
                if done { return }
                drain()
            }
        }
        t.name = "ChromaGlow.MicAnalysis"
        t.qualityOfService = .userInteractive
        os_unfair_lock_lock(lock)
        thread = t
        os_unfair_lock_unlock(lock)
        t.start()
    }

    /// Stop delivering. The thread exits after its current hop; anything
    /// still in the ring is discarded. Idempotent.
    func stop() {
        os_unfair_lock_lock(lock)
        stopped = true
        thread = nil
        os_unfair_lock_unlock(lock)
        wake.signal()
    }
}
