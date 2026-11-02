// MusicAnalysisProbe.swift
// ChromaGlow — Debug builds only (beyond-any-app research, §2 item 6 and §7.1).
//
// How fast Apple's Music Understanding (iOS 27) runs on this phone, and what
// it finds, on a test song made up in memory: a 128 BPM dance track with an
// intro, two builds and drops and a breakdown, whose beats and section starts
// are known exactly. No microphone, nothing saved, nothing sent. "It knows
// what's coming" (remembered song maps) depends on these numbers; nobody has
// published them for an iPhone.

#if DEBUG
import AVFoundation
import CoreMedia
import Foundation
import QuartzCore
#if canImport(MusicUnderstanding)
@_weakLinked import MusicUnderstanding
#endif

enum MusicAnalysisProbe {

    struct TestSong: Sendable {
        let samples: [Float]
        let sampleRate: Double
        let bpm: Double
        /// Every beat, in seconds.
        let beats: [Double]
        /// Where each section after the first starts.
        let sectionStarts: [Double]
        let sectionNames: [String]
        var duration: Double { Double(samples.count) / sampleRate }
    }

    enum Part: String, Sendable { case intro, build, drop, breakdown, outro }

    static let plan: [(part: Part, bars: Int)] = [
        (.intro, 8), (.build, 8), (.drop, 16), (.breakdown, 8), (.build, 8), (.drop, 16), (.outro, 8),
    ]

    /// The test song: 72 bars at 128 BPM (about 2¼ minutes), mono.
    static func makeTestSong(sampleRate fs: Double = 44_100, bpm: Double = 128, seed: UInt64 = 0x50B0) -> TestSong {
        let beat = 60 / bpm, bar = 4 * beat, lead = 0.5
        let totalBars = plan.reduce(0) { $0 + $1.bars }
        var x = [Float](repeating: 0, count: Int((lead + Double(totalBars) * bar + 1.5) * fs))
        var rng = Noise(state: seed)
        let kick = kickWave(fs: fs), clap = noiseWave(fs: fs, seconds: 0.18, decay: 0.05, rng: &rng)
        let hat = hatWave(fs: fs, rng: &rng)
        let chords: [[Double]] = [[220, 261.63, 329.63], [174.61, 220, 261.63], [261.63, 329.63, 392], [196, 246.94, 293.66]]
        let roots: [Double] = [55, 43.65, 65.41, 49]
        var beats: [Double] = [], starts: [Double] = [], names: [String] = []
        var barIndex = 0

        for (si, section) in plan.enumerated() {
            let sectionStart = lead + Double(barIndex) * bar
            names.append(section.part.rawValue)
            if si > 0 { starts.append(sectionStart) }
            for b in 0..<section.bars {
                let t = sectionStart + Double(b) * bar
                let progress = Double(b) / Double(section.bars)
                let chord = chords[barIndex % 4], root = roots[barIndex % 4]
                for q in 0..<4 { beats.append(t + Double(q) * beat) }
                switch section.part {
                case .intro:
                    pad(&x, fs: fs, at: t, length: bar, freqs: chord, amp: 0.10)
                    for e in 0..<8 { add(&x, hat, at: t + Double(e) * beat / 2, fs: fs, gain: e % 2 == 1 ? 0.06 : 0.03) }
                case .build:
                    pad(&x, fs: fs, at: t, length: bar, freqs: chord, amp: 0.08)
                    let steps = progress < 0.5 ? 8 : 16
                    for e in 0..<steps {
                        add(&x, clap, at: t + Double(e) * bar / Double(steps), fs: fs, gain: Float(0.08 + 0.3 * progress))
                    }
                    riser(&x, fs: fs, at: t, length: bar, from: progress, to: progress + 1 / Double(section.bars), rng: &rng)
                case .drop:
                    for q in 0..<4 {
                        add(&x, kick, at: t + Double(q) * beat, fs: fs, gain: 0.9)
                        if q % 2 == 1 { add(&x, clap, at: t + Double(q) * beat, fs: fs, gain: 0.35) }
                        bass(&x, fs: fs, at: t + (Double(q) + 0.5) * beat, length: beat * 0.45, freq: root, amp: 0.22)
                    }
                    for e in 0..<16 { add(&x, hat, at: t + Double(e) * beat / 4, fs: fs, gain: e % 4 == 2 ? 0.08 : 0.035) }
                    pad(&x, fs: fs, at: t, length: bar, freqs: chord, amp: 0.05)
                case .breakdown:
                    pad(&x, fs: fs, at: t, length: bar, freqs: chord, amp: 0.15)
                case .outro:
                    for q in 0..<4 { add(&x, kick, at: t + Double(q) * beat, fs: fs, gain: Float(0.8 * (1 - progress))) }
                    for e in 0..<8 { add(&x, hat, at: t + Double(e) * beat / 2, fs: fs, gain: 0.04) }
                }
                barIndex += 1
            }
        }
        let peak = x.reduce(Float(0)) { max($0, abs($1)) }
        if peak > 0 { for i in x.indices { x[i] *= 0.9 / peak } }
        return TestSong(samples: x, sampleRate: fs, bpm: bpm, beats: beats, sectionStarts: starts, sectionNames: names)
    }

