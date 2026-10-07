// Synth.swift — deterministic synthetic "room music" for the beat lab.
// Drum kit (kick 1&3, snare 2&4, hats on 8ths), bass on beats, pad chords per bar,
// Schroeder reverb, phone-mic band limits, pink noise. Ground-truth beat times out.

import Foundation

struct SplitMix {
    var s: UInt64
    mutating func next() -> UInt64 {
        s &+= 0x9E3779B97F4A7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func gauss() -> Double {
        let u1 = max(1e-12, unit()), u2 = unit()
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
}

struct Segment {
    var bpm: Double
    var leadIn: Double          // silence before the first beat (s)
    var bars: Int
    var gapAfter: Double = 0    // silence after (s)
    var hats: Bool = true
    var kickOnAllFour: Bool = false   // four-on-the-floor (house) instead of rock 1&3
    var swing: Double = 0
    var drums: Bool = true
    var bass: Bool = true
    var pad: Bool = true
    var bursts: Bool = false          // random speech-like noise bursts (no beat)
    var driftPct: Double = 0          // sinusoidal tempo drift amplitude (live drummer)
    var driftPeriod: Double = 20
}

struct Rendered {
    var samples: [Float]
    var beats: [(time: Double, bpm: Double, isDownbeat: Bool)]
    var fs: Double
}

enum Synth {
    static func render(_ segments: [Segment], fs: Double = 48_000, seed: UInt64 = 1,
                       noiseDB: Double = -24, reverbWet: Float = 0.3, humanizeMs: Double = 4) -> Rendered {
        var rng = SplitMix(s: seed)
        // Total length.
        var total = 0.0
        for s in segments { total += s.leadIn + Double(s.bars * 4) * 60 / s.bpm + s.gapAfter }
        total += 1
        let n = Int(total * fs)
        var out = [Float](repeating: 0, count: n)
        var beats: [(Double, Double, Bool)] = []

        let kick = kickWave(fs: fs)
        let snare = snareWave(fs: fs, rng: &rng)
        let hat = hatWave(fs: fs, rng: &rng)

        let chords: [[Double]] = [[220, 261.63, 329.63], [174.61, 220, 261.63], [261.63, 329.63, 392], [196, 246.94, 293.66]]
        let roots: [Double] = [110, 87.31, 130.81, 98]

        var t0 = 0.0
        for seg in segments {
            let beatLen = 60 / seg.bpm
            let start = t0 + seg.leadIn
            // Beat times: integrate a drifting tempo (constant when driftPct == 0).
            var beatTimes: [Double] = []
            var tb0 = start
            for i in 0..<(seg.bars * 4 + 1) {
                beatTimes.append(tb0)
                let local = seg.bpm * (1 + seg.driftPct / 100 * sin(2 * .pi * (tb0 - start) / seg.driftPeriod))
                tb0 += 60 / local
                _ = i
            }
            if seg.bursts {
                var tt = start
                let end = start + Double(seg.bars * 4) * beatLen
                while tt < end {
                    tt += 0.12 + 0.35 * rng.unit()
                    let len = Int((0.06 + 0.2 * rng.unit()) * fs)
                    let st = Int(tt * fs)
                    let amp = 0.2 + 0.3 * rng.unit()
                    var prev = 0.0
                    for i in 0..<len where st + i < out.count {
                        let x = rng.gauss(); let v = x - 0.5 * prev; prev = x
                        let env = sin(.pi * Double(i) / Double(len))
                        out[st + i] += Float(v * amp * env * 0.4)
                    }
                }
            }
            for bar in 0..<seg.bars {
                let chord = chords[bar % chords.count]
                let root = roots[bar % roots.count]
                let barStart = beatTimes[bar * 4]
                let barLen = beatTimes[bar * 4 + 4] - barStart
                // Pad: chord held for the bar, slow attack.
                if seg.pad { addPad(&out, fs: fs, at: barStart, length: barLen, freqs: chord, amp: 0.035) }
                for b in 0..<4 {
                    let tb = beatTimes[bar * 4 + b]
                    let thisBeatLen = beatTimes[bar * 4 + b + 1] - tb
                    if seg.drums || seg.bass || seg.pad { beats.append((tb, 60 / thisBeatLen, b == 0)) }
                    let h = { (rng: inout SplitMix) -> Double in rng.gauss() * humanizeMs / 1000 }
                    let vel = { (rng: inout SplitMix) -> Float in Float(0.85 + 0.15 * rng.unit()) }
                    let isKick = seg.kickOnAllFour || b == 0 || b == 2
                    if seg.drums {
                        if isKick { add(&out, kick, at: tb + h(&rng), fs: fs, gain: 0.9 * vel(&rng)) }
                        if b == 1 || b == 3 { add(&out, snare, at: tb + h(&rng), fs: fs, gain: 0.55 * vel(&rng)) }
                        if seg.hats {
                            add(&out, hat, at: tb + h(&rng), fs: fs, gain: 0.25 * vel(&rng))
                            add(&out, hat, at: tb + thisBeatLen * (0.5 + seg.swing) + h(&rng), fs: fs, gain: 0.18 * vel(&rng))
                        }
                    }
                    if seg.bass { addBass(&out, fs: fs, at: tb, length: thisBeatLen * 0.9, freq: root, amp: 0.12) }
                }
            }
            t0 = beatTimes[seg.bars * 4] + seg.gapAfter
        }

        // Room: Schroeder reverb, then phone-mic band limits, then noise.
        var wet = schroeder(out, fs: fs)
        for i in 0..<n { wet[i] = out[i] * (1 - reverbWet) + wet[i] * reverbWet }
        var y = highPass(wet, fs: fs, cutoff: 120)
        y = lowPass(y, fs: fs, cutoff: 9000)
        // Normalize to ~ -20 dBFS RMS over the musical part, then add pink noise.
        var rms: Double = 0
        for v in y { rms += Double(v * v) }
        rms = sqrt(rms / Double(n))
        let g = rms > 0 ? Float(0.1 / rms) : 1
        for i in 0..<n { y[i] *= g }
        let noiseRMS = 0.1 * pow(10, noiseDB / 20)
        let pink = pinkNoise(count: n, rng: &rng)
        var prms: Double = 0
        for v in pink { prms += Double(v * v) }
        prms = sqrt(prms / Double(n))
        let ng = Float(noiseRMS / max(prms, 1e-9))
        for i in 0..<n { y[i] += pink[i] * ng }
        return Rendered(samples: y, beats: beats.map { (time: $0.0, bpm: $0.1, isDownbeat: $0.2) }, fs: fs)
    }

    // MARK: Voices

    static func kickWave(fs: Double) -> [Float] {
        let len = Int(0.35 * fs)
        var w = [Float](repeating: 0, count: len)
        var phase = 0.0
        for i in 0..<len {
            let t = Double(i) / fs
            let f = 55 + 110 * exp(-t / 0.03)
            phase += 2 * .pi * f / fs
            let env = exp(-t / 0.14) * min(1, t / 0.002)
            // Click transient + body.
            let click = t < 0.004 ? (1 - t / 0.004) * 0.6 : 0
            w[i] = Float(sin(phase) * env + click)
        }
        return w
    }

    static func snareWave(fs: Double, rng: inout SplitMix) -> [Float] {
        let len = Int(0.25 * fs)
        var w = [Float](repeating: 0, count: len)
        var prev = 0.0
        for i in 0..<len {
            let t = Double(i) / fs
            let noise = rng.gauss()
            let hp = noise - prev * 0.6   // crude high-shelf
            prev = noise
            let env = exp(-t / 0.09) * min(1, t / 0.001)
            let body = sin(2 * .pi * 185 * t) * exp(-t / 0.06)
            w[i] = Float(0.7 * hp * env * 0.5 + 0.6 * body)
        }
        return w
    }

    static func hatWave(fs: Double, rng: inout SplitMix) -> [Float] {
        let len = Int(0.06 * fs)
        var w = [Float](repeating: 0, count: len)
        var prev = 0.0
        for i in 0..<len {
            let t = Double(i) / fs
            let noise = rng.gauss()
            let hp = noise - prev   // first difference = high-pass
            prev = noise
            w[i] = Float(hp * exp(-t / 0.018) * 0.5)
        }
        return w
    }

    static func add(_ out: inout [Float], _ wave: [Float], at time: Double, fs: Double, gain: Float) {
        let start = Int((time * fs).rounded())
        guard start >= 0 else { return }
        for i in 0..<wave.count where start + i < out.count { out[start + i] += wave[i] * gain }
    }

    static func addBass(_ out: inout [Float], fs: Double, at time: Double, length: Double, freq: Double, amp: Double) {
        let start = Int(time * fs), len = Int(length * fs)
        for i in 0..<len where start + i < out.count && start + i >= 0 {
            let t = Double(i) / fs
            let env = min(1, t / 0.008) * (0.6 + 0.4 * exp(-t / 0.08)) * (t > length - 0.02 ? max(0, (length - t) / 0.02) : 1)
            out[start + i] += Float(amp * env * (sin(2 * .pi * freq * t) + 0.5 * sin(4 * .pi * freq * t)))
        }
    }

    static func addPad(_ out: inout [Float], fs: Double, at time: Double, length: Double, freqs: [Double], amp: Double) {
        let start = Int(time * fs), len = Int(length * fs)
        for i in 0..<len where start + i < out.count && start + i >= 0 {
            let t = Double(i) / fs
            let env = min(1, t / 0.12) * (t > length - 0.05 ? max(0, (length - t) / 0.05) : 1)
            var v = 0.0
            for f in freqs { v += sin(2 * .pi * f * t) + 0.3 * sin(4 * .pi * f * t) }
            out[start + i] += Float(amp * env * v)
        }
    }

    // MARK: Room

    static func schroeder(_ x: [Float], fs: Double) -> [Float] {
        let combDelays = [0.0297, 0.0371, 0.0411, 0.0437].map { Int($0 * fs) }
        let rt60 = 0.6
        var sum = [Float](repeating: 0, count: x.count)
        for d in combDelays {
            let g = Float(pow(10, -3 * Double(d) / fs / rt60))
            var buf = [Float](repeating: 0, count: d)
            var idx = 0
            for i in 0..<x.count {
                let yv = buf[idx]
                buf[idx] = x[i] + yv * g
                idx = (idx + 1) % d
                sum[i] += yv * 0.25
            }
        }
        var y = sum
        for (dSec, g) in [(0.005, Float(0.7)), (0.0017, Float(0.7))] {
            let d = Int(dSec * fs)
            var buf = [Float](repeating: 0, count: d)
            var idx = 0
            var out = [Float](repeating: 0, count: y.count)
            for i in 0..<y.count {
                let bufOut = buf[idx]
                let v = y[i] + bufOut * g
                out[i] = bufOut - v * g
                buf[idx] = v
                idx = (idx + 1) % d
            }
            y = out
        }
        return y
    }

    static func highPass(_ x: [Float], fs: Double, cutoff: Double) -> [Float] {
        let rc = 1 / (2 * .pi * cutoff), dt = 1 / fs
        let a = Float(rc / (rc + dt))
        var y = [Float](repeating: 0, count: x.count)
        var prevX: Float = 0, prevY: Float = 0
        for i in 0..<x.count {
            let v = a * (prevY + x[i] - prevX)
            y[i] = v; prevY = v; prevX = x[i]
        }
        // Second pass → 2nd order.
        var y2 = [Float](repeating: 0, count: x.count)
        prevX = 0; prevY = 0
        for i in 0..<y.count {
            let v = a * (prevY + y[i] - prevX)
            y2[i] = v; prevY = v; prevX = y[i]
        }
        return y2
    }

    static func lowPass(_ x: [Float], fs: Double, cutoff: Double) -> [Float] {
        let rc = 1 / (2 * .pi * cutoff), dt = 1 / fs
        let a = Float(dt / (rc + dt))
        var y = [Float](repeating: 0, count: x.count)
        var prev: Float = 0
        for i in 0..<x.count { prev += a * (x[i] - prev); y[i] = prev }
        return y
    }

    static func pinkNoise(count: Int, rng: inout SplitMix) -> [Float] {
        // Paul Kellet's economy pink filter.
        var b0 = 0.0, b1 = 0.0, b2 = 0.0
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let w = rng.gauss()
            b0 = 0.99765 * b0 + w * 0.0990460
            b1 = 0.96300 * b1 + w * 0.2965164
            b2 = 0.57000 * b2 + w * 1.0526913
            out[i] = Float(b0 + b1 + b2 + w * 0.1848)
        }
        return out
    }
}
