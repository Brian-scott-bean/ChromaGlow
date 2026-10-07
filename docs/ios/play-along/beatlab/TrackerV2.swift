// TrackerV2.swift — prototype of the proposed tracker.
//  • ODF: 10 ms hops (480 @ 48 kHz), 1024-pt Hann window, log-compressed band
//    energies (18 log-spaced bands), half-wave-rectified flux. Every frame is
//    stamped with its own capture time (window centre), not the buffer's.
//  • Tempo: autocorrelation over the last 8 s, multi-harmonic comb evaluated
//    on a 0.25-BPM grid with fractional lags, log-Gaussian prior, hysteresis
//    with octave awareness.
//  • Phase: comb phase search at 2 ms resolution over the last ~12 beats with
//    recency weighting, using the EXACT (fractional) period.
//  • Bar phase: low-band (kick) vs mid-band (snare) accents folded on the bar.

import Accelerate
import Foundation

final class OnsetODF {
    let fs: Double
    let hop: Int
    let win: Int
    private var history: [Float]
    private var filled = 0
    private var pendingHop = 0
    private var samplesSeen: Int = 0
    private var firstSampleTime: Double = 0
    private var setup: FFTSetup
    private let log2n: vDSP_Length
    private var window: [Float]
    private var windowed: [Float]
    private var realp: [Float]
    private var imagp: [Float]
    private var mags: [Float]
    private var bandEdges: [Int] = []
    private var prev: [Float] = []
    var gamma: Float = 200

    // Outputs (streaming, append-only)
    private(set) var odf: [Float] = []
    private(set) var low: [Float] = []
    private(set) var mid: [Float] = []
    private(set) var high: [Float] = []
    private(set) var bands: [[Float]] = []
    private(set) var times: [Double] = []

