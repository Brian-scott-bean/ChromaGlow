// PlayAlongTestSynth.swift
// HueHome Pro — Unit Tests (Play Along)
//
// Deterministic synthetic "room music" for the beat tracker tests — a small
// cut of docs/ios/play-along/beatlab/Synth.swift: kick, snare, hats, a bass
// note on every beat and a chord change on every bar, one room echo, a phone
// mic's low cut and a noise floor. Ground-truth beat times come out with the
// samples, so a test can score exactly what the lights would have used.

import Foundation
@testable import HueHome

enum PlayAlongTestSynth {

    struct Song {
        var bpm: Double
        var leadIn: Double = 0.3
        var bars: Int = 12
        var kickOnAllFour = false
        var drums = true
        var bass = true
        var chords = true
        /// Random speech-like noise bursts instead of music.
        var bursts = false
    }

    struct Rendered {
        var samples: [Float]
        var beats: [(time: Double, isDownbeat: Bool)]
        var fs: Double
    }

    struct Rng {
        var s: UInt64
        mutating func next() -> UInt64 {
            s &+= 0x9E37_79B9_7F4A_7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func signed() -> Double { unit() * 2 - 1 }
    }

    static func render(_ song: Song, fs: Double = 48_000, seed: UInt64 = 7, noise: Float = 0.004) -> Rendered {
        var rng = Rng(s: seed)
        let beatLen = 60 / song.bpm
        let total = song.leadIn + Double(song.bars * 4) * beatLen + 1
        var out = [Float](repeating: 0, count: Int(total * fs))
        var beats: [(Double, Bool)] = []

        let kick = (0..<Int(0.3 * fs)).map { i -> Float in
            let t = Double(i) / fs
            let phase = 2 * Double.pi * (55 * t + 110 * 0.03 * (1 - exp(-t / 0.03)))
            return Float(sin(phase) * exp(-t / 0.14) + (t < 0.004 ? (1 - t / 0.004) * 0.6 : 0))
        }
        let snare = (0..<Int(0.22 * fs)).map { i -> Float in
            let t = Double(i) / fs
            return Float(0.35 * rng.signed() * exp(-t / 0.09) + 0.6 * sin(2 * Double.pi * 185 * t) * exp(-t / 0.06))
        }
        var previousNoise = 0.0
        let hat = (0..<Int(0.05 * fs)).map { i -> Float in
            let n = rng.signed()
            defer { previousNoise = n }
            return Float((n - previousNoise) * 0.5 * exp(-(Double(i) / fs) / 0.018))
        }
        func add(_ wave: [Float], at t: Double, gain: Float) {
            let start = Int((t * fs).rounded())
            guard start >= 0 else { return }
            for i in 0..<wave.count where start + i < out.count { out[start + i] += wave[i] * gain }
        }
        func tone(_ freqs: [Double], at t: Double, length: Double, amp: Double, attack: Double) {
            let start = Int(t * fs), n = Int(length * fs)
            for i in 0..<n where start + i < out.count {
                let tt = Double(i) / fs
                let env = min(1, tt / attack) * (tt > length - 0.03 ? max(0, (length - tt) / 0.03) : 1)
                var v = 0.0
                for f in freqs { v += sin(2 * Double.pi * f * tt) + 0.3 * sin(4 * Double.pi * f * tt) }
                out[start + i] += Float(amp * env * v)
            }
        }

        if song.bursts {
            var t = song.leadIn
            while t < total - 1 {
                t += 0.12 + 0.35 * rng.unit()
                let n = Int((0.06 + 0.2 * rng.unit()) * fs), start = Int(t * fs), amp = 0.2 + 0.3 * rng.unit()
                for i in 0..<n where start + i < out.count {
                    out[start + i] += Float(rng.signed() * amp * sin(Double.pi * Double(i) / Double(n)) * 0.4)
                }
            }
        }

        let chords: [[Double]] = [[220, 261.63, 329.63], [174.61, 220, 261.63], [261.63, 329.63, 392], [196, 246.94, 293.66]]
        let roots: [Double] = [110, 87.31, 130.81, 98]
        if !song.bursts {
            for bar in 0..<song.bars {
                let barStart = song.leadIn + Double(bar * 4) * beatLen
                if song.chords { tone(chords[bar % 4], at: barStart, length: 4 * beatLen, amp: 0.035, attack: 0.12) }
                for b in 0..<4 {
                    let t = barStart + Double(b) * beatLen
                    beats.append((t, b == 0))
                    if song.drums {
                        if song.kickOnAllFour || b == 0 || b == 2 { add(kick, at: t, gain: 0.9) }
                        if b == 1 || b == 3 { add(snare, at: t, gain: 0.55) }
                        add(hat, at: t, gain: 0.25)
                        add(hat, at: t + beatLen / 2, gain: 0.18)
                    }
                    if song.bass { tone([roots[bar % 4]], at: t, length: beatLen * 0.9, amp: 0.12, attack: 0.008) }
                }
            }
        }

        // One room echo, a phone mic's low cut, a noise floor.
        let delay = Int(0.037 * fs)
        if delay < out.count {
            for i in delay..<out.count { out[i] += 0.35 * out[i - delay] }
        }
        let rc = 1 / (2 * Double.pi * 120), a = Float(rc / (rc + 1 / fs))
        var px: Float = 0, py: Float = 0
        for i in 0..<out.count {
            let y = a * (py + out[i] - px)
            px = out[i]; py = y
            out[i] = y * 0.25 + noise * Float(rng.signed())
        }
        return Rendered(samples: out, beats: beats.map { (time: $0.0, isDownbeat: $0.1) }, fs: fs)
    }

