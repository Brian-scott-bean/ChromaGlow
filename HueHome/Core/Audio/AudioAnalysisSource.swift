// AudioAnalysisSource.swift
// ChromaGlow — Core/Audio (audio-source boundary)
//
// Where the analyzed audio comes from. AudioAnalysisEngine used to BE the
// microphone; it now owns demand, lifecycle and publishing, and pulls PCM from
// whichever AudioAnalysisSource is selected. Every source feeds the same
// AudioPCMSink → AudioFeatureExtractor → latestFeatures() path, so the FFT,
// AGC smoothing, onset/tempo tracking, color mapping and Hue output downstream
// are shared — a source only produces PCM.
//
// Real-time contract (all sources): deliveries happen on the source's own
// audio/decoder thread, never hop to the MainActor, never create a Task, and
// never allocate once warm. A delivery is gated on the activation generation
// its sink was issued under, so a stop or source switch invalidates late
// callbacks before they can touch the extractor or the published features.

import AVFoundation
import Foundation
import QuartzCore

/// The audio sources light sync can analyze. Only the microphone exists in a
/// normal build; the experimental Spotify Connect case compiles in only under
/// CHROMAGLOW_EXPERIMENTAL_SPOTIFY (local Debug builds, never Release).
enum AudioAnalysisSourceKind: String, Sendable, CaseIterable {
    case microphone
    #if CHROMAGLOW_EXPERIMENTAL_SPOTIFY
    case spotifyConnect
    #endif
}

@MainActor
protocol AudioAnalysisSource: AnyObject {
    var kind: AudioAnalysisSourceKind { get }

    /// Async preflight (the mic permission prompt). false = cannot run now.
    /// `stillWanted` re-checks the engine's demand after any suspension, so a
    /// demand withdrawn while a prompt was up ends quietly (L-19).
    func prepare(stillWanted: @MainActor () -> Bool) async -> Bool

    /// Begin delivering PCM into `sink`. Synchronous on purpose: the engine's
    /// running/stopped bookkeeping must have no suspension window.
    func start(sink: AudioPCMSink) -> Bool

    /// Stop delivering. Idempotent. The engine has already invalidated the
    /// sink when this runs, so an in-flight delivery is dropped regardless.
    /// `deactivatingSession: false` is a rebuild — the audio session is about
    /// to be re-activated, so a source that owns it must leave it up.
    func stop(deactivatingSession: Bool)

    /// Delivery is actually flowing. The system can stop a source behind the
    /// engine's back (a hardware configuration change stops the mic's
    /// AVAudioEngine), so "started" alone can claim a capture that is dead.
    var isLive: Bool { get }

    /// Set by the engine before start(): the source calls it on the main
    /// actor when it stopped on its own and should be rebuilt.
    var onSystemStop: (@MainActor () async -> Void)? { get set }
}

// MARK: - Sink

/// The single entry every source feeds. A Sendable value captured by
/// real-time callbacks; it carries the activation generation it was issued
/// under and the extractor owned by that activation.
struct AudioPCMSink: Sendable {
    let generation: UInt64
    let extractor: AudioFeatureExtractor

    /// True while this sink's activation is the live one.
    var isCurrent: Bool { AudioAnalysisEngine.isCurrentActivation(generation) }

    /// The microphone tap's path: analyze channel 0 as it arrives ("now"),
    /// then fan the untouched buffer out to raw-buffer taps. `when` is the
    /// tap's buffer time: the tempo ring is stamped with when the audio was
    /// CAPTURED (the buffer's midpoint), not when the callback ran — a whole
    /// ~100 ms buffer plus the tap's dispatch delay later — so BeatClock's
    /// grid isn't anchored late. Arrival time still stamps the features.
    func deliver(buffer: AVAudioPCMBuffer, sampleRate: Float, when: AVAudioTime?) {
        guard isCurrent else { return }
        if let data = buffer.floatChannelData?[0] {
            let hostTime = CACurrentMediaTime()
            let frameCount = Int(buffer.frameLength)
            let captureTime = AudioFeatureExtractor.captureMidpoint(
                bufferStart: when.flatMap { $0.isHostTimeValid ? AVAudioTime.seconds(forHostTime: $0.hostTime) : nil },
                frameCount: frameCount,
                sampleRate: Double(sampleRate))
            if let features = extractor.process(
                data: data,
                frameCount: frameCount,
                sampleRate: sampleRate,
                hostTime: hostTime,
                captureTime: captureTime
            ) {
                AudioAnalysisEngine.publish(features, generation: generation)
            }
        }
        AudioAnalysisEngine.fanOut(buffer, sampleRate: sampleRate)
    }