    init(fs: Double, hop: Int = 480, win: Int = 1024) {
        self.fs = fs; self.hop = hop; self.win = win
        history = [Float](repeating: 0, count: win)
        log2n = vDSP_Length(log2(Double(win)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(FFT_RADIX2))!
        window = [Float](repeating: 0, count: win)
        vDSP_hann_window(&window, vDSP_Length(win), Int32(vDSP_HANN_NORM))
        windowed = [Float](repeating: 0, count: win)
        realp = [Float](repeating: 0, count: win / 2)
        imagp = [Float](repeating: 0, count: win / 2)
        mags = [Float](repeating: 0, count: win / 2)
        let hzPerBin = fs / Double(win)
        let edgesHz: [Double] = [30, 94, 141, 188, 281, 375, 469, 656, 844, 1125, 1500, 2063, 2813, 3750, 5156, 7031, 9375, 12188, 16000]
        bandEdges = edgesHz.map { max(1, min(win / 2, Int(($0 / hzPerBin).rounded()))) }
        prev = [Float](repeating: 0, count: bandEdges.count - 1)
    }

    private var ring: [Float] = []
    private var ringPos = 0

    /// Push a buffer whose first sample was captured at `bufferStartTime`.
    func push(_ data: UnsafePointer<Float>, count: Int, bufferStartTime: Double) {
        if ring.isEmpty { ring = [Float](repeating: 0, count: win) }
        for i in 0..<count {
            ring[ringPos] = data[i]
            ringPos = (ringPos + 1) % win
            samplesSeen += 1
            pendingHop += 1
            if pendingHop == hop {
                pendingHop = 0
                if samplesSeen >= win {
                    // unroll ring (oldest first) into history
                    for j in 0..<win { history[j] = ring[(ringPos + j) % win] }
                    // the newest sample is i; the window centre is win/2 samples earlier
                    let centreTime = bufferStartTime + (Double(i) - Double(win) / 2) / fs
                    frame(time: centreTime)
                }
            }
        }
    }

    private func frame(time: Double) {
        vDSP_vmul(history, 1, window, 1, &windowed, 1, vDSP_Length(win))
        windowed.withUnsafeBufferPointer { wBuf in
            realp.withUnsafeMutableBufferPointer { rBuf in
                imagp.withUnsafeMutableBufferPointer { iBuf in
                    var split = DSPSplitComplex(realp: rBuf.baseAddress!, imagp: iBuf.baseAddress!)
                    wBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: win / 2) { c in
                        vDSP_ctoz(c, 2, &split, 1, vDSP_Length(win / 2))
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    mags.withUnsafeMutableBufferPointer { m in
                        vDSP_zvabs(&split, 1, m.baseAddress!, 1, vDSP_Length(win / 2))
                    }
                }
            }
        }
        var scale = Float(2.0 / Double(win))
        vDSP_vsmul(mags, 1, &scale, &mags, 1, vDSP_Length(win / 2))
        var flux: Float = 0, lowFlux: Float = 0, midFlux: Float = 0, highFlux: Float = 0
        var levels = [Float](repeating: 0, count: bandEdges.count - 1)
        for b in 0..<(bandEdges.count - 1) {
            var s: Float = 0
            let lo = bandEdges[b], hi = max(bandEdges[b] + 1, bandEdges[b + 1])
            for k in lo..<hi { s += mags[k] }
            let l = log1p(gamma * s)
            levels[b] = l
            let rise = max(0, l - prev[b])
            prev[b] = l
            flux += rise
            if b <= 3 { lowFlux += rise }            // < 281 Hz: kick / bass
            else if b <= 11 { midFlux += rise }      // 281 Hz–2.8 kHz: snare body / chords
            else { highFlux += rise }                // ≥ 2.8 kHz: snare noise / hats
        }
        odf.append(flux); low.append(lowFlux); mid.append(midFlux); high.append(highFlux)
        bands.append(levels); times.append(time)
    }
}

struct V2Estimate {
    var bpm: Double
    var confidence: Double
    var lastBeatTime: Double
    var rawPeakRatio: Double
    var downbeatPhaseBeats: Int?   // which beat (0-3) after lastBeat-grid origin carries the bar start
    var barConfidence: Double
}

final class TempoPhaseV2 {
    let frameRate: Double
    var windowSeconds = 8.0
    var priorCenter = 115.0
    var priorOctaves = 0.9
    var minSeconds = 4.0
    var silenceReset = false
    /// Frame index after the most recent ≥0.8 s near-silence (window may not reach back past it).
    private var windowFloor = 0
    private var quietRun = 0
    private(set) var currentBPM: Double = 0
    private var candidate: Double = 0
    private var wins = 0

    init(frameRate: Double) { self.frameRate = frameRate }

    func reset() { currentBPM = 0; candidate = 0; wins = 0 }

    var debug = false
    var lastSlots = ""
    var bandHistory: [[Float]]? = nil
    var allHigh: [Float]? = nil