    // MARK: Scores

    /// Share of matched beats within ±`window` (F-measure, one-to-one).
    static func beatF(reference: [Double], found: [Double], window: Double = 0.07) -> Double {
        guard !reference.isEmpty, !found.isEmpty else { return 0 }
        var used = [Bool](repeating: false, count: found.count)
        var hits = 0
        var j0 = 0
        for r in reference {
            while j0 < found.count && found[j0] < r - window { j0 += 1 }
            var best = -1
            var j = j0
            while j < found.count && found[j] <= r + window {
                if !used[j], best < 0 || abs(found[j] - r) < abs(found[best] - r) { best = j }
                j += 1
            }
            if best >= 0 { used[best] = true; hits += 1 }
        }
        let p = Double(hits) / Double(found.count), rc = Double(hits) / Double(reference.count)
        return p + rc > 0 ? 2 * p * rc / (p + rc) : 0
    }

    /// How many true section starts have a found boundary within ±`window`.
    static func boundaryHits(truth: [Double], found: [Double], window: Double = 2) -> Int {
        truth.filter { t in found.contains { abs($0 - t) <= window } }.count
    }

    // MARK: Voices

    struct Noise {
        var state: UInt64
        mutating func next() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int64(bitPattern: state >> 11) & 0xFFFF_FFFF) / Float(0x8000_0000) - 1
        }
    }

    private static func add(_ x: inout [Float], _ wave: [Float], at time: Double, fs: Double, gain: Float) {
        let start = Int(time * fs)
        guard start >= 0 else { return }
        for i in 0..<wave.count where start + i < x.count { x[start + i] += wave[i] * gain }
    }

    private static func kickWave(fs: Double) -> [Float] {
        let n = Int(0.35 * fs)
        var phase = 0.0
        return (0..<n).map { i in
            let t = Double(i) / fs
            phase += 2 * .pi * (45 + 110 * exp(-t / 0.03)) / fs
            return Float(sin(phase) * exp(-t / 0.12))
        }
    }

    private static func noiseWave(fs: Double, seconds: Double, decay: Double, rng: inout Noise) -> [Float] {
        (0..<Int(seconds * fs)).map { i in rng.next() * Float(exp(-Double(i) / fs / decay)) }
    }

    private static func hatWave(fs: Double, rng: inout Noise) -> [Float] {
        var prev: Float = 0
        return (0..<Int(0.05 * fs)).map { i in
            let w = rng.next()
            defer { prev = w }
            return (w - prev) * Float(exp(-Double(i) / fs / 0.012))
        }
    }

    private static func bass(_ x: inout [Float], fs: Double, at time: Double, length: Double, freq: Double, amp: Double) {
        let start = Int(time * fs), n = Int(length * fs)
        for i in 0..<n where start + i < x.count {
            let t = Double(i) / fs
            let env = min(1, t / 0.005) * exp(-t / (length * 0.6))
            let v = sin(2 * .pi * freq * t) + 0.5 * sin(4 * .pi * freq * t) + 0.25 * sin(6 * .pi * freq * t)
            x[start + i] += Float(v * env * amp)
        }
    }

    private static func pad(_ x: inout [Float], fs: Double, at time: Double, length: Double, freqs: [Double], amp: Double) {
        let start = Int(time * fs), n = Int(length * fs)
        for i in 0..<n where start + i < x.count {
            let t = Double(i) / fs
            let env = min(1, t / 0.3) * min(1, (length - t) / 0.3)
            var v = 0.0
            for f in freqs { v += sin(2 * .pi * f * (time + t)) }
            x[start + i] += Float(v / Double(freqs.count) * env * amp)
        }
    }

    private static func riser(_ x: inout [Float], fs: Double, at time: Double, length: Double, from: Double, to: Double,
                              rng: inout Noise) {
        let start = Int(time * fs), n = Int(length * fs)
        var prev: Float = 0
        for i in 0..<n where start + i < x.count {
            let p = from + (to - from) * Double(i) / Double(n)
            let w = rng.next()
            let bright = Float(0.3 + 0.7 * p)
            let v = w - prev * (1 - bright)
            prev = w
            x[start + i] += v * Float(0.12 * p * p)
        }
    }
}

