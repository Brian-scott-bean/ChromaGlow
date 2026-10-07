// BeatTracker.swift
// ChromaGlow — Core/Audio (Play Along P1)
//
// Tempo, beat phase and bar ("the one") from the 10 ms onset frames.
// Pure: no clocks, no I/O, no audio — the ~2 Hz tempo pass hands it a frame
// window and gets a BeatObservation back, which BeatClock turns into the
// predictive grid every render loop reads.
//
// Method (prototype and measurements: docs/ios/play-along/beatlab):
//  • Tempo: autocorrelation of the detrended onset flux over the last 8 s,
//    scored by a 4-harmonic comb on a 0.25-BPM grid with fractional lags,
//    weighted by a log-Gaussian "lighting tempo" prior (115 BPM, σ 0.9
//    octave) — or by narrow peaks at a tempo the music service or the song
//    memory already knows. Octave-aware hysteresis keeps it from flapping.
//  • Phase: a comb search at 2 ms resolution over the last 12 beats, recency
//    weighted, at the EXACT fractional period. The old tracker rounded the
//    period to whole 100 ms hops and placed beats to the nearest hop.
//  • Bar: the last 16 beats folded onto the 4 slots of a bar. Kick-vs-snare
//    (low minus high flux) separates {1,3} from {2,4}; the beat-synchronous
//    change in spectral SHAPE (cosine distance of level-normalised mid-band
//    vectors) marks chord changes, which fall on bar lines and separate 1
//    from 3.
//  • Silence of 0.8 s or more drops the old song from the window, so the
//    next one locks fresh instead of fighting the last one's onsets.

import Foundation

/// What the tracker heard, in the capture timebase (CACurrentMediaTime).
struct BeatObservation: Sendable, Equatable {
    var bpm: Double
    /// Capture time of the most recent beat.
    var lastBeat: Double
    /// 0–1: how strongly the onsets repeat at this tempo.
    var tempoConfidence: Double
    /// 0–1: how sharply the onsets agree on where the beat falls.
    var phaseConfidence: Double
    /// Downbeats fall at beat indices ≡ `barSlot` (mod 4) counted from
    /// `lastBeat` (0 = `lastBeat` itself). nil = no opinion.
    var barSlot: Int?
    /// 0–1: how clearly one slot wins.
    var barConfidence: Double

    var period: Double { 60 / bpm }
}

/// A tempo already known from outside the room (music service, song memory).
struct TempoPrior: Sendable, Equatable {
    var bpm: Double
    /// 0…1 — how much the prior outweighs the generic lighting-tempo prior.
    var strength: Double = 1
}

final class BeatTracker: @unchecked Sendable {

    // ── Tunables (measured in the beat lab) ──
    static let windowSeconds = 8.0
    static let minSeconds = 4.0
    static let minBPM = 60.0
    static let maxBPM = 200.0
    static let bpmStep = 0.25
    static let priorCenterBPM = 115.0
    static let priorOctaves = 0.9
    static let phaseStep = 0.002
    static let phaseBeats = 12
    static let phaseDecay = 0.85
    static let barBeats = 16
    static let silenceSeconds = 0.8
    /// A frame is "quiet" below this share of the window's loud level.
    static let silenceRatio: Float = 0.3
    /// Normalised autocorrelation that maps to zero / full tempo confidence.
    static let confidenceFloor = 0.2
    static let confidenceSpan = 0.3

    // ── State (single caller: the tempo pass) ──
    private var currentBPM = 0.0
    private var candidateBPM = 0.0
    private var candidateWins = 0
    /// Frames captured before this time belong to a previous song.
    private(set) var windowFloor = -Double.infinity

    func reset() {
        currentBPM = 0
        candidateBPM = 0
        candidateWins = 0
        windowFloor = -.infinity
    }