    /// One mono analysis hop from a non-microphone source.
    /// `presentationTime` (CACurrentMediaTime timebase) is when this audio is
    /// HEARD: every timestamp the extractor stamps (features, onsets, the
    /// tempo envelope) lives on that clock, and latestFeatures() reveals the
    /// hop only once that moment arrives — which is how a source whose audio
    /// plays out later (a playback queue, AirPlay) keeps lights in sync.
    func deliver(
        mono: UnsafePointer<Float>,
        frameCount: Int,
        sampleRate: Float,
        presentationTime: Double,
        buffer: AVAudioPCMBuffer?
    ) {
        guard isCurrent else { return }
        if let features = extractor.process(
            data: mono,
            frameCount: frameCount,
            sampleRate: sampleRate,
            hostTime: presentationTime
        ) {
            AudioAnalysisEngine.publish(features, generation: generation)
        }
        if let buffer {
            AudioAnalysisEngine.fanOut(buffer, sampleRate: sampleRate)
        }
    }

    /// The source went quiet (paused, disconnected, stalled): show silence
    /// now instead of holding the last hop. Gated like every delivery.
    func publishSilence() {
        AudioAnalysisEngine.publishSilence(generation: generation)
    }
}

// MARK: - Interleaved PCM → mono analysis hops

/// Downmixes interleaved PCM to mono and re-blocks it into fixed analysis
/// hops (1024 frames — what the mic tap requests), so a decoder's arbitrary
/// packet sizes reach the extractor exactly like microphone buffers.
///
/// THREADING CONTRACT: one producer thread at a time (same as the extractor).
/// Zero allocation per push once warm; `reset()` and a sample-rate change are
/// the only allocating paths.
final class InterleavedPCMHopper: @unchecked Sendable {
    let hopFrames: Int
    private var accumulator: [Float]
    private var filled = 0
    private var bufferRate: Double = 0
    /// Reused mono buffer handed to raw-buffer taps for each hop.
    private(set) var hopBuffer: AVAudioPCMBuffer?

    init(hopFrames: Int = 1024) {
        self.hopFrames = hopFrames
        self.accumulator = [Float](repeating: 0, count: hopFrames)
    }

    func reset() {
        filled = 0
    }

    /// Push `frames` interleaved frames; `emit` runs once per completed hop
    /// with a pointer valid only for the duration of the call.
    func push(
        _ samples: UnsafePointer<Float>,
        frames: Int,
        channels: Int,
        sampleRate: Double,
        emit: (UnsafePointer<Float>, Int, AVAudioPCMBuffer?) -> Void
    ) {
        guard frames > 0, channels > 0, sampleRate > 0 else { return }
        if sampleRate != bufferRate {
            bufferRate = sampleRate
            filled = 0
            hopBuffer = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
                .flatMap { AVAudioPCMBuffer(pcmFormat: $0, frameCapacity: AVAudioFrameCount(hopFrames)) }
        }
        let scale = 1 / Float(channels)
        accumulator.withUnsafeMutableBufferPointer { acc in
            var frame = 0
            while frame < frames {
                let take = min(hopFrames - filled, frames - frame)
                for i in 0..<take {
                    let base = (frame + i) * channels
                    var sum: Float = 0
                    for c in 0..<channels { sum += samples[base + c] }
                    acc[filled + i] = sum * scale
                }
                filled += take
                frame += take
                if filled == hopFrames {
                    if let hopBuffer, let dst = hopBuffer.floatChannelData?[0] {
                        dst.update(from: acc.baseAddress!, count: hopFrames)
                        hopBuffer.frameLength = AVAudioFrameCount(hopFrames)
                    }
                    emit(acc.baseAddress!, hopFrames, hopBuffer)
                    filled = 0
                }
            }
        }
    }
}

// MARK: - Presentation-time delay line

/// Bounded FIFO of analysis frames waiting for their presentation time.
/// Fixed capacity, preallocated, overwrite-oldest — never grows. Only touched
/// under AudioAnalysisEngine's features lock.
struct AnalysisFeatureDelayLine {
    static let capacity = 512   // ≈ 12 s of 1024-frame hops at 44.1 kHz

    private var slots = [AudioFeatures](repeating: .silent, count: AnalysisFeatureDelayLine.capacity)
    private var head = 0
    private(set) var count = 0

    var isEmpty: Bool { count == 0 }

    mutating func append(_ features: AudioFeatures) {
        if count == Self.capacity {
            head = (head + 1) % Self.capacity   // drop the oldest — bounded
            count -= 1
        }
        slots[(head + count) % Self.capacity] = features
        count += 1
    }

    /// Pop every frame whose presentation time has arrived; returns the
    /// newest of them, or nil when none is due yet.
    mutating func popDue(now: Double) -> AudioFeatures? {
        var due: AudioFeatures?
        while count > 0, slots[head].timestamp <= now {
            due = slots[head]
            head = (head + 1) % Self.capacity
            count -= 1
        }
        return due
    }

    mutating func removeAll() {
        head = 0
        count = 0
    }
}