    func update(odf allODF: [Float], low allLow: [Float], mid allMid: [Float], times allTimes: [Double]) -> V2Estimate? {
        let w = Int(windowSeconds * frameRate)
        if silenceReset {
            // scan frames since last call for silence runs
            var i = max(windowFloor, allODF.count - Int(0.6 * frameRate))
            while i < allODF.count {
                if allODF[i] < 0.02 { quietRun += 1 } else { quietRun = 0 }
                if quietRun >= Int(0.8 * frameRate) { windowFloor = i; currentBPM = 0; candidate = 0; wins = 0 }
                i += 1
            }
        }
        let available = allODF.count - windowFloor
        guard available >= Int(minSeconds * frameRate) else { return nil }
        let n = min(w, available)
        let start = allODF.count - n
        let x0 = Array(allODF[start...])
        let times = Array(allTimes[start...])
        let energy = x0.reduce(0, +)
        guard energy > 1e-3 else { return nil }
        // Detrend: subtract a 0.5 s moving average, half-wave rectify.
        let ma = movingAverage(x0, radius: Int(0.25 * frameRate))
        var x = [Double](repeating: 0, count: n)
        for i in 0..<n { x[i] = Double(max(0, x0[i] - ma[i])) }
        let mean = x.reduce(0, +) / Double(n)
        let xc = x.map { $0 - mean }
        // Autocorrelation up to 4 × the slowest period (60 BPM = 1 s) or n/2.
        let maxLag = min(n - 1, Int(4.2 * frameRate))
        var acf = [Double](repeating: 0, count: maxLag + 1)
        xc.withUnsafeBufferPointer { p in
            for lag in 0...maxLag {
                var s = 0.0
                var i = lag
                while i < n { s += p[i] * p[i - lag]; i += 1 }
                acf[lag] = s / Double(n - lag)
            }
        }
        guard acf[0] > 0 else { return nil }
        func interp(_ lag: Double) -> Double {
            guard lag >= 0, lag < Double(maxLag) else { return 0 }
            let i = Int(lag), f = lag - Double(i)
            return acf[i] * (1 - f) + acf[i + 1] * f
        }
        var bestScore = -Double.infinity, bestBPM = 0.0
        var scores: [(bpm: Double, s: Double, raw: Double)] = []
        var bpm = 60.0
        while bpm <= 200 {
            let tau = 60 * frameRate / bpm
            var s = 0.0
            for k in 1...4 { s += interp(tau * Double(k)) / Double(k).squareRoot() }
            let prior = exp(-0.5 * pow(log2(bpm / priorCenter) / priorOctaves, 2))
            let score = s * prior
            scores.append((bpm, score, s))
            if score > bestScore { bestScore = score; bestBPM = bpm }
            bpm += 0.25
        }
        guard bestScore > 0 else { return nil }
        let meanScore = scores.map { max(0, $0.s) }.reduce(0, +) / Double(scores.count)
        let peakRatio = bestScore / max(1e-12, meanScore)
        let normACF = interp(60 * frameRate / bestBPM) / acf[0]

        // Hysteresis with octave awareness.
        if currentBPM == 0 {
            currentBPM = bestBPM
        } else {
            let r = bestBPM / currentBPM
            if abs(r - 1) < 0.03 {
                currentBPM = currentBPM * 0.7 + bestBPM * 0.3; wins = 0
            } else if abs(r - 2) < 0.06 || abs(r - 0.5) < 0.03 || abs(r - 1.5) < 0.05 || abs(r - 2.0 / 3.0) < 0.03 {
                // octave/metrical flip: needs much more evidence
                if abs(bestBPM - candidate) / candidate < 0.03 { wins += 1 } else { candidate = bestBPM; wins = 1 }
                if wins >= 8 { currentBPM = candidate; wins = 0 }
            } else {
                if candidate > 0, abs(bestBPM - candidate) / candidate < 0.03 { wins += 1 } else { candidate = bestBPM; wins = 1 }
                if wins >= 3 { currentBPM = candidate; wins = 0 }
            }
        }

        // Phase: comb over the last ~12 beats, recency weighted, exact period.
        let period = 60 / currentBPM
        let tEnd = times[n - 1]
        var bestPhase = 0.0, bestE = -Double.infinity
        let step = 0.002
        var phi = 0.0
        while phi < period {
            var e = 0.0
            for k in 0..<12 {
                let t = tEnd - phi - Double(k) * period
                let pos = (t - times[0]) * frameRate
                if pos < 1 { break }
                let i = Int(pos), f = pos - Double(i)
                guard i + 1 < n else { continue }
                let v = x[i] * (1 - f) + x[i + 1] * f
                e += v * pow(0.85, Double(k))
            }
            if e > bestE { bestE = e; bestPhase = phi }
            phi += step
        }
        let lastBeat = tEnd - bestPhase

        // Bar phase (no ML): two cues folded onto the 4 beat slots of a bar.
        //  K: kick-vs-snare accent at each beat (low-band flux minus high-band flux)
        //     separates {1,3} from {2,4} in backbeat music;
        //  H: beat-synchronous spectral change (mean log-band energy over each beat
        //     vs the previous beat) — chords and textures change on bar lines,
        //     which separates 1 from 3 (and carries four-on-the-floor alone).
        var kSlot = [Double](repeating: 0, count: 4)
        var hSlot = [Double](repeating: 0, count: 4)
        if let bandHist = bandHistory {
            let lowW = Array(allLow[start...]), highW = Array(allHigh![start...])
            func idx(_ t: Double) -> Int { Int(((t - times[0]) * frameRate).rounded()) }
            var prevMean: [Float]? = nil
            // walk FORWARD over the last 16 complete beats
            for j in stride(from: 16, through: 1, by: -1) {
                let b0 = lastBeat - Double(j) * period
                let i0 = idx(b0), i1 = idx(b0 + period)
                guard i0 >= 2, i1 + 2 < n, i1 > i0 else { prevMean = nil; continue }
                // slot of the beat at b0: beat index relative to lastBeat is -j
                let slotIndex = ((-j) % 4 + 4) % 4
                var lv = 0.0, hv = 0.0
                for d in -2...2 { lv += Double(lowW[i0 + d]); hv += Double(highW[i0 + d]) }
                kSlot[slotIndex] += lv - hv
                // Harmonic-shape vector: mean log-band energy over the beat, 281 Hz–2.8 kHz,
                // level-normalised (mean removed, unit length) so broadband drum hits
                // cancel and only spectral SHAPE changes (chords, textures) remain.
                let lo = 4, hi = 11
                var mean = [Float](repeating: 0, count: hi - lo + 1)
                for i in i0..<i1 { for b in lo...hi { mean[b - lo] += bandHist[start + i][b] } }
                let mu = mean.reduce(0, +) / Float(mean.count)
                var norm: Float = 0
                for b in 0..<mean.count { mean[b] -= mu; norm += mean[b] * mean[b] }
                norm = norm.squareRoot()
                if norm > 1e-6 { for b in 0..<mean.count { mean[b] /= norm } }
                if let pm = prevMean {
                    var dot: Float = 0
                    for b in 0..<mean.count { dot += mean[b] * pm[b] }
                    hSlot[slotIndex] += Double(1 - dot)   // cosine distance
                }
                prevMean = mean
            }
        }
        func normalized(_ v: [Double]) -> [Double] {
            let m = v.reduce(0, +) / 4
            let dev = v.map { $0 - m }
            let scale = dev.map { abs($0) }.reduce(0, +)
            return scale > 1e-9 ? dev.map { $0 / scale } : [0, 0, 0, 0]
        }
        let kN = normalized(kSlot), hN = normalized(hSlot)
        var combined = [Double](repeating: 0, count: 4)
        for s in 0..<4 { combined[s] = hN[s] + 0.8 * kN[s] }
        let order = (0..<4).sorted { combined[$0] > combined[$1] }
        let pick = order[0]
        let barConf = combined[order[0]] - combined[order[1]]
        if debug {
            lastSlots = "K " + kN.map { String(format: "%+.2f", $0) }.joined(separator: " ") + " | H " + hN.map { String(format: "%+.2f", $0) }.joined(separator: " ")
        }

        return V2Estimate(bpm: currentBPM, confidence: min(1, max(0, normACF)), lastBeatTime: lastBeat,
                          rawPeakRatio: peakRatio, downbeatPhaseBeats: pick, barConfidence: barConf)
    }

    private func movingAverage(_ x: [Float], radius: Int) -> [Float] {
        var out = [Float](repeating: 0, count: x.count)
        var acc: Float = 0
        var count = 0
        var lo = 0, hi = -1
        for i in 0..<x.count {
            let newHi = min(x.count - 1, i + radius), newLo = max(0, i - radius)
            while hi < newHi { hi += 1; acc += x[hi]; count += 1 }
            while lo < newLo { acc -= x[lo]; lo += 1; count -= 1 }
            out[i] = acc / Float(max(1, count))
        }
        return out
    }
}

struct V2Options { var minSeconds = 4.0; var silenceReset = false; var pll = false }