    /// One tempo pass. nil when the window is too short, silent, or has no
    /// usable periodicity (the clock keeps what it had).
    func update(_ frames: OnsetFrames, prior: TempoPrior? = nil) -> BeatObservation? {
        guard frames.count > 2, frames.frameRate > 0 else { return nil }
        let fr = frames.frameRate
        noteSilence(frames)

        // The analysis window: the last 8 s, never reaching back past a silence.
        var start = max(0, frames.count - Int(Self.windowSeconds * fr))
        while start < frames.count && frames.times[start] < windowFloor { start += 1 }
        let n = frames.count - start
        guard n >= Int(Self.minSeconds * fr) else { return nil }

        // Detrend (0.5 s moving average) and rectify.
        var x = [Double](repeating: 0, count: n)
        let radius = Int(0.25 * fr)
        var acc: Double = 0, lo = start, hi = start - 1, cnt = 0
        for i in 0..<n {
            let idx = start + i
            let newHi = min(frames.count - 1, idx + radius), newLo = max(start, idx - radius)
            while hi < newHi { hi += 1; acc += Double(frames.flux[hi]); cnt += 1 }
            while lo < newLo { acc -= Double(frames.flux[lo]); lo += 1; cnt -= 1 }
            x[i] = max(0, Double(frames.flux[idx]) - acc / Double(max(1, cnt)))
        }
        let total = x.reduce(0, +)
        guard total > 1e-6 else { return nil }
        let mean = total / Double(n)

        // Autocorrelation up to four periods of the slowest tempo.
        let maxLag = min(n - 2, Int(4.2 * 60 / Self.minBPM * fr))
        guard maxLag > Int(60 / Self.maxBPM * fr) else { return nil }
        var acf = [Double](repeating: 0, count: maxLag + 1)
        x.withUnsafeBufferPointer { p in
            for lag in 0...maxLag {
                var s = 0.0
                var i = lag
                while i < n { s += (p[i] - mean) * (p[i - lag] - mean); i += 1 }
                acf[lag] = s / Double(n - lag)
            }
        }
        guard acf[0] > 0 else { return nil }
        func at(_ lag: Double) -> Double {
            guard lag >= 0, lag < Double(maxLag) else { return 0 }
            let i = Int(lag), f = lag - Double(i)
            return acf[i] * (1 - f) + acf[i + 1] * f
        }

        // Comb score × prior on a 0.25-BPM grid.
        var grid: [(bpm: Double, score: Double)] = []
        grid.reserveCapacity(Int((Self.maxBPM - Self.minBPM) / Self.bpmStep) + 1)
        var bpm = Self.minBPM
        while bpm <= Self.maxBPM + 1e-9 {
            let tau = 60 * fr / bpm
            var s = 0.0
            for k in 1...4 { s += at(tau * Double(k)) / Double(k).squareRoot() }
            grid.append((bpm, s * priorWeight(bpm, prior: prior)))
            bpm += Self.bpmStep
        }
        guard let bestIndex = grid.indices.max(by: { grid[$0].score < grid[$1].score }),
              grid[bestIndex].score > 0 else { return nil }
        // Parabolic refinement between grid points.
        var best = grid[bestIndex].bpm
        if bestIndex > 0, bestIndex < grid.count - 1 {
            let a = grid[bestIndex - 1].score, b = grid[bestIndex].score, c = grid[bestIndex + 1].score
            let denom = a - 2 * b + c
            if abs(denom) > 1e-12 {
                let d = 0.5 * (a - c) / denom
                if abs(d) < 1 { best += d * Self.bpmStep }
            }
        }
        let normACF = at(60 * fr / best) / acf[0]
        var tempoConfidence = min(1, max(0, (normACF - Self.confidenceFloor) / Self.confidenceSpan))
        adoptTempo(best, prior: prior)
        if let prior, Self.isSameMeter(currentBPM, prior.bpm) {
            tempoConfidence = max(tempoConfidence, 0.9 * prior.strength)
        }

        // Phase: comb over the last 12 beats at the exact period.
        let period = 60 / currentBPM
        let tEnd = frames.times[frames.count - 1]
        let t0 = frames.times[start]
        func sample(_ t: Double) -> Double? {
            let pos = (t - t0) * fr
            guard pos >= 0 else { return nil }
            let i = Int(pos), f = pos - Double(i)
            guard i + 1 < n else { return i < n ? x[i] : nil }
            return x[i] * (1 - f) + x[i + 1] * f
        }
        var bestPhase = 0.0, bestEnergy = -Double.infinity, energySum = 0.0, steps = 0
        var phi = 0.0
        while phi < period {
            var e = 0.0, w = 1.0
            for k in 0..<Self.phaseBeats {
                guard let v = sample(tEnd - phi - Double(k) * period) else { break }
                e += v * w
                w *= Self.phaseDecay
            }
            energySum += e
            steps += 1
            if e > bestEnergy { bestEnergy = e; bestPhase = phi }
            phi += Self.phaseStep
        }
        let lastBeat = tEnd - bestPhase
        let meanEnergy = energySum / Double(max(1, steps))
        let peakiness = bestEnergy > 0 ? (bestEnergy - meanEnergy) / bestEnergy : 0
        let phaseConfidence = tempoConfidence * min(1, max(0, peakiness / 0.6))

        let bar = barEstimate(frames, start: start, lastBeat: lastBeat, period: period)
        return BeatObservation(bpm: currentBPM, lastBeat: lastBeat,
                               tempoConfidence: tempoConfidence, phaseConfidence: phaseConfidence,
                               barSlot: bar?.slot, barConfidence: bar?.confidence ?? 0)
    }

    // MARK: - Tempo prior and hysteresis

    private func priorWeight(_ bpm: Double, prior: TempoPrior?) -> Double {
        let generic = exp(-0.5 * pow(log2(bpm / Self.priorCenterBPM) / Self.priorOctaves, 2))
        guard let prior, prior.bpm > 0 else { return generic }
        var known = 0.0
        for (multiple, weight) in [(1.0, 1.0), (2.0, 0.5), (0.5, 0.5)] {
            let d = log2(bpm / (prior.bpm * multiple)) / 0.03
            known = max(known, weight * exp(-0.5 * d * d))
        }
        let s = min(1, max(0, prior.strength))
        return generic * (1 - s) + known * s
    }