    /// Feed `r` to the production front end and tracker the way the device
    /// does — 100 ms buffers, a tracker pass every 0.5 s — and record the
    /// clock the lights would read after each pass.
    @MainActor
    static func track(_ r: Rendered, prior: TempoPrior? = nil,
                      clock existing: BeatClock? = nil) -> [(t: Double, snap: BeatSnapshot, confidence: Double)] {
        let clock = existing ?? BeatClock()
        clock.clear()
        let analyzer = OnsetFrameAnalyzer()
        let tracker = BeatTracker()
        let buffer = Int(r.fs * 0.1)
        var snaps: [(Double, BeatSnapshot, Double)] = []
        r.samples.withUnsafeBufferPointer { p in
            var k = 0
            while (k + 1) * buffer <= r.samples.count {
                let start = Double(k * buffer) / r.fs
                analyzer.process(p.baseAddress! + k * buffer, frameCount: buffer, sampleRate: r.fs, bufferStart: start)
                if k % 5 == 4 {
                    if let o = tracker.update(analyzer.snapshot(seconds: BeatTracker.windowSeconds + 2), prior: prior) {
                        clock.ingest(observation: o)
                    }
                    snaps.append((start + 0.11, BeatClock.snapshot(), clock.confidence))
                }
                k += 1
            }
        }
        return snaps.map { (t: $0.0, snap: $0.1, confidence: $0.2) }
    }

    struct Score {
        var tempoRight = 0, beatsScored = 0
        var errorsMs: [Double] = []
        var downbeats = 0, downbeatsRight = 0

        var medianAbsMs: Double { percentile(0.5) }
        var p90AbsMs: Double { percentile(0.9) }
        var tempoShare: Double { beatsScored > 0 ? Double(tempoRight) / Double(beatsScored) : 0 }
        var downbeatShare: Double { downbeats > 0 ? Double(downbeatsRight) / Double(downbeats) : 0 }

        private func percentile(_ p: Double) -> Double {
            let s = errorsMs.map(abs).sorted()
            guard !s.isEmpty else { return .infinity }
            return s[min(s.count - 1, Int(Double(s.count) * p))]
        }
    }

    /// Score every true beat after `warmup` seconds against the latest clock
    /// recorded before it — what the lights would actually have shown.
    static func score(_ snaps: [(t: Double, snap: BeatSnapshot, confidence: Double)],
                      beats: [(time: Double, isDownbeat: Bool)], bpm: Double, warmup: Double = 10) -> Score {
        var s = Score()
        var idx = 0
        for b in beats where b.time >= warmup {
            while idx + 1 < snaps.count && snaps[idx + 1].t <= b.time { idx += 1 }
            guard idx < snaps.count, snaps[idx].t <= b.time else { continue }
            let snap = snaps[idx].snap
            s.beatsScored += 1
            guard snap.bpm > 0, abs(snap.bpm / bpm - 1) < 0.02 else { continue }
            s.tempoRight += 1
            let ph = snap.beatPhase(at: b.time)
            s.errorsMs.append((ph < 0.5 ? ph : ph - 1) * snap.beatInterval * 1000)
            if b.isDownbeat {
                s.downbeats += 1
                let bp = snap.barPhase(at: b.time) * Double(snap.beatsPerBar)
                if min(bp, Double(snap.beatsPerBar) - bp) < 0.5 { s.downbeatsRight += 1 }
            }
        }
        return s
    }
}