// MARK: - The analysis (iOS 27)

#if canImport(MusicUnderstanding)
@available(iOS 27.0, *)
extension MusicAnalysisProbe {
    struct Timed: Sendable {
        var seconds: Double
        var beats: [Double]
        var bpm: Double?
        var sectionStarts: [Double]
        var instruments: [String]
    }

    /// One session over `[start, start + duration)` of the song.
    static func analyze(_ song: TestSong, start: Double = 0, duration: Double? = nil,
                        types: Set<AnalysisType>? = nil) async throws -> Timed {
        let buffers = slices(song, start: start, duration: duration ?? song.duration - start)
        let stream = AsyncStream<AVReadOnlyAudioPCMBuffer> { continuation in
            for b in buffers { continuation.yield(b) }
            continuation.finish()
        }
        let t0 = CACurrentMediaTime()
        let session = MusicUnderstandingSession(audioProvider: stream)
        let result: MusicUnderstandingSession.SessionResult
        if let types {
            result = try await session.analyze(for: types)
        } else {
            result = try await session.analyze()
        }
        let seconds = CACurrentMediaTime() - t0
        let beats = result.rhythm?.beats.map { $0.seconds + start } ?? []
        let starts = result.structure?.sections.map { $0.start.seconds + start }.filter { $0 > start + 0.5 } ?? []
        let instruments = result.instrumentActivity?.activity.keys.map(\.rawValue).sorted() ?? []
        return Timed(seconds: seconds, beats: beats, bpm: result.rhythm?.beatsPerMinute.map { Double($0) },
                     sectionStarts: starts, instruments: instruments)
    }

    private static func slices(_ song: TestSong, start: Double, duration: Double,
                               chunk: Int = 4096) -> [AVReadOnlyAudioPCMBuffer] {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: song.sampleRate, channels: 1,
                                         interleaved: false) else { return [] }
        let s0 = max(0, Int(start * song.sampleRate))
        let end = min(song.samples.count, s0 + Int(duration * song.sampleRate))
        var out: [AVReadOnlyAudioPCMBuffer] = []
        var pos = s0
        while pos < end {
            let len = min(chunk, end - pos)
            guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(len)),
                  let dst = b.floatChannelData?[0] else { break }
            b.frameLength = AVAudioFrameCount(len)
            song.samples.withUnsafeBufferPointer { src in
                dst.update(from: src.baseAddress!.advanced(by: pos), count: len)
            }
            out.append(AVReadOnlyAudioPCMBuffer(copying: b))
            pos += len
        }
        return out
    }
}
#endif
#endif