    /// Same tempo, or the same music at double / half / 3:2 metre.
    static func isSameMeter(_ a: Double, _ b: Double) -> Bool {
        guard a > 0, b > 0 else { return false }
        let r = a / b
        return [1.0, 2.0, 0.5].contains { abs(r / $0 - 1) < 0.03 }
    }

    private func adoptTempo(_ bpm: Double, prior: TempoPrior?) {
        if currentBPM == 0 {
            currentBPM = bpm
            return
        }
        let r = bpm / currentBPM
        if abs(r - 1) < 0.03 {
            currentBPM = currentBPM * 0.7 + bpm * 0.3
            candidateWins = 0
            return
        }
        // A tempo the outside world vouches for switches at once.
        if let prior, abs(bpm / prior.bpm - 1) < 0.03 {
            currentBPM = bpm
            candidateWins = 0
            return
        }
        let metricFlip = [2.0, 0.5, 1.5, 2.0 / 3.0].contains { abs(r / $0 - 1) < 0.03 }
        if candidateBPM > 0, abs(bpm / candidateBPM - 1) < 0.03 {
            candidateWins += 1
        } else {
            candidateBPM = bpm
            candidateWins = 1
        }
        if candidateWins >= (metricFlip ? 8 : 3) {
            currentBPM = candidateBPM
            candidateWins = 0
        }
    }

    // MARK: - Silence

    /// A run of quiet frames of at least 0.8 s ends the song: frames before
    /// its end leave the window and the tempo state starts over.
    private func noteSilence(_ frames: OnsetFrames) {
        let fr = frames.frameRate
        let lookback = min(frames.count, Int(Self.windowSeconds * fr))
        guard lookback > Int(Self.silenceSeconds * fr) else { return }
        let from = frames.count - lookback
        var loud: Float = 0
        for i in from..<frames.count { loud = max(loud, frames.energy[i]) }
        guard loud > 0 else { return }
        let gate = loud * Self.silenceRatio
        let needed = Int(Self.silenceSeconds * fr)
        var run = 0
        var lastQuietEnd: Double?
        for i in from..<frames.count {
            if frames.energy[i] < gate {
                run += 1
                if run >= needed { lastQuietEnd = frames.times[i] }
            } else {
                run = 0
            }
        }
        if let end = lastQuietEnd, end > windowFloor {
            windowFloor = end
            currentBPM = 0
            candidateBPM = 0
            candidateWins = 0
        }
    }

    // MARK: - Bar

    private func barEstimate(_ frames: OnsetFrames, start: Int, lastBeat: Double,
                             period: Double) -> (slot: Int, confidence: Double)? {
        let fr = frames.frameRate
        let t0 = frames.times[start]
        func index(_ t: Double) -> Int { start + Int(((t - t0) * fr).rounded()) }
        var kick = [Double](repeating: 0, count: 4)
        var change = [Double](repeating: 0, count: 4)
        var previous: [Double]? = nil
        let mid = Array(OnsetFrameAnalyzer.midBands)
        var used = 0
        for j in stride(from: Self.barBeats, through: 1, by: -1) {
            let beatTime = lastBeat - Double(j) * period
            let i0 = index(beatTime), i1 = index(beatTime + period)
            guard i0 - 2 >= start, i1 + 2 < frames.count, i1 > i0 else { previous = nil; continue }
            let slot = ((-j) % 4 + 4) % 4
            var low = 0.0, high = 0.0
            for d in -2...2 { low += Double(frames.low[i0 + d]); high += Double(frames.high[i0 + d]) }
            kick[slot] += low - high
            // Level-normalised mid-band shape over the beat.
            var v = [Double](repeating: 0, count: mid.count)
            for i in i0..<i1 { for (k, b) in mid.enumerated() { v[k] += Double(frames.band(i, b)) } }
            let mu = v.reduce(0, +) / Double(v.count)
            var norm = 0.0
            for k in v.indices { v[k] -= mu; norm += v[k] * v[k] }
            norm = norm.squareRoot()
            if norm > 1e-9 { for k in v.indices { v[k] /= norm } }
            if let previous {
                var dot = 0.0
                for k in v.indices { dot += v[k] * previous[k] }
                change[slot] += 1 - dot
            }
            previous = v
            used += 1
        }
        guard used >= 8 else { return nil }
        func normalized(_ v: [Double]) -> [Double] {
            let m = v.reduce(0, +) / 4
            let dev = v.map { $0 - m }
            let scale = dev.map { abs($0) }.reduce(0, +)
            return scale > 1e-9 ? dev.map { $0 / scale } : [0, 0, 0, 0]
        }
        let k = normalized(kick), h = normalized(change)
        let combined = (0..<4).map { h[$0] + 0.8 * k[$0] }
        let order = (0..<4).sorted { combined[$0] > combined[$1] }
        let margin = combined[order[0]] - combined[order[1]]
        return (order[0], min(1, max(0, margin / 0.3)))
    }
}
